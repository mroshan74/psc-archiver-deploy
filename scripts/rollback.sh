#!/usr/bin/env bash
#
# Go back to a previously published image tag.
#
#   ./scripts/rollback.sh <api|web|learner> <tag>
#   ./scripts/rollback.sh api          # lists the tags available locally
#
# Rollback is just a deploy of an older tag: every build is pushed to GHCR
# under its own immutable short-SHA, and compose resolves whatever tag .env
# names. Nothing special happens here.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE="${1:-}"
TAG="${2:-}"

if [[ -z "$SERVICE" ]]; then
  echo "Usage: $0 <api|web|learner> <tag>" >&2
  exit 1
fi

case "$SERVICE" in
  api)     IMAGE_VAR=API_IMAGE ;;
  web)     IMAGE_VAR=WEB_IMAGE ;;
  learner) IMAGE_VAR=LEARNER_IMAGE ;;
  *)       echo "Unknown service '$SERVICE' (expected 'api', 'web', or 'learner')." >&2; exit 1 ;;
esac
IMAGE="$(sed -n "s/^${IMAGE_VAR}=//p" "$SCRIPT_DIR/../.env" | head -1)"

if [[ -z "$TAG" ]]; then
  echo "Tags for ${IMAGE} present on this host:"
  docker image ls "$IMAGE" --format '  {{.Tag}}\t(built {{.CreatedSince}})' | grep -v '^  latest' || true
  echo
  echo "Older builds not listed here are still in GHCR and will be pulled on demand."
  echo "Usage: $0 $SERVICE <tag>"
  exit 0
fi

exec "$SCRIPT_DIR/deploy.sh" "$SERVICE" "$TAG"
