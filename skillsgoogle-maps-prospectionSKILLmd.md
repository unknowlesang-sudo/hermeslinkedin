<hr />

<p>name: google-maps-prospection<br />
description: Prospecte des entreprises locales via OpenStreetMap/Overpass API — recherche par secteur et ville, extrait nom/adresse/téléphone/site web, enrichit les emails via web_extract, exporte dans Google Sheets onglet &#8216;Leads Google Maps&#8217; et génère un rapport de synthèse.
version: 1.0.0
author: hermes-business-agents
license: MIT
platforms: [macos, linux]
metadata:
  hermes:
    tags: [Prospection, GoogleMaps, OpenStreetMap, Leads, Local]
    related_skills: [linkedin-prospection, linkedin-content-publisher]<br />
    requires_tools: [web_extract, bash]<br />
required_environment_variables:</p>

<ul>
<li>name: GOOGLE_SHEETS_ID<br />
prompt: &#8220;ID du Google Sheets CRM"<br />
help: &#8220;Visible dans l&#8217;URL du spreadsheet"<br />
required_for: &#8220;Export des leads&#8221;
required_credential_files:</li>
<li>path: google_sheets/token.json</li>
</ul>

<h2 id="description-token-oauth2-google-sheets">    description: Token OAuth2 Google Sheets</h2>

<h1 id="google-maps-prospection">Google Maps Prospection</h1>

<p>Agent de prospection d&#8217;entreprises locales via OpenStreetMap (API Overpass, gratuite, sans clé). Identifie les entreprises par secteur et ville, enrichit les données de contact, et exporte dans le CRM Google Sheets.</p>

<h2 id="when-to-use">When to Use</h2>

<ul>
<li>Prospecter des entreprises locales dans un secteur spécifique</li>
<li>Construire une liste de leads géolocalisés (restaurants, hôtels, commerces, etc.)</li>
<li>Enrichir une base de prospects avec des données de contact locales</li>
<li>Compléter la prospection LinkedIn avec des leads hors-réseau</li>
</ul>

<h2 id="quick-reference">Quick Reference</h2>

<pre><code>Secteur + Ville → Overpass API → Extraction données → Enrichissement email → Export Sheets → Rapport
</code></pre>

<p><strong>API utilisée :</strong> Overpass API (https://overpass-api.de/api/interpreter)</p>

<ul>
<li>Gratuite, sans clé API</li>
<li>Basée sur OpenStreetMap</li>
<li>Limite : requêtes raisonnables (pas de scraping massif)</li>
</ul>

<h2 id="procedure">Procedure</h2>

<h3 id="etape-1-definir-les-criteres-de-recherche">Étape 1 — Définir les critères de recherche</h3>

<p>Paramètres requis :</p>

<ul>
<li><strong>Secteur/catégorie</strong> : type d&#8217;entreprise OSM (ex: restaurant, hotel, shop, office)</li>
<li><strong>Ville</strong> : nom de la ville ou coordonnées GPS</li>
<li><strong>Rayon</strong> : rayon de recherche en mètres (défaut: 5000m)</li>
</ul>

<p>Catégories OSM courantes :</p>

<table>
<thead>
<tr>
  <th>Secteur</th>
  <th>Tag OSM</th>
</tr>
</thead>
<tbody>
<tr>
  <td>Restaurants</td>
  <td><code>amenity=restaurant</code></td>
</tr>
<tr>
  <td>Hôtels</td>
  <td><code>tourism=hotel</code></td>
</tr>
<tr>
  <td>Commerces</td>
  <td><code>shop=*</code></td>
</tr>
<tr>
  <td>Bureaux</td>
  <td><code>office=*</code></td>
</tr>
<tr>
  <td>Médecins</td>
  <td><code>amenity=doctors</code></td>
</tr>
<tr>
  <td>Avocats</td>
  <td><code>office=lawyer</code></td>
</tr>
<tr>
  <td>Agences immo</td>
  <td><code>office=estate_agent</code></td>
</tr>
<tr>
  <td>Garages</td>
  <td><code>shop=car_repair</code></td>
</tr>
<tr>
  <td>Coiffeurs</td>
  <td><code>shop=hairdresser</code></td>
</tr>
</tbody>
</table>

<h3 id="etape-2-scraping-via-overpass-api">Étape 2 — Scraping via Overpass API</h3>

<p><strong>Script :</strong> <code>scripts/gmaps_scraper.sh</code></p>

<pre><code class="bash language-bash">./scripts/gmaps_scraper.sh \
  --category "restaurant" \
  --city "Lyon" \
  --radius 3000 \
  --output leads_raw.json
</code></pre>

<p>L&#8217;API Overpass retourne pour chaque entreprise :</p>

<ul>
<li>Nom (<code>name</code>)</li>
<li>Adresse (<code>addr:street</code>, <code>addr:housenumber</code>, <code>addr:city</code>, <code>addr:postcode</code>)</li>
<li>Téléphone (<code>phone</code>, <code>contact:phone</code>)</li>
<li>Site web (<code>website</code>, <code>contact:website</code>)</li>
<li>Coordonnées GPS (<code>lat</code>, <code>lon</code>)</li>
<li>Tags OSM supplémentaires</li>
</ul>

<h3 id="etape-3-enrichissement-email">Étape 3 — Enrichissement email</h3>

<p>Pour chaque entreprise avec un site web, utiliser <code>web_extract</code> pour :</p>

<ol>
<li>Visiter la page de contact du site</li>
<li>Extraire les adresses email visibles</li>
<li>Chercher des patterns email courants (contact@, info@, etc.)</li>
</ol>

<pre><code>Pour chaque lead avec website:
  → web_extract(website + "/contact")
  → Extraire emails avec regex [a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}
  → Stocker dans le champ "email"
</code></pre>

<p><strong>Limites :</strong> Respecter les robots.txt, ne pas surcharger les serveurs.</p>

<h3 id="etape-4-export-google-sheets">Étape 4 — Export Google Sheets</h3>

<p><strong>Script :</strong> <code>scripts/export_leads.sh</code></p>

<pre><code class="bash language-bash">./scripts/export_leads.sh \
  --input leads_raw.json \
  --sheet-tab "Leads Google Maps"
</code></pre>

<p>Colonnes de l&#8217;onglet <strong>&#8217;Leads Google Maps&#8217;</strong> :</p>

<table>
<thead>
<tr>
  <th>Colonne</th>
  <th>Description</th>
</tr>
</thead>
<tbody>
<tr>
  <td>Date</td>
  <td>Date d&#8217;extraction</td>
</tr>
<tr>
  <td>Nom</td>
  <td>Nom de l&#8217;entreprise</td>
</tr>
<tr>
  <td>Catégorie</td>
  <td>Type d&#8217;entreprise (OSM)</td>
</tr>
<tr>
  <td>Adresse</td>
  <td>Adresse complète</td>
</tr>
<tr>
  <td>Ville</td>
  <td>Ville</td>
</tr>
<tr>
  <td>Code Postal</td>
  <td>CP</td>
</tr>
<tr>
  <td>Téléphone</td>
  <td>Numéro de téléphone</td>
</tr>
<tr>
  <td>Site Web</td>
  <td>URL du site</td>
</tr>
<tr>
  <td>Email</td>
  <td>Email extrait (si trouvé)</td>
</tr>
<tr>
  <td>GPS Lat</td>
  <td>Latitude</td>
</tr>
<tr>
  <td>GPS Lon</td>
  <td>Longitude</td>
</tr>
<tr>
  <td>Statut</td>
  <td>Nouveau / Contacté / Qualifié / Refusé</td>
</tr>
<tr>
  <td>Notes</td>
  <td>Notes libres</td>
</tr>
</tbody>
</table>

<p><strong>Déduplication :</strong> Vérifier avant insertion que le nom + adresse n&#8217;existe pas déjà.</p>

<h3 id="etape-5-rapport-de-synthese">Étape 5 — Rapport de synthèse</h3>

<p>Générer un rapport incluant :</p>

<ul>
<li>Nombre total de leads trouvés</li>
<li>Répartition par catégorie</li>
<li>Taux d&#8217;enrichissement email (% avec email trouvé)</li>
<li>Top 10 des leads les mieux documentés</li>
<li>Leads sans site web (à contacter par téléphone)</li>
<li>Recommandations pour la prochaine session</li>
</ul>

<h2 id="pitfalls">Pitfalls</h2>

<ul>
<li><strong>Overpass API</strong> : éviter les requêtes trop larges (rayon &gt; 50km) — risque de timeout</li>
<li><strong>Déduplication</strong> : toujours vérifier avant d&#8217;exporter pour éviter les doublons</li>
<li><strong>Emails</strong> : ne pas envoyer d&#8217;emails non sollicités sans opt-in — RGPD</li>
<li><strong>Rate limiting</strong> : respecter un délai entre les requêtes d&#8217;enrichissement email</li>
<li><strong>Données OSM</strong> : qualité variable selon les zones — vérifier les données avant contact</li>
</ul>

<h2 id="verification">Verification</h2>

<p>Après export :</p>

<ul>
<li>Vérifier le nombre de lignes dans l&#8217;onglet &#8216;Leads Google Maps&#8217;</li>
<li>Contrôler le taux de déduplication</li>
<li>Vérifier que les coordonnées GPS sont cohérentes avec la ville</li>
<li>Tester quelques numéros de téléphone manuellement</li>
</ul>
