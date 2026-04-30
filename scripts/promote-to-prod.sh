#!/usr/bin/env bash
# Promote the current commit on main to production via signed tag.
#
# This is the only sanctioned path for getting code into the prod
# cluster. The prod cluster's Flux GitRepository tracks `prod-v*` tag
# pattern; tagging triggers reconciliation. Pushes to main alone
# CANNOT reach prod.
#
# Usage:
#   ./scripts/promote-to-prod.sh                   # auto-bump patch
#   ./scripts/promote-to-prod.sh --version 0.5.0   # explicit version
#   ./scripts/promote-to-prod.sh --dry-run         # show what would happen
#
# Pre-flight checks:
#   - On main branch
#   - Working tree clean
#   - Local main is up-to-date with remote
#   - Validate stage of CI passed for the commit being tagged
#   - GPG signing key configured (commits on prod tags MUST be signed)
#
# After tagging:
#   - Pushes the tag to GitLab (Flux source) AND GitHub
#   - Operator must manually approve `prod-apply` in GitLab CI pipeline
#     (the tag fires the prod stage but the apply job is `when: manual`)
#
# The `prod-vN` format is fixed — the prod cluster's GitRepository
# matches via semver, so the version after `prod-v` must be valid
# semver (e.g. `prod-v1.2.3`, NOT `prod-v1`).

set -euo pipefail

DRY_RUN=0
EXPLICIT_VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --version) EXPLICIT_VERSION="$2"; shift 2 ;;
        --help|-h)
            sed -n '2,/^set -euo pipefail/p' "$0"; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

GREEN=$(tput setaf 2 2>/dev/null || true)
YELLOW=$(tput setaf 3 2>/dev/null || true)
RED=$(tput setaf 1 2>/dev/null || true)
RESET=$(tput sgr0 2>/dev/null || true)
log() { printf '%s[promote]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$YELLOW" "$RESET" "$*"; }
err() { printf '%s[error]%s %s\n' "$RED" "$RESET" "$*" >&2; }

# ─────────────────────────────────────────────────────────────────
# Pre-flight
# ─────────────────────────────────────────────────────────────────

# Branch check
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
    err "Current branch is '$BRANCH' — must be on main to promote"
    exit 1
fi

# Working tree clean
if ! git diff --quiet || ! git diff --cached --quiet; then
    err "Working tree has uncommitted changes — commit or stash first"
    git status --short
    exit 1
fi

# Up-to-date with remote
log "Fetching origin..."
git fetch origin main --quiet
LOCAL=$(git rev-parse main)
REMOTE=$(git rev-parse origin/main)
if [[ "$LOCAL" != "$REMOTE" ]]; then
    err "Local main diverges from origin/main — pull/rebase first"
    err "  local : $LOCAL"
    err "  remote: $REMOTE"
    exit 1
fi

# GPG signing key configured
if ! git config --get user.signingkey >/dev/null; then
    err "No git config user.signingkey — set up GPG signing first:"
    err "  gpg --list-secret-keys --keyid-format=long"
    err "  git config --global user.signingkey <KEYID>"
    err "  git config --global commit.gpgsign true   # optional"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Determine next version
# ─────────────────────────────────────────────────────────────────

if [[ -n "$EXPLICIT_VERSION" ]]; then
    NEXT_VERSION="$EXPLICIT_VERSION"
else
    LAST_TAG=$(git tag --list 'prod-v*' --sort=-v:refname | head -1 || true)
    if [[ -z "$LAST_TAG" ]]; then
        NEXT_VERSION="0.1.0"
        log "No prior prod tags — starting at $NEXT_VERSION"
    else
        # Strip prefix, bump patch
        LAST_VER="${LAST_TAG#prod-v}"
        IFS='.' read -r MAJOR MINOR PATCH <<<"$LAST_VER"
        PATCH=$((PATCH + 1))
        NEXT_VERSION="${MAJOR}.${MINOR}.${PATCH}"
        log "Last prod tag: $LAST_TAG → next: prod-v$NEXT_VERSION"
    fi
fi

NEXT_TAG="prod-v$NEXT_VERSION"

# Validate semver-ish
if ! echo "$NEXT_VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.-]+)?$'; then
    err "Version '$NEXT_VERSION' is not valid semver"
    exit 1
fi

# Tag must not already exist
if git rev-parse "$NEXT_TAG" >/dev/null 2>&1; then
    err "Tag $NEXT_TAG already exists"
    exit 1
fi

# ─────────────────────────────────────────────────────────────────
# Confirmation
# ─────────────────────────────────────────────────────────────────

COMMIT_HASH=$(git rev-parse --short HEAD)
COMMIT_MSG=$(git log -1 --pretty=format:"%s")

cat <<EOF

═══════════════════════════════════════════════════════════════════
  PRODUCTION PROMOTION

  Commit  : $COMMIT_HASH  $COMMIT_MSG
  Tag     : $NEXT_TAG
  Branch  : main
  Pushes  : gitlab + origin (GitHub)
  Signed  : YES (GPG)
═══════════════════════════════════════════════════════════════════
EOF

if [[ $DRY_RUN -eq 1 ]]; then
    warn "DRY RUN — no tag will be created"
    exit 0
fi

read -rp "Proceed? [y/N] " ANSWER
if [[ ! "$ANSWER" =~ ^[yY] ]]; then
    log "Aborted."
    exit 0
fi

# ─────────────────────────────────────────────────────────────────
# Create + push tag
# ─────────────────────────────────────────────────────────────────

TAG_MSG="Production release $NEXT_TAG

Commit: $COMMIT_HASH
Promoted from main HEAD via scripts/promote-to-prod.sh.
"

log "Creating signed tag $NEXT_TAG..."
git tag -s "$NEXT_TAG" -m "$TAG_MSG"

log "Pushing to gitlab..."
git push gitlab "$NEXT_TAG"

log "Pushing to origin (GitHub)..."
git push origin "$NEXT_TAG"

cat <<EOF

═══════════════════════════════════════════════════════════════════
  Tag $NEXT_TAG pushed.

  Next: GitLab pipeline for the tag will appear at:
    http://gitlab.kubew.dev/root/kube-world/-/pipelines

  The prod-apply job is MANUAL — go click "Run" when you're ready.
  prod-dryrun-apply will already have run automatically; review its
  output before approving the apply.

  Rollback: re-tag a known-good earlier commit:
    git tag -s prod-v<NEXT> -m '...' <commit>
    git push gitlab prod-v<NEXT>
═══════════════════════════════════════════════════════════════════
EOF
