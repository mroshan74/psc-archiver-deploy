# psc-archiver-deploy

Deployment configuration for **PSC Archiver** — the NestJS API (`psc-archiver-api`)
and the React admin SPA (`psc-archiver-admin`).

Infrastructure lives in its own repo on purpose. In the two predecessor
projects it was buried inside an application repo, and in both cases the copy
on the server silently drifted from the copy in git. Here, `deploy.sh` pulls
this repo on every deploy, so the server can only run what is committed.

---

## Before your first deploy

Fill these in — the checked-in files use placeholders.

| Placeholder | Where | What to put |
|---|---|---|
| `APP_HOST` | `/opt/psc-archiver/.env` | The public hostname, e.g. `archiver.trynbuild.com` |
| `ACME_EMAIL` | passed to `compose.traefik.yml` | Where Let's Encrypt sends expiry warnings |
| `REPO_URL` | `scripts/setup-app.sh` | This repo's clone URL, if not `mroshan74/psc-archiver-deploy` |
| `API_IMAGE` / `WEB_IMAGE` | `.env` | GHCR paths, if the owner is not `mroshan74` |
| `MONGODB_URI`, `JWT_SECRET`, `OPENAI_API_KEY` | `.env` | Real credentials |

---

## Architecture

```
                       ┌──────────── VPS ─────────────────────────────┐
  browser ── HTTPS ──▶ │  traefik  (:80 → :443, Let's Encrypt)        │
                       │     │                                        │
                       │     ▼  Host(APP_HOST)                        │
                       │  web  nginx ── SPA                           │
                       │        └────── /api/* ──proxy──▶ api :5000   │
                       └──────────────────────────────────────────────┘
                                                            │
                                                            ▼
                                                   MongoDB Atlas
```

**One hostname, one origin.** The SPA is built with an empty `VITE_BACKEND_URL`,
so it calls the relative path `/api`, and nginx forwards that to the API
container. Consequences worth knowing:

- No CORS in production, and only one TLS certificate.
- The API is **never routed by Traefik** (`traefik.enable=false`) and publishes
  no host port. It is only reachable from inside the Docker network.
- The same web image works locally and in production — there is no baked-in
  backend hostname, so no per-environment rebuild.

## Repository layout

| File | Purpose |
|---|---|
| `compose.prod.yml` | The production stack (`api` + `web`) |
| `compose.traefik.yml` | Edge proxy and TLS. Brought up once, then left alone |
| `compose.local.yml` | Prod-parity local stack, with its own MongoDB |
| `.env.example` | The key schema `deploy.sh` validates the server's `.env` against |
| `scripts/setup-app.sh` | One-time application setup on an already-provisioned server. Checks its prerequisites; provisions nothing |
| `scripts/deploy.sh` | What CI runs over SSH |
| `scripts/rollback.sh` | Redeploy an older tag |
| `scripts/seed-local.mjs` | First-run bootstrap for the local stack. Runs *inside* the `api` container (via the `seed` compose profile) — the host never needs Node.js, only Docker |

---

## Run it locally

The local stack runs the **same images, same nginx, same routing** as
production. It is the fastest way to see the app, demo it, or check a change
before pushing — and it is where the deployment setup itself gets tested.

```bash
git clone <this repo>            # next to psc-archiver-api and psc-archiver-admin
cd psc-archiver-deploy

docker compose -f compose.local.yml up -d --build          # builds your working tree
docker compose -f compose.local.yml --profile seed run --rm seed   # first run only
```

Open **http://localhost:8080** and sign in as `superadmin` / `ChangeMe123!`
(you will be asked to set a new password). Override with
`SEED_SUPERADMIN_USERNAME` / `SEED_SUPERADMIN_PASSWORD`.

The seed step is idempotent — re-running it creates nothing twice. It runs
`scripts/seed-local.mjs` *inside* the `api` image's own Node (via the `seed`
profile above) — the host you run these commands on never needs Node.js
installed, only Docker.

To run an exact published build instead of your working tree:

```bash
export API_IMAGE=ghcr.io/mroshan74/psc-archiver-api
export WEB_IMAGE=ghcr.io/mroshan74/psc-archiver-web
export API_TAG=a1b2c3d WEB_TAG=a1b2c3d
docker compose -f compose.local.yml pull
docker compose -f compose.local.yml up -d --no-build
```

Other useful bits:

```bash
docker compose -f compose.local.yml logs -f api      # follow API logs
docker compose -f compose.local.yml down             # stop, keep data
docker compose -f compose.local.yml down -v          # stop and wipe the database
```

MongoDB is published on **27018** (not 27017) so it never collides with a
MongoDB you already run. It is a throwaway container: this stack never touches
Atlas, so a demo cannot damage real data.

---

## Prerequisites — provisioned by whoever owns the server

Server provisioning belongs to the platform team, not to an application
deploy. **Nothing in this repo installs packages, creates users or groups,
writes SSH keys, edits `sshd_config`, or configures the firewall.** The setup
script checks for what it needs and stops with a specific ask when something
is missing.

The following must already be true before the application can be set up:

| Requirement | Notes |
|---|---|
| Docker Engine + the Compose plugin | `setup-app.sh` verifies, never installs |
| An account to SSH in as, able to reach the Docker socket (typically via the `docker` group), that the developer doing setup can log in to | never created here. A dedicated service account is preferred; `root` works |
| The CI public key installed on that account's `authorized_keys` | needed before the first CI *deploy*, not before setup. Never written here — you generate the keypair (below) and hand over the public half |
| `/opt/psc-archiver`, owned by that account | the one thing `setup-app.sh` offers to do itself — it prints the `sudo install -d` and waits for a `y` before running it. Answer `n` and it stops, unchanged |
| Inbound 80 and 443 reachable, and SSH reachable from GitHub Actions | never changed here |

---

## Set up the application

A one-time manual step, run by a developer after the server is handed over and
**before the first CI deploy**. CI never runs it — CI only runs `deploy.sh`,
which is on the server because this put it there.

```bash
ssh <account>@<vps>
curl -fsSL https://raw.githubusercontent.com/mroshan74/psc-archiver-deploy/master/scripts/setup-app.sh | bash
```

**Whichever account you SSH in as is the account CI must use.** The script
checks *that* account — not a hardcoded one — for Docker access and write
access to `/opt/psc-archiver`, and prints it at the end as the value for the
`VPS_USER` secret. Setting up as one account while CI connects as another is
the classic failure: `deploy.sh`'s `git pull` and its `sed -i` on `.env` both
need to write there, and fail with "permission denied" otherwise.

It then clones this repo to `/opt/psc-archiver` and creates `.env` from the
template. It prints the remaining manual steps when it finishes, and also
saves them to `/opt/psc-archiver/REMAINING-STEPS.txt` in case your session
drops before you're done — `cat` that file anytime, or just re-run the script;
it's idempotent and safe to repeat.

**It stops and asks twice**, and in both cases prints the exact command before
running anything:

| Prompt | If you answer `y` | If you answer `n` |
|---|---|---|
| Create (or hand over) `/opt/psc-archiver` — the one privileged command | runs that single `sudo` and continues | stops immediately, server unchanged, and prints the command to pass to whoever administers it |
| Log in to ghcr.io | asks for your GitHub username and PAT (input hidden, piped straight to `--password-stdin` — never echoed, never a shell argument, never written anywhere but Docker's own config) | carries on; it stays in the printed steps for later |

It skips the second prompt entirely if credentials for `ghcr.io` are already
stored, and the printed steps reflect what is actually still outstanding — a
login you completed does not sit there looking pending. Prompts read from
`/dev/tty`, so they work under `curl … | bash`; with no terminal at all
(a non-interactive run) both answer "no".

**A key dedicated to CI.** Generate one (don't reuse a personal key):

```bash
ssh-keygen -t ed25519 -C psc-archiver-ci -f ci-deploy-key
```

Hand `ci-deploy-key.pub` to whoever manages access on that server, to be
installed on the account above. Then, in the GitHub settings of **both** app
repos, add these secrets:

| Secret | Value |
|---|---|
| `VPS_HOST` | Server IP or hostname |
| `VPS_USER` | The account `setup-app.sh` ran as — it prints the exact value |
| `VPS_SSH_KEY` | Contents of `ci-deploy-key` (the private half) |
| `VPS_SSH_KEY_PASSPHRASE` | The passphrase you set above |

That covers the **push**: CI authenticates to GHCR with the built-in
`GITHUB_TOKEN`, no secret to add. It does not cover the **pull** — both GHCR
packages are private (they inherit that from the source repos), and the VPS
has no access to `GITHUB_TOKEN`, so it needs its own one-time login before
the first deploy. `setup-app.sh` offers to do this for you; to do it by hand
instead, or later:

```bash
ssh <VPS_USER>@<vps>
# Generate at github.com/settings/tokens — classic PAT, scope: read:packages
echo "<PAT>" | docker login ghcr.io -u <your-github-username> --password-stdin
```

One-time only: Docker persists this to that account's `~/.docker/config.json`,
so every later `docker compose pull` — CI-triggered or by hand —
authenticates automatically from here on. Skip this entirely by
making the two GHCR packages public instead (repo → Packages → package →
Package settings → visibility) if you'd rather not manage this credential.

**Bring Traefik up before the app stack.** The `compose.traefik.yml` stack
owns the shared `traefik_proxy` network; `compose.prod.yml` joins it as
`external`, so starting the app stack first on a fresh server fails with
`network traefik_proxy declared as external, but could not be found`.

---

## Deploy

**Normally you do nothing.** Push to `master` in either app repo and CI builds,
publishes to GHCR, and runs `deploy.sh` over SSH.

By hand, on the server:

```bash
cd /opt/psc-archiver
./scripts/deploy.sh api a1b2c3d
./scripts/deploy.sh web a1b2c3d
```

**Exception: the very first deploy on a brand-new server.** Step 5 below
polls `/api/readyz` *through the `web` container's nginx proxy* — which
needs **both** containers already running. On a server where neither has
ever been started, deploying one alone with `deploy.sh` will always time out
waiting for the other one, regardless of which you pick first. (The `web`
container itself now *starts* fine without the api — it just returns 502
until the api appears — but the deploy probe still needs both.) Bring both up
together, once, instead (after `API_TAG`/`WEB_TAG` in `.env` point at real
published tags):

```bash
docker compose -f compose.prod.yml -p psc-archiver up -d
```

Every deploy after that — from CI or by hand — can go through `deploy.sh`
normally, since from then on the other container is always already up.

`deploy.sh` will:

1. `git pull` this repo, so the config is the committed one
2. check the server's `.env` has every key present in `.env.example`, and
   **abort before touching anything** if not
3. write the tag into `.env` (and `BUILD_ID`, for the api)
4. pull the image, then recreate only that one service
5. poll `/api/readyz` **from inside the web container** — the real browser path
6. prune images older than 7 days, keeping a week of rollback targets

Step 5 normally costs 3–10 seconds: the loop probes once *before* its first
sleep, so a container that is already serving passes immediately. The 60s in
the script is the failure deadline, not the usual cost. It is not redundant
with the container healthchecks below — plain Compose only *reports* health, it
never restarts an unhealthy-but-running container, and `restart: unless-stopped`
fires on process exit rather than on unhealthy.

**Only one deploy runs at a time.** `deploy.sh` takes an exclusive `flock` on
`.deploy.lock` in this directory and waits up to 5 minutes for a running deploy
to finish. The lock is shared across accounts (the file is created `0666`), so a
hand-run rollback as `root` and a CI deploy as `VPS_USER` still exclude each
other. This is not covered by GitHub's `concurrency:` group, which is per-repo
and so cannot serialise an api deploy against a web deploy.

Expect a few seconds of downtime while the container restarts. That is
accepted: this pipeline optimises for fast, verified iteration rather than
availability. Real zero-downtime needs two API replicas, which needs a
distributed lock first (see *Known constraints*).

### Container health

Both services carry a Docker healthcheck, so `docker compose -f compose.prod.yml
-p psc-archiver ps` reports real status rather than just "Up":

| Service | Probe | Means |
|---------|-------|-------|
| `api` | `GET /api/readyz` on `127.0.0.1:5000` | process is up **and** MongoDB is connected |
| `web` | `GET /healthz` on `127.0.0.1:80` | nginx is serving (deliberately does not depend on the api) |

The api gets a 30s `start_period` for Nest boot plus the first Mongo
connection; failures inside that window don't count against it.

## Roll back

Every build is published under its own immutable short-SHA tag, and
`compose.prod.yml` resolves whatever tag `.env` names. So rollback is just a
deploy of an older tag:

```bash
cd /opt/psc-archiver
./scripts/rollback.sh api               # list tags available on this host
./scripts/rollback.sh api 9f8e7d6       # go back to that build
```

Or from the GitHub UI, without SSH: **Actions → Build, Push & Deploy → Run
workflow**, and put the old tag in the `tag` input. That path skips the build
entirely and only redeploys.

`deploy.sh` prints the tag it replaced at the end of every run, so the value to
roll back to is always in the previous deploy's log.

## Rotate a secret

```bash
ssh <VPS_USER>@<vps>
cd /opt/psc-archiver
nano .env                                  # edit the value
./scripts/deploy.sh api "$(sed -n 's/^API_TAG=//p' .env)"   # redeploy the same tag
```

Rotating `JWT_SECRET` signs everyone out, which is the intended effect.

## Bootstrap a fresh database

The app has never been in production, so there is no migration path — a fresh
database is seeded from scratch.

```bash
cd /opt/psc-archiver
docker compose -f compose.prod.yml -p psc-archiver run --rm \
  api node dist/scripts/seed-superadmin.js
```

Idempotent: it does nothing if a superadmin already exists. Content (exam
papers and questions) is then imported by signing in and calling
`POST /api/seeder/import` — `scripts/seed-local.mjs` shows the exact sequence.

---

## Troubleshooting

**`Error error from registry: unauthorized` while pulling the image.** The
VPS hasn't logged in to GHCR yet — see the `docker login` step under *Set up
the application*. Confirm it's this and not a tag that never got pushed:
`docker pull <image>:<tag>` on the server as `VPS_USER` reproduces the same
error; a 401 `unauthorized` (rather than 404 `not found`) points at auth.
After `docker login ghcr.io`, retry the pull, then re-run the deploy.

**`docker login` succeeds but pulling still fails with `denied`.** Different
error from the one above — `unauthorized` (401) means bad/missing
credentials; `denied` (403) means the credentials are valid but lack
permission. `docker login` only checks that the PAT is real, not that it has
the right scope, so this combination is the classic sign of a PAT missing
the `read:packages` scope. Check what scopes a token actually has without
regenerating it: `curl -sSI -H "Authorization: token <PAT>" https://api.github.com/user | grep -i x-oauth-scopes`.
Fix: generate a **classic** PAT (not fine-grained) at
github.com/settings/tokens with `read:packages` checked, and log in again.

**Deploy failed at "Checking environment".** The output lists the missing keys.
Add them to `/opt/psc-archiver/.env`. Nothing was changed — the running stack is
untouched.

**Deploy failed at "Waiting for the app to respond".** The new image is running
but not serving. The last 40 log lines are printed above the failure. Roll back
with the command the script prints, then investigate. **If this is the very
first deploy on this server**, this is expected rather than a real failure —
see the callout under *Deploy* above: bring both containers up together once
with plain `docker compose up -d` before using `deploy.sh` for the first time.

**Deploy failed at "Another deploy has held the lock for over 5 minutes."**
Another `deploy.sh` is still running, or one was killed in a way that left its
shell alive. Check with `ps aux | grep deploy.sh`. There is no stale lock to
clean up by hand — the kernel releases a `flock` when the holding process dies,
including on `kill -9` — so if nothing is running, simply retry.

**A container sits at `(unhealthy)`.** Read the last probe's actual output:

```bash
docker inspect --format '{{json .State.Health}}' psc-archiver-api | jq
```

For `api` this almost always means `/api/readyz` is returning 503 because
MongoDB is unreachable — the process is fine, the database is not. Note that
nothing restarts an unhealthy container automatically; it is a signal, not a
remediation.

**The API container restarts in a loop.** Almost always a missing or malformed
env var — the app deliberately refuses to boot without `MONGODB_URI` and
`JWT_SECRET`. Check `docker compose -f compose.prod.yml -p psc-archiver logs api`.

**502 on `/api` while the api container is healthy.** The `web` container's
nginx resolves the api by name through Docker's embedded DNS
(`resolver 127.0.0.11` in `psc-archiver-admin/nginx.conf`) and re-resolves it
every 10s, so a recreated api container with a new IP is picked up on its own.
A 502 in the ~10s right after a deploy is that DNS cache expiring and is
expected — the deploy probe retries through it. A *persistent* 502 means the
running web image predates that change; redeploy `web` to pick it up.

**Probing by hand from inside the web container.** Use `127.0.0.1`, not
`localhost`: Docker's `/etc/hosts` maps `localhost` to both `127.0.0.1` and
`::1`, BusyBox wget tries `::1` first, and nginx's `listen 80` binds IPv4 only,
so the `localhost` form is refused every time regardless of app state.

```bash
docker compose -f compose.prod.yml -p psc-archiver exec -T web \
  wget -q -O- http://127.0.0.1/api/readyz
```

**`network traefik_proxy declared as external, but could not be found`.** The
Traefik stack hasn't been started on this server yet — it is what creates that
network. Bring it up first
(`ACME_EMAIL=… docker compose -f compose.traefik.yml -p traefik up -d`), then
retry the app stack.

**`Local changes present in /opt/psc-archiver — skipping git pull` on every
deploy, with `git status` showing nothing you edited.** Run `git diff` on the
server: if the only hunks are `old mode 100644` / `new mode 100755` on
`scripts/*.sh`, that is a file-mode diff, not a content one. It appears when the
scripts are committed without the executable bit (a Windows clone has
`core.fileMode=false`, so git never records it) and `setup-app.sh` then
`chmod +x`es them on the server, where `core.fileMode` is `true`. The checkout
is then permanently dirty and `deploy.sh` skips its config pull for good — so
the server keeps running old compose files while reporting a clean deploy. Fixed
in the repo by recording the bit (`git update-index --chmod=+x scripts/*.sh`);
to clear a server that is already in this state, drop the mode-only diff and
pull once by hand:

```bash
cd /opt/psc-archiver
git diff --stat          # confirm it is mode-only before discarding anything
git checkout -- scripts/
git pull --ff-only
git status               # clean, and ls -l scripts/ shows 755
```

Do **not** "fix" this with `git config core.fileMode false` on the server — that
hides the symptom while leaving the scripts non-executable for anyone who clones
the repo fresh.

**`permission denied` on `git pull` or `.env` during a deploy.** `VPS_USER`
is not the account `/opt/psc-archiver` belongs to. Compare `ls -ld
/opt/psc-archiver` with the `VPS_USER` secret; re-running `setup-app.sh` as
the intended account prints the value it should be.

**Certificate is not issued.** Traefik needs the `APP_HOST` DNS record to
resolve to this server *before* it can complete the ACME challenge. Confirm with
`dig +short <APP_HOST>`, then `docker logs traefik`.

**Which build is live?** The version string is rendered in the app's sidebar
footer. `GET /api/readyz` also returns the API's `buildId`.

---

## Known constraints

- **Run exactly one `api` container.** The AI-tagging queue worker holds an
  in-process lock; a second replica would double-process the queue. Scaling
  needs a distributed lock (a Mongo lease document) first.
- **No monitoring yet.** Container logs are rotated (10 MB × 3), and both
  services now report real health to Docker — so `docker ps` is a truthful
  local signal, but nothing is watching it and nothing acts on it. Compose does
  not restart an unhealthy container. A log shipper and an external uptime check
  are still additive work. Whenever that happens, the acceptance test is *"a log
  line from the app appears in the dashboard"* — the predecessor project's Loki
  pipeline was installed but silently dropping everything for a year.
- **Back up the `letsencrypt` volume.** It holds `acme.json`. Losing it means
  re-issuing certificates and risking Let's Encrypt rate limits.
- **MongoDB is Atlas**, so database backups are Atlas's job, not this repo's.
