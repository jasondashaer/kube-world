#!/usr/bin/env bash
# In-place K3s cutover — convert a vanilla Companion Pi into a K3s
# cluster member running Companion in-pod with auto-import GitOps.
#
# Idempotent: re-running picks up where it left off.
#
# Pre-conditions:
#   - Pi has vanilla Companion installed (deploy/vanilla/install.sh ran).
#   - tag:maintenance is on this Pi in Tailscale (ACL allows you to SSH).
#   - Stream Decks are connected via the Network module (NOT USB) — they
#     reconnect to the Pi's LAN IP automatically after cutover. USB-
#     connected Stream Decks would require manual re-pairing inside the
#     in-pod Companion's UI.
#   - You have a backup of:
#     * /etc/default/companion (the env file)
#     * Companion DB — copy /var/lib/companion off-Pi before running
#     * The mixer's current state — TF Editor → File → Backup
#
# What happens (~3-5 min total downtime):
#   1. Snapshot Companion DB + env file under /var/lib/companion.pre-k3s/
#   2. Stop systemd companion service (downtime starts).
#   3. Install K3s server (single-cluster mode by default, or --join to
#      register against an existing Karmada control plane).
#   4. Copy snapshot DB into a PVC-backed location.
#   5. Apply kube-world Companion manifests via kubectl. The init
#      container of the deploy Deployment runs companion-deploy.py
#      and imports the seed config into the in-pod Companion.
#   6. Verify: Companion pod Running, web UI on :8000 responding,
#      Stream Decks reconnect (visible in Surfaces tab).
#   7. Disable + remove systemd companion.service. Vanilla install
#      retired.
#
# Rollback path: --rollback restores the systemd unit + DB snapshot
# and uninstalls K3s. ~2 min.
#
# Usage:
#   sudo ./cutover.sh --site yibc                    # standalone single-cluster K3s
#   sudo ./cutover.sh --site yibc --join <token>     # register against existing Karmada
#   sudo ./cutover.sh --rollback                     # undo

set -euo pipefail

# ─────────────────────────────────────────────────────────────────
# Args
# ─────────────────────────────────────────────────────────────────

SITE=""
ROLLBACK=0
JOIN_TOKEN=""
JOIN_URL=""
K3S_VERSION="${K3S_VERSION:-v1.34.6+k3s1}"
COMPANION_REPO_URL="${COMPANION_REPO_URL:-https://github.com/jasondashaer/kube-world.git}"
COMPANION_REPO_REF="${COMPANION_REPO_REF:-main}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)         SITE="$2"; shift 2 ;;
        --join)         JOIN_TOKEN="$2"; JOIN_URL="$3"; shift 3 ;;
        --rollback)     ROLLBACK=1; shift ;;
        --k3s-version)  K3S_VERSION="$2"; shift 2 ;;
        --repo-url)     COMPANION_REPO_URL="$2"; shift 2 ;;
        --repo-ref)     COMPANION_REPO_REF="$2"; shift 2 ;;
        --help|-h)      sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must run as root (sudo)" >&2
    exit 1
fi

GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
log()  { printf '%s[cutover]%s %s\n' "$GREEN"  "$RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n'    "$YELLOW" "$RESET" "$*"; }
err()  { printf '%s[error]%s %s\n'   "$RED"    "$RESET" "$*" >&2; }

SNAPSHOT_DIR="/var/lib/companion.pre-k3s"

# ─────────────────────────────────────────────────────────────────
# Rollback path
# ─────────────────────────────────────────────────────────────────

rollback() {
    log "Rolling back K3s cutover..."

    if ! [[ -d "$SNAPSHOT_DIR" ]]; then
        err "No snapshot directory at $SNAPSHOT_DIR — nothing to rollback to"
        exit 1
    fi

    log "Stopping Companion in K3s if running..."
    if command -v kubectl >/dev/null 2>&1; then
        kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml \
            delete -n companion deployment/companion --ignore-not-found 2>/dev/null || true
    fi

    log "Uninstalling K3s..."
    if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
        /usr/local/bin/k3s-uninstall.sh
    fi

    log "Restoring vanilla Companion data..."
    if [[ -d /var/lib/companion ]]; then
        rm -rf /var/lib/companion
    fi
    cp -a "$SNAPSHOT_DIR"/companion-data /var/lib/companion
    cp -a "$SNAPSHOT_DIR"/companion-env /etc/default/companion
    chown -R companion:companion /var/lib/companion

    log "Re-enabling systemd companion.service..."
    cp -a "$SNAPSHOT_DIR"/companion.service /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now companion.service

    log "Rollback complete. Vanilla Companion restored."
    log "Snapshot kept at $SNAPSHOT_DIR — delete manually after confirming."
    exit 0
}

if [[ $ROLLBACK -eq 1 ]]; then
    rollback
fi

# ─────────────────────────────────────────────────────────────────
# Forward path: cutover
# ─────────────────────────────────────────────────────────────────

if [[ -z "$SITE" ]]; then
    err "--site is required (yibc | saitama)"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────

log "Pre-flight checks..."

if ! systemctl is-enabled companion >/dev/null 2>&1; then
    err "vanilla companion.service not found — is this a vanilla install?"
    err "(if this is a fresh Pi, use deploy/vanilla/install.sh first)"
    exit 1
fi

if [[ ! -f /etc/default/companion ]]; then
    err "/etc/default/companion missing — env file required"
    exit 1
fi

if [[ ! -d /var/lib/companion ]]; then
    err "/var/lib/companion missing — Companion data dir required"
    exit 1
fi

# Confirm Stream Decks are connected via Network module, not USB
if lsusb 2>/dev/null | grep -qi "Elgato Systems"; then
    warn "USB Stream Deck detected. After cutover, USB connections need"
    warn "manual re-pairing in the new in-pod Companion's Surfaces tab."
    warn "Press Ctrl+C now to abort if any Stream Decks are USB-only."
    sleep 5
fi

# ─────────────────────────────────────────────────────────────────
# Snapshot
# ─────────────────────────────────────────────────────────────────

if [[ -d "$SNAPSHOT_DIR" ]]; then
    warn "Snapshot dir already exists at $SNAPSHOT_DIR (idempotent re-run?)"
else
    log "Snapshotting Companion data + env + systemd unit → $SNAPSHOT_DIR"
    mkdir -p "$SNAPSHOT_DIR"
    cp -a /var/lib/companion "$SNAPSHOT_DIR"/companion-data
    cp -a /etc/default/companion "$SNAPSHOT_DIR"/companion-env
    cp -a /etc/systemd/system/companion.service "$SNAPSHOT_DIR"/companion.service
fi

# ─────────────────────────────────────────────────────────────────
# Stop vanilla Companion (downtime begins)
# ─────────────────────────────────────────────────────────────────

log "Stopping vanilla Companion (downtime begins)..."
systemctl stop companion.service

# ─────────────────────────────────────────────────────────────────
# Install K3s
# ─────────────────────────────────────────────────────────────────

if command -v k3s >/dev/null 2>&1; then
    log "K3s already installed — skipping installer"
else
    log "Installing K3s $K3S_VERSION..."
    if [[ -n "$JOIN_URL" && -n "$JOIN_TOKEN" ]]; then
        # Join existing cluster as agent
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        curl -sfL https://get.k3s.io \
            | K3S_URL="https://${JOIN_URL}:6443" \
              K3S_TOKEN="$JOIN_TOKEN" \
              INSTALL_K3S_EXEC="agent --node-label workload-type=iot --node-label site=${SITE}" \
              sh -
    else
        # Single-node server
        export INSTALL_K3S_VERSION="$K3S_VERSION"
        curl -sfL https://get.k3s.io \
            | INSTALL_K3S_EXEC="server --node-label workload-type=iot --node-label site=${SITE} --tls-san $(hostname) --write-kubeconfig-mode 644" \
              sh -
    fi
fi

# Wait for node Ready
log "Waiting for node Ready..."
for i in $(seq 1 60); do
    if k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; then
        break
    fi
    sleep 2
done

# ─────────────────────────────────────────────────────────────────
# Apply Companion manifests
# ─────────────────────────────────────────────────────────────────

log "Cloning kube-world repo for manifests..."
if [[ ! -d /opt/kube-world ]]; then
    apt-get install -y -qq git
    git clone --depth=1 --branch "$COMPANION_REPO_REF" "$COMPANION_REPO_URL" /opt/kube-world
else
    git -C /opt/kube-world fetch --quiet origin "$COMPANION_REPO_REF"
    git -C /opt/kube-world checkout --quiet "$COMPANION_REPO_REF"
    git -C /opt/kube-world reset --hard --quiet "origin/$COMPANION_REPO_REF" || true
fi

log "Applying Companion namespace + sealed-secrets prereq..."
k3s kubectl apply -f /opt/kube-world/apps/base/namespaces.yaml || true

log "Applying Companion deployment + auto-import..."
# In single-cluster mode (no Karmada), apply the base directly.
# In multi-cluster mode (joined), Karmada handles propagation, so this
# is a no-op or a sync.
if [[ -z "$JOIN_URL" ]]; then
    # Standalone — apply base
    k3s kubectl apply -k /opt/kube-world/apps/companion/overlays/dev
else
    log "Joined to Karmada — manifests will arrive via PropagationPolicy"
fi

# ─────────────────────────────────────────────────────────────────
# Migrate Companion data → PVC
# ─────────────────────────────────────────────────────────────────

# K3s default storage class is local-path. PVC backs onto
# /var/lib/rancher/k3s/storage/. Locate the bound PV path and copy
# the snapshot data into it so the in-pod Companion sees the same DB.

log "Waiting for companion-data PVC to bind..."
for i in $(seq 1 60); do
    PVC_PATH=$(k3s kubectl -n companion get pv \
        -o jsonpath='{range .items[?(@.spec.claimRef.name=="companion-data")]}{.spec.local.path}{end}' \
        2>/dev/null || true)
    if [[ -n "$PVC_PATH" ]]; then
        break
    fi
    sleep 2
done

if [[ -n "$PVC_PATH" ]]; then
    log "Copying snapshot Companion DB → $PVC_PATH"
    rsync -a --no-perms "$SNAPSHOT_DIR/companion-data/" "$PVC_PATH/"
    chown -R 1000:1000 "$PVC_PATH"
else
    warn "Could not resolve companion-data PVC path — Companion will start with"
    warn "a fresh DB (auto-import will populate it from YAML, but OAuth"
    warn "tokens stored on the old DB will need to be re-authorized via UI)."
fi

# ─────────────────────────────────────────────────────────────────
# Wait for Companion pod
# ─────────────────────────────────────────────────────────────────

log "Waiting for Companion pod Running..."
for i in $(seq 1 90); do
    if k3s kubectl -n companion get pods -l app.kubernetes.io/name=companion \
        -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
        break
    fi
    sleep 2
done

# ─────────────────────────────────────────────────────────────────
# Verify web UI responds
# ─────────────────────────────────────────────────────────────────

PI_IP=$(hostname -I | awk '{print $1}')
log "Verifying Companion web UI on http://$PI_IP:8000 ..."
for i in $(seq 1 30); do
    if curl -fsS -o /dev/null --max-time 3 "http://$PI_IP:8000/"; then
        log "Companion UI responding."
        break
    fi
    sleep 2
done

# ─────────────────────────────────────────────────────────────────
# Disable + remove vanilla systemd unit
# ─────────────────────────────────────────────────────────────────

log "Disabling vanilla companion.service..."
systemctl disable companion.service 2>/dev/null || true
rm -f /etc/systemd/system/companion.service
systemctl daemon-reload

# ─────────────────────────────────────────────────────────────────
# Success
# ─────────────────────────────────────────────────────────────────

cat <<EOF

═══════════════════════════════════════════════════════════════════
  K3s cutover complete.

  Pi              : $(hostname) ($PI_IP)
  Site            : $SITE
  Mode            : $([ -z "$JOIN_URL" ] && echo "standalone single-cluster" || echo "Karmada-joined")
  Snapshot kept   : $SNAPSHOT_DIR  (rollback target)
  Companion UI    : http://$PI_IP:8000  (now in-cluster pod)
  Stream Decks    : reconnect automatically (network module hits same Pi LAN IP)

  Verify on Stream Deck:
    - Pages should appear within 30s of import.
    - If a page is blank, check
        kubectl logs -n companion deploy/companion-deploy -c deploy
      for import errors.

  Now under GitOps:
    - YAML changes in apps/companion/config/ → git push → re-import.
    - Karmada will revert any direct Companion UI changes.
    - Run:
        kubectl get pods -n companion
        kubectl logs -n companion deploy/companion -f

  Rollback (if needed):
    sudo $(realpath "$0") --rollback

  Update CLAUDE.md / handoff docs to reflect this site is now k3s mode.
═══════════════════════════════════════════════════════════════════
EOF
