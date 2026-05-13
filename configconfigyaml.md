<pre><code class="yaml language-yaml"># =============================================================================
# ~/.hermes/config.yaml
# Configuration Hermes Agent — Département Autonome de Prospection LinkedIn
# Provider : nous (OAuth via hermes login)
# Modèle   : Qwen 3.6 Plus (slug à confirmer via `hermes model`)
# =============================================================================

# ─── Modèle LLM ──────────────────────────────────────────────────────────────
model:
  # Slug Qwen 3.6 Plus — vérifier via `hermes model` sur le Nous Portal
  # Alternatives possibles : "qwen/qwen3-6b-plus" | "nous/qwen3-6b-plus"
  default: "qwen/qwen3-6b-plus"
  provider: "nous"                    # Authentification OAuth via `hermes login`
  # provider: "nous-api"              # Alternative : API key via NOUS_API_KEY

# ─── Serveurs MCP ────────────────────────────────────────────────────────────
mcp_servers:

  # Composio MCP — LinkedIn via HTTP
  composio:
    url: "${COMPOSIO_MCP_URL}"        # Ex: https://mcp.composio.dev/linkedin/YOUR_KEY
    headers:
      x-consumer-api-key: "${COMPOSIO_API_KEY}"
    enabled: true
    timeout: 180                      # Timeout opérations longues LinkedIn (secondes)
    connect_timeout: 60               # Timeout connexion initiale (secondes)
    tools:
      resources: true
      prompts: true
    # Outils LinkedIn autorisés (whitelist de sécurité)
    # Décommenter pour restreindre les actions disponibles
    # tools:
    #   include:
    #     - "linkedin_send_message"
    #     - "linkedin_create_post"
    #     - "linkedin_get_profile"

# ─── Terminal ────────────────────────────────────────────────────────────────
terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300

# ─── Mémoire persistante ─────────────────────────────────────────────────────
memory:
  enabled: true
  # La mémoire est stockée dans ~/.hermes/memory/
  # Permet à l'agent de se souvenir des prospects contactés, des conversations, etc.

# ─── Gateway Telegram ────────────────────────────────────────────────────────
# Notifications et rapports quotidiens via Telegram
telegram:
  token: "${TELEGRAM_BOT_TOKEN}"      # Token du bot Telegram
  chat_id: "${TELEGRAM_CHAT_ID}"      # ID du chat de notification

# ─── Configuration des Skills ────────────────────────────────────────────────
skills:
  config:
    bereach:
      api_token: "${BEREACH_TOKEN}"
      base_url: "https://api.bereach.ai"
      max_connections_per_day: 30     # Limite LinkedIn : 30 connexions/jour max
      daily_prospect_target: "${DAILY_PROSPECT_TARGET}"
    google_sheets:
      spreadsheet_id: "${GOOGLE_SPREADSHEET_ID}"
      client_id: "${GOOGLE_CLIENT_ID}"
      client_secret: "${GOOGLE_CLIENT_SECRET}"

# ─── Cron ────────────────────────────────────────────────────────────────────
cron:
  wrap_response: false                # Désactiver le wrapper de réponse par défaut
  # Les tâches cron sont définies dans ~/.hermes/cron/
  # - daily_prospection.yaml  : Lundi-Vendredi 9h
  # - content_schedule.yaml   : Mardi 8h

# ─── Logging ─────────────────────────────────────────────────────────────────
# Les logs sont écrits dans ~/.hermes/logs/
</code></pre>
