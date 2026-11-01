// Launching a browser as the playback engine: it just opens our localhost page with a dedicated profile.
// Control happens over the page's SSE channel (server.mjs), so no automation protocol is attached.
import { spawn } from 'node:child_process'
import { existsSync, mkdirSync, readFileSync, readdirSync, readlinkSync, realpathSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { CONFIG_DIR, ORIGIN, loadEnv } from './config.mjs'

// Engine profile prefs (verified headless on firefox-esr 140, see research notes).
const FIREFOX_PREFS = {
  // Mozilla turns EME off on Linux; without it MusicKit silently falls back to 30 s previews.
  // Firefox then fetches the Widevine CDM itself on the first request (5-20 s, 60 s timeout).
  'media.eme.enabled': true,
  'media.gmp-widevinecdm.enabled': true, // already the Debian default
  'media.gmp-widevinecdm.visible': true,
  // Headless has no user gesture, so audible autoplay must be allowed or play() never starts.
  'media.autoplay.default': 0,
  'media.block-autoplay-until-in-foreground': false,
  // Fewer processes for a single trusted page: ~400-560 MiB instead of ~460-540+ MiB.
  'fission.autostart': false,
  'dom.ipc.processCount': 1,
  'dom.ipc.processPrelaunch.enabled': false,
  'extensions.enabledScopes': 5, // no system add-ons (e.g. KDE's, which claims a fixed MPRIS name)
  'browser.shell.checkDefaultBrowser': false,
  'browser.aboutwelcome.enabled': false,
  'browser.startup.homepage_override.mstone': 'ignore',
  'datareporting.policy.dataSubmissionEnabled': false,
  'toolkit.telemetry.reportingpolicy.firstRun': false,
  'browser.sessionstore.resume_from_crash': false,
  // Firefox counts every session shorter than ~30 s as a startup crash (we stop it with SIGTERM),
  // and after 3 of those it restarts itself in safe mode without our URL. Never do that.
  'toolkit.startup.max_resumed_crashes': -1,
}

// Mozilla currently serves Widevine 4.10.3050.0; Chrome bundles 4.10.3112.0. If Apple rejects the
// older CDM (WIDEVINE_CDM_EXPIRED), FIREFOX_WIDEVINE=google makes Firefox take Google's current
// version directly, a stock pref meant for early testing that skips Mozilla's hash check.
// Always written explicitly: user.js values persist in prefs.js after they're removed.
const firefoxPrefs = () => ({ ...FIREFOX_PREFS, 'media.gmp-widevinecdm.force-chromium-update': loadEnv().firefoxWidevine === 'google' })

const ENGINES = {
  chrome: {
    profile: join(CONFIG_DIR, 'chrome-profile'),
    binary: () => loadEnv().chromePath ?? '/opt/google/chrome/chrome',
    args: ({ profile, headless, url }) => [
      `--user-data-dir=${profile}`,
      '--no-first-run',
      '--no-default-browser-check',
      '--password-store=basic',
      '--autoplay-policy=no-user-gesture-required', // play() comes from the CLI, not a click
      ...(headless ? ['--headless'] : ['--new-window']),
      url,
    ],
  },
  firefox: {
    profile: join(CONFIG_DIR, 'firefox-profile'),
    binary: () => loadEnv().firefoxPath ?? '/usr/lib/firefox-esr/firefox-esr',
    prepare(profile) {
      const lines = Object.entries(firefoxPrefs()).map(([k, v]) => `user_pref(${JSON.stringify(k)}, ${JSON.stringify(v)});`)
      writeFileSync(join(profile, 'user.js'), lines.join('\n') + '\n')
    },
    // Firefox's remoting is keyed by profile path, so this never reaches the user's own Firefox.
    // (--no-remote is ignored by Firefox 140; --new-instance is the working equivalent.)
    args: ({ profile, headless, url }) => ['--new-instance', '--profile', profile, ...(headless ? ['--headless'] : []), url],
    env: { MOZ_CRASHREPORTER_DISABLE: '1', MOZ_DISABLE_AUTO_SAFE_MODE: '1' },
  },
}

export const ENGINE_NAMES = Object.keys(ENGINES)

const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

// kill(-pgid, 0) succeeds while any process of the group is alive.
function groupAlive(pgid) {
  try {
    process.kill(-pgid, 0)
    return true
  } catch (err) {
    return err.code === 'EPERM'
  }
}

async function killGroup(pgid) {
  for (const [signal, waitMs] of [['SIGTERM', 5000], ['SIGKILL', 2000]]) {
    try {
      process.kill(-pgid, signal)
    } catch {}
    for (let t = 0; t < waitMs && groupAlive(pgid); t += 100) await sleep(100)
    if (!groupAlive(pgid)) return
  }
}

const pgrpOf = (pid) => {
  const stat = readFileSync(`/proc/${pid}/stat`, 'utf8')
  return Number(stat.slice(stat.lastIndexOf(')') + 2).split(' ')[2])
}

// An engine from an earlier run that was killed without cleanup (terminal closed, OOM, kill -9)
// still holds the profile lock and may still be playing. It runs the engine binary with our
// profile on its command line, which the user's own browser never uses.
async function killLeftovers(binary, profile) {
  const exe = realpathSync(binary)
  const groups = new Set()
  for (const pid of readdirSync('/proc')) {
    if (!/^\d+$/.test(pid)) continue
    try {
      if (readlinkSync(`/proc/${pid}/exe`) !== exe) continue
      if (!readFileSync(`/proc/${pid}/cmdline`, 'utf8').split('\0').some((a) => a.includes(profile))) continue
      groups.add(pgrpOf(pid))
    } catch {}
  }
  groups.delete(pgrpOf('self'))
  for (const pgid of groups) {
    console.log(`killing a leftover engine from an earlier run (process group ${pgid})`)
    await killGroup(pgid)
  }
}

// Starts the browser on the engine page. Resolves once the process is spawned; the page connects on its own.
export async function launchEngine(name, { headless = false, path = '/' } = {}) {
  const engine = ENGINES[name]
  if (!engine) throw new Error(`unknown engine "${name}" (one of: ${ENGINE_NAMES.join(', ')})`)
  const binary = engine.binary()
  if (!existsSync(binary)) throw new Error(`${name} not found at ${binary}`)
  await killLeftovers(binary, engine.profile)
  mkdirSync(engine.profile, { recursive: true, mode: 0o700 })
  engine.prepare?.(engine.profile)
  const child = spawn(binary, engine.args({ profile: engine.profile, headless, url: ORIGIN + path }), {
    env: { ...process.env, ...engine.env },
    stdio: ['ignore', 'ignore', 'pipe'],
    detached: true, // own process group, so close() can take down every helper process
  })
  let stderr = ''
  child.stderr.on('data', (d) => (stderr = (stderr + d).slice(-4000)))
  const exited = new Promise((resolve) => child.once('exit', (code, signal) => resolve({ code, signal })))
  let closed = false
  return {
    pid: child.pid,
    exited,
    stderr: () => stderr,
    // Takes down the whole process group, even when the first process has already exited
    // (Firefox can fork and exit; its helpers would keep the profile and our stderr pipe).
    async close() {
      if (closed) return
      await killGroup(child.pid)
      child.stderr.destroy()
      closed = true
    },
    // Last resort for process 'exit' handlers, which can't wait.
    killNow() {
      if (closed) return
      try {
        process.kill(-child.pid, 'SIGKILL')
      } catch {}
    },
  }
}
