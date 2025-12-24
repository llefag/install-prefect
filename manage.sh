#!/usr/bin/env bash
# Prefect Worker Manager v2.1 (Hardened)
# Script de maintenance interactif pour les workers Prefect
#
# Usage: sudo ./manage.sh
#
set -euo pipefail

# Sécurité : umask restrictif
umask 077

VERSION="2.1.0"
PREFIX="prefect-worker-"
META_DIR="/etc/prefect-workers.d"
LOG_FILE="/var/log/prefect-install.log"

# Couleurs (désactivées si pas de tty)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' NC=''
fi

# -------------------- Logging --------------------

log_to_file() {
  local level="$1"
  shift
  echo "[$(date -Iseconds)] [$level] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info()    { echo -e "${BLUE}ℹ${NC} $*"; log_to_file "INFO" "$*"; }
log_success() { echo -e "${GREEN}✓${NC} $*"; log_to_file "SUCCESS" "$*"; }
log_warning() { echo -e "${YELLOW}⚠${NC} $*"; log_to_file "WARNING" "$*"; }
log_error()   { echo -e "${RED}✗${NC} $*" >&2; log_to_file "ERROR" "$*"; }

# -------------------- Validations --------------------

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    log_error "Ce script doit être exécuté en tant que root"
    log_info "Usage: sudo ./manage.sh"
    exit 1
  }
}

need_systemd() {
  command -v systemctl >/dev/null || {
    log_error "systemd/systemctl est requis"
    exit 1
  }
}

# Validation stricte des noms (anti-injection)
sanitize_name() {
  local n="$1"
  if [[ ! "$n" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,63}$ ]]; then
    log_error "Nom invalide: doit commencer par une lettre, max 64 chars, [a-zA-Z0-9._-]"
    return 1
  fi
  if [[ "$n" =~ \.\.|-- ]]; then
    log_error "Nom invalide: séquences '..' ou '--' interdites"
    return 1
  fi
  return 0
}

confirm() {
  local prompt="${1:-Confirmer ?}"
  local response
  read -rp "$prompt (y/N) : " response
  response="${response,,}"
  [[ "$response" == "y" || "$response" == "yes" ]]
}

# Lecture sécurisée des métadonnées (pas de source direct)
read_meta_file() {
  local meta_file="$1"
  local -n result_ref="$2"
  
  [ -f "$meta_file" ] || return 1
  
  while IFS='=' read -r key value || [ -n "$key" ]; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    # Nettoyer
    key="${key%%[[:space:]]}"
    value="${value##[[:space:]]}"
    value="${value%%[[:space:]]}"
    # Valider la clé
    [[ "$key" =~ ^[A-Z_]+$ ]] || continue
    # Stocker
    result_ref["$key"]="$value"
  done < "$meta_file"
  
  return 0
}

# -------------------- Listing --------------------

list_workers() {
  echo
  echo -e "${CYAN}🧾 Workers détectés (services systemd)${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  local units
  units="$(systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -E "^${PREFIX}.*\.service$" || true)"
  if [ -z "$units" ]; then
    echo "(aucun worker installé)"
    return 0
  fi
  printf "%-45s %-10s %-10s\n" "SERVICE" "ACTIF" "ENABLED"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  while read -r u; do
    [ -z "$u" ] && continue
    local a e
    a="$(systemctl is-active "$u" 2>/dev/null || echo 'unknown')"
    e="$(systemctl is-enabled "$u" 2>/dev/null || echo 'unknown')"
    
    local a_color="$RED"
    [[ "$a" == "active" ]] && a_color="$GREEN"
    
    printf "• %-43s ${a_color}%-10s${NC} %-10s\n" "$u" "$a" "$e"
  done <<< "$units"
}

show_worker_details() {
  echo
  read -rp "Nom du worker (sans préfixe prefect-worker-) : " NAME
  sanitize_name "$NAME" || return 1
  
  local SERVICE="${PREFIX}${NAME}"
  local META="${META_DIR}/${SERVICE}.conf"
  
  if ! systemctl list-unit-files --type=service 2>/dev/null | grep -q "^${SERVICE}.service"; then
    log_error "Worker introuvable: ${SERVICE}"
    return 1
  fi
  
  echo
  echo -e "${CYAN}📋 Détails du worker: ${NAME}${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  
  if [ -f "$META" ]; then
    echo "Métadonnées:"
    # Lecture sécurisée sans source
    while IFS='=' read -r key value || [ -n "$key" ]; do
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
      # Ne pas afficher les chemins complets des fichiers sensibles
      [[ "$key" == "ENV_FILE" ]] && value="[masqué]"
      echo "  $key=$value"
    done < "$META"
    echo
  fi
  
  echo "Status systemd:"
  systemctl status "${SERVICE}.service" --no-pager 2>/dev/null | head -15 | sed 's/^/  /'
}

# -------------------- Worker lifecycle --------------------

upgrade_prefect() {
  echo
  echo -e "${CYAN}⬆️ Upgrade Prefect${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  list_workers
  echo
  read -rp "Upgrade (one/all) ? : " MODE
  MODE="${MODE,,}"

  local -a units=()
  local -A meta_data=()
  
  if [[ "$MODE" == "all" ]]; then
    local metas
    metas="$(find "$META_DIR" -maxdepth 1 -name '*.conf' -type f 2>/dev/null || true)"
    [ -z "$metas" ] && { echo "(aucun worker)"; return 0; }
    for m in $metas; do
      meta_data=()
      read_meta_file "$m" meta_data || continue
      [ -n "${meta_data[SERVICE_NAME]:-}" ] && units+=("${meta_data[SERVICE_NAME]}.service")
    done
  else
    read -rp "Nom du worker : " NAME
    sanitize_name "$NAME" || return 1
    local meta="${META_DIR}/${PREFIX}${NAME}.conf"
    [ -f "$meta" ] || { log_error "Métadonnées introuvables: $meta"; return 1; }
    read_meta_file "$meta" meta_data || { log_error "Erreur lecture métadonnées"; return 1; }
    units+=("${meta_data[SERVICE_NAME]}.service")
  fi

  for u in "${units[@]}"; do
    local base="${u%.service}"
    local meta="${META_DIR}/${base}.conf"
    [ -f "$meta" ] || { log_warning "meta manquant pour $u"; continue; }
    
    meta_data=()
    read_meta_file "$meta" meta_data || continue
    
    local install_dir="${meta_data[INSTALL_DIR]:-}"
    local prefect_user="${meta_data[PREFECT_USER]:-prefect}"
    
    [ -z "$install_dir" ] && { log_warning "INSTALL_DIR manquant pour $u"; continue; }
    [ -d "$install_dir" ] || { log_warning "Dossier inexistant: $install_dir"; continue; }

    echo
    log_info "Upgrade pour $u (dir=$install_dir user=$prefect_user)"
    log_to_file "AUDIT" "Upgrade démarré: $u"
    
    systemctl stop "$u" || true
    
    local venv_script="set -e; source '$install_dir/venv/bin/activate'; pip install --upgrade pip --quiet --timeout 60; pip install --upgrade prefect --quiet --timeout 120"
    
    if timeout 300 sudo -u "$prefect_user" bash -c "$venv_script"; then
      systemctl start "$u"
      if systemctl is-active "$u" >/dev/null 2>&1; then
        log_success "$u relancé"
        log_to_file "AUDIT" "Upgrade réussi: $u"
      else
        log_error "$u n'a pas démarré correctement"
        log_to_file "AUDIT" "Upgrade échoué au démarrage: $u"
      fi
    else
      log_error "Échec upgrade pip/prefect pour $u"
      log_to_file "AUDIT" "Upgrade échoué: $u"
      systemctl start "$u" || true
    fi
  done
}

rename_worker() {
  echo
  echo -e "${CYAN}🏷️ Renommer un worker${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  list_workers
  echo
  read -rp "Nom ACTUEL du worker : " OLD
  sanitize_name "$OLD" || return 1
  read -rp "NOUVEAU nom du worker : " NEW
  sanitize_name "$NEW" || return 1

  local OLD_SVC="${PREFIX}${OLD}"
  local NEW_SVC="${PREFIX}${NEW}"

  local OLD_UNIT="/etc/systemd/system/${OLD_SVC}.service"
  local NEW_UNIT="/etc/systemd/system/${NEW_SVC}.service"
  local OLD_ENV="/etc/${OLD_SVC}.env"
  local NEW_ENV="/etc/${NEW_SVC}.env"
  local OLD_META="${META_DIR}/${OLD_SVC}.conf"
  local NEW_META="${META_DIR}/${NEW_SVC}.conf"

  [ -f "$OLD_UNIT" ] || { log_error "Service introuvable: ${OLD_SVC}.service"; return 1; }
  [ ! -f "$NEW_UNIT" ] || { log_error "Le nouveau service existe déjà: ${NEW_SVC}.service"; return 1; }

  echo
  echo "Récap: ${OLD} → ${NEW}"
  confirm "Confirmer le renommage ?" || { log_warning "Annulé"; return 0; }

  log_to_file "AUDIT" "Renommage démarré: $OLD -> $NEW"

  systemctl stop "${OLD_SVC}.service" || true
  systemctl disable "${OLD_SVC}.service" || true

  mv "$OLD_UNIT" "$NEW_UNIT"
  [ -f "$OLD_ENV" ] && mv "$OLD_ENV" "$NEW_ENV"
  [ -f "$OLD_META" ] && mv "$OLD_META" "$NEW_META"

  # Maj des références avec sed sécurisé
  sed -i "s/--name ${OLD}/--name ${NEW}/g" "$NEW_UNIT"
  [ -f "$NEW_META" ] && {
    sed -i "s/^SERVICE_NAME=.*/SERVICE_NAME=${NEW_SVC}/" "$NEW_META"
    sed -i "s/^WORKER_NAME=.*/WORKER_NAME=${NEW}/" "$NEW_META"
  }

  systemctl daemon-reload
  systemctl enable "${NEW_SVC}.service"
  systemctl start "${NEW_SVC}.service"
  sleep 1

  if systemctl is-active "${NEW_SVC}.service" >/dev/null 2>&1; then
    log_success "Renommé et relancé"
    log_to_file "AUDIT" "Renommage réussi: $OLD -> $NEW"
  else
    log_error "Le service n'a pas démarré correctement"
    log_to_file "AUDIT" "Renommage échoué au démarrage: $OLD -> $NEW"
  fi
  
  journalctl -u "${NEW_SVC}.service" -n 10 --no-pager
}

remove_worker() {
  echo
  echo -e "${CYAN}🗑️ Supprimer un worker${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  list_workers
  echo
  read -rp "Nom du worker à supprimer : " NAME
  sanitize_name "$NAME" || return 1

  local SVC="${PREFIX}${NAME}"
  local UNIT="/etc/systemd/system/${SVC}.service"
  local ENV="/etc/${SVC}.env"
  local META="${META_DIR}/${SVC}.conf"

  [ -f "$UNIT" ] || { log_error "Service introuvable: ${SVC}.service"; return 1; }

  # Lecture sécurisée du répertoire
  local DIR=""
  if [ -f "$META" ]; then
    local -A meta_data=()
    read_meta_file "$META" meta_data
    DIR="${meta_data[INSTALL_DIR]:-}"
  fi

  echo "Cible: ${SVC}.service"
  confirm "Confirmer suppression ?" || { log_warning "Annulé"; return 0; }

  log_to_file "AUDIT" "Suppression démarrée: $SVC"

  systemctl stop "${SVC}.service" || true
  systemctl disable "${SVC}.service" || true

  rm -f "$UNIT" "$ENV" "$META"
  systemctl daemon-reload
  systemctl reset-failed "${SVC}.service" 2>/dev/null || true

  if [ -n "$DIR" ] && [ -d "$DIR" ]; then
    # Vérification de sécurité supplémentaire
    if [[ "$DIR" == /opt/prefect/* || "$DIR" == /srv/prefect/* || "$DIR" == /var/lib/prefect/* ]]; then
      confirm "Supprimer aussi le dossier d'installation ($DIR) ?" && rm -rf "$DIR"
    else
      log_warning "Dossier non supprimé automatiquement (chemin non standard): $DIR"
    fi
  fi

  log_success "Worker supprimé"
  log_to_file "AUDIT" "Suppression terminée: $SVC"
}

remove_all_workers() {
  echo
  echo -e "${CYAN}🧹 Supprimer TOUS les workers${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  list_workers
  echo
  confirm "Confirmer suppression de TOUS les ${PREFIX}*.service ?" || { log_warning "Annulé"; return 0; }

  log_to_file "AUDIT" "Suppression de tous les workers démarrée"

  local units
  units="$(systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -E "^${PREFIX}.*\.service$" || true)"
  [ -z "$units" ] && { echo "(aucun)"; return 0; }

  while read -r u; do
    [ -z "$u" ] && continue
    local base="${u%.service}"
    systemctl stop "$u" || true
    systemctl disable "$u" || true
    rm -f "/etc/systemd/system/${u}" || true
    rm -f "/etc/${base}.env" || true
    rm -f "${META_DIR}/${base}.conf" || true
  done <<< "$units"

  systemctl daemon-reload
  log_success "Tous les workers supprimés (services + env + meta)"
  log_info "Les dossiers d'installation ne sont pas supprimés automatiquement."
  log_to_file "AUDIT" "Tous les workers supprimés"
}

uninstall_prefect() {
  echo
  echo -e "${CYAN}💣 Désinstaller Prefect (clean)${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "Cela va:"
  echo " - supprimer tous les workers"
  echo " - supprimer $META_DIR"
  echo " - (optionnel) supprimer l'utilisateur 'prefect' et /opt/prefect"
  echo
  confirm "Continuer ?" || { log_warning "Annulé"; return 0; }

  log_to_file "AUDIT" "Désinstallation complète démarrée"

  remove_all_workers
  rm -rf "$META_DIR" || true

  if confirm "Supprimer l'utilisateur système 'prefect' s'il existe ?" ; then
    if id prefect >/dev/null 2>&1; then
      if confirm "Supprimer /opt/prefect (si existe) ?" ; then
        rm -rf /opt/prefect || true
      fi
      userdel prefect || true
      log_success "Utilisateur 'prefect' supprimé"
    else
      log_info "Utilisateur 'prefect' absent"
    fi
  fi

  log_success "Désinstallation terminée"
  log_to_file "AUDIT" "Désinstallation complète terminée"
}

# -------------------- Help / Audit --------------------

show_logs() {
  echo
  read -rp "Nom du worker : " NAME
  sanitize_name "$NAME" || return 1
  
  local SERVICE="${PREFIX}${NAME}"
  echo
  log_info "Logs de ${SERVICE}.service (50 dernières lignes):"
  echo
  journalctl -u "${SERVICE}.service" -n 50 --no-pager
  echo
  confirm "Voir les logs en temps réel ?" && journalctl -u "${SERVICE}.service" -f
}

show_audit_logs() {
  echo
  echo -e "${CYAN}📜 Logs d'audit${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [ -f "$LOG_FILE" ]; then
    tail -50 "$LOG_FILE"
  else
    echo "(aucun log d'audit)"
  fi
}

help_audit() {
  echo
  echo -e "${CYAN}🧪 Aide / Audit systemd et worker${NC}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  cat <<'EOF'

Lister les workers :
  systemctl list-unit-files | grep '^prefect-worker-'
  systemctl status prefect-worker-<name>

Voir les logs :
  journalctl -u prefect-worker-<name> -n 200 --no-pager
  journalctl -u prefect-worker-<name> -f

Voir le hardening systemd :
  systemd-analyze security prefect-worker-<name>

Voir les propriétés runtime du service :
  systemctl show prefect-worker-<name> | head -50
  systemctl show -p User,Group,ExecStart,EnvironmentFiles prefect-worker-<name>

Tester le CLI Prefect dans le venv du worker :
  sudo -u prefect bash -c 'source /opt/prefect/<name>/venv/bin/activate && prefect version'

Récupérer la configuration Prefect du service :
  sudo cat /etc/prefect-worker-<name>.env
  sudo cat /etc/systemd/system/prefect-worker-<name>.service

Reset un service qui crash-loop :
  sudo systemctl reset-failed prefect-worker-<name>
  sudo systemctl restart prefect-worker-<name>

Logs d'audit :
  sudo cat /var/log/prefect-install.log

EOF
}

# -------------------- Menu --------------------

menu() {
  echo
  echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
  echo -e "${CYAN}║   Prefect Worker Manager v${VERSION}      ║${NC}"
  echo -e "${CYAN}║            (Hardened)                  ║${NC}"
  echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
  echo
  echo "  1) Lister les workers"
  echo "  2) Détails d'un worker"
  echo "  3) Voir les logs d'un worker"
  echo "  4) Renommer un worker"
  echo "  5) Upgrade Prefect (un ou tous)"
  echo "  6) Supprimer un worker"
  echo "  7) Supprimer tous les workers"
  echo "  8) Désinstaller Prefect (clean)"
  echo "  9) Aide / Audit (commandes utiles)"
  echo " 10) Voir les logs d'audit"
  echo "  0) Quitter"
  echo
  read -rp "Choix : " CH
  case "$CH" in
    1) list_workers ;;
    2) show_worker_details ;;
    3) show_logs ;;
    4) rename_worker ;;
    5) upgrade_prefect ;;
    6) remove_worker ;;
    7) remove_all_workers ;;
    8) uninstall_prefect ;;
    9) help_audit ;;
    10) show_audit_logs ;;
    0) exit 0 ;;
    *) log_error "Choix invalide" ;;
  esac
}

main() {
  need_root
  need_systemd
  
  # Créer/vérifier le fichier de log
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  
  mkdir -p "$META_DIR"
  chmod 755 "$META_DIR"
  
  log_to_file "AUDIT" "=== Session manage.sh démarrée par $(whoami) ==="
  
  while true; do
    menu
  done
}

main
