#!/usr/bin/env bash
#===============================================================================
# Zitadel Identity Seed Script
#
# Runs after Zitadel Helm install to create the initial identity
# configuration via the Zitadel Management API:
#
#   1. Read the machine user PAT (created by Helm chart's FirstInstance)
#   2. Create "kube-world" project with admin + user roles
#   3. Create human admin user (jharris)
#   4. Grant admin role to jharris
#   5. Create OIDC applications: rancher, gitlab, grafana
#   6. Create claim-flattening action (nested roles → flat groups array)
#   7. Store OIDC client secrets as K8s Secrets in each app namespace
#
# Prerequisites:
#   - Zitadel running and healthy (readiness endpoint responding)
#   - kubectl configured with the host cluster kubeconfig
#   - ADMIN_PASSWORD env var set (initial password for jharris)
#
# Usage:
#   ADMIN_PASSWORD=... ./scripts/seed-zitadel.sh
#   ADMIN_PASSWORD=... ./scripts/seed-zitadel.sh --zitadel-url https://auth.kubew.dev
#   ADMIN_PASSWORD=... ./scripts/seed-zitadel.sh --local  # uses kubectl port-forward
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Configuration
ZITADEL_URL="${ZITADEL_URL:-}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-${RANCHER_BOOTSTRAP_PASSWORD:-}}"
ADMIN_USERNAME="${ADMIN_USERNAME:-jharris}"
ADMIN_EMAIL="${ADMIN_EMAIL:-jharris@kubew.dev}"
DOMAIN="${DOMAIN:-kubew.dev}"
USE_PORT_FORWARD="${USE_PORT_FORWARD:-false}"
STATE_FILE="${STATE_FILE:-/tmp/zitadel-seed.state}"

# Microsoft Entra ID federation (Thread B2 — Entra as upstream IdP, Zitadel brokers).
# All three must be set to enable; otherwise federation is skipped (warn, no fail).
# Provide via .env.bootstrap — NEVER commit the client secret.
ENTRA_TENANT_ID="${ENTRA_TENANT_ID:-}"
ENTRA_CLIENT_ID="${ENTRA_CLIENT_ID:-}"
ENTRA_CLIENT_SECRET="${ENTRA_CLIENT_SECRET:-}"
ENTRA_IDP_NAME="${ENTRA_IDP_NAME:-Microsoft Entra ID}"

# Actions v2 group-sync webhook (Entra group GUID -> HA role). Hooks the Login V2
# RetrieveIdentityProviderIntent response; legacy Actions v1 flow-1 does NOT fire
# under Login V2. The webhook (infrastructure/zitadel-groupsync) writes ha_roles
# user metadata; flattenRoles merges it into the flat groups claim.
GROUPSYNC_TARGET_NAME="${GROUPSYNC_TARGET_NAME:-ha-groupsync}"
GROUPSYNC_ENDPOINT="${GROUPSYNC_ENDPOINT:-http://zitadel-groupsync.zitadel.svc.cluster.local:8080/}"
GROUPSYNC_METHOD="${GROUPSYNC_METHOD:-/zitadel.user.v2.UserService/RetrieveIdentityProviderIntent}"
# Entra group GUID -> HA role map (JSON). kube-world-admins -> admin, kube-world-users -> user.
GROUP_ROLE_MAP="${GROUP_ROLE_MAP:-{\"7eafbda9-c2d8-41f0-854b-0e43cfaeadb3\":\"admin\",\"a7a96cec-3e21-4702-8a07-ced98245a01e\":\"user\"}}"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[ZITADEL-SEED]${NC} $*"; }
warn()  { echo -e "${YELLOW}[ZITADEL-SEED]${NC} $*"; }
error() { echo -e "${RED}[ZITADEL-SEED]${NC} $*" >&2; }
debug() { echo -e "${BLUE}[ZITADEL-SEED]${NC} $*"; }

# Parse args
while [[ $# -gt 0 ]]; do
    case $1 in
        --zitadel-url) ZITADEL_URL="$2"; shift 2 ;;
        --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
        --admin-username) ADMIN_USERNAME="$2"; shift 2 ;;
        --domain) DOMAIN="$2"; shift 2 ;;
        --local) USE_PORT_FORWARD=true; shift ;;
        --state-file) STATE_FILE="$2"; shift 2 ;;
        -h|--help) echo "Usage: $0 [--zitadel-url URL] [--local] [--admin-password PW]"; exit 0 ;;
        *) error "Unknown option: $1"; exit 1 ;;
    esac
done

#===============================================================================
# Helpers
#===============================================================================

# Authenticated API call using the machine user PAT
_api() {
    local method="$1"
    local path="$2"
    local data="${3:-}"
    # Zitadel routes requests by hostname (multi-instance support).
    # When using port-forward, the actual Host is localhost:PORT but
    # Zitadel expects its ExternalDomain. Pass it explicitly.
    local host_header="auth.${DOMAIN:-kubew.dev}"
    local args=(-sk -X "$method" \
        -H "Authorization: Bearer ${PAT}" \
        -H "Content-Type: application/json" \
        -H "Accept: application/json" \
        -H "Host: ${host_header}")
    if [[ -n "$data" ]]; then
        args+=(-d "$data")
    fi
    curl "${args[@]}" "${ZITADEL_URL}${path}" 2>/dev/null
}

# Port-forward lifecycle
_pf_start() {
    # Find a free port (avoid collisions with previous runs)
    local port=18080
    while lsof -iTCP:${port} -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; do
        port=$((port + 1))
        [[ $port -gt 18100 ]] && { error "No free port for Zitadel PF"; return 1; }
    done
    kubectl -n zitadel port-forward svc/zitadel ${port}:8080 > /tmp/zitadel-pf.log 2>&1 &
    PF_PID=$!
    local waited=0
    while [[ $waited -lt 30 ]]; do
        if curl -sk "http://localhost:${port}/debug/ready" 2>/dev/null | grep -q "ok"; then
            ZITADEL_URL="http://localhost:${port}"
            debug "Port-forward ready: localhost:${port}"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    error "Zitadel port-forward failed"
    kill $PF_PID 2>/dev/null || true
    return 1
}

_pf_stop() {
    if [[ -n "${PF_PID:-}" ]]; then
        kill $PF_PID 2>/dev/null || true
        wait $PF_PID 2>/dev/null || true
        unset PF_PID
    fi
}

#===============================================================================
# Step 1: Get the machine user PAT
#===============================================================================
get_pat() {
    log "Reading machine user PAT from K8s secret..."
    # The Zitadel Helm chart stores the PAT under key "pat" (not "token")
    PAT=$(kubectl -n zitadel get secret iam-admin-pat \
        -o jsonpath='{.data.pat}' 2>/dev/null | base64 -d || echo "")

    if [[ -z "$PAT" ]]; then
        error "Could not find Zitadel machine user PAT secret"
        error "Check: kubectl -n zitadel get secrets"
        return 1
    fi

    debug "PAT obtained (${#PAT} chars)"
}

#===============================================================================
# Step 2: Create project with roles
#===============================================================================
create_project() {
    log "Creating 'infrastructure' project..."

    # Check if project already exists
    local existing
    existing=$(_api GET "/management/v1/projects/_search" \
        '{"queries":[{"nameQuery":{"name":"infrastructure","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' \
        | jq -r '.result[0].id // empty' 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        PROJECT_ID="$existing"
        log "  Project already exists: ${PROJECT_ID}"
    else
        local resp
        resp=$(_api POST "/management/v1/projects" \
            '{"name":"infrastructure","projectRoleAssertion":true,"projectRoleCheck":true}')
        PROJECT_ID=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [[ -z "$PROJECT_ID" ]]; then
            # Might be "already exists" from a previous partial run — re-search
            if echo "$resp" | grep -qi "already exists"; then
                PROJECT_ID=$(_api POST "/management/v1/projects/_search" \
                    '{"queries":[{"nameQuery":{"name":"infrastructure","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' \
                    | jq -r '.result[0].id // empty' 2>/dev/null || echo "")
                if [[ -n "$PROJECT_ID" ]]; then
                    log "  Project already existed: ${PROJECT_ID}"
                else
                    error "Failed to create or find project: $(echo "$resp" | head -c 200)"
                    return 1
                fi
            else
                error "Failed to create project: $(echo "$resp" | head -c 200)"
                return 1
            fi
        fi
        log "  Project created: ${PROJECT_ID}"
    fi

    # Create roles
    for role in admin user; do
        _api POST "/management/v1/projects/${PROJECT_ID}/roles" \
            "{\"roleKey\":\"${role}\",\"displayName\":\"${role}\",\"group\":\"kube-world\"}" \
            > /dev/null 2>&1 || debug "  Role '${role}' may already exist"
    done
    log "  Roles created: admin, user"
}

#===============================================================================
# Step 3: Create human admin user
#===============================================================================
create_admin_user() {
    log "Creating admin user: ${ADMIN_USERNAME}..."

    if [[ -z "$ADMIN_PASSWORD" ]]; then
        error "ADMIN_PASSWORD not set"
        return 1
    fi

    # Check if user exists
    local existing
    existing=$(_api POST "/management/v1/users/_search" \
        "{\"queries\":[{\"userNameQuery\":{\"userName\":\"${ADMIN_USERNAME}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}" \
        | jq -r '.result[0].id // empty' 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        ADMIN_USER_ID="$existing"
        log "  User already exists: ${ADMIN_USER_ID}"
    else
        local resp
        resp=$(_api POST "/management/v1/users/human/_import" "{
            \"userName\": \"${ADMIN_USERNAME}\",
            \"profile\": {
                \"firstName\": \"Jackson\",
                \"lastName\": \"Harris\",
                \"displayName\": \"Jackson Harris\",
                \"preferredLanguage\": \"en\"
            },
            \"email\": {
                \"email\": \"${ADMIN_EMAIL}\",
                \"isEmailVerified\": true
            },
            \"password\": \"${ADMIN_PASSWORD}!Kw1\",
            \"passwordChangeRequired\": false
        }")
        ADMIN_USER_ID=$(echo "$resp" | jq -r '.userId // empty' 2>/dev/null || echo "")
        if [[ -z "$ADMIN_USER_ID" ]]; then
            error "Failed to create user: $(echo "$resp" | head -c 300)"
            return 1
        fi
        log "  User created: ${ADMIN_USER_ID}"
    fi
}

#===============================================================================
# Step 4: Grant admin role
#===============================================================================
grant_admin_role() {
    log "Granting admin role to ${ADMIN_USERNAME}..."

    _api POST "/management/v1/users/${ADMIN_USER_ID}/grants" "{
        \"projectId\": \"${PROJECT_ID}\",
        \"roleKeys\": [\"admin\"]
    }" > /dev/null 2>&1 || debug "  Grant may already exist"

    log "  Role granted ✓"
}

#===============================================================================
# Step 5: Create OIDC applications
#===============================================================================
create_oidc_app() {
    local app_name="$1"
    local redirect_uris="$2"
    local post_logout_uris="${3:-}"
    local var_prefix="$4"

    log "Creating OIDC application: ${app_name}..."

    # Check if app exists
    local existing
    existing=$(_api POST "/management/v1/projects/${PROJECT_ID}/apps/_search" \
        "{\"queries\":[{\"nameQuery\":{\"name\":\"${app_name}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}" \
        | jq -r '.result[0].id // empty' 2>/dev/null || echo "")

    if [[ -n "$existing" ]]; then
        log "  App already exists: ${existing}"
        # Can't retrieve client secret for existing app — store ID only
        eval "${var_prefix}_APP_ID=${existing}"
        eval "${var_prefix}_CLIENT_ID="
        eval "${var_prefix}_CLIENT_SECRET="
        return 0
    fi

    local logout_json=""
    if [[ -n "$post_logout_uris" ]]; then
        logout_json="\"postLogoutRedirectUris\": ${post_logout_uris},"
    fi

    local resp
    resp=$(_api POST "/management/v1/projects/${PROJECT_ID}/apps/oidc" "{
        \"name\": \"${app_name}\",
        \"redirectUris\": ${redirect_uris},
        ${logout_json}
        \"responseTypes\": [\"OIDC_RESPONSE_TYPE_CODE\"],
        \"grantTypes\": [\"OIDC_GRANT_TYPE_AUTHORIZATION_CODE\"],
        \"appType\": \"OIDC_APP_TYPE_WEB\",
        \"authMethodType\": \"OIDC_AUTH_METHOD_TYPE_BASIC\",
        \"accessTokenType\": \"OIDC_TOKEN_TYPE_BEARER\",
        \"idTokenRoleAssertion\": true,
        \"idTokenUserinfoAssertion\": true
    }")

    local app_id client_id client_secret
    app_id=$(echo "$resp" | jq -r '.appId // empty' 2>/dev/null || echo "")
    client_id=$(echo "$resp" | jq -r '.clientId // empty' 2>/dev/null || echo "")
    client_secret=$(echo "$resp" | jq -r '.clientSecret // empty' 2>/dev/null || echo "")

    if [[ -z "$client_id" ]]; then
        warn "  Failed to create app: $(echo "$resp" | head -c 300)"
        return 0
    fi

    eval "${var_prefix}_APP_ID=${app_id}"
    eval "${var_prefix}_CLIENT_ID=${client_id}"
    eval "${var_prefix}_CLIENT_SECRET=${client_secret}"

    log "  Created: clientId=${client_id:0:15}..."
}

create_oidc_apps() {
    create_oidc_app "rancher" \
        "[\"https://rancher.${DOMAIN}/dashboard/auth/verify\", \"https://rancher.${DOMAIN}\", \"https://rancher.${DOMAIN}/verify-auth\"]" \
        "[\"https://rancher.${DOMAIN}\"]" \
        "RANCHER"

    create_oidc_app "gitlab" \
        "[\"http://gitlab.${DOMAIN}/users/auth/openid_connect/callback\"]" \
        "[\"http://gitlab.${DOMAIN}\"]" \
        "GITLAB"

    create_oidc_app "grafana" \
        "[\"https://grafana.${DOMAIN}/login/generic_oauth\"]" \
        "[\"https://grafana.${DOMAIN}\"]" \
        "GRAFANA"

    create_oidc_app "homeassistant" \
        "[\"https://ha.edge1.${DOMAIN}/auth/oidc/callback\"]" \
        "[\"https://ha.edge1.${DOMAIN}\"]" \
        "HOMEASSISTANT"
}

#===============================================================================
# Step 6: Create claim-flattening action
#===============================================================================
create_claim_action() {
    log "Creating claim-flattening action..."

    # Zitadel's native role claim (urn:zitadel:iam:org:project:roles) is nested:
    #   {"admin": {"orgId": "orgDomain"}, "user": {...}}
    # Most apps (HA/Rancher/Grafana/GitLab) want a flat array: ["admin","user"].
    # Read authoritative user grants (NOT ctx.v1.claims — the native role claim is
    # not reliably present in the action context) and emit via api.v1.claims.setClaim
    # (direct property assignment api.v1.claims["groups"]=... is a SILENT NO-OP).
    #
    # ALSO merge the `ha_roles` user-metadata array (base64-encoded JSON written by
    # the zitadel-groupsync Actions v2 webhook from Entra group membership). goja has
    # no atob/Buffer, so decode with a pure-JS base64 decoder; dual-path (raw JSON or
    # base64) keeps it robust. Dedupe and emit the union as the flat "groups" claim.
    local action_script='
function flattenRoles(ctx, api) {
  function b64decode(s) {
    var chars = '"'"'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'"'"';
    var str = String(s).replace(/=+$/, '"'"''"'"');
    var output = '"'"''"'"';
    if (str.length % 4 == 1) { return '"'"''"'"'; }
    for (var bc = 0, bs = 0, buffer, i = 0; (buffer = str.charAt(i++));) {
      buffer = chars.indexOf(buffer);
      if (buffer === -1) { continue; }
      bs = bc % 4 ? bs * 64 + buffer : buffer;
      if (bc++ % 4) { output += String.fromCharCode(255 & (bs >> ((-2 * bc) & 6))); }
    }
    return output;
  }
  var roles = [];
  if (ctx.v1.user.grants !== undefined && ctx.v1.user.grants.count > 0) {
    ctx.v1.user.grants.grants.forEach(function (grant) {
      grant.roles.forEach(function (role) { roles.push(role); });
    });
  }
  try {
    var md = ctx.v1.user.getMetadata();
    var list = (md && md.metadata) ? md.metadata : md;
    if (list && list.forEach) {
      list.forEach(function (entry) {
        if (entry.key === '"'"'ha_roles'"'"' && entry.value) {
          var raw = String(entry.value);
          var parsed = null;
          try { parsed = JSON.parse(raw); }
          catch (e1) {
            try { parsed = JSON.parse(b64decode(raw)); } catch (e2) { parsed = null; }
          }
          if (parsed && parsed.forEach) {
            parsed.forEach(function (r) { roles.push(r); });
          }
        }
      });
    }
  } catch (e) {}
  var seen = {};
  var out = [];
  roles.forEach(function (r) { if (!seen[r]) { seen[r] = true; out.push(r); } });
  api.v1.claims.setClaim('"'"'groups'"'"', out);
}
'

    # Create or update the action
    local existing_id
    existing_id=$(_api POST "/management/v1/actions/_search" \
        '{"queries":[{"actionNameQuery":{"name":"flattenRoles","method":"TEXT_QUERY_METHOD_EQUALS"}}]}' \
        | jq -r '.result[0].id // empty' 2>/dev/null || echo "")

    if [[ -n "$existing_id" ]]; then
        debug "  Action already exists: ${existing_id}"
    else
        local resp
        resp=$(_api POST "/management/v1/actions" "{
            \"name\": \"flattenRoles\",
            \"script\": $(echo "$action_script" | jq -Rs .),
            \"timeout\": \"10s\",
            \"allowedToFail\": true
        }")
        existing_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [[ -z "$existing_id" ]]; then
            warn "  Failed to create action: $(echo "$resp" | head -c 200)"
            return 0
        fi
        debug "  Action created: ${existing_id}"
    fi

    # Bind the action to flow type 2 (Complement Token).
    # Trigger 4 = Pre Userinfo creation (populates id_token + userinfo — what
    # OIDC clients like hass-oidc-auth read). Trigger 5 = Pre Access Token creation.
    # NOTE: trigger 1 (Post Authentication) is INVALID for this flow and silently
    # no-ops — the prior binding to /trigger/1 never ran, so the flat "groups"
    # claim was never emitted (broke HA group gating).
    for trig in 4 5; do
        _api POST "/management/v1/flows/2/trigger/${trig}" "{
            \"actionIds\": [\"${existing_id}\"]
        }" > /dev/null 2>&1 || debug "  Trigger ${trig} binding may already exist"
    done

    log "  Claim-flattening action configured ✓"
}

#===============================================================================
# Step 7: Store OIDC secrets in K8s
#===============================================================================
# Federate Microsoft Entra ID as an upstream IdP at instance scope, brokered by
# Zitadel. Apps keep talking OIDC to Zitadel; users authenticate via Entra.
# Idempotent: skips if an instance IdP with the same name already exists.
# Entra app must register redirect URI: https://auth.${DOMAIN}/idps/callback
configure_entra_federation() {
    if [[ -z "$ENTRA_TENANT_ID" || -z "$ENTRA_CLIENT_ID" || -z "$ENTRA_CLIENT_SECRET" ]]; then
        warn "Entra federation skipped (ENTRA_TENANT_ID/CLIENT_ID/CLIENT_SECRET not all set)"
        return 0
    fi

    log "Configuring Microsoft Entra ID federation (instance scope)..."

    # Idempotency: look for an existing instance IdP by name.
    local existing
    existing=$(_api POST "/admin/v1/idps/_search" '{}' \
        | jq -r --arg n "$ENTRA_IDP_NAME" '.result[]? | select(.name==$n) | .id' 2>/dev/null | head -1)

    local idp_id
    if [[ -n "$existing" ]]; then
        idp_id="$existing"
        log "  Entra IdP already exists: ${idp_id}"
    else
        local resp
        resp=$(_api POST "/admin/v1/idps/azure" "{
            \"name\": \"${ENTRA_IDP_NAME}\",
            \"clientId\": \"${ENTRA_CLIENT_ID}\",
            \"clientSecret\": \"${ENTRA_CLIENT_SECRET}\",
            \"scopes\": [\"openid\",\"profile\",\"email\",\"User.Read\"],
            \"tenant\": {\"tenantId\": \"${ENTRA_TENANT_ID}\"},
            \"emailVerified\": true,
            \"providerOptions\": {
                \"isLinkingAllowed\": true,
                \"isCreationAllowed\": true,
                \"isAutoCreation\": true,
                \"isAutoUpdate\": true,
                \"autoLinking\": \"AUTO_LINKING_OPTION_EMAIL\"
            }
        }")
        idp_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null)
        if [[ -z "$idp_id" ]]; then
            error "Failed to add Entra IdP: $resp"
            return 1
        fi
        log "  Entra IdP created: ${idp_id}"
    fi

    # Activate on the instance default login policy (idempotent — ignore 'already exists').
    _api POST "/admin/v1/policies/login/idps" \
        "{\"idpId\": \"${idp_id}\", \"ownerType\": \"IDP_OWNER_TYPE_SYSTEM\"}" > /dev/null 2>&1 \
        || debug "  Login-policy binding may already exist"
    log "  Entra IdP active on instance login policy"
    log "  Entra redirect URI must be: https://auth.${DOMAIN}/idps/callback"
}

# Configure the Actions v2 group-sync webhook: Target (HTTP webhook) + Execution
# (response hook on the IdP-intent method). The Target signing key is generated by
# Zitadel at creation time, so it cannot be pre-sealed in git — capture it and write
# the in-cluster zitadel-groupsync-credentials secret imperatively (same pattern as
# store_oidc_secrets). Gated on ENTRA_* like configure_entra_federation. Idempotent.
configure_actions_v2_groupsync() {
    if [[ -z "$ENTRA_TENANT_ID" || -z "$ENTRA_CLIENT_ID" || -z "$ENTRA_CLIENT_SECRET" ]]; then
        warn "Actions v2 group-sync skipped (Entra federation not configured)"
        return 0
    fi

    log "Configuring Actions v2 group-sync webhook (Entra groups -> HA roles)..."

    # Idempotency: find an existing Target by name; reuse its signing key (rotating
    # it would orphan the secret already mounted in the running webhook pod).
    local target_id signing_key
    local search
    search=$(_api POST "/v2beta/actions/targets/search" \
        "{\"queries\":[{\"targetNameQuery\":{\"name\":\"${GROUPSYNC_TARGET_NAME}\",\"method\":\"TEXT_QUERY_METHOD_EQUALS\"}}]}")
    target_id=$(echo "$search" | jq -r '.targets[0].id // empty' 2>/dev/null || echo "")
    signing_key=$(echo "$search" | jq -r '.targets[0].signingKey // empty' 2>/dev/null || echo "")

    if [[ -n "$target_id" ]]; then
        log "  Target already exists: ${target_id}"
    else
        local resp
        resp=$(_api POST "/v2beta/actions/targets" "{
            \"name\": \"${GROUPSYNC_TARGET_NAME}\",
            \"restWebhook\": {\"interruptOnError\": false},
            \"endpoint\": \"${GROUPSYNC_ENDPOINT}\",
            \"timeout\": \"10s\"
        }")
        target_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")
        signing_key=$(echo "$resp" | jq -r '.signingKey // empty' 2>/dev/null || echo "")
        if [[ -z "$target_id" || -z "$signing_key" ]]; then
            warn "  Failed to create Target: $(echo "$resp" | head -c 200)"
            return 0
        fi
        log "  Target created: ${target_id}"
    fi

    # Execution: response hook on the IdP-intent method -> Target. PUT is upsert,
    # keyed by the condition, so re-running just re-points the same condition.
    _api PUT "/v2beta/actions/executions" "{
        \"condition\": {\"response\": {\"method\": \"${GROUPSYNC_METHOD}\"}},
        \"targets\": [\"${target_id}\"]
    }" > /dev/null 2>&1 || debug "  Execution upsert may already exist"
    log "  Execution bound: response ${GROUPSYNC_METHOD} -> ${target_id}"

    # Imperative secret: API token (reuse the iam-admin PAT) + the Target signing key.
    # NOT committed to git; sealed-secrets is not deployed. Hardening: swap the PAT for
    # a scoped service-user token later.
    if [[ -n "$signing_key" && -n "${PAT:-}" ]]; then
        kubectl create secret generic zitadel-groupsync-credentials \
            --namespace=zitadel \
            --from-literal=ZITADEL_API_TOKEN="${PAT}" \
            --from-literal=TARGET_SIGNING_KEY="${signing_key}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  groupsync credentials secret → zitadel"
    else
        warn "  groupsync secret not written (missing signing key or PAT)"
    fi
}

store_oidc_secrets() {
    log "Storing OIDC client secrets in K8s..."

    local issuer_url="https://auth.${DOMAIN}"

    # Rancher OIDC secret (cattle-system namespace)
    if [[ -n "${RANCHER_CLIENT_ID:-}" ]]; then
        kubectl create namespace cattle-system --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
        kubectl create secret generic zitadel-oidc-rancher \
            --namespace=cattle-system \
            --from-literal=clientId="${RANCHER_CLIENT_ID}" \
            --from-literal=clientSecret="${RANCHER_CLIENT_SECRET}" \
            --from-literal=issuerUrl="${issuer_url}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  rancher OIDC secret → cattle-system"
    fi

    # GitLab OIDC secret (zitadel namespace — GitLab reads from config, not K8s secret)
    if [[ -n "${GITLAB_CLIENT_ID:-}" ]]; then
        kubectl create secret generic zitadel-oidc-gitlab \
            --namespace=zitadel \
            --from-literal=clientId="${GITLAB_CLIENT_ID}" \
            --from-literal=clientSecret="${GITLAB_CLIENT_SECRET}" \
            --from-literal=issuerUrl="${issuer_url}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  gitlab OIDC secret → zitadel"
    fi

    # Grafana OIDC secret (pre-created for Phase 5)
    if [[ -n "${GRAFANA_CLIENT_ID:-}" ]]; then
        kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
        kubectl create secret generic zitadel-oidc-grafana \
            --namespace=monitoring \
            --from-literal=clientId="${GRAFANA_CLIENT_ID}" \
            --from-literal=clientSecret="${GRAFANA_CLIENT_SECRET}" \
            --from-literal=issuerUrl="${issuer_url}" \
            --dry-run=client -o yaml | kubectl apply -f -
        log "  grafana OIDC secret → monitoring (pre-created)"
    fi
}

#===============================================================================
# Step 8: Write state file
#===============================================================================
write_state() {
    umask 077
    cat > "$STATE_FILE" <<EOF
{
  "project_id": "${PROJECT_ID:-}",
  "admin_user_id": "${ADMIN_USER_ID:-}",
  "admin_username": "${ADMIN_USERNAME}",
  "rancher_client_id": "${RANCHER_CLIENT_ID:-}",
  "gitlab_client_id": "${GITLAB_CLIENT_ID:-}",
  "grafana_client_id": "${GRAFANA_CLIENT_ID:-}",
  "homeassistant_client_id": "${HOMEASSISTANT_CLIENT_ID:-}",
  "homeassistant_client_secret": "${HOMEASSISTANT_CLIENT_SECRET:-}",
  "entra_federated": $([[ -n "$ENTRA_CLIENT_SECRET" ]] && echo true || echo false),
  "issuer_url": "https://auth.${DOMAIN}",
  "seeded_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
    chmod 600 "$STATE_FILE"
    log "State written to ${STATE_FILE}"
}

#===============================================================================
# Main
#===============================================================================
main() {
    log "Seeding Zitadel identity provider..."

    # Set up access
    if [[ "$USE_PORT_FORWARD" == "true" || -z "$ZITADEL_URL" ]]; then
        _pf_start || return 1
        trap '_pf_stop' EXIT
    fi

    # Wait for Zitadel readiness
    local attempts=0
    while [[ $attempts -lt 30 ]]; do
        if curl -sk "${ZITADEL_URL}/debug/ready" 2>/dev/null | grep -q "ok"; then
            break
        fi
        sleep 5
        attempts=$((attempts + 1))
    done
    if [[ $attempts -ge 30 ]]; then
        error "Zitadel not ready at ${ZITADEL_URL}"
        return 1
    fi

    get_pat
    create_project
    create_admin_user
    grant_admin_role
    create_oidc_apps
    create_claim_action
    configure_entra_federation
    configure_actions_v2_groupsync
    store_oidc_secrets
    write_state

    echo ""
    log "=============================================="
    log "  Zitadel Identity Seed Complete"
    log "=============================================="
    log ""
    log "  Issuer URL:  https://auth.${DOMAIN}"
    log "  Admin user:  ${ADMIN_USERNAME}"
    log "  Project:     infrastructure (${PROJECT_ID})"
    log ""
    log "  OIDC Applications:"
    log "    rancher:  ${RANCHER_CLIENT_ID:-(existing)}"
    log "    gitlab:   ${GITLAB_CLIENT_ID:-(existing)}"
    log "    grafana:  ${GRAFANA_CLIENT_ID:-(pre-created)}"
    log ""
    log "  State: ${STATE_FILE}"
    log "=============================================="
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
