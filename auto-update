#!/usr/bin/env bash
set -euo pipefail

# --- Helpers ---
log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*"; }
need_root() { [ "${EUID:-$(id -u)}" -eq 0 ] || { echo "Run as root."; exit 1; }; }

# --- Vars ---
TARGET_SCRIPT="/usr/local/sbin/system-auto-update.sh"
LOG_FILE="/var/log/system-auto-update.log"
SERVICE_NAME="system-auto-update"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
TIMER_FILE="/etc/systemd/system/${SERVICE_NAME}.timer"

need_root

# Detect distro
. /etc/os-release || true
ID_LIKE_LOWER="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
ID_LOWER="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"

is_deb() { [[ "$ID_LIKE_LOWER" == *"debian"* ]] || [[ "$ID_LOWER" == "debian" ]] || [[ "$ID_LOWER" == "ubuntu" ]]; }
is_rhel() { [[ "$ID_LIKE_LOWER" == *"rhel"* || "$ID_LIKE_LOWER" == *"fedora"* || "$ID_LOWER" =~ ^(rhel|centos|rocky|almalinux|fedora)$ ]]; }
is_suse() { [[ "$ID_LIKE_LOWER" == *"suse"* || "$ID_LOWER" =~ ^(opensuse|sles)$ ]]; }
is_arch() { [[ "$ID_LOWER" == "arch" || "$ID_LIKE_LOWER" == *"arch"* ]]; }
is_alpine() { [[ "$ID_LOWER" == "alpine" ]]; }

has_systemd() { command -v systemctl >/dev/null 2>&1 && pidof systemd >/dev/null 2>&1; }

# --- Create the worker script ---
install -d -m 0755 "$(dirname "$TARGET_SCRIPT")"

cat > "$TARGET_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/system-auto-update.log"
touch "$LOG_FILE"; chmod 0644 "$LOG_FILE"

log() { printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE"; }

. /etc/os-release || true
ID_LIKE_LOWER="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
ID_LOWER="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"

is_deb()   { [[ "$ID_LIKE_LOWER" == *"debian"* ]] || [[ "$ID_LOWER" == "debian" ]] || [[ "$ID_LOWER" == "ubuntu" ]]; }
is_rhel()  { [[ "$ID_LIKE_LOWER" == *"rhel"* || "$ID_LIKE_LOWER" == *"fedora"* || "$ID_LOWER" =~ ^(rhel|centos|rocky|almalinux|fedora)$ ]]; }
is_suse()  { [[ "$ID_LIKE_LOWER" == *"suse"* || "$ID_LOWER" =~ ^(opensuse|sles)$ ]]; }
is_arch()  { [[ "$ID_LOWER" == "arch" || "$ID_LIKE_LOWER" == *"arch"* ]]; }
is_alpine(){ [[ "$ID_LOWER" == "alpine" ]]; }

# No auto reboot policy respected everywhere
log "Starting automated update run."

if is_deb; then
  export DEBIAN_FRONTEND=noninteractive
  log "Debian/Ubuntu detected: updating APT caches…"
  apt-get update -y | tee -a "$LOG_FILE"
  log "Applying security updates (unattended-upgrades)…"
  # Trigger only security first; then minimal dist-upgrade if needed
  unattended-upgrade -d | tee -a "$LOG_FILE" || true
  log "Applying remaining safe upgrades…"
  apt-get -y -o Dpkg::Options::=--force-confnew dist-upgrade | tee -a "$LOG_FILE"
  apt-get -y autoremove --purge | tee -a "$LOG_FILE" || true
  apt-get -y autoclean | tee -a "$LOG_FILE" || true

elif is_rhel; then
  log "RHEL/CentOS/Rocky/Alma/Fedora detected: updating security advisories…"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y updateinfo --security | tee -a "$LOG_FILE" || true
    dnf -y upgrade --security | tee -a "$LOG_FILE"
  else
    yum -y update --security | tee -a "$LOG_FILE"
  fi

elif is_suse; then
  log "openSUSE/SLES detected: applying security patches…"
  zypper --non-interactive refresh | tee -a "$LOG_FILE"
  zypper --non-interactive patch --category security | tee -a "$LOG_FILE"
  # Optionally include recommended patches:
  zypper --non-interactive patch | tee -a "$LOG_FILE" || true

elif is_arch; then
  log "Arch Linux detected: full system upgrade (no dedicated security channel)…"
  pacman -Syu --noconfirm | tee -a "$LOG_FILE"

elif is_alpine; then
  log "Alpine detected: updating and upgrading available packages…"
  apk update | tee -a "$LOG_FILE"
  apk upgrade --available | tee -a "$LOG_FILE"

else
  log "Unknown distro. Attempting generic APT/DNF/Zypper/Pacman/APK best-effort…"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y && apt-get -y dist-upgrade | tee -a "$LOG_FILE"
  elif command -v dnf >/dev/null 2>&1; then
    dnf -y upgrade --security | tee -a "$LOG_FILE" || dnf -y upgrade | tee -a "$LOG_FILE"
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive refresh && zypper --non-interactive patch | tee -a "$LOG_FILE"
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm | tee -a "$LOG_FILE"
  elif command -v apk >/dev/null 2>&1; then
    apk update && apk upgrade --available | tee -a "$LOG_FILE"
  else
    log "No known package manager found."
    exit 1
  fi
fi

log "Update run finished (no automatic reboot)."
EOF

chmod 0755 "$TARGET_SCRIPT"
touch "$LOG_FILE"; chmod 0644 "$LOG_FILE"

# --- Configure security auto-updates per distro ---
if is_deb; then
  log "Configuring Debian/Ubuntu: unattended-upgrades (security) and periodic APT…"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y unattended-upgrades apt-listchanges >/dev/null 2>&1 || true

  # 50unattended-upgrades
  cat >/etc/apt/apt.conf.d/50unattended-upgrades <<'EOC'
Unattended-Upgrade::Origins-Pattern {
        "origin=Ubuntu,codename=${distro_codename}-security";
        "origin=Ubuntu,codename=${distro_codename}-updates";
        "origin=Debian,codename=${distro_codename}-security";
        "origin=Debian,codename=${distro_codename}-updates";
};
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Verbose "true";
EOC

  # 20auto-upgrades
  cat >/etc/apt/apt.conf.d/20auto-upgrades <<'EOC'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOC

  systemctl enable --now unattended-upgrades.service || true
fi

if is_rhel; then
  log "Configuring DNF Automatic (security only, no reboot)…"
  if command -v dnf >/dev/null 2>&1; then
    dnf -y install dnf-automatic || true
    sed -i \
      -e 's/^apply_updates.*/apply_updates = yes/' \
      -e 's/^upgrade_type.*/upgrade_type = security/' \
      -e 's/^download_updates.*/download_updates = yes/' \
      /etc/dnf/automatic.conf || true
    # We'll use our own 01:00 timer below, no need to enable the default one.
  else
    yum -y install yum-cron || true
    sed -i \
      -e 's/^apply_updates.*/apply_updates = yes/' \
      -e 's/^update_cmd.*/update_cmd = security/' \
      /etc/yum/yum-cron.conf || true
    systemctl enable --now yum-cron || true
  fi
fi

if is_suse; then
  log "Ensuring zypper and patching tools are present…"
  zypper --non-interactive install -y patch || true
fi

# --- Schedule daily at 01:00 ---
if has_systemd; then
  log "Creating systemd service and timer at 01:00…"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Nightly system auto update (no reboot)
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$TARGET_SCRIPT
Nice=10
IOSchedulingClass=best-effort
EOF

  cat >"$TIMER_FILE" <<EOF
[Unit]
Description=Run ${SERVICE_NAME} daily at 01:00

[Timer]
OnCalendar=*-*-* 01:00:00
RandomizedDelaySec=300
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "${SERVICE_NAME}.timer"
  log "Timer enabled: systemctl list-timers ${SERVICE_NAME}.timer"
else
  log "Systemd not detected. Installing root cron entry for 01:00…"
  # ensure cron is present
  if command -v apt-get >/dev/null 2>&1; then apt-get install -y cron >/dev/null 2>&1 || true; fi
  if command -v zypper >/dev/null 2>&1; then zypper --non-interactive install -y cron >/dev/null 2>&1 || true; fi
  if command -v dnf >/dev/null 2>&1; then dnf -y install cronie >/dev/null 2>&1 || true; fi
  if command -v yum >/dev/null 2>&1; then yum -y install cronie >/dev/null 2>&1 || true; fi

  # add to /etc/crontab (idempotent)
  CRON_LINE="0 1 * * * root ${TARGET_SCRIPT} >/dev/null 2>&1"
  grep -Fq "${TARGET_SCRIPT}" /etc/crontab || echo "$CRON_LINE" >> /etc/crontab
  log "Cron installed in /etc/crontab: $CRON_LINE"
fi

# --- Run once now to ensure everything is healthy ---
log "Running an initial update pass now…"
"$TARGET_SCRIPT"

log "Installation complete. Logs: $LOG_FILE"
