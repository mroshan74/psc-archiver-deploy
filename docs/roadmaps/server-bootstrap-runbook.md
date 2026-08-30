# Roadmap — one-command server bootstrap, and the deploy-doc catch-up

> **Status:** All five phases complete (2026-08-30). What remains is a **runtime
> pass**: every exit criterion that needs Docker actually running is still
> unticked, and is listed as such under its phase. Everything checkable
> statically (compose parse, `node --check`, `bash -n`, `pnpm check:copy`, the
> reference sweeps) has been run and passes.
>
> **This roadmap advances one phase at a time.** Do the one phase that was asked
> for, tick its boxes, report what was done, and **stop**. Do not continue into
> the next phase unless explicitly told to. See the planning rule in the
> workspace [CLAUDE.md](../../../CLAUDE.md) — `psc-archiver-deploy` has no
> `CLAUDE.md` of its own, so that rule covers this repo.
>
> **Owner repo:** this one. Phases 3-5 touch `psc-archiver-api`,
> `psc-archiver-admin`, `psc-archiver-client` and the workspace root; the
> cross-repo seams follow [INTEGRATION.md](../../../INTEGRATION.md).

## Context

This repo last shipped on **2026-08-18**. The three app repos have moved well past
it: the API landed multi-tenant organizations, the `organization_manager` role, a
fresh-database verification pass and a `src/scripts/` cleanup (through 2026-08-29),
and both frontends have had UI work through 2026-08-30. The docs here describe a
world that no longer quite exists.

The concrete pain: **after every MVP test the server is torn down and started anew,
and standing it back up is not a copy-paste job.** An operator had to bring up
Traefik, bring up the app stack, run a superadmin one-off, then sign in by hand and
`POST /api/seeder/import` with a bearer token to load content. Taxonomy was seeded
by no automated path at all.

Outcome: a fresh server goes from nothing to a fully populated app in **three
pasted commands**, the last of which seeds superadmin, the System organization,
taxonomy, exam papers and questions in one shot with no manual API call, mirroring
what the local prod-parity stack already does.

## Decisions taken up front

1. **Deploy-repo only, no API change.** `scripts/seed-local.mjs` became a shared
   `scripts/bootstrap.mjs` driving *both* compose files, and `compose.prod.yml`
   gained the `seed` profile that only `compose.local.yml` had. The HTTP hop to
   `api:5000` stays inside the compose network: the operator makes no API call,
   needs no token, and the already-published API image works unchanged. An offline
   `dist/scripts/bootstrap.js` inside the API was considered and **deferred** — it
   needs a code change, a build and a GHCR push before the runbook works at all.
2. **Taxonomy is guarded in the script, not fixed in the API.**
   `POST /api/taxonomy/seed` is **not idempotent**: `TaxonomyService.seed` calls
   `createWithNextVersion`, which allocates v1, v2, v3… on every call, and
   `activate` defaults to `true`. The bootstrap reads `GET /api/taxonomy/versions`
   first and seeds only when the list is empty. `SEED_TAXONOMY_FORCE=1` overrides.
3. **No teardown tooling.** The operator clears the Atlas database by hand.
   Nothing destructive is added to a compose file or a script; the runbook only
   states that the database must already be empty. Production has no `mongo`
   container, so `down -v` does not clear data.
4. **The runbook is commands-only, in its own file.** `README.md` is 663 lines and
   stays the reference; `QUICKSTART.md` is the paste target.
5. **No new key in `.env.example`.** `deploy.sh` validates the server's `.env`
   against it key-for-key and aborts on a missing one, so a new required key would
   break every existing server. `SEED_FORCE` and `SEED_TAXONOMY_FORCE` are passed
   inline with `docker compose run -e`.

## What the investigation found

| # | Finding | Where |
|---|---|---|
| F1 | `compose.prod.yml` had **no `seed` service and no profiles** | `compose.prod.yml` |
| F2 | `seed-local.mjs` **never seeded taxonomy**; no automated path did | `scripts/seed-local.mjs` |
| F3 | `POST /api/taxonomy/seed` accumulates a new version per call | `psc-archiver-api/src/taxonomy/taxonomy.service.ts:292` |
| F4 | Bootstrap URL says `/master/scripts/setup-app.sh`; this repo's only branch is **`main`**, so that curl 404s | `README.md:240`, `INSTRUCTION.md:100`, `scripts/setup-app.sh:8` |
| F5 | Workspace `CLAUDE.md` claims deploy is on `master`; it is on `main` | workspace `CLAUDE.md` |
| F6 | The bootstrap hardcoded `http://localhost:8080` in its closing message | `scripts/seed-local.mjs:149` |
| F7 | `seed-superadmin.ts` now also creates the **System organization** at fixed `_id` `6a71ad994b228f7bf76fb570`. No deploy doc mentioned it | `psc-archiver-api/src/scripts/seed-superadmin.ts` |
| F8 | ADR 0013 calls the seed files "untracked `data/dumb/`". They **are** tracked and **do** ship in the image | `psc-archiver-api/doc/decisions/0013-seeder-module.md` |
| F9 | `doc/08-deployment.md` still describes content import as signing in and calling the endpoint | `psc-archiver-api/doc/08-deployment.md` |
| F10 | `psc-archiver-admin/ARCHITECTURE.md` has **no Deployment section**; the client's is the model | both `ARCHITECTURE.md` |
| F11 | Admin `README.md` `## Docker` still says `bash docker.sh`; that file was deleted | `psc-archiver-admin/README.md` |
| F12 | Admin `.env.example` names `https://app.pscarchiver.in`; the real host is `archiver.trynbuild.com` | `psc-archiver-admin/.env.example` |
| F13 | Client nginx `error_page … /50x.html` points at a file the client image does not ship | `psc-archiver-client/nginx.conf`, `public/` |
| F14 | `VITE_CTA_STYLE` is absent from `.env.production` and has no Dockerfile ARG, so production silently takes the code default | `psc-archiver-client/.env.example` |

---

## Phase 1 — The one-command bootstrap ✅

- [x] **Rename** `scripts/seed-local.mjs` → `scripts/bootstrap.mjs` (`git mv`). It is
      no longer local-only; the header comment now says it drives both stacks.
- [x] **Add the taxonomy step**, between `login()` and `checkContent()`:
      `GET /api/taxonomy/versions`, seed only when the list is empty or
      `SEED_TAXONOMY_FORCE=1`, otherwise log a skip naming the active version.
- [x] **Make the closing message environment-aware** — `ADMIN_URL`, defaulting to
      `http://localhost:8080` (F6).
- [x] **Add the `seed` profile to `compose.prod.yml`**: same `${API_IMAGE}:${API_TAG}`
      the `api` service resolves, `env_file: [.env]`, `API_BASE_URL: http://api:5000`,
      `ADMIN_URL: https://${ADMIN_HOST}`, the script mounted read-only,
      `depends_on: [api]`, **`networks: [traefik_proxy]`** and
      **`traefik.enable=false`**.
- [x] **Update `compose.local.yml`'s `seed` service** to mount and run
      `bootstrap.mjs`, plus `ADMIN_URL: http://localhost:${WEB_PORT:-8080}`.

### Exit criteria — Phase 1

- [ ] From an empty database (`down -v`, then `up -d --build`),
      `docker compose -f compose.local.yml --profile seed run --rm seed` completes
      once and reports the System organization and superadmin created, taxonomy
      seeded, 163 papers and 14,868 questions created.
- [ ] `GET /api/taxonomy/versions` returns exactly **one** version, and it is active.
- [ ] An immediate **second** run exits 0 and reports superadmin "nothing to do",
      taxonomy "already seeded, skipped", and `created: 0 / changed: 0` for content.
      The version count stays at 1.
- [x] `docker compose -f compose.prod.yml -p psc-archiver config` parses with the new
      service, on `traefik_proxy`, with `traefik.enable=false`.
- [ ] Admin at `:8080` and learner at `:8081` both serve; the superadmin signs in and
      is prompted to change the password; the taxonomy screen shows subjects.

> The unticked criteria need Docker running against a live stack. The compose-parse
> and static checks are done; the runtime pass is owed at the next stack bring-up.

---

## Phase 2 — `QUICKSTART.md` and the deploy-repo docs ✅

- [x] **New `QUICKSTART.md`** — commands only, in paste order, one line of expected
      output per step. Assumes the box is provisioned (`INSTRUCTION.md` §1-3 +
      `setup-app.sh`) and **the database has already been emptied by the operator**.
      Sections: `0. Preconditions` → `1. Traefik` → `2. App stack` →
      `3. Seed everything (one command)` → `4. Verify` → `5. Later deploys`. Include
      the local prod-parity equivalent, the `-e SEED_FORCE=1` /
      `-e SEED_TAXONOMY_FORCE=1` override forms, and the verify probes from the README.
- [x] **Rewrite `README.md` → "Bootstrap a fresh database"** around the one-command
      path (F1, F2). Keep the standalone `seed-superadmin.js` fallback and the
      `dryRun` / `questionsUnmatchedCount` explanation; add the System organization
      and taxonomy (F7).
- [x] **Fix the `master` → `main` bootstrap URL** in `README.md:240`,
      `INSTRUCTION.md:100`, and `scripts/setup-app.sh:8` (F4).
- [x] **Update `setup-app.sh`'s printed step 7** (`print_remaining_steps`) to the
      one-command bootstrap, so `REMAINING-STEPS.txt` matches the runbook.
- [x] **README housekeeping:** `QUICKSTART.md` in the repository-layout table and
      linked from the intro; `seed-local.mjs` → `bootstrap.mjs` everywhere; note in
      the Deploy section that *this* repo is on `main`.
- [x] **One new Troubleshooting entry:** the seed container failing at
      `API did not become ready` — check it joined `traefik_proxy` first, then that
      the `api` container is up.

### Exit criteria — Phase 2

- [ ] Pasting `QUICKSTART.md` §1-3 in order on a torn-down server brings the app up
      and fully populated, with no editing and no step missing from the file.
- [x] `grep -rn "seed-local\|/master/scripts" . --exclude-dir=.git` returns only this
      roadmap (which records the rename) and `bootstrap.mjs`'s own header comment.
- [x] `setup-app.sh`'s printed steps and `QUICKSTART.md` name the same commands.

> The first criterion is owed a real teardown-and-rebuild on the server. Anything
> it gets wrong is a doc fix, not a code fix.

---

## Phase 3 — API deployment docs catch up ✅

Owner repo: `psc-archiver-api`. Docs only, no code.

- [x] **`doc/08-deployment.md` → "Bootstrapping a database"** — rewrite for the
      one-command path, add taxonomy and its guard, and record that
      `seed-superadmin.js` creates the System organization first because a staff
      role cannot exist without an organization (F7, F9).
- [x] **`doc/08-deployment.md` → "The image"** — state that the `prod` stage ships
      `dist/scripts/` (five entry points) and that `data/exam-papers/` (~19 MB) is
      shipped but read by nothing at runtime.
- [x] **`doc/decisions/0013-seeder-module.md`** — one-clause correction: the seed
      files are tracked and ship in the image (F8). Do not rewrite the decision.
- [x] **`doc/07-future-work.md`** — beside the taxonomy-seed non-idempotency note,
      record that the deploy bootstrap guards it, making an idempotent endpoint a
      cleanup rather than a blocker.
- [x] **`doc/roadmaps/scripts-folder-cleanup.md`** — update the two `seed-local.mjs`
      references. Ticked boxes stay ticked; only the filename changes.

### Exit criteria — Phase 3

- [x] `doc/08-deployment.md` and `QUICKSTART.md` describe the same commands with no
      contradiction.
- [x] No doc in `psc-archiver-api/doc/` names `seed-local.mjs` or claims the seed
      data is untracked.

---

## Phase 4 — Frontend deploy-surface catch-up ✅

Owner repos: `psc-archiver-admin`, `psc-archiver-client`.

- [x] **`psc-archiver-admin/ARCHITECTURE.md`: add a `## Deployment` section** (F10),
      mirroring `psc-archiver-client/ARCHITECTURE.md`: the hostname, the two-stage
      image, push-to-`master` → GHCR `:<short-sha>` → `deploy.sh web <sha>`, rollback,
      the four-file install layer and why `--frozen-lockfile` must stay, the three
      load-bearing `nginx.conf` facts, and the `/fonts/` warning.
- [x] **`psc-archiver-admin/README.md`** — replace the stale `## Docker` /
      `bash docker.sh` block with a pointer to that section (F11).
- [x] **`psc-archiver-admin/.env.example`** — production `VITE_APP_URL` example
      becomes `https://archiver.trynbuild.com` (F12).
- [x] **`psc-archiver-client/public/50x.html`** — add it, in learner voice, so the
      `error_page` directive resolves (F13). Keep the no-em-dash rule.
- [x] **`psc-archiver-client/.env.production`** — add an explicit `VITE_CTA_STYLE`
      line (F14). Touches in-flight uncommitted work, so confirm the intended
      production value first.
- [x] **Both `ARCHITECTURE.md` Deployment sections** — link `QUICKSTART.md` as the
      server-side runbook.

### Exit criteria — Phase 4

- [x] `pnpm check:copy` passes in both repos.
- [ ] Rebuilding the client image and requesting `http://localhost:8081/50x.html`
      returns the branded page, not nginx's stock body.
- [x] Both `CLAUDE.md` doc-sync tables' deploy rows point at sections that exist.
      The admin had **no** such row until now; the client's gained `public/50x.html`.

> The 50x criterion needs a client image rebuild. Extending `check:copy` to scan
> `public/50x.html` immediately caught **two em dashes in the admin's existing
> error page**, which had never been checked because the scanner only looked at
> `src/**` and `index.html`. Both are fixed and both repos' checkers pass.

---

## Phase 5 — Workspace-level docs ✅

- [x] **`CLAUDE.md`** — correct the branch line: `master` for api and admin,
      **`main`** for client **and deploy** (F5). `repos.json` is already right.
- [x] **`INTEGRATION.md` → "Deployment"** — add the bootstrap contract: one command
      seeds superadmin, the System organization, taxonomy and content; it is safe to
      re-run; taxonomy is the one non-idempotent piece and is guarded in the script
      rather than in the API. Link `QUICKSTART.md`.
- [x] **`INTEGRATION.md` → "Run the full stack"** — update the local seed command for
      the renamed script.

### Exit criteria — Phase 5

- [x] `grep -rn "master" CLAUDE.md INTEGRATION.md` finds no claim that the deploy or
      client repo is on `master`.
- [x] A reader starting at the workspace root reaches `QUICKSTART.md` in one hop.

---

## Risks and non-goals

- **Main risk: the seed container's network.** In `compose.local.yml` everything
  shares the default project network, so that service needs no `networks:` key.
  `compose.prod.yml` has no default network of its own, only external
  `traefik_proxy`. Omitting `networks: [traefik_proxy]` produces a container that
  starts fine and then fails 90 seconds later at `waitForApi()` with a message
  pointing at the API rather than at the network. This is the likeliest way Phase 1
  ships broken, and it is why the compose-parse check is an exit criterion.
- **A rename ripples.** `bootstrap.mjs` is referenced from two compose files, the
  README, `setup-app.sh`'s printed steps and two API docs. Phases 2 and 3 exist
  largely to close that sweep; a `grep` for the old name is the real gate.
- **Non-goal: making `POST /api/taxonomy/seed` idempotent.** Left to the API repo.
- **Non-goal: any teardown or database-wipe tooling.** The operator clears the
  database by hand; nothing destructive is added here.
- **Non-goal: an offline `dist/scripts/bootstrap.js` in the API.** Deferred; it is
  the eventual way to drop the HTTP hop entirely.
- **Non-goal: trimming `data/exam-papers/` from the API image.** ~19 MB read by
  nothing, but that is the API repo's own cleanup.
- **Phase 4 touches uncommitted work.** `psc-archiver-client` has ~19 modified files
  and two untracked ones in flight. Only `.env.production` and `public/50x.html` are
  in scope there; leave the rest alone.
