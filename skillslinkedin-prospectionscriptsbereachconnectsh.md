<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# bereach_connect.sh — Envoi d'une demande de connexion LinkedIn via BeReach API
# Endpoint : POST /connect/linkedin/profile
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

: "${BEREACH_TOKEN:?Erreur : BEREACH_TOKEN non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BEREACH_BASE_URL="https://api.bereach.ai"
MAX_RETRIES=2
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/bereach_connect_$(date +%Y%m%d).log"
MAX_NOTE_LENGTH=300

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" &gt;&amp;2
}

random_delay() {
  local delay=$(( RANDOM % 4 + 2 ))
  log "INFO" "Délai de sécurité : ${delay}s"
  sleep "$delay"
}

usage() {
  cat &lt;&lt;EOF
Usage: $(basename "$0") [OPTIONS]

Envoie une demande de connexion LinkedIn personnalisée via BeReach API.

OPTIONS:
  --profile-url   URL      URL LinkedIn du profil cible (obligatoire)
  --profile-id    ID       URN ou publicIdentifier du profil (alternatif à --profile-url)
  --profile-data  JSON     Données du profil JSON pour personnalisation de la note
  --note          TEXTE    Note de connexion personnalisée (max 300 chars)
                           Si absent, génération automatique depuis --profile-data
  --dry-run                Afficher la note sans envoyer la demande
  -h, --help               Afficher cette aide

EXEMPLES:
  $(basename "$0") --profile-url "https://linkedin.com/in/john-doe"
  $(basename "$0") --profile-url "https://linkedin.com/in/john-doe" --note "Bonjour John, j'ai vu votre post sur..."
  $(basename "$0") --profile-url "https://linkedin.com/in/john-doe" --profile-data '{"firstName":"John","headline":"CEO"}'
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Génération automatique de la note de connexion
# Personnalisée selon les données du profil (max 300 chars)
# -----------------------------------------------------------------------------
generate_connection_note() {
  local profile_data="$1"

  local first_name headline company position
  first_name=$(echo "$profile_data" | jq -r '.firstName // ""' 2&gt;/dev/null || echo "")
  headline=$(echo "$profile_data" | jq -r '.headline // ""' 2&gt;/dev/null || echo "")
  company=$(echo "$profile_data" | jq -r '.company // ""' 2&gt;/dev/null || echo "")
  position=$(echo "$profile_data" | jq -r '.position // ""' 2&gt;/dev/null || echo "")

  # Construire une note personnalisée selon les données disponibles
  local note=""

  if [[ -n "$first_name" &amp;&amp; -n "$company" ]]; then
    note="Bonjour ${first_name}, votre profil chez ${company} a retenu mon attention."
  elif [[ -n "$first_name" &amp;&amp; -n "$headline" ]]; then
    # Tronquer le headline si trop long
    local short_headline="${headline:0:50}"
    note="Bonjour ${first_name}, votre expertise en ${short_headline} m'intéresse."
  elif [[ -n "$first_name" ]]; then
    note="Bonjour ${first_name}, je souhaite rejoindre votre réseau professionnel."
  else
    note="Bonjour, je souhaite rejoindre votre réseau LinkedIn."
  fi

  # Ajouter une phrase de contexte si place disponible
  local offer_desc="${OFFER_DESCRIPTION:-}"
  if [[ -n "$offer_desc" &amp;&amp; ${#note} -lt 200 ]]; then
    local remaining=$(( MAX_NOTE_LENGTH - ${#note} - 2 ))
    if [[ $remaining -gt 50 ]]; then
      local short_offer="${offer_desc:0:$remaining}"
      note="${note} ${short_offer}"
    fi
  fi

  # Tronquer si nécessaire (max 300 chars)
  if [[ ${#note} -gt $MAX_NOTE_LENGTH ]]; then
    note="${note:0:$((MAX_NOTE_LENGTH - 3))}..."
  fi

  echo "$note"
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
PROFILE_URL=""
PROFILE_ID=""
PROFILE_DATA=""
CUSTOM_NOTE=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile-url)  PROFILE_URL="$2";  shift 2 ;;
    --profile-id)   PROFILE_ID="$2";   shift 2 ;;
    --profile-data) PROFILE_DATA="$2"; shift 2 ;;
    --note)         CUSTOM_NOTE="$2";  shift 2 ;;
    --dry-run)      DRY_RUN=true;      shift ;;
    -h|--help)      usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

# Validation : au moins un identifiant de profil requis
if [[ -z "$PROFILE_URL" &amp;&amp; -z "$PROFILE_ID" ]]; then
  log "ERROR" "--profile-url ou --profile-id est obligatoire"
  exit 1
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== bereach_connect.sh démarré ==="

  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # Déterminer l'identifiant du profil à utiliser
  local profile_identifier="${PROFILE_URL:-$PROFILE_ID}"
  log "INFO" "Profil cible : $profile_identifier"

  # Générer ou utiliser la note de connexion
  local connection_note
  if [[ -n "$CUSTOM_NOTE" ]]; then
    connection_note="$CUSTOM_NOTE"
    log "INFO" "Note personnalisée fournie"
  elif [[ -n "$PROFILE_DATA" ]]; then
    connection_note=$(generate_connection_note "$PROFILE_DATA")
    log "INFO" "Note générée automatiquement depuis les données du profil"
  else
    connection_note="Bonjour, je souhaite rejoindre votre réseau professionnel LinkedIn."
    log "INFO" "Note par défaut utilisée"
  fi

  # Vérification de la longueur de la note
  if [[ ${#connection_note} -gt $MAX_NOTE_LENGTH ]]; then
    log "WARN" "Note trop longue (${#connection_note} chars) — troncature à $MAX_NOTE_LENGTH chars"
    connection_note="${connection_note:0:$((MAX_NOTE_LENGTH - 3))}..."
  fi

  log "INFO" "Note de connexion (${#connection_note} chars) : $connection_note"

  # Mode dry-run : afficher sans envoyer
  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "[DRY-RUN] Simulation — aucune demande envoyée"
    echo "{\"dryRun\": true, \"profile\": \"$profile_identifier\", \"note\": $(echo "$connection_note" | jq -Rs .), \"noteLength\": ${#connection_note}}"
    return 0
  fi

  # Construire le body JSON
  local request_body
  request_body=$(jq -n \
    --arg profile "$profile_identifier" \
    --arg note "$connection_note" \
    '{
      profile: $profile,
      message: $note
    }')

  # Délai de sécurité
  random_delay

  # Appel API avec retry
  local attempt=0
  local response http_code

  while [[ $attempt -le $MAX_RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -gt 1 ]] &amp;&amp; random_delay

    log "INFO" "Tentative $attempt/$((MAX_RETRIES + 1)) — envoi demande de connexion..."

    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${BEREACH_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --max-time 30 \
      --data "$request_body" \
      "${BEREACH_BASE_URL}/connect/linkedin/profile" 2&gt;&amp;1)

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | head -n -1)

    log "INFO" "HTTP $http_code reçu"

    case "$http_code" in
      200|201)
        log "INFO" "✅ Demande de connexion envoyée avec succès"

        # Extraire les métriques
        local credits_used retry_after
        credits_used=$(echo "$response" | jq '.creditsUsed // 0' 2&gt;/dev/null || echo "0")
        retry_after=$(echo "$response" | jq '.retryAfter // 0' 2&gt;/dev/null || echo "0")

        log "INFO" "Crédits consommés : $credits_used | retryAfter : ${retry_after}s"

        # Enrichir la réponse avec les métadonnées
        local enriched_response
        enriched_response=$(echo "$response" | jq \
          --arg profile "$profile_identifier" \
          --arg note "$connection_note" \
          --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          '. + {
            _profile: $profile,
            _noteSent: $note,
            _sentAt: $ts,
            _action: "connect"
          }' 2&gt;/dev/null || echo "$response")

        echo "$enriched_response"
        log "INFO" "=== bereach_connect.sh terminé avec succès ==="
        return 0
        ;;
      429)
        local retry_after
        retry_after=$(echo "$response" | jq -r '.retryAfter // 60' 2&gt;/dev/null || echo "60")
        log "WARN" "Rate limit (429) — retryAfter: ${retry_after}s"
        if [[ $attempt -le $MAX_RETRIES ]]; then
          sleep "$retry_after"
        else
          log "ERROR" "Rate limit persistant"
          echo "{\"_error\": \"RATE_LIMIT_EXCEEDED\", \"_retryAfter\": $retry_after, \"_profile\": \"$profile_identifier\"}"
          exit 1
        fi
        ;;
      409)
        log "WARN" "Conflit (409) — demande de connexion déjà envoyée ou déjà connecté"
        echo "{\"_error\": \"ALREADY_CONNECTED_OR_PENDING\", \"_httpCode\": 409, \"_profile\": \"$profile_identifier\"}"
        return 0
        ;;
      401)
        log "ERROR" "Authentification échouée (401)"
        echo "{\"_error\": \"AUTH_FAILED\", \"_httpCode\": 401}"
        exit 1
        ;;
      403)
        log "ERROR" "Accès refusé (403) — limite journalière atteinte ou compte restreint"
        echo "{\"_error\": \"FORBIDDEN_OR_DAILY_LIMIT\", \"_httpCode\": 403, \"_profile\": \"$profile_identifier\"}"
        exit 1
        ;;
      500|502|503)
        log "WARN" "Erreur serveur ($http_code)"
        if [[ $attempt -le $MAX_RETRIES ]]; then
          sleep $(( 5 * attempt ))
        else
          log "ERROR" "Erreur serveur persistante"
          echo "{\"_error\": \"SERVER_ERROR\", \"_httpCode\": $http_code}"
          exit 1
        fi
        ;;
      *)
        log "ERROR" "Code HTTP inattendu : $http_code"
        echo "{\"_error\": \"UNEXPECTED_HTTP_CODE\", \"_httpCode\": $http_code}"
        exit 1
        ;;
    esac
  done
}

main "$@"
</code></pre>
