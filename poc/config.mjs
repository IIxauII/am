// Paths and settings shared by the POC. Secrets live in ~/.config/am, never in the project.
import { readFileSync } from 'node:fs'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const CONFIG_DIR = process.env.AM_CONFIG_DIR ?? join(homedir(), '.config', 'am')
export const ENV_FILE = join(CONFIG_DIR, 'env')
export const DEV_TOKEN_CACHE = join(CONFIG_DIR, 'developer-token.jwt')
export const MUT_FILE = join(CONFIG_DIR, 'music-user-token')

// Fixed on purpose: MusicKit keeps the Music User Token in localStorage, which is scoped to
// scheme+host+port. A different port means a different origin and a fresh sign-in.
export const PORT = Number(process.env.AM_PORT ?? 47823)
export const ORIGIN = `http://localhost:${PORT}`

const expandHome = (p) => p.replace(/^~(?=$|\/)/, homedir())

// Reads ~/.config/am/env (KEY=VALUE lines). Real environment variables win.
export function loadEnv() {
  let text = ''
  try {
    text = readFileSync(ENV_FILE, 'utf8')
  } catch (err) {
    if (err.code !== 'ENOENT') throw err
  }
  const fileVars = {}
  for (const line of text.split('\n')) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/)
    if (m) fileVars[m[1]] = m[2].replace(/^(['"])(.*)\1$/, '$2')
  }
  const get = (k) => process.env[k] ?? fileVars[k]
  const teamId = get('TEAM_ID')
  const keyId = get('KEY_ID')
  const keyPath = expandHome(get('KEY_PATH') ?? join(CONFIG_DIR, `AuthKey_${keyId}.p8`))
  const path = (k) => get(k) && expandHome(get(k))
  return { teamId, keyId, keyPath, engine: get('ENGINE'), firefoxWidevine: get('FIREFOX_WIDEVINE'), chromePath: path('CHROME_PATH'), firefoxPath: path('FIREFOX_PATH') }
}
