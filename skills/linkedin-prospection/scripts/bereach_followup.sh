#!/bin/bash
# =============================================================================
# bereach_followup.sh — Suivi des demandes de connexion LinkedIn via BeReach API
# Endpoints :
#   POST /invitations/linkedin/sent  — lister les invitations envoyées
#   GET  /me/linkedin/connections    — lister les connexions actuelles
# Compare avec le CRM Google Sheets pour détecter les nouvelles acceptations
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Chargement des variables d'environnement
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../../../../.env"

if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

: "${BEREACH_TOKEN:?Erreur : BEREACH_TOKEN non défini dans .env}"
: "${GOOGLE_SHEETS_ID:?Erreur : GOOGLE_SHEETS_ID non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BEREACH_BASE_URL="https://api.bereach.ai"
MAX_RETRIES=2
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/bereach_followup_$(date +%Y%m%d).log"
CACHE_DIR="${HOME}/.hermes/cache/linkedin-prospection"
SENT_INVITATIONS_CACHE="${CACHE_DIR}/sent_invitations.json"

mkdir -p "$LOG_DIR" "$CACHE_DIR"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" >&2
}

random_delay() {
  local delay=$(( RANDOM % 4 + 2 ))
  log "INFO" "Délai de sécurité : ${delay}s"
  sleep "$delay"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Vérifie les nouvelles acceptations de connexion LinkedIn.
Compare les invitations envoyées avec les connexions actuelles.

OPTIONS:
  --output      FICHIER    Fichier de sortie JSON (défaut: stdout)
  --since       DATE       Filtrer les acceptations depuis cette date (ISO 8601)
                           Ex: --since "2026-05-01T00:00:00Z"
  --update-crm             Mettre à jour le statut dans Google Sheets après détection
  -h, --help               Afficher cette aide

EXEMPLES:
  $(basename "$0")
  $(basename "$0") --since "2026-05-10T00:00:00Z" --update-crm
  $(basename "$0") --output new_connections.json
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Appel API générique avec retry
# -----------------------------------------------------------------------------
api_call() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local attempt=0
  local response http_code

  while [[ $attempt -le $MAX_RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -gt 1 ]] && random_delay

    if [[ "$method" == "GET" ]]; then
      response=$(curl -s -w "\n%{http_code}" \
        -X GET \
        -H "Authorization: Bearer ${BEREACH_TOKEN}" \
        -H "Accept: application/json" \
        --max-time 30 \
        "${BEREACH_BASE_URL}${endpoint}" 2>&1)
    else
      response=$(curl -s -w "\n%{http_code}" \
        -X POST \
        -H "Authorization: Bearer ${BEREACH_TOKEN}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        --max-time 30 \
        ${body:+--data "$body"} \
        "${BEREACH_BASE_URL}${endpoint}" 2>&1)
    fi

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | head -n -1)

    case "$http_code" in
      200)
        echo "$response"
        return 0
        ;;
      429)
        local retry_after
        retry_after=$(echo "$response" | jq -r '.retryAfter // 60' 2>/dev/null || echo "60")
        log "WARN" "Rate limit (429) sur $endpoint — attente ${retry_after}s"
        [[ $attempt -le $MAX_RETRIES ]] && sleep "$retry_after" || { echo "{\"_error\": \"RATE_LIMIT\"}"; return 1; }
        ;;
      401)
        log "ERROR" "Auth échouée (401) sur $endpoint"
        echo "{\"_error\": \"AUTH_FAILED\"}"
        return 1
        ;;
      500|502|503)
        log "WARN" "Erreur serveur ($http_code) sur $endpoint"
        [[ $attempt -le $MAX_RETRIES ]] && sleep $(( 5 * attempt )) || { echo "{\"_error\": \"SERVER_ERROR\"}"; return 1; }
        ;;
      *)
        log "ERROR" "HTTP $http_code inattendu sur $endpoint"
        echo "{\"_error\": \"HTTP_$http_code\"}"
        return 1
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Récupérer les invitations envoyées (en attente)
# Endpoint : POST /invitations/linkedin/sent
# -----------------------------------------------------------------------------
get_sent_invitations() {
  log "INFO" "Récupération des invitations envoyées..."
  random_delay

  local response
  response=$(api_call "POST" "/invitations/linkedin/sent" '{}')

  if echo "$response" | jq -e '._error' &>/dev/null; then
    log "ERROR" "Échec récupération invitations envoyées : $response"
    echo "[]"
    return 1
  fi

  # Extraire la liste des invitations
  local invitations
  invitations=$(echo "$response" | jq '.items // .invitations // []' 2>/dev/null || echo "[]")

  local count
  count=$(echo "$invitations" | jq 'length')
  log "INFO" "$count invitations en attente trouvées"

  # Mettre en cache
  echo "$invitations" > "$SENT_INVITATIONS_CACHE"
  log "INFO" "Cache mis à jour : $SENT_INVITATIONS_CACHE"

  echo "$invitations"
}

# -----------------------------------------------------------------------------
# Récupérer les connexions actuelles
# Endpoint : GET /me/linkedin/connections
# -----------------------------------------------------------------------------
get_current_connections() {
  log "INFO" "Récupération des connexions actuelles..."
  random_delay

  local response
  response=$(api_call "GET" "/me/linkedin/connections")

  if echo "$response" | jq -e '._error' &>/dev/null; then
    log "ERROR" "Échec récupération connexions : $response"
    echo "[]"
    return 1
  fi

  local connections
  connections=$(echo "$response" | jq '.items // .connections // []' 2>/dev/null || echo "[]")

  local count
  count=$(echo "$connections" | jq 'length')
  log "INFO" "$count connexions actuelles trouvées"

  echo "$connections"
}

# -----------------------------------------------------------------------------
# Charger les profils envoyés depuis Google Sheets (CRM)
# Utilise gsheet_sync.sh pour lire les lignes avec statut "Connexion envoyée"
# -----------------------------------------------------------------------------
get_crm_pending_profiles() {
  log "INFO" "Chargement des profils en attente depuis le CRM..."

  local gsheet_script="${SCRIPT_DIR}/gsheet_sync.sh"

  if [[ ! -f "$gsheet_script" ]]; then
    log "WARN" "gsheet_sync.sh non trouvé — utilisation du cache local"
    if [[ -f "$SENT_INVITATIONS_CACHE" ]]; then
      cat "$SENT_INVITATIONS_CACHE"
    else
      echo "[]"
    fi
    return 0
  fi

  # Lire les profils avec statut "Connexion envoyée" depuis le CRM
  bash "$gsheet_script" --action read --filter-status "Connexion envoyée" 2>/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# Détecter les nouvelles acceptations
# Compare les profils en attente avec les connexions actuelles
# -----------------------------------------------------------------------------
detect_new_acceptances() {
  local pending_profiles="$1"
  local current_connections="$2"
  local since_date="${3:-}"

  log "INFO" "Détection des nouvelles acceptations..."

  # Extraire les URLs des connexions actuelles (normalisées)
  local connection_urls
  connection_urls=$(echo "$current_connections" | jq -r '
    [.[] |
      (.profileUrl // .linkedinUrl // "") |
      gsub("\\?.*$"; "") |
      rtrimstr("/") |
      ascii_downcase
    ] | unique
  ' 2>/dev/null || echo "[]")

  # Comparer avec les profils en attente
  local new_acceptances
  new_acceptances=$(echo "$pending_profiles" | jq \
    --argjson connections "$connection_urls" \
    --arg since "$since_date" \
    '
    [.[] |
      . as $prospect |
      (
        (.url // .profileUrl // "") |
        gsub("\\?.*$"; "") |
        rtrimstr("/") |
        ascii_downcase
      ) as $normalized_url |
      select(
        ($connections | map(. == $normalized_url) | any) and
        (
          $since == "" or
          (.sentAt // .date // "1970-01-01") >= $since
        )
      ) |
      . + {
        _acceptedAt: (now | todate),
        _status: "Connexion acceptée",
        _normalizedUrl: $normalized_url
      }
    ]
  ' 2>/dev/null || echo "[]")

  local count
  count=$(echo "$new_acceptances" | jq 'length')
  log "INFO" "✅ $count nouvelle(s) acceptation(s) détectée(s)"

  echo "$new_acceptances"
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
OUTPUT_FILE=""
SINCE_DATE=""
UPDATE_CRM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --output)     OUTPUT_FILE="$2"; shift 2 ;;
    --since)      SINCE_DATE="$2";  shift 2 ;;
    --update-crm) UPDATE_CRM=true;  shift ;;
    -h|--help)    usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== bereach_followup.sh démarré ==="

  if ! command -v jq &>/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # 1. Récupérer les invitations envoyées
  local sent_invitations
  sent_invitations=$(get_sent_invitations)

  # 2. Récupérer les connexions actuelles
  local current_connections
  current_connections=$(get_current_connections)

  # 3. Charger les profils en attente depuis le CRM
  local crm_pending
  crm_pending=$(get_crm_pending_profiles)

  # 4. Détecter les nouvelles acceptations
  local new_acceptances
  new_acceptances=$(detect_new_acceptances "$crm_pending" "$current_connections" "$SINCE_DATE")

  # 5. Mettre à jour le CRM si demandé
  if [[ "$UPDATE_CRM" == "true" ]]; then
    local acceptance_count
    acceptance_count=$(echo "$new_acceptances" | jq 'length')

    if [[ "$acceptance_count" -gt 0 ]]; then
      log "INFO" "Mise à jour du CRM pour $acceptance_count acceptation(s)..."
      local gsheet_script="${SCRIPT_DIR}/gsheet_sync.sh"

      if [[ -f "$gsheet_script" ]]; then
        echo "$new_acceptances" | jq -c '.[]' | while read -r prospect; do
          bash "$gsheet_script" \
            --action update-status \
            --prospect-data "$prospect" \
            --new-status "Connexion acceptée" 2>/dev/null || \
            log "WARN" "Échec mise à jour CRM pour : $(echo "$prospect" | jq -r '._normalizedUrl')"
          random_delay
        done
      else
        log "WARN" "gsheet_sync.sh non trouvé — mise à jour CRM ignorée"
      fi
    fi
  fi

  # 6. Construire le rapport final
  local report
  report=$(jq -n \
    --argjson sent "$sent_invitations" \
    --argjson connections "$current_connections" \
    --argjson acceptances "$new_acceptances" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      checkedAt: $ts,
      sentInvitationsCount: ($sent | length),
      currentConnectionsCount: ($connections | length),
      newAcceptancesCount: ($acceptances | length),
      newAcceptances: $acceptances
    }')

  # 7. Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" > "$OUTPUT_FILE"
    log "INFO" "Rapport sauvegardé dans : $OUTPUT_FILE"
  else
    echo "$report"
  fi

  log "INFO" "=== bereach_followup.sh terminé ==="
}

main "$@"
