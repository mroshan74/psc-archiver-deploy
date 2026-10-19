# Quickstart — bring the server up from nothing

**Commands, in order, meant to be pasted one after another.** This is the path
back to a working app after an MVP round has been torn down. Everything here is
explained properly in [README.md](README.md); this file exists so you do not
have to read it again at 1am.

Every step is safe to re-run.

---

## 0. Preconditions

No commands. Confirm these are true before pasting anything:

- [ ] The box is provisioned and Docker works for your account: [INSTRUCTION.md](INSTRUCTION.md) steps 1-3, verified with `docker info`.
- [ ] `scripts/setup-app.sh` has been run once, so `/opt/psc-archiver` exists, holds this repo, and has a filled-in `.env`.
- [ ] `docker login ghcr.io` has been done once on this account (the three GHCR packages are private).
- [ ] Both DNS A records (`ADMIN_HOST`, `LEARNER_HOST`) resolve to this server.
- [ ] `API_TAG`, `WEB_TAG` and `LEARNER_TAG` in `.env` name **published** tags.
- [ ] **The database is empty.** Production runs on MongoDB Atlas, so there is no container to wipe and `down -v` clears nothing. Clear it in Atlas yourself. Nothing in this repo deletes data.

If any of those is not true, start from [README.md → Set up the application](README.md#set-up-the-application) instead.

---

## 1. Traefik

Owns the shared `traefik_proxy` network, so it goes first. Already running from a
previous round? Skip it, this stack is not torn down between rounds.

```bash
cd /opt/psc-archiver
ACME_EMAIL=you@example.com docker compose -f compose.traefik.yml -p traefik up -d
```

Expect: `Container traefik  Started`.

---

## 2. The app stack

All three services together. Not `deploy.sh` — its readiness probe reaches the
api *through* a web container, so on a stack where nothing is running yet a
single-service deploy always times out.

```bash
docker compose -f compose.prod.yml -p psc-archiver up -d
```

Expect: `psc-archiver-api`, `psc-archiver-web` and `psc-archiver-learner` started.
Give the api ~30s, then:

```bash
docker compose -f compose.prod.yml -p psc-archiver ps
```

Expect: `api` reaches `(healthy)`. Do not seed before it does.

---

## 3. Seed everything — one command

System organization, superadmin, taxonomy, then the 163 bundled exam papers and
their 14,868 questions. It runs inside the api image and talks to `api:5000` over
the internal network, so **you never sign in or call the API yourself**.

```bash
docker compose -f compose.prod.yml -p psc-archiver --profile seed run --rm seed
```

Expect, on an empty database:

```
[seed] Creating the System organization and superadmin (skipped if present)...
[seed] Seeded the system organization (_id=6a71ad994b228f7bf76fb570).
[seed] Seeded superadmin: _id=6a71ad994b228f7bf76fb569, ...
[seed] Waiting for http://api:5000/api/readyz ...
[seed] API is ready.
[seed] Signed in as <SEED_SUPERADMIN_USERNAME>.
[seed] Seeding the taxonomy from the bundled file...
[seed] Taxonomy v1 is active: ...
[seed] Check: papers to create 163, already present 0, questions to add 14868, to refresh 0, not in the files 0.
[seed] Done. Papers created: 163, already present: 0, questions created: 14868, changed: 0, brought back: 0.
[seed] Sign in at https://<ADMIN_HOST> with "<SEED_SUPERADMIN_USERNAME>".
```

Run it again and every line reports a skip or a zero. That is the expected
outcome, not a failure.

### The two overrides

Both are one-off, passed inline. Neither belongs in `.env`.

```bash
# add a taxonomy version even though the database already has one
docker compose -f compose.prod.yml -p psc-archiver --profile seed \
  run --rm -e SEED_TAXONOMY_FORCE=1 seed

# import content even though the check found questions the seed files do not list
docker compose -f compose.prod.yml -p psc-archiver --profile seed \
  run --rm -e SEED_FORCE=1 seed
```

`SEED_FORCE` exists for one case only: you added questions deliberately and want
to keep them. If you did not, the check is telling you the database predates
`_id` matching and importing would insert a second copy of all 14,868 rows. Clear
the database and start from step 3 instead.

---

## 4. Verify

```bash
# both nginx tiers reach the api through their own /api proxy
docker compose -f compose.prod.yml -p psc-archiver exec -T web     wget -q -O- http://127.0.0.1/api/readyz
docker compose -f compose.prod.yml -p psc-archiver exec -T learner wget -q -O- http://127.0.0.1/api/readyz
```

Expect: `{"status":"ok","database":"connected","buildId":"..."}` from each.

```bash
# the PDF faces, including the one with spaces in its name
for svc in web learner; do
  docker compose -f compose.prod.yml -p psc-archiver exec -T $svc \
    wget -S -q -O /dev/null "http://127.0.0.1/fonts/Century%20Schoolbook%20Std%20Regular.otf"
done

# a missing face must 404, never 200 with index.html
docker compose -f compose.prod.yml -p psc-archiver exec -T web \
  wget -S -q -O /dev/null "http://127.0.0.1/fonts/no-such-face.otf"
```

Expect: `200 OK` with `Content-Type: font/otf` for the first, `404` for the second.
A 200 on the second means the `/fonts/` block is missing and every Malayalam
export will fail several layers away from the cause.

Then in a browser:

- `https://<ADMIN_HOST>` — sign in as the seeded superadmin, set a new password when prompted, confirm the taxonomy page shows subjects and the exam papers list shows 163.
- `https://<LEARNER_HOST>` — sign in by mobile number, open a paper, download it, and confirm the Malayalam renders.

### Paper lifecycle audit (once, when the decision 0040 build first goes out)

Read-only report of published papers with no questions and stale question counts, run inside the api container so it uses that container's `MONGODB_URI`. Exit `0` means clean. `--apply` moves empty published papers back to draft and refreshes the counts. Details: `psc-archiver-api/src/scripts/audit-paper-lifecycle.ts`.

```bash
docker compose -f compose.prod.yml -p psc-archiver exec -T api node dist/scripts/audit-paper-lifecycle.js
docker compose -f compose.prod.yml -p psc-archiver exec -T api node dist/scripts/audit-paper-lifecycle.js --apply
```

### Question bank backfill (once, when the decision 0042 build first goes out, and required)

Every question needs a `bank` (`pyq` or `external`) before the admin app can list it: each Question Bank page now asks for one bank, and a row from before the field matches neither, so an unbackfilled database shows **empty** Questions, My Questions and Review pages. Run it right after the new api image is up, inside the api container so it uses that container's `MONGODB_URI`. The first form only reports; `--apply` writes. It is safe to re-run, and rows the new build creates are stamped on write. Details: `psc-archiver-api/src/scripts/backfill-question-banks.ts`.

```bash
docker compose -f compose.prod.yml -p psc-archiver exec -T api node dist/scripts/backfill-question-banks.js
docker compose -f compose.prod.yml -p psc-archiver exec -T api node dist/scripts/backfill-question-banks.js --apply
```

---

## 5. Pull the latest build and restart everything

**This is the loop to use until the git pipelines are wired up.** Every push to
an app repo publishes `:latest` alongside its `:<short-sha>` tag, so pointing the
stack at `latest` and pulling is enough to pick up whatever was last built.

**One command does the whole thing:**

```bash
cd /opt/psc-archiver
./scripts/deploy-latest.sh
```

Stop, pull, start, and prove both nginx tiers answer. Add `--seed` to run the
step 3 bootstrap in the same pass, which is what you want after clearing the
database:

```bash
./scripts/deploy-latest.sh --seed
```

| Flag | Does |
|---|---|
| *(none)* | `down`, `pull`, `up -d`, then probe `web` and `learner` |
| `--seed` | also runs the seed profile once the api is answering |
| `--no-down` | skip the stop; compose recreates only services whose image changed, so an unchanged frontend is not bounced |
| `--tag <tag>` | use a pinned tag instead of `latest`, for all three services at once |
| `--help` | the summary above |

It refuses to touch anything if `.env` is missing a key that `.env.example` has,
the same check `deploy.sh` runs, and it takes the **same lock** as `deploy.sh` so
a refresh and a CI deploy cannot interleave.

### The same thing by hand

If you would rather not use the script, or want to see what it does:

```bash
cd /opt/psc-archiver

# 1. point every service at the newest published image, and stamp a fresh
#    BUILD_ID so old sessions are retired the way a real deploy retires them
sed -i 's/^API_TAG=.*/API_TAG=latest/;s/^WEB_TAG=.*/WEB_TAG=latest/;s/^LEARNER_TAG=.*/LEARNER_TAG=latest/' .env
sed -i "s/^BUILD_ID=.*/BUILD_ID=$(date +%y%m%d%H%M)-latest/" .env

# 2. stop all app services
docker compose -f compose.prod.yml -p psc-archiver down

# 3. pull the newest images
docker compose -f compose.prod.yml -p psc-archiver pull

# 4. start everything again
docker compose -f compose.prod.yml -p psc-archiver up -d
```

Step 1 only has to be run **once**; after that `.env` already says `latest` and
the loop is just steps 2 to 4. Re-stamping `BUILD_ID` each time is what signs out
sessions minted by the previous build, which a pinned-tag deploy gets for free.

Once the stack is up, re-run the seed if the database was cleared:

```bash
docker compose -f compose.prod.yml -p psc-archiver --profile seed run --rm seed
```

> **Never add `-v` to that `down`.** It would delete the `ai_tagging_jobs`
> volume, and OpenAI batch jobs run for minutes to 24 hours with their artefacts
> on it. It is also **not** a way to reset data: the database is MongoDB Atlas,
> which no compose command touches. Clear that in Atlas.

> **`latest` is a testing convenience, not the deployment model.** While the tags
> say `latest` you cannot roll back, because `rollback.sh` works by redeploying a
> pinned tag and there is no record here of which build you are on. `docker
> compose -f compose.prod.yml -p psc-archiver images` shows the image IDs you are
> actually running. When the pipelines land, go back to pinned short-SHA tags,
> which is what `deploy.sh` writes.

---

## 6. Once the git pipelines are wired up

CI then does all of the above on every push, and by hand it becomes:

```bash
cd /opt/psc-archiver
./scripts/deploy.sh api     <sha>
./scripts/deploy.sh web     <sha>   # staff back office
./scripts/deploy.sh learner <sha>   # learner app
```

Roll back:

```bash
./scripts/rollback.sh api            # list the tags on this host
./scripts/rollback.sh api <old-sha>
```

---

## The same thing locally

The prod-parity stack, which brings its own MongoDB and needs no Traefik, DNS or
TLS. Use it to rehearse any of the above:

```bash
cd psc-archiver-deploy
docker compose -f compose.local.yml down -v            # wipe the database
docker compose -f compose.local.yml up -d --build
docker compose -f compose.local.yml --profile seed run --rm seed
# → http://localhost:8080  (admin)
# → http://localhost:8081  (learner)
```

Default account: `superadmin` / `ChangeMe123!`, override with
`SEED_SUPERADMIN_USERNAME` / `SEED_SUPERADMIN_PASSWORD`. The learner's one-time
code is printed in `docker compose -f compose.local.yml logs api`.

---

## When it goes wrong

| Symptom | Cause |
|---|---|
| `network traefik_proxy declared as external, but could not be found` | Step 1 was skipped |
| Seed stops at `API did not become ready` | The api container is not up, or is unhealthy. `docker compose -f compose.prod.yml -p psc-archiver logs api` |
| Seed stops at `Login failed (401)` | `SEED_SUPERADMIN_USERNAME` / `SEED_SUPERADMIN_PASSWORD` in `.env` do not match the account already in the database |
| `Refusing to import: N questions ... are not in the seed files` | The database is not empty and predates `_id` matching. Clear it and re-run step 3 |
| `unauthorized` / `denied` pulling an image | No GHCR login on this account, or a fine-grained PAT instead of a classic one with `read:packages` |
| `manifest unknown` pulling `:latest` | That repo's workflow has never completed a build, so no `:latest` exists yet. Push once, or set that one tag back to a short SHA that does exist |
| A refresh pulled nothing and the app looks unchanged | `:latest` has not moved since the last pull. Confirm the build actually ran, then compare `docker compose -f compose.prod.yml -p psc-archiver images` before and after |
| Certificate not issued | DNS does not resolve yet. `dig +short <ADMIN_HOST>`, then `docker logs traefik` |

Longer list, with the reasoning: [README.md → Troubleshooting](README.md#troubleshooting).
