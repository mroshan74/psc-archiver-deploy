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
| `REPO_URL` | `scripts/bootstrap-server.sh` | This repo's clone URL, if not `mroshan74/psc-archiver-deploy` |
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
| `scripts/bootstrap-server.sh` | One-time VPS setup (Docker + firewall are **not** included — see below) |
| `scripts/configure-firewall.sh` | Optional, manual: lock the server down to SSH/HTTP/HTTPS |
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

## Set up a server

```bash
ssh root@<new-vps>
curl -fsSL https://raw.githubusercontent.com/mroshan74/psc-archiver-deploy/master/scripts/bootstrap-server.sh | bash
```

Requires Docker (with the Compose plugin) to already be installed — the
script checks and refuses to continue otherwise rather than installing it
for you; provisioning the platform is the operator's call, not the app's.
See [docs.docker.com/engine/install](https://docs.docker.com/engine/install/).

Given that, bootstrap creates the `deploy` user, clones this repo to
`/opt/psc-archiver`, and creates the `traefik_proxy` network. It prints the
remaining manual steps when it finishes, and also saves them to
`/opt/psc-archiver/REMAINING-STEPS.txt` in case your session drops before
you're done — `cat` that file anytime, or just re-run the script; it's
idempotent and safe to repeat.

**Firewall lockdown is a separate, manual step on purpose** — resetting ufw
from inside this unattended script could end the SSH session running it.
Once you're ready, with a way to recover if something goes wrong (provider
console, a second session), run:

```bash
sudo /opt/psc-archiver/scripts/configure-firewall.sh
```

It auto-detects the real SSH port(s) from `sshd_config` (22 is always kept
open regardless), shows you exactly what it's about to allow, and requires
typing `yes` before touching anything.

Then, in the GitHub settings of **both** app repos, add these secrets:

| Secret | Value |
|---|---|
| `VPS_HOST` | Server IP or hostname |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Private half of a passphrase-protected deploy key |
| `VPS_SSH_KEY_PASSPHRASE` | That key's passphrase |

No registry credentials are needed — GHCR authenticates with the built-in
`GITHUB_TOKEN`.

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

`deploy.sh` will:

1. `git pull` this repo, so the config is the committed one
2. check the server's `.env` has every key present in `.env.example`, and
   **abort before touching anything** if not
3. write the tag into `.env` (and `BUILD_ID`, for the api)
4. pull the image, then recreate only that one service
5. poll `/api/readyz` **from inside the web container** — the real browser path
6. prune images older than 7 days, keeping a week of rollback targets

Expect a few seconds of downtime while the container restarts. That is
accepted: this pipeline optimises for fast, verified iteration rather than
availability. Real zero-downtime needs two API replicas, which needs a
distributed lock first (see *Known constraints*).

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
ssh deploy@<vps>
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

**Deploy failed at "Checking environment".** The output lists the missing keys.
Add them to `/opt/psc-archiver/.env`. Nothing was changed — the running stack is
untouched.

**Deploy failed at "Waiting for the app to respond".** The new image is running
but not serving. The last 40 log lines are printed above the failure. Roll back
with the command the script prints, then investigate.

**The API container restarts in a loop.** Almost always a missing or malformed
env var — the app deliberately refuses to boot without `MONGODB_URI` and
`JWT_SECRET`. Check `docker compose -f compose.prod.yml -p psc-archiver logs api`.

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
- **No monitoring yet.** Container logs are rotated (10 MB × 3) and the health
  endpoints exist, so a log shipper and uptime checks are additive when needed.
  Whenever that happens, the acceptance test is *"a log line from the app
  appears in the dashboard"* — the predecessor project's Loki pipeline was
  installed but silently dropping everything for a year.
- **Back up the `letsencrypt` volume.** It holds `acme.json`. Losing it means
  re-issuing certificates and risking Let's Encrypt rate limits.
- **MongoDB is Atlas**, so database backups are Atlas's job, not this repo's.
