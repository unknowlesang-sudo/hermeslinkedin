<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# gsheet_sync.sh — Synchronisation CRM Google Sheets
# Auth via google_sheets/oauth_setup.py (OAuth2)
# Colonnes CRM : Date | Nom | Titre | Entreprise | URL LinkedIn | Statut |
#                Message envoyé | Notes
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

: "${GOOGLE_SHEETS_ID:?Erreur : GOOGLE_SHEETS_ID non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SHEETS_BASE_URL="https://sheets.googleapis.com/v4/spreadsheets"
CRM_SHEET_NAME="CRM"
CRM_SHEET_RANGE="${CRM_SHEET_NAME}!A:H"
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/gsheet_sync_$(date +%Y%m%d).log"
OAUTH_SCRIPT="${SCRIPT_DIR}/../../../google_sheets/oauth_setup.py"
TOKEN_FILE="${HOME}/.hermes/credentials/google_sheets_token.json"
CREDENTIALS_FILE="${HOME}/.hermes/credentials/google_sheets_credentials.json"

# Colonnes CRM (index 0-based)
COL_DATE=0
COL_NOM=1
COL_TITRE=2
COL_ENTREPRISE=3
COL_URL=4
COL_STATUT=5
COL_MESSAGE=6
COL_NOTES=7

mkdir -p "$LOG_DIR" "$(dirname "$TOKEN_FILE")"

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

Synchronise les données prospects avec le CRM Google Sheets.

ACTIONS:
  --action upsert          Ajouter ou mettre à jour un prospect
  --action read            Lire les prospects (avec filtre optionnel)
  --action update-status   Mettre à jour uniquement le statut d'un prospect
  --action deduplicate     Retourner les URLs déjà présentes dans le CRM

OPTIONS:
  --prospect-data  JSON    Données du prospect (JSON)
  --filter-status  STATUT  Filtrer par statut (pour --action read)
  --new-status     STATUT  Nouveau statut (pour --action update-status)
  --output         FICHIER Fichier de sortie JSON (défaut: stdout)
  -h, --help               Afficher cette aide

STATUTS VALIDES:
  "Connexion envoyée" | "Connexion acceptée" | "Message envoyé" |
  "Réponse reçue" | "Qualifié" | "Refusé" | "En attente"

EXEMPLES:
  $(basename "$0") --action upsert --prospect-data '{"firstName":"Marie","company":"Acme",...}'
  $(basename "$0") --action read --filter-status "Connexion envoyée"
  $(basename "$0") --action deduplicate
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Obtenir un token d'accès OAuth2 Google
# Utilise oauth_setup.py ou le token en cache
# -----------------------------------------------------------------------------
get_access_token() {
  # Vérifier si le token en cache est encore valide
  if [[ -f "$TOKEN_FILE" ]]; then
    local expiry
    expiry=$(jq -r '.expiry // ""' "$TOKEN_FILE" 2&gt;/dev/null || echo "")
    local now
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    if [[ -n "$expiry" &amp;&amp; "$expiry" &gt; "$now" ]]; then
      local token
      token=$(jq -r '.token' "$TOKEN_FILE" 2&gt;/dev/null || echo "")
      if [[ -n "$token" &amp;&amp; "$token" != "null" ]]; then
        echo "$token"
        return 0
      fi
    fi
  fi

  # Rafraîchir le token via oauth_setup.py
  if [[ -f "$OAUTH_SCRIPT" ]]; then
    log "INFO" "Rafraîchissement du token OAuth2 via oauth_setup.py..."
    local token
    token=$(python3 "$OAUTH_SCRIPT" --action get-token \
      --credentials "$CREDENTIALS_FILE" \
      --token-file "$TOKEN_FILE" 2&gt;/dev/null)

    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
  fi

  # Fallback : utiliser GOOGLE_ACCESS_TOKEN si défini
  if [[ -n "${GOOGLE_ACCESS_TOKEN:-}" ]]; then
    echo "$GOOGLE_ACCESS_TOKEN"
    return 0
  fi

  log "ERROR" "Impossible d'obtenir un token OAuth2 Google Sheets"
  log "ERROR" "Vérifier : $OAUTH_SCRIPT ou définir GOOGLE_ACCESS_TOKEN dans .env"
  return 1
}

# -----------------------------------------------------------------------------
# Appel API Google Sheets
# -----------------------------------------------------------------------------
sheets_api_call() {
  local method="$1"
  local endpoint="$2"
  local body="${3:-}"
  local token="$4"

  local response
  if [[ "$method" == "GET" ]]; then
    response=$(curl -s -w "\n%{http_code}" \
      -X GET \
      -H "Authorization: Bearer $token" \
      -H "Accept: application/json" \
      --max-time 30 \
      "${SHEETS_BASE_URL}/${GOOGLE_SHEETS_ID}${endpoint}" 2&gt;&amp;1)
  else
    response=$(curl -s -w "\n%{http_code}" \
      -X "$method" \
      -H "Authorization: Bearer $token" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --max-time 30 \
      ${body:+--data "$body"} \
      "${SHEETS_BASE_URL}/${GOOGLE_SHEETS_ID}${endpoint}" 2&gt;&amp;1)
  fi

  local http_code
  http_code=$(echo "$response" | tail -n1)
  response=$(echo "$response" | head -n -1)

  if [[ "$http_code" != "200" ]]; then
    log "ERROR" "Google Sheets API HTTP $http_code : $response"
    return 1
  fi

  echo "$response"
}

# -----------------------------------------------------------------------------
# Lire toutes les lignes du CRM
# -----------------------------------------------------------------------------
read_crm_rows() {
  local token="$1"
  local filter_status="${2:-}"

  log "INFO" "Lecture du CRM (onglet: $CRM_SHEET_NAME)..."

  local response
  response=$(sheets_api_call "GET" \
    "/values/${CRM_SHEET_RANGE}?majorDimension=ROWS" \
    "" \
    "$token")

  local rows
  rows=$(echo "$response" | jq '.values // []' 2&gt;/dev/null || echo "[]")

  # Convertir en objets JSON avec les noms de colonnes
  local prospects
  prospects=$(echo "$rows" | jq '
    .[1:] |  # Ignorer la ligne d'"'"'en-tête
    [.[] |
      select(length &gt; 0) |
      {
        date:        (.[0] // ""),
        nom:         (.[1] // ""),
        titre:       (.[2] // ""),
        entreprise:  (.[3] // ""),
        url:         (.[4] // ""),
        statut:      (.[5] // ""),
        message:     (.[6] // ""),
        notes:       (.[7] // "")
      }
    ]
  ' 2&gt;/dev/null || echo "[]")

  # Filtrer par statut si demandé
  if [[ -n "$filter_status" ]]; then
    prospects=$(echo "$prospects" | jq \
      --arg status "$filter_status" \
      '[.[] | select(.statut == $status)]' 2&gt;/dev/null || echo "[]")
  fi

  echo "$prospects"
}

# -----------------------------------------------------------------------------
# Trouver la ligne d'un prospect par URL LinkedIn
# Retourne le numéro de ligne (1-based) ou -1 si non trouvé
# -----------------------------------------------------------------------------
find_prospect_row() {
  local token="$1"
  local profile_url="$2"

  local response
  response=$(sheets_api_call "GET" \
    "/values/${CRM_SHEET_RANGE}?majorDimension=ROWS" \
    "" \
    "$token")

  local rows
  rows=$(echo "$response" | jq '.values // []' 2&gt;/dev/null || echo "[]")

  # Normaliser l'URL recherchée
  local normalized_url
  normalized_url=$(echo "$profile_url" | sed 's|?.*||' | sed 's|/$||' | tr '[:upper:]' '[:lower:]')

  # Chercher la ligne correspondante (index 1-based, ligne 1 = en-tête)
  local row_index
  row_index=$(echo "$rows" | jq -r \
    --arg url "$normalized_url" \
    'to_entries |
    .[] |
    select(
      (.value[4] // "") |
      gsub("\\?.*$"; "") |
      rtrimstr("/") |
      ascii_downcase |
      . == $url
    ) |
    .key + 2' 2&gt;/dev/null | head -1)

  echo "${row_index:--1}"
}

# -----------------------------------------------------------------------------
# Ajouter ou mettre à jour un prospect dans le CRM
# -----------------------------------------------------------------------------
upsert_prospect() {
  local token="$1"
  local prospect_data="$2"

  # Extraire les champs
  local date nom titre entreprise url statut message notes
  date=$(date '+%Y-%m-%d')
  nom=$(echo "$prospect_data" | jq -r '(.firstName // "") + " " + (.lastName // "") | ltrimstr(" ") | rtrimstr(" ")' 2&gt;/dev/null || echo "")
  titre=$(echo "$prospect_data" | jq -r '.position // .headline // ""' 2&gt;/dev/null || echo "")
  entreprise=$(echo "$prospect_data" | jq -r '.company // ""' 2&gt;/dev/null || echo "")
  url=$(echo "$prospect_data" | jq -r '.profileUrl // .url // ""' 2&gt;/dev/null || echo "")
  statut=$(echo "$prospect_data" | jq -r '._status // "Connexion envoyée"' 2&gt;/dev/null || echo "Connexion envoyée")
  message=$(echo "$prospect_data" | jq -r '._messageSent // ""' 2&gt;/dev/null || echo "")
  notes=$(echo "$prospect_data" | jq -r '._notes // ""' 2&gt;/dev/null || echo "")

  if [[ -z "$url" ]]; then
    log "ERROR" "URL LinkedIn manquante dans les données du prospect"
    return 1
  fi

  log "INFO" "Upsert prospect : $nom | $titre @ $entreprise | $statut"

  # Chercher si le prospect existe déjà
  local existing_row
  existing_row=$(find_prospect_row "$token" "$url")

  local row_data
  row_data=$(jq -n \
    --arg date "$date" \
    --arg nom "$nom" \
    --arg titre "$titre" \
    --arg entreprise "$entreprise" \
    --arg url "$url" \
    --arg statut "$statut" \
    --arg message "$message" \
    --arg notes "$notes" \
    '{"values": [[$date, $nom, $titre, $entreprise, $url, $statut, $message, $notes]]}')

  if [[ "$existing_row" == "-1" ]]; then
    # Ajouter une nouvelle ligne
    log "INFO" "Ajout d'une nouvelle ligne dans le CRM..."
    sheets_api_call "POST" \
      "/values/${CRM_SHEET_NAME}!A:H:append?valueInputOption=USER_ENTERED&amp;insertDataOption=INSERT_ROWS" \
      "$row_data" \
      "$token" &gt; /dev/null

    log "INFO" "✅ Prospect ajouté : $nom"
    echo "{\"action\": \"inserted\", \"nom\": \"$nom\", \"url\": \"$url\", \"statut\": \"$statut\"}"
  else
    # Mettre à jour la ligne existante
    log "INFO" "Mise à jour de la ligne $existing_row..."
    sheets_api_call "PUT" \
      "/values/${CRM_SHEET_NAME}!A${existing_row}:H${existing_row}?valueInputOption=USER_ENTERED" \
      "$row_data" \
      "$token" &gt; /dev/null

    log "INFO" "✅ Prospect mis à jour : $nom (ligne $existing_row)"
    echo "{\"action\": \"updated\", \"row\": $existing_row, \"nom\": \"$nom\", \"url\": \"$url\", \"statut\": \"$statut\"}"
  fi
}

# -----------------------------------------------------------------------------
# Mettre à jour uniquement le statut d'un prospect
# -----------------------------------------------------------------------------
update_status() {
  local token="$1"
  local prospect_data="$2"
  local new_status="$3"

  local url
  url=$(echo "$prospect_data" | jq -r '.url // .profileUrl // ._normalizedUrl // ""' 2&gt;/dev/null || echo "")

  if [[ -z "$url" ]]; then
    log "ERROR" "URL LinkedIn manquante pour la mise à jour du statut"
    return 1
  fi

  local row
  row=$(find_prospect_row "$token" "$url")

  if [[ "$row" == "-1" ]]; then
    log "WARN" "Prospect non trouvé dans le CRM : $url"
    echo "{\"action\": \"not_found\", \"url\": \"$url\"}"
    return 0
  fi

  log "INFO" "Mise à jour statut ligne $row → '$new_status'"

  local update_data
  update_data=$(jq -n --arg status "$new_status" '{"values": [[$status]]}')

  sheets_api_call "PUT" \
    "/values/${CRM_SHEET_NAME}!F${row}?valueInputOption=USER_ENTERED" \
    "$update_data" \
    "$token" &gt; /dev/null

  log "INFO" "✅ Statut mis à jour : $url → $new_status"
  echo "{\"action\": \"status_updated\", \"row\": $row, \"url\": \"$url\", \"newStatus\": \"$new_status\"}"
}

# -----------------------------------------------------------------------------
# Retourner toutes les URLs présentes dans le CRM (pour déduplication)
# -----------------------------------------------------------------------------
get_all_urls() {
  local token="$1"

  local response
  response=$(sheets_api_call "GET" \
    "/values/${CRM_SHEET_NAME}!E:E?majorDimension=ROWS" \
    "" \
    "$token")

  echo "$response" | jq -r '
    .values // [] |
    .[1:] |  # Ignorer l'"'"'en-tête
    [.[] | .[0] // "" | select(. != "") |
      gsub("\\?.*$"; "") | rtrimstr("/") | ascii_downcase
    ] | unique
  ' 2&gt;/dev/null || echo "[]"
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
ACTION=""
PROSPECT_DATA=""
FILTER_STATUS=""
NEW_STATUS=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action)         ACTION="$2";         shift 2 ;;
    --prospect-data)  PROSPECT_DATA="$2";  shift 2 ;;
    --filter-status)  FILTER_STATUS="$2";  shift 2 ;;
    --new-status)     NEW_STATUS="$2";     shift 2 ;;
    --output)         OUTPUT_FILE="$2";    shift 2 ;;
    -h|--help)        usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

if [[ -z "$ACTION" ]]; then
  log "ERROR" "--action est obligatoire"
  exit 1
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== gsheet_sync.sh démarré (action: $ACTION) ==="

  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # Obtenir le token OAuth2
  local token
  if ! token=$(get_access_token); then
    log "ERROR" "Impossible d'obtenir le token OAuth2"
    exit 1
  fi

  local result

  case "$ACTION" in
    upsert)
      if [[ -z "$PROSPECT_DATA" ]]; then
        log "ERROR" "--prospect-data requis pour l'action upsert"
        exit 1
      fi
      result=$(upsert_prospect "$token" "$PROSPECT_DATA")
      ;;

    read)
      result=$(read_crm_rows "$token" "$FILTER_STATUS")
      ;;

    update-status)
      if [[ -z "$PROSPECT_DATA" || -z "$NEW_STATUS" ]]; then
        log "ERROR" "--prospect-data et --new-status requis pour update-status"
        exit 1
      fi
      result=$(update_status "$token" "$PROSPECT_DATA" "$NEW_STATUS")
      ;;

    deduplicate)
      result=$(get_all_urls "$token")
      ;;

    *)
      log "ERROR" "Action inconnue : $ACTION (valeurs : upsert, read, update-status, deduplicate)"
      exit 1
      ;;
  esac

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$result" &gt; "$OUTPUT_FILE"
    log "INFO" "Résultat sauvegardé dans : $OUTPUT_FILE"
  else
    echo "$result"
  fi

  log "INFO" "=== gsheet_sync.sh terminé ==="
}

main "$@"
</code></pre>
