#!/usr/bin/env bash
# Prefect Worker Installer v2.1 (Hardened)
# Lit les secrets depuis stdin et installe un worker Prefect comme service systemd
#
# Usage:
#   cat secrets.txt | sudo ./install.sh [OPTIONS]
#   echo "PREFECT_API_URL=...
#   PREFECT_API_KEY=...
#   WORK_POOL=..." | sudo ./install.sh [OPTIONS]
#
set -euo pipefail

# Sécurité : umask restrictif
umask 077

VERSION="2.1.0"
PREFIX="prefect-worker-"
META_DIR="/etc/prefect-workers.d"
LOG_FILE="/var/log/prefect-install.log"

# Configuration (peut être surchargée par stdin ou arguments)
PREFECT_API_URL=""
PREFECT_API_KEY=""
WORK_POOL=""
WORKER_NAME=""
PREFECT_USER="prefect"
INSTALL_DIR=""
AUTO_INSTALL_DEPS="true"

# Couleurs (désactivées si pas de tty)
if [ -t 1 ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' NC=''
fi

# -------------------- Logging --------------------

log_to_file() {
  local level="$1"
  shift
  echo "[$(date -Iseconds)] [$level] $*" >> "$LOG_FILE" 2>/dev/null || true
}

log_info() {
  echo -e "${BLUE}ℹ${NC} $*"
  log_to_file "INFO" "$*"
}

log_success() {
  echo -e "${GREEN}✓${NC} $*"
  log_to_file "SUCCESS" "$*"
}

log_warning() {
  echo -e "${YELLOW}⚠${NC} $*"
  log_to_file "WARNING" "$*"
}

log_error() {
  echo -e "${RED}✗${NC} $*" >&2
  log_to_file "ERROR" "$*"
}

show_usage() {
  cat <<EOF
Prefect Worker Installer v${VERSION} (Hardened)

Installation automatique d'un worker Prefect comme service systemd.
Les secrets sont lus depuis stdin (format KEY=VALUE).

USAGE:
  cat secrets.txt | sudo ./install.sh [OPTIONS]
  echo "PREFECT_API_URL=...
  PREFECT_API_KEY=...
  WORK_POOL=..." | sudo ./install.sh [OPTIONS]

SECRETS REQUIS (via stdin):
  PREFECT_API_URL    URL complète de l'API Prefect
  PREFECT_API_KEY    Clé API Prefect (commence par pnu_)
  WORK_POOL          Nom du work pool existant

SECRETS OPTIONNELS (via stdin):
  WORKER_NAME        Nom du worker [auto: hostname-timestamp]
  PREFECT_USER       Utilisateur système [prefect]
  INSTALL_DIR        Dossier d'installation [/opt/prefect/<worker-name>]

OPTIONS (arguments CLI):
  --worker-name NAME     Surcharge le nom du worker
  --user USER            Surcharge l'utilisateur système
  --install-dir DIR      Surcharge le dossier d'installation
  --no-auto-deps         Ne pas installer automatiquement les dépendances
  -h, --help             Afficher cette aide
  -v, --version          Afficher la version

SÉCURITÉ:
  - Secrets via stdin uniquement (non visibles dans ps)
  - Fichiers sensibles en mode 600
  - Hardening systemd complet
  - Logs d'audit dans $LOG_FILE

EOF
}

# -------------------- Sécurité --------------------

# Nettoie une valeur de façon sécurisée (sans xargs)
safe_trim() {
  local var="$1"
  # Supprime espaces/tabs en début et fin
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  printf '%s' "$var"
}

# Valide qu'une chaîne ne contient pas de caractères dangereux
validate_safe_string() {
  local str="$1"
  local name="$2"
  # Rejette les caractères de contrôle, backticks, $, etc.
  if [[ "$str" =~ [\`\$\(\)\{\}\;\&\|\<\>\\] ]]; then
    log_error "Caractères dangereux détectés dans $name"
    return 1
  fi
  return 0
}

# -------------------- Parsing --------------------

parse_stdin() {
  # Lire stdin si des données sont disponibles (pipe)
  if [ -t 0 ]; then
    return 0
  fi
  
  while IFS= read -r line || [ -n "$line" ]; do
    # Ignorer les lignes vides et les commentaires
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    
    # Séparer clé=valeur de façon sécurisée
    local key="${line%%=*}"
    local value="${line#*=}"
    
    # Nettoyer sans xargs (plus sûr)
    key="$(safe_trim "$key")"
    value="$(safe_trim "$value")"
    
    # Valider la valeur
    validate_safe_string "$value" "$key" || continue
    
    case "$key" in
      PREFECT_API_URL) PREFECT_API_URL="$value" ;;
      PREFECT_API_KEY) PREFECT_API_KEY="$value" ;;
      WORK_POOL)       WORK_POOL="$value" ;;
      WORKER_NAME)     [ -z "$WORKER_NAME" ] && WORKER_NAME="$value" ;;
      PREFECT_USER)    PREFECT_USER="$value" ;;
      INSTALL_DIR)     [ -z "$INSTALL_DIR" ] && INSTALL_DIR="$value" ;;
    esac
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case $1 in
      --worker-name)
        [ -n "${2:-}" ] || { log_error "--worker-name requiert une valeur"; exit 1; }
        WORKER_NAME="$2"
        shift 2
        ;;
      --user)
        [ -n "${2:-}" ] || { log_error "--user requiert une valeur"; exit 1; }
        PREFECT_USER="$2"
        shift 2
        ;;
      --install-dir)
        [ -n "${2:-}" ] || { log_error "--install-dir requiert une valeur"; exit 1; }
        INSTALL_DIR="$2"
        shift 2
        ;;
      --no-auto-deps)
        AUTO_INSTALL_DEPS="false"
        shift
        ;;
      -h|--help)
        show_usage
        exit 0
        ;;
      -v|--version)
        echo "Prefect Worker Installer v${VERSION}"
        exit 0
        ;;
      *)
        log_error "Option inconnue: $1"
        show_usage
        exit 1
        ;;
    esac
  done
}

# -------------------- Validations --------------------

need_root() {
  [ "$(id -u)" -eq 0 ] || {
    log_error "Ce script doit être exécuté en tant que root"
    log_info "Usage: cat secrets.txt | sudo ./install.sh"
    exit 1
  }
}

need_systemd() {
  command -v systemctl >/dev/null || {
    log_error "systemd/systemctl est requis mais non trouvé"
    exit 1
  }
}

# Validation stricte des noms (anti-injection)
sanitize_name() {
  local n="$1"
  # Doit commencer par une lettre, max 64 chars
  if [[ ! "$n" =~ ^[a-zA-Z][a-zA-Z0-9._-]{0,63}$ ]]; then
    log_error "Nom invalide '$n': doit commencer par une lettre, max 64 chars, [a-zA-Z0-9._-]"
    return 1
  fi
  # Pas de double points ou tirets (path traversal)
  if [[ "$n" =~ \.\.|-- ]]; then
    log_error "Nom invalide '$n': séquences '..' ou '--' interdites"
    return 1
  fi
  return 0
}

# Validation du chemin d'installation
validate_install_dir() {
  local dir="$1"
  
  # Doit être un chemin absolu
  [[ "$dir" == /* ]] || {
    log_error "INSTALL_DIR doit être un chemin absolu: $dir"
    return 1
  }
  
  # Chemins interdits
  local forbidden_paths=("/home" "/root" "/tmp" "/var/tmp" "/etc" "/usr" "/bin" "/sbin" "/lib")
  for fp in "${forbidden_paths[@]}"; do
    if [[ "$dir" == "$fp" || "$dir" == "$fp"/* ]]; then
      # Exception pour /var/lib/prefect
      [[ "$dir" == /var/lib/prefect* ]] && continue
      log_error "Chemin interdit pour INSTALL_DIR: $dir"
      log_info "Utilisez /opt/prefect/<name>, /srv/prefect/<name> ou /var/lib/prefect/<name>"
      return 1
    fi
  done
  
  # Pas de path traversal
  if [[ "$dir" =~ \.\. ]]; then
    log_error "Path traversal interdit dans INSTALL_DIR: $dir"
    return 1
  fi
  
  return 0
}

# Validation de l'URL API
validate_api_url() {
  local url="$1"
  # Doit être HTTPS (sauf localhost pour dev)
  if [[ ! "$url" =~ ^https:// && ! "$url" =~ ^http://localhost && ! "$url" =~ ^http://127\.0\.0\.1 ]]; then
    log_error "PREFECT_API_URL doit utiliser HTTPS: $url"
    return 1
  fi
  return 0
}

# Validation de la clé API
validate_api_key() {
  local key="$1"
  # Doit commencer par pnu_ ou pnb_ (Prefect Cloud) ou être vide pour self-hosted sans auth
  if [[ -n "$key" && ! "$key" =~ ^pn[ub]_[a-zA-Z0-9]{20,}$ ]]; then
    log_warning "Format de clé API inhabituel (attendu: pnu_xxx ou pnb_xxx)"
  fi
  return 0
}

generate_worker_name() {
  if [ -n "$WORKER_NAME" ]; then
    echo "$WORKER_NAME"
    return 0
  fi
  local hostname_short
  hostname_short="$(hostname -s 2>/dev/null || echo 'worker')"
  # Sanitize hostname
  hostname_short="${hostname_short//[^a-zA-Z0-9-]/-}"
  local timestamp
  timestamp="$(date +%s | tail -c 6)"
  echo "${hostname_short}-${timestamp}"
}

validate_inputs() {
  [ -n "$PREFECT_API_URL" ] || {
    log_error "PREFECT_API_URL est requis (manquant dans stdin)"
    exit 1
  }
  validate_api_url "$PREFECT_API_URL" || exit 1
  
  [ -n "$PREFECT_API_KEY" ] || {
    log_error "PREFECT_API_KEY est requis (manquant dans stdin)"
    exit 1
  }
  validate_api_key "$PREFECT_API_KEY"
  
  [ -n "$WORK_POOL" ] || {
    log_error "WORK_POOL est requis (manquant dans stdin)"
    exit 1
  }
  sanitize_name "$WORK_POOL" || exit 1
  
  # Valider utilisateur système
  sanitize_name "$PREFECT_USER" || exit 1
  
  WORKER_NAME="$(generate_worker_name)"
  sanitize_name "$WORKER_NAME" || exit 1
  
  if [ -z "$INSTALL_DIR" ]; then
    INSTALL_DIR="/opt/prefect/${WORKER_NAME}"
  fi
  validate_install_dir "$INSTALL_DIR" || exit 1
  
  log_to_file "AUDIT" "Installation validée: worker=$WORKER_NAME pool=$WORK_POOL user=$PREFECT_USER dir=$INSTALL_DIR"
}

# -------------------- Installation --------------------

detect_pm() {
  if command -v apt-get >/dev/null 2>&1; then echo "apt"
  elif command -v dnf >/dev/null 2>&1; then echo "dnf"
  elif command -v yum >/dev/null 2>&1; then echo "yum"
  else echo "none"
  fi
}

install_deps() {
  if [ "$AUTO_INSTALL_DEPS" != "true" ]; then
    log_info "Installation automatique des dépendances désactivée"
    return 0
  fi

  local pm
  pm="$(detect_pm)"
  if [ "$pm" = "none" ]; then
    log_warning "Gestionnaire de paquets non détecté (apt/dnf/yum)"
    log_info "Assurez-vous d'avoir: python3, python3-venv, curl, jq"
    return 0
  fi

  log_info "Installation des dépendances système..."
  if [ "$pm" = "apt" ]; then
    apt-get update -y >/dev/null 2>&1
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      python3 python3-venv python3-pip python3-full curl jq >/dev/null 2>&1
  elif [ "$pm" = "dnf" ]; then
    dnf install -y python3 python3-venv curl jq >/dev/null 2>&1
  else
    yum install -y python3 python3-venv curl jq >/dev/null 2>&1
  fi
  log_success "Dépendances installées"
}

hardening_block() {
  cat <<'EOF'
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
ProtectHostname=true
ProtectClock=true
ProtectProc=invisible
ProcSubset=pid
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictNamespaces=true
RestrictSUIDSGID=true
RestrictRealtime=true
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
SystemCallArchitectures=native
SystemCallFilter=@system-service
SystemCallFilter=~@privileged @resources
CapabilityBoundingSet=
AmbientCapabilities=
UMask=077
StandardOutput=journal
StandardError=journal
EOF
}

create_user_if_needed() {
  local user="$1"
  local home="$2"
  if ! id "$user" >/dev/null 2>&1; then
    log_info "Création de l'utilisateur système: $user"
    # Shell nologin pour sécurité (le service n'a pas besoin de shell interactif)
    useradd --system --create-home --home-dir "$home" --shell /usr/sbin/nologin "$user"
    log_to_file "AUDIT" "Utilisateur créé: $user (nologin shell)"
  fi
}

write_env_file() {
  local env_file="$1"
  local api_url="$2"
  local api_key="$3"
  # PREFECT_HOME n'est PAS mis dans le fichier env : il est défini uniquement
  # dans le unit systemd. Ainsi le worker a PREFECT_HOME sur l'hôte, mais
  # les jobs Docker (ex. lxboard-etl) ne le reçoivent pas et utilisent
  # celui défini dans les job_variables du déploiement (/app/.prefect).
  # Évite "Failed to create the Prefect home directory" + "Unable to authenticate to the event stream".
  install -m 600 -o root -g root /dev/null "$env_file"
  cat > "$env_file" <<EOF
PREFECT_API_URL=$api_url
PREFECT_API_KEY=$api_key
PREFECT_LOGGING_LEVEL=INFO
EOF
  log_to_file "AUDIT" "Fichier env créé: $env_file (mode 600)"
}

install_worker() {
  log_info "Installation du worker Prefect..."
  log_info "  Worker name  : ${WORKER_NAME}"
  log_info "  Work pool    : ${WORK_POOL}"
  log_info "  User         : ${PREFECT_USER}"
  log_info "  Install dir  : ${INSTALL_DIR}"
  
  local SERVICE="${PREFIX}${WORKER_NAME}"
  local UNIT="/etc/systemd/system/${SERVICE}.service"
  local ENV="/etc/${SERVICE}.env"
  local META="${META_DIR}/${SERVICE}.conf"
  local PREFECT_HOME="${INSTALL_DIR}/.prefect"
  
  # Vérifier si le service existe déjà
  if [ -f "$UNIT" ] || systemctl list-unit-files --type=service 2>/dev/null | awk '{print $1}' | grep -qx "${SERVICE}.service"; then
    log_error "Ce worker existe déjà: ${SERVICE}.service"
    log_info "Utilisez ./manage.sh pour gérer les workers existants"
    exit 1
  fi
  
  # Créer les répertoires avec permissions appropriées
  install -d -m 755 "$META_DIR"
  install -d -m 750 "$INSTALL_DIR"
  install -d -m 700 "$PREFECT_HOME"
  
  create_user_if_needed "$PREFECT_USER" "$INSTALL_DIR"
  chown -R "$PREFECT_USER:$PREFECT_USER" "$INSTALL_DIR"
  
  if command -v docker >/dev/null 2>&1; then
    log_info "Docker détecté → ajout de $PREFECT_USER au groupe docker"
    usermod -aG docker "$PREFECT_USER" 2>/dev/null || true
  fi
  
  log_info "Création de l'environnement virtuel Python..."
  # Utiliser env -i pour environnement propre, timeout pour éviter blocage
  local venv_script
  venv_script=$(cat <<'EOFSCRIPT'
set -e
python3 -m venv "$1/venv"
source "$1/venv/bin/activate"
pip install --upgrade pip --quiet --timeout 60
pip install --upgrade prefect prefect-docker --quiet --timeout 120
EOFSCRIPT
)
  
  if ! timeout 300 sudo -u "$PREFECT_USER" bash -c "$venv_script" -- "$INSTALL_DIR"; then
    log_error "Échec de la création du venv ou de l'installation de Prefect"
    exit 1
  fi
  
  log_info "Configuration du fichier d'environnement..."
  write_env_file "$ENV" "$PREFECT_API_URL" "$PREFECT_API_KEY"
  
  # Paths d'écriture requis avec ProtectSystem=strict
  local RW="ReadWritePaths=${INSTALL_DIR}"
  [ -S /var/run/docker.sock ] && RW="${RW} /var/run/docker.sock"
  [ -S /run/docker.sock ] && RW="${RW} /run/docker.sock"
  [ -d /run/docker ] && RW="${RW} /run/docker"
  
  log_info "Création du service systemd..."
  {
    cat <<EOF
[Unit]
Description=Prefect Worker (${WORKER_NAME})
After=network-online.target
Wants=network-online.target
Documentation=https://docs.prefect.io/

[Service]
Type=simple
User=${PREFECT_USER}
Group=${PREFECT_USER}
EnvironmentFile=${ENV}
Environment=PREFECT_HOME=${PREFECT_HOME}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/venv/bin/prefect worker start -p ${WORK_POOL} --name ${WORKER_NAME}
Restart=always
RestartSec=10
TimeoutStartSec=120
TimeoutStopSec=60
${RW}

# --- Hardening ---
EOF
    hardening_block
    cat <<EOF

[Install]
WantedBy=multi-user.target
EOF
  } > "$UNIT"
  chmod 644 "$UNIT"
  
  log_info "Enregistrement des métadonnées..."
  # Métadonnées en 600 (contient des infos sensibles sur la config)
  install -m 600 -o root -g root /dev/null "$META"
  cat > "$META" <<EOF
SERVICE_NAME=${SERVICE}
WORKER_NAME=${WORKER_NAME}
WORK_POOL=${WORK_POOL}
PREFECT_USER=${PREFECT_USER}
INSTALL_DIR=${INSTALL_DIR}
ENV_FILE=${ENV}
UNIT_FILE=${UNIT}
PREFECT_HOME=${PREFECT_HOME}
CREATED_AT=$(date -Iseconds)
INSTALLER_VERSION=${VERSION}
EOF
  
  log_info "Activation et démarrage du service..."
  systemctl daemon-reload
  systemctl enable "${SERVICE}.service"
  systemctl restart "${SERVICE}.service"
  sleep 2
  
  log_to_file "AUDIT" "Worker installé: $SERVICE"
  
  log_success "Worker installé avec succès!"
  echo
  echo "📋 Informations du service:"
  echo "  Service      : ${SERVICE}.service"
  echo "  Status       : $(systemctl is-active "${SERVICE}.service" 2>/dev/null || echo 'unknown')"
  echo "  Enabled      : $(systemctl is-enabled "${SERVICE}.service" 2>/dev/null || echo 'unknown')"
  echo
  echo "📖 Commandes utiles:"
  echo "  Voir les logs    : journalctl -u ${SERVICE}.service -f"
  echo "  Status           : systemctl status ${SERVICE}.service"
  echo "  Redémarrer       : systemctl restart ${SERVICE}.service"
  echo "  Arrêter          : systemctl stop ${SERVICE}.service"
  echo
  echo "🔧 Maintenance     : sudo ./manage.sh"
  echo "📜 Logs d'audit    : $LOG_FILE"
  echo
}

# -------------------- Main --------------------

main() {
  # Parser stdin AVANT les arguments (les arguments surchargent)
  parse_stdin
  parse_args "$@"
  
  echo "╔════════════════════════════════════════╗"
  echo "║  Prefect Worker Installer v${VERSION}    ║"
  echo "║            (Hardened)                  ║"
  echo "╚════════════════════════════════════════╝"
  echo
  
  need_root
  need_systemd
  
  # Créer le fichier de log avec bonnes permissions
  touch "$LOG_FILE" 2>/dev/null || true
  chmod 600 "$LOG_FILE" 2>/dev/null || true
  
  log_to_file "AUDIT" "=== Installation démarrée par $(whoami) ==="
  
  validate_inputs
  install_deps
  install_worker
  
  log_to_file "AUDIT" "=== Installation terminée avec succès ==="
}

main "$@"
