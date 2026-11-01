#!/usr/bin/env node
// POC driver: node poc/am.mjs <token|signin|doctor|search|play> [...]
import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { readFileSync } from 'node:fs'
import { constants } from 'node:os'
import { parseArgs } from 'node:util'
import { api, readUserToken, searchSongs } from './api.mjs'
import { MUT_FILE, ORIGIN, loadEnv } from './config.mjs'
import { ENGINE_NAMES, launchEngine } from './engines.mjs'
import { engineSinkInputs, measureTree } from './metrics.mjs'
import { startServer } from './server.mjs'
import { decodeJwt, getDeveloperToken } from './token.mjs'

const TEST_SONG = '1561837008' // 2:55, in the US catalog
const USAGE = `usage: node poc/am.mjs <command> [--engine ${ENGINE_NAMES.join('|')}] [--headless]
  token                     sign the developer token and test it against Apple
  signin [--engine E]       one-time Apple ID sign-in (default: your normal browser via xdg-open)
  doctor                    start the engine, report DRM/MusicKit/sign-in status
  search <term>             catalog search via the REST API (no browser)
  play [id|term] [--seconds N | --full]
                            play a track (default ${TEST_SONG}) and verify it's the full version`

const { values: opts, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    engine: { type: 'string' },
    headless: { type: 'boolean', default: false },
    full: { type: 'boolean', default: false },
    seconds: { type: 'string', default: '100' },
  },
})
const [command, ...rest] = positionals
const engineName = () => opts.engine ?? loadEnv().engine ?? 'firefox'

const fmt = (sec) => (sec == null || !isFinite(sec) ? '–:––' : `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`)
const sleep = (ms) => new Promise((r) => setTimeout(r, ms))
const check = (ok, label) => console.log(`${ok === null ? '?' : ok ? '✔' : '✘'} ${label}`)

function waitFor(server, predicate, ms, what) {
  return new Promise((resolve, reject) => {
    const last = server.lastReport()
    if (last && predicate(last)) return resolve(last)
    const settle = (fn, value) => (clearTimeout(timer), server.off('report', onReport), fn(value))
    const onReport = (r) => predicate(r) && settle(resolve, r)
    // unref: if something else wins a race against this wait, the timer must not keep the CLI alive.
    const timer = setTimeout(() => settle(reject, new Error(`timed out after ${ms / 1000}s waiting for ${what}`)), ms).unref()
    server.on('report', onReport)
  })
}

// The engine runs in its own process group (detached), so it never sees the terminal's signals.
// Tear it down on Ctrl-C, kill, and a closed terminal; returns a function that removes the handlers.
function onTerminate(shutdown, engineRef) {
  const signals = ['SIGINT', 'SIGTERM', 'SIGHUP']
  const handler = (signal) => shutdown().finally(() => process.exit(128 + constants.signals[signal]))
  const lastResort = () => engineRef()?.killNow()
  for (const signal of signals) process.once(signal, handler)
  process.once('exit', lastResort)
  return () => {
    for (const signal of signals) process.off(signal, handler)
    process.off('exit', lastResort)
  }
}

// The engine needs ~0.4-0.55 GB; launching it into memory pressure risks the OOM killer
// picking the user's own browser instead.
function checkMemory() {
  const kb = Number(readFileSync('/proc/meminfo', 'utf8').match(/^MemAvailable:\s+(\d+)/m)[1])
  if (kb < 700 * 1024) console.log(`warning: only ${Math.round(kb / 1024)} MiB RAM available; the engine needs ~400-550 MiB`)
}

// Starts server + engine browser, waits for MusicKit to configure, runs fn, and always tears down.
async function withEngine(fn) {
  const name = engineName()
  checkMemory()
  const server = await startServer()
  const nonce = randomBytes(6).toString('hex')
  server.setSession(nonce)
  let engine
  const shutdown = async () => {
    await engine?.close()
    await server.close()
  }
  const removeHandlers = onTerminate(shutdown, () => engine)
  try {
    engine = await launchEngine(name, { headless: opts.headless, path: `/?engine=${nonce}` })
    console.log(`engine: ${name}${opts.headless ? ' (headless)' : ''}, pid ${engine.pid}`)
    const crashed = engine.exited.then(({ code, signal }) => {
      throw new Error(`${name} exited early (code ${code}, signal ${signal}): ${engine.stderr().slice(-800)}`)
    })
    const ready = await Promise.race([waitFor(server, (r) => r.configured || r.configureError, 90_000, 'MusicKit to load'), crashed])
    if (!ready.configured) throw new Error(`MusicKit failed to configure: ${ready.configureError}`)
    return await fn({ server, engine, ready, name })
  } finally {
    await shutdown()
    removeHandlers()
  }
}

// MusicKit decides DRM support once, at configure(). If the CDM wasn't there yet (Firefox downloads
// Widevine on first start), wait for it and reload the page so MusicKit probes again.
async function ensureDrm(server, ready, { waitSec = 180 } = {}) {
  if (ready.browserSupportsVideoDrm) return ready
  // Firefox holds requestMediaKeySystemAccess open while it installs the CDM (up to 60 s).
  const probe = () => server.call('drmProbe', [], 90_000).catch((err) => ({ widevine: false, widevineError: err.message }))
  let result = await probe()
  for (let t = 0; !result.widevine && t < waitSec; t += 5) {
    if (t === 0) console.log(`Widevine not available yet (${result.widevineError}); waiting up to ${waitSec}s for the browser to install it…`)
    await sleep(5000)
    result = await probe()
  }
  if (!result.widevine) return ready
  console.log('Widevine is available now; reloading the engine page so MusicKit sees it.')
  // Reports from before the reload carry the same nonce; only a new page load counts.
  const before = server.lastReport().load
  await server.call('reload')
  return waitFor(server, (r) => r.load !== before && r.configured, 60_000, 'MusicKit to reconfigure')
}

async function userTokenStatus() {
  const token = readUserToken()
  if (!token) return { ok: false, status: 'missing' }
  const { status } = await api('/v1/me/storefront', { userToken: token })
  return { ok: status === 200, status }
}

async function cmdToken() {
  const token = getDeveloperToken()
  const { header, payload } = decodeJwt(token)
  console.log(`developer token: kid=${header.kid} iss=${payload.iss} expires ${new Date(payload.exp * 1000).toISOString()}`)
  // /v1/test is uncached; some catalog endpoints answer 200 from Apple's CDN cache even without a token.
  const { status, body } = await api('/v1/test', { userToken: null })
  check(status === 200, `Apple accepted the token (GET /v1/test → HTTP ${status})`)
  if (status !== 200) {
    console.log(JSON.stringify(body).slice(0, 500))
    process.exitCode = 1
  }
}

async function cmdSignin() {
  const server = await startServer()
  let engine
  let timer
  const shutdown = async () => {
    await engine?.close()
    await server.close()
  }
  const removeHandlers = onTerminate(shutdown, () => engine)
  try {
    const done = new Promise((resolve) =>
      server.on('signin', (r) => (r.ok ? resolve(r) : console.log(`✘ Apple rejected that token (HTTP ${r.status}); click the button again`))),
    )
    const races = [done, new Promise((_, reject) => (timer = setTimeout(() => reject(new Error('no successful sign-in within 10 minutes')), 600_000)))]
    const url = `${ORIGIN}/?signin`
    if (opts.engine) {
      engine = await launchEngine(opts.engine, { path: '/?signin' })
      races.push(engine.exited.then(() => Promise.reject(new Error('the engine window was closed before sign-in finished'))))
      console.log(`Opened ${url} in the ${opts.engine} engine profile.`)
    } else {
      spawn('xdg-open', [url], { stdio: 'ignore', detached: true }).unref()
      console.log(`Opened ${url} in your default browser.`)
    }
    console.log('Click "Sign in to Apple Music" and finish Apple\'s sign-in (waiting up to 10 min)…')
    const r = await Promise.race(races)
    console.log(`✔ signed in (storefront ${r.storefront}); Music User Token saved to ${MUT_FILE}`)
  } finally {
    clearTimeout(timer)
    await shutdown()
    removeHandlers()
  }
}

async function cmdDoctor() {
  await withEngine(async ({ server, ready }) => {
    console.log(`UA: ${ready.userAgent}  webdriver=${ready.webdriver}`)
    const probe = await server.call('drmProbe')
    check(!!probe.h264 && !!probe.aac, `codecs: H.264 "${probe.h264}", AAC "${probe.aac}", MSE AAC ${probe.mseAac}`)
    check(probe.widevine, `Widevine with MusicKit's exact EME config${probe.widevineError ? `: ${probe.widevineError}` : ''}`)
    const after = await ensureDrm(server, ready)
    check(after.browserSupportsVideoDrm, `MusicKit ${after.musicKitVersion} sees DRM support (browserSupportsVideoDrm)`)
    const mut = await userTokenStatus()
    check(mut.ok, `Music User Token valid (GET /v1/me/storefront → ${mut.status})${mut.ok ? '' : ': run `node poc/am.mjs signin`'}`)
    check(after.isAuthorized, `MusicKit authorized in the engine (storefront ${after.storefrontId})`)
    check(after.subscriptionActive, `Apple Music subscription active${after.meError ? `: ${after.meError}` : ''}`)
  })
}

async function cmdSearch() {
  const term = rest.join(' ')
  if (!term) throw new Error('search needs a term')
  for (const s of await searchSongs(term))
    console.log(`${s.id.padEnd(11)} ${fmt(s.durationSec)}  ${s.name} — ${s.artist} (${s.album}) [${s.storefront}]`)
}

async function cmdPlay() {
  const arg = rest.join(' ') || TEST_SONG
  let songId = arg
  if (!/^\d+$/.test(arg)) {
    const [hit] = await searchSongs(arg, { limit: 1 })
    if (!hit) throw new Error(`no song found for "${arg}"`)
    console.log(`search "${arg}" → ${hit.id}: ${hit.name} — ${hit.artist} (${fmt(hit.durationSec)})`)
    songId = hit.id
  }
  const mut = await userTokenStatus()
  if (!mut.ok) throw new Error(`Music User Token ${mut.status}: run \`node poc/am.mjs signin\` first`)
  const seconds = Number(opts.seconds)

  await withEngine(async ({ server, engine, ready: first }) => {
    const ready = await ensureDrm(server, first)
    if (!ready.browserSupportsVideoDrm) console.log('warning: MusicKit found no usable DRM; expect a 30 s preview')
    if (!ready.isAuthorized) throw new Error('MusicKit is not authorized in the engine page')
    if (ready.subscriptionActive === false) console.log(`warning: no active Apple Music subscription (${ready.meError ?? 'per /v1/me/account'}); expect a preview`)

    let engineGone = false
    engine.exited.then(() => (engineGone = true))
    await server.call('play', [songId], 60_000)
    let usage = null
    let audio = null
    let sampling = false
    let maxTime = 0
    let failure = null
    let s
    // MusicKit clears nowPlayingItem and the media element's src before it reports 'ended', so keep
    // the last values seen while the track was loaded.
    let np = null
    let media = null
    const started = Date.now()
    const tty = process.stdout.isTTY
    for (let tick = 0; ; tick++) {
      await sleep(1000)
      s = server.lastReport()
      maxTime = Math.max(maxTime, s.currentPlaybackTime ?? 0)
      if (s.nowPlaying) np = s.nowPlaying
      if (s.mediaElement?.blobSrc) media = s.mediaElement
      const line = `${String(s.playbackState).padEnd(9)} ${fmt(s.currentPlaybackTime)} / ${fmt(s.currentPlaybackDuration)}  ${np?.title ?? ''} — ${np?.artist ?? ''} [${np?.playbackType ?? '?'}]`
      if (tty) process.stdout.write(`\r${line}\x1b[K`)
      else if (tick % 10 === 0) console.log(line)
      if (!sampling && s.playbackState === 'playing' && s.currentPlaybackTime > 10) {
        // Sample while audio is flowing, without blocking the status loop.
        sampling = true
        measureTree(engine.pid).then((u) => (usage = u))
        engineSinkInputs(engine.pid).then((a) => (audio = a))
      }
      const elapsed = (Date.now() - started) / 1000
      if (engineGone) failure = 'the engine browser exited during playback'
      else if (Date.now() - server.lastReportAt() > 20_000) failure = 'the engine page stopped reporting for 20 s'
      else if (opts.full && np?.catalogDurationSec && elapsed > np.catalogDurationSec + 60) failure = 'playback took over a minute longer than the track'
      if (failure) break
      if (['ended', 'completed', 'stopped'].includes(s.playbackState)) break
      if (!opts.full && elapsed >= seconds) break
      if (elapsed > 30 && maxTime === 0) break // never started
    }
    if (tty) process.stdout.write('\n')
    if (!failure) await server.call('pause', [], 5000).catch(() => {})
    for (let i = 0; i < 40 && sampling && !usage && !failure; i++) await sleep(250)

    const full = np?.playbackType === 'encryptedFull'
    const notable = s.lastEvents.filter((e) => /error|drmUnsupported|authorization/i.test(e.type))
    console.log()
    if (failure) console.log(`✘ ${failure}`)
    if (!s.isAuthorized) console.log('✘ MusicKit lost its authorization during play (Apple rejected the Music User Token)')
    check(ready.browserSupportsVideoDrm, 'MusicKit sees DRM support')
    check(full, `playbackType = ${np?.playbackType} (encryptedFull = full track; preview = 30 s clip)`)
    check(!!(media?.blobSrc && media?.mediaKeys), `media element: MSE blob src ${media?.blobSrc ?? false}, MediaKeys attached ${media?.mediaKeys ?? false}`)
    check(maxTime > 95 || (maxTime > 31 ? null : false), `playback reached ${fmt(maxTime)} of ${fmt(np?.catalogDurationSec)} (previews stop at 0:30, sometimes 1:30)`)
    const streams = Array.isArray(audio) ? audio : []
    check(sampling ? streams.some((a) => !a.corked && !a.mute) : null, `engine audio stream in PipeWire: ${sampling ? JSON.stringify(audio) : 'not sampled (playback never reached 0:10)'}`)
    if (notable.length) console.log(`events: ${JSON.stringify(notable)}`)
    if (usage)
      console.log(
        `engine footprint: ${usage.processes} processes, ${usage.memoryMiB.toFixed(0)} MiB` +
          `${usage.rssOnlyProcesses ? ` (RSS for ${usage.rssOnlyProcesses} sandboxed processes, over-counts shared pages)` : ' PSS'}, ` +
          `CPU ${usage.cpuPercent.toFixed(1)}% of one core`,
      )
    if (failure || !(full && maxTime > 31)) process.exitCode = 1
  })
}

const COMMANDS = { token: cmdToken, signin: cmdSignin, doctor: cmdDoctor, search: cmdSearch, play: cmdPlay }
if (!COMMANDS[command]) {
  console.log(USAGE)
  process.exit(command ? 2 : 0)
}
try {
  await COMMANDS[command]()
} catch (err) {
  console.error(`error: ${err.message}`)
  process.exitCode = 1
}
