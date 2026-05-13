---
name: linkedin-prospection
description: Orchestre la prospection LinkedIn automatisée B2B via BeReach API — implémente fidèlement les 12 phases du workflow d'acquisition (recherche, préfiltre, enrichissement profil/entreprise, analyse activité, scoring) avec validation humaine Telegram et CRM Google Sheets. Max 5–10 prospects/jour qualifiés.
version: 1.0.0
author: hermes-business-agents
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [LinkedIn, Prospection, BeReach, B2B, Automation]
    related_skills: [linkedin-content-publisher, google-maps-prospection]
    requires_tools: [bash]
required_environment_variables:
  - name: BEREACH_TOKEN
    prompt: "Token API BeReach (format: brc_xxxxx)"
    help: "Obtenir sur https://app.bereach.ai/settings/api"
    required_for: "Tous les appels API BeReach"
  - name: TELEGRAM_BOT_TOKEN
    prompt: "Token du bot Telegram"
    help: "Créer via @BotFather"
    required_for: "Validation humaine des messages"
  - name: TELEGRAM_CHAT_ID
    prompt: "Chat ID Telegram"
    help: "Obtenir via @userinfobot"
    required_for: "Envoi des validations"
  - name: GOOGLE_SHEETS_ID
    prompt: "ID du Google Sheets CRM"
    help: "Visible dans l'URL du spreadsheet"
    required_for: "CRM et déduplication"
  - name: ICP_DESCRIPTION
    prompt: "Description de votre ICP (Ideal Customer Profile)"
    help: "Ex: 'Directeurs commerciaux PME 50-200 salariés secteur SaaS France'"
    required_for: "Filtrage et personnalisation des messages"
  - name: OFFER_DESCRIPTION
    prompt: "Description courte de votre offre"
    help: "Ex: 'Automatisation de la prospection LinkedIn pour équipes commerciales'"
    required_for: "Personnalisation des messages de prospection"
required_credential_files:
  - path: google_sheets/token.json
    description: Token OAuth2 Google Sheets
---

# LinkedIn Prospection — Workflow 12 Phases BeReach

Agent de prospection LinkedIn automatisée. Implémente fidèlement le workflow `bereach_linkedin_acquisition_phase_1_to_2b` en 12 phases, de la recherche de prospects jusqu'à l'envoi de messages validés par l'humain.

## When to Use

- Lancer une session de prospection LinkedIn quotidienne (5–10 prospects)
- Enrichir et scorer des profils LinkedIn selon l'ICP
- Envoyer des demandes de connexion et messages de suivi personnalisés
- Synchroniser les prospects dans le CRM Google Sheets

## Quick Reference

