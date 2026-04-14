"""Callback route to return the user to after external OIDC interaction."""

import logging
from aiohttp import web
from homeassistant.components.http import HomeAssistantView
from ..tools.oidc_client import OIDCClient
from ..provider import OpenIDAuthProvider
from ..tools.helpers import get_url, get_view

PATH = "/auth/oidc/callback"
_LOGGER = logging.getLogger(__name__)


class OIDCCallbackView(HomeAssistantView):
    """OIDC Plugin Callback View."""

    requires_auth = False
    url = PATH
    name = "auth:oidc:callback"

    def __init__(
        self,
        oidc_client: OIDCClient,
        oidc_provider: OpenIDAuthProvider,
        force_https: bool,
    ) -> None:
        self.oidc_client = oidc_client
        self.oidc_provider = oidc_provider
        self.force_https = force_https

    async def get(self, request: web.Request) -> web.Response:
        """Process the OIDC callback after user authenticates at IdP."""

        params = request.rel_url.query
        code = params.get("code")
        state = params.get("state")

        if not (code and state):
            view_html = await get_view(
                "error",
                {"error": "Missing code or state parameter."},
            )
            return web.Response(text=view_html, content_type="text/html")

        redirect_uri = get_url("/auth/oidc/callback", self.force_https)
        user_details = await self.oidc_client.async_complete_token_flow(
            redirect_uri, code, state
        )
        if user_details is None:
            view_html = await get_view(
                "error",
                {"error": "Failed to get user details, see HA logs."},
            )
            return web.Response(text=view_html, content_type="text/html")

        if user_details.get("role") == "invalid":
            view_html = await get_view(
                "error",
                {"error": "User not in correct group for HA access."},
            )
            return web.Response(text=view_html, content_type="text/html")

        # Save user info and get the internal OIDC code
        oidc_code = await self.oidc_provider.async_save_user_info(user_details)

        # Check if this came from a mobile app (captured in redirect handler)
        app_redirect = request.cookies.get("ha_app_redirect_uri", "")
        app_client_id = request.cookies.get("ha_app_client_id", "")

        if app_redirect and "homeassistant://" in app_redirect:
            _LOGGER.info("Mobile app flow detected, completing HA auth flow")
            try:
                # Complete HA native auth flow programmatically
                hass = request.app["hass"]
                handler_key = (self.oidc_provider.type, self.oidc_provider.id)

                # Start a login flow
                flow_result = await hass.auth.login_flow.async_init(
                    handler_key,
                    context={
                        "ip_address": request.remote,
                        "credential_only": False,
                    },
                )

                # Complete the flow with the OIDC code
                flow_result = await hass.auth.login_flow.async_configure(
                    flow_result["flow_id"],
                    user_input={"code": oidc_code},
                )

                if flow_result.get("type") == "create_entry":
                    ha_code = flow_result["result"]
                    redirect_url = f"{app_redirect}?code={ha_code}&state="
                    _LOGGER.info("Redirecting to mobile app: %s", app_redirect)
                    raise web.HTTPFound(redirect_url)
                else:
                    _LOGGER.error("Login flow failed: %s", flow_result)
            except web.HTTPFound:
                raise  # Let the redirect through
            except Exception as e:
                _LOGGER.error("Failed to complete mobile app auth: %s", e)

        # Default: web browser flow → show finish page
        raise web.HTTPFound(
            get_url("/auth/oidc/finish?code=" + oidc_code, self.force_https)
        )
