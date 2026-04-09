#!/usr/bin/env bash
#===============================================================================
# Run Renovate bot against the self-hosted GitLab instance.
#
# Renovate scans config.yaml, apps/**, and infrastructure/** for version
# references and opens MRs on GitLab when updates are available.
#
# Prerequisites:
#   - Docker installed (runs Renovate in a container)
#   - RENOVATE_TOKEN: GitLab personal access token with api scope
#   - GITLAB_URL: GitLab instance URL (default: https://gitlab.kubew.dev)
#
# Usage:
#   RENOVATE_TOKEN=glpat-xxx ./scripts/run-renovate.sh
#   RENOVATE_TOKEN=glpat-xxx GITLAB_URL=https://gitlab.kubew.dev ./scripts/run-renovate.sh
#===============================================================================
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[RENOVATE]${NC} $*"; }
error() { echo -e "${RED}[RENOVATE]${NC} $*" >&2; }

GITLAB_URL="${GITLAB_URL:-https://gitlab.kubew.dev}"
RENOVATE_TOKEN="${RENOVATE_TOKEN:-}"

if [[ -z "$RENOVATE_TOKEN" ]]; then
    error "RENOVATE_TOKEN is required. Create a GitLab PAT with 'api' scope."
    exit 1
fi

log "Running Renovate against ${GITLAB_URL}..."

docker run --rm \
    -e RENOVATE_PLATFORM=gitlab \
    -e RENOVATE_ENDPOINT="${GITLAB_URL}/api/v4" \
    -e RENOVATE_TOKEN="${RENOVATE_TOKEN}" \
    -e RENOVATE_AUTODISCOVER=true \
    -e LOG_LEVEL=info \
    ghcr.io/renovatebot/renovate:latest

log "Renovate run complete."
