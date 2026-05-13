#!/bin/bash
# =============================================================================
# gmaps_scraper.sh — Scraping d'entreprises via API Overpass (OpenStreetMap)
# API : https://overpass-api.de/api/interpreter (gratuite, sans clé)
# Retourne : nom, adresse, téléphone, site web, coordonnées GPS
# =============================================================================
set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
OVERPASS_API="https://overpass-api.de/api/interpreter"
OVERPASS_TIMEOUT=60       # Timeout de la requête Overpass en secondes
REQUEST_DELAY=2           # Délai entre les requêtes (politesse)
MAX_RETRIES=3
LOG_DIR="${HOME}/.hermes/logs/google-maps-prospection"
LOG_FILE="${LOG_DIR}/gmaps_scraper_$(date +%Y%m%d).log"

mkdir -p "$LOG_DIR"

# -----------------------------------------------------------------------------
# Fonctions utilitaires
# -----------------------------------------------------------------------------

log() {
  local level="$1"
  shift
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" | tee -a "$LOG_FILE" >&2
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Scrape des entreprises via l'API Overpass (OpenStreetMap).
Gratuit, sans clé API requise.

OPTIONS:
  --category    TYPE     Catégorie OSM (obligatoire)
                         Exemples : restaurant, hotel, shop, office, doctors,
                                    lawyer, estate_agent, car_repair, hairdresser
  --city        VILLE    Nom de la ville (obligatoire si pas --bbox)
  --bbox        BBOX     Bounding box "sud,ouest,nord,est" (alternatif à --city)
  --radius      N        Rayon de recherche en mètres autour de la ville (défaut: 5000)
  --tag-key     CLE      Clé du tag OSM (défaut: amenity)
                         Exemples : amenity, shop, office, tourism
  --tag-value   VALEUR   Valeur du tag OSM (défaut: valeur de --category)
  --max-results N        Nombre max de résultats (défaut: 100)
  --output      FICHIER  Fichier de sortie JSON (défaut: stdout)
  --format      FORMAT   Format de sortie : json (défaut) | csv
  -h, --help             Afficher cette aide

EXEMPLES:
  $(basename "$0") --category restaurant --city "Lyon" --radius 3000
  $(basename "$0") --tag-key shop --tag-value hairdresser --city "Paris" --max-results 50
  $(basename "$0") --tag-key office --tag-value lawyer --city "Bordeaux" --output lawyers.json
  $(basename "$0") --category hotel --bbox "45.7,4.8,45.8,4.9" --output hotels.json

CATÉGORIES COURANTES:
  amenity=restaurant    Restaurants
  amenity=cafe          Cafés
  amenity=doctors       Médecins
  amenity=pharmacy      Pharmacies
  tourism=hotel         Hôtels
  shop=hairdresser      Coiffeurs
  shop=car_repair       Garages
  office=lawyer         Avocats
  office=estate_agent   Agences immobilières
  office=company        Entreprises génériques
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Résoudre les coordonnées d'une ville via Nominatim (OpenStreetMap)
# -----------------------------------------------------------------------------
resolve_city_coordinates() {
  local city="$1"
  local radius="$2"

  log "INFO" "Résolution des coordonnées pour : $city"

  local response
  response=$(curl -s \
    "https://nominatim.openstreetmap.org/search?q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$city'))" 2>/dev/null || echo "$city" | sed 's/ /+/g')&format=json&limit=1" \
    -H "User-Agent: hermes-business-agents/1.0" \
    --max-time 15 2>&1)

  local lat lon
  lat=$(echo "$response" | jq -r '.[0].lat // ""' 2>/dev/null || echo "")
  lon=$(echo "$response" | jq -r '.[0].lon // ""' 2>/dev/null || echo "")

  if [[ -z "$lat" || -z "$lon" ]]; then
    log "ERROR" "Impossible de résoudre les coordonnées pour : $city"
    return 1
  fi

  log "INFO" "Coordonnées trouvées : lat=$lat lon=$lon"

  # Calculer la bounding box approximative
  # 1 degré ≈ 111km → radius_deg = radius_m / 111000
  local radius_deg
  radius_deg=$(python3 -c "print(round($radius / 111000, 4))" 2>/dev/null || echo "0.045")

  local south north west east
  south=$(python3 -c "print(round($lat - $radius_deg, 6))" 2>/dev/null || echo "$(echo "$lat - $radius_deg" | bc -l)")
  north=$(python3 -c "print(round($lat + $radius_deg, 6))" 2>/dev/null || echo "$(echo "$lat + $radius_deg" | bc -l)")
  west=$(python3 -c "print(round($lon - $radius_deg, 6))" 2>/dev/null || echo "$(echo "$lon - $radius_deg" | bc -l)")
  east=$(python3 -c "print(round($lon + $radius_deg, 6))" 2>/dev/null || echo "$(echo "$lon + $radius_deg" | bc -l)")

  echo "${south},${west},${north},${east}"
}

# -----------------------------------------------------------------------------
# Construire la requête Overpass QL
# -----------------------------------------------------------------------------
build_overpass_query() {
  local tag_key="$1"
  local tag_value="$2"
  local bbox="$3"
  local max_results="$4"
  local timeout="$OVERPASS_TIMEOUT"

  # Requête Overpass QL pour nodes et ways avec le tag spécifié
  cat <<EOF
[out:json][timeout:${timeout}][maxsize:10000000];
(
  node["${tag_key}"="${tag_value}"](${bbox});
  way["${tag_key}"="${tag_value}"](${bbox});
  relation["${tag_key}"="${tag_value}"](${bbox});
);
out center ${max_results};
EOF
}

# -----------------------------------------------------------------------------
# Appel API Overpass avec retry
# -----------------------------------------------------------------------------
call_overpass_api() {
  local query="$1"
  local attempt=0
  local response http_code

  while [[ $attempt -lt $MAX_RETRIES ]]; do
    attempt=$(( attempt + 1 ))
    [[ $attempt -gt 1 ]] && sleep $(( REQUEST_DELAY * attempt ))

    log "INFO" "Tentative $attempt/$MAX_RETRIES — appel Overpass API..."

    response=$(curl -s -w "\n%{http_code}" \
      -X POST \
      -H "Content-Type: application/x-www-form-urlencoded" \
      -H "User-Agent: hermes-business-agents/1.0 (contact: admin@example.com)" \
      --data-urlencode "data=$query" \
      --max-time $(( OVERPASS_TIMEOUT + 10 )) \
      "$OVERPASS_API" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | head -n -1)

    case "$http_code" in
      200)
        log "INFO" "Réponse Overpass reçue"
        echo "$response"
        return 0
        ;;
      429|504)
        log "WARN" "Rate limit ou timeout ($http_code) — attente avant retry..."
        sleep $(( 30 * attempt ))
        ;;
      400)
        log "ERROR" "Requête Overpass invalide (400) : $response"
        return 1
        ;;
      *)
        log "WARN" "HTTP $http_code — tentative $attempt/$MAX_RETRIES"
        sleep $(( REQUEST_DELAY * attempt ))
        ;;
    esac
  done

  log "ERROR" "Échec après $MAX_RETRIES tentatives"
  return 1
}

# -----------------------------------------------------------------------------
# Parser et normaliser la réponse Overpass
# -----------------------------------------------------------------------------
parse_overpass_response() {
  local response="$1"
  local city="$2"
  local category="$3"

  if ! echo "$response" | jq empty 2>/dev/null; then
    log "ERROR" "Réponse Overpass non-JSON"
    return 1
  fi

  local elements_count
  elements_count=$(echo "$response" | jq '.elements | length' 2>/dev/null || echo "0")
  log "INFO" "$elements_count éléments bruts trouvés"

  # Normaliser chaque élément
  local leads
  leads=$(echo "$response" | jq \
    --arg city "$city" \
    --arg category "$category" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '
    [.elements[] |
      select(.tags.name != null) |  # Garder seulement les éléments nommés
      {
        # Identifiant OSM
        osmId: (.id | tostring),
        osmType: .type,

        # Informations principales
        nom: (.tags.name // ""),
        categorie: $category,

        # Adresse
        adresse: (
          [
            (.tags["addr:housenumber"] // ""),
            (.tags["addr:street"] // "")
          ] | map(select(. != "")) | join(" ")
        ),
        ville: (.tags["addr:city"] // $city),
        codePostal: (.tags["addr:postcode"] // ""),
        pays: (.tags["addr:country"] // "FR"),

        # Contact
        telephone: (
          .tags.phone //
          .tags["contact:phone"] //
          .tags["phone:mobile"] //
          ""
        ),
        siteWeb: (
          .tags.website //
          .tags["contact:website"] //
          .tags.url //
          ""
        ),
        email: (
          .tags.email //
          .tags["contact:email"] //
          ""
        ),

        # Coordonnées GPS
        gpsLat: (
          if .type == "node" then .lat
          elif .center then .center.lat
          else null
          end
        ),
        gpsLon: (
          if .type == "node" then .lon
          elif .center then .center.lon
          else null
          end
        ),

        # Métadonnées
        tags: .tags,
        extractedAt: $ts,
        statut: "Nouveau"
      }
    ] |
    # Dédupliquer par nom + adresse
    group_by(.nom + .adresse) |
    map(.[0])
    ' 2>/dev/null || echo "[]")

  local final_count
  final_count=$(echo "$leads" | jq 'length')
  log "INFO" "$final_count leads uniques après normalisation et déduplication"

  echo "$leads"
}

# -----------------------------------------------------------------------------
# Convertir en CSV si demandé
# -----------------------------------------------------------------------------
convert_to_csv() {
  local json_data="$1"

  echo "Date,Nom,Catégorie,Adresse,Ville,Code Postal,Téléphone,Site Web,Email,GPS Lat,GPS Lon,Statut"

  echo "$json_data" | jq -r '
    .[] |
    [
      .extractedAt,
      .nom,
      .categorie,
      .adresse,
      .ville,
      .codePostal,
      .telephone,
      .siteWeb,
      .email,
      (.gpsLat | tostring),
      (.gpsLon | tostring),
      .statut
    ] |
    map(. // "" | gsub(","; ";") | gsub("\n"; " ")) |
    join(",")
  ' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
CATEGORY=""
CITY=""
BBOX=""
RADIUS=5000
TAG_KEY=""
TAG_VALUE=""
MAX_RESULTS=100
OUTPUT_FILE=""
FORMAT="json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --category)   CATEGORY="$2";    shift 2 ;;
    --city)       CITY="$2";        shift 2 ;;
    --bbox)       BBOX="$2";        shift 2 ;;
    --radius)     RADIUS="$2";      shift 2 ;;
    --tag-key)    TAG_KEY="$2";     shift 2 ;;
    --tag-value)  TAG_VALUE="$2";   shift 2 ;;
    --max-results) MAX_RESULTS="$2"; shift 2 ;;
    --output)     OUTPUT_FILE="$2"; shift 2 ;;
    --format)     FORMAT="$2";      shift 2 ;;
    -h|--help)    usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

# Validation
if [[ -z "$CATEGORY" && -z "$TAG_KEY" ]]; then
  log "ERROR" "--category ou --tag-key est obligatoire"
  exit 1
fi

if [[ -z "$CITY" && -z "$BBOX" ]]; then
  log "ERROR" "--city ou --bbox est obligatoire"
  exit 1
fi

# Déterminer tag_key et tag_value
if [[ -z "$TAG_KEY" ]]; then
  # Mapper les catégories courantes vers les tags OSM
  case "$CATEGORY" in
    restaurant|cafe|doctors|pharmacy|hospital|school|bank|fuel|parking)
      TAG_KEY="amenity"
      TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
      ;;
    hotel|hostel|camp_site|motel)
      TAG_KEY="tourism"
      TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
      ;;
    hairdresser|car_repair|bakery|butcher|clothes|electronics|florist|supermarket)
      TAG_KEY="shop"
      TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
      ;;
    lawyer|estate_agent|company|accountant|architect|engineer|it)
      TAG_KEY="office"
      TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
      ;;
    *)
      TAG_KEY="amenity"
      TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
      ;;
  esac
else
  TAG_VALUE="${TAG_VALUE:-$CATEGORY}"
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== gmaps_scraper.sh démarré ==="
  log "INFO" "Recherche : ${TAG_KEY}=${TAG_VALUE} | Ville: ${CITY:-bbox} | Rayon: ${RADIUS}m | Max: $MAX_RESULTS"

  if ! command -v jq &>/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  if ! command -v curl &>/dev/null; then
    log "ERROR" "curl est requis mais non installé."
    exit 1
  fi

  # Résoudre la bounding box
  local bbox
  if [[ -n "$BBOX" ]]; then
    bbox="$BBOX"
    log "INFO" "Bounding box fournie : $bbox"
  else
    if ! bbox=$(resolve_city_coordinates "$CITY" "$RADIUS"); then
      log "ERROR" "Impossible de résoudre les coordonnées de : $CITY"
      exit 1
    fi
    log "INFO" "Bounding box calculée : $bbox"
  fi

  # Délai de politesse
  sleep "$REQUEST_DELAY"

  # Construire la requête Overpass
  local query
  query=$(build_overpass_query "$TAG_KEY" "$TAG_VALUE" "$bbox" "$MAX_RESULTS")
  log "INFO" "Requête Overpass construite"

  # Appel API
  local raw_response
  if ! raw_response=$(call_overpass_api "$query"); then
    log "ERROR" "Échec de l'appel Overpass API"
    exit 1
  fi

  # Parser la réponse
  local leads
  leads=$(parse_overpass_response "$raw_response" "${CITY:-unknown}" "${TAG_KEY}=${TAG_VALUE}")

  # Formater la sortie
  local output
  if [[ "$FORMAT" == "csv" ]]; then
    output=$(convert_to_csv "$leads")
  else
    # JSON avec métadonnées
    output=$(jq -n \
      --argjson leads "$leads" \
      --arg city "${CITY:-}" \
      --arg bbox "$bbox" \
      --arg tag "${TAG_KEY}=${TAG_VALUE}" \
      --argjson radius "$RADIUS" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{
        metadata: {
          extractedAt: $ts,
          city: $city,
          bbox: $bbox,
          tag: $tag,
          radius: $radius,
          totalLeads: ($leads | length),
          withPhone: ($leads | map(select(.telephone != "")) | length),
          withWebsite: ($leads | map(select(.siteWeb != "")) | length),
          withEmail: ($leads | map(select(.email != "")) | length)
        },
        leads: $leads
      }')
  fi

  # Afficher les statistiques
  local total with_phone with_website
  total=$(echo "$leads" | jq 'length')
  with_phone=$(echo "$leads" | jq '[.[] | select(.telephone != "")] | length')
  with_website=$(echo "$leads" | jq '[.[] | select(.siteWeb != "")] | length')

  log "INFO" "📊 Résultats : $total leads | $with_phone avec téléphone | $with_website avec site web"

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$output" > "$OUTPUT_FILE"
    log "INFO" "Résultats sauvegardés dans : $OUTPUT_FILE"
  else
    echo "$output"
  fi

  log "INFO" "=== gmaps_scraper.sh terminé ==="
}

main "$@"
