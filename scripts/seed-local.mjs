/**
 * First-run bootstrap for the local stack.
 *
 * Mirrors the setup path the multi-tenant roadmap specifies: because the app
 * has never been in production there is no migration story — a fresh database
 * is seeded from scratch.
 *
 *   1. create the superadmin (idempotent — the account is pinned to a fixed
 *      _id, so the script does nothing if it is already there, and warns
 *      without creating a second account if a superadmin exists under a
 *      different _id)
 *   2. wait for the API to report ready
 *   3. log in and run the content seeder over the bundled exam-paper JSON
 *
 * Safe to re-run at any time: the content seeder upserts papers and questions
 * against the _id in the seed files, so a repeat run refreshes existing rows
 * rather than duplicating them.
 *
 * Step 3 always runs a check first and refuses the write if the check reports
 * questions the seed files do not account for. That is the signal of a database
 * seeded by the pre-_id-matching seeder, where a real import would insert a
 * second copy of the whole corpus. Set SEED_FORCE=1 to import anyway.
 *
 * Runs inside the API image, so it has `dist/scripts/` and Node 22's global
 * fetch. No extra dependencies.
 */
import { execFileSync } from 'node:child_process'

const API_BASE_URL = process.env.API_BASE_URL ?? 'http://api:5000'
const USERNAME = process.env.SEED_SUPERADMIN_USERNAME
const PASSWORD = process.env.SEED_SUPERADMIN_PASSWORD
const FORCE = process.env.SEED_FORCE === '1'

const log = (msg) => console.log(`[seed] ${msg}`)

function seedSuperadmin() {
  log('Creating superadmin (skipped if one already exists)...')
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

  throw new Error(`API did not become ready within ${timeoutMs / 1000}s`)
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

async function runSeeder(token, dryRun) {
  const res = await fetch(`${API_BASE_URL}/api/seeder/import`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({ dryRun }),
  })

  const body = await res.text()
  if (!res.ok) {
    throw new Error(
      `Seeder ${dryRun ? 'check' : 'import'} failed (${res.status}): ${body}`,
    )
  }
  return JSON.parse(body)
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
        '[seed] Drop the seeder-owned collections and seed again:\n' +
        "[seed]   docker compose -f compose.local.yml exec mongo mongosh pscarchiver --eval 'db.questions.drop(); db.exampapers.drop()'\n" +
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
  await checkContent(token)
  await importContent(token)

  log('')
  log(`Sign in at http://localhost:8080 with "${USERNAME}".`)
  log('You will be asked to set a new password on first sign-in.')
}

main().catch((err) => {
  console.error(`[seed] ${err.message}`)
  process.exit(1)
})
