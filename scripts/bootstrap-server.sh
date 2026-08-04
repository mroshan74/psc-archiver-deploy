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

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; NC='\033[0m'
step() { echo -e "${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
note() { echo -e "${YELLOW}$*${NC}"; }

DEPLOY_USER="${DEPLOY_USER:-deploy}"
DEPLOY_DIR="/opt/psc-archiver"
REPO_URL="${REPO_URL:-https://github.com/mroshan74/psc-archiver-deploy.git}"

[[ "$(id -u)" -eq 0 ]] || { echo "Run as root or with sudo." >&2; exit 1; }

# ── Docker ─────────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
  step "Installing Docker Engine"
  curl -fsSL https://get.docker.com | sh
else
  ok "Docker already installed ($(docker --version))"
fi

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
# Only SSH and HTTP(S). Container ports stay on the internal Docker network —
# the predecessor projects published app ports publicly, which served plain
# HTTP straight past Traefik's TLS.
step "Configuring the firewall"
if ! command -v ufw >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq ufw
fi
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp   comment 'SSH'   >/dev/null
ufw allow 80/tcp   comment 'HTTP'  >/dev/null
ufw allow 443/tcp  comment 'HTTPS' >/dev/null
ufw --force enable >/dev/null
ok "Firewall allows 22, 80, 443 only"

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

EOF
