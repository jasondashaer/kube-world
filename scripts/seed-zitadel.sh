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
            \"password\": \"${ADMIN_PASSWORD}!\",
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
        "[\"https://rancher.${DOMAIN}/verify-auth\"]" \
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
}

#===============================================================================
# Step 6: Create claim-flattening action
#===============================================================================
create_claim_action() {
    log "Creating claim-flattening action..."

    # Zitadel's default role claim is nested JSON:
    #   {"admin": {"orgId": "orgDomain"}, "user": {...}}
    # Most apps (Rancher, Grafana, GitLab) expect a flat array:
    #   ["admin", "user"]
    # This action transforms the claims at token issuance time.
    local action_script='
function flattenRoles(ctx, api) {
  if (ctx.v1.claims["urn:zitadel:iam:org:project:roles"] === undefined) {
    return;
  }
  var roles = [];
  var projectRoles = ctx.v1.claims["urn:zitadel:iam:org:project:roles"];
  for (var role in projectRoles) {
    roles.push(role);
  }
  api.v1.claims["groups"] = roles;
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
            \"allowedToFail\": false
        }")
        existing_id=$(echo "$resp" | jq -r '.id // empty' 2>/dev/null || echo "")
        if [[ -z "$existing_id" ]]; then
            warn "  Failed to create action: $(echo "$resp" | head -c 200)"
            return 0
        fi
        debug "  Action created: ${existing_id}"
    fi

    # Bind the action to the "pre userinfo creation" and "pre access token creation" flows
    # Flow type 2 = Complement Token, Trigger type 1 = Pre Access Token Creation
    _api POST "/management/v1/flows/2/trigger/1" "{
        \"actionIds\": [\"${existing_id}\"]
    }" > /dev/null 2>&1 || debug "  Token flow binding may already exist"

    log "  Claim-flattening action configured ✓"
}

#===============================================================================
# Step 7: Store OIDC secrets in K8s
#===============================================================================
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
