#!/usr/bin/env bash
set -euo pipefail

# -------- Helpers --------
log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
need_root(){ [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root"; exit 1; }; }
bk(){ local f="$1"; [ -f "$f" ] && cp -a "$f" "${f}.bak.$(date +%s)"; }

need_root
. /etc/os-release || true
ID_LOW="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"
IDLIKE_LOW="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
is_deb(){ [[ "$ID_LOW" =~ ^(debian|ubuntu)$ || "$IDLIKE_LOW" == *debian* ]]; }

log "== Secure hardening started =="

# -------- Packages --------
if is_deb; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y ufw fail2ban unattended-upgrades apt-listchanges auditd
else
  log "Non-Debian/Ubuntu system. Attempting best-effort installs…"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install fail2ban audit
  elif command -v yum >/dev/null 2>&1; then
    yum -y install fail2ban audit
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache fail2ban
  fi
fi

# -------- Detect SSH port --------
SSHD_CFG="/etc/ssh/sshd_config"
SSH_PORT="22"
if [ -f "$SSHD_CFG" ]; then
  p="$(awk '/^[Pp]ort[[:space:]]+[0-9]+/ {print $2; exit}' "$SSHD_CFG" || true)"
  [ -n "${p:-}" ] && SSH_PORT="$p"
fi
log "Detected SSH port: $SSH_PORT"

# -------- UFW firewall (Deb/Ubuntu) --------
if command -v ufw >/dev/null 2>&1; then
  log "Configuring UFW…"
  ufw --force reset
  ufw default deny incoming
  ufw default allow outgoing

  # Always allow SSH on detected port
  ufw allow "${SSH_PORT}/tcp" comment "SSH"

  # If web ports are in use, allow them
  if ss -ltn | awk '{print $4}' | grep -qE ':(80|443)$'; then
    ss -ltn | awk '{print $4}' | grep -E ':(80|443)$' | sed 's/.*://g' | sort -u | while read -r port; do
      ufw allow "${port}/tcp" comment "web"
    done
  fi

  ufw --force enable
  ufw status verbose
else
  log "UFW not available; skipping firewall (consider firewalld/nftables)."
fi

# -------- SSH hardening (safe) --------
if [ -f "$SSHD_CFG" ]; then
  log "Hardening SSH…"
  bk "$SSHD_CFG"
  # Ensure key auth if keys exist; else keep password auth to avoid lockout
  HAS_KEYS=0
  for d in "/root/.ssh/authorized_keys" "/home/${SUDO_USER:-$USER}/.ssh/authorized_keys"; do
    [ -s "$d" ] && HAS_KEYS=1
  done

  # Basic safe settings
  sed -i \
    -e 's/^[#[:space:]]*Protocol.*/Protocol 2/' \
    -e "s/^[#[:space:]]*Port.*/Port ${SSH_PORT}/" \
    -e 's/^[#[:space:]]*PermitRootLogin.*/PermitRootLogin prohibit-password/' \
    -e 's/^[#[:space:]]*MaxAuthTries.*/MaxAuthTries 3/' \
    -e 's/^[#[:space:]]*LoginGraceTime.*/LoginGraceTime 30/' \
    -e 's/^[#[:space:]]*ClientAliveInterval.*/ClientAliveInterval 300/' \
    -e 's/^[#[:space:]]*ClientAliveCountMax.*/ClientAliveCountMax 2/' \
    "$SSHD_CFG"

  if [ "$HAS_KEYS" -eq 1 ]; then
    if grep -qi '^[#[:space:]]*PasswordAuthentication' "$SSHD_CFG"; then
      sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CFG"
    else
      echo "PasswordAuthentication no" >> "$SSHD_CFG"
    fi
    log "Found SSH keys → PasswordAuthentication disabled."
  else
    if grep -qi '^[#[:space:]]*PasswordAuthentication' "$SSHD_CFG"; then
      sed -i 's/^[#[:space:]]*PasswordAuthentication.*/PasswordAuthentication yes/' "$SSHD_CFG"
    else
      echo "PasswordAuthentication yes" >> "$SSHD_CFG"
    fi
    log "No SSH keys found → PasswordAuthentication kept to avoid lockout."
  fi

  systemctl reload ssh || systemctl reload sshd || true
fi

# -------- Fail2ban --------
if command -v fail2ban-server >/dev/null 2>&1; then
  log "Configuring Fail2ban…"
  JAILD="/etc/fail2ban/jail.d"
  mkdir -p "$JAILD"

  cat > "$JAILD/00-hardening-ssh.local" <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ssh
backend = systemd
EOF

  # Enable nginx auth protections if nginx present
  if command -v nginx >/dev/null 2>&1; then
    cat > "$JAILD/10-nginx.local" <<'EOF'
[nginx-http-auth]
enabled = true

[nginx-botsearch]
enabled = true
EOF
  fi

  systemctl enable --now fail2ban || true
  fail2ban-client reload || true
  fail2ban-client status || true
fi

# -------- Unattended upgrades (Deb/Ubuntu) --------
if is_deb; then
  log "Configuring unattended-upgrades (security)…"
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOC'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOC

  cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOC'
Unattended-Upgrade::Origins-Pattern {
  "origin=Ubuntu,codename=${distro_codename}-security";
  "origin=Ubuntu,codename=${distro_codename}-updates";
  "origin=Debian,codename=${distro_codename}-security";
  "origin=Debian,codename=${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Verbose "true";
EOC
  systemctl enable --now unattended-upgrades.service || true
fi

# -------- sysctl hardening --------
SYSCTL_H="/etc/sysctl.d/99-hardening.conf"
log "Applying sysctl hardening…"
bk "$SYSCTL_H" || true
cat > "$SYSCTL_H" <<'EOF'
# Anti spoof / redirects / misc hardening
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
# Note: accept_ra=0 is safer for serveurs, peut casser SLAAC sur certains hôtes
net.ipv6.conf.all.accept_ra = 0
net.ipv6.conf.default.accept_ra = 0

net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_rfc1337 = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.unprivileged_bpf_disabled = 1
kernel.randomize_va_space = 2
EOF

sysctl --system >/dev/null 2>&1 || sysctl -p "$SYSCTL_H" >/dev/null 2>&1 || true

# -------- auditd basic --------
if command -v auditctl >/dev/null 2>&1 || [ -f /sbin/auditctl ]; then
  log "Enabling auditd…"
  systemctl enable --now auditd || true
fi

log "== Hardening complete =="
echo
echo "Firewall: $(command -v ufw >/dev/null 2>&1 && ufw status | sed -n '1,8p' || echo 'Not configured (no ufw)')"
echo "Fail2ban: $(systemctl is-active fail2ban 2>/dev/null || true)"
echo "SSH port: ${SSH_PORT}"
echo "Tip: ajoute une clé SSH puis re-lance le script pour désactiver les mots de passe."
