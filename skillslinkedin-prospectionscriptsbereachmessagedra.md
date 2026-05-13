<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# bereach_message_draft.sh — Génération de message de prospection personnalisé
# Prend les données d'un profil LinkedIn enrichi (JSON) et génère un message
# de prospection B2B personnalisé (max 300 chars) basé sur l'activité du profil.
# Retourne un JSON avec le brouillon et les métadonnées.
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Chargement des variables d'environnement
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &amp;&amp; pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../../.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${OFFER_DESCRIPTION:?Erreur : OFFER_DESCRIPTION non défini dans .env}"
: "${ICP_DESCRIPTION:?Erreur : ICP_DESCRIPTION non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MAX_MESSAGE_LENGTH=300
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/bereach_message_draft_$(date +%Y%m%d).log"

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" &gt;&amp;2
}

usage() {
  cat &lt;&lt;EOF
Usage: $(basename "$0") [OPTIONS]

Génère un message de prospection LinkedIn personnalisé depuis les données d'un profil.

OPTIONS:
  --profile-data  JSON     Données du profil enrichi (JSON, obligatoire)
                           Doit contenir : firstName, headline, company, position,
                           originalPosts45d[], intentSignals[]
  --template      TYPE     Template à utiliser :
                           - auto (défaut) : sélection automatique selon les signaux
                           - pain_point    : basé sur un problème détecté
                           - activity      : basé sur un post récent
                           - generic       : message générique personnalisé
  --output        FICHIER  Fichier de sortie JSON (défaut: stdout)
  --dry-run                Afficher sans sauvegarder
  -h, --help               Afficher cette aide

EXEMPLES:
  $(basename "$0") --profile-data '{"firstName":"Marie","headline":"DRH","company":"Acme"}'
  $(basename "$0") --profile-data "$(cat profile.json)" --template activity
  $(basename "$0") --profile-data "$(cat profile.json)" --output draft.json

VARIABLES D'ENVIRONNEMENT:
  OFFER_DESCRIPTION   Description courte de votre offre (obligatoire)
  ICP_DESCRIPTION     Description de votre ICP (obligatoire)
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Extraction des données du profil
# -----------------------------------------------------------------------------
extract_profile_fields() {
  local profile_data="$1"

  FIRST_NAME=$(echo "$profile_data" | jq -r '.firstName // ""' 2&gt;/dev/null || echo "")
  LAST_NAME=$(echo "$profile_data" | jq -r '.lastName // ""' 2&gt;/dev/null || echo "")
  HEADLINE=$(echo "$profile_data" | jq -r '.headline // ""' 2&gt;/dev/null || echo "")
  COMPANY=$(echo "$profile_data" | jq -r '.company // ""' 2&gt;/dev/null || echo "")
  POSITION=$(echo "$profile_data" | jq -r '.position // ""' 2&gt;/dev/null || echo "")
  PROFILE_URL=$(echo "$profile_data" | jq -r '.profileUrl // ""' 2&gt;/dev/null || echo "")

  # Signaux d'intention (depuis Phase 7 du workflow)
  HAS_EXPLICIT_PAIN=$(echo "$profile_data" | jq -r '.intentSignals.explicit_pain // false' 2&gt;/dev/null || echo "false")
  HAS_SEEKING_SOLUTION=$(echo "$profile_data" | jq -r '.intentSignals.seeking_solution // false' 2&gt;/dev/null || echo "false")
  HAS_TOOL_CHANGE=$(echo "$profile_data" | jq -r '.intentSignals.tool_change // false' 2&gt;/dev/null || echo "false")
  HAS_GROWTH_SIGNAL=$(echo "$profile_data" | jq -r '.intentSignals.growth_or_launch_signal // false' 2&gt;/dev/null || echo "false")
  HAS_HIRING=$(echo "$profile_data" | jq -r '.intentSignals.hiring_signal // false' 2&gt;/dev/null || echo "false")

  # Dernier post original (pour personnalisation basée sur l'activité)
  LAST_POST_TEXT=$(echo "$profile_data" | jq -r '.originalPosts45d[0].text // ""' 2&gt;/dev/null | head -c 100 || echo "")
  LAST_POST_DATE=$(echo "$profile_data" | jq -r '.originalPosts45d[0].date // ""' 2&gt;/dev/null || echo "")

  # Data quality
  DATA_QUALITY=$(echo "$profile_data" | jq -r '.dataQuality // "MEDIUM"' 2&gt;/dev/null || echo "MEDIUM")
}

# -----------------------------------------------------------------------------
# Sélection automatique du template selon les signaux
# -----------------------------------------------------------------------------
select_template() {
  if [[ "$HAS_EXPLICIT_PAIN" == "true" || "$HAS_SEEKING_SOLUTION" == "true" ]]; then
    echo "pain_point"
  elif [[ -n "$LAST_POST_TEXT" ]]; then
    echo "activity"
  elif [[ "$HAS_TOOL_CHANGE" == "true" || "$HAS_GROWTH_SIGNAL" == "true" ]]; then
    echo "growth"
  else
    echo "generic"
  fi
}

# -----------------------------------------------------------------------------
# Génération du message selon le template
# Règles : max 300 chars, mentionne OFFER_DESCRIPTION, ton humain et direct
# -----------------------------------------------------------------------------
generate_message() {
  local template="$1"
  local message=""

  # Préparer les variables courtes
  local name="${FIRST_NAME:-}"
  local short_offer="${OFFER_DESCRIPTION:0:80}"
  local short_company="${COMPANY:0:30}"
  local short_position="${POSITION:0:40}"

  case "$template" in
    pain_point)
      # Message basé sur un problème détecté dans les posts
      if [[ -n "$name" &amp;&amp; -n "$short_company" ]]; then
        message="Bonjour ${name}, j'ai vu vos posts sur les défis chez ${short_company}. ${short_offer}. Ça pourrait vous aider — 5 min pour en parler ?"
      elif [[ -n "$name" ]]; then
        message="Bonjour ${name}, vos posts montrent un vrai défi. ${short_offer}. Ça vous parle ? 5 min ?"
      else
        message="Bonjour, j'ai vu vos posts sur ce sujet. ${short_offer}. Ça pourrait vous aider ?"
      fi
      ;;

    activity)
      # Message basé sur un post récent
      local post_snippet="${LAST_POST_TEXT:0:50}"
      if [[ -n "$name" &amp;&amp; -n "$post_snippet" ]]; then
        message="Bonjour ${name}, votre post sur \"${post_snippet}...\" m'a interpellé. ${short_offer}. On pourrait en discuter ?"
      elif [[ -n "$name" ]]; then
        message="Bonjour ${name}, j'ai suivi votre activité récente. ${short_offer}. Ça vous intéresse ?"
      else
        message="Bonjour, votre activité récente m'a interpellé. ${short_offer}. On pourrait en discuter ?"
      fi
      ;;

    growth)
      # Message basé sur un signal de croissance ou changement d'outil
      if [[ -n "$name" &amp;&amp; -n "$short_company" ]]; then
        message="Bonjour ${name}, je vois que ${short_company} est en pleine croissance. ${short_offer}. Ça pourrait accélérer vos résultats ?"
      elif [[ -n "$name" ]]; then
        message="Bonjour ${name}, votre profil montre une belle dynamique. ${short_offer}. On en parle ?"
      else
        message="Bonjour, ${short_offer}. Ça pourrait vous intéresser dans votre contexte actuel ?"
      fi
      ;;

    generic|*)
      # Message générique personnalisé
      if [[ -n "$name" &amp;&amp; -n "$short_position" &amp;&amp; -n "$short_company" ]]; then
        message="Bonjour ${name}, en tant que ${short_position} chez ${short_company}, ${short_offer} pourrait vous intéresser. 5 min pour échanger ?"
      elif [[ -n "$name" &amp;&amp; -n "$short_company" ]]; then
        message="Bonjour ${name}, j'ai vu votre profil chez ${short_company}. ${short_offer}. Ça vous parle ?"
      elif [[ -n "$name" ]]; then
        message="Bonjour ${name}, ${short_offer}. Votre profil m'a semblé pertinent — on pourrait échanger ?"
      else
        message="Bonjour, ${short_offer}. Votre profil m'a semblé pertinent pour en discuter."
      fi
      ;;
  esac

  # Tronquer si nécessaire (max 300 chars)
  if [[ ${#message} -gt $MAX_MESSAGE_LENGTH ]]; then
    log "WARN" "Message trop long (${#message} chars) — troncature à $MAX_MESSAGE_LENGTH"
    message="${message:0:$((MAX_MESSAGE_LENGTH - 3))}..."
  fi

  echo "$message"
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
PROFILE_DATA=""
TEMPLATE="auto"
OUTPUT_FILE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-data) PROFILE_DATA="$2"; shift 2 ;;
    --template)     TEMPLATE="$2";     shift 2 ;;
    --output)       OUTPUT_FILE="$2";  shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift ;;
    -h|--help)      usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

if [[ -z "$PROFILE_DATA" ]]; then
  log "ERROR" "--profile-data est obligatoire"
  exit 1
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== bereach_message_draft.sh démarré ==="

  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # Valider le JSON du profil
  if ! echo "$PROFILE_DATA" | jq empty 2&gt;/dev/null; then
    log "ERROR" "--profile-data n'est pas un JSON valide"
    exit 1
  fi

  # Extraire les champs du profil
  extract_profile_fields "$PROFILE_DATA"

  log "INFO" "Profil : ${FIRST_NAME} ${LAST_NAME} | ${POSITION} @ ${COMPANY}"
  log "INFO" "Signaux : pain=${HAS_EXPLICIT_PAIN} seeking=${HAS_SEEKING_SOLUTION} tool_change=${HAS_TOOL_CHANGE} growth=${HAS_GROWTH_SIGNAL}"
  log "INFO" "Data quality : $DATA_QUALITY"

  # Sélectionner le template
  local selected_template
  if [[ "$TEMPLATE" == "auto" ]]; then
    selected_template=$(select_template)
    log "INFO" "Template sélectionné automatiquement : $selected_template"
  else
    selected_template="$TEMPLATE"
    log "INFO" "Template forcé : $selected_template"
  fi

  # Générer le message
  local message
  message=$(generate_message "$selected_template")

  log "INFO" "Message généré (${#message} chars) : $message"

  # Construire le JSON de sortie
  local draft_json
  draft_json=$(jq -n \
    --arg message "$message" \
    --arg template "$selected_template" \
    --arg profile_url "$PROFILE_URL" \
    --arg first_name "$FIRST_NAME" \
    --arg company "$COMPANY" \
    --arg position "$POSITION" \
    --arg data_quality "$DATA_QUALITY" \
    --argjson length "${#message}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      message: $message,
      messageLength: $length,
      template: $template,
      profileUrl: $profile_url,
      prospectName: $first_name,
      prospectCompany: $company,
      prospectPosition: $position,
      dataQuality: $data_quality,
      generatedAt: $ts,
      status: "draft"
    }')

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$draft_json" &gt; "$OUTPUT_FILE"
    log "INFO" "Brouillon sauvegardé dans : $OUTPUT_FILE"
  else
    echo "$draft_json"
  fi

  log "INFO" "=== bereach_message_draft.sh terminé ==="
}

main "$@"
</code></pre>
