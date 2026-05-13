<pre><code class="bash language-bash">#!/bin/bash
# =============================================================================
# telegram_validation.sh — Validation humaine via Telegram (boutons inline)
# Envoie un message de prospection draft sur Telegram avec boutons :
#   ✅ Approuver / ✏️ Modifier / ❌ Rejeter
# Attend la réponse via long-polling de l'API Telegram.
# Retourne la décision : approved | modified | rejected
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

: "${TELEGRAM_BOT_TOKEN:?Erreur : TELEGRAM_BOT_TOKEN non défini dans .env}"
: "${TELEGRAM_CHAT_ID:?Erreur : TELEGRAM_CHAT_ID non défini dans .env}"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}"
POLL_TIMEOUT=300        # Timeout long-polling en secondes (5 min)
POLL_INTERVAL=3         # Intervalle entre les polls en secondes
MAX_WAIT_SECONDS=600    # Attente max totale (10 min)
LOG_DIR="${HOME}/.hermes/logs/linkedin-prospection"
LOG_FILE="${LOG_DIR}/telegram_validation_$(date +%Y%m%d).log"
OFFSET_FILE="${HOME}/.hermes/cache/telegram_offset"

mkdir -p "$LOG_DIR" "$(dirname "$OFFSET_FILE")"

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

Envoie un message draft sur Telegram pour validation humaine.
Attend la réponse via boutons inline (✅ Approuver / ✏️ Modifier / ❌ Rejeter).

OPTIONS:
  --message-draft   JSON    Brouillon du message (JSON avec champ "message")
                            Ou texte brut du message
  --prospect-name   NOM     Nom du prospect (pour l'affichage)
  --prospect-url    URL     URL LinkedIn du prospect
  --timeout         N       Timeout d'attente en secondes (défaut: 600)
  --output          FICHIER Fichier de sortie JSON (défaut: stdout)
  -h, --help                Afficher cette aide

RETOUR (JSON):
  {
    "decision": "approved|modified|rejected",
    "finalMessage": "...",    // message final (modifié si applicable)
    "respondedAt": "...",
    "waitSeconds": N
  }

EXEMPLES:
  $(basename "$0") --message-draft '{"message":"Bonjour..."}' --prospect-name "Marie" --prospect-url "https://linkedin.com/in/marie"
  $(basename "$0") --message-draft "Bonjour Marie..." --prospect-name "Marie" --prospect-url "https://linkedin.com/in/marie"
EOF
  exit 0
}

# -----------------------------------------------------------------------------
# Lire l'offset Telegram (pour éviter de retraiter les anciens messages)
# -----------------------------------------------------------------------------
get_offset() {
  if [[ -f "$OFFSET_FILE" ]]; then
    cat "$OFFSET_FILE"
  else
    echo "0"
  fi
}

save_offset() {
  echo "$1" &gt; "$OFFSET_FILE"
}

# -----------------------------------------------------------------------------
# Envoyer un message Telegram avec boutons inline
# -----------------------------------------------------------------------------
send_telegram_message() {
  local text="$1"
  local callback_prefix="$2"  # Préfixe unique pour identifier cette session

  # Construire le clavier inline
  local keyboard
  keyboard=$(jq -n \
    --arg approve "${callback_prefix}_approve" \
    --arg modify "${callback_prefix}_modify" \
    --arg reject "${callback_prefix}_reject" \
    '{
      inline_keyboard: [
        [
          {text: "✅ Approuver", callback_data: $approve},
          {text: "✏️ Modifier", callback_data: $modify},
          {text: "❌ Rejeter", callback_data: $reject}
        ]
      ]
    }')

  local response
  response=$(curl -s -X POST \
    "${TELEGRAM_API}/sendMessage" \
    -H "Content-Type: application/json" \
    --data "$(jq -n \
      --arg chat_id "$TELEGRAM_CHAT_ID" \
      --arg text "$text" \
      --argjson keyboard "$keyboard" \
      '{
        chat_id: $chat_id,
        text: $text,
        parse_mode: "HTML",
        reply_markup: $keyboard
      }')" \
    --max-time 15 2&gt;&amp;1)

  # Extraire le message_id pour référence
  local message_id
  message_id=$(echo "$response" | jq -r '.result.message_id // ""' 2&gt;/dev/null || echo "")

  if [[ -z "$message_id" ]]; then
    log "ERROR" "Échec envoi message Telegram : $response"
    return 1
  fi

  log "INFO" "Message Telegram envoyé (message_id: $message_id)"
  echo "$message_id"
}

# -----------------------------------------------------------------------------
# Construire le texte du message Telegram
# -----------------------------------------------------------------------------
build_telegram_text() {
  local message_draft="$1"
  local prospect_name="$2"
  local prospect_url="$3"
  local message_text="$4"
  local message_length="${#message_text}"

  cat &lt;&lt;EOF
🔔 &lt;b&gt;Validation message LinkedIn&lt;/b&gt;

👤 &lt;b&gt;Prospect :&lt;/b&gt; ${prospect_name}
🔗 &lt;b&gt;Profil :&lt;/b&gt; ${prospect_url}
📏 &lt;b&gt;Longueur :&lt;/b&gt; ${message_length}/300 chars

📝 &lt;b&gt;Message à envoyer :&lt;/b&gt;
&lt;i&gt;${message_text}&lt;/i&gt;

━━━━━━━━━━━━━━━━━━━━
Que souhaitez-vous faire ?
EOF
}

# -----------------------------------------------------------------------------
# Polling Telegram pour attendre la réponse
# -----------------------------------------------------------------------------
poll_for_response() {
  local callback_prefix="$1"
  local start_time
  start_time=$(date +%s)
  local offset
  offset=$(get_offset)

  log "INFO" "Démarrage du polling Telegram (timeout: ${MAX_WAIT_SECONDS}s)..."

  while true; do
    local current_time
    current_time=$(date +%s)
    local elapsed=$(( current_time - start_time ))

    if [[ $elapsed -ge $MAX_WAIT_SECONDS ]]; then
      log "WARN" "Timeout atteint (${MAX_WAIT_SECONDS}s) — aucune réponse reçue"
      echo "timeout"
      return 1
    fi

    # Appel getUpdates avec long-polling
    local updates
    updates=$(curl -s \
      "${TELEGRAM_API}/getUpdates?offset=${offset}&amp;timeout=${POLL_TIMEOUT}&amp;allowed_updates=[\"callback_query\"]" \
      --max-time $(( POLL_TIMEOUT + 5 )) 2&gt;&amp;1)

    if ! echo "$updates" | jq -e '.ok' &amp;&gt;/dev/null; then
      log "WARN" "Erreur getUpdates : $updates"
      sleep "$POLL_INTERVAL"
      continue
    fi

    # Traiter chaque update
    local update_count
    update_count=$(echo "$updates" | jq '.result | length' 2&gt;/dev/null || echo "0")

    if [[ "$update_count" -gt 0 ]]; then
      # Mettre à jour l'offset
      local last_update_id
      last_update_id=$(echo "$updates" | jq '.result[-1].update_id' 2&gt;/dev/null || echo "$offset")
      save_offset $(( last_update_id + 1 ))
      offset=$(( last_update_id + 1 ))

      # Chercher un callback_query correspondant à notre session
      local matching_callback
      matching_callback=$(echo "$updates" | jq -r \
        --arg prefix "$callback_prefix" \
        '.result[] |
          select(.callback_query != null) |
          select(.callback_query.data | startswith($prefix)) |
          .callback_query.data' 2&gt;/dev/null | head -1)

      if [[ -n "$matching_callback" ]]; then
        log "INFO" "Réponse reçue : $matching_callback"

        # Extraire la décision
        if [[ "$matching_callback" == *"_approve" ]]; then
          echo "approved"
          return 0
        elif [[ "$matching_callback" == *"_modify" ]]; then
          echo "modify"
          return 0
        elif [[ "$matching_callback" == *"_reject" ]]; then
          echo "rejected"
          return 0
        fi
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

# -----------------------------------------------------------------------------
# Demander la modification du message
# -----------------------------------------------------------------------------
request_modification() {
  local original_message="$1"
  local prospect_name="$2"

  local mod_text
  mod_text=$(cat &lt;&lt;EOF
✏️ &lt;b&gt;Modification demandée&lt;/b&gt;

Prospect : ${prospect_name}

Message original :
&lt;i&gt;${original_message}&lt;/i&gt;

Répondez à ce message avec le nouveau texte (max 300 chars).
EOF
)

  # Envoyer le message de demande de modification
  curl -s -X POST \
    "${TELEGRAM_API}/sendMessage" \
    -H "Content-Type: application/json" \
    --data "$(jq -n \
      --arg chat_id "$TELEGRAM_CHAT_ID" \
      --arg text "$mod_text" \
      '{
        chat_id: $chat_id,
        text: $text,
        parse_mode: "HTML",
        reply_markup: {force_reply: true, selective: false}
      }')" \
    --max-time 15 &amp;&gt;/dev/null

  log "INFO" "Demande de modification envoyée — attente de la réponse..."

  # Attendre la réponse texte
  local start_time
  start_time=$(date +%s)
  local offset
  offset=$(get_offset)

  while true; do
    local elapsed=$(( $(date +%s) - start_time ))
    [[ $elapsed -ge $MAX_WAIT_SECONDS ]] &amp;&amp; { echo "$original_message"; return 1; }

    local updates
    updates=$(curl -s \
      "${TELEGRAM_API}/getUpdates?offset=${offset}&amp;timeout=30&amp;allowed_updates=[\"message\"]" \
      --max-time 35 2&gt;&amp;1)

    local update_count
    update_count=$(echo "$updates" | jq '.result | length' 2&gt;/dev/null || echo "0")

    if [[ "$update_count" -gt 0 ]]; then
      local last_update_id
      last_update_id=$(echo "$updates" | jq '.result[-1].update_id' 2&gt;/dev/null || echo "$offset")
      save_offset $(( last_update_id + 1 ))
      offset=$(( last_update_id + 1 ))

      # Chercher un message texte (la modification)
      local new_message
      new_message=$(echo "$updates" | jq -r \
        '.result[] |
          select(.message.text != null) |
          select(.message.chat.id | tostring == "'"$TELEGRAM_CHAT_ID"'") |
          .message.text' 2&gt;/dev/null | head -1)

      if [[ -n "$new_message" &amp;&amp; "$new_message" != "null" ]]; then
        # Tronquer si nécessaire
        if [[ ${#new_message} -gt 300 ]]; then
          new_message="${new_message:0:297}..."
        fi
        log "INFO" "Message modifié reçu (${#new_message} chars)"
        echo "$new_message"
        return 0
      fi
    fi

    sleep "$POLL_INTERVAL"
  done
}

# -----------------------------------------------------------------------------
# Parsing des arguments
# -----------------------------------------------------------------------------
MESSAGE_DRAFT=""
PROSPECT_NAME="Prospect"
PROSPECT_URL=""
OUTPUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --message-draft)  MESSAGE_DRAFT="$2";  shift 2 ;;
    --prospect-name)  PROSPECT_NAME="$2";  shift 2 ;;
    --prospect-url)   PROSPECT_URL="$2";   shift 2 ;;
    --timeout)        MAX_WAIT_SECONDS="$2"; shift 2 ;;
    --output)         OUTPUT_FILE="$2";    shift 2 ;;
    -h|--help)        usage ;;
    *)
      log "ERROR" "Argument inconnu : $1"
      usage
      ;;
  esac
done

if [[ -z "$MESSAGE_DRAFT" ]]; then
  log "ERROR" "--message-draft est obligatoire"
  exit 1
fi

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------
main() {
  log "INFO" "=== telegram_validation.sh démarré ==="

  if ! command -v jq &amp;&gt;/dev/null; then
    log "ERROR" "jq est requis mais non installé."
    exit 1
  fi

  # Extraire le texte du message (JSON ou texte brut)
  local message_text
  if echo "$MESSAGE_DRAFT" | jq -e '.message' &amp;&gt;/dev/null 2&gt;&amp;1; then
    message_text=$(echo "$MESSAGE_DRAFT" | jq -r '.message')
  else
    message_text="$MESSAGE_DRAFT"
  fi

  log "INFO" "Prospect : $PROSPECT_NAME | Message (${#message_text} chars)"

  # Générer un préfixe unique pour cette session
  local session_id
  session_id="val_$(date +%s)_$$"

  # Construire le texte Telegram
  local telegram_text
  telegram_text=$(build_telegram_text "$MESSAGE_DRAFT" "$PROSPECT_NAME" "$PROSPECT_URL" "$message_text")

  # Envoyer le message Telegram
  local message_id
  if ! message_id=$(send_telegram_message "$telegram_text" "$session_id"); then
    log "ERROR" "Impossible d'envoyer le message Telegram"
    exit 1
  fi

  local start_time
  start_time=$(date +%s)

  # Attendre la décision
  local decision
  decision=$(poll_for_response "$session_id")
  local poll_exit=$?

  local end_time
  end_time=$(date +%s)
  local wait_seconds=$(( end_time - start_time ))

  local final_message="$message_text"

  # Traiter la décision
  case "$decision" in
    approved)
      log "INFO" "✅ Message approuvé par l'humain"
      ;;
    modify)
      log "INFO" "✏️ Modification demandée — attente du nouveau texte..."
      final_message=$(request_modification "$message_text" "$PROSPECT_NAME")
      decision="modified"
      log "INFO" "Message modifié : $final_message"
      ;;
    rejected)
      log "INFO" "❌ Message rejeté par l'humain"
      ;;
    timeout)
      log "WARN" "⏰ Timeout — aucune réponse après ${MAX_WAIT_SECONDS}s"
      decision="timeout"
      ;;
  esac

  # Construire le JSON de sortie
  local result
  result=$(jq -n \
    --arg decision "$decision" \
    --arg final_message "$final_message" \
    --arg original_message "$message_text" \
    --arg prospect_name "$PROSPECT_NAME" \
    --arg prospect_url "$PROSPECT_URL" \
    --argjson wait_seconds "$wait_seconds" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{
      decision: $decision,
      finalMessage: $final_message,
      originalMessage: $original_message,
      prospectName: $prospect_name,
      prospectUrl: $prospect_url,
      respondedAt: $ts,
      waitSeconds: $wait_seconds
    }')

  # Sortie
  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "$result" &gt; "$OUTPUT_FILE"
    log "INFO" "Résultat sauvegardé dans : $OUTPUT_FILE"
  else
    echo "$result"
  fi

  log "INFO" "=== telegram_validation.sh terminé (décision: $decision) ==="
}

main "$@"
</code></pre>
