#!/usr/bin/env bash
#
# Sets up the APPLICATION on a server that has already been provisioned. Run it
# once, by hand, over SSH, before the first CI deploy — CI never runs this
# script; it only runs deploy.sh, which exists on the box because this ran.
#
#   ssh <account>@<vps>
#   curl -fsSL https://raw.githubusercontent.com/<owner>/psc-archiver-deploy/master/scripts/setup-app.sh | bash
#
# or clone the repo first and run it locally. Safe to re-run.
#
# WHICHEVER ACCOUNT YOU RUN THIS AS IS THE ACCOUNT CI MUST CONNECT AS. Every
# check below tests that account, not a hardcoded one, and the script prints it
# at the end for the VPS_USER GitHub secret. Setting up as one account while CI
# connects as another is the classic failure: deploy.sh's `git pull` and its
# `sed -i` on .env both fail with "permission denied".
#
# This script does NOT install packages, create users or groups, write SSH keys,
# change sshd configuration, or touch the firewall — those belong to whoever
# provisions the server, not to an application deploy. See README.md's
# "Prerequisites" for the full list of what must already be true.
#
# It is interactive where it has to be. Nothing privileged and nothing that
# stores a credential happens silently: the exact command is printed first and
# runs only after you answer y. Answer n to the privileged one and it stops
# having changed nothing; answer n to the GHCR login and it carries on, leaving
# that in the printed steps for later.
#
# Afterwards you still have to, by hand — the script prints these and saves them
# to /opt/psc-archiver/REMAINING-STEPS.txt:
#   1. fill in /opt/psc-archiver/.env      (copied from .env.example)
#   2. set the VPS_USER / VPS_HOST / VPS_SSH_KEY GitHub secrets
#   3. point APP_HOST's DNS A record at this server
#   4. bring up Traefik — that is what creates the shared traefik_proxy network
#   5. log in to GHCR, if you declined the prompt for it here

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
note() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

APP_DIR="${APP_DIR:-/opt/psc-archiver}"
REPO_URL="${REPO_URL:-https://github.com/mroshan74/psc-archiver-deploy.git}"
RUN_AS="$(id -un)"

# ── Prompting ──────────────────────────────────────────────────────────────
# Every prompt reads from /dev/tty, never stdin. This script is documented as
# `curl … | bash`, where stdin is the script text itself — a plain `read` would
# swallow the rest of the script instead of waiting for you. When there is no
# terminal at all (a non-interactive run), there is nobody to ask: every prompt
# answers "no" and the caller decides whether that is fatal.
#
# The check is an actual open, in a subshell, not `[[ -r /dev/tty ]]`: the test
# reports true even where opening fails (a process with no controlling
# terminal), and the subshell keeps a failure from touching this shell.
have_tty() { ( : >/dev/tty ) 2>/dev/null; }

ask() {
  local reply
  have_tty || return 1
  printf '%b' "${YELLOW}$1 [y/N] ${NC}" >/dev/tty
  read -r reply </dev/tty || return 1
  [[ "$reply" == [Yy] || "$reply" == [Yy][Ee][Ss] ]]
}

# Nothing privileged runs without being shown in full and agreed to first, and
# declining leaves the server exactly as it was.
request_sudo() {
  local what="$1"; shift
  local shown="" arg
  for arg in "$@"; do shown+=" $(printf '%q' "$arg")"; done

  note "$what needs one privileged command:"
  echo "    sudo$shown"
  ask "Run it now?" || fail \
"Stopped — nothing was changed. Run that command yourself, or have whoever
administers this server run it, then re-run this script."
  sudo "$@" || fail "That command failed. Run it by hand to see why, then re-run this script."
}

# ── Prerequisites ──────────────────────────────────────────────────────────
# Everything here is a check, never a fix. Each probe tests the account running
# this script for something deploy.sh will later need as that same account:
# `docker info` covers the socket (root or docker-group membership, in one
# probe, without guessing which); a writable $APP_DIR covers both
# `git pull --ff-only` and the `sed -i` on .env — GNU sed -i writes a temp file
# and renames it, so it needs the directory, not just the file.
step "Checking prerequisites (as '$RUN_AS')"

if ! command -v docker >/dev/null 2>&1; then
  fail "Docker is not installed. Ask whoever provisions this server for Docker Engine with the Compose plugin: https://docs.docker.com/engine/install/"
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker is installed but the Compose plugin ('docker compose') is missing. Ask for it to be installed: https://docs.docker.com/compose/install/"
fi
if ! docker info >/dev/null 2>&1; then
  fail "'$RUN_AS' cannot reach the Docker daemon. Ask for this account to be added to the 'docker' group, then reconnect so the new group takes effect."
fi
ok "Docker reachable as '$RUN_AS' ($(docker --version))"

if [[ "$(id -u)" -eq 0 ]]; then
  note "Running as root, so CI would need VPS_USER=root. A dedicated service"
  note "account is preferred — re-run this as that account instead if you have one."
fi

# ── Application directory ──────────────────────────────────────────────────
# /opt, not a personal home directory — the server layout should not depend on
# who set it up. Creating a directory under /opt needs root, which is the one
# privileged thing this script does; it creates that directory and nothing
# else, and hands off cleanly when it can't.
# Numeric gid, not `id -gn`: a group name is not guaranteed to resolve on every
# host, and `install`/`chown` accept the number just as well.
RUN_GID="$(id -g)"

if [[ ! -d "$APP_DIR" ]]; then
  step "$APP_DIR does not exist yet"
  request_sudo "Creating it, owned by '$RUN_AS'" \
    install -d -o "$RUN_AS" -g "$RUN_GID" -m 755 "$APP_DIR"
fi

if [[ ! -w "$APP_DIR" ]]; then
  step "$APP_DIR is not writable by '$RUN_AS'"
  note "Deploys run as this account and have to write there — both the git pull"
  note "and the tag rewrite in .env need it."
  request_sudo "Handing $APP_DIR to '$RUN_AS'" \
    chown -R "$RUN_AS:$RUN_GID" "$APP_DIR"
  [[ -w "$APP_DIR" ]] || fail "$APP_DIR is still not writable by '$RUN_AS'."
fi
ok "$APP_DIR is writable by '$RUN_AS'"

# ── Deploy checkout ────────────────────────────────────────────────────────
if [[ ! -d "$APP_DIR/.git" ]]; then
  step "Cloning $REPO_URL to $APP_DIR"
  git clone --quiet "$REPO_URL" "$APP_DIR"
else
  step "Updating $APP_DIR"
  git -C "$APP_DIR" pull --ff-only --quiet
fi
chmod +x "$APP_DIR"/scripts/*.sh

if [[ ! -f "$APP_DIR/.env" ]]; then
  cp "$APP_DIR/.env.example" "$APP_DIR/.env"
  chmod 600 "$APP_DIR/.env"
  ok "Created $APP_DIR/.env from the template"
else
  ok "$APP_DIR/.env already exists — left untouched"
fi

# ── GHCR access ────────────────────────────────────────────────────────────
# Both images are private, so every deploy fails with "unauthorized" until this
# account has logged in once. Offered here rather than left to the printed steps
# because forgetting it is the single most common first-deploy failure.
#
# The PAT is read with `read -rs` straight into `docker login --password-stdin`:
# never echoed, never a shell argument (which would put it in the process list),
# never written anywhere except Docker's own config.
GHCR_DONE="no"
DOCKER_CFG="${DOCKER_CONFIG:-$HOME/.docker}/config.json"

step "Checking GHCR access"
if [[ -f "$DOCKER_CFG" ]] && grep -q '"ghcr\.io"' "$DOCKER_CFG"; then
  GHCR_DONE="yes"
  ok "Credentials for ghcr.io are already stored for '$RUN_AS'"
else
  note "Both images are private — deploys fail with \"unauthorized\" until '$RUN_AS' logs in once."
  note "The command that will run:"
  echo "    echo \"<PAT>\" | docker login ghcr.io -u <github-username> --password-stdin"
  note "The PAT comes from github.com/settings/tokens — classic, scope read:packages."

  if ask "Log in to ghcr.io now?"; then
    ghcr_user=""
    ghcr_pat=""
    printf '%b' "${BLUE}  GitHub username: ${NC}" >/dev/tty
    read -r ghcr_user </dev/tty || true
    printf '%b' "${BLUE}  PAT (not shown as you type or paste): ${NC}" >/dev/tty
    read -rs ghcr_pat </dev/tty || true
    echo >/dev/tty

    if [[ -z "$ghcr_user" || -z "$ghcr_pat" ]]; then
      note "Username or PAT was empty — skipped. It's in the steps below."
    elif printf '%s\n' "$ghcr_pat" | docker login ghcr.io -u "$ghcr_user" --password-stdin; then
      GHCR_DONE="yes"
      ok "Logged in to ghcr.io as '$ghcr_user'"
    else
      note "Login failed. A classic PAT with scope read:packages is what this needs —"
      note "a fine-grained token fails here. Retry with the command in the steps below."
    fi
    unset ghcr_pat
  else
    note "Skipped — it's in the steps below, to do whenever you're ready."
  fi
fi

# The printed steps reflect what is actually still outstanding, so a completed
# login does not sit there looking like a pending task.
if [[ "$GHCR_DONE" == "yes" ]]; then
  GHCR_STEP="  5. GHCR login — already done for '$RUN_AS'. Nothing to do here."
else
  GHCR_STEP="  5. Both GHCR images are private — log in once, as '$RUN_AS', or every deploy
     fails with \"unauthorized\":
       echo \"<PAT>\" | docker login ghcr.io -u <github-username> --password-stdin
     PAT from github.com/settings/tokens — classic, scope read:packages."
fi

# A function, not an inline heredoc, so the exact same text can be written
# both to the terminal and to a file — see below. If your session drops
# before you're done with these, the file is how you get them back without
# re-running the whole script.
print_remaining_steps() {
  cat <<EOF

$(echo -e "${GREEN}Application setup complete.${NC}")

Remaining steps:

  1. Fill in the environment:
       nano $APP_DIR/.env
     At minimum: APP_HOST, MONGODB_URI, JWT_SECRET, OPENAI_API_KEY.

  2. In BOTH app repos' GitHub settings, set the deploy secrets. VPS_USER is
     the account this script just ran as — CI has to be that same account, or
     it cannot write to $APP_DIR:
       VPS_USER                 $RUN_AS
       VPS_HOST                 this server's IP or hostname
       VPS_SSH_KEY              private half of a key dedicated to CI
       VPS_SSH_KEY_PASSPHRASE   its passphrase
     Generate the key with e.g. \`ssh-keygen -t ed25519 -C psc-archiver-ci\`,
     and have its PUBLIC half installed on '$RUN_AS' by whoever manages server
     access — this script never writes authorized_keys.

  3. Point the APP_HOST DNS A record at this server and let it propagate.
     Let's Encrypt cannot issue a certificate until it resolves here.

  4. Start the edge proxy. This also CREATES the shared traefik_proxy network,
     which compose.prod.yml joins as external — so it must come before step 6:
       cd $APP_DIR
       ACME_EMAIL=you@example.com docker compose -f compose.traefik.yml -p traefik up -d

$GHCR_STEP

  6. FIRST deploy only: deploy.sh's health check execs into the 'web'
     container and curls /api/readyz through its nginx proxy — so it needs
     BOTH containers already running, which isn't true yet. Bring them up
     together once instead (after setting real API_TAG/WEB_TAG in .env):
       docker compose -f compose.prod.yml -p psc-archiver up -d
     Every deploy after this one — from CI or by hand — can safely use:
       ./scripts/deploy.sh api <tag>
       ./scripts/deploy.sh web <tag>

  7. Create the first admin account (only once, on an empty database):
       docker compose -f compose.prod.yml -p psc-archiver run --rm \\
         api node dist/scripts/seed-superadmin.js

Lost this output? It's saved at $APP_DIR/REMAINING-STEPS.txt — cat it
anytime, or just re-run this script; it's idempotent and safe to repeat.

EOF
}

print_remaining_steps | tee "$APP_DIR/REMAINING-STEPS.txt"
