#!/usr/bin/env bash
#
# Lock the server down to SSH + HTTP(S) only, via ufw.
#
#   sudo /opt/psc-archiver/scripts/configure-firewall.sh
#
# or, on a box that hasn't been bootstrapped yet:
#
#   curl -fsSL https://raw.githubusercontent.com/mroshan74/psc-archiver-deploy/master/scripts/configure-firewall.sh | bash
#
# ── READ THIS FIRST ──────────────────────────────────────────────────────────
# This is deliberately NOT part of bootstrap-server.sh. Resetting the firewall
# can end the very SSH session you're running it from — if this server's real
# SSH port isn't the one this script detects, or something else inbound needs
# to stay open, you can lock yourself out with no way back short of your
# hosting provider's console. Run it only when you're sure, ideally with a
# second, independent way to reach the box (provider console, second SSH
# session on a different key) available while you confirm access afterwards.
#
# What it does: resets ufw, denies all inbound by default, and allows outbound
# plus SSH (auto-detected from sshd_config, port 22 is always kept open
# regardless) / HTTP / HTTPS. Container ports stay off the public interface —
# they're only reachable over the internal Docker network, which is the whole
# point: the predecessor projects published app ports publicly, serving plain
# HTTP straight past Traefik's TLS.
#
# Safe to re-run; it always asks for confirmation first.

set -euo pipefail

BLUE='\033[0;34m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; NC='\033[0m'
step() { echo -e "${BLUE}==> $*${NC}"; }
ok()   { echo -e "${GREEN}✓ $*${NC}"; }
warn() { echo -e "${YELLOW}! $*${NC}"; }
fail() { echo -e "${RED}✗ $*${NC}" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || fail "Run as root or with sudo."

# ── ufw ──────────────────────────────────────────────────────────────────────
if ! command -v ufw >/dev/null 2>&1; then
  step "Installing ufw"
  apt-get update -qq && apt-get install -y -qq ufw
fi

# ── Detect the real SSH port(s) ──────────────────────────────────────────────
# Never trust a single guess here: collect every `Port` directive from
# sshd_config (and any drop-in files), and ALWAYS allow 22 in addition,
# whatever is found. Under-detecting can only leave 22 open when it isn't
# actually in use; it can never take away a port you're really listening on.
ssh_config_files=(/etc/ssh/sshd_config)
if [[ -d /etc/ssh/sshd_config.d ]]; then
  while IFS= read -r -d '' f; do ssh_config_files+=("$f"); done \
    < <(find /etc/ssh/sshd_config.d -name '*.conf' -print0 2>/dev/null)
fi

ssh_ports="$(sed -n 's/^[[:space:]]*Port[[:space:]]\+\([0-9]\+\).*/\1/p' "${ssh_config_files[@]}" 2>/dev/null | sort -un)"
ssh_ports="$(printf '22\n%s\n' "$ssh_ports" | sort -un)"

step "Detected SSH port(s): $(echo "$ssh_ports" | tr '\n' ' ')"

# ── Confirm before touching anything ────────────────────────────────────────
# Read from the controlling terminal, not stdin — this script is meant to
# also work piped from curl, where stdin is the script itself, not a place a
# human can type into.
if [[ ! -e /dev/tty ]]; then
  fail "No controlling terminal to confirm from (are you running this from another script?). Run it interactively instead."
fi

echo
warn "About to reset ufw and allow ONLY:"
for p in $ssh_ports; do echo "    - ${p}/tcp (SSH)"; done
echo "    - 80/tcp  (HTTP)"
echo "    - 443/tcp (HTTPS)"
echo
warn "Everything else inbound will be denied. If that's wrong for this box, Ctrl-C now."
echo
read -r -p "Type 'yes' to apply this firewall configuration: " reply < /dev/tty
[[ "$reply" == "yes" ]] || fail "Not confirmed — nothing changed."

# ── Apply ────────────────────────────────────────────────────────────────────
step "Applying firewall rules"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
for p in $ssh_ports; do
  ufw allow "${p}/tcp" comment 'SSH' >/dev/null
done
ufw allow 80/tcp  comment 'HTTP'  >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw --force enable >/dev/null

ok "Firewall allows $(echo "$ssh_ports" | tr '\n' ' ')(SSH), 80, 443 only"
echo
warn "Open a NEW terminal now and confirm you can still SSH in before closing this one."
