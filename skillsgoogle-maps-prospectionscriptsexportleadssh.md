<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# export_leads.sh — Export des leads Google Maps vers Google Sheets
# Auth via google_sheets/oauth_setup.py (OAuth2)
# Onglet cible : 'Leads Google Maps'
# Déduplication par nom + adresse avant insertion
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
LEADS_SHEET_NAME="Leads Google Maps"
LEADS_SHEET_RANGE="${LEADS_SHEET_NAME}!A:M"
LOG_DIR="${HOME}/.hermes/logs/google-maps-prospection"
LOG_FILE="${LOG_DIR}/export_leads_$(date +%Y%m%d).log"
OAUTH_SCRIPT="${SCRIPT_DIR}/../../../google_sheets/oauth_setup.py"
TOKEN_FILE="${HOME}/.hermes/credentials/google_sheets_token.json"
CREDENTIALS_FILE="${HOME}/.hermes/credentials/google_sheets_credentials.json"

# En-têtes des colonnes
SHEET_HEADERS=("Date" "Nom" "Catégorie" "Adresse" "Ville" "Code Postal" "Téléphone" "Site Web" "Email" "GPS Lat" "GPS Lon" "Statut" "Notes")

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

Exporte des leads JSON vers l'onglet 'Leads Google Maps' du CRM Google Sheets.
Déduplique automatiquement par nom + adresse.

OPTIONS:
  --input       FICHIER    Fichier JSON des leads (obligatoire)
                           Format : tableau JSON ou objet avec champ "leads"
  --sheet-tab   NOM        Nom de l'onglet (défaut: "Leads Google Maps")
  --no-dedup               Désactiver la déduplication
  --dry-run                Afficher les leads sans exporter
  --output      FICHIER    Fichier de rapport JSON (défaut: stdout)
  -h, --help               Afficher cette aide

FORMAT D'ENTRÉE (JSON):
  Tableau direct :
    [{"nom": "...", "adresse": "...", ...}, ...]

  Ou objet avec métadonnées :
    {"metadata": {...}, "leads": [...]}

EXEMPLES:
  $(basename "$0") --input leads_raw.json
  $(basename "$0") --input leads_raw.json --dry-run
  $(basename "$0") --input leads_raw.json --sheet-tab "Leads Lyon" --output rapport.json
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Obtenir un token d'accès OAuth2 Google
# -----------------------------------------------------------------------------
get_access_token() {
  # Vérifier le token en cache
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

  # Rafraîchir via oauth_setup.py
  if [[ -f "$OAUTH_SCRIPT" ]]; then
    log "INFO" "Rafraîchissement du token OAuth2..."
    local token
    token=$(python3 "$OAUTH_SCRIPT" --action get-token \
      --credentials "$CREDENTIALS_FILE" \
      --token-file "$TOKEN_FILE" 2&gt;/dev/null)
    if [[ -n "$token" ]]; then
      echo "$token"
      return 0
    fi
  fi

  # Fallback
  if [[ -n "${GOOGLE_ACCESS_TOKEN:-}" ]]; then
    echo "$GOOGLE_ACCESS_TOKEN"
    return 0
  fi

  log "ERROR" "Impossible d'obtenir le token OAuth2 Google Sheets"
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
# Vérifier et créer l'onglet si nécessaire
# -----------------------------------------------------------------------------
ensure_sheet_exists() {
  local token="$1"
  local sheet_name="$2"

  log "INFO" "Vérification de l'onglet : $sheet_name"

  # Lister les onglets existants
  local spreadsheet_info
  spreadsheet_info=$(sheets_api_call "GET" "" "" "$token")

  local sheet_exists
  sheet_exists=$(echo "$spreadsheet_info" | jq \
    --arg name "$sheet_name" \
    '.sheets[] | select(.properties.title == $name) | .properties.sheetId' \
    2&gt;/dev/null | head -1)

  if [[ -n "$sheet_exists" ]]; then
    log "INFO" "Onglet '$sheet_name' trouvé (ID: $sheet_exists)"
    return 0
  fi

  # Créer l'onglet
  log "INFO" "Création de l'onglet '$sheet_name'..."
  local create_body
  create_body=$(jq -n \
    --arg title "$sheet_name" \
    '{
      requests: [{
        addSheet: {
          properties: {
            title: $title,
            gridProperties: {
              rowCount: 1000,
              columnCount: 13
            }
          }
        }
      }]
    }')

  sheets_api_call "POST" ":batchUpdate" "$create_body" "$token" &gt; /dev/null

  log "INFO" "Onglet '$sheet_name' créé"

  # Ajouter les en-têtes
  local headers_body
  headers_body=$(jq -n \
    --arg range "${sheet_name}!A1:M1" \
    --argjson headers '["Date","Nom","Catégorie","Adresse","Ville","Code Postal","Téléphone","Site Web","Email","GPS Lat","GPS Lon","Statut","Notes"]' \
    '{
      range: $range,
      majorDimension: "ROWS",
      values: [$headers]
    }')

  sheets_api_call "PUT" \
    "/values/${sheet_name}!A1:M1?valueInputOption=USER_ENTERED" \
    "$headers_body" \
    "$token" &gt; /dev/null

  log "INFO" "En-têtes ajoutés à l'onglet '$sheet_name'"
}

# -----------------------------------------------------------------------------
# Charger les leads existants pour déduplication
# Retourne un set de clés "nom|adresse" normalisées
# -----------------------------------------------------------------------------
load_existing_leads() {
  local token="$1"
  local sheet_name="$2"

  log "INFO" "Chargement des leads existants pour déduplication..."

  local response
  response=$(sheets_api_call "GET" \
    "/values/${sheet_name}!A:E?majorDimension=ROWS" \
    "" \
    "$token" 2&gt;/dev/null || echo '{"values":[]}')

  # Extraire les clés de déduplication (nom + adresse normalisés)
  echo "$response" | jq -r '
    .values // [] |
    .[1:] |  # Ignorer l'"'"'en-tête
    .[] |
    select(length &gt;= 2) |
    (
      (.[1] // "") + "|" + (.[3] // "")  # nom|adresse
    ) |
    ascii_downcase |
    gsub("  +"; " ") |
    ltrimstr(" ") |
    rtrimstr(" ")
  ' 2&gt;/dev/null | sort -u
}

# -----------------------------------------------------------------------------
# Filtrer les leads en dédupliquant
# -----------------------------------------------------------------------------
deduplicate_leads() {
  local leads="$1"
  local existing_keys="$2"

  log "INFO" "Déduplication des leads..."

  local total
  total=$(echo "$leads" | jq 'length')

  # Créer un fichier temporaire avec les clés existantes
  local tmp_keys
  tmp_keys=$(mktemp)
  echo "$existing_keys" &gt; "$tmp_keys"

  # Filtrer les leads non présents
  local new_leads
  new_leads=$(echo "$leads" | jq \
    --rawfile existing_keys "$tmp_keys" \
    '
    ($existing_keys | split("\n") | map(select(. != "")) | unique) as $keys |
    [.[] |
      . as $lead |
      (
        ((.nom // "") + "|" + (.adresse // "")) |
        ascii_downcase |
        gsub("  +"; " ") |
        ltrimstr(" ") |
        rtrimstr(" ")
      ) as $key |
      select($keys | map(. == $key) | any | not)
    ]
    ' 2&gt;/dev/null || echo "$leads")

  rm -f "$tmp_keys"

  local new_count
  new_count=$(echo "$new_leads" | jq 'length')
  local dupes=$(( total - new_count ))

  log "INFO" "Déduplication : $total leads → $new_count nouveaux ($dupes doublons ignorés)"

  echo "$new_leads"
}

# -----------------------------------------------------------------------------
# Convertir un lead JSON en ligne Google Sheets
# -----------------------------------------------------------------------------
lead_to_row() {
  local lead="$1"

  jq -r '
    [
      (.extractedAt // (now | todate)),
      (.nom // ""),
      (.categorie // ""),
      (.adresse // ""),
      (.ville // ""),
      (.codePostal // ""),
      (.telephone // ""),
      (.siteWeb // ""),
      (.email // ""),
      ((.gpsLat // "") | tostring),
      ((.gpsLon // "") | tostring),
      (.statut // "Nouveau"),
      (.notes // "")
    ]
  ' &lt;&lt;&lt; "$lead" 2&gt;/dev/null
}

# -----------------------------------------------------------------------------
# Exporter les leads par batch (max 1000 lignes par requête)
# -----------------------------------------------------------------------------
export_leads_batch() {
  local token="$1"
  local leads="$2"
  local sheet_name="$3"

  local total
  total=$(echo "$leads" | jq 'length')

  if [[ "$total" -eq 0 ]]; then
    log "INFO" "Aucun nouveau lead à exporter"
    return 0
  fi

  log "INFO" "Export de $total leads vers '$sheet_name'..."

  # Construire le tableau de valeurs
  local values
  values=$(echo "$leads" | jq '
    [.[] |
      [
        (.extractedAt // (now | todate)),
        (.nom // ""),
        (.categorie // ""),
        (.adresse // ""),
        (.ville // ""),
        (.codePostal // ""),
        (.telephone // ""),
        (.siteWeb // ""),
        (.email // ""),
        ((.gpsLat // null) | if . then tostring else "" end),
        ((.gpsLon // null) | if . then tostring else "" end),
        (.statut // "Nouveau"),
        (.notes // "")
      ]
    ]
  ' 2&gt;/dev/null)

  # Construire le body de la requête
  local append_body
  append_body=$(jq -n \
    --arg range "${sheet_name}!A:M" \
    --argjson values "$values" \
    '{
      range: $range,
      majorDimension: "ROWS",
      values: $values
    }')

  # Appel API append
  local response
  response=$(sheets_api_call "POST" \
    "/values/${sheet_name}!A:M:append?valueInputOption=USER_ENTERED&amp;insertDataOption=INSERT_ROWS" \
    "$append_body" \
    "$token")

  local updated_rows
  updated_rows=$(echo "$response" | jq -r '.updates.updatedRows // 0' 2&gt;/dev/null || echo "0")

  log "INFO" "✅ $updated_rows lignes ajoutées dans '$sheet_name'"
  echo "$updated_rows"
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
INPUT_FILE=""
SHEET_TAB="$LEADS_SHEET_NAME"
NO_DEDUP=false
DRY_RUN=false
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --input)      INPUT_FILE="$2";  shift 2 ;;
    --sheet-tab)  SHEET_TAB="$2";   shift 2 ;;
    --no-dedup)   NO_DEDUP=true;    shift ;;
    --dry-run)    DRY_RUN=true;     shift ;;
    --output)     OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)    usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

if [[ -z "$INPUT_FILE" ]]; then
  log "ERROR" "--input est obligatoire"
  exit 1
fi

if [[ ! -f "$INPUT_FILE" ]]; then
  log "ERROR" "Fichier introuvable : $INPUT_FILE"
  exit 1
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== export_leads.sh démarré ==="

  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # Charger et parser le fichier JSON
  log "INFO" "Chargement du fichier : $INPUT_FILE"

  local raw_data
  raw_data=$(cat "$INPUT_FILE")

  # Extraire le tableau de leads (supporte les deux formats)
  local leads
  if echo "$raw_data" | jq -e '.leads' &amp;&gt;/dev/null 2&gt;&amp;1; then
    leads=$(echo "$raw_data" | jq '.leads')
    log "INFO" "Format détecté : objet avec métadonnées"
  else
    leads="$raw_data"
    log "INFO" "Format détecté : tableau direct"
  fi

  local total_input
  total_input=$(echo "$leads" | jq 'length')
  log "INFO" "$total_input leads chargés depuis $INPUT_FILE"

  # Mode dry-run
  if [[ "$DRY_RUN" == "true" ]]; then
    log "INFO" "[DRY-RUN] Simulation — aucun export effectué"
    echo "$leads" | jq '{
      dryRun: true,
      totalLeads: length,
      sample: .[0:3]
    }'
    return 0
  fi

  # Obtenir le token OAuth2
  local token
  if ! token=$(get_access_token); then
    log "ERROR" "Impossible d'obtenir le token OAuth2"
    exit 1
  fi

  # Vérifier/créer l'onglet
  ensure_sheet_exists "$token" "$SHEET_TAB"

  # Déduplication
  local leads_to_export="$leads"
  local dupes_count=0

  if [[ "$NO_DEDUP" == "false" ]]; then
    local existing_keys
    existing_keys=$(load_existing_leads "$token" "$SHEET_TAB")

    local before_dedup
    before_dedup=$(echo "$leads" | jq 'length')

    leads_to_export=$(deduplicate_leads "$leads" "$existing_keys")

    local after_dedup
    after_dedup=$(echo "$leads_to_export" | jq 'length')
    dupes_count=$(( before_dedup - after_dedup ))
  fi

  # Export
  local exported_count=0
  if [[ $(echo "$leads_to_export" | jq 'length') -gt 0 ]]; then
    exported_count=$(export_leads_batch "$token" "$leads_to_export" "$SHEET_TAB")
  else
    log "INFO" "Aucun nouveau lead à exporter (tous dédupliqués)"
  fi

  # Rapport final
  local report
  report=$(jq -n \
    --argjson total_input "$total_input" \
    --argjson exported "$exported_count" \
    --argjson dupes "$dupes_count" \
    --arg sheet "$SHEET_TAB" \
    --arg input_file "$INPUT_FILE" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      exportedAt: $ts,
      inputFile: $input_file,
      sheetTab: $sheet,
      totalInput: $total_input,
      exported: $exported,
      duplicatesSkipped: $dupes,
      status: "success"
    }')

  log "INFO" "📊 Rapport : $total_input leads en entrée → $exported_count exportés ($dupes_count doublons ignorés)"

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$report" &gt; "$OUTPUT_FILE"
    log "INFO" "Rapport sauvegardé dans : $OUTPUT_FILE"
  else
    echo "$report"
  fi

  log "INFO" "=== export_leads.sh terminé ==="
}

main "$@"
</code></pre>
