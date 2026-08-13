#!/usr/bin/env bash
#
# Deploy one service to a specific, immutable image tag.
#
#   ./scripts/deploy.sh <api|web|learner> <tag>
#
#     api      NestJS backend      (psc-archiver-api)
#     web      staff back office   (psc-archiver-admin)
#     learner  learner-facing app  (psc-archiver-client)
#
# Invoked over SSH by GitHub Actions, and by hand for rollbacks. Safe to run
# repeatedly; deploying the tag that is already live is a no-op restart.
#
# Downtime is accepted: the container is recreated in place, so there is a few
# seconds of 502 while it comes back. What is NOT accepted is a deploy that
# silently half-works — hence the env check before anything is touched and the
# readiness check after.

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; NC='\033[0m'
step()  { echo -e "${BLUE}==> $*${NC}"; }
ok()    { echo -e "${GREEN}✓ $*${NC}"; }
warn()  { echo -e "${YELLOW}! $*${NC}"; }
fail()  { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$DEPLOY_DIR/compose.prod.yml"
PROJECT_NAME="psc-archiver"
ENV_FILE="$DEPLOY_DIR/.env"
ENV_TEMPLATE="$DEPLOY_DIR/.env.example"
# One shared lock for every account that can deploy. A per-user filename would
# mean root and the deploy user take *different* locks and so never exclude
# each other, which defeats the point. The "permission denied" that motivated
# scoping it per-user is a file-mode problem, and is fixed below by creating
# the file 0666 — it is a lock token holding no data, so that costs nothing.
LOCK_FILE="$DEPLOY_DIR/.deploy.lock"

SERVICE="${1:-}"
TAG="${2:-}"

[[ -n "$SERVICE" && -n "$TAG" ]] || fail "Usage: $0 <api|web|learner> <tag>"
case "$SERVICE" in
  api|web|learner) ;;
  *) fail "Unknown service '$SERVICE' (expected 'api', 'web', or 'learner')." ;;
esac

# One deploy at a time. Two pushes in quick succession would otherwise
# interleave their pull/up steps against the same compose project — and since
# `sed -i` below rewrites .env via a temp file and a rename, an interleave
# silently drops one of the two tag edits and reports success for a tag that
# was never applied. GitHub's `concurrency:` group cannot prevent this: api,
# admin and client are three separate repos with three separate groups, so
# their workflows can reach this server at the same moment.
#
# flock is part of util-linux and always present on the server; it is missing
# on Windows/macOS, where this script is only ever smoke-tested.
if command -v flock >/dev/null 2>&1; then
  # Created under umask 000 so whichever account gets here first does not lock
  # the other out with EACCES on `exec 9>>`.
  (umask 000; : >>"$LOCK_FILE") 2>/dev/null || true
  exec 9>>"$LOCK_FILE"
  flock -w 300 9 || fail "Another deploy has held the lock for over 5 minutes."
else
  warn "flock unavailable — running without a concurrency lock."
fi

cd "$DEPLOY_DIR"

# ── 1. Refresh infra config from git ───────────────────────────────────────
# The repo is the source of truth for compose files and scripts. Hand-editing
# them on the server is how the previous projects drifted out of sync.
step "Updating deploy configuration"
if ! git -C "$DEPLOY_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  warn "$DEPLOY_DIR is not a git checkout — cannot verify it matches the repo."
elif ! git -C "$DEPLOY_DIR" remote | grep -q .; then
  warn "No git remote configured — skipping update."
elif ! (git -C "$DEPLOY_DIR" diff --quiet && git -C "$DEPLOY_DIR" diff --cached --quiet); then
  warn "Local changes present in $DEPLOY_DIR — skipping git pull."
  warn "Commit or discard them so the server matches the repo."
else
  git -C "$DEPLOY_DIR" pull --ff-only --quiet
  ok "Configuration is at $(git -C "$DEPLOY_DIR" rev-parse --short HEAD)"
fi

# ── 2. Validate the environment BEFORE touching the running stack ──────────
step "Checking environment"
[[ -f "$ENV_FILE" ]] || fail "$ENV_FILE is missing. Copy .env.example and fill it in."

env_keys() {
  # Key names only: strip comments, blank lines, and values.
  sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$1" | sort -u
}

missing="$(comm -23 <(env_keys "$ENV_TEMPLATE") <(env_keys "$ENV_FILE") || true)"
if [[ -n "$missing" ]]; then
  echo -e "${RED}Missing from $ENV_FILE:${NC}" >&2
  echo "$missing" | sed 's/^/    /' >&2
  fail "Environment is incomplete. Nothing was changed."
fi
ok "All $(env_keys "$ENV_TEMPLATE" | wc -l | tr -d ' ') expected keys present"

# ── 3. Record the tag (this is the rollback trail) ─────────────────────────
case "$SERVICE" in
  api)     TAG_VAR=API_TAG ;;
  web)     TAG_VAR=WEB_TAG ;;
  learner) TAG_VAR=LEARNER_TAG ;;
esac
PREVIOUS_TAG="$(sed -n "s/^${TAG_VAR}=//p" "$ENV_FILE" | head -1)"

step "Setting ${TAG_VAR}=${TAG} (was ${PREVIOUS_TAG:-unset})"
if grep -q "^${TAG_VAR}=" "$ENV_FILE"; then
  sed -i "s|^${TAG_VAR}=.*|${TAG_VAR}=${TAG}|" "$ENV_FILE"
else
  echo "${TAG_VAR}=${TAG}" >> "$ENV_FILE"
fi

# The API stamps BUILD_ID into every token it issues, so bumping it on deploy
# retires sessions minted by the previous build.
if [[ "$SERVICE" == "api" ]]; then
  if grep -q "^BUILD_ID=" "$ENV_FILE"; then
    sed -i "s|^BUILD_ID=.*|BUILD_ID=${TAG}|" "$ENV_FILE"
  else
    echo "BUILD_ID=${TAG}" >> "$ENV_FILE"
  fi
fi

# ── 4. Pull, then recreate just this service ───────────────────────────────
step "Pulling ${SERVICE}:${TAG}"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" pull "$SERVICE"

step "Starting ${SERVICE}"
# --no-deps so an api deploy never bounces web, and vice versa.
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --no-deps "$SERVICE"

# ── 5. Verify. A container that started is not a deploy that worked. ───────
# Probe through the nginx of the tier just deployed, so a learner deploy is
# proved through the learner's own proxy rather than the admin's. An api deploy
# is still proved through `web`, unchanged.
PROBE_SERVICE="$([[ "$SERVICE" == "learner" ]] && echo learner || echo web)"

step "Waiting for the app to respond (via ${PROBE_SERVICE})"
probe() {
  # Checked from inside a web container, which exercises the real path a
  # browser takes: nginx -> (proxy) -> api.
  #
  # 127.0.0.1, NOT localhost: Docker's /etc/hosts maps localhost to both
  # 127.0.0.1 and ::1, BusyBox wget tries ::1 first, and nginx's `listen 80`
  # binds IPv4 only — so the localhost form is refused on every attempt and
  # this loop could only ever time out.
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" \
    exec -T "$PROBE_SERVICE" wget -q -O /dev/null "http://127.0.0.1/api/readyz" 2>/dev/null
}

deadline=$((SECONDS + 60))
until probe; do
  if (( SECONDS >= deadline )); then
    echo >&2
    echo -e "${RED}Recent ${SERVICE} logs:${NC}" >&2
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs --tail 40 "$SERVICE" >&2 || true
    echo >&2
    warn "The stack is still running the newly pulled image."
    warn "To go back:  ./scripts/rollback.sh ${SERVICE} ${PREVIOUS_TAG:-<previous-tag>}"
    fail "App did not become ready within 60s."
  fi
  sleep 3
done
ok "App is responding"

# ── 6. Reclaim disk, but keep a week of rollback targets ───────────────────
# A bare `docker image prune -f` deletes the image you would roll back to.
step "Pruning images older than 7 days"
docker image prune -f --filter "until=168h" >/dev/null

echo
ok "Deployed ${SERVICE}:${TAG}"
echo -e "  previous: ${PREVIOUS_TAG:-unknown}   roll back with: ./scripts/rollback.sh ${SERVICE} ${PREVIOUS_TAG:-<tag>}"
