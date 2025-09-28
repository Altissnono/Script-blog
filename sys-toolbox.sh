#!/usr/bin/env bash
# sys-toolbox.sh - Menu interactif pour opérations d'admin courantes
# Actions :
# 1) health-report  2) cleanup-system  3) docker update
# 4) ssl expiry check  5) disk-space check  6) quitter
# Journal léger : /var/log/sys-toolbox.log

set -euo pipefail

# ---------- Couleurs & helpers ----------
C_RESET="\033[0m"; C_BOLD="\033[1m"; C_DIM="\033[2m"
C_OK="\033[32m"; C_WARN="\033[33m"; C_ERR="\033[31m"; C_INFO="\033[36m"
LOG_FILE="/var/log/sys-toolbox.log"
mkdir -p "$(dirname "$LOG_FILE")" && touch "$LOG_FILE" && chmod 0644 "$LOG_FILE"

log(){ printf "[%s] %s\n" "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >/dev/null; }
say(){ printf "${C_INFO}%s${C_RESET}\n" "$*"; }
ok(){ printf "${C_OK}✔ %s${C_RESET}\n" "$*"; }
warn(){ printf "${C_WARN}⚠ %s${C_RESET}\n" "$*"; }
err(){ printf "${C_ERR}✖ %s${C_RESET}\n" "$*"; }

need_root(){
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Cette action nécessite root (sudo)."; return 1
  fi
}

# Détection OS / pkg
. /etc/os-release 2>/dev/null || true
ID_LOW="$(echo "${ID:-}" | tr '[:upper:]' '[:lower:]')"
IDLIKE_LOW="$(echo "${ID_LIKE:-}" | tr '[:upper:]' '[:lower:]')"
is_deb(){ [[ "$ID_LOW" =~ ^(debian|ubuntu)$ || "$IDLIKE_LOW" == *debian* ]]; }
is_rhel(){ [[ "$ID_LOW" =~ ^(rhel|centos|rocky|almalinux|fedora)$ || "$IDLIKE_LOW" == *rhel* || "$IDLIKE_LOW" == *fedora* ]]; }
is_suse(){ [[ "$ID_LOW" =~ ^(opensuse|sles)$ || "$IDLIKE_LOW" == *suse* ]]; }
is_arch(){ [[ "$ID_LOW" == "arch" || "$IDLIKE_LOW" == *arch* ]]; }
is_alpine(){ [[ "$ID_LOW" == "alpine" ]]; }

have(){ command -v "$1" >/dev/null 2>&1; }

# ---------- Envoi / sortie ----------
send_to_file(){
  local content="$1"; local default="/root/report-$(date +%F_%H%M%S).txt"
  read -rp "Chemin du fichier (defaut: $default) : " path
  path="${path:-$default}"
  printf "%s\n" "$content" > "$path"
  ok "Fichier enregistré : $path"
}

send_to_discord(){
  local content="$1"
  if ! have curl; then err "curl requis pour Discord webhook."; return 1; fi
  read -rp "URL du webhook Discord : " webhook
  [ -z "${webhook:-}" ] && { warn "Webhook vide, envoi annulé."; return 1; }
  curl -sS -H "Content-Type: application/json" -X POST \
    -d "$(jq -Rn --arg c "$content" '{content:$c}' 2>/dev/null || echo "{\"content\":\"$(printf "%s" "$content" | sed 's/"/\\"/g')\"}")" \
    "$webhook" >/dev/null || true
  ok "Envoyé sur Discord."
}

send_to_mail(){
  local content="$1"
  if ! have mail && ! have mailx && ! have sendmail; then
    warn "mail/mailx/sendmail absent → envoi mail indisponible."; return 1
  fi
  read -rp "Adresse e-mail destinataire : " to
  [ -z "${to:-}" ] && { warn "Adresse vide, envoi annulé."; return 1; }
  local subj="Rapport $(hostname) $(date '+%F %T')"
  if have mailx; then echo "$content" | mailx -s "$subj" "$to"
  elif have mail; then echo "$content" | mail -s "$subj" "$to"
  else
    {
      echo "Subject: $subj"
      echo "To: $to"
      echo
      echo "$content"
    } | sendmail -t
  fi
  ok "E-mail envoyé à $to."
}

choose_destination(){
  local content="$1"
  echo
  say "Choisir la destination :
  1) Afficher à l'écran
  2) Enregistrer dans un fichier
  3) Envoyer sur Discord (webhook)
  4) Envoyer par e-mail"
  read -rp "Choix [1-4] : " dst
  case "${dst:-1}" in
    1) echo -e "\n${C_BOLD}--- Rapport ---${C_RESET}\n$content\n";;
    2) send_to_file "$content";;
    3) send_to_discord "$content";;
    4) send_to_mail "$content";;
    *) warn "Choix invalide, affichage écran par défaut."; echo "$content";;
  esac
}

# ---------- 1) HEALTH REPORT ----------
health_report(){
  say "Génération du rapport santé…"
  local hn up load mem swap disk top cpu temp pubip iplocal pkgs
  hn="$(hostnamectl 2>/dev/null || hostname 2>/dev/null || echo "$(hostname)")"
  up="$(uptime -p 2>/dev/null || uptime 2>/dev/null)"
  load="$(awk '{print $1" "$2" "$3}' /proc/loadavg 2>/dev/null)"
  mem="$(free -h 2>/dev/null || free -m)"
  swap="$(grep -E '^Swap' /proc/meminfo 2>/dev/null || true)"
  disk="$(df -hT -x tmpfs -x devtmpfs 2>/dev/null)"
  top="$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)"
  cpu="$(lscpu 2>/dev/null | sed -n '1,12p' || true)"
  temp="$(/usr/sbin/sensors 2>/dev/null || true)"
  iplocal="$(ip -o -4 addr show 2>/dev/null | awk '{print $2"="$4}' | sed 's/\/.*//')"
  if have curl; then pubip="$(curl -s https://ifconfig.me 2>/dev/null || curl -s https://api.ipify.org 2>/dev/null || true)"; fi

  if is_deb; then
    pkgs="$(apt list --upgradeable 2>/dev/null | sed -n '2,50p' || true)"
  elif is_rhel; then
    pkgs="$(dnf -q check-update 2>/dev/null || true)"
  elif is_arch; then
    pkgs="$(checkupdates 2>/dev/null || true)"
  elif is_alpine; then
    pkgs="$(apk version -l '<' 2>/dev/null || true)"
  else pkgs="N/A"; fi

  local REPORT
  REPORT="$(cat <<EOF
=== HEALTH REPORT ===
Host:
$hn

Uptime:
$up

Charges (1/5/15) :
$load

IP locale(s) :
$iplocal
IP publique :
${pubip:-N/A}

CPU (résumé) :
$cpu

Température (si dispo) :
${temp:-N/A}

Mémoire :
$mem

Disques :
$disk

Top 10 processus par CPU :
$top

Mises à jour disponibles :
${pkgs:-N/A}

Généré le : $(date '+%F %T')
EOF
)"
  choose_destination "$REPORT"
}

# ---------- 2) CLEANUP SYSTEM ----------
cleanup_system(){
  need_root || return 1
  say "Nettoyage système : caches, journaux, /tmp (sélectif)."
  read -rp "Nettoyer cache paquets ? [Y/n] " a; a="${a:-Y}"
  read -rp "Nettoyer /tmp ? [y/N] " b; b="${b:-N}"
  read -rp "Purger journaux (journalctl) > 7 jours ? [y/N] " c; c="${c:-N}"
  read -rp "Docker prune (dangereux: supprime non utilisés) ? [y/N] " d; d="${d:-N}"

  if [[ "$a" =~ ^[Yy]$ ]]; then
    if is_deb && have apt-get; then
      apt-get -y autoremove --purge || true
      apt-get -y autoclean || true
      apt-get -y clean || true
      ok "Cache APT nettoyé."
    elif is_rhel && have dnf; then
      dnf -y autoremove || true
      dnf -y clean all || true
      ok "Cache DNF nettoyé."
    elif is_alpine && have apk; then
      rm -rf /var/cache/apk/* || true
      ok "Cache APK nettoyé."
    elif is_arch && have pacman; then
      pacman -Sc --noconfirm || true
      ok "Cache pacman nettoyé."
    else
      warn "Gestionnaire de paquets non détecté."
    fi
  fi

  if [[ "$b" =~ ^[Yy]$ ]]; then
    find /tmp -mindepth 1 -maxdepth 1 -mtime +1 -exec rm -rf {} + 2>/dev/null || true
    ok "/tmp nettoyé (fichiers > 24h)."
  fi

  if [[ "$c" =~ ^[Yy]$ ]]; then
    if have journalctl; then
      journalctl --vacuum-time=7d || true
      ok "journald purgé (>7j)."
    else
      warn "journalctl indisponible."
    fi
  fi

  if [[ "$d" =~ ^[Yy]$ ]]; then
    if have docker; then
      docker system prune -af --volumes || true
      ok "Docker prune effectué."
    else
      warn "Docker non installé."
    fi
  fi

  ok "Nettoyage terminé."
}

# ---------- 3) DOCKER UPDATE ----------
docker_update_all(){
  need_root || return 1
  if ! have docker; then err "Docker non installé."; return 1; fi
  say "Mise à jour des images Docker et redéploiement (compose si présent)…"
  # Pull images utilisées
  docker images --format '{{.Repository}}:{{.Tag}}' | while read -r IMG; do
    [ "$IMG" = "<none>:<none>" ] && continue
    echo "Pull: $IMG"; docker pull "$IMG" >/dev/null 2>&1 || true
  done
  # Redémarrer via compose si trouvé
  if have "docker compose"; then
    mapfile -t files < <(find / -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null || true)
    for f in "${files[@]:-}"; do
      d="$(dirname "$f")"; echo "Compose: $d"
      (cd "$d" && docker compose pull && docker compose up -d) >/dev/null 2>&1 || true
    done
  elif have docker-compose; then
    mapfile -t files < <(find / -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null || true)
    for f in "${files[@]:-}"; do
      d="$(dirname "$f")"; echo "Compose: $d"
      (cd "$d" && docker-compose pull && docker-compose up -d) >/dev/null 2>&1 || true
    done
  else
    warn "docker compose non trouvé, redéploiement limité."
  fi
  docker image prune -af >/dev/null 2>&1 || true
  ok "Docker à jour."
}

# ---------- 4) SSL EXPIRY CHECK ----------
ssl_expiry_check(){
  say "Vérification d'expiration SSL/TLS (OpenSSL requis)."
  [ -z "${1:-}" ] && read -rp "Domaines séparés par des espaces (ex: exemple.com www.ex.com) : " domains || domains="$*"
  [ -z "${domains:-}" ] && { warn "Aucun domaine saisi."; return 0; }
  local OUT="=== SSL EXPIRY ===
Date: $(date '+%F %T')"
  for d in $domains; do
    exp=$(echo | timeout 5 openssl s_client -servername "$d" -connect "$d:443" 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | sed 's/notAfter=//') || exp="N/A"
    OUT="$OUT
$d → ${exp:-N/A}"
  done
  choose_destination "$OUT"
}

# ---------- 5) DISK SPACE CHECK ----------
disk_space_check(){
  read -rp "Seuil d'alerte (en %, defaut 80) : " seuil
  seuil="${seuil:-80}"
  local ALERTS
  ALERTS="$(df -PTh -x tmpfs -x devtmpfs | awk -v s="$seuil" 'NR>1 {gsub("%","",$6); if ($6+0 >= s) print $0}')"
  if [ -z "$ALERTS" ]; then ok "Aucune partition >= ${seuil}%."; return 0; fi
  local MSG="=== DISK ALERT ($(hostname)) ===
Seuil: ${seuil}%
$(printf "%s\n" "$ALERTS")"
  choose_destination "$MSG"
}

# ---------- Menu ----------
show_menu(){
  echo -e "${C_BOLD}=== SYS TOOLBOX ($(hostname)) ===${C_RESET}
1) Health report
2) Cleanup system
3) Docker update images & compose
4) SSL expiry check (saisir domaines)
5) Disk space check (alerte ponctuelle)
6) Quitter"
}

main(){
  while true; do
    echo
    show_menu
    read -rp "Choix [1-6] : " ch
    case "${ch:-}" in
      1) health_report;;
      2) cleanup_system;;
      3) docker_update_all;;
      4) ssl_expiry_check;;
      5) disk_space_check;;
      6) ok "Bye!"; exit 0;;
      *) warn "Choix invalide.";;
    esac
  done
}

main "$@"
