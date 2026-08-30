/**
 * First-run bootstrap. Drives BOTH stacks — the local prod-parity one
 * (compose.local.yml) and the server (compose.prod.yml), through the `seed`
 * profile in each. It was `seed-local.mjs` until it grew a production caller.
 *
 * Mirrors the setup path the multi-tenant roadmap specifies: because the app
 * has never been in production there is no migration story — a fresh database
 * is seeded from scratch.
 *
 *   1. create the System organization and the superadmin (idempotent — both are
 *      pinned to fixed _ids, so the script does nothing if they are already
 *      there, and warns without creating a second account if a superadmin
 *      exists under a different _id). Written straight to MongoDB; the API does
 *      not need to be up for this step
 *   2. wait for the API to report ready
 *   3. sign in, and seed the taxonomy if the database has none
 *   4. run the content seeder over the bundled exam-paper JSON
 *
 * Steps 3 and 4 talk to the API over the compose network (`api:5000`), never
 * over the public internet: whoever runs this makes no API call of their own
 * and needs no token.
 *
 * Safe to re-run at any time. The content seeder upserts papers and questions
 * against the _id in the seed files, so a repeat run refreshes existing rows
 * rather than duplicating them.
 *
 * Two guards, because two things here are not idempotent by themselves:
 *
 *   - Step 3. `POST /api/taxonomy/seed` mints a NEW version on every call and
 *     activates it, so a bare re-run would pile up v1, v2, v3... This reads
 *     `GET /api/taxonomy/versions` first and seeds only into an empty list.
 *     Set SEED_TAXONOMY_FORCE=1 to add a version deliberately.
 *   - Step 4 always runs a check first and refuses the write if the check
 *     reports questions the seed files do not account for. That is the signal
 *     of a database seeded by the pre-_id-matching seeder, where a real import
 *     would insert a second copy of the whole corpus. Set SEED_FORCE=1 to
 *     import anyway.
 *
 * Runs inside the API image, so it has `dist/scripts/` and Node 22's global
 * fetch. No extra dependencies.
 */
import { execFileSync } from 'node:child_process'

const API_BASE_URL = process.env.API_BASE_URL ?? 'http://api:5000'
// Where a human should go when this finishes. The local stack passes the
// published admin port; the server passes https://$ADMIN_HOST.
const ADMIN_URL = process.env.ADMIN_URL ?? 'http://localhost:8080'
const USERNAME = process.env.SEED_SUPERADMIN_USERNAME
const PASSWORD = process.env.SEED_SUPERADMIN_PASSWORD
const FORCE = process.env.SEED_FORCE === '1'
const TAXONOMY_FORCE = process.env.SEED_TAXONOMY_FORCE === '1'

const log = (msg) => console.log(`[seed] ${msg}`)

function seedSuperadmin() {
  log('Creating the System organization and superadmin (skipped if present)...')
  execFileSync('node', ['/app/dist/scripts/seed-superadmin.js'], {
    stdio: 'inherit',
    cwd: '/app',
  })
}

async function waitForApi(timeoutMs = 90_000) {
  log(`Waiting for ${API_BASE_URL}/api/readyz ...`)
  const deadline = Date.now() + timeoutMs

  while (Date.now() < deadline) {
    try {
      const res = await fetch(`${API_BASE_URL}/api/readyz`)
      if (res.ok) {
        log('API is ready.')
        return
      }
    } catch {
      // Not listening yet — keep waiting.
    }
    await new Promise((resolve) => setTimeout(resolve, 2000))
  }

  throw new Error(
    `API did not become ready within ${timeoutMs / 1000}s. ` +
      `Check that the api container is up and that this container shares its network.`,
  )
}

async function login() {
  const res = await fetch(`${API_BASE_URL}/api/auth/login`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ username: USERNAME, password: PASSWORD }),
  })

  if (!res.ok) {
    throw new Error(`Login failed (${res.status}): ${await res.text()}`)
  }

  const { access_token: token } = await res.json()
  if (!token) throw new Error('Login succeeded but returned no token.')

  log(`Signed in as ${USERNAME}.`)
  return token
}

async function api(token, method, path, body) {
  const res = await fetch(`${API_BASE_URL}${path}`, {
    method,
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })

  const text = await res.text()
  if (!res.ok) {
    throw new Error(`${method} ${path} failed (${res.status}): ${text}`)
  }
  return text ? JSON.parse(text) : null
}

async function seedTaxonomy(token) {
  const { data: versions = [] } = await api(token, 'GET', '/api/taxonomy/versions')

  if (versions.length > 0 && !TAXONOMY_FORCE) {
    const active = versions.find((v) => v.isActive)
    log(
      `Taxonomy already seeded: ${versions.length} version(s), active v${active?.version ?? 'none'}. Skipped.`,
    )
    log('Set SEED_TAXONOMY_FORCE=1 to add a version from the bundled file anyway.')
    return
  }

  if (versions.length > 0) {
    log(`SEED_TAXONOMY_FORCE=1: adding a version on top of the existing ${versions.length}.`)
  }

  log('Seeding the taxonomy from the bundled file...')
  const created = await api(token, 'POST', '/api/taxonomy/seed', {
    activate: true,
    changeSummary: 'Seeded by the deploy bootstrap',
  })

  log(
    `Taxonomy v${created.version} is active: ${created.subjectCount} subjects, ` +
      `${created.topicCount} topics, ${created.subtopicCount} subtopics.`,
  )
}

async function runSeeder(token, dryRun) {
  return api(token, 'POST', '/api/seeder/import', { dryRun })
}

async function checkContent(token) {
  log('Checking the seed files against the database...')
  const result = await runSeeder(token, true)

  log(
    `Check: papers to create ${result.papersCreated}, already present ${result.papersExisting}, ` +
      `questions to add ${result.questionsCreated}, to refresh ${result.questionsUpdated}, ` +
      `not in the files ${result.questionsUnmatchedCount}.`,
  )

  if (result.questionsUnmatchedCount > 0 && !FORCE) {
    throw new Error(
      `Refusing to import: ${result.questionsUnmatchedCount} questions on these papers are not in the seed files.\n` +
        '[seed] That is what a database seeded before _id matching looks like — importing would add a second copy of every question.\n' +
        '[seed] Drop the seeder-owned collections (questions, exampapers) and run this again.\n' +
        "[seed] On the local stack:  docker compose -f compose.local.yml exec mongo mongosh pscarchiver --eval 'db.questions.drop(); db.exampapers.drop()'\n" +
        '[seed] On a server the database is Atlas, so clear it there.\n' +
        '[seed] Or set SEED_FORCE=1 if you are certain those extra questions should stay.',
    )
  }
}

async function importContent(token) {
  log('Importing the bundled exam papers and questions...')
  const result = await runSeeder(token, false)

  // These are true change counts: the seeder does not stamp updatedAt, so a
  // repeat run with no seed-file edits reports created 0 / changed 0.
  log(
    `Done. Papers created: ${result.papersCreated}, already present: ${result.papersExisting}, ` +
      `questions created: ${result.questionsCreated}, changed: ${result.questionsUpdated}, ` +
      `brought back: ${result.questionsRestored}.`,
  )
}

async function main() {
  if (!USERNAME || !PASSWORD) {
    throw new Error(
      'SEED_SUPERADMIN_USERNAME and SEED_SUPERADMIN_PASSWORD must be set.',
    )
  }

  seedSuperadmin()
  await waitForApi()
  const token = await login()
  await seedTaxonomy(token)
  await checkContent(token)
  await importContent(token)

  log('')
  log(`Sign in at ${ADMIN_URL} with "${USERNAME}".`)
  log('You will be asked to set a new password on first sign-in.')
}

main().catch((err) => {
  console.error(`[seed] ${err.message}`)
  process.exit(1)
})
