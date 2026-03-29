#!/usr/bin/env bash
# install-zitadel.sh — Deploy Zitadel identity provider on the central Pi
#
# Installs Zitadel as a native service (like GitLab and ntfy) with PostgreSQL.
# Zitadel provides OIDC/SAML SSO for K8s, Rancher, GitLab, and cloud consoles.
#
# Usage:
#   ./scripts/install-zitadel.sh --pi-ip 10.5.5.249
#   ./scripts/install-zitadel.sh --pi-ip 10.5.5.249 --domain auth.kbw.dev
#   ./scripts/install-zitadel.sh --dry-run
#
# Prerequisites:
#   - SSH access to the Pi as admin
#   - PostgreSQL already running (installed with GitLab) or will be installed
#   - Domain configured (optional, can use IP initially)

set -euo pipefail
IFS=$'\n\t'

#===============================================================================
# Configuration
#===============================================================================
PI_IP="${PI_IP:-10.5.5.249}"
PI_USER="${PI_USER:-admin}"
ZITADEL_VERSION="${ZITADEL_VERSION:-2.67.1}"
ZITADEL_PORT="${ZITADEL_PORT:-8080}"
ZITADEL_DOMAIN="${ZITADEL_DOMAIN:-auth.kbw.dev}"
ZITADEL_DB_NAME="${ZITADEL_DB_NAME:-zitadel}"
ZITADEL_DB_USER="${ZITADEL_DB_USER:-zitadel}"
DRY_RUN="${DRY_RUN:-false}"

#===============================================================================
# Logging
#===============================================================================
log()   { echo -e "\033[0;32m[INFO]\033[0m  $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }
debug() { [[ "${VERBOSE:-false}" == "true" ]] && echo -e "\033[0;34m[DEBUG]\033[0m $*"; }

#===============================================================================
# Argument parsing
#===============================================================================
while [[ $# -gt 0 ]]; do
  case $1 in
    --pi-ip)      PI_IP="$2"; shift 2 ;;
    --pi-user)    PI_USER="$2"; shift 2 ;;
    --domain)     ZITADEL_DOMAIN="$2"; shift 2 ;;
    --version)    ZITADEL_VERSION="$2"; shift 2 ;;
    --port)       ZITADEL_PORT="$2"; shift 2 ;;
    --dry-run)    DRY_RUN=true; shift ;;
    --verbose)    VERBOSE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--pi-ip IP] [--domain DOMAIN] [--dry-run] [--verbose]"
      exit 0
      ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
done

#===============================================================================
# Helpers
#===============================================================================
ssh_cmd() {
  ssh -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
    "${PI_USER}@${PI_IP}" "$@"
}

#===============================================================================
# Step 1: Check prerequisites
#===============================================================================
check_prerequisites() {
  log "Checking prerequisites on ${PI_IP}..."

  if ! ssh_cmd "echo ok" &>/dev/null; then
    error "Cannot SSH to ${PI_USER}@${PI_IP}"
    exit 1
  fi

  # Check architecture
  local arch
  arch=$(ssh_cmd "uname -m")
  if [[ "$arch" != "aarch64" ]]; then
    warn "Expected aarch64, got ${arch}. Continuing anyway."
  fi

  log "Prerequisites OK (arch: ${arch})"
}

#===============================================================================
# Step 2: Install PostgreSQL if not present
#===============================================================================
install_postgresql() {
  log "Checking PostgreSQL..."

  if ssh_cmd "command -v psql" &>/dev/null; then
    log "PostgreSQL already installed"
  else
    log "Installing PostgreSQL..."
    if [[ "$DRY_RUN" == "true" ]]; then
      log "[DRY RUN] Would install postgresql"
      return
    fi
    ssh_cmd "sudo apt-get update -qq && sudo apt-get install -y -qq postgresql postgresql-client"
    ssh_cmd "sudo systemctl enable postgresql && sudo systemctl start postgresql"
  fi

  # Create Zitadel database and user
  log "Configuring Zitadel database..."
  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would create database ${ZITADEL_DB_NAME}"
    return
  fi

  ssh_cmd "sudo -u postgres psql -tc \"SELECT 1 FROM pg_roles WHERE rolname='${ZITADEL_DB_USER}'\" | grep -q 1 || \
    sudo -u postgres psql -c \"CREATE ROLE ${ZITADEL_DB_USER} LOGIN PASSWORD 'zitadel-change-me';\""

  ssh_cmd "sudo -u postgres psql -tc \"SELECT 1 FROM pg_database WHERE datname='${ZITADEL_DB_NAME}'\" | grep -q 1 || \
    sudo -u postgres psql -c \"CREATE DATABASE ${ZITADEL_DB_NAME} OWNER ${ZITADEL_DB_USER};\""

  log "PostgreSQL configured"
}

#===============================================================================
# Step 3: Download and install Zitadel binary
#===============================================================================
install_zitadel() {
  log "Installing Zitadel ${ZITADEL_VERSION}..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would download and install Zitadel ${ZITADEL_VERSION}"
    return
  fi

  # Download arm64 binary
  local download_url="https://github.com/zitadel/zitadel/releases/download/v${ZITADEL_VERSION}/zitadel-linux-arm64.tar.gz"

  ssh_cmd "cd /tmp && \
    curl -fsSL '${download_url}' -o zitadel.tar.gz && \
    tar xzf zitadel.tar.gz && \
    sudo mv zitadel-linux-arm64/zitadel /usr/local/bin/zitadel && \
    sudo chmod +x /usr/local/bin/zitadel && \
    rm -rf zitadel.tar.gz zitadel-linux-arm64"

  log "Zitadel binary installed: $(ssh_cmd '/usr/local/bin/zitadel version' 2>/dev/null || echo 'version check pending')"
}

#===============================================================================
# Step 4: Configure Zitadel
#===============================================================================
configure_zitadel() {
  log "Configuring Zitadel..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would write Zitadel configuration"
    return
  fi

  ssh_cmd "sudo mkdir -p /etc/zitadel"

  # Generate a master key (32 bytes, base64)
  local master_key
  master_key=$(ssh_cmd "openssl rand -base64 32 | tr -d '\\n'")

  # Write configuration
  ssh_cmd "sudo tee /etc/zitadel/config.yaml > /dev/null" <<EOF
Log:
  Level: info
  Formatter:
    Format: text

Port: ${ZITADEL_PORT}

# External domain — how users reach Zitadel
ExternalDomain: ${ZITADEL_DOMAIN}
ExternalPort: 443
ExternalSecure: true

# For initial setup without TLS, use these instead:
# ExternalPort: ${ZITADEL_PORT}
# ExternalSecure: false

# TLS handled by Traefik/Cloudflare, not Zitadel
TLS:
  Enabled: false

Database:
  postgres:
    Host: localhost
    Port: 5432
    Database: ${ZITADEL_DB_NAME}
    User:
      Username: ${ZITADEL_DB_USER}
      Password: zitadel-change-me
      SSL:
        Mode: disable
    Admin:
      Username: postgres
      Password: ""
      SSL:
        Mode: disable
    MaxOpenConns: 20
    MaxIdleConns: 10
    MaxConnLifetime: 30m
    MaxConnIdleTime: 5m

# Master encryption key (change in production)
EncryptionKeys:
  AEAD:
    EncryptionKeyID: "master"
    DecryptionKeyIDs:
      - "master"
    Keys:
      master: "${master_key}"

# First instance configuration
FirstInstance:
  Org:
    Name: kube-world
    Human:
      UserName: admin
      FirstName: Admin
      LastName: User
      # Password set on first login
      Password: "KubeW0rld-Ch4nge-Me!"
      PasswordChangeRequired: true
  DefaultLanguage: en
EOF

  log "Zitadel configured at /etc/zitadel/config.yaml"
}

#===============================================================================
# Step 5: Create systemd service
#===============================================================================
create_service() {
  log "Creating systemd service..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would create zitadel.service"
    return
  fi

  ssh_cmd "sudo tee /etc/systemd/system/zitadel.service > /dev/null" <<'EOF'
[Unit]
Description=Zitadel Identity Provider
After=network.target postgresql.service
Requires=postgresql.service

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/zitadel start-from-init --masterkeyFromEnv --config /etc/zitadel/config.yaml
EnvironmentFile=-/etc/zitadel/env
Restart=on-failure
RestartSec=10
LimitNOFILE=65535

# Resource limits for Pi 5
MemoryMax=1G
CPUQuota=200%

[Install]
WantedBy=multi-user.target
EOF

  # Write the master key as env var for the service
  local master_key
  master_key=$(ssh_cmd "sudo grep -A3 'Keys:' /etc/zitadel/config.yaml | grep 'master:' | awk '{print \$2}' | tr -d '\"'")
  ssh_cmd "sudo tee /etc/zitadel/env > /dev/null <<ENVEOF
ZITADEL_MASTERKEY=${master_key}
ENVEOF"
  ssh_cmd "sudo chmod 600 /etc/zitadel/env"

  ssh_cmd "sudo systemctl daemon-reload"
  ssh_cmd "sudo systemctl enable zitadel"

  log "Systemd service created"
}

#===============================================================================
# Step 6: Create K8s resources for Zitadel access
#===============================================================================
create_k8s_resources() {
  log "Creating K8s Service + Endpoints for Zitadel..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would create K8s resources"
    return
  fi

  ssh_cmd "sudo k3s kubectl apply -f -" <<EOF
---
apiVersion: v1
kind: Namespace
metadata:
  name: zitadel
  labels:
    app.kubernetes.io/name: zitadel
    app.kubernetes.io/part-of: kube-world
---
apiVersion: v1
kind: Endpoints
metadata:
  name: zitadel
  namespace: zitadel
  labels:
    app.kubernetes.io/name: zitadel
    app.kubernetes.io/part-of: kube-world
subsets:
  - addresses:
      - ip: "${PI_IP}"
    ports:
      - name: http
        port: ${ZITADEL_PORT}
        protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: zitadel
  namespace: zitadel
  labels:
    app.kubernetes.io/name: zitadel
    app.kubernetes.io/part-of: kube-world
spec:
  type: ClusterIP
  ports:
    - name: http
      port: 80
      targetPort: 80
      protocol: TCP
EOF

  log "K8s resources created in namespace zitadel"
}

#===============================================================================
# Step 7: Start Zitadel
#===============================================================================
start_zitadel() {
  log "Starting Zitadel..."

  if [[ "$DRY_RUN" == "true" ]]; then
    log "[DRY RUN] Would start Zitadel service"
    return
  fi

  ssh_cmd "sudo systemctl start zitadel"

  # Wait for Zitadel to be ready
  log "Waiting for Zitadel to initialize (first start takes ~30-60 seconds)..."
  local attempts=0
  while [[ $attempts -lt 30 ]]; do
    if ssh_cmd "curl -sf http://localhost:${ZITADEL_PORT}/debug/ready" &>/dev/null; then
      log "Zitadel is ready!"
      return
    fi
    sleep 5
    attempts=$((attempts + 1))
    debug "Waiting... (attempt ${attempts}/30)"
  done

  warn "Zitadel may still be initializing. Check: ssh ${PI_USER}@${PI_IP} 'sudo journalctl -u zitadel -f'"
}

#===============================================================================
# Main
#===============================================================================
main() {
  log "=== Zitadel Identity Provider Installation ==="
  log "Pi: ${PI_USER}@${PI_IP}"
  log "Domain: ${ZITADEL_DOMAIN}"
  log "Version: ${ZITADEL_VERSION}"
  log "Port: ${ZITADEL_PORT}"
  [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN MODE — no changes will be made"
  echo

  check_prerequisites
  install_postgresql
  install_zitadel
  configure_zitadel
  create_service
  create_k8s_resources
  start_zitadel

  echo
  log "=== Installation Complete ==="
  log ""
  log "Zitadel is running at http://${PI_IP}:${ZITADEL_PORT}"
  log ""
  log "Initial admin credentials:"
  log "  Username: admin"
  log "  Password: KubeW0rld-Ch4nge-Me! (change on first login)"
  log ""
  log "Next steps:"
  log "  1. Access Zitadel UI and change admin password"
  log "  2. Configure Traefik HTTPRoute for auth.kbw.dev"
  log "  3. Set up OIDC client for K3s API server"
  log "  4. Set up OIDC client for Rancher"
  log "  5. Set up OIDC client for GitLab"
  log "  6. Configure cloud console federation (AWS/Azure/GCP)"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main "$@"
fi
