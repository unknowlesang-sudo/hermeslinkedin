<pre><code class="markdown language-markdown">---
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

</code></pre>

<p>Vérif compte → Recherche → Préfiltre → Visite profil → Gate entreprise →<br />
Collecte posts → Gate reposts → Collecte reposts → Gate commentaires →<br />
Collecte commentaires → Scoring final → Validation Telegram → Connexion/Message → CRM</p>

<pre><code>
**Limites de sécurité absolues :**
- Max **30 connexions/jour**
- Max **100 messages/jour**
- Délai aléatoire **2–5 secondes** entre chaque action
- Vérifier statut compte BeReach avant chaque run
- Respecter les `retryAfter` retournés par l'API

## Procedure

### Pré-run — Vérification du compte BeReach

Avant tout run, exécuter :
```bash
# Vérifier crédits disponibles
curl -s -H "Authorization: Bearer $BEREACH_TOKEN" \
  https://api.bereach.ai/me/credits

# Vérifier limites du compte
curl -s -H "Authorization: Bearer $BEREACH_TOKEN" \
  https://api.bereach.ai/me/limits

# Vérifier statut du compte LinkedIn connecté
curl -s -H "Authorization: Bearer $BEREACH_TOKEN" \
  https://api.bereach.ai/me/linkedin
</code></pre>

<p><strong>Arrêter si :</strong> crédits &lt; 50 | compte LinkedIn déconnecté | limites atteintes.</p>

<hr />

<h3 id="phase-1-resolution-des-parametres-optionnelle">Phase 1 — Résolution des paramètres (optionnelle)</h3>

<p><strong>Script :</strong> aucun script dédié — appel direct si nécessaire<br />
<strong>Endpoint :</strong> <code>GET /search/linkedin/parameters?type={type}&amp;keywords={keywords}&amp;limit=10</code><br />
<strong>Condition :</strong> Seulement si les filtres ICP sont en format texte (ex: &#8220;Paris") et non en IDs numériques LinkedIn.<br />
<strong>Types :</strong> GEO, COMPANY, INDUSTRY, SCHOOL, CONNECTIONS, PEOPLE<br />
<strong>Output :</strong> Mapper GEO→locationIds, INDUSTRY→industryIds, COMPANY→currentCompanyIds</p>

<hr />

<h3 id="phase-2-recherche-de-personnes">Phase 2 — Recherche de personnes</h3>

<p><strong>Script :</strong> <code>scripts/bereach_search.sh</code></p>

<pre><code class="bash language-bash">./scripts/bereach_search.sh \
  --title "Directeur Commercial" \
  --location "France" \
  --industry "Software" \
  --count 50
</code></pre>

<p><strong>Endpoint :</strong> <code>POST /search/linkedin/people</code><br />
<strong>Règles :</strong></p>

<ul>
<li>count max = 50 (globalRule: maxSearchCount)</li>
<li>connectionDegree : F (1er), S (2ème), O (hors réseau)</li>
<li>Stocker tous les résultats avec audit trail</li>
</ul>

<hr />

<h3 id="phase-3-prefiltre-local-sans-appel-api">Phase 3 — Préfiltre local (sans appel API)</h3>

<p>Pour chaque prospect retourné, appliquer les filtres locaux :</p>

<p><strong>Rejeter si :</strong></p>

<ul>
<li>URL LinkedIn manquante (<code>MISSING_LINKEDIN_URL</code>)</li>
<li>Déjà dans les connexions actives (<code>DUPLICATE_ACTIVE</code>)</li>
<li>Refusé récemment &lt; 30 jours (<code>DUPLICATE_RECENTLY_REFUSED</code>)</li>
<li>Titre dans la liste d&#8217;exclusion (<code>EXCLUDED_TITLE</code>)</li>
<li>Localisation hors cible (<code>OUT_OF_TARGET_LOCATION</code>)</li>
<li>Clairement hors ICP (<code>CLEARLY_NOT_ICP</code>)</li>
</ul>

<p><strong>Passer si :</strong></p>

<ul>
<li>Titre compatible ICP (<code>TITLE_COMPATIBLE</code>)</li>
<li>Localisation compatible (<code>LOCATION_COMPATIBLE</code>)</li>
<li>Ambigu mais potentiel (<code>AMBIGUOUS_BUT_POTENTIAL</code>)</li>
</ul>

<p>Charger la liste de déduplication depuis Google Sheets (onglet CRM, colonne URL LinkedIn).</p>

<hr />

<h3 id="phase-4-visite-du-profil">Phase 4 — Visite du profil</h3>

<p><strong>Script :</strong> intégré dans le workflow principal<br />
<strong>Endpoint :</strong> <code>POST /visit/linkedin/profile</code></p>

<pre><code class="json language-json">{
  "profile": "&lt;profileUrl&gt;",
  "includeAbout": true,
  "includePosts": false,
  "includeComments": false
}
</code></pre>

<p><strong>Si batch ≥ 10 profils :</strong> utiliser <code>POST /visit/linkedin/profile/bulk</code> puis polling <code>GET /visit/linkedin/profile/bulk/{batchId}</code>.</p>

<p><strong>Extraire :</strong> firstName, lastName, headline, summary, location, company, position (isCurrent=true), currentCompanyUrl, connectionsCount, followersCount, pendingConnection.</p>

<p><strong>⚠️ Ne pas utiliser <code>lastPosts</code> comme source d&#8217;activité principale.</strong></p>

<hr />

<h3 id="phase-5-gate-entreprise-decision">Phase 5 — Gate entreprise (décision)</h3>

<p>Appeler l&#8217;API entreprise <strong>seulement si TOUS ces critères sont vrais :</strong></p>

<ul>
<li><code>companySizeIsHardFilter = true</code> OU <code>targetCompanySize</code> défini dans l&#8217;ICP</li>
<li><code>currentCompanyUrl</code> existe dans le profil</li>
<li>Taille de l&#8217;entreprise non déjà connue</li>
</ul>

<p><strong>Sinon :</strong> passer directement à la Phase 7.</p>

<hr />

<h3 id="phase-6-visite-de-lentreprise-si-gate-true">Phase 6 — Visite de l&#8217;entreprise (si gate = true)</h3>

<p><strong>Endpoint :</strong> <code>POST /visit/linkedin/company</code></p>

<pre><code class="json language-json">{ "companyUrl": "&lt;currentCompanyUrl&gt;" }
</code></pre>

<p>Comparer <code>employeeCount</code> avec <code>targetCompanySize</code> de l&#8217;ICP.<br />
Si hors range → <code>nextRecommendedStep = REFUSE</code>, reason = <code>COMPANY_SIZE_OUT_OF_RANGE</code> → passer à Phase 12.</p>

<hr />

<h3 id="phase-7-collecte-des-posts-originaux">Phase 7 — Collecte des posts originaux</h3>

<p><strong>Endpoint :</strong> <code>POST /collect/linkedin/posts</code></p>

<pre><code class="json language-json">{
  "profileUrl": "&lt;profileUrl&gt;",
  "count": 20,
  "start": 0,
  "returnReposts": false
}
</code></pre>

<p>Garder seulement les posts des <strong>45 derniers jours</strong> (globalRule: postsWindowDays=45).<br />
Exclure les reposts → <code>originalPosts45d[]</code>.</p>

<p><strong>Signaux d&#8217;intention à extraire :</strong></p>

<ul>
<li><code>explicit_pain</code> : mentionne un problème explicite</li>
<li><code>seeking_solution</code> : cherche une solution</li>
<li><code>active_project</code> : projet en cours</li>
<li><code>tool_change</code> : changement d&#8217;outil</li>
<li><code>competitor_mention</code> : mentionne un concurrent</li>
<li><code>hiring_signal</code> : recrutement en cours</li>
<li><code>growth_or_launch_signal</code> : croissance ou lancement</li>
</ul>

<hr />

<h3 id="phase-8-gate-reposts-decision">Phase 8 — Gate reposts (décision)</h3>

<p>Appeler la collecte de reposts <strong>seulement si</strong> <code>originalPosts45d.length == 0</code>.<br />
Si des posts originaux existent → passer directement à Phase 10.</p>

<hr />

<h3 id="phase-9-collecte-des-reposts-si-gate-true">Phase 9 — Collecte des reposts (si gate = true)</h3>

<p><strong>Endpoint :</strong> <code>POST /collect/linkedin/posts</code></p>

<pre><code class="json language-json">{
  "profileUrl": "&lt;profileUrl&gt;",
  "count": 20,
  "start": 0,
  "returnReposts": true
}
</code></pre>

<p>Garder 45 derniers jours, reposts uniquement → <code>reposts45d[]</code>.<br />
Signal strength = medium_or_low. Ne pas traiter comme intention directe.</p>

<hr />

<h3 id="phase-10-gate-commentaires-decision">Phase 10 — Gate commentaires (décision)</h3>

<p>Sélectionner max <strong>3 posts</strong> où :</p>

<ul>
<li>Date dans les 45 derniers jours</li>
<li><code>commentsCount &gt; 0</code></li>
<li>Utile pour scoring/personnalisation</li>
</ul>

<p>Priorité : <code>originalPosts45d</code> → <code>reposts45d</code>.<br />
Si aucun post sélectionné → passer à Phase 12.</p>

<hr />

<h3 id="phase-11-collecte-des-commentaires">Phase 11 — Collecte des commentaires</h3>

<p><strong>Endpoint :</strong> <code>POST /collect/linkedin/comments</code></p>

<pre><code class="json language-json">{
  "postUrl": "&lt;selectedPost.postUrl&gt;",
  "start": 0,
  "count": 50
}
</code></pre>

<p>Prioriser : <code>isPostAuthor=true</code> ou <code>hasReplyFromPostAuthor=true</code>.<br />
<strong>⚠️ Ne pas traiter comme tous les commentaires du prospect.</strong></p>

<hr />

<h3 id="phase-12-scoring-final-et-decision">Phase 12 — Scoring final et décision</h3>

<p><strong>dataQuality :</strong></p>

<ul>
<li><code>HIGH</code> : profil complet + company (si hard filter) + originalPosts45d &gt; 0</li>
<li><code>MEDIUM</code> : profil + company non-bloquant + activité faible</li>
<li><code>LOW</code> : profil incomplet ou company manquante ou aucune activité</li>
</ul>

<p><strong>nextRecommendedStep :</strong></p>

<ul>
<li><code>QUALIFY</code> → envoyer demande de connexion (script: <code>bereach_connect.sh</code>)</li>
<li><code>NURTURE</code> → envoyer message de suivi (script: <code>bereach_message_draft.sh</code> + <code>telegram_validation.sh</code>)</li>
<li><code>REFUSE</code> → logger comme refusé dans CRM</li>
<li><code>REVIEW</code> → mettre en attente pour revue manuelle</li>
<li><code>WAIT_RETRY_AFTER</code> → respecter le délai retryAfter</li>
<li><code>BUDGET_EXCEEDED</code> → arrêter le run</li>
<li><code>ERROR</code> → logger l&#8217;erreur et continuer</li>
</ul>

<hr />

<h3 id="post-phase-connexion-et-message">Post-Phase — Connexion et message</h3>

<p><strong>Si QUALIFY :</strong></p>

<pre><code class="bash language-bash">./scripts/bereach_connect.sh --profile-url "&lt;url&gt;" --profile-data "&lt;json&gt;"
</code></pre>

<p><strong>Si NURTURE (connexion déjà acceptée) :</strong></p>

<pre><code class="bash language-bash"># Générer le brouillon
DRAFT=$(./scripts/bereach_message_draft.sh --profile-data "&lt;json&gt;")

# Valider via Telegram
DECISION=$(./scripts/telegram_validation.sh \
  --message-draft "$DRAFT" \
  --prospect-name "&lt;nom&gt;" \
  --prospect-url "&lt;url&gt;")

# Si approuvé : envoyer
if [ "$DECISION" = "approved" ]; then
  curl -s -X POST https://api.bereach.ai/message/linkedin \
    -H "Authorization: Bearer $BEREACH_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"profile\": \"&lt;url&gt;\", \"message\": $DRAFT}"
fi
</code></pre>

<p><strong>Synchroniser dans CRM :</strong></p>

<pre><code class="bash language-bash">./scripts/gsheet_sync.sh --action upsert --prospect-data "&lt;json&gt;"
</code></pre>

<h2 id="pitfalls">Pitfalls</h2>

<ul>
<li><strong>Ne jamais dépasser 30 connexions/jour</strong> : risque de restriction du compte LinkedIn</li>
<li><strong>Toujours respecter retryAfter</strong> : ignorer = ban API</li>
<li><strong>Ne pas utiliser lastPosts</strong> comme source d&#8217;activité (règle globalRule explicite)</li>
<li><strong>Ne pas collecter les commentaires sur tous les posts</strong> : max 3 posts sélectionnés</li>
<li><strong>Vérifier les crédits avant chaque run</strong> : <code>GET /me/credits</code></li>
<li><strong>Délai aléatoire obligatoire</strong> entre chaque action (2–5 secondes)</li>
</ul>

<h2 id="verification">Verification</h2>

<p>Après chaque run :</p>

<ul>
<li>Vérifier le Google Sheets CRM : nouvelles lignes ajoutées</li>
<li>Vérifier les crédits consommés : <code>GET /me/credits</code></li>
<li>Vérifier les invitations envoyées : <code>POST /invitations/linkedin/sent</code></li>
<li>Contrôler les logs dans <code>~/.hermes/logs/linkedin-prospection/</code><br />
```</li>
</ul>
