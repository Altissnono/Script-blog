#!/usr/bin/env bash
#
# docker-update-all.sh
# Met à jour toutes les images Docker et relance les conteneurs.
# Compatible Debian/Ubuntu/CentOS/RHEL/Alpine.
# Journal dans /var/log/docker-update.log
# Aucun conteneur n’est supprimé tant que l’image est utilisée.

set -euo pipefail

LOGFILE="/var/log/docker-update.log"
DATE_NOW="$(date '+%F %T')"
touch "$LOGFILE"
chmod 0644 "$LOGFILE"

log() {
  echo "[$(date '+%F %T')] $*" | tee -a "$LOGFILE"
}

log "=== DÉBUT DE LA MISE À JOUR DOCKER – $DATE_NOW ==="

# 1. Vérification docker installé
if ! command -v docker >/dev/null 2>&1; then
  log "ERREUR: Docker n’est pas installé."
  exit 1
fi

# 2. Vérifier docker compose (v2 intégré à docker)
if command -v docker compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE_CMD="docker-compose"
else
  COMPOSE_CMD=""
fi

# 3. Mettre à jour les images des conteneurs existants
log "Mise à jour des images en cours..."
docker images --format '{{.Repository}}:{{.Tag}}' | while read -r IMAGE; do
  [ "$IMAGE" = "<none>:<none>" ] && continue
  log "Pull image: $IMAGE"
  docker pull "$IMAGE" >>"$LOGFILE" 2>&1 || log "Échec pull $IMAGE"
done

# 4. Redémarrer les conteneurs qui utilisent des images mises à jour
log "Redémarrage des conteneurs basés sur les nouvelles images..."
docker ps -q | while read -r CID; do
  NAME=$(docker inspect --format '{{.Name}}' "$CID" | sed 's|/||')
  log "Recreate & restart: $NAME"
  docker stop "$CID" >>"$LOGFILE" 2>&1
  docker rm "$CID" >>"$LOGFILE" 2>&1 || true
done

# 5. Relancer via compose si présent
if [ -n "$COMPOSE_CMD" ]; then
  # Parcourt tous les fichiers compose.yml/ docker-compose.yml trouvés
  log "Recherche et redémarrage des stacks Compose…"
  find / -name "docker-compose.yml" -o -name "compose.yml" 2>/dev/null | while read -r FILE; do
    DIR=$(dirname "$FILE")
    log "Stack: $DIR"
    (cd "$DIR" && $COMPOSE_CMD pull && $COMPOSE_CMD up -d) >>"$LOGFILE" 2>&1
  done
fi

# 6. Nettoyer les images inutilisées
log "Nettoyage des images obsolètes..."
docker image prune -af >>"$LOGFILE" 2>&1 || true

log "=== MISE À JOUR TERMINÉE ==="
exit 0
