// Signs the shared Apple Music developer token: an ES256 JWT, with Web Crypto only (it runs in
// Cloudflare Workers and in Node, where the tests run it).

/** Seven days: a copied token stops working within a week. `am` downloads a new one once fewer
 * than five days are left. */
export const LIFETIME_SECONDS = 7 * 24 * 3600

/** Where `am`'s engine page runs (the daemon's default port, src/settings.zig `default_port`).
 * Apple accepts the token only from these origins. `am` sends the first one as the Origin
 * header of its own requests (src/apple.zig `origin`). */
export const ORIGINS = ['http://localhost:47823', 'http://127.0.0.1:47823', 'http://[::1]:47823']

const b64url = (bytes) => {
  let s = ''
  for (const b of bytes) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}
const utf8 = (text) => new TextEncoder().encode(text)

/** The DER bytes of a PKCS #8 PEM (`-----BEGIN PRIVATE KEY-----`, as in Apple's .p8). */
export function pemToDer(pem) {
  const armoured = /-----BEGIN PRIVATE KEY-----([\s\S]*?)-----END PRIVATE KEY-----/.exec(pem)
  const body = armoured ? armoured[1].replace(/\s+/g, '') : ''
  if (body.length === 0 || !/^[A-Za-z0-9+/]+=*$/.test(body)) throw new Error('MUSICKIT_KEY is not a PEM private key')
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
}

/** Header `{alg, kid}`, claims `{iss, iat, exp, origin}`. Web Crypto's ECDSA signature is already
 * the raw r||s that JWS wants. */
export async function signToken({ keyPem, teamId, keyId, now, crypto = globalThis.crypto }) {
  const key = await crypto.subtle.importKey('pkcs8', pemToDer(keyPem), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const header = { alg: 'ES256', kid: keyId }
  const claims = { iss: teamId, iat: now, exp: now + LIFETIME_SECONDS, origin: ORIGINS }
  const input = `${b64url(utf8(JSON.stringify(header)))}.${b64url(utf8(JSON.stringify(claims)))}`
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, utf8(input))
  return `${input}.${b64url(new Uint8Array(signature))}`
}
