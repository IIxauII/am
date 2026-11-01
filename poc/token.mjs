// Apple Music developer token: an ES256 JWT signed with the MusicKit .p8 key, using only node:crypto.
import { createPrivateKey, sign } from 'node:crypto'
import { mkdirSync, readFileSync, statSync, writeFileSync } from 'node:fs'
import { dirname } from 'node:path'
import { DEV_TOKEN_CACHE, ENV_FILE, loadEnv } from './config.mjs'

const MAX_TTL = 15777000 // Apple's documented maximum: ~6 months
const TTL = 30 * 24 * 3600
const b64url = (buf) => Buffer.from(buf).toString('base64url')

export function signDeveloperToken({ teamId, keyId, keyPem, ttl = TTL, now = Math.floor(Date.now() / 1000) }) {
  if (ttl > MAX_TTL) throw new Error(`ttl ${ttl}s exceeds Apple's max of ${MAX_TTL}s`)
  const header = { alg: 'ES256', kid: keyId }
  const payload = { iss: teamId, iat: now, exp: now + ttl }
  const input = `${b64url(JSON.stringify(header))}.${b64url(JSON.stringify(payload))}`
  // JWS wants the raw r||s signature (IEEE P1363), not the DER that node emits by default.
  const sig = sign('sha256', Buffer.from(input), { key: createPrivateKey(keyPem), dsaEncoding: 'ieee-p1363' })
  return `${input}.${b64url(sig)}`
}

export function decodeJwt(jwt) {
  const [h, p] = jwt.split('.')
  return { header: JSON.parse(Buffer.from(h, 'base64url')), payload: JSON.parse(Buffer.from(p, 'base64url')) }
}

// Returns the cached token while it matches the current env and key file and has more than a day
// left, otherwise signs a fresh one.
export function getDeveloperToken() {
  const { teamId, keyId, keyPath } = loadEnv()
  if (!teamId || !keyId) throw new Error(`TEAM_ID / KEY_ID missing: create ${ENV_FILE} (see SETUP.md section 1)`)
  try {
    const cached = readFileSync(DEV_TOKEN_CACHE, 'utf8').trim()
    const { header, payload } = decodeJwt(cached)
    const fresh = statSync(DEV_TOKEN_CACHE).mtimeMs >= statSync(keyPath).mtimeMs
    if (header.kid === keyId && payload.iss === teamId && fresh && payload.exp - Date.now() / 1000 > 24 * 3600) return cached
  } catch {}
  const token = signDeveloperToken({ teamId, keyId, keyPem: readFileSync(keyPath, 'utf8') })
  mkdirSync(dirname(DEV_TOKEN_CACHE), { recursive: true, mode: 0o700 })
  writeFileSync(DEV_TOKEN_CACHE, token + '\n', { mode: 0o600 })
  return token
}
