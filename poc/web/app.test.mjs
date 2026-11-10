// Tests for the engine page (app.js) against a fake MusicKit: bounded waits, stop and the
// cancel generation. Run with `npm run test:page` (or `zig build test`); APP_JS points them at
// another copy.
//
// Time is virtual: the page and the fakes get their timers and Date from a fake clock, which
// moves to the next timer only once nothing else can run. A test runs in milliseconds, whatever
// its waits, and a duration it measures is exact.
import { test as nodeTest } from 'node:test'
import { AsyncLocalStorage } from 'node:async_hooks'
import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const appPath = process.env.APP_JS ?? fileURLToPath(new URL('./app.js', import.meta.url))
const appSource = readFileSync(appPath, 'utf8')

// `zig build test` passes a file here. What runs is written to it before it starts, synchronously,
// so even a hang that blocks node leaves it there: the build names it when it stops node.
const progressPath = process.env.AM_PAGE_TEST_PROGRESS
const progress = (what) => progressPath && writeFileSync(progressPath, what)

const S = { none: 0, loading: 1, playing: 2, paused: 3, stopped: 4, ended: 5, seeking: 6, waiting: 8, stalled: 9, completed: 10 }
const never = () => new Promise(() => {})
const noop = () => {}
// MusicKit's buffered seek on paused media: the state goes to `seeking` and the seek never settles.
const stuckSeek = (_, m) => ((m.playbackState = S.seeking), never())

// The running test's {clock, unhandled}. Through the async context, not a variable: a test that
// node:test has already failed (an unhandled rejection does that at once) may still be running,
// and must keep to its own clock.
const running = new AsyncLocalStorage()
const clock = () => running.getStore().clock

// Unhandled rejections go to the test whose async context they come from.
process.on('unhandledRejection', (reason) => running.getStore()?.unhandled.push(reason))

// How far a clock may run: far past any bound of the page's (seconds), so a wait that never ends
// but keeps setting timers (an unbounded poll) fails at once instead of spinning forever. The
// steps (timers fired and flushes) bound what doesn't move time: a loop of zero-delay timers, or
// of `await flush()`.
const VIRTUAL_LIMIT_MS = 10 * 60 * 1000
const STEP_LIMIT = 20_000
// Where virtual time 0 is, as a date: what the page's Date says at the start of a test.
const EPOCH_MS = Date.UTC(2026, 0, 1)

// Timers that fire in virtual time. Between two timers, it waits one macrotask (setImmediate),
// so every promise chain the last one started has run: it only moves on when nothing else can.
// Past its limits it stops, and `overrun` rejects.
function fakeClock() {
  const timers = new Map() // id → {at, fn, args}, in the order they were set
  const flushers = []
  const idlers = []
  let now = 0
  let ids = 0
  let steps = 0
  let scheduled = false
  let disposed = false
  let overran
  const overrun = new Promise((_, reject) => (overran = reject))
  overrun.catch(() => {}) // observed by `withClock`; never an unhandled rejection
  const schedule = () => {
    if (scheduled || disposed) return
    scheduled = true
    setImmediate(step)
  }
  const stop = (why) => {
    disposed = true
    timers.clear()
    overran(new Error(why))
  }
  const secsAt = (ms) => `${(ms / 1000).toFixed(3)} s`
  function step() {
    scheduled = false
    if (disposed) return
    try {
      if (flushers.length) {
        if (++steps > STEP_LIMIT) return stop(`the test clock stopped: its step limit (${STEP_LIMIT} timers and flushes) was passed by a flush at ${secsAt(now)} of virtual time`)
        for (const resolve of flushers.splice(0)) resolve()
        return
      }
      let next = null
      for (const [id, t] of timers) if (!next || t.at < next.at) next = { id, ...t }
      if (!next) {
        for (const resolve of idlers.splice(0)) resolve()
        return
      }
      if (next.at > VIRTUAL_LIMIT_MS) return stop(`the test clock stopped: its next timer, due at ${secsAt(next.at)} (set for ${secsAt(next.at - next.setAt)} at ${secsAt(next.setAt)}), is past its limit of ${VIRTUAL_LIMIT_MS / 1000} s of virtual time`)
      if (++steps > STEP_LIMIT) return stop(`the test clock stopped: its step limit (${STEP_LIMIT} timers and flushes) was passed by a timer due at ${secsAt(next.at)} (set for ${secsAt(next.at - next.setAt)})`)
      timers.delete(next.id)
      now = next.at
      // A callback that throws fails the test with its error (node:test sees it as uncaught);
      // the clock goes on.
      next.fn(...next.args)
    } finally {
      if (timers.size || flushers.length || idlers.length) schedule()
    }
  }
  return {
    overrun,
    get now() {
      return now
    },
    // A timer is set or a step is due: time can still bring something.
    get busy() {
      return scheduled || timers.size > 0 || flushers.length > 0 || idlers.length > 0
    },
    setTimeout(fn, ms, ...args) {
      const id = ++ids
      timers.set(id, { at: now + Math.max(0, Number(ms) || 0), setAt: now, fn, args })
      schedule()
      return id
    },
    clearTimeout: (id) => timers.delete(id),
    // Once everything that can run without time passing has run.
    flush: () => new Promise((resolve) => (flushers.push(resolve), schedule())),
    // Once no timer is left: everything the test started has played out.
    idle: () => new Promise((resolve) => (idlers.push(resolve), schedule())),
    dispose() {
      disposed = true
      timers.clear()
    },
  }
}

// A Date whose now is `own`'s: Date.now() and new Date() move with virtual time.
function clockDate(own) {
  return class extends Date {
    constructor(...args) {
      if (args.length) super(...args)
      else super(EPOCH_MS + own.now)
    }
    static now() {
      return EPOCH_MS + own.now
    }
  }
}

const sleep = (ms) => new Promise((resolve) => clock().setTimeout(resolve, ms))
const flush = () => clock().flush()
const idle = () => clock().idle()

// Rejects once the test can't go on: it still waits, and two macrotasks in a row passed with no
// timer set. Nothing else here is asynchronous, so whatever it waits on never comes (a page call
// whose wait isn't bounded, say). Without this, node:test would wait for it forever.
function stalled(own, going) {
  return new Promise((_, reject) => {
    let quiet = 0
    const look = () => {
      if (!going()) return
      quiet = own.busy ? 0 : quiet + 1
      if (quiet >= 2) return reject(new Error('stalled: the test waits on something that never happens, and no timer is left'))
      setImmediate(look)
    }
    setImmediate(look)
  })
}

// Runs `fn` on a fresh clock, failing if it stalls or its clock overruns. Once `fn` is done, the
// clock runs on until no timer is left (within the same limits), so what the page still does
// late runs too, and its rejections count. Nothing it started runs on into the next test.
// Returns the unhandled rejections that came from it.
async function withClock(fn) {
  const own = fakeClock()
  const store = { clock: own, unhandled: [] }
  let going = true
  const failed = Promise.race([own.overrun, stalled(own, () => going)])
  try {
    await running.run(store, async () => {
      await Promise.race([(async () => fn())(), failed])
      await Promise.race([own.idle(), failed])
      // Rejections are reported once the microtasks run out: give the last ones a chance.
      await new Promise((resolve) => setImmediate(resolve))
    })
  } finally {
    going = false
    own.dispose()
  }
  return store.unhandled
}

// node:test's test, on its own clock, and failing if an unhandled rejection came from it.
// (node:test fails a test for one too, but only while the test runs: one that lands after it
// ended is only a diagnostic.)
function test(name, fn) {
  nodeTest(name, async (t) => {
    progress(`in the test "${name}"`)
    const unhandled = await withClock(() => fn(t))
    progress(`after the test "${name}"`)
    assert.deepEqual(unhandled.map(String), [], 'unhandled rejections')
  })
}

function page(music) {
  const { am, configure } = coldPage(music)
  configure()
  return am
}

// A page whose MusicKit isn't configured yet: `configure` makes it ready, `half` sets `music`
// only (configure() between MusicKit.configure and the account check). `listeners` holds what
// the page registered with window.addEventListener. `browser` replaces parts of the page's
// window (its location, document, fetch, ...).
function coldPage(music, browser = {}) {
  const own = clock()
  const listeners = []
  const ctx = {
    location: { search: '?engine=n0nce', reload: noop, replace: noop },
    URLSearchParams,
    URL,
    document: { getElementById: () => null, addEventListener: noop, body: { classList: { add: noop } } },
    navigator: { userAgent: 'test', webdriver: false },
    atob,
    // Web Crypto's digest runs off the thread, which the fake clock would take for a stall.
    crypto: { subtle: { digest: async (_, data) => Uint8Array.from(createHash('sha256').update(data).digest()).buffer } },
    TextEncoder,
    fetch: () => new Promise(() => {}),
    setTimeout: (...args) => own.setTimeout(...args),
    clearTimeout: (id) => own.clearTimeout(id),
    Date: clockDate(own),
    setInterval: noop,
    console,
    MusicKit: { PlaybackStates: S, PlaybackType: {}, PlayerShuffleMode: { off: 0, songs: 1 }, PlayerRepeatMode: { none: 0, one: 1, all: 2 } },
    ...browser,
  }
  ctx.window = ctx
  ctx.addEventListener = (type, fn) => listeners.push({ type, fn })
  vm.createContext(ctx)
  vm.runInContext(appSource, ctx)
  ctx.__music = music
  return {
    am: ctx.am,
    ctx,
    listeners,
    half: () => vm.runInContext('music = __music', ctx),
    configure: () => vm.runInContext('music = __music; ready = true', ctx),
  }
}

// What app.js waits at most, read from it: SETTLE_MS and START_MS (its constants), UNTIL_MS
// (until()'s default bound, measured).
async function pageBounds() {
  progress('reading the page bounds, before the first test')
  let bounds
  await withClock(async () => {
    const { ctx } = coldPage(null)
    const { SETTLE_MS, START_MS } = vm.runInContext('({ SETTLE_MS, START_MS })', ctx)
    const { ms: UNTIL_MS } = await timed(() => ctx.until(() => false))
    bounds = { SETTLE_MS, START_MS, UNTIL_MS }
  })
  for (const [name, ms] of Object.entries(bounds)) assert.ok(Number.isInteger(ms) && ms > 0, `${name} = ${ms}`)
  return bounds
}

// The fake MusicKit. `calls` lists the calls the page made, as `call` records them; `reached`
// resolves once a call (or a `signal`) of that label has happened, so a test can act while the
// page waits in it. `seek` gets the time and the fake.
function fakeMusic({ state, pause, seek, stop, live = false }) {
  const seen = new Set()
  const waiters = []
  const m = {
    playbackState: state,
    get isPlaying() {
      return m.playbackState === S.playing
    },
    currentPlaybackTime: 12,
    nowPlayingItem: { id: '1', title: 'Little Wing', isLiveRadioStation: live },
    calls: [],
    signal(label) {
      seen.add(label)
      for (const w of waiters.filter((w) => w.label === label)) {
        waiters.splice(waiters.indexOf(w), 1)
        w.resolve()
      }
    },
    call(label) {
      m.calls.push(label)
      m.signal(label)
    },
    // Forgets the calls so far, for `calls` and `reached` both.
    reset() {
      m.calls.length = 0
      seen.clear()
    },
    reached: (label) => (seen.has(label) ? Promise.resolve() : new Promise((resolve) => waiters.push({ label, resolve }))),
    pause() {
      m.call('pause')
      return pause()
    },
    seekToTime(t) {
      m.call(`seek ${t}`)
      return seek(t, m)
    },
    stop() {
      m.call('stop')
      return stop()
    },
  }
  return m
}

// How long `fn` took, in virtual time.
async function timed(fn) {
  const t0 = clock().now
  const value = await fn()
  return { value, ms: clock().now - t0 }
}

// A value from the page's realm as plain JSON: its arrays have that realm's prototype, which
// deepStrictEqual tells apart from this one's.
const plain = (value) => JSON.parse(JSON.stringify(value))

// A bound as the page words it in a give-up.
const secs = (ms) => `${ms / 1000} s`

const { SETTLE_MS, START_MS, UNTIL_MS } = await pageBounds()

test('stop on a paused song whose seek never settles answers in about 2 s, paused where it was', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: never })
  const { value, ms } = await timed(() => page(m).stop())
  assert.deepEqual(m.calls, ['seek 0'])
  assert.equal(ms, SETTLE_MS)
  assert.deepEqual(plain(value.gaveUp), [`seekToTime(0) after ${secs(SETTLE_MS)}`])
  assert.equal(value.currentPlaybackTime, 12)
  assert.equal(value.lastEvents.at(-1).type, 'gaveUp')
})

test('stop while playing whose pause never settles fails in about 3 s with the reason, without seeking', async () => {
  const m = fakeMusic({ state: S.playing, pause: never, seek: never })
  const { ms } = await timed(() => assert.rejects(page(m).stop(), { message: `gave up waiting on pause() after ${secs(SETTLE_MS)}; MusicKit still plays` }))
  // The pause's bound, then the wait for the music to go quiet.
  assert.equal(ms, SETTLE_MS + UNTIL_MS)
  assert.deepEqual(m.calls, ['pause'])
})

test('pause whose pause() never settles while MusicKit plays fails with the reason', async () => {
  const m = fakeMusic({ state: S.playing, pause: never, seek: never })
  await assert.rejects(page(m).pause(), { message: `gave up waiting on pause() after ${secs(SETTLE_MS)}; MusicKit still plays` })
})

test('a stop whose pause settles but leaves MusicKit playing fails', async () => {
  const m = fakeMusic({ state: S.playing, pause: async () => {}, seek: never })
  await assert.rejects(page(m).stop(), { message: 'MusicKit still plays after pause()' })
  assert.deepEqual(m.calls, ['pause'])
})

test('a stop during loading whose pause gives up succeeds: nothing plays yet, and it seeks', async () => {
  const m = fakeMusic({
    state: S.loading,
    pause: () => sleep(SETTLE_MS + 300).then(() => (m.playbackState = S.paused)),
    seek: async (t) => (m.currentPlaybackTime = t),
  })
  const { value } = await timed(() => page(m).stop())
  assert.deepEqual(plain(value.gaveUp), [`pause() after ${secs(SETTLE_MS)}`])
  assert.equal(value.currentPlaybackTime, 0)
})

test('resume of stopped live radio whose setQueue never settles answers in about 6 s', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: async () => (m.playbackState = S.stopped) })
  const am = page(m)
  await am.stop()
  m.setQueue = () => (m.call('setQueue'), never())
  m.play = () => (m.call('play'), Promise.resolve())
  const { value, ms } = await timed(() => am.resume())
  // The restart's bound, then the wait for the music to start.
  assert.equal(ms, START_MS + UNTIL_MS)
  assert.deepEqual(m.calls, ['stop', 'setQueue'])
  assert.deepEqual(plain(value.gaveUp), [`setQueue({station}) and play() after ${secs(START_MS)}`])
})

test('playLater on an empty queue whose play() never settles answers in about 5 s', async () => {
  const m = fakeMusic({ state: S.none, pause: never, seek: never })
  m.setQueue = async () => {}
  m.play = () => (m.call('play'), never())
  const { value, ms } = await timed(() => page(m).playLater({ songs: ['1'] }))
  assert.equal(ms, START_MS)
  assert.deepEqual(plain(value.gaveUp), [`play() after ${secs(START_MS)}`])
})

test('a stop whose steps settle answers at once with a plain snapshot at 0:00', async () => {
  const m = fakeMusic({
    state: S.playing,
    pause: async () => (m.playbackState = S.paused),
    seek: async (t) => (m.currentPlaybackTime = t),
  })
  const { value, ms } = await timed(() => page(m).stop())
  assert.equal(ms, 0)
  assert.equal(value.gaveUp, undefined)
  assert.equal(value.currentPlaybackTime, 0)
  assert.equal(value.playbackState, 'paused')
})

test('live radio still stops with stop(), bounded: a stop() that never settles while it plays fails', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: never })
  await assert.rejects(page(m).stop(), { message: `gave up waiting on stop() after ${secs(SETTLE_MS)}; MusicKit still plays` })
  assert.deepEqual(m.calls, ['stop'])
})

test('live radio whose stop() never settles but goes silent answers, with the give-up', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: () => ((m.playbackState = S.stopped), never()) })
  const { value } = await timed(() => page(m).stop())
  assert.deepEqual(m.calls, ['stop'])
  assert.deepEqual(plain(value.gaveUp), [`stop() after ${secs(SETTLE_MS)}`])
})

test('a pause that rejects still fails the call', async () => {
  const m = fakeMusic({ state: S.playing, pause: async () => Promise.reject(new Error('boom')), seek: never })
  await assert.rejects(page(m).pause(), /boom/)
})

test('next on the last item goes through the bounded stop', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: never })
  m.capabilities = { canSkipToNextItem: true }
  m.queue = { nextPlayableItemIndex: -1 }
  m.repeatMode = 0
  const { value } = await timed(() => page(m).next())
  assert.deepEqual(plain(value.gaveUp), [`seekToTime(0) after ${secs(SETTLE_MS)}`])
})

test('a stop while setQueue loads cancels the queue: it never plays, and playQueue says why', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: never })
  m.nowPlayingItem = null
  m.setQueue = () => (m.call('setQueue'), sleep(300))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  const am = page(m)
  const queued = am.playQueue({ songs: ['1'] }, 0)
  await m.reached('setQueue')
  assert.equal(am.snapshot().loadPending, true)
  const stopped = await am.stop(1)
  assert.equal(stopped.gaveUp, undefined)
  assert.equal(stopped.cancelled, 1)
  await assert.rejects(queued, { message: 'stopped before it started' })
  assert.deepEqual(m.calls, ['setQueue'])
  assert.equal(m.isPlaying, false)
  assert.equal(am.snapshot().loadPending, false)
})

test('a stop while play() is pending pauses it once it starts, and playQueue says why', async () => {
  const m = fakeMusic({ state: S.none, pause: null, seek: async () => {} })
  m.nowPlayingItem = null
  let started
  const pendingPlay = new Promise((r) => (started = r))
  m.setQueue = async () => {
    m.nowPlayingItem = { id: '1', title: 'x' }
    m.playbackState = S.loading
  }
  m.play = () => (m.call('play'), pendingPlay)
  // MusicKit's pause() waits for the pending play(), then pauses.
  m.pause = () => (m.call('pause'), pendingPlay.then(() => (m.playbackState = S.paused)))
  const am = page(m)
  const queued = am.playQueue({ songs: ['1'] }, 0)
  await m.reached('play')
  const stopping = am.stop(1)
  await m.reached('pause')
  m.playbackState = S.playing
  started()
  const stopped = await stopping
  assert.equal(stopped.playbackState, 'paused')
  await assert.rejects(queued, { message: 'stopped before it started' })
  assert.deepEqual(m.calls, ['play', 'pause', 'seek 0'])
})

test('am play <song> is cancelled the same way, and a load after the stop plays', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: never })
  m.nowPlayingItem = null
  m.setQueue = (o) => (m.call(`setQueue ${o.song}`), sleep(200))
  m.play = () => (m.call('play'), Promise.resolve())
  const am = page(m)
  const first = am.play('1', 0)
  await m.reached('setQueue 1')
  await am.stop(1)
  await assert.rejects(first, { message: 'stopped before it started' })
  await am.play('2', 1)
  assert.deepEqual(m.calls, ['setQueue 1', 'setQueue 2', 'play'])
})

test('a stop after the bound of a slow live-radio restart still cancels it, and its late cancel is handled and not noted as a failure', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: async () => (m.playbackState = S.stopped) })
  const am = page(m)
  await am.stop()
  m.nowPlayingItem = null
  // Past the resume's bound, and ends while the stop waits for it.
  m.setQueue = () => (m.call('setQueue'), sleep(START_MS + UNTIL_MS + SETTLE_MS / 2))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  const resumed = await am.resume(0)
  assert.deepEqual(plain(resumed.gaveUp), [`setQueue({station}) and play() after ${secs(START_MS)}`])
  assert.equal(am.snapshot().loadPending, true)
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 1)
  await idle()
  assert.deepEqual(m.calls, ['stop', 'setQueue'])
  assert.equal(am.snapshot().loadPending, false)
  assert.ok(!am.snapshot().lastEvents.some((e) => e.type === 'restartFailed'))
  // Nor an unhandled rejection: `test` fails any test that leaves one.
})

test('a stop that fails (the music still plays) doesn\'t cancel the load in flight', async () => {
  const m = fakeMusic({ state: S.playing, pause: never, seek: async () => {} })
  m.setQueue = () => (m.call('setQueue'), sleep(300))
  m.play = () => (m.call('play'), Promise.resolve())
  const am = page(m)
  const queued = am.playQueue({ songs: ['1'] }, 0)
  await m.reached('setQueue')
  await assert.rejects(am.stop(1), { message: `gave up waiting on pause() after ${secs(SETTLE_MS)}; MusicKit still plays` })
  await queued
  assert.deepEqual(m.calls, ['setQueue', 'pause', 'play'])
})

test('a stop during playLater\'s API read on an empty queue cancels it before setQueue', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: never })
  m.nowPlayingItem = null
  m.api = { music: () => (m.signal('api read'), sleep(300).then(() => ({ data: { data: [{ id: '1', type: 'songs', attributes: { playParams: { kind: 'song' } } }] } }))) }
  m.setQueue = () => (m.call('setQueue'), Promise.resolve())
  m.play = () => (m.call('play'), Promise.resolve())
  const am = page(m)
  const later = am.playLater({ container: { type: 'albums', id: 'a1' } }, 0)
  await m.reached('api read')
  // The read decides nothing yet (the daemon counts the call as on its way).
  await am.stop(1)
  await assert.rejects(later, { message: 'stopped before it started' })
  assert.deepEqual(m.calls, [])
})

// Round 2 of review findings.

test('a live-radio restart cancelled at its very start keeps the station for the next resume', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: async () => (m.playbackState = S.stopped) })
  const am = page(m)
  await am.stop()
  m.nowPlayingItem = null
  m.reset()
  m.setQueue = () => (m.call('setQueue'), Promise.resolve())
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  // The stop reached the page before the Space that came first.
  await am.stop(1)
  await assert.rejects(am.resume(0), { message: 'stopped before it started' })
  assert.deepEqual(m.calls, [])
  await am.resume(1)
  assert.deepEqual(m.calls, ['setQueue', 'play'])
})

test('two quick play-laters on an empty queue start one queue and add the second to it', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: async () => {} })
  m.nowPlayingItem = null
  m.queue = { length: 0, items: [], position: -1, queueItem: () => null, indexForItem: () => -1 }
  m.setQueue = (o) => (m.call(`setQueue ${o.songs}`), sleep(200).then(() => (m.queue.length = o.songs.length)))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  m.playLater = (o) => (m.call(`playLater ${o.songs}`), Promise.resolve())
  const am = page(m)
  await Promise.all([am.playLater({ songs: ['1'] }, 0), am.playLater({ songs: ['2'] }, 0)])
  assert.deepEqual(m.calls, ['setQueue 1', 'play', 'playLater 2'])
})

// Play-next/later on an empty queue (#16).

// A fake with a queue: setQueue fills it, playLater/playNext add to it.
function queueMusic() {
  const m = fakeMusic({ state: S.none, pause: async () => (m.playbackState = m.playbackState === S.playing ? S.paused : m.playbackState), seek: async () => {} })
  m.nowPlayingItem = null
  m.queue = { length: 0, items: [], position: -1, queueItem: () => null, indexForItem: () => -1 }
  const ids = (o) => o.songs ?? o.items.map((t) => t.id)
  m.setQueue = (o) => (m.call(`setQueue ${ids(o)}`), sleep(50).then(() => (m.queue.length = ids(o).length)))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  m.playLater = (o) => (m.call(`playLater ${ids(o)}`), Promise.resolve().then(() => (m.queue.length += ids(o).length)))
  return m
}

const song = (id) => ({ id, type: 'songs', attributes: { playParams: { kind: 'song' } } })
const video = (id) => ({ id, type: 'music-videos', attributes: { playParams: { kind: 'musicVideo' } } })

// Apple's API: `pages` of tracks per container id, each page answered after `ms`. `m.pages`
// lists the pages asked for.
function fakeApi(m, containers, ms = 300) {
  m.pages = []
  m.api = {
    music(path, query) {
      const id = Object.keys(containers).find((c) => path.includes(`/${c}/`))
      const page = Number(query.offset ?? 0) / 100
      m.pages.push(`${id} ${page}`)
      m.signal(`api ${id} ${page}`)
      const pages = containers[id]
      const next = page + 1 < pages.length ? `${path}?offset=${(page + 1) * 100}` : undefined
      return sleep(ms).then(() => ({ data: { data: pages[page], next } }))
    },
  }
}

for (const { how, cancelled } of [
  { how: 'ends without playable tracks', cancelled: false },
  { how: 'is cancelled by a stop the play-laters came after', cancelled: true },
]) {
  test(`two play-laters during a load that ${how} start one queue and add the second to it`, async () => {
    const m = queueMusic()
    fakeApi(m, { a1: [[video('v1')]] })
    const am = page(m)
    const queued = am.playQueue({ container: { type: 'albums', id: 'a1' } }, 0)
    await m.reached('api a1 0')
    let gen = 0
    let stopping = null
    if (cancelled) {
      // The stop's seek takes a while: the play-laters reach the page while it runs, so they
      // have its generation and find the load not cancelled yet.
      m.nowPlayingItem = { id: '0', title: 'paused' }
      m.seekToTime = (t) => (m.call(`seek ${t}`), sleep(100))
      stopping = am.stop(1)
      await m.reached('seek 0')
      m.reset()
      gen = 1
    }
    const later = [am.playLater({ songs: ['1'] }, gen), am.playLater({ songs: ['2'] }, gen)]
    if (cancelled) assert.equal((await stopping).cancelled, 1)
    await assert.rejects(queued, cancelled ? { message: 'stopped before it started' } : /no playable tracks/)
    await Promise.all(later)
    assert.deepEqual(m.calls, ['setQueue 1', 'play', 'playLater 2'])
    assert.equal(m.queue.length, 2)
  })
}

const pagesOf = (prefix, n) => Array.from({ length: n }, (_, p) => Array.from({ length: 100 }, (_, i) => song(`${prefix}${p * 100 + i}`)))

test('a stop during play-later\'s multi-page read on an empty queue cancels it at the next page, and counts it', async () => {
  const m = queueMusic()
  fakeApi(m, { p1: pagesOf('s', 3) })
  const am = page(m)
  const later = am.playLater({ container: { type: 'playlists', id: 'p1' } }, 0)
  await m.reached('api p1 0')
  assert.equal(am.snapshot().loadPending, true)
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 1)
  await assert.rejects(later, { message: 'stopped before it started' })
  assert.deepEqual(m.pages, ['p1 0'])
  assert.deepEqual(m.calls, [])
  assert.equal(am.snapshot().loadPending, false)
})

test('a play-later a stop cancelled stays cancelled when a cancelled load\'s late setQueue fills the queue', async () => {
  const m = queueMusic()
  m.setQueue = (o) => (m.call(`setQueue ${o.songs}`), sleep(500).then(() => (m.queue.length = o.songs.length)))
  fakeApi(m, { p1: pagesOf('s', 2) }, 600)
  const am = page(m)
  // Both end while the stop waits for them: their outcomes are taken at once.
  const queued = assert.rejects(am.playQueue({ songs: ['1'] }, 0), { message: 'stopped before it started' })
  await m.reached('setQueue 1')
  const later = assert.rejects(am.playLater({ container: { type: 'playlists', id: 'p1' } }, 0), { message: 'stopped before it started' })
  await m.reached('api p1 0')
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 2)
  assert.equal(stopped.gaveUp, undefined)
  await queued
  await later
  assert.equal(m.queue.length, 1)
  assert.deepEqual(m.pages, ['p1 0'])
  assert.deepEqual(m.calls, ['setQueue 1'])
})

test('a play-later that only adds, during a stopped live-radio restart, leaves the station for the next resume', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: async () => (m.playbackState = S.stopped) })
  m.queue = { length: 1 }
  const am = page(m)
  await am.stop()
  m.nowPlayingItem = null
  m.reset()
  m.setQueue = () => (m.call('setQueue'), sleep(300))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  m.playLater = (o) => (m.call(`playLater ${o.songs}`), Promise.resolve())
  const resumed = am.resume(0)
  await m.reached('setQueue')
  const later = am.playLater({ songs: ['9'] }, 0)
  assert.equal((await am.stop(1)).cancelled, 1)
  await assert.rejects(resumed, { message: 'stopped before it started' })
  await later
  assert.deepEqual(m.calls, ['setQueue', 'playLater 9'])
  m.reset()
  await am.resume(1)
  assert.deepEqual(m.calls, ['setQueue', 'play'])
})

test('a stop during play-later\'s slow read on a queue that has music leaves it alone: the add happens', async () => {
  const m = queueMusic()
  m.queue.length = 3
  m.playbackState = S.playing
  m.nowPlayingItem = { id: '0', title: 'playing' }
  fakeApi(m, { p1: pagesOf('s', 2) })
  const am = page(m)
  const later = am.playLater({ container: { type: 'playlists', id: 'p1' } }, 0)
  await m.reached('api p1 0')
  assert.equal(am.snapshot().loadPending, false)
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 0)
  assert.equal(am.snapshot().loadPending, false)
  await m.reached('api p1 1')
  assert.equal(am.snapshot().loadPending, false)
  await later
  assert.deepEqual(m.pages, ['p1 0', 'p1 1'])
  assert.deepEqual(m.calls.slice(-1), [`playLater ${pagesOf('s', 2).flat().map((t) => t.id)}`])
  assert.equal(m.queue.length, 203)
})

test('a plain resume or toggle carries its generation: a stop that reached the page first keeps it silent', async () => {
  const m = fakeMusic({ state: S.paused, pause: async () => (m.playbackState = S.paused), seek: async () => {} })
  m.queue = { length: 1 }
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  const am = page(m)
  await am.stop(1)
  await assert.rejects(am.toggle(0), { message: 'stopped before it started' })
  await assert.rejects(am.play(null, 0), { message: 'stopped before it started' })
  assert.equal(m.isPlaying, false)
  await am.toggle(1)
  assert.equal(m.isPlaying, true)
  assert.deepEqual(m.calls, ['seek 0', 'play'])
})

test('a stop while a plain resume\'s play() is pending pauses it once it starts', async () => {
  const m = fakeMusic({ state: S.paused, pause: async () => (m.playbackState = m.playbackState === S.playing ? S.paused : m.playbackState), seek: async () => {} })
  m.play = () => (m.call('play'), (m.playbackState = S.loading), sleep(300).then(() => (m.playbackState = S.playing)))
  const am = page(m)
  const resumed = am.resume(0)
  await m.reached('play')
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 1)
  await assert.rejects(resumed, { message: 'stopped before it started' })
  // The play() lands after the stop.
  await idle()
  assert.equal(m.isPlaying, false)
})

test('a cancelled load whose play() starts late leaves a newer load under way alone', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => (m.playbackState = m.playbackState === S.playing ? S.paused : m.playbackState), seek: async () => {} })
  m.nowPlayingItem = null
  let startFirst
  const firstPlay = new Promise((r) => (startFirst = r))
  m.setQueue = (o) => (m.call(`setQueue ${o.song}`), (m.queued = o.song), sleep(o.song === '2' ? 400 : 0))
  // The first song's play() stays pending until the test starts it; any other starts at once.
  m.play = () => (m.call('play'), m.queued === '1' ? firstPlay : ((m.playbackState = S.playing), Promise.resolve()))
  const am = page(m)
  const first = am.play('1', 0)
  await m.reached('play')
  await am.stop(1)
  await assert.rejects(first, { message: 'stopped before it started' })
  const second = am.play('2', 1)
  await m.reached('setQueue 2')
  const before = m.calls.length
  // The first song's play() lands while the second loads: not the first one's to silence now.
  startFirst((m.playbackState = S.playing))
  await flush()
  assert.deepEqual(m.calls.slice(before), [])
  await second
  assert.deepEqual(m.calls.slice(before), ['play'])
})

// A cancelled load's play() that starts the music late, while a newer load reads (#17).

// Load A (`playA`, generation 0) sends play(), which stays pending until the test calls the
// `startA` this returns; a stop (generation 1) cancels A meanwhile. The fake's later play()
// calls start at once. Forgets the calls so far.
async function cancelledWithPendingPlay(m, am, playA, started = () => (m.playbackState = S.playing)) {
  let startA
  const play = m.play
  m.play = () => {
    m.play = play
    m.call('play')
    return new Promise((resolve) => (startA = () => (started(), resolve())))
  }
  const a = playA(am)
  await m.reached('play')
  assert.equal((await am.stop(1)).cancelled, 1)
  await assert.rejects(a, { message: 'stopped before it started' })
  m.reset()
  return startA
}

const playSong1 = (am) => am.playQueue({ songs: ['1'] }, 0)
const playAlbum = (am) => am.playQueue({ container: { type: 'albums', id: 'a1' } }, 1)

// Load B plays album a1 (generation 1); while it reads the album from Apple, A's music starts.
// Returns B's outcome.
async function albumWithLateStart(m, am, startA) {
  const b = playAlbum(am)
  await m.reached('api a1 0')
  startA()
  return b
}

const radio = { id: 'ra.1', title: 'Radio', isLiveRadioStation: true }

// A queueMusic that plays live radio ra.1. Its stop() drops the item, as MusicKit's does, and a
// station queue takes `ms` to load.
function radioMusic(ms = 0) {
  const m = queueMusic()
  m.nowPlayingItem = radio
  m.playbackState = S.playing
  m.stop = () => (m.call('stop'), (m.playbackState = S.stopped), (m.nowPlayingItem = null), Promise.resolve())
  const setQueue = m.setQueue
  m.setQueue = (o) => (o.station ? (m.call(`setQueue ${o.station}`), sleep(ms)) : setQueue(o))
  m.setStationQueue = (o) => (m.call(`setStationQueue ${o.song ?? o.artist}`), sleep(ms))
  return m
}

// Space on stopped live radio restarts it. MusicKit names the station once its stream plays.
const restartRadio = (am) => am.resume(0)
const radioStarts = (m) => () => ((m.nowPlayingItem = radio), (m.playbackState = S.playing))

for (const [what, playA] of [
  ['a queue', playSong1],
  ['a play-later on an empty queue', (am) => am.playLater({ songs: ['1'] }, 0)],
]) {
  test(`a cancelled load (${what}) whose play() starts during a newer load's API read is paused before that load's setQueue`, async () => {
    const m = queueMusic()
    fakeApi(m, { a1: [[song('s1'), song('s2')]] })
    const am = page(m)
    const b = albumWithLateStart(m, am, await cancelledWithPendingPlay(m, am, playA))
    await flush()
    assert.deepEqual(m.calls, ['pause'])
    assert.equal(m.isPlaying, false)
    await b
    assert.deepEqual(m.calls, ['pause', 'setQueue s1,s2', 'play'])
    assert.equal(m.isPlaying, true)
  })
}

for (const { how, tracks, refuse, error, calls } of [
  { how: 'finds no playable tracks', tracks: [video('v1')], refuse: false, error: 'no playable tracks in albums a1', calls: ['pause'] },
  { how: 'has its setQueue rejected', tracks: [song('s1')], refuse: true, error: 'MusicKit refused the queue', calls: ['pause', 'setQueue'] },
]) {
  test(`a newer load that ${how} fails with that, leaving silent what a cancelled load's late play() started`, async () => {
    const m = queueMusic()
    fakeApi(m, { a1: [tracks] })
    const am = page(m)
    const startA = await cancelledWithPendingPlay(m, am, playSong1)
    if (refuse) m.setQueue = () => (m.call('setQueue'), Promise.reject(new Error('MusicKit refused the queue')))
    await assert.rejects(albumWithLateStart(m, am, startA), { message: error })
    await idle()
    assert.deepEqual(m.calls, calls)
    assert.equal(m.isPlaying, false)
  })
}

test('a cancelled live-radio restart whose play() starts during a newer load\'s API read is stopped, not paused', async () => {
  const m = radioMusic()
  fakeApi(m, { a1: [[song('s1')]] })
  const am = page(m)
  await am.stop()
  const b = albumWithLateStart(m, am, await cancelledWithPendingPlay(m, am, restartRadio, radioStarts(m)))
  await flush()
  assert.deepEqual(m.calls, ['stop'])
  assert.equal(m.isPlaying, false)
  await b
  assert.deepEqual(m.calls, ['stop', 'setQueue s1', 'play'])
  assert.equal(m.isPlaying, true)
  assert.equal(am.snapshot().stoppedLive, null)
})

// Once B has sent its queue, the music is B's (as in "a cancelled load whose play() starts late
// leaves a newer load under way alone", there with `am play`).
for (const [what, playB, queued] of [
  ['station', (am) => am.playQueue({ station: 'ra.2' }, 1), 'setQueue ra.2'],
  ['station for a song', (am) => am.playQueue({ stationFor: { song: '7' } }, 1), 'setStationQueue 7'],
  ['live-radio restart', (am) => am.resume(1), 'setQueue ra.1'],
]) {
  test(`a cancelled live-radio restart whose play() starts once a newer ${what} has sent its queue is left alone`, async () => {
    const m = radioMusic(300)
    const am = page(m)
    await am.stop()
    const startA = await cancelledWithPendingPlay(m, am, restartRadio, radioStarts(m))
    const b = playB(am)
    await m.reached(queued)
    startA()
    await b
    assert.deepEqual(m.calls, [queued, 'play'])
    assert.equal(m.isPlaying, true)
  })
}

for (const [what, playB, steps] of [
  ['album', playAlbum, ['setQueue s1', 'play']],
  ['plain resume', (am) => am.resume(1), ['play']],
]) {
  test(`a cancelled load's late pause still in flight holds back a newer ${what} until it lands`, async () => {
    const m = queueMusic()
    fakeApi(m, { a1: [[song('s1')]] })
    const am = page(m)
    const startA = await cancelledWithPendingPlay(m, am, playSong1)
    // Still in flight when B takes the music (the album: after its API read), within the page's
    // bound on a pause.
    const PAUSE_MS = 1000
    assert.ok(PAUSE_MS < SETTLE_MS)
    m.pause = () => (m.call('pause'), sleep(PAUSE_MS).then(() => (m.call('paused'), (m.playbackState = S.paused))))
    startA()
    await flush()
    await playB(am)
    assert.deepEqual(m.calls, ['pause', 'paused', ...steps])
    await idle()
    assert.deepEqual(m.calls, ['pause', 'paused', ...steps])
    assert.equal(m.isPlaying, true)
  })
}

test('a cancelled load\'s late pause that never settles holds back a newer load\'s setQueue for the pause bound at most', async () => {
  const m = queueMusic()
  const READ_MS = 300
  fakeApi(m, { a1: [[song('s1')]] }, READ_MS)
  const am = page(m)
  const startA = await cancelledWithPendingPlay(m, am, playSong1)
  m.pause = () => (m.call('pause'), never())
  let queuedAt
  const setQueue = m.setQueue
  m.setQueue = (o) => ((queuedAt = clock().now), setQueue(o))
  const t0 = clock().now
  await albumWithLateStart(m, am, startA)
  assert.equal(queuedAt - t0, READ_MS + SETTLE_MS)
  assert.deepEqual(m.calls, ['pause', 'setQueue s1', 'play'])
  assert.ok(am.snapshot().lastEvents.some((e) => e.type === 'gaveUp' && e.detail === `the cancelled loads' silences after ${secs(SETTLE_MS)}`))
})

// The generation model (src/daemon/host.zig `Plays`).

test('a load begun during a slow stop has its generation and plays once the stop is done', async () => {
  const m = fakeMusic({ state: S.playing, pause: () => sleep(800).then(() => (m.playbackState = S.paused)), seek: async () => {} })
  m.setQueue = () => (m.call('setQueue'), Promise.resolve())
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  const am = page(m)
  const stopping = am.stop(1)
  await m.reached('pause')
  // `am play` right after `am stop`: the daemon gave it the stop's generation.
  const next = am.play('2', 1)
  const stopped = await stopping
  assert.equal(stopped.cancelled, 0)
  await next
  assert.deepEqual(m.calls, ['pause', 'seek 0', 'setQueue', 'play'])
  assert.equal(m.isPlaying, true)
})

test('a play that reaches the page after a stop that began later is cancelled at its start', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: never })
  m.nowPlayingItem = null
  m.setQueue = () => (m.call('setQueue'), Promise.resolve())
  m.play = () => (m.call('play'), Promise.resolve())
  const am = page(m)
  const stopped = await am.stop(1)
  // Nothing in flight here: the daemon knows it was on its way.
  assert.equal(stopped.cancelled, 0)
  await assert.rejects(am.playQueue({ songs: ['1'] }, 0), { message: 'stopped before it started' })
  await assert.rejects(am.playLater({ songs: ['1'] }, 0), { message: 'stopped before it started' })
  assert.deepEqual(m.calls, [])
  // A later play has the new generation.
  await am.playQueue({ songs: ['1'] }, 1)
  assert.deepEqual(m.calls, ['setQueue', 'play'])
})

test('a stop without a generation (next on the last item) cancels nothing', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: async () => {} })
  m.nowPlayingItem = null
  m.setQueue = () => (m.call('setQueue'), sleep(200))
  m.play = () => (m.call('play'), Promise.resolve())
  const am = page(m)
  const queued = am.playQueue({ songs: ['1'] }, 0)
  await m.reached('setQueue')
  const stopped = await am.stop()
  assert.equal(stopped.cancelled, 0)
  await queued
  assert.deepEqual(m.calls, ['setQueue', 'play'])
})

test('appending to a queue that plays is no load: a stop meanwhile pauses the music and the append goes on', async () => {
  const m = fakeMusic({ state: S.playing, pause: async () => (m.playbackState = S.paused), seek: async () => {} })
  m.queue = { length: 3, items: [], position: 0, queueItem: () => null }
  m.playNext = () => (m.call('playNext'), sleep(300))
  const am = page(m)
  const next = am.playNext({ songs: ['9'] }, 0)
  await m.reached('playNext')
  assert.equal(am.snapshot().loadPending, false)
  const stopped = await am.stop(1)
  assert.equal(stopped.cancelled, 0)
  await next
  assert.deepEqual(m.calls, ['playNext', 'pause', 'seek 0'])
})

test('Space on stopped live radio then a stop while its play() is pending: the radio, once it starts, is stopped again', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: async () => {}, seek: never, stop: async () => (m.playbackState = S.stopped) })
  const am = page(m)
  await am.stop()
  m.reset()
  // MusicKit names no item until the stream plays; play() resolves seconds later.
  const PLAY_MS = 1500
  m.nowPlayingItem = null
  m.setQueue = () => (m.call('setQueue'), (m.playbackState = S.loading), Promise.resolve())
  m.play = () => (
    m.call('play'),
    sleep(PLAY_MS).then(() => {
      m.nowPlayingItem = { id: 'ra.1', title: 'Radio', isLiveRadioStation: true }
      m.playbackState = S.playing
    })
  )
  const resumed = am.resume(0)
  await m.reached('play')
  const { value: stopped, ms } = await timed(() => am.stop(1))
  // The stop doesn't wait for the pending play(): the load stops the radio at once...
  assert.ok(ms < PLAY_MS, `${ms} ms`)
  assert.equal(stopped.cancelled, 1)
  await assert.rejects(resumed, { message: 'stopped before it started' })
  assert.deepEqual(m.calls, ['setQueue', 'play', 'pause', 'stop'])
  // ...and again once play() started it after all.
  await idle()
  assert.equal(m.isPlaying, false)
  assert.deepEqual(m.calls, ['setQueue', 'play', 'pause', 'stop', 'stop'])
  // Still the station a resume restarts.
  m.reset()
  m.setQueue = () => (m.call('setQueue'), Promise.resolve())
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  await am.resume(1)
  assert.deepEqual(m.calls, ['setQueue', 'play'])
})

test('a live-radio restart that fails past the bound is noted; within it, the resume fails with it', async () => {
  const m = fakeMusic({ state: S.playing, live: true, pause: never, seek: never, stop: async () => (m.playbackState = S.stopped) })
  const am = page(m)
  await am.stop()
  m.nowPlayingItem = null
  m.setQueue = () => sleep(START_MS + 500).then(() => Promise.reject(new Error('late boom')))
  await am.resume(0)
  await idle()
  assert.ok(am.snapshot().lastEvents.some((e) => e.type === 'restartFailed' && e.detail.includes('late boom')))
  m.nowPlayingItem = { id: 'ra.1', isLiveRadioStation: true }
  m.playbackState = S.playing
  await am.stop()
  m.nowPlayingItem = null
  m.setQueue = () => Promise.reject(new Error('early boom'))
  await assert.rejects(am.resume(0), /early boom/)
  assert.equal(am.snapshot().lastEvents.filter((e) => e.type === 'restartFailed').length, 1)
})

test('the snapshot names stopped live radio until a play, a queue load or a restart replaces it', async () => {
  const station = { id: 'ra.1', title: 'Apple Music 1', isLiveRadioStation: true }
  const song = { id: '1', title: 'Little Wing', isLiveRadioStation: false }
  // MusicKit drops the item on stop(), and names the station's only once its stream plays.
  const m = fakeMusic({ state: S.playing, live: true, pause: async () => {}, seek: async () => {}, stop: async () => ((m.playbackState = S.stopped), (m.nowPlayingItem = null)) })
  m.nowPlayingItem = station
  let queued = null
  m.setQueue = (opts) => ((queued = opts.station ? station : song), (m.nowPlayingItem = null), Promise.resolve())
  m.play = () => ((m.nowPlayingItem = queued), (m.playbackState = S.playing), Promise.resolve())
  const am = page(m)
  const stopped = { id: 'ra.1', name: 'Apple Music 1' }
  assert.equal(am.snapshot().stoppedLive, null)

  const afterStop = await am.stop()
  assert.equal(afterStop.nowPlaying, null)
  assert.deepEqual(plain(afterStop.stoppedLive), stopped)
  assert.deepEqual(plain(am.snapshot().stoppedLive), stopped)
  // A successful restart.
  const resumed = await am.resume(0)
  assert.equal(resumed.nowPlaying.id, 'ra.1')
  assert.equal(resumed.stoppedLive, null)

  // A pause stops it the same way; a new play replaces it.
  assert.deepEqual(plain((await am.pause()).stoppedLive), stopped)
  await am.play('1', 0)
  assert.equal(am.snapshot().stoppedLive, null)

  // A queue load replaces it too.
  await am.playQueue({ station: 'ra.1' }, 0)
  assert.deepEqual(plain((await am.stop()).stoppedLive), stopped)
  await am.playQueue({ songs: ['1'] }, 0)
  assert.equal(am.snapshot().stoppedLive, null)
})

test('a new play waits for a cancelled one to end, so its late setQueue does not land on the new queue', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => {}, seek: async () => {} })
  m.nowPlayingItem = null
  const queues = []
  m.setQueue = (o) => (m.call(`setQueue ${o.song}`), sleep(o.song === '1' ? 600 : 10).then(() => queues.push(o.song)))
  m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
  const am = page(m)
  const first = am.play('1', 0)
  await m.reached('setQueue 1')
  await am.stop(1)
  const second = am.play('2', 1)
  await assert.rejects(first, { message: 'stopped before it started' })
  await second
  assert.deepEqual(queues, ['1', '2'])
  assert.deepEqual(m.calls, ['setQueue 1', 'setQueue 2', 'play'])
})

test('a stop whose pause misses a pending play() answers once the cancelled load silenced it, with a new play already waiting', async () => {
  const m = fakeMusic({ state: S.none, pause: async () => (m.playbackState = m.playbackState === S.playing ? S.paused : m.playbackState), seek: async () => {} })
  m.nowPlayingItem = null
  m.setQueue = async (o) => (m.call(`setQueue ${o.song}`), (m.nowPlayingItem = { id: o.song, title: o.song }), (m.playbackState = S.loading))
  m.play = () => (m.call('play'), sleep(300).then(() => (m.playbackState = S.playing)))
  const am = page(m)
  const first = am.play('1', 0)
  await m.reached('play')
  const stopping = am.stop(1)
  const second = am.play('2', 1)
  const stopped = await stopping
  assert.equal(stopped.cancelled, 1)
  assert.equal(stopped.isPlaying, false)
  await assert.rejects(first, { message: 'stopped before it started' })
  await second
  assert.deepEqual(m.calls, ['setQueue 1', 'play', 'pause', 'seek 0', 'pause', 'setQueue 2', 'play'])
  assert.equal(m.isPlaying, true)
})

// A stop's seek to 0:00 that MusicKit leaves pending (#20): it stays `seeking`, which the
// daemon and TUI read as a song starting.

test('a stop on a paused item already at 0:00 doesn\'t seek and answers paused', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  m.currentPlaybackTime = 0
  const { value, ms } = await timed(() => page(m).stop())
  assert.deepEqual(m.calls, [])
  assert.equal(ms, 0)
  assert.equal(value.gaveUp, undefined)
  assert.equal(value.playbackState, 'paused')
})

test('a stop at 0:12 whose seek gives up in `seeking` reports paused, in its answer and after', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  const am = page(m)
  const { value, ms } = await timed(() => am.stop())
  assert.equal(ms, SETTLE_MS)
  assert.deepEqual(m.calls, ['seek 0'])
  assert.deepEqual(plain(value.gaveUp), [`seekToTime(0) after ${secs(SETTLE_MS)}`])
  assert.equal(value.lastEvents.at(-1).type, 'gaveUp')
  assert.equal(m.playbackState, S.seeking)
  assert.equal(value.playbackState, 'paused')
  await sleep(60_000)
  assert.equal(am.snapshot().playbackState, 'paused')
  assert.equal(am.snapshot().currentPlaybackTime, 12)
})

// The fake's play() leaves MusicKit `seeking` (still on the stop's seek): what the page then
// reports is MusicKit's own state, not the stop's.
for (const [what, start] of [
  ['a resume', (am) => am.resume(1)],
  ['a play', (am) => am.play('2', 1)],
  ['a new queue', (am) => am.playQueue({ songs: ['2'] }, 1)],
]) {
  test(`after a stop whose seek gave up, ${what} reports MusicKit's own state again`, async () => {
    const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
    m.setQueue = async () => {}
    m.play = () => (m.call('play'), Promise.resolve())
    const am = page(m)
    assert.equal((await am.stop(1)).playbackState, 'paused')
    const value = await start(am)
    assert.ok(m.calls.includes('play'), m.calls.join())
    assert.equal(value.playbackState, 'seeking')
    assert.equal(am.snapshot().playbackState, 'seeking')
  })
}

// A seek the user asked for shows `seeking` while it is pending, right after such a stop too; so
// does a skip or jump that leaves MusicKit there.
for (const [what, call, label] of [
  ['a seek', (am) => am.seek(30), 'seek 30'],
  ['a seekBy', (am) => am.seekBy(5), 'seek 17'],
  ['a prev', (am) => am.prev(), 'seek 0'],
  ['a next', (am) => am.next(), 'skipToNextItem'],
  ['a jump', (am) => am.jump(1), 'changeToMediaAtIndex 1'],
]) {
  test(`after a stop whose seek gave up, ${what} still pending reports seeking`, async () => {
    const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
    m.capabilities = { canSeek: true, canSkipToNextItem: true, canSkipToPreviousItem: true }
    m.queue = { length: 3, position: 0, nextPlayableItemIndex: 1 }
    m.repeatMode = 0
    m.skipToNextItem = () => (m.call('skipToNextItem'), Promise.resolve())
    m.changeToMediaAtIndex = (i) => (m.call(`changeToMediaAtIndex ${i}`), Promise.resolve())
    const am = page(m)
    assert.equal((await am.stop()).playbackState, 'paused')
    m.reset()
    const value = await call(am)
    assert.deepEqual(m.calls, [label])
    assert.equal(value.playbackState, 'seeking')
    assert.equal(am.snapshot().playbackState, 'seeking')
  })
}

test('after a stop whose seek gave up, MusicKit leaving `seeking` on its own ends the paused report', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  const am = page(m)
  assert.equal((await am.stop()).playbackState, 'paused')
  // The late seek lands.
  m.playbackState = S.paused
  m.currentPlaybackTime = 0
  assert.equal(am.snapshot().playbackState, 'paused')
  // From here on, a `seeking` is MusicKit's own.
  m.playbackState = S.seeking
  assert.equal(am.snapshot().playbackState, 'seeking')
  m.playbackState = S.stopped
  assert.equal(am.snapshot().playbackState, 'stopped')
})

test('after a stop whose seek gave up, music that plays (started outside the page) ends the paused report', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  const am = page(m)
  await am.stop()
  let playing = true
  Object.defineProperty(m, 'isPlaying', { get: () => playing })
  assert.equal(am.snapshot().playbackState, 'seeking')
  playing = false
  assert.equal(am.snapshot().playbackState, 'seeking')
})

test('next on the last item whose stop seek gives up in `seeking` reports paused', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  m.capabilities = { canSkipToNextItem: true }
  m.queue = { nextPlayableItemIndex: -1 }
  m.repeatMode = 0
  const am = page(m)
  const value = await am.next()
  assert.deepEqual(plain(value.gaveUp), [`seekToTime(0) after ${secs(SETTLE_MS)}`])
  assert.equal(value.playbackState, 'paused')
  assert.equal(am.snapshot().playbackState, 'paused')
})

test('a user seek that reaches the page while the stop\'s seek is pending still reports seeking after the stop gives up', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  m.capabilities = { canSeek: true }
  const am = page(m)
  const stopping = am.stop()
  await m.reached('seek 0')
  const seeking = am.seek(30)
  assert.deepEqual(plain((await stopping).gaveUp), [`seekToTime(0) after ${secs(SETTLE_MS)}`])
  assert.equal(am.snapshot().playbackState, 'seeking')
  await seeking
  assert.equal(am.snapshot().playbackState, 'seeking')
})

test('a user seek still pending reports seeking', async () => {
  const m = fakeMusic({ state: S.paused, pause: never, seek: stuckSeek })
  m.capabilities = { canSeek: true }
  const am = page(m)
  const seeking = am.seek(30)
  await m.reached('seek 30')
  assert.equal(am.snapshot().playbackState, 'seeking')
  assert.deepEqual(plain((await seeking).gaveUp), [`seekToTime(30) after ${secs(SETTLE_MS)}`])
  assert.equal(am.snapshot().playbackState, 'seeking')
})

// The browser hands the page's unhandledrejection listener the reason; the page notes it.
test('the page notes an unhandled rejection in its events', async () => {
  const { am, listeners } = coldPage(null)
  const onRejection = listeners.filter((l) => l.type === 'unhandledrejection')
  assert.equal(onRejection.length, 1)
  onRejection[0].fn({ reason: new TypeError('stray') })
  assert.deepEqual(plain(am.snapshot().lastEvents.map(({ type, detail }) => ({ type, detail }))), [{ type: 'unhandledRejection', detail: 'TypeError | stray' }])
})

test('the page\'s Date runs on the test\'s clock, its event times too', async () => {
  const { am, ctx, listeners } = coldPage(null)
  const pageNow = () => vm.runInContext('Date.now()', ctx)
  assert.equal(pageNow(), EPOCH_MS)
  await sleep(1500)
  assert.equal(pageNow(), EPOCH_MS + 1500)
  listeners.find((l) => l.type === 'unhandledrejection').fn({ reason: new Error('now') })
  assert.equal(am.snapshot().lastEvents.at(-1).t, new Date(EPOCH_MS + 1500).toISOString().slice(11, 23))
})

// Web Storage held in memory, for a launch to keep across its page loads.
function memoryStorage() {
  const items = new Map()
  return {
    get length() {
      return items.size
    },
    key: (i) => [...items.keys()][i] ?? null,
    getItem: (key) => items.get(String(key)) ?? null,
    setItem: (key, value) => void items.set(String(key), String(value)),
    removeItem: (key) => void items.delete(String(key)),
    clear: () => items.clear(),
  }
}

const nonceIn = (url) => new URL(url, 'http://localhost').searchParams.get('engine')

// A launch of the engine page at `search` (the URL's query). Each `load()` is one page load, as a
// browser runs it until it starts reporting: the daemon grants its claim and the DOM loads, so it
// opens the event stream. A later `load()` is a reload: the same URL, and the launch keeps its
// sessionStorage, localStorage and window.name, so a page load id kept in any of them fails the
// reload test. A load's `claims` holds each claim as its method and nonce, `streams` each event
// stream's nonce, `sockets` each WebSocket it opened, `reports` each report's body as sent over
// one, and `sentAt` when (virtual ms); `tick` runs its once-a-second report, and `ctx` is its window.
//
// Its WebSocket is a browser's as far as the page can tell: it opens on the next turn of the
// clock, its `send` throws while it is still opening and drops what it is given once closed, and
// `drop()` closes it from the daemon's end, or refuses it while it opens.
function engineLaunch(search) {
  const kept = { sessionStorage: memoryStorage(), localStorage: memoryStorage(), name: '' }
  let lastWindow = null
  return {
    async load() {
      if (lastWindow) kept.name = lastWindow.name
      const sent = { claims: [], streams: [], sockets: [], reports: [], sentAt: [] }
      const ticks = []
      const domLoaded = []
      const signin = { addEventListener: noop }
      class WebSocket {
        static CONNECTING = 0
        static OPEN = 1
        static CLOSING = 2
        static CLOSED = 3
        onopen = null
        onclose = null
        constructor(url) {
          this.url = url
          this.readyState = WebSocket.CONNECTING
          sent.sockets.push(this)
          clock().setTimeout(() => {
            if (this.readyState !== WebSocket.CONNECTING) return
            this.readyState = WebSocket.OPEN
            this.onopen?.({ type: 'open' })
          }, 0)
        }
        send(data) {
          if (this.readyState === WebSocket.CONNECTING) throw new Error('InvalidStateError: the WebSocket is still connecting')
          if (this.readyState !== WebSocket.OPEN) return
          sent.reports.push(JSON.parse(data))
          sent.sentAt.push(clock().now)
        }
        close() {
          this.drop()
        }
        drop() {
          if (this.readyState === WebSocket.CLOSED) return
          this.readyState = WebSocket.CLOSED
          this.onclose?.({ type: 'close' })
        }
      }
      lastWindow = coldPage(null, {
        ...kept,
        location: { search, host: 'localhost:47823', reload: noop, replace: noop },
        document: {
          getElementById: (id) => (id === 'signin' ? signin : null),
          addEventListener: (type, fn) => type === 'DOMContentLoaded' && domLoaded.push(fn),
          body: { classList: { add: noop } },
        },
        fetch: async (url, init = {}) => {
          const { pathname } = new URL(url, 'http://localhost')
          if (pathname === '/claim') sent.claims.push({ method: init.method ?? 'GET', engine: nonceIn(url) })
          return { status: 204 }
        },
        EventSource: class {
          constructor(url) {
            sent.streams.push(nonceIn(url))
          }
        },
        WebSocket,
        setInterval: (fn) => ticks.push(fn),
      }).ctx
      for (const fn of domLoaded) await fn()
      return { ...sent, ctx: lastWindow, tick: () => ticks.forEach((fn) => fn()) }
    },
  }
}

// The daemon takes a page's claim, stream and reports only with its launch's nonce, and tells one
// page load from the next by the `load` id in its reports.
test('a reload keeps the launch nonce in its claim, stream and reports, and reports a new page load id', async () => {
  const launch = engineLaunch('?engine=l4unch')
  const loads = []
  for (const name of ['first load', 'reload']) {
    const load = await launch.load()
    // Three reports, a second apart as the page's timer sends them (it spaces two by 250 ms at least).
    for (let i = 0; i < 3; i++) {
      load.tick()
      await sleep(1000)
    }
    loads.push({ name, ...load })
  }
  for (const { name, claims, streams, sockets, reports } of loads) {
    assert.deepEqual(claims, [{ method: 'GET', engine: 'l4unch' }], `the ${name}'s claims`)
    assert.deepEqual(streams, ['l4unch'], `the ${name}'s event streams`)
    assert.deepEqual(sockets.map((s) => s.url), ['ws://localhost:47823/reports?engine=l4unch'], `the ${name}'s report sockets`)
    assert.ok(reports.length >= 3, `the ${name} sent ${reports.length} reports`)
    assert.deepEqual(new Set(reports.map((r) => r.engine)), new Set(['l4unch']), `the ${name}'s reports' nonces`)
    // One id for all of a page load's reports.
    const ids = new Set(reports.map((r) => r.load))
    assert.equal(ids.size, 1, `the ${name}'s page load ids: ${[...ids]}`)
    assert.match(reports[0].load, /^\S+$/, `the ${name}'s page load id`)
  }
  const [first, reloaded] = loads.map((l) => l.reports[0].load)
  assert.notEqual(reloaded, first, 'the reload kept the first load\'s id')
})

const gaps = (times) => times.slice(1).map((t, i) => t - times[i])

// Every report of a page load goes over its one socket: the timer's, once a second, and those its
// events bring, at most about four a second, with the last of a burst sent at the burst's end.
test('reports go over one socket per page load, once a second and at most about four a second in a burst', async () => {
  const load = await engineLaunch('?engine=l4unch').load()
  for (let i = 0; i < 5; i++) {
    load.tick()
    await sleep(1000)
  }
  assert.equal(load.sockets.length, 1, 'report sockets')
  assert.deepEqual(gaps(load.sentAt), [1000, 1000, 1000, 1000], 'the timer\'s reports, ms apart')

  // An event every 50 ms for a second.
  const before = load.sentAt.length
  for (let i = 0; i < 20; i++) {
    vm.runInContext(`note('burst', ${i})`, load.ctx)
    await sleep(50)
  }
  await sleep(1000)
  const burst = load.sentAt.slice(before)
  assert.equal(load.sockets.length, 1, 'report sockets after the burst')
  assert.ok(burst.length >= 4 && burst.length <= 5, `the burst sent ${burst.length} reports`)
  for (const gap of gaps(burst)) assert.ok(gap >= 250, `two of the burst's reports ${gap} ms apart`)
  assert.equal(load.reports.at(-1).lastEvents.at(-1).detail, 19, 'the burst\'s last event, in its last report')
})

// The socket closes when the daemon restarts, say: the next report opens another, which it goes out
// over once it opens. One refused while it opens (a launch that is over) is tried again the same way.
test('a report socket that closes is opened again by the next report, which goes out over the new one', async () => {
  const load = await engineLaunch('?engine=l4unch').load()
  load.tick()
  await sleep(1000)
  load.sockets[0].drop()
  await sleep(500)
  assert.equal(load.sockets.length, 1, 'report sockets before the next report')

  load.tick()
  load.sockets[1].drop()
  await sleep(1000)
  load.tick()
  await sleep(1000)
  assert.deepEqual(load.sockets.map((s) => s.url), Array(3).fill('ws://localhost:47823/reports?engine=l4unch'), 'report sockets')
  assert.deepEqual(load.sockets.map((s) => s.readyState), [3, 3, 1], 'their states')
  assert.deepEqual(load.sentAt, [0, 2500], 'when reports went out')
})

// Cold engine: the page is connected (the daemon can call it) before MusicKit is configured.
for (const phase of ['before MusicKit.configure', 'while the account loads']) {
  test(`a stop on a page not configured yet (${phase}) succeeds without touching MusicKit, and cancels the older plays once it is`, async () => {
    const m = fakeMusic({ state: S.none, pause: never, seek: never, stop: never })
    m.nowPlayingItem = null
    m.setQueue = () => (m.call('setQueue'), Promise.resolve())
    m.play = () => (m.call('play'), (m.playbackState = S.playing), Promise.resolve())
    const { am, half, configure } = coldPage(m)
    if (phase === 'while the account loads') half()
    const stopped = await am.stop(1)
    assert.equal(stopped.configured, false)
    assert.equal(stopped.cancelled, 0)
    assert.equal(stopped.nowPlaying, null)
    assert.deepEqual(m.calls, [])
    configure()
    // A play that began before the stop reaches the page only now: it never starts.
    await assert.rejects(am.play('1', 0), { message: 'stopped before it started' })
    await assert.rejects(am.playQueue({ songs: ['1'] }, 0), { message: 'stopped before it started' })
    assert.deepEqual(m.calls, [])
    // One that began after it plays.
    await am.play('2', 1)
    assert.deepEqual(m.calls, ['setQueue', 'play'])
  })
}

// The page stays cold after the stop (its developer token never came): a play older than the stop
// is cancelled, one with no generation or the stop's still finds MusicKit missing.
for (const phase of ['before MusicKit.configure', 'while the account loads']) {
  test(`a play older than a cold stop, on a page still not configured (${phase}), stopped before it started`, async () => {
    const touched = []
    const m = new Proxy({}, { get: (_, key) => void touched.push(String(key)), set: (_, key) => (touched.push(`set ${String(key)}`), true) })
    const { am, half } = coldPage(m)
    if (phase === 'while the account loads') half()
    await am.stop(2)
    touched.length = 0 // the stop's snapshot reads a half-configured MusicKit
    const older = {
      play: ['1', 1],
      playQueue: [{ songs: ['1'] }, 1],
      playNext: [{ songs: ['1'] }, 1],
      playLater: [{ songs: ['1'] }, 1],
      resume: [1],
      toggle: [1],
    }
    for (const [name, args] of Object.entries(older)) {
      await assert.rejects(async () => am[name](...args), { message: 'stopped before it started' }, `${name} older`)
      const current = [...args]
      current[current.length - 1] = 2
      await assert.rejects(async () => am[name](...current), { message: 'MusicKit is not configured yet' }, `${name} current`)
      await assert.rejects(async () => am[name](...args.slice(0, -1)), { message: 'MusicKit is not configured yet' }, `${name} without a generation`)
    }
    assert.deepEqual(touched, [])
    assert.equal(am.snapshot().loadPending, false)
  })
}

// Every call but these needs MusicKit configured (`requireMusic`). The cold stop above relies on
// it for the play entry points: none of them may start a load on a cold page.
const coldExempt = {
  snapshot: 'reports the cold page',
  drmProbe: 'probes the browser, not MusicKit',
  stop: 'succeeds on a cold page (above)',
  reload: 'reloads the page',
}
const coldArgs = {
  play: ['1', 0],
  playQueue: [{ songs: ['1'] }, 0],
  playNext: [{ songs: ['1'] }, 0],
  playLater: [{ songs: ['1'] }, 0],
  resume: [0],
  toggle: [0],
  jump: [0],
  seek: [30],
  seekBy: [5],
  setVolume: [0.5],
  setShuffle: [true],
  setRepeat: ['all'],
  setAutoplay: [false],
  removeAt: [1],
  queueWindow: [0, 10],
}

for (const phase of ['before MusicKit.configure', 'while the account loads']) {
  test(`the other calls on a page not configured yet still fail as before (${phase})`, async () => {
    // Records every touch of MusicKit: the calls must fail before any.
    const touched = []
    const m = new Proxy({}, { get: (_, key) => void touched.push(String(key)), set: (_, key) => (touched.push(`set ${String(key)}`), true) })
    const { am, half } = coldPage(m)
    if (phase === 'while the account loads') half()
    const calls = Object.keys(am).filter((name) => !(name in coldExempt))
    for (const name of ['play', 'playQueue', 'playNext', 'playLater', 'resume', 'toggle', 'pause']) assert.ok(calls.includes(name), name)
    for (const name of calls) {
      await assert.rejects(async () => am[name](...(coldArgs[name] ?? [])), { message: 'MusicKit is not configured yet' }, name)
    }
    assert.deepEqual(touched, [])
    assert.equal(am.snapshot().loadPending, false)
  })
}

test('queue items carry the catalog id, as now playing does: a library song its match, an upload none', async () => {
  const m = fakeMusic({ state: S.playing })
  m.queue = {
    position: 0,
    length: 3,
    items: [
      { id: 'i.1', title: 'a', isLibraryItem: true, attributes: { playParams: { catalogId: '100' } } },
      { id: '200', title: 'b', attributes: {} },
      { id: 'i.2', title: 'upload', isLibraryItem: true, attributes: { playParams: {} } },
    ],
    queueItem: () => null,
  }
  const am = page(m)
  assert.deepEqual(plain(am.queueWindow(0, 10).items.map((it) => it.catalogId)), ['100', '200', null])
})

// A developer token as the page reads it: header and claims, base64url without padding. The
// signature is never checked (MusicKit doesn't check it either).
const b64url = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
const jwt = (header, claims) => `${b64url(header)}.${b64url(claims)}.c2ln`
// A hash as `tokenId` reports it: the first 8 bytes of the token's SHA-256, in hex.
const hash16 = (token) => createHash('sha256').update(token).digest('hex').slice(0, 16)

test('the report names the developer token MusicKit was configured with: its key, when it ends, and a hash of it', async () => {
  const { am, ctx } = coldPage(null)
  assert.equal(am.snapshot().developerToken, null)
  const token = jwt({ alg: 'ES256', kid: 'KEY' }, { iss: 'TEAM', iat: 1_793_000_000, exp: 1_793_604_800, origin: ['http://localhost:47823'] })
  ctx.__token = token
  await vm.runInContext('(async () => { developerToken = await tokenId(__token) })()', ctx)
  // The first 8 bytes of its SHA-256, as the daemon computes it (`doctorDeveloperToken`).
  assert.deepEqual(plain(am.snapshot().developerToken), { kid: 'KEY', exp: 1_793_604_800, hash: hash16(token) })
  // Never the token itself: the report goes to the TUI and the logs.
  assert.equal(JSON.stringify(am.snapshot()).includes(token), false)
  // Unreadable claims still get the hash: it alone tells two tokens apart.
  ctx.__token = 'not a token'
  assert.deepEqual(plain(await vm.runInContext('tokenId(__token)', ctx)), { kid: null, exp: null, hash: hash16('not a token') })
  // Parts that decode to JSON null, and a browser that can't hash: no throw, so configure goes on.
  ctx.__token = `${Buffer.from('null').toString('base64url')}.${Buffer.from('null').toString('base64url')}.c2ln`
  ctx.crypto = {}
  assert.deepEqual(plain(await vm.runInContext('tokenId(__token)', ctx)), { kid: null, exp: null, hash: null })
})

// An engine page whose own configure() ran: the daemon's token routes answer it, `/user-token`
// with `stored` (204 when null), and its fake MusicKit holds the Music User Token it is given.
// `posted` gets each POST /user-token body, and `reports` each report the page sends. With
// `hashes: false`, the browser can't hash.
async function configuredPage(stored, { hashes = true } = {}) {
  const { am, ctx } = coldPage(null)
  if (!hashes) ctx.crypto = {}
  const music = {
    musicUserToken: null,
    get isAuthorized() {
      return !!music.musicUserToken
    },
    addEventListener: () => {},
    me: async () => ({ subscription: { active: true } }),
    authorize: async () => music.musicUserToken,
    unauthorize: async () => void (music.musicUserToken = null),
  }
  const posted = []
  const reports = []
  ctx.MusicKit = { ...ctx.MusicKit, Events: {}, PlaybackBitrate: { HIGH: 256 }, configure: async () => {}, getInstance: () => music }
  ctx.fetch = async (url, init) => {
    const text = (body, status = 200) => ({ ok: status < 300, status, text: async () => body, json: async () => JSON.parse(body) })
    if (url.startsWith('/developer-token')) return text(jwt({ alg: 'ES256', kid: 'KEY' }, { exp: 1_793_604_800 }))
    if (url.startsWith('/user-token') && init?.method === 'POST') return (posted.push({ body: JSON.parse(init.body), snapshot: am.snapshot() }), text('{"ok":true,"status":200,"storefront":"gb"}'))
    if (url.startsWith('/user-token')) return stored ? text(`${stored}\n`) : text('', 204)
    return never()
  }
  ctx.__reports = reports
  vm.runInContext('report = () => __reports.push(JSON.parse(JSON.stringify(snapshot())))', ctx)
  await vm.runInContext('configure()', ctx)
  return { am, ctx, music, posted, reports }
}

// Music User Tokens are opaque to the page: no header, no claims.
const userToken = 'AgVBVHN0b3JlZC1tdXNpYy11c2VyLXRva2Vu+/='
const freshToken = 'AgVBVGZyZXNoLW11c2ljLXVzZXItdG9rZW4+/='

test('the report names the Music User Token configure gave MusicKit by a hash of it, and none when none is stored or the browser can’t hash', async () => {
  assert.equal(coldPage(null).am.snapshot().musicUserToken, null)
  const { am, music, reports } = await configuredPage(userToken)
  assert.equal(music.musicUserToken, userToken)
  assert.equal(am.snapshot().configured, true)
  assert.deepEqual(plain(am.snapshot().musicUserToken), { kid: null, exp: null, hash: hash16(userToken) })
  // The first report that says configured names it already: the daemon decides on that one.
  const first = reports.find((r) => r.configured)
  assert.equal(first.musicUserToken.hash, hash16(userToken))
  // Never the token itself: the report goes to the TUI and the logs.
  for (const r of [...reports, am.snapshot()]) assert.equal(JSON.stringify(r).includes(userToken), false)

  const none = await configuredPage(null)
  assert.equal(none.am.snapshot().configured, true)
  assert.equal(none.am.snapshot().musicUserToken, null)

  const unhashed = await configuredPage(userToken, { hashes: false })
  assert.equal(unhashed.music.musicUserToken, userToken)
  assert.equal(unhashed.am.snapshot().configured, true)
  assert.equal(unhashed.am.snapshot().musicUserToken, null)
})

test('the id follows the Music User Token MusicKit holds: the page’s own sign-in, and a change MusicKit makes itself', async () => {
  const { am, ctx, music, posted, reports } = await configuredPage(userToken)
  // The page's own sign-in gives MusicKit a new token: it is named by the time the page posts
  // it, since the daemon looks at the page as soon as it has stored it.
  music.authorize = async () => (music.musicUserToken = freshToken)
  await vm.runInContext('signIn()', ctx)
  assert.deepEqual(plain(posted.map((p) => p.body)), [{ token: freshToken }])
  assert.equal(posted[0].snapshot.musicUserToken.hash, hash16(freshToken))
  assert.equal(reports.at(-1).musicUserToken.hash, hash16(freshToken))

  // MusicKit changes it by itself: no snapshot names the old one, and the next report names the new.
  music.musicUserToken = userToken
  assert.equal(am.snapshot().musicUserToken, null)
  await flush()
  assert.equal(reports.at(-1).musicUserToken.hash, hash16(userToken))
  assert.equal(am.snapshot().musicUserToken.hash, hash16(userToken))
  // MusicKit drops it: none.
  await music.unauthorize()
  assert.equal(am.snapshot().musicUserToken, null)
  await flush()
  assert.equal(reports.at(-1).musicUserToken, null)
  for (const r of [...reports, am.snapshot()]) {
    assert.equal(JSON.stringify(r).includes(userToken), false)
    assert.equal(JSON.stringify(r).includes(freshToken), false)
  }
})

test('checkDeveloperToken asks Apple with the page’s own developer token: only a 401 counts as refused', async () => {
  const m = fakeMusic({ state: S.paused })
  m.storefrontId = 'gb'
  const paths = []
  let answer = () => Promise.resolve({ data: { data: [{ id: 'gb', type: 'storefronts' }] } })
  m.api = { music: (path) => (paths.push(path), answer()) }
  const am = page(m)
  assert.deepEqual(plain(await am.checkDeveloperToken()), { refused: false })
  assert.deepEqual(paths, ['/v1/storefronts/gb'])
  // MusicKit rejects api.music() with the HTTP status's reason (401 UNAUTHORIZED_ERROR).
  answer = () => Promise.reject({ name: 'MKError', reason: 'UNAUTHORIZED_ERROR', message: '401', data: { status: 401 } })
  const refused = await am.checkDeveloperToken()
  assert.equal(refused.refused, true)
  assert.match(refused.error, /UNAUTHORIZED_ERROR/)
  // 403 is about the Music User Token; a network failure says nothing about either.
  for (const err of [{ reason: 'ACCESS_DENIED', data: { status: 403 } }, new TypeError('NetworkError when attempting to fetch resource.')]) {
    answer = () => Promise.reject(err)
    const r = await am.checkDeveloperToken()
    assert.equal(r.refused, false)
    assert.ok(r.error)
  }
})

// A document with the page's elements, which record what the page writes to them.
function fakeDocument() {
  const writes = []
  const element = (id) => ({
    get textContent() {
      return ''
    },
    set textContent(v) {
      writes.push(id)
    },
    set disabled(v) {
      writes.push(`${id}.disabled`)
    },
    addEventListener: noop,
  })
  const elements = { status: element('status'), log: element('log'), signin: element('signin') }
  return { writes, document: { getElementById: (id) => elements[id] ?? null, addEventListener: noop, body: { classList: { add: noop } } } }
}

// The hidden engine page does no DOM work: on macOS every repaint cost a parent frame even headless
// (#1). The sign-in page keeps its status and log.
test('in engine mode, render() and note() leave the DOM alone', async () => {
  const { writes, document } = fakeDocument()
  const { ctx, configure } = coldPage(fakeMusic({ state: S.playing }), { document })
  configure()
  vm.runInContext('render(); note("playbackStateDidChange", "paused → playing")', ctx)
  assert.deepEqual(writes, [])
  // The event is still reported.
  assert.equal(plain(ctx.snapshot()).lastEvents.at(-1).type, 'playbackStateDidChange')
})

test('the sign-in page still renders the status and the log', async () => {
  const { writes, document } = fakeDocument()
  const { ctx, configure } = coldPage(fakeMusic({ state: S.paused }), { document, location: { search: '?signin', reload: noop, replace: noop } })
  configure()
  vm.runInContext('render(); note("signin", "token accepted")', ctx)
  assert.deepEqual(writes, ['status', 'signin.disabled', 'log'])
})
