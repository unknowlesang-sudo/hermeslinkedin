<pre><code class="python language-python"># =============================================================================
# tools/bereach_api/bereach_client.py
# Client Python BeReach API — Production Ready
# Basé sur apibereach.json (OpenAPI 3.0.3)
# =============================================================================

import os
import time
import logging
import random
from datetime import datetime, date
from typing import Optional, Any
from dataclasses import dataclass, field

import httpx
import structlog
from tenacity import (
    retry,
    stop_after_attempt,
    wait_exponential,
    retry_if_exception_type,
    before_sleep_log,
)
from dotenv import load_dotenv

# ─── Chargement des variables d'environnement ────────────────────────────────
load_dotenv(os.path.expanduser("~/.hermes/.env"))

# ─── Configuration du logging structuré ─────────────────────────────────────
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger(__name__)

# ─── Constantes ──────────────────────────────────────────────────────────────
BEREACH_BASE_URL = "https://api.bereach.ai"
MAX_CONNECTIONS_PER_DAY = 30       # Limite LinkedIn stricte
MAX_MESSAGES_PER_DAY = 50          # Limite LinkedIn stricte
MAX_VISITS_PER_DAY = 100           # Limite LinkedIn recommandée
MAX_SEARCHES_PER_DAY = 50          # Limite BeReach
MAX_RETRIES = 2                    # Tentatives max par endpoint
MIN_DELAY_BETWEEN_ACTIONS = 2.0    # Secondes minimum entre actions
MAX_DELAY_BETWEEN_ACTIONS = 5.0    # Secondes maximum entre actions


# ─── Exceptions personnalisées ───────────────────────────────────────────────
class BereachError(Exception):
    """Erreur générique BeReach API."""
    pass

class BereachRateLimitError(BereachError):
    """Erreur 429 — Rate limit atteint."""
    def __init__(self, retry_after: int = 60):
        self.retry_after = retry_after
        super().__init__(f"Rate limit atteint. Retry après {retry_after}s.")

class BereachAuthError(BereachError):
    """Erreur 401/403 — Token invalide ou expiré."""
    pass

class BereachBudgetExceededError(BereachError):
    """Budget de crédits dépassé."""
    pass

class BereachDailyLimitError(BereachError):
    """Limite quotidienne d'actions atteinte."""
    pass


# ─── Dataclasses de résultats ────────────────────────────────────────────────
@dataclass
class ApiResponse:
    """Réponse standardisée de l'API BeReach."""
    success: bool
    data: Any
    credits_used: int = 0
    retry_after: int = 0
    status_code: int = 200
    error: Optional[str] = None


@dataclass
class DailyCounter:
    """Compteur quotidien des actions LinkedIn."""
    date: date = field(default_factory=date.today)
    connections_sent: int = 0
    messages_sent: int = 0
    profiles_visited: int = 0
    searches_done: int = 0
    credits_used_total: int = 0

    def reset_if_new_day(self):
        """Réinitialise les compteurs si c'est un nouveau jour."""
        today = date.today()
        if self.date != today:
            logger.info("Nouveau jour détecté — réinitialisation des compteurs quotidiens",
                       previous_date=str(self.date), new_date=str(today))
            self.date = today
            self.connections_sent = 0
            self.messages_sent = 0
            self.profiles_visited = 0
            self.searches_done = 0
            # Ne pas réinitialiser credits_used_total (cumulatif)


# ─── Client BeReach Principal ────────────────────────────────────────────────
class BereachClient:
    """
    Client Python pour l'API BeReach LinkedIn.

    Fonctionnalités :
    - Authentification via BEREACH_TOKEN
    - Retry automatique avec backoff exponentiel (erreurs 5xx)
    - Gestion du rate limit (429) avec attente retryAfter
    - Compteur quotidien des actions LinkedIn
    - Délai aléatoire entre actions (comportement humain)
    - Logging structuré JSON

    Usage :
        client = BereachClient()
        results = client.search_people(title="CEO OR Directeur", count=10)
    """

    def __init__(
        self,
        token: Optional[str] = None,
        base_url: str = BEREACH_BASE_URL,
        max_credits_per_run: int = 500,
        timeout: int = 60,
    ):
        self.token = token or os.getenv("BEREACH_TOKEN")
        if not self.token:
            raise BereachAuthError(
                "BEREACH_TOKEN non défini. "
                "Ajoutez-le dans ~/.hermes/.env ou passez-le en paramètre."
            )

        self.base_url = base_url.rstrip("/")
        self.max_credits_per_run = max_credits_per_run
        self.timeout = timeout
        self.counter = DailyCounter()

        # Client HTTP avec headers par défaut
        self.http = httpx.Client(
            base_url=self.base_url,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
            },
            timeout=httpx.Timeout(timeout),
        )

        logger.info("BereachClient initialisé",
                   base_url=self.base_url,
                   max_credits_per_run=max_credits_per_run)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def close(self):
        """Ferme le client HTTP."""
        self.http.close()

    # ─── Méthode de requête centrale ─────────────────────────────────────────
    def _request(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        params: Optional[dict] = None,
    ) -&gt; ApiResponse:
        """
        Effectue une requête HTTP vers l'API BeReach.
        Gère les erreurs, le rate limit et le tracking des crédits.
        """
        self.counter.reset_if_new_day()

        # Vérifier le budget de crédits
        if self.counter.credits_used_total &gt;= self.max_credits_per_run:
            raise BereachBudgetExceededError(
                f"Budget de {self.max_credits_per_run} crédits atteint "
                f"(utilisés: {self.counter.credits_used_total})"
            )

        url = path
        log = logger.bind(method=method, path=path)

        try:
            log.debug("Requête API BeReach", body=body, params=params)

            if method.upper() == "GET":
                response = self.http.get(url, params=params)
            elif method.upper() == "POST":
                response = self.http.post(url, json=body, params=params)
            elif method.upper() == "PATCH":
                response = self.http.patch(url, json=body, params=params)
            elif method.upper() == "PUT":
                response = self.http.put(url, json=body, params=params)
            elif method.upper() == "DELETE":
                response = self.http.delete(url, params=params)
            else:
                raise BereachError(f"Méthode HTTP non supportée : {method}")

            # Gestion des erreurs HTTP
            if response.status_code == 401:
                raise BereachAuthError(
                    "Token BeReach invalide ou expiré. "
                    "Vérifiez BEREACH_TOKEN dans ~/.hermes/.env"
                )
            elif response.status_code == 403:
                raise BereachAuthError(
                    "Accès refusé. Vérifiez les permissions de votre token BeReach."
                )
            elif response.status_code == 429:
                data = response.json() if response.content else {}
                retry_after = data.get("retryAfter", 60)
                log.warning("Rate limit BeReach atteint", retry_after=retry_after)
                raise BereachRateLimitError(retry_after=retry_after)
            elif response.status_code in (400, 404, 409, 422):
                # Erreurs non-retryables
                error_msg = response.text[:500]
                log.error("Erreur API non-retryable",
                         status_code=response.status_code, error=error_msg)
                return ApiResponse(
                    success=False,
                    data=None,
                    status_code=response.status_code,
                    error=error_msg,
                )
            elif response.status_code &gt;= 500:
                # Erreurs serveur — retryables
                raise httpx.HTTPStatusError(
                    f"Erreur serveur {response.status_code}",
                    request=response.request,
                    response=response,
                )

            # Succès
            data = response.json() if response.content else {}
            credits_used = data.get("creditsUsed", 0)
            retry_after = data.get("retryAfter", 0)

            # Mettre à jour les compteurs
            self.counter.credits_used_total += credits_used

            # Respecter le retryAfter même en cas de succès
            if retry_after &gt; 0:
                log.info("retryAfter reçu — pause", seconds=retry_after)
                time.sleep(retry_after)

            log.info("Requête réussie",
                    status_code=response.status_code,
                    credits_used=credits_used,
                    credits_total=self.counter.credits_used_total)

            return ApiResponse(
                success=True,
                data=data,
                credits_used=credits_used,
                retry_after=retry_after,
                status_code=response.status_code,
            )

        except BereachRateLimitError:
            raise
        except BereachAuthError:
            raise
        except BereachBudgetExceededError:
            raise
        except httpx.TimeoutException as e:
            log.error("Timeout de la requête", error=str(e))
            raise BereachError(f"Timeout lors de la requête {method} {path}: {e}")
        except httpx.HTTPStatusError as e:
            log.error("Erreur HTTP serveur", status_code=e.response.status_code)
            raise  # Sera retryé par le décorateur @retry

    def _request_with_retry(
        self,
        method: str,
        path: str,
        body: Optional[dict] = None,
        params: Optional[dict] = None,
    ) -&gt; ApiResponse:
        """
        Wrapper avec retry automatique pour les erreurs 5xx.
        Backoff exponentiel borné avec jitter.
        """
        @retry(
            stop=stop_after_attempt(MAX_RETRIES + 1),
            wait=wait_exponential(multiplier=1, min=2, max=30),
            retry=retry_if_exception_type(httpx.HTTPStatusError),
            before_sleep=before_sleep_log(logging.getLogger(__name__), logging.WARNING),
            reraise=True,
        )
        def _do_request():
            return self._request(method, path, body, params)

        return _do_request()

    def _human_delay(self):
        """Pause aléatoire pour simuler un comportement humain."""
        delay = random.uniform(MIN_DELAY_BETWEEN_ACTIONS, MAX_DELAY_BETWEEN_ACTIONS)
        logger.debug("Pause humaine", seconds=round(delay, 2))
        time.sleep(delay)

    def _handle_rate_limit(self, error: BereachRateLimitError):
        """Gère un rate limit en attendant le délai requis."""
        wait_time = error.retry_after + random.randint(1, 5)  # Jitter
        logger.warning("Rate limit — attente avant retry",
                      retry_after=error.retry_after, wait_with_jitter=wait_time)
        time.sleep(wait_time)

    # ─── Méthodes publiques ───────────────────────────────────────────────────

    def search_people(
        self,
        title: Optional[str] = None,
        keywords: Optional[str] = None,
        location: Optional[list] = None,
        industry: Optional[list] = None,
        current_company: Optional[list] = None,
        profile_language: Optional[list] = None,
        connection_degree: Optional[list] = None,
        count: int = 10,
        start: int = 0,
    ) -&gt; ApiResponse:
        """
        Recherche des profils LinkedIn selon des critères ICP.

        Args:
            title: Requête booléenne sur le titre (ex: "CEO OR Directeur Commercial")
            keywords: Mots-clés de recherche générale
            location: IDs de localisation LinkedIn
            industry: IDs de secteur LinkedIn
            current_company: IDs d'entreprises actuelles
            profile_language: Langues du profil (ex: ["fr", "en"])
            connection_degree: Degrés de connexion ["F", "S", "O"]
            count: Nombre de résultats (1-50 max)
            start: Offset de pagination

        Returns:
            ApiResponse avec items[] de profils LinkedIn
        """
        # Vérifier la limite quotidienne
        if self.counter.searches_done &gt;= MAX_SEARCHES_PER_DAY:
            raise BereachDailyLimitError(
                f"Limite quotidienne de recherches atteinte ({MAX_SEARCHES_PER_DAY})"
            )

        # Construire le body (exclure les None)
        body = {}
        if title:
            body["title"] = title
        if keywords:
            body["keywords"] = keywords
        if location:
            body["location"] = location
        if industry:
            body["industry"] = industry
        if current_company:
            body["currentCompany"] = current_company
        if profile_language:
            body["profileLanguage"] = profile_language
        if connection_degree:
            # Valider les degrés
            valid_degrees = {"F", "S", "O"}
            invalid = set(connection_degree) - valid_degrees
            if invalid:
                raise BereachError(f"Degrés de connexion invalides : {invalid}. Valides : F, S, O")
            body["connectionDegree"] = connection_degree

        body["count"] = min(count, 50)  # Max 50
        body["start"] = start

        logger.info("Recherche de personnes LinkedIn", body=body)

        try:
            result = self._request_with_retry("POST", "/search/linkedin/people", body=body)
            if result.success:
                self.counter.searches_done += 1
                items_count = len(result.data.get("items", []))
                logger.info("Recherche réussie",
                           results_count=items_count,
                           searches_today=self.counter.searches_done)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/search/linkedin/people", body=body)

    def visit_profile(
        self,
        profile_url: str,
        include_about: bool = True,
    ) -&gt; ApiResponse:
        """
        Visite et enrichit un profil LinkedIn.

        Args:
            profile_url: URL du profil LinkedIn
            include_about: Inclure la section "À propos"

        Returns:
            ApiResponse avec données complètes du profil
        """
        # Vérifier la limite quotidienne
        if self.counter.profiles_visited &gt;= MAX_VISITS_PER_DAY:
            raise BereachDailyLimitError(
                f"Limite quotidienne de visites atteinte ({MAX_VISITS_PER_DAY})"
            )

        body = {
            "profile": profile_url,
            "includeAbout": include_about,
            "includePosts": False,      # Toujours False — utiliser collect_posts
            "includeComments": False,   # Toujours False — utiliser collect_comments
        }

        logger.info("Visite de profil LinkedIn", profile_url=profile_url)
        self._human_delay()

        try:
            result = self._request_with_retry("POST", "/visit/linkedin/profile", body=body)
            if result.success:
                self.counter.profiles_visited += 1
                logger.info("Profil visité",
                           profile_url=profile_url,
                           visits_today=self.counter.profiles_visited)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/visit/linkedin/profile", body=body)

    def send_connection(
        self,
        profile_url: str,
        message: Optional[str] = None,
    ) -&gt; ApiResponse:
        """
        Envoie une demande de connexion LinkedIn.
        LIMITE STRICTE : 30 connexions/jour maximum.

        Args:
            profile_url: URL du profil LinkedIn cible
            message: Message personnalisé (300 caractères max)

        Returns:
            ApiResponse avec confirmation d'envoi
        """
        # Vérifier la limite quotidienne STRICTE
        if self.counter.connections_sent &gt;= MAX_CONNECTIONS_PER_DAY:
            raise BereachDailyLimitError(
                f"LIMITE LINKEDIN ATTEINTE : {MAX_CONNECTIONS_PER_DAY} connexions/jour max. "
                f"Envoyées aujourd'hui : {self.counter.connections_sent}"
            )

        # Valider la longueur du message
        if message and len(message) &gt; 300:
            logger.warning("Message de connexion tronqué à 300 caractères",
                          original_length=len(message))
            message = message[:297] + "..."

        body = {"profile": profile_url}
        if message:
            body["message"] = message

        logger.info("Envoi demande de connexion",
                   profile_url=profile_url,
                   has_message=bool(message),
                   connections_today=self.counter.connections_sent)
        self._human_delay()

        try:
            result = self._request_with_retry("POST", "/connect/linkedin/profile", body=body)
            if result.success:
                self.counter.connections_sent += 1
                logger.info("Connexion envoyée",
                           profile_url=profile_url,
                           connections_today=self.counter.connections_sent,
                           remaining_today=MAX_CONNECTIONS_PER_DAY - self.counter.connections_sent)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/connect/linkedin/profile", body=body)

    def send_message(
        self,
        profile_url: str,
        message: str,
    ) -&gt; ApiResponse:
        """
        Envoie un message direct LinkedIn.

        Args:
            profile_url: URL du profil LinkedIn du destinataire
            message: Contenu du message

        Returns:
            ApiResponse avec confirmation d'envoi
        """
        # Vérifier la limite quotidienne
        if self.counter.messages_sent &gt;= MAX_MESSAGES_PER_DAY:
            raise BereachDailyLimitError(
                f"Limite quotidienne de messages atteinte ({MAX_MESSAGES_PER_DAY})"
            )

        if not message.strip():
            raise BereachError("Le message ne peut pas être vide.")

        body = {
            "profile": profile_url,
            "message": message,
        }

        logger.info("Envoi message LinkedIn",
                   profile_url=profile_url,
                   message_length=len(message),
                   messages_today=self.counter.messages_sent)
        self._human_delay()

        try:
            result = self._request_with_retry("POST", "/message/linkedin", body=body)
            if result.success:
                self.counter.messages_sent += 1
                logger.info("Message envoyé",
                           profile_url=profile_url,
                           messages_today=self.counter.messages_sent)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/message/linkedin", body=body)

    def get_connections(self) -&gt; ApiResponse:
        """
        Récupère la liste des connexions LinkedIn du compte.

        Returns:
            ApiResponse avec liste des connexions
        """
        logger.info("Récupération des connexions LinkedIn")
        return self._request_with_retry("GET", "/me/linkedin/connections")

    def get_pending_invitations(self) -&gt; ApiResponse:
        """
        Récupère les invitations LinkedIn reçues en attente.

        Returns:
            ApiResponse avec liste des invitations
        """
        logger.info("Récupération des invitations en attente")
        return self._request_with_retry("POST", "/invitations/linkedin")

    def collect_posts(
        self,
        profile_url: str,
        count: int = 20,
        start: int = 0,
        return_reposts: bool = False,
    ) -&gt; ApiResponse:
        """
        Collecte les posts LinkedIn d'un profil.

        Args:
            profile_url: URL du profil LinkedIn
            count: Nombre de posts (max 20)
            start: Offset de pagination
            return_reposts: False=posts originaux, True=inclure reposts

        Returns:
            ApiResponse avec liste de posts
        """
        body = {
            "profileUrl": profile_url,
            "count": min(count, 20),
            "start": start,
            "returnReposts": return_reposts,
        }

        logger.info("Collecte des posts LinkedIn",
                   profile_url=profile_url,
                   return_reposts=return_reposts)

        try:
            result = self._request_with_retry("POST", "/collect/linkedin/posts", body=body)
            if result.success:
                posts_count = len(result.data.get("posts", []))
                logger.info("Posts collectés", count=posts_count, profile_url=profile_url)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/collect/linkedin/posts", body=body)

    def collect_comments(
        self,
        post_url: str,
        count: int = 50,
        start: int = 0,
    ) -&gt; ApiResponse:
        """
        Collecte les commentaires d'un post LinkedIn.

        Args:
            post_url: URL du post LinkedIn
            count: Nombre de commentaires (max 50)
            start: Offset de pagination

        Returns:
            ApiResponse avec liste de commentaires
        """
        body = {
            "postUrl": post_url,
            "start": start,
            "count": min(count, 50),
        }

        logger.info("Collecte des commentaires", post_url=post_url)

        try:
            result = self._request_with_retry("POST", "/collect/linkedin/comments", body=body)
            if result.success:
                comments_count = len(result.data.get("profiles", []))
                logger.info("Commentaires collectés", count=comments_count)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/collect/linkedin/comments", body=body)

    def get_credits(self) -&gt; ApiResponse:
        """
        Vérifie le solde de crédits BeReach.

        Returns:
            ApiResponse avec solde de crédits
        """
        logger.info("Vérification des crédits BeReach")
        return self._request_with_retry("GET", "/me/credits")

    def publish_post(
        self,
        text: str,
        visibility: str = "PUBLIC",
    ) -&gt; ApiResponse:
        """
        Publie un post sur LinkedIn.

        Args:
            text: Contenu du post (texte + hashtags)
            visibility: "PUBLIC" ou "CONNECTIONS"

        Returns:
            ApiResponse avec confirmation et postUrl
        """
        if not text.strip():
            raise BereachError("Le contenu du post ne peut pas être vide.")

        if visibility not in ("PUBLIC", "CONNECTIONS"):
            raise BereachError(f"Visibilité invalide : {visibility}. Valides : PUBLIC, CONNECTIONS")

        body = {
            "text": text,
            "visibility": visibility,
        }

        logger.info("Publication d'un post LinkedIn",
                   text_length=len(text),
                   visibility=visibility)

        try:
            result = self._request_with_retry("POST", "/publish/linkedin/post", body=body)
            if result.success:
                post_url = result.data.get("postUrl", "N/A")
                logger.info("Post publié", post_url=post_url)
            return result
        except BereachRateLimitError as e:
            self._handle_rate_limit(e)
            return self._request_with_retry("POST", "/publish/linkedin/post", body=body)

    def get_daily_stats(self) -&gt; dict:
        """
        Retourne les statistiques d'utilisation du jour.

        Returns:
            Dictionnaire avec les compteurs quotidiens
        """
        self.counter.reset_if_new_day()
        return {
            "date": str(self.counter.date),
            "connections_sent": self.counter.connections_sent,
            "connections_remaining": MAX_CONNECTIONS_PER_DAY - self.counter.connections_sent,
            "messages_sent": self.counter.messages_sent,
            "messages_remaining": MAX_MESSAGES_PER_DAY - self.counter.messages_sent,
            "profiles_visited": self.counter.profiles_visited,
            "searches_done": self.counter.searches_done,
            "credits_used_total": self.counter.credits_used_total,
        }


# ─── Point d'entrée pour tests ───────────────────────────────────────────────
if __name__ == "__main__":
    """Test rapide du client BeReach."""
    print("Test BereachClient...")

    with BereachClient() as client:
        # Vérifier les crédits
        credits = client.get_credits()
        if credits.success:
            print(f"✅ Connexion BeReach OK — Crédits : {credits.data}")
        else:
            print(f"❌ Erreur : {credits.error}")

        # Afficher les stats quotidiennes
        stats = client.get_daily_stats()
        print(f"📊 Stats du jour : {stats}")
</code></pre>
