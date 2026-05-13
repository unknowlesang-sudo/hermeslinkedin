<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# bereach_search.sh — Recherche de personnes LinkedIn via BeReach API
# Endpoint : POST /search/linkedin/people
# Doc : https://api.bereach.ai
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

# Vérification des variables obligatoires
: "${BEREACH_TOKEN:?Erreur : BEREACH_TOKEN non défini dans .env}"
: "${ICP_DESCRIPTION:?Erreur : ICP_DESCRIPTION non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
BEREACH_BASE_URL="https://api.bereach.ai"
MAX_RETRIES=2
RETRY_DELAY=5
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/bereach_search_$(date +%Y%m%d).log"

# Créer le répertoire de logs si nécessaire
mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

# Logging avec timestamp
log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" &gt;&amp;2
}

# Délai aléatoire entre 2 et 5 secondes (sécurité anti-ban)
random_delay() {
  local delay=$(( RANDOM % 4 + 2 ))
  log "INFO" "Délai de sécurité : ${delay}s"
  sleep "$delay"
}

# Afficher l'aide
usage() {
  cat &lt;&lt;EOF
Usage: $(basename "$0") [OPTIONS]

Recherche des personnes LinkedIn via BeReach API (POST /search/linkedin/people).

OPTIONS:
  --title       TITRE      Titre/poste recherché (ex: "Directeur Commercial")
  --company     ENTREPRISE Nom de l'entreprise cible (optionnel)
  --location    LIEU       Localisation (ex: "France", "Paris") ou ID numérique
  --industry    SECTEUR    Secteur d'activité ou ID numérique
  --degree      DEGRE      Degré de connexion : F (1er), S (2ème), O (hors réseau)
                           Défaut : S (2ème degré)
  --count       N          Nombre de résultats (1-50, défaut: 50)
  --start       N          Offset de pagination (défaut: 0)
  --output      FICHIER    Fichier de sortie JSON (défaut: stdout)
  -h, --help               Afficher cette aide

EXEMPLES:
  $(basename "$0") --title "Directeur Commercial" --location "France" --count 50
  $(basename "$0") --title "CEO" --industry "Software" --degree S --output results.json

VARIABLES D'ENVIRONNEMENT:
  BEREACH_TOKEN     Token API BeReach (obligatoire)
  ICP_DESCRIPTION   Description de l'ICP (utilisée pour le logging)
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
TITLE=""
COMPANY=""
LOCATION=""
INDUSTRY=""
DEGREE="S"
COUNT=50
START=0
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --title)     TITLE="$2";    shift 2 ;;
    --company)   COMPANY="$2";  shift 2 ;;
    --location)  LOCATION="$2"; shift 2 ;;
    --industry)  INDUSTRY="$2"; shift 2 ;;
    --degree)    DEGREE="$2";   shift 2 ;;
    --count)     COUNT="$2";    shift 2 ;;
    --start)     START="$2";    shift 2 ;;
    --output)    OUTPUT_FILE="$2"; shift 2 ;;
    -h|--help)   usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

# Validation des arguments
if [[ -z "$TITLE" &amp;&amp; -z "$COMPANY" &amp;&amp; -z "$LOCATION" &amp;&amp; -z "$INDUSTRY" ]]; then
  log "ERROR" "Au moins un critère de recherche est requis (--title, --company, --location, ou --industry)"
  exit 1
fi

# Validation du degré de connexion
if [[ "$DEGREE" != "F" &amp;&amp; "$DEGREE" != "S" &amp;&amp; "$DEGREE" != "O" ]]; then
  log "ERROR" "Degré de connexion invalide : $DEGREE (valeurs acceptées : F, S, O)"
  exit 1
fi

# Validation du count (max 50 selon globalRules)
if [[ "$COUNT" -gt 50 ]]; then
  log "WARN" "count=$COUNT dépasse le maximum autorisé (50). Réduction à 50."
  COUNT=50
fi

# -----------------------------------------------------------------------------
# Construction du body JSON
# -----------------------------------------------------------------------------
build_request_body() {
  local body="{}"

  # Ajouter les champs non vides
  [[ -n "$TITLE" ]]    &amp;&amp; body=$(echo "$body" | jq --arg v "$TITLE"    '. + {title: $v}')
  [[ -n "$COMPANY" ]]  &amp;&amp; body=$(echo "$body" | jq --arg v "$COMPANY"  '. + {currentCompany: [$v]}')
  [[ -n "$LOCATION" ]] &amp;&amp; body=$(echo "$body" | jq --arg v "$LOCATION" '. + {location: [$v]}')
  [[ -n "$INDUSTRY" ]] &amp;&amp; body=$(echo "$body" | jq --arg v "$INDUSTRY" '. + {industry: [$v]}')

  # Champs obligatoires
  body=$(echo "$body" | jq \
    --arg degree "$DEGREE" \
    --argjson count "$COUNT" \
    --argjson start "$START" \
    '. + {
      connectionDegree: [$degree],
      count: $count,
      start: $start
    }')

  echo "$body"
}

# -----------------------------------------------------------------------------
# Appel API avec retry
# -----------------------------------------------------------------------------
call_bereach_api() {
  local request_body="$1"
  local attempt=0
  local response
  local http_code

  log "INFO" "Recherche LinkedIn — ICP: $ICP_DESCRIPTION"
  log "INFO" "Paramètres : title='$TITLE' location='$LOCATION' industry='$INDUSTRY' degree='$DEGREE' count=$COUNT start=$START"

  while [[ $attempt -le $MAX_RETRIES ]]; do
    attempt=$(( attempt + 1 ))

    # Délai de sécurité (sauf premier appel)
    [[ $attempt -gt 1 ]] &amp;&amp; random_delay

    log "INFO" "Tentative $attempt/$((MAX_RETRIES + 1))..."

    # Appel API avec capture du code HTTP
    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Authorization: Bearer ${BEREACH_TOKEN}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --max-time 30 \
      --data "$request_body" \
      "${BEREACH_BASE_URL}/search/linkedin/people" 2&gt;&amp;1)

    # Séparer le body du code HTTP
    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | head -n -1)

    log "INFO" "HTTP $http_code reçu"

    # Traitement selon le code HTTP
    case "$http_code" in
      200)
        log "INFO" "Recherche réussie"
        echo "$response"
        return 0
        ;;
      429)
        # Rate limit — lire retryAfter
        local retry_after
        retry_after=$(echo "$response" | jq -r '.retryAfter // 60' 2&gt;/dev/null || echo "60")
        log "WARN" "Rate limit (429) — retryAfter: ${retry_after}s"

        if [[ $attempt -le $MAX_RETRIES ]]; then
          log "INFO" "Attente de ${retry_after}s avant retry..."
          sleep "$retry_after"
        else
          log "ERROR" "Rate limit persistant après $MAX_RETRIES tentatives"
          echo "$response" | jq '. + {_error: "RATE_LIMIT_EXCEEDED", _retryAfter: '"$retry_after"'}' 2&gt;/dev/null || \
            echo "{\"_error\": \"RATE_LIMIT_EXCEEDED\", \"_retryAfter\": $retry_after}"
          return 1
        fi
        ;;
      401)
        log "ERROR" "Authentification échouée (401) — vérifier BEREACH_TOKEN"
        echo "{\"_error\": \"AUTH_FAILED\", \"_httpCode\": 401}"
        return 1
        ;;
      403)
        log "ERROR" "Accès refusé (403) — vérifier les permissions du compte"
        echo "{\"_error\": \"FORBIDDEN\", \"_httpCode\": 403}"
        return 1
        ;;
      400)
        log "ERROR" "Requête invalide (400) : $response"
        echo "$response" | jq '. + {_error: "BAD_REQUEST"}' 2&gt;/dev/null || \
          echo "{\"_error\": \"BAD_REQUEST\", \"_response\": \"$response\"}"
        return 1
        ;;
      500|502|503)
        log "WARN" "Erreur serveur ($http_code) — tentative $attempt/$((MAX_RETRIES + 1))"
        if [[ $attempt -le $MAX_RETRIES ]]; then
          local backoff=$(( RETRY_DELAY * attempt ))
          log "INFO" "Backoff exponentiel : ${backoff}s"
          sleep "$backoff"
        else
          log "ERROR" "Erreur serveur persistante après $MAX_RETRIES tentatives"
          echo "{\"_error\": \"SERVER_ERROR\", \"_httpCode\": $http_code}"
          return 1
        fi
        ;;
      *)
        log "ERROR" "Code HTTP inattendu : $http_code"
        echo "{\"_error\": \"UNEXPECTED_HTTP_CODE\", \"_httpCode\": $http_code}"
        return 1
        ;;
    esac
  done
}

# -----------------------------------------------------------------------------
# Post-traitement de la réponse
# -----------------------------------------------------------------------------
process_response() {
  local response="$1"

  # Vérifier que la réponse est du JSON valide
  if ! echo "$response" | jq empty 2&gt;/dev/null; then
    log "ERROR" "Réponse non-JSON reçue : $response"
    exit 1
  fi

  # Extraire les métriques
  local items_count total credits_used retry_after has_more
  items_count=$(echo "$response" | jq '.items | length' 2&gt;/dev/null || echo "0")
  total=$(echo "$response" | jq '.paging.total // 0' 2&gt;/dev/null || echo "0")
  credits_used=$(echo "$response" | jq '.creditsUsed // 0' 2&gt;/dev/null || echo "0")
  retry_after=$(echo "$response" | jq '.retryAfter // 0' 2&gt;/dev/null || echo "0")
  has_more=$(echo "$response" | jq '.hasMore // false' 2&gt;/dev/null || echo "false")

  log "INFO" "Résultats : $items_count prospects trouvés (total: $total, hasMore: $has_more)"
  log "INFO" "Crédits consommés : $credits_used | retryAfter : ${retry_after}s"

  # Avertissement si retryAfter &gt; 0
  if [[ "$retry_after" -gt 0 ]]; then
    log "WARN" "retryAfter=${retry_after}s — respecter ce délai avant le prochain appel"
  fi

  # Normaliser les URLs des profils
  local normalized
  normalized=$(echo "$response" | jq '
    .items = [
      .items[] |
      .profileUrl = (
        if .profileUrl then
          .profileUrl | gsub("\\?.*$"; "") | rtrimstr("/")
        else null
        end
      ) |
      .profileUrn = (.profileUrn // null) |
      .publicIdentifier = (.publicIdentifier // null) |
      ._enrichedAt = (now | todate)
    ]
  ' 2&gt;/dev/null || echo "$response")

  echo "$normalized"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== bereach_search.sh démarré ==="

  # Vérifier que jq est disponible
  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé. Installer avec : apt-get install jq"
    exit 1
  fi

  # Vérifier que curl est disponible
  if ! command -v curl &amp;&gt;/dev/null; then
    log "ERROR" "curl est requis mais non installé."
    exit 1
  fi

  # Construire le body de la requête
  local request_body
  request_body=$(build_request_body)
  log "INFO" "Body de la requête : $request_body"

  # Délai de sécurité initial
  random_delay

  # Appel API
  local api_response
  if ! api_response=$(call_bereach_api "$request_body"); then
    log "ERROR" "Échec de l'appel API BeReach"
    exit 1
  fi

  # Post-traitement
  local final_response
  final_response=$(process_response "$api_response")

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$final_response" &gt; "$OUTPUT_FILE"
    log "INFO" "Résultats sauvegardés dans : $OUTPUT_FILE"
  else
    echo "$final_response"
  fi

  log "INFO" "=== bereach_search.sh terminé ==="
}

main "$@"
</code></pre>
