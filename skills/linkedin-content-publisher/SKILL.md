---
name: linkedin-content-publisher
description: Génère et publie des posts LinkedIn B2B professionnels — reçoit un brief, rédige un post optimisé (hook, corps, CTA, hashtags), soumet à validation humaine via Telegram, publie via Composio MCP et logue dans Google Sheets.
version: 1.0.0
author: hermes-business-agents
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [LinkedIn, Content, Publishing, B2B]
    related_skills: [linkedin-prospection]
    requires_toolsets: [mcp]
    requires_tools: [mcp_composio_linkedin_publishPost]
required_environment_variables:
  - name: TELEGRAM_BOT_TOKEN
    prompt: "Token du bot Telegram (BotFather)"
    help: "Créer un bot via @BotFather sur Telegram"
    required_for: "Validation humaine des posts"
  - name: TELEGRAM_CHAT_ID
    prompt: "Chat ID Telegram pour les notifications"
    help: "Obtenir via @userinfobot"
    required_for: "Envoi des messages de validation"
  - name: GOOGLE_SHEETS_ID
    prompt: "ID du Google Sheets CRM"
    help: "Visible dans l'URL du spreadsheet"
    required_for: "Logging des publications"
required_credential_files:
  - path: google_sheets/token.json
    description: Token OAuth2 Google Sheets
---

# LinkedIn Content Publisher

Agent de publication de contenu LinkedIn B2B. Transforme un brief en post professionnel optimisé, valide avec l'humain via Telegram, publie et logue automatiquement.

## When to Use

- Quand tu reçois un brief ou une idée de post LinkedIn
- Quand tu dois publier du contenu B2B régulier sur LinkedIn
- Quand tu veux maintenir une présence LinkedIn active avec validation humaine

## Quick Reference

