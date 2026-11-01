// Live check of a deployed token service, against Apple:
//
//   node token-worker/live-check.mjs [token service URL]
//
// The URL defaults to TOKEN_URL, else https://am-token.xauyxau.workers.dev/token (the built-in
// one, src/token_source.zig `default_url`).
//
// 1. GET the token from the service (prints its header and claims, never the token).
// 2. GET /v1/test and one catalog search with it and `Origin: http://localhost:47823`: must be 200.
// 3. GET /v1/test without an Origin header, and with another origin: Apple must refuse them.
// Exits 1 when anything doesn't go as expected. Sends nothing that changes an account.
const url = process.argv[2] || process.env.TOKEN_URL || 'https://am-token.xauyxau.workers.dev/token'
const apple = 'https://api.music.apple.com'
const origin = 'http://localhost:47823'
let failed = false
const report = (ok, line) => {
  console.log(`${ok ? '✔' : '✘'} ${line}`)
  if (!ok) failed = true
}

const res = await fetch(url)
const token = (await res.text()).trim()
report(res.status === 200, `token service ${url} → HTTP ${res.status}${res.status === 200 ? '' : `: ${token.slice(0, 200)}`}`)
if (res.status !== 200) process.exit(1)
const [h, c] = token.split('.')
const header = JSON.parse(Buffer.from(h, 'base64url'))
const claims = JSON.parse(Buffer.from(c, 'base64url'))
const left = claims.exp - Math.floor(Date.now() / 1000)
console.log(`  header ${JSON.stringify(header)}`)
console.log(`  claims ${JSON.stringify(claims)}`)
report(left > 0 && left <= 7 * 24 * 3600, `expires ${new Date(claims.exp * 1000).toISOString()} (${(left / 86400).toFixed(1)} days left)`)
report(Array.isArray(claims.origin) && claims.origin.includes(origin), `origin claim includes ${origin}`)

const call = async (path, headers) => {
  const r = await fetch(`${apple}${path}`, { headers: { Authorization: `Bearer ${token}`, ...headers } })
  return { status: r.status, body: await r.text() }
}

const test = await call('/v1/test', { Origin: origin })
report(test.status === 200, `GET /v1/test with Origin ${origin} → HTTP ${test.status} (expected 200)`)

const search = await call('/v1/catalog/us/search?term=beatles&types=songs&limit=1', { Origin: origin })
let hits = 0
try {
  hits = JSON.parse(search.body).results?.songs?.data?.length ?? 0
} catch {}
report(search.status === 200 && hits > 0, `catalog search with Origin → HTTP ${search.status}, ${hits} song(s) (expected 200 and 1)`)

const bare = await call('/v1/test', {})
report(bare.status === 401 || bare.status === 403, `GET /v1/test without Origin → HTTP ${bare.status} (expected 401 or 403: refused)`)

const other = await call('/v1/test', { Origin: 'https://example.com' })
report(other.status === 401 || other.status === 403, `GET /v1/test with Origin https://example.com → HTTP ${other.status} (expected 401 or 403: refused)`)

process.exit(failed ? 1 : 0)
