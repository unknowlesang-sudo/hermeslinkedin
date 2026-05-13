<pre><code class="yaml language-yaml"># =============================================================================
# cron/daily_prospection.yaml
# Tâche cron Hermes — Prospection LinkedIn quotidienne
# Schedule : Lundi-Vendredi à 9h00 (heure locale)
# Skill    : linkedin-prospection
# =============================================================================

# Métadonnées de la tâche
name: "Prospection LinkedIn Quotidienne"
description: &gt;
  Lance la prospection LinkedIn automatique chaque matin en semaine.
  Identifie, enrichit et contacte 7 prospects qualifiés selon l'ICP défini.

# ─── Schedule ────────────────────────────────────────────────────────────────
# Format cron standard : minute heure jour mois jour_semaine
# 0 9 * * 1-5 = Lundi (1) au Vendredi (5) à 9h00
schedule: "0 9 * * 1-5"

# ─── Skill activé ────────────────────────────────────────────────────────────
skill: linkedin-prospection

# ─── Répertoire de travail ───────────────────────────────────────────────────
workdir: "~/.hermes"

# ─── Livraison des résultats ─────────────────────────────────────────────────
# Envoyer le rapport via Telegram
delivery: "telegram"

# ─── Prompt de la tâche ──────────────────────────────────────────────────────
prompt: |
  Tu es un SDR IA expert en prospection LinkedIn B2B. Lance la prospection quotidienne.

  ## Objectif du jour
  Identifier, enrichir et contacter **${DAILY_PROSPECT_TARGET:-7} prospects qualifiés** 
  correspondant à l'ICP défini dans la variable ICP_DESCRIPTION.

  ## ICP (Ideal Customer Profile)
  ${ICP_DESCRIPTION}

  ## Offre à promouvoir
  ${OFFER_DESCRIPTION}

  ## Workflow à exécuter (dans l'ordre)

  ### Étape 1 — Vérification des crédits
  Appelle `get_credits` pour vérifier le solde BeReach disponible.
  Si crédits &lt; 50, envoie une alerte Telegram et arrête.

  ### Étape 2 — Recherche de prospects
  Utilise `search_people` avec les critères ICP :
  - title: requête booléenne basée sur ICP_DESCRIPTION
  - connectionDegree: ["S", "O"] (2ème et 3ème degré uniquement)
  - profileLanguage: ["fr"]
  - count: 20 (pour avoir de la marge après filtrage)
  - start: 0

  ### Étape 3 — Déduplication et pré-filtrage
  Pour chaque prospect trouvé :
  - Vérifie qu'il n'a pas déjà été contacté (mémoire Hermes)
  - Vérifie que le titre correspond à l'ICP
  - Vérifie la localisation (France prioritaire)
  - Rejette si titre exclu ou hors cible évidente
  Garde les 10-15 meilleurs candidats pour enrichissement.

  ### Étape 4 — Enrichissement des profils
  Pour chaque candidat retenu, appelle `visit_profile` :
  - profile: URL du profil LinkedIn
  - includeAbout: true
  Extrais : poste actuel, entreprise, résumé, email si disponible.
  Respecte un délai de 2-5 secondes entre chaque visite.

  ### Étape 5 — Analyse de l'activité récente
  Pour chaque profil enrichi, appelle `collect_posts` :
  - profileUrl: URL du profil
  - count: 20
  - returnReposts: false
  Filtre les posts des 45 derniers jours.
  Identifie les signaux d'intention :
  🔥 HAUTE : douleur explicite, recherche de solution, changement d'outil
  🟡 MOYENNE : projet actif, mention concurrent, signal recrutement
  🟢 BASSE : signal croissance ou lancement

  ### Étape 6 — Scoring et sélection finale
  Score chaque prospect de 1 à 10 selon :
  - Correspondance ICP (titre, secteur, taille entreprise) : 0-4 pts
  - Signaux d'intention détectés : 0-4 pts
  - Activité LinkedIn récente (posts dans 45j) : 0-2 pts
  Sélectionne les **${DAILY_PROSPECT_TARGET:-7} meilleurs scores**.

  ### Étape 7 — Rédaction des messages personnalisés
  Pour chaque prospect sélectionné, rédige un message de connexion :
  - 2-3 phrases maximum (300 caractères max)
  - Mentionner un élément SPÉCIFIQUE du profil ou d'un post récent
  - Ton professionnel et chaleureux, jamais robotique
  - Ne PAS pitcher le produit directement
  - Terminer par une question ouverte ou une observation pertinente

  Exemple de structure :
  "Bonjour [Prénom], j'ai lu votre post sur [sujet spécifique] — [observation pertinente]. 
  Je travaille sur [lien avec leur problématique]. Échangeons ?"

  ### Étape 8 — Envoi des demandes de connexion
  Pour chaque prospect, appelle `send_connection` :
  - profile: URL du profil
  - message: message personnalisé rédigé à l'étape 7
  LIMITE STRICTE : maximum 30 connexions/jour sur LinkedIn.
  Respecte un délai de 3-5 secondes entre chaque envoi.
  Arrête immédiatement si la limite quotidienne est atteinte.

  ### Étape 9 — Enregistrement dans Google Sheets
  Pour chaque prospect contacté, enregistre dans le spreadsheet ${GOOGLE_SPREADSHEET_ID} :
  - Date du contact
  - Nom complet
  - Poste et entreprise
  - URL du profil LinkedIn
  - Score ICP (1-10)
  - Signaux d'intention détectés
  - Message envoyé
  - Statut : "Connexion envoyée"

  ### Étape 10 — Rapport final Telegram
  Envoie un rapport structuré :

  📊 Rapport Prospection LinkedIn — {date_du_jour}

  ✅ Prospects contactés : {n}/{DAILY_PROSPECT_TARGET}
  🔍 Profils analysés : {n}
  💬 Connexions envoyées : {n}

  🏆 Top prospect du jour :
    • {nom} — {poste} @ {entreprise}
    • Signal : {signal_intention}
    • Score ICP : {score}/10

  💳 Crédits BeReach utilisés : {n}
  ⚠️ Alertes : {alertes_ou_"Aucune"}

  ## Règles de sécurité OBLIGATOIRES
  - Ne jamais dépasser 30 connexions/jour
  - Toujours respecter le retryAfter retourné par l'API
  - En cas d'erreur 401/403 : alerter Telegram immédiatement et arrêter
  - En cas d'erreur 429 : attendre retryAfter secondes avant de continuer
  - Mémoriser tous les prospects contactés pour éviter les doublons futurs
</code></pre>
