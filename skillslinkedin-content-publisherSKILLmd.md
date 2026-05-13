<pre><code class="markdown language-markdown">---
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

</code></pre>

<p>Brief → Génération post → Validation Telegram → Publication Composio → Log Sheets</p>

<pre><code>
**Contraintes post LinkedIn B2B :**
- 1200–1500 caractères (zone optimale d'engagement)
- Pas de liens dans le corps du post (pénalise la portée)
- Hook percutant sur la 1ère ligne (visible avant "voir plus")
- Structure : Hook → Problème/Contexte → Solution/Insight → CTA → Hashtags
- Max 5 hashtags pertinents
- Ton professionnel mais humain, pas corporate

## Procedure

### Étape 1 — Réception du brief

Extraire du brief :
- **Sujet principal** : thème ou angle du post
- **Audience cible** : qui doit être touché (ex: DRH, CEO PME, etc.)
- **Objectif** : notoriété / génération de leads / engagement / recrutement
- **Ton souhaité** : inspirant / éducatif / provocateur / storytelling
- **Éléments clés** : chiffres, anecdotes, insights à inclure

Si le brief est incomplet, demander les éléments manquants avant de rédiger.

### Étape 2 — Génération du post LinkedIn B2B

Rédiger un post respectant cette structure :

**HOOK (1–2 lignes)** — Accroche qui stoppe le scroll :
- Question provocatrice, stat surprenante, ou affirmation contre-intuitive
- Doit créer de la curiosité ou de l'identification
- Exemples : "95% des commerciaux font cette erreur." / "J'ai perdu 3 clients en 1 semaine. Voici pourquoi."

**CORPS (8–12 lignes)** — Développement :
- Paragraphes courts (1–3 lignes max)
- Sauts de ligne entre chaque idée
- Progression logique : contexte → problème → solution/insight
- Chiffres concrets si disponibles
- Pas de jargon inutile

**CTA (1–2 lignes)** — Appel à l'action :
- Question ouverte pour générer des commentaires
- Ou invitation à partager / sauvegarder
- Exemples : "Et toi, comment tu gères ça ?" / "Sauvegarde ce post si tu veux y revenir."

**HASHTAGS (ligne finale)** :
- 3–5 hashtags pertinents
- Mix : hashtag large (#LinkedIn) + hashtag niche (#ProspectionB2B)
- Pas de hashtags inventés

**Vérifications avant envoi :**
- [ ] Longueur : 1200–1500 caractères
- [ ] Aucun lien dans le corps
- [ ] Hook sur 1ère ligne
- [ ] Pas plus de 5 hashtags
- [ ] Ton cohérent avec la cible

### Étape 3 — Validation Telegram

Envoyer le post draft via Telegram avec :
- Aperçu du post complet
- Nombre de caractères
- Boutons inline :
  - ✅ **Approuver** → publication immédiate
  - ✏️ **Modifier** → demander les modifications souhaitées
  - ❌ **Rejeter** → annuler la publication

Si **Modifier** : appliquer les retours et renvoyer pour validation.
Si **Rejeter** : logger le refus dans Sheets et terminer.

### Étape 4 — Publication via Composio MCP

Une fois approuvé, appeler l'outil MCP Composio LinkedIn :
</code></pre>

<p>mcp_composio_linkedin_publishPost({<br />
  text: &#8220;<contenu_du_post_approuvé&gt;"<br />
})</p>

<pre><code>
Récupérer l'URL du post publié depuis la réponse.

### Étape 5 — Logging Google Sheets

Ajouter une ligne dans l'onglet **'Publications'** du Google Sheets CRM :

| Colonne | Valeur |
|---------|--------|
| Date | Date/heure de publication (ISO 8601) |
| Sujet | Thème principal du post |
| Audience | Cible visée |
| Objectif | Notoriété / Leads / Engagement |
| Caractères | Nombre de caractères |
| Hashtags | Liste des hashtags utilisés |
| URL Post | URL LinkedIn du post publié |
| Statut | Publié / Refusé / En attente |
| Notes | Retours de validation si applicable |

## Pitfalls

- **Ne jamais inclure de liens** dans le corps du post (réduit drastiquement la portée organique)
- **Éviter les posts trop longs** (&gt;1800 chars) : taux de lecture chute
- **Ne pas sur-hashtaguer** : &gt;5 hashtags = signal spam pour l'algorithme
- **Hook générique** = post ignoré : "Bonjour à tous, aujourd'hui je voulais partager..." → à bannir
- **Ton trop corporate** : LinkedIn B2B performant = voix humaine, pas communiqué de presse

## Verification

Après publication :
- Confirmer que l'URL du post est accessible
- Vérifier la ligne dans Google Sheets onglet 'Publications'
- Optionnel : vérifier les analytics 24h après via BeReach `POST /analytics/linkedin/post`
</code></pre>
