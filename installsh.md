<pre><code class="bash language-bash">#!/usr/bin/env bash
# =============================================================================
# install.sh — Script d'installation idempotent pour hermes-business-agents
# Compatible Ubuntu/Debian (Google Cloud e2-standard)
# Usage : bash install.sh
# =============================================================================

set -euo pipefail

# ─── Couleurs pour l'affichage ───────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ─── Fonctions utilitaires ───────────────────────────────────────────────────
log_info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ─── Répertoire du script ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &amp;&amp; pwd)"
HERMES_DIR="${HOME}/.hermes"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   Département Autonome de Prospection LinkedIn — 197€/mois  ║"
echo "║   Installation de hermes-business-agents                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# =============================================================================
# ÉTAPE 1 : Vérification des prérequis système
# =============================================================================
log_info "Vérification des prérequis système..."

# Vérifier que l'OS est Ubuntu/Debian
if ! command -v apt-get &amp;&gt;/dev/null; then
    log_error "Ce script nécessite Ubuntu/Debian (apt-get non trouvé)."
fi

# Vérifier Python 3.10+
if command -v python3 &amp;&gt;/dev/null; then
    PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
    PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
    PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
    if [[ "$PYTHON_MAJOR" -ge 3 &amp;&amp; "$PYTHON_MINOR" -ge 10 ]]; then
        log_success "Python $PYTHON_VERSION détecté."
    else
        log_warn "Python $PYTHON_VERSION détecté — Python 3.10+ recommandé."
    fi
else
    log_info "Installation de Python 3..."
    sudo apt-get update -qq &amp;&amp; sudo apt-get install -y python3 python3-pip python3-venv
    log_success "Python 3 installé."
fi

# Vérifier curl
if ! command -v curl &amp;&gt;/dev/null; then
    log_info "Installation de curl..."
    sudo apt-get install -y curl
fi

# Vérifier git
if ! command -v git &amp;&gt;/dev/null; then
    log_info "Installation de git..."
    sudo apt-get install -y git
fi

log_success "Prérequis système OK."

# =============================================================================
# ÉTAPE 2 : Installation de Hermes Agent (idempotent)
# =============================================================================
log_info "Vérification de l'installation Hermes Agent..."

if command -v hermes &amp;&gt;/dev/null; then
    HERMES_VERSION=$(hermes --version 2&gt;/dev/null || echo "version inconnue")
    log_success "Hermes Agent déjà installé : $HERMES_VERSION"
else
    log_info "Installation de Hermes Agent (Nous Research)..."
    # Installation via le script officiel Nous Research
    curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash
    # Recharger le PATH pour inclure hermes
    export PATH="${HOME}/.local/bin:${PATH}"
    if command -v hermes &amp;&gt;/dev/null; then
        log_success "Hermes Agent installé avec succès."
    else
        log_error "Échec de l'installation de Hermes. Vérifiez votre connexion internet."
    fi
fi

# =============================================================================
# ÉTAPE 3 : Création de la structure de répertoires ~/.hermes/
# =============================================================================
log_info "Création de la structure de répertoires ~/.hermes/..."

# Créer les répertoires nécessaires
mkdir -p "${HERMES_DIR}/config"
mkdir -p "${HERMES_DIR}/tools/bereach_api"
mkdir -p "${HERMES_DIR}/cron"
mkdir -p "${HERMES_DIR}/skills/prospection/linkedin-prospection"
mkdir -p "${HERMES_DIR}/skills/content/linkedin-content-publisher"
mkdir -p "${HERMES_DIR}/memory"
mkdir -p "${HERMES_DIR}/logs"

log_success "Structure de répertoires créée."

# =============================================================================
# ÉTAPE 4 : Copie des fichiers de configuration
# =============================================================================
log_info "Copie des fichiers vers ~/.hermes/..."

# Fonction de copie idempotente avec sauvegarde
copy_file() {
    local src="$1"
    local dst="$2"
    if [[ -f "$src" ]]; then
        # Sauvegarder l'existant si différent
        if [[ -f "$dst" ]] &amp;&amp; ! diff -q "$src" "$dst" &amp;&gt;/dev/null; then
            cp "$dst" "${dst}.backup.$(date +%Y%m%d_%H%M%S)"
            log_warn "Sauvegarde créée : ${dst}.backup.*"
        fi
        cp "$src" "$dst"
        log_success "Copié : $src → $dst"
    else
        log_warn "Fichier source introuvable : $src (ignoré)"
    fi
}

# Copier config.yaml
copy_file "${SCRIPT_DIR}/config/config.yaml" "${HERMES_DIR}/config.yaml"

# Copier SOUL.md
copy_file "${SCRIPT_DIR}/config/SOUL.md" "${HERMES_DIR}/SOUL.md"

# Copier les outils BeReach
copy_file "${SCRIPT_DIR}/tools/bereach_api/tool.yaml"        "${HERMES_DIR}/tools/bereach_api/tool.yaml"
copy_file "${SCRIPT_DIR}/tools/bereach_api/bereach_client.py" "${HERMES_DIR}/tools/bereach_api/bereach_client.py"

# Copier les tâches cron
copy_file "${SCRIPT_DIR}/cron/daily_prospection.yaml"  "${HERMES_DIR}/cron/daily_prospection.yaml"
copy_file "${SCRIPT_DIR}/cron/content_schedule.yaml"   "${HERMES_DIR}/cron/content_schedule.yaml"

log_success "Fichiers copiés."

# =============================================================================
# ÉTAPE 5 : Installation des dépendances Python
# =============================================================================
log_info "Installation des dépendances Python..."

# Créer un environnement virtuel si inexistant
VENV_DIR="${HERMES_DIR}/venv"
if [[ ! -d "$VENV_DIR" ]]; then
    python3 -m venv "$VENV_DIR"
    log_success "Environnement virtuel créé : $VENV_DIR"
else
    log_success "Environnement virtuel existant : $VENV_DIR"
fi

# Activer le venv et installer les dépendances
source "${VENV_DIR}/bin/activate"

# Dépendances requises pour bereach_client.py et l'agent
pip install --quiet --upgrade pip
pip install --quiet \
    requests&gt;=2.31.0 \
    httpx&gt;=0.27.0 \
    tenacity&gt;=8.2.0 \
    python-dotenv&gt;=1.0.0 \
    google-auth&gt;=2.29.0 \
    google-auth-oauthlib&gt;=1.2.0 \
    google-api-python-client&gt;=2.126.0 \
    gspread&gt;=6.1.0 \
    python-telegram-bot&gt;=21.0.0 \
    pydantic&gt;=2.7.0 \
    structlog&gt;=24.1.0

deactivate
log_success "Dépendances Python installées."

# =============================================================================
# ÉTAPE 6 : Création du fichier .env depuis .env.example (idempotent)
# =============================================================================
log_info "Vérification du fichier .env..."

ENV_FILE="${HERMES_DIR}/.env"
ENV_EXAMPLE="${SCRIPT_DIR}/config/.env.example"

if [[ -f "$ENV_FILE" ]]; then
    log_success "Fichier .env existant conservé : $ENV_FILE"
else
    if [[ -f "$ENV_EXAMPLE" ]]; then
        cp "$ENV_EXAMPLE" "$ENV_FILE"
        log_success "Fichier .env créé depuis .env.example : $ENV_FILE"
        log_warn "⚠️  IMPORTANT : Éditez $ENV_FILE et renseignez vos vraies valeurs !"
    else
        log_warn "Fichier .env.example introuvable — création d'un .env minimal..."
        cat &gt; "$ENV_FILE" &lt;&lt; 'EOF'
# Renseignez vos variables d'environnement ici
BEREACH_TOKEN=
TELEGRAM_BOT_TOKEN=
TELEGRAM_CHAT_ID=
COMPOSIO_API_KEY=
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_SPREADSHEET_ID=
ICP_DESCRIPTION=
OFFER_DESCRIPTION=
DAILY_PROSPECT_TARGET=7
EOF
        log_warn "Fichier .env minimal créé. Renseignez vos valeurs avant de lancer l'agent."
    fi
fi

# =============================================================================
# ÉTAPE 7 : Affichage du résumé des variables d'environnement
# =============================================================================
echo ""
echo "─────────────────────────────────────────────────────────────────"
log_info "Résumé des variables d'environnement (.env) :"
echo "─────────────────────────────────────────────────────────────────"

# Variables requises
REQUIRED_VARS=(
    "BEREACH_TOKEN"
    "TELEGRAM_BOT_TOKEN"
    "TELEGRAM_CHAT_ID"
    "COMPOSIO_API_KEY"
    "GOOGLE_CLIENT_ID"
    "GOOGLE_CLIENT_SECRET"
    "GOOGLE_SPREADSHEET_ID"
    "ICP_DESCRIPTION"
    "OFFER_DESCRIPTION"
    "DAILY_PROSPECT_TARGET"
)

# Charger le .env pour vérification
set -a
# shellcheck disable=SC1090
source "$ENV_FILE" 2&gt;/dev/null || true
set +a

ALL_SET=true
for var in "${REQUIRED_VARS[@]}"; do
    value="${!var:-}"
    if [[ -z "$value" ]]; then
        echo -e "  ${RED}✗${NC} $var = (non défini)"
        ALL_SET=false
    else
        # Masquer les tokens sensibles
        if [[ "$var" == *"TOKEN"* || "$var" == *"KEY"* || "$var" == *"SECRET"* ]]; then
            masked="${value:0:4}****${value: -4}"
            echo -e "  ${GREEN}✓${NC} $var = $masked"
        else
            echo -e "  ${GREEN}✓${NC} $var = $value"
        fi
    fi
done

echo "─────────────────────────────────────────────────────────────────"

if [[ "$ALL_SET" == false ]]; then
    log_warn "Certaines variables ne sont pas définies. Éditez : $ENV_FILE"
fi

# =============================================================================
# ÉTAPE 8 : Vérification de la configuration Hermes
# =============================================================================
echo ""
log_info "Lancement de 'hermes config check'..."
echo "─────────────────────────────────────────────────────────────────"

# Exporter les variables du .env pour hermes config check
export PATH="${HOME}/.local/bin:${PATH}"
set -a
source "$ENV_FILE" 2&gt;/dev/null || true
set +a

if command -v hermes &amp;&gt;/dev/null; then
    hermes config check 2&gt;&amp;1 || log_warn "hermes config check a retourné des avertissements (voir ci-dessus)."
else
    log_warn "Hermes non trouvé dans le PATH. Ajoutez ~/.local/bin à votre PATH et relancez."
    log_warn "Commande : export PATH=\"\${HOME}/.local/bin:\${PATH}\""
fi

# =============================================================================
# RÉSUMÉ FINAL
# =============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    INSTALLATION TERMINÉE                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
log_success "Fichiers installés dans : ${HERMES_DIR}"
echo ""
echo "  Prochaines étapes :"
echo "  1. Éditez ${HERMES_DIR}/.env avec vos vraies valeurs"
echo "  2. Lancez : hermes login  (pour authentifier le provider 'nous')"
echo "  3. Lancez : hermes model  (pour sélectionner Qwen 3.6 Plus)"
echo "  4. Lancez : hermes start  (pour démarrer l'agent)"
echo ""
echo "  Documentation : https://hermes-agent.nousresearch.com/docs/"
echo ""
</code></pre>
