#!/usr/bin/env bash
#
# Stop everything, pull the newest images, start everything again.
#
#   ./scripts/deploy-latest.sh [--tag <tag>] [--no-down] [--seed]
#
# The manual loop for MVP test rounds, for use until the git pipelines are
# driving deploys. Every app workflow publishes `:latest` next to its immutable
# `:<short-sha>` tag, so this picks up whatever was last built without anyone
# having to look a SHA up.
#
# How this differs from deploy.sh, which is the real deployment path:
#
#   deploy.sh          one service, one pinned tag, --no-deps, keeps a rollback
#                      trail in .env. What CI runs.
#   deploy-latest.sh   all three services at once, floating tag, full restart.
#                      No rollback trail: while .env says `latest` there is no
#                      record of which build is live.
#
# So this is a convenience, not a replacement. When the pipelines land, go back
# to pinned tags — that is what compose.prod.yml's "never :latest" comment is
# about.

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
# The SAME lock deploy.sh takes. A separate file would let a refresh and a CI
# deploy interleave their `sed -i` on .env and their pull/up on one compose
# project, which is the exact race deploy.sh's lock exists to prevent.
LOCK_FILE="$DEPLOY_DIR/.deploy.lock"

TAG="latest"
DO_DOWN=1
DO_SEED=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--tag)   TAG="${2:-}"; [[ -n "$TAG" ]] || fail "--tag needs a value."; shift 2 ;;
    --no-down)  DO_DOWN=0; shift ;;
    --seed)     DO_SEED=1; shift ;;
    -h|--help)
      sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^#\{1,2\} \?//'
      exit 0 ;;
    *) fail "Unknown argument '$1'. Try --help." ;;
  esac
done

if command -v flock >/dev/null 2>&1; then
  (umask 000; : >>"$LOCK_FILE") 2>/dev/null || true
  exec 9>>"$LOCK_FILE"
  flock -w 300 9 || fail "Another deploy has held the lock for over 5 minutes."
else
  warn "flock unavailable — running without a concurrency lock."
fi

cd "$DEPLOY_DIR"

# ── 1. Refresh infra config from git ───────────────────────────────────────
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
  sed -n 's/^[[:space:]]*\([A-Za-z_][A-Za-z0-9_]*\)[[:space:]]*=.*/\1/p' "$1" | sort -u
}

missing="$(comm -23 <(env_keys "$ENV_TEMPLATE") <(env_keys "$ENV_FILE") || true)"
if [[ -n "$missing" ]]; then
  echo -e "${RED}Missing from $ENV_FILE:${NC}" >&2
  echo "$missing" | sed 's/^/    /' >&2
  fail "Environment is incomplete. Nothing was changed."
fi
ok "All $(env_keys "$ENV_TEMPLATE" | wc -l | tr -d ' ') expected keys present"

# ── 3. Point every service at the tag, and stamp BUILD_ID ──────────────────
set_key() {
  local key="$1" value="$2"
  if grep -q "^${key}=" "$ENV_FILE"; then
    sed -i "s|^${key}=.*|${key}=${value}|" "$ENV_FILE"
  else
    echo "${key}=${value}" >> "$ENV_FILE"
  fi
}

PREVIOUS="$(sed -n 's/^API_TAG=//p' "$ENV_FILE" | head -1)"
step "Setting API_TAG / WEB_TAG / LEARNER_TAG to '${TAG}' (api was ${PREVIOUS:-unset})"
set_key API_TAG "$TAG"
set_key WEB_TAG "$TAG"
set_key LEARNER_TAG "$TAG"

# The API stamps BUILD_ID into every token it issues, so changing it retires
# sessions minted by the previous build. A floating tag never changes on its
# own, so without a timestamp here a tester keeps a token from the old build
# and `GET /api/readyz` reports a version that is no longer running.
if [[ "$TAG" == "latest" ]]; then
  BUILD_ID="$(date +%y%m%d%H%M)-latest"
else
  BUILD_ID="$TAG"
fi
set_key BUILD_ID "$BUILD_ID"
ok "BUILD_ID=${BUILD_ID}"

# ── 4. Stop, pull, start ───────────────────────────────────────────────────
if (( DO_DOWN )); then
  # No -v, ever. That would delete the ai_tagging_jobs volume, and OpenAI batch
  # jobs run for minutes to 24 hours with their artefacts on it. It is also not
  # a way to reset data: the database is Atlas, which no compose command here
  # touches.
  step "Stopping all app services"
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down
else
  step "Leaving the stack up (--no-down); compose will recreate what changed"
fi

step "Pulling ${TAG} images"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" pull

step "Starting all app services"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d

# ── 5. Verify through BOTH nginx tiers ─────────────────────────────────────
# Everything restarted, so both proxies are worth proving rather than just one
# the way a single-service deploy does.
probe() {
  # 127.0.0.1, NOT localhost: BusyBox wget tries ::1 first and nginx's
  # `listen 80` is IPv4-only, so the localhost form can only ever time out.
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" \
    exec -T "$1" wget -q -O /dev/null "http://127.0.0.1/api/readyz" 2>/dev/null
}

for tier in web learner; do
  step "Waiting for the app to respond (via ${tier})"
  deadline=$((SECONDS + 90))
  until probe "$tier"; do
    if (( SECONDS >= deadline )); then
      echo >&2
      echo -e "${RED}Recent api logs:${NC}" >&2
      docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" logs --tail 40 api >&2 || true
      echo >&2
      warn "The stack is running the newly pulled images."
      warn "To pin a known-good build instead:  ./scripts/deploy.sh api <short-sha>"
      fail "App did not become ready within 90s (via ${tier})."
    fi
    sleep 3
  done
  ok "${tier} is responding"
done

# ── 6. Seed, only when asked ───────────────────────────────────────────────
if (( DO_SEED )); then
  step "Seeding (System organization, superadmin, taxonomy, papers and questions)"
  docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" --profile seed run --rm seed
fi

# ── 7. Reclaim disk, but keep a week of recovery targets ───────────────────
# Each `latest` pull orphans the previous image, and the api image is not
# small, so this loop accumulates faster than a pinned deploy does. The 7-day
# window is kept anyway: those untagged layers are the only way back to the
# build you were running before this refresh. `docker image prune -af` when
# disk actually gets tight.
step "Pruning images older than 7 days"
docker image prune -f --filter "until=168h" >/dev/null

echo
ok "All services are running ${TAG} (BUILD_ID=${BUILD_ID})"
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" images
if (( ! DO_SEED )); then
  echo
  echo -e "  Seed a fresh database with:"
  echo -e "    docker compose -f compose.prod.yml -p psc-archiver --profile seed run --rm seed"
  echo -e "  or re-run this with --seed."
fi
if [[ "$TAG" == "latest" ]]; then
  echo
  warn "Tags are floating. rollback.sh needs a pinned tag, so there is no way back"
  warn "from here — pin a short SHA with ./scripts/deploy.sh <service> <sha> first."
fi
