#!/usr/bin/env bash
#
# One-time setup for a fresh Ubuntu/Debian VPS. Run as root (or with sudo) on
# the new server.
#
# This repo is PRIVATE, so the classic "curl the raw file, pipe to bash"
# one-liner does not work unauthenticated — raw.githubusercontent.com 404s on
# private repos with no token. Instead, this script clones itself with a
# read-only GitHub deploy key, so give the server that key first:
#
#   1. Generate a dedicated, passphrase-less keypair (it has to unlock itself
#      non-interactively — deploy.sh runs `git pull` on every future deploy):
#        ssh-keygen -t ed25519 -N "" -C psc-archiver-deploy \
#          -f psc-archiver-deploy-key
#
#   2. Add the PUBLIC half as a read-only Deploy key on this repo:
#        GitHub → this repo → Settings → Deploy keys → Add deploy key
#        (leave "Allow write access" unchecked)
#
#   3. Copy the PRIVATE half to the new server:
#        scp psc-archiver-deploy-key root@<new-vps>:/root/.ssh/psc-archiver-deploy-key
#
#   4. On the server, use that key for a one-time throwaway clone just to run
#      this script (the script then does its own, permanent clone as the
#      'deploy' user — this first one is scratch space you can delete after):
#        chmod 600 /root/.ssh/psc-archiver-deploy-key
#        GIT_SSH_COMMAND='ssh -i /root/.ssh/psc-archiver-deploy-key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new' \
#          git clone git@github.com:mroshan74/psc-archiver-deploy.git /root/psc-archiver-deploy-bootstrap
#        bash /root/psc-archiver-deploy-bootstrap/scripts/bootstrap-server.sh
#        rm -rf /root/psc-archiver-deploy-bootstrap   # scratch clone, safe to remove once this finishes
#
# The script itself installs that same key for the 'deploy' user and points
# git at it, so its own clone into /opt/psc-archiver, and every later
# `git pull` deploy.sh does over SSH as 'deploy', keep working non-interactively.
#
# (If this repo is ever made public, none of the above is needed — the
# original curl-pipe-bash one-liner and an anonymous REPO_URL work as-is.)
#
# Safe to re-run.
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
REPO_URL_DEFAULT="git@github.com:mroshan74/psc-archiver-deploy.git"
REPO_URL="${REPO_URL:-$REPO_URL_DEFAULT}"
# Only consulted when REPO_URL is the default SSH form (see header comment).
DEPLOY_KEY_SRC="${DEPLOY_KEY_SRC:-/root/.ssh/psc-archiver-deploy-key}"
DEPLOY_KEY_DEST="/home/${DEPLOY_USER}/.ssh/psc-archiver-deploy-key"

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

# ── Deploy key (private repo access) ────────────────────────────────────────
# Only needed when REPO_URL is the default SSH form — see this script's
# header for how to generate and stage the key. If REPO_URL has been
# overridden (e.g. this repo is public, or a different auth method is
# already wired up for $DEPLOY_USER), skip this entirely.
if [[ "$REPO_URL" == "$REPO_URL_DEFAULT" ]]; then
  step "Installing the GitHub deploy key for '$DEPLOY_USER'"
  [[ -f "$DEPLOY_KEY_SRC" ]] || fail "No deploy key at $DEPLOY_KEY_SRC. See this script's header for how to generate one, add it as a read-only Deploy key on the repo, and copy it here (or point DEPLOY_KEY_SRC at wherever you staged it)."

  install -m 600 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_KEY_SRC" "$DEPLOY_KEY_DEST"

  ssh_config="/home/${DEPLOY_USER}/.ssh/config"
  if [[ ! -f "$ssh_config" ]] || ! grep -q "IdentityFile $DEPLOY_KEY_DEST" "$ssh_config" 2>/dev/null; then
    cat >> "$ssh_config" <<EOF
Host github.com
  IdentityFile $DEPLOY_KEY_DEST
  IdentitiesOnly yes
EOF
    chown "$DEPLOY_USER:$DEPLOY_USER" "$ssh_config"
    chmod 600 "$ssh_config"
  fi

  # Accept GitHub's host key up front (trust-on-first-use) so the first
  # `git clone`/`pull` below doesn't hang on an interactive host-key prompt.
  known_hosts="/home/${DEPLOY_USER}/.ssh/known_hosts"
  touch "$known_hosts"
  if ! ssh-keygen -F github.com -f "$known_hosts" >/dev/null 2>&1; then
    ssh-keyscan -H github.com >> "$known_hosts" 2>/dev/null
  fi
  chown "$DEPLOY_USER:$DEPLOY_USER" "$known_hosts"
  chmod 600 "$known_hosts"

  ok "Deploy key installed for '$DEPLOY_USER'"
else
  note "REPO_URL overridden — skipping deploy-key setup."
fi

# ── Firewall ───────────────────────────────────────────────────────────────
# Deliberately NOT done here. Resetting ufw from inside an unattended,
# curl-piped script can end the very SSH session running it — e.g. if this
# server's real SSH port isn't 22, or something else inbound needs to stay
# open. Locking it down is scripts/configure-firewall.sh, run by hand,
# separately, after you've read its warnings. Pointed to again in the
# "Remaining steps" below.

# ── Deploy checkout ────────────────────────────────────────────────────────
# /opt, not a personal home directory — the server layout should not depend on
# who set it up. Cloned as $DEPLOY_USER (not root) so it picks up the SSH
# config/key set up above — the same identity deploy.sh's later `git pull`
# runs as, over SSH from CI.
if [[ ! -d "$DEPLOY_DIR/.git" ]]; then
  step "Cloning $REPO_URL to $DEPLOY_DIR"
  install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$DEPLOY_DIR"
  sudo -H -u "$DEPLOY_USER" git clone --quiet "$REPO_URL" "$DEPLOY_DIR"
else
  step "Updating $DEPLOY_DIR"
  sudo -H -u "$DEPLOY_USER" git -C "$DEPLOY_DIR" pull --ff-only --quiet
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
