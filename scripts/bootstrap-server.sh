#!/usr/bin/env bash
#
# One-time setup for a fresh Ubuntu/Debian VPS. Run as root (or with sudo) on
# the new server:
#
#   curl -fsSL https://raw.githubusercontent.com/<owner>/psc-archiver-deploy/master/scripts/bootstrap-server.sh | bash
#
# or clone the repo first and run it locally. Safe to re-run.
#
# Afterwards you still have to, by hand:
#   1. fill in /opt/psc-archiver/.env          (copied from .env.example)
#   2. add the CI public key to ~deploy/.ssh/authorized_keys
#   3. point APP_HOST's DNS A record at this server
#   4. bring up Traefik (printed at the end)
#   5. optionally lock down the firewall — scripts/configure-firewall.sh,
#      run separately and deliberately (see that script's own header)
#
# This script does NOT install Docker and does NOT touch the firewall — both
# are the operator's call, not something to do unattended from a curled
# script. See the "Remaining steps" it prints at the end (also saved to
# /opt/psc-archiver/REMAINING-STEPS.txt).

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
note() { echo -e "${YELLOW}$*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="/opt/psc-archiver"
REPO_URL="${REPO_URL:-https://github.com/mroshan74/psc-archiver-deploy.git}"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }

# ── Docker ─────────────────────────────────────────────────────────────────
# This script provisions the app, not the platform: installing a container
# runtime is the operator's call (version, storage driver, etc are theirs to
# pick), so a missing Docker is a hard stop rather than something we install
# for you.
step "Checking for Docker"
if ! command -v docker >/dev/null 2>&1; then
  fail "Docker is not installed. Install Docker Engine (with the Compose plugin) first, then re-run this script: https://docs.docker.com/engine/install/"
fi
if ! docker compose version >/dev/null 2>&1; then
  fail "Docker is installed but the Compose plugin ('docker compose') is missing. Install it, then re-run this script: https://docs.docker.com/compose/install/"
fi
ok "Docker already installed ($(docker --version))"

# ── Deploy user ────────────────────────────────────────────────────────────
if ! id -u "$DEPLOY_USER" >/dev/null 2>&1; then
  step "Creating the '$DEPLOY_USER' user"
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
fi
usermod -aG docker "$DEPLOY_USER"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
touch "/home/$DEPLOY_USER/.ssh/authorized_keys"
chown "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh/authorized_keys"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys"
ok "User '$DEPLOY_USER' ready (member of the docker group)"

# ── Firewall ───────────────────────────────────────────────────────────────
# Deliberately NOT done here. Resetting ufw from inside an unattended,
# curl-piped script can end the very SSH session running it — e.g. if this
# server's real SSH port isn't 22, or something else inbound needs to stay
# open. Locking it down is scripts/configure-firewall.sh, run by hand,
# separately, after you've read its warnings. Pointed to again in the
# "Remaining steps" below.

# ── Deploy checkout ────────────────────────────────────────────────────────
# /opt, not a personal home directory — the server layout should not depend on
# who set it up.
if [[ ! -d "$DEPLOY_DIR/.git" ]]; then
  step "Cloning $REPO_URL to $DEPLOY_DIR"
  git clone --quiet "$REPO_URL" "$DEPLOY_DIR"
else
  step "Updating $DEPLOY_DIR"
  git -C "$DEPLOY_DIR" pull --ff-only --quiet
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR"
chmod +x "$DEPLOY_DIR"/scripts/*.sh

if [[ ! -f "$DEPLOY_DIR/.env" ]]; then
  cp "$DEPLOY_DIR/.env.example" "$DEPLOY_DIR/.env"
  chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR/.env"
  chmod 600 "$DEPLOY_DIR/.env"
  ok "Created $DEPLOY_DIR/.env from the template"
else
  ok "$DEPLOY_DIR/.env already exists — left untouched"
fi

# ── Docker network ─────────────────────────────────────────────────────────
if ! docker network inspect traefik_proxy >/dev/null 2>&1; then
  step "Creating the traefik_proxy network"
  docker network create traefik_proxy >/dev/null
fi
ok "Network traefik_proxy ready"

# A function, not an inline heredoc, so the exact same text can be written
# both to the terminal and to a file — see below. If your session drops
# before you're done with these, the file is how you get them back without
# re-running the whole script.
print_remaining_steps() {
  cat <<EOF

$(echo -e "${GREEN}Server bootstrap complete.${NC}")

Remaining steps:

  1. Fill in the environment:
       sudo -u $DEPLOY_USER nano $DEPLOY_DIR/.env
     At minimum: APP_HOST, MONGODB_URI, JWT_SECRET, OPENAI_API_KEY.

  2. Authorise CI to deploy — paste the public half of the key stored in the
     VPS_SSH_KEY GitHub secret:
       sudo -u $DEPLOY_USER nano /home/$DEPLOY_USER/.ssh/authorized_keys

  3. Point the APP_HOST DNS A record at this server and let it propagate.
     Let's Encrypt cannot issue a certificate until it resolves here.

  4. Start the edge proxy:
       cd $DEPLOY_DIR
       ACME_EMAIL=you@example.com docker compose -f compose.traefik.yml -p traefik up -d

  5. Push to master in either app repo, or deploy an existing tag by hand:
       ./scripts/deploy.sh api <tag>
       ./scripts/deploy.sh web <tag>

  6. Create the first admin account (only once, on an empty database):
       docker compose -f compose.prod.yml -p psc-archiver run --rm \\
         api node dist/scripts/seed-superadmin.js

  7. (Optional, recommended) Lock down the firewall to SSH/HTTP/HTTPS only.
     Read the script's header first — it can end your SSH session if this
     server's SSH port isn't detected correctly:
       sudo $DEPLOY_DIR/scripts/configure-firewall.sh

Lost this output? It's saved at $DEPLOY_DIR/REMAINING-STEPS.txt — cat it
anytime, or just re-run this script; it's idempotent and safe to repeat.

EOF
}

print_remaining_steps | tee "$DEPLOY_DIR/REMAINING-STEPS.txt"
chown "$DEPLOY_USER:$DEPLOY_USER" "$DEPLOY_DIR/REMAINING-STEPS.txt"
