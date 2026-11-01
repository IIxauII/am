// Apple Music REST API called directly from Node, no browser: the "search/library" half of the architecture.
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { CONFIG_DIR, MUT_FILE } from './config.mjs'
import { getDeveloperToken } from './token.mjs'

const BASE = 'https://api.music.apple.com'

export function readUserToken() {
  try {
    return readFileSync(MUT_FILE, 'utf8').trim() || null
  } catch {
    return null
  }
}

export function saveUserToken(token) {
  mkdirSync(CONFIG_DIR, { recursive: true, mode: 0o700 })
  writeFileSync(MUT_FILE, token + '\n', { mode: 0o600 })
}

export async function api(path, { params, userToken = readUserToken(), requireUser = false } = {}) {
  if (requireUser && !userToken) throw new Error('no Music User Token yet: run `node poc/am.mjs signin` first')
  const url = new URL(path, BASE)
  for (const [k, v] of Object.entries(params ?? {})) url.searchParams.set(k, v)
  const headers = { Authorization: `Bearer ${getDeveloperToken()}` }
  if (userToken) headers['Music-User-Token'] = userToken
  const res = await fetch(url, { headers })
  // Some endpoints (e.g. /v1/test) answer 200 with a JSON content type and an empty body.
  const text = await res.text()
  const body = text && res.headers.get('content-type')?.includes('json') ? JSON.parse(text) : text
  return { status: res.status, body }
}

// The user's storefront if we have their token, else the given fallback.
export async function storefront(fallback = 'us') {
  if (!readUserToken()) return fallback
  const { status, body } = await api('/v1/me/storefront')
  return status === 200 ? body.data[0].id : fallback
}

export async function searchSongs(term, { sf, limit = 5 } = {}) {
  sf ??= await storefront()
  const { status, body } = await api(`/v1/catalog/${sf}/search`, { params: { term, types: 'songs', limit } })
  if (status !== 200) throw new Error(`search failed: HTTP ${status} ${JSON.stringify(body).slice(0, 300)}`)
  return (body.results?.songs?.data ?? []).map((s) => ({
    id: s.id,
    name: s.attributes.name,
    artist: s.attributes.artistName,
    album: s.attributes.albumName,
    durationSec: s.attributes.durationInMillis / 1000,
    storefront: sf,
  }))
}
