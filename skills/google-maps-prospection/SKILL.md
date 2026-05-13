---
name: google-maps-prospection
version: 1.0.0
description: >
  Prospector B2B depuis Google Maps. Recherche des entreprises par secteur et
  géolocalisation via Overpass API / scraping Google Maps, extrait les coordonnées,
  enrichit avec email, exporte dans Google Sheets et rapporte via Telegram.
license: MIT
---

# Google Maps Prospection

Skill de prospection B2B via Google Maps et Overpass API.

## Objectif

Identifier des prospects B2B locaux en extrayant les données d'entreprises depuis Google Maps et OpenStreetMap.

## Workflow

```
Secteur + Ville → Recherche Overpass → Extraction données → Enrichissement email → Export Sheets → Rapport
```

## Scripts

- `scripts/gmaps_scraper.sh` : Extrait les entreprises depuis Google Maps / Overpass
- `scripts/export_leads.sh` : Formate et exporte les leads dans Google Sheets

## Configuration

Variables `.env` requises :

```
GOOGLE_CLIENT_ID=
GOOGLE_CLIENT_SECRET=
GOOGLE_SPREADSHEET_ID=
OVERPASS_ENDPOINT=https://overpass-api.de/api
```

## Limites

- Respecter les limites de requêtes Overpass (pas plus de 1 requête par minute)
- Ne pas scraper Google Maps de manière agressive
- Déduplication obligatoire avant export

## Intégration

Ce skill complète le skill `linkedin-prospection` en fournissant des leads
qui peuvent ensuite être enrichis et contactés via BeReach API.
