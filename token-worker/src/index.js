// The shared developer token service for `am` (SETUP.md section 6): `GET /token` answers a token
// signed with the MusicKit key in the MUSICKIT_KEY secret.
//
// Settings, all secrets (`wrangler secret put`), so wrangler.toml holds nothing of the account's
// and a deploy never resets them:
//   MUSICKIT_KEY  the .p8 contents (PEM)
//   TEAM_ID       the Apple Developer Team ID
//   KEY_ID        the ID of that MusicKit key
//   ENABLED       "true" hands out tokens; anything else, or unset, answers 503 (the off switch)
import { signToken } from './token.js'

const DAY = 24 * 3600

const text = (status, body, headers = {}) =>
  new Response(body, { status, headers: { 'content-type': 'text/plain; charset=utf-8', ...headers } })

/** One token per UTC day and key per instance: every caller that day gets the same one. */
let memo = { day: -1, keyId: '', token: '' }

export async function handle(request, env, { now = Math.floor(Date.now() / 1000), cache } = {}) {
  const url = new URL(request.url)
  if (url.pathname !== '/token') return text(404, 'not found\n')
  if (request.method !== 'GET' && request.method !== 'HEAD') return text(405, 'GET only\n', { allow: 'GET, HEAD' })
  if (env.ENABLED !== 'true') return text(503, 'the shared developer token is switched off\n', { 'cache-control': 'no-store' })
  if (!env.MUSICKIT_KEY || !env.TEAM_ID || !env.KEY_ID) return text(500, 'the token service is missing MUSICKIT_KEY, TEAM_ID or KEY_ID\n', { 'cache-control': 'no-store' })

  const day = Math.floor(now / DAY)
  const headers = { 'cache-control': `public, max-age=${(day + 1) * DAY - now}` }
  if (memo.day === day && memo.keyId === env.KEY_ID) return text(200, memo.token, headers)

  // The Cache API shares the day's token across instances in one data centre where it works;
  // where it doesn't (it isn't confirmed on workers.dev), signing again is cheap. The key ID is
  // in the cache key, so a rotated key never gets the old key's token handed out.
  const key = new Request(`${url.origin}/token?day=${day}&kid=${encodeURIComponent(env.KEY_ID)}`)
  const hit = cache ? await cache.match(key).catch(() => undefined) : undefined
  let token = hit ? await hit.text() : ''
  if (!token) {
    token = await signToken({ keyPem: env.MUSICKIT_KEY, teamId: env.TEAM_ID, keyId: env.KEY_ID, now })
    if (cache) await cache.put(key, text(200, token, headers)).catch(() => {})
  }
  memo = { day, keyId: env.KEY_ID, token }
  return text(200, token, headers)
}

/** Forgets the day's token (tests). */
export function reset() {
  memo = { day: -1, keyId: '', token: '' }
}

export default {
  async fetch(request, env) {
    return handle(request, env, { cache: globalThis.caches?.default })
  },
}
