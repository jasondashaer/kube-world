#!/usr/bin/env bash
#===============================================================================
# Rancher Account Management Script
#
# Provides utilities for managing Rancher admin accounts without lockouts:
# - Generate secure random passwords
# - Reset admin password via API
# - Backup/restore credentials using external secrets
# - RBAC setup for non-admin users
#
# Usage:
#   ./account-management.sh [COMMAND] [OPTIONS]
#
# Commands:
#   reset-password    Reset admin password (requires cluster access)
#   gen-password      Generate a secure random password
#   backup-creds      Backup current credentials to a secret
#   restore-creds     Restore credentials from a secret
#   create-user       Create a new user with RBAC
#   show-password     Show current bootstrap password (from secret)
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Configuration
RANCHER_NAMESPACE="${RANCHER_NAMESPACE:-cattle-system}"
SECRET_NAME="${SECRET_NAME:-rancher-admin-creds}"
SECRET_NAMESPACE="${SECRET_NAMESPACE:-kube-world-secrets}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[ACCOUNT]${NC} $*"; }
warn() { echo -e "${YELLOW}[ACCOUNT]${NC} $*"; }
error() { echo -e "${RED}[ACCOUNT]${NC} $*" >&2; }

#===============================================================================
# Generate Secure Password
#===============================================================================
gen_password() {
    local length="${1:-24}"
    # Generate a secure password with alphanumeric + special chars
    # Avoid problematic chars: ', ", \, `, $
    LC_ALL=C tr -dc 'A-Za-z0-9!@#%^&*()_+-=' < /dev/urandom | head -c "$length"
    echo
}

#===============================================================================
# Show Current Bootstrap Password
#===============================================================================
show_password() {
    log "Retrieving current bootstrap password..."
    
    # Check if we have a backup secret
    if kubectl get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" &>/dev/null; then
        local password
        password=$(kubectl get secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" \
            -o jsonpath='{.data.password}' | base64 -d)
        echo ""
        echo "Current Password (from backup secret): ${password}"
        echo ""
        return 0
    fi
    
    # Try to get from Rancher bootstrap secret
    if kubectl get secret bootstrap-secret -n "$RANCHER_NAMESPACE" &>/dev/null; then
        local password
        password=$(kubectl get secret bootstrap-secret -n "$RANCHER_NAMESPACE" \
            -o jsonpath='{.data.bootstrapPassword}' 2>/dev/null | base64 -d || echo "")
        if [[ -n "$password" ]]; then
            echo ""
            echo "Bootstrap Password: ${password}"
            echo ""
            return 0
        fi
    fi
    
    error "Could not find stored password. Try reset-password instead."
    return 1
}

#===============================================================================
# Backup Credentials to Secret
#===============================================================================
backup_creds() {
    local password="$1"
    
    log "Backing up credentials to Kubernetes secret..."
    
    # Create namespace if needed
    kubectl create namespace "$SECRET_NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    
    # Create secret with current credentials
    kubectl create secret generic "$SECRET_NAME" \
        --namespace "$SECRET_NAMESPACE" \
        --from-literal=username=admin \
        --from-literal=password="$password" \
        --from-literal=created="$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Add label for identification
    kubectl label secret "$SECRET_NAME" -n "$SECRET_NAMESPACE" \
        app.kubernetes.io/part-of=kube-world \
        app.kubernetes.io/component=rancher-credentials \
        --overwrite
    
    log "Credentials backed up to ${SECRET_NAMESPACE}/${SECRET_NAME} ✓"
}

#===============================================================================
# Reset Admin Password (Emergency Recovery)
#===============================================================================
reset_password() {
    local new_password="${1:-}"
    
    log "Resetting Rancher admin password..."
    
    # Generate new password if not provided
    if [[ -z "$new_password" ]]; then
        new_password=$(gen_password 24)
        log "Generated new password: ${new_password}"
    fi
    
    # Method 1: Try via kubectl exec into rancher pod
    log "Attempting password reset via Rancher pod..."
    local rancher_pod
    rancher_pod=$(kubectl -n "$RANCHER_NAMESPACE" get pods -l app=rancher \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$rancher_pod" ]]; then
        # Reset using Rancher's reset-password command
        if kubectl -n "$RANCHER_NAMESPACE" exec "$rancher_pod" -- \
            reset-password 2>/dev/null; then
            log "Password reset command executed. Check pod logs for new password."
        else
            warn "reset-password command not available, trying alternative method..."
        fi
    fi
    
    # Method 2: Direct secret update (for fresh installs)
    log "Updating bootstrap secret..."
    kubectl -n "$RANCHER_NAMESPACE" create secret generic bootstrap-secret \
        --from-literal=bootstrapPassword="$new_password" \
        --dry-run=client -o yaml | kubectl apply -f -
    
    # Backup the new password
    backup_creds "$new_password"
    
    # Restart Rancher to pick up new password (for bootstrap scenarios)
    log "Restarting Rancher deployment to apply changes..."
    kubectl -n "$RANCHER_NAMESPACE" rollout restart deployment/rancher
    kubectl -n "$RANCHER_NAMESPACE" rollout status deployment/rancher --timeout=300s
    
    echo ""
    echo "=============================================="
    echo "  Password Reset Complete"
    echo "=============================================="
    echo ""
    echo "  New Password: ${new_password}"
    echo "  Username: admin"
    echo ""
    echo "  Password backed up to: ${SECRET_NAMESPACE}/${SECRET_NAME}"
    echo "  Retrieve with: ./account-management.sh show-password"
    echo ""
    echo "  IMPORTANT: Log in and change password immediately!"
    echo ""
}

#===============================================================================
# Create Non-Admin User with RBAC
#===============================================================================
create_user() {
    local username="$1"
    local role="${2:-user}"  # user, admin, cluster-admin
    
    log "Creating RBAC user: ${username} with role: ${role}"
    
    # Note: Full user creation requires Rancher API
    # This creates a Kubernetes RBAC binding that Rancher can recognize
    
    local cluster_role=""
    case "$role" in
        admin)
            cluster_role="admin"
            ;;
        cluster-admin)
            cluster_role="cluster-admin"
            ;;
        user|*)
            cluster_role="view"
            ;;
    esac
    
    # Create ClusterRoleBinding
    cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: ${username}-${cluster_role}
  labels:
    app.kubernetes.io/part-of: kube-world
    kube-world.io/managed-user: "true"
subjects:
- kind: User
  name: ${username}
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: ClusterRole
  name: ${cluster_role}
  apiGroup: rbac.authorization.k8s.io
EOF
    
    log "RBAC binding created for ${username} ✓"
    echo ""
    echo "  User '${username}' has been granted '${cluster_role}' permissions."
    echo "  To complete user setup, create the user in Rancher UI with the same username."
    echo ""
}

#===============================================================================
# Main
#===============================================================================
show_help() {
    cat << 'EOF'
Rancher Account Management

Usage:
    ./account-management.sh [COMMAND] [OPTIONS]

Commands:
    reset-password [PASSWORD]   Reset admin password (generates if not provided)
    gen-password [LENGTH]       Generate a secure random password
    backup-creds PASSWORD       Backup credentials to Kubernetes secret
    show-password               Show current stored password
    create-user USERNAME [ROLE] Create RBAC for a user (role: user/admin/cluster-admin)
    help                        Show this help

Examples:
    # Generate a new password
    ./account-management.sh gen-password

    # Reset admin password with auto-generated password
    ./account-management.sh reset-password

    # Reset admin password with specific password
    ./account-management.sh reset-password "MyNewSecurePassword123!"

    # Show stored password
    ./account-management.sh show-password

    # Create a view-only user
    ./account-management.sh create-user viewer user

    # Create an admin user
    ./account-management.sh create-user ops-admin admin

Environment Variables:
    RANCHER_NAMESPACE       Rancher namespace (default: cattle-system)
    SECRET_NAME             Credential secret name (default: rancher-admin-creds)
    SECRET_NAMESPACE        Secret namespace (default: kube-world-secrets)
EOF
}

main() {
    local cmd="${1:-help}"
    shift || true
    
    case "$cmd" in
        reset-password)
            reset_password "${1:-}"
            ;;
        gen-password)
            gen_password "${1:-24}"
            ;;
        backup-creds)
            if [[ -z "${1:-}" ]]; then
                error "Password required for backup"
                exit 1
            fi
            backup_creds "$1"
            ;;
        show-password)
            show_password
            ;;
        create-user)
            if [[ -z "${1:-}" ]]; then
                error "Username required"
                exit 1
            fi
            create_user "$1" "${2:-user}"
            ;;
        help|--help|-h)
            show_help
            ;;
        *)
            error "Unknown command: $cmd"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
