"""Redirect route to redirect the user to the external OIDC server."""

import logging
from urllib.parse import urlparse, parse_qs
from aiohttp import web
from homeassistant.components.http import HomeAssistantView

from ..tools.oidc_client import OIDCClient
from ..tools.helpers import get_url, get_view

PATH = "/auth/oidc/redirect"
_LOGGER = logging.getLogger(__name__)


class OIDCRedirectView(HomeAssistantView):
    """OIDC Plugin Redirect View."""

    requires_auth = False
    url = PATH
    name = "auth:oidc:redirect"

    def __init__(self, oidc_client: OIDCClient, force_https: bool) -> None:
        self.oidc_client = oidc_client
        self.force_https = force_https

    async def get(self, request: web.Request) -> web.Response:
        """Redirect to OIDC provider, capturing mobile app callback URI."""

        try:
            redirect_uri = get_url("/auth/oidc/callback", self.force_https)
            auth_url = await self.oidc_client.async_get_authorization_url(redirect_uri)

            if auth_url:
                response = web.HTTPFound(auth_url)

                # Check if this request came from a mobile app auth flow.
                # The Referer will be /auth/authorize?...redirect_uri=homeassistant://...
                # Capture the app callback URI so the OIDC callback can redirect there.
                referer = request.headers.get("Referer", "")
                if "redirect_uri=" in referer:
                    try:
                        parsed = urlparse(referer)
                        params = parse_qs(parsed.query)
                        app_redirect = params.get("redirect_uri", [""])[0]
                        app_client_id = params.get("client_id", [""])[0]
                        if app_redirect:
                            response.set_cookie(
                                "ha_app_redirect_uri", app_redirect,
                                max_age=300, httponly=True, samesite="Lax", path="/"
                            )
                            response.set_cookie(
                                "ha_app_client_id", app_client_id,
                                max_age=300, httponly=True, samesite="Lax", path="/"
                            )
                            _LOGGER.debug("Captured app redirect_uri: %s", app_redirect)
                    except Exception:
                        _LOGGER.debug("Failed to parse Referer for app redirect_uri")

                raise response
        except RuntimeError:
            pass

        view_html = await get_view(
            "error",
            {"error": "Integration is misconfigured, discovery could not be obtained."},
        )
        return web.Response(text=view_html, content_type="text/html")

    async def post(self, request: web.Request) -> web.Response:
        """POST"""
        return await self.get(request)
