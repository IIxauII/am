// node --test token-worker/test: the token service signs what Apple and `am` expect.
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { generateKeyPairSync, verify } from 'node:crypto'
import { handle, reset } from '../src/index.js'
import { LIFETIME_SECONDS, ORIGINS, pemToDer, signToken } from '../src/token.js'

const { privateKey, publicKey } = generateKeyPairSync('ec', { namedCurve: 'P-256' })
const keyPem = privateKey.export({ type: 'pkcs8', format: 'pem' })
const env = { MUSICKIT_KEY: keyPem, TEAM_ID: 'TEAM123456', KEY_ID: 'KEY1234567', ENABLED: 'true' }
const now = 1_800_000_000

const part = (s) => JSON.parse(Buffer.from(s, 'base64url').toString())
const get = (path = '/token', init) => new Request(`https://am-token.example.workers.dev${path}`, init)

function checkSignature(token) {
  const [h, c, s] = token.split('.')
  return verify('sha256', Buffer.from(`${h}.${c}`), { key: publicKey, dsaEncoding: 'ieee-p1363' }, Buffer.from(s, 'base64url'))
}

test('a token is ES256 over {alg,kid}.{iss,iat,exp,origin}, valid for 7 days, for the engine page origins', async () => {
  const token = await signToken({ keyPem, teamId: 'TEAM123456', keyId: 'KEY1234567', now })
  const [h, c, s] = token.split('.')
  assert.deepEqual(part(h), { alg: 'ES256', kid: 'KEY1234567' })
  assert.deepEqual(part(c), { iss: 'TEAM123456', iat: now, exp: now + 7 * 24 * 3600, origin: ORIGINS })
  assert.equal(LIFETIME_SECONDS, 604800)
  assert.deepEqual(ORIGINS, ['http://localhost:47823', 'http://127.0.0.1:47823', 'http://[::1]:47823'])
  // Raw r||s, 64 bytes, as JWS wants; node verifies it with the public key.
  assert.equal(Buffer.from(s, 'base64url').length, 64)
  assert.ok(checkSignature(token))
  assert.ok(!/[+/=]/.test(token), 'base64url without padding')
})

test('GET /token answers the token as text, the same one all day', async () => {
  reset()
  const first = await handle(get(), env, { now })
  assert.equal(first.status, 200)
  assert.match(first.headers.get('content-type'), /^text\/plain/)
  const token = await first.text()
  assert.ok(checkSignature(token))
  assert.equal(part(token.split('.')[1]).exp, now + LIFETIME_SECONDS)
  const day = 24 * 3600
  const endOfDay = (Math.floor(now / day) + 1) * day
  assert.equal(first.headers.get('cache-control'), `public, max-age=${endOfDay - now}`)

  const later = await handle(get(), env, { now: now + 60 })
  assert.equal(await later.text(), token)
  const nextDay = await handle(get(), env, { now: endOfDay })
  assert.notEqual(await nextDay.text(), token)
})

test('a rotated key gets a new token the same day, from memory and from the cache', async () => {
  reset()
  const store = new Map()
  const cache = {
    match: async (req) => store.get(req.url)?.clone(),
    put: async (req, res) => void store.set(req.url, res.clone()),
  }
  await handle(get(), env, { now, cache })
  const rotated = await (await handle(get(), { ...env, KEY_ID: 'NEWKEY0001' }, { now: now + 5, cache })).text()
  assert.equal(part(rotated.split('.')[0]).kid, 'NEWKEY0001')
  reset()
  const fromCache = await (await handle(get(), { ...env, KEY_ID: 'NEWKEY0001' }, { now: now + 6, cache })).text()
  assert.equal(fromCache, rotated)
  assert.equal(store.size, 2)
})

test('the day token is taken from the cache when another instance signed it', async () => {
  reset()
  const store = new Map()
  const cache = {
    match: async (req) => store.get(req.url)?.clone(),
    put: async (req, res) => void store.set(req.url, res.clone()),
  }
  const token = await (await handle(get(), env, { now, cache })).text()
  assert.equal(store.size, 1)
  reset()
  assert.equal(await (await handle(get(), env, { now: now + 5, cache })).text(), token)
  // A cache that fails is only slower.
  reset()
  const broken = { match: async () => { throw new Error('no cache') }, put: async () => { throw new Error('no cache') } }
  assert.equal((await handle(get(), env, { now, cache: broken })).status, 200)
})

test('the off switch: anything but ENABLED=true answers 503, and nothing is signed', async () => {
  reset()
  for (const ENABLED of ['false', '', undefined, 'TRUE']) {
    const res = await handle(get(), { ...env, ENABLED }, { now })
    assert.equal(res.status, 503)
    assert.equal(res.headers.get('cache-control'), 'no-store')
    assert.match(await res.text(), /switched off/)
  }
})

test('other paths, other methods and missing settings', async () => {
  reset()
  assert.equal((await handle(get('/'), env, { now })).status, 404)
  assert.equal((await handle(get('/token/x'), env, { now })).status, 404)
  assert.equal((await handle(get('/token', { method: 'POST', body: 'x' }), env, { now })).status, 405)
  assert.equal((await handle(get(), { ...env, MUSICKIT_KEY: undefined }, { now })).status, 500)
  assert.equal((await handle(get(), { ...env, KEY_ID: '' }, { now })).status, 500)
})

test('the PEM armour and line breaks are stripped; anything else is refused', () => {
  const der = pemToDer(keyPem)
  assert.equal(der[0], 0x30, 'DER SEQUENCE')
  assert.deepEqual(pemToDer(keyPem.replace(/\n/g, '\r\n')), der)
  assert.throws(() => pemToDer('not a key'), /not a PEM/)
  assert.throws(() => pemToDer(''), /not a PEM/)
})
