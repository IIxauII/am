// MusicKit JS v3 playback engine page. Browser-agnostic: the CLI drives it over SSE (/events)
// and it reports state back with POSTs, so the same page runs in Chrome or Firefox.
'use strict'

const params = new URLSearchParams(location.search)
const SIGNIN = params.has('signin')
const ENGINE = params.get('engine') // per-launch nonce from the CLI; on ?signin, the sign-in's
const LOAD = Math.random().toString(36).slice(2, 10) // per page load; a reload keeps the nonce
const events = [] // ring buffer of notable events, included in every report
let music = null
let ready = false // configured and, in engine mode, the Music User Token injected
let configureError = null
// The developer token MusicKit was configured with, as `tokenId` names it. MusicKit keeps it
// until the page reloads: it has no setter, and checks it with Apple only by using it.
let developerToken = null
// The Music User Token MusicKit last held, its id (`userTokenId`) and the hashing of it. Only
// the id goes in a report, never the token.
let userToken = { token: null, id: null, hashed: Promise.resolve() }
let subscription = { active: null, error: null }
let report = () => {}
// The user's autoplay choice. `am play <song>` turns MusicKit's autoplay off for its one song.
let autoplay = true
// What the current queue plays from, when MusicKit doesn't say: {type, id, name}.
let context = null
// The song on live radio, from MusicKit's timed metadata.
let timed = null
// The volume last set through setVolume, applied again whenever a queue starts.
let volume = null
// Live radio stopped by pause/stop: MusicKit's play() doesn't restart it, so resume queues it again.
// {id, name}: the station, and its name for the daemon's line while MusicKit names no item.
let stoppedLive = null
// A stop's seekToTime(0) that gave up can leave MusicKit `seeking` on paused media for good. The
// item then reports as paused (`reportedState`) until MusicKit leaves `seeking` or `userMoves`.
let stopSeekGaveUp = false
let moves = 0 // `userMoves` calls so far

// A load, seek, skip or jump is about to move MusicKit: from here on, what it shows is its own.
function userMoves() {
  stopSeekGaveUp = false
  moves++
}

const UPCOMING = 20 // queue items in every snapshot
const PAGE = 100 // tracks per API request; MusicKit's own setQueue stops at the first 100
const PREV_RESTART_SEC = 3
const MAX_SONGS = 300

function note(type, detail) {
  const entry = { t: new Date().toISOString().slice(11, 23), type, detail }
  events.push(entry)
  if (events.length > 200) events.shift()
  if (SIGNIN) {
    const log = document.getElementById('log')
    if (log) log.textContent = `${entry.t} ${type} ${detail ?? ''}\n` + log.textContent.slice(0, 5000)
  }
  report()
}

// The page must not look like Node: MusicKit disables playback when globalThis.process exists.
window.addEventListener('error', (e) => note('pageError', e.message))
window.addEventListener('unhandledrejection', (e) => note('unhandledRejection', errText(e.reason)))

function enumName(enumObj, value) {
  return Object.keys(enumObj ?? {}).find((k) => enumObj[k] === value && isNaN(k)) ?? (value == null ? null : String(value))
}

function snapshot() {
  const m = music
  const item = m?.nowPlayingItem
  const catalogMs = item?.attributes?.durationInMillis ?? item?.playbackDuration
  const audio = document.getElementById('apple-music-player') // created by MusicKit
  return {
    musicKitVersion: window.MusicKit?.version ?? null,
    configured: ready,
    configureError,
    developerToken,
    musicUserToken: userTokenId(),
    browserSupportsVideoDrm: m?.browserSupportsVideoDrm ?? null,
    isAuthorized: m?.isAuthorized ?? false,
    storefrontId: m?.storefrontId ?? null,
    previewOnly: m?.previewOnly ?? null,
    subscriptionActive: subscription.active,
    meError: subscription.error,
    playbackState: m ? enumName(MusicKit.PlaybackStates, reportedState(m)) : null,
    currentPlaybackTime: m?.currentPlaybackTime ?? null,
    currentPlaybackDuration: m?.currentPlaybackDuration ?? null,
    nowPlaying: item
      ? {
          id: item.id,
          title: item.title ?? item.attributes?.name,
          artist: item.artistName ?? item.attributes?.artistName,
          catalogDurationSec: catalogMs ? catalogMs / 1000 : null,
          // encryptedFull (3) is the proof of a full track; preview (1) is the silent 30 s fallback.
          playbackType: enumName(MusicKit.PlaybackType, item.playbackType),
          ...safe(() => nowPlayingExtra(m, item), {}),
        }
      : null,
    mediaElement: audio
      ? { blobSrc: (audio.currentSrc || audio.src || '').startsWith('blob:'), mediaKeys: !!audio.mediaKeys, paused: audio.paused }
      : null,
    userAgent: navigator.userAgent,
    webdriver: navigator.webdriver,
    engine: ENGINE,
    load: LOAD,
    lastEvents: events.slice(-15),
    loadPending: [...loads].some((l) => l.pending()),
    // MusicKit has dropped the item: this is what a resume restarts.
    stoppedLive,
    ...safe(() => playerState(m, item), {}),
  }
}

// MusicKit's state, but paused while a stop's seek that gave up keeps it `seeking` and nothing
// plays: the daemon and TUI would read `seeking` as a song starting. The playbackStateDidChange
// listener ends that too; this catches a snapshot before its event.
function reportedState(m) {
  const S = MusicKit.PlaybackStates
  if (stopSeekGaveUp && (m.playbackState !== S.seeking || m.isPlaying)) stopSeekGaveUp = false
  return stopSeekGaveUp ? S.paused : m.playbackState
}

// A snapshot must never throw: it is the report.
function safe(fn, fallback) {
  try {
    return fn()
  } catch (err) {
    return fallback
  }
}

// The catalog id of a queue or Now Playing item: library items and live radio have none of their own.
function catalogIdOf(item) {
  const a = item.attributes ?? {}
  return a.playParams?.catalogId ?? (item.isLibraryItem || item.isLiveRadioStation ? null : item.id ?? null)
}

function nowPlayingExtra(m, item) {
  const a = item.attributes ?? {}
  const live = !!item.isLiveRadioStation
  return {
    catalogId: catalogIdOf(item),
    album: item.albumName ?? a.albumName ?? null,
    artworkUrl: item.artwork?.url ?? a.artwork?.url ?? null,
    isLive: live,
    container: containerOf(item, m.nowPlayingItemIndex),
  }
}

// What the TUI shows besides the item: transport modes, the queue, what MusicKit allows.
function playerState(m, item) {
  if (!m) return {}
  const c = m.capabilities
  const live = !!item?.isLiveRadioStation
  return {
    nowPlayingIndex: m.nowPlayingItemIndex ?? -1,
    isPlaying: !!m.isPlaying,
    volume: typeof m.volume === 'number' ? m.volume : null,
    shuffle: enumName(MusicKit.PlayerShuffleMode, m.shuffleMode) ?? 'off',
    repeat: enumName(MusicKit.PlayerRepeatMode, m.repeatMode) ?? 'none',
    autoplay: !!m.autoplayEnabled,
    queue: queueSummary(m),
    capabilities: {
      pause: !!c?.canPause,
      seek: !!c?.canSeek,
      skipNext: !!c?.canSkipToNextItem,
      skipPrevious: !!c?.canSkipToPreviousItem,
      shuffle: !!c?.canSetShuffleMode,
      repeat: !!c?.canSetRepeatMode,
      editQueue: !!c?.canEditPlaybackQueue,
    },
    liveInfo: live && timed ? { title: timed.title ?? null, artist: timed.performer ?? null, album: timed.album ?? null } : null,
  }
}

function queueSummary(m) {
  const q = m.queue
  if (!q) return { position: -1, length: 0, upcoming: [] }
  const from = Math.max(q.position + 1, 0)
  return { position: q.position, length: q.length, upcoming: queueItems(q, from, UPCOMING) }
}

function queueItems(q, offset, limit) {
  return q.items.slice(offset, offset + limit).map((it, k) => itemSummary(q, it, offset + k))
}

function itemSummary(q, it, index) {
  const a = it.attributes ?? {}
  return {
    index,
    id: it.id ?? null,
    catalogId: catalogIdOf(it),
    title: it.title ?? a.name ?? null,
    // The performer: MediaItem.artistName is the composer for classical music.
    artist: a.artistName ?? it.artistName ?? null,
    album: it.albumName ?? a.albumName ?? null,
    durationSec: it.playbackDuration ? it.playbackDuration / 1000 : null,
    artworkUrl: it.artwork?.url ?? a.artwork?.url ?? null,
    autoplay: !!q.queueItem(index)?.isAutoplay,
  }
}

// What the queue was asked to play from; MusicKit's own container is no help for a queue built
// from tracks (its id is the song's), but names a station, and autoplay's station.
function containerOf(item, index) {
  const c = item.container
  const autoplayed = !!music?.queue?.queueItem(index)?.isAutoplay
  if (context && !autoplayed) return context.name || !c?.attributes?.name ? context : { ...context, name: c.attributes.name }
  if (c?.type) return { type: c.type, id: c.id ?? null, name: c.attributes?.name ?? null }
  return null
}

// The sign-in page's status. The engine page touches no DOM: nobody sees it, and on macOS every
// repaint cost the parent a frame even headless (about 60 wake-ups/s while playing, #1).
function render() {
  if (!SIGNIN) return
  const s = snapshot()
  const el = document.getElementById('status')
  if (!el) return
  const np = s.nowPlaying ? `${s.nowPlaying.title} — ${s.nowPlaying.artist} [${s.nowPlaying.playbackType}]` : '–'
  el.textContent = [
    `MusicKit:   ${s.configured ? `configured (v${s.musicKitVersion}), DRM: ${s.browserSupportsVideoDrm}` : s.configureError ?? 'loading…'}`,
    `Authorized: ${s.isAuthorized}  storefront: ${s.storefrontId ?? '–'}`,
    `State:      ${s.playbackState}  ${fmt(s.currentPlaybackTime)} / ${fmt(s.currentPlaybackDuration)}`,
    `Now:        ${np}`,
  ].join('\n')
  document.getElementById('signin').disabled = !s.configured
}

function fmt(sec) {
  if (sec == null || !isFinite(sec)) return '–:––'
  return `${Math.floor(sec / 60)}:${String(Math.floor(sec % 60)).padStart(2, '0')}`
}

function errText(e) {
  const err = e?.error ?? e
  return [err?.name, err?.errorCode, err?.reason, err?.message, err?.description].filter(Boolean).join(' | ') || String(err)
}

// The same gate MusicKit 3.2526.0 applies at configure() time; if this fails, MusicKit silently plays previews.
async function drmProbe() {
  const video = document.createElement('video')
  const result = {
    h264: video.canPlayType('video/mp4;codecs="avc1.42E01E"'),
    aac: video.canPlayType('audio/mp4;codecs="mp4a.40.2"'),
    mseAac: window.MediaSource?.isTypeSupported('audio/mp4;codecs="mp4a.40.2"') ?? false,
  }
  const config = [
    {
      initDataTypes: ['keyids', 'cenc'],
      distinctiveIdentifier: 'optional',
      persistentState: 'required',
      videoCapabilities: [{ contentType: 'video/mp4;codecs="avc1.42E01E"', robustness: 'SW_SECURE_CRYPTO' }],
      audioCapabilities: [{ contentType: 'audio/mp4;codecs="mp4a.40.2"' }],
    },
  ]
  try {
    const access = await navigator.requestMediaKeySystemAccess('com.widevine.alpha', config)
    await access.createMediaKeys()
    result.widevine = true
  } catch (err) {
    result.widevine = false
    result.widevineError = `${err.name}: ${err.message}`
  }
  return result
}

// Which developer token: its key and when it ends, for people reading the report, and the first
// 8 bytes of its SHA-256 in hex, which tells it from the one the daemon would hand out now (null
// when the browser can't hash). Nothing in it works as the token, and it never throws.
async function tokenId(token) {
  const part = (i) => {
    try {
      return JSON.parse(atob(token.split('.')[i].replace(/-/g, '+').replace(/_/g, '/'))) ?? {}
    } catch {
      return {}
    }
  }
  const { kid } = part(0)
  const { exp } = part(1)
  let hash = null
  try {
    const digest = new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(token)))
    hash = [...digest.slice(0, 8)].map((b) => b.toString(16).padStart(2, '0')).join('')
  } catch {}
  return { kid: typeof kid === 'string' ? kid : null, exp: Number.isInteger(exp) ? exp : null, hash }
}

function heldUserToken() {
  return safe(() => music?.musicUserToken || null, null)
}

// The id (`tokenId`) of the Music User Token MusicKit holds, for the daemon to compare with the
// stored one; null when MusicKit holds none, the browser can't hash, or the token is still being
// hashed. When MusicKit's token changed since the last hash, it starts a new hash and returns
// null, so a report never names a token MusicKit no longer holds.
function userTokenId() {
  if (heldUserToken() === userToken.token) return userToken.id
  hashUserToken()
  return null
}

// Hashes the Music User Token MusicKit holds, unless it is the one hashed last, then reports.
// Resolves once the id is ready.
function hashUserToken() {
  const token = heldUserToken()
  if (token === userToken.token) return userToken.hashed
  const named = { token, id: null, hashed: null }
  userToken = named
  named.hashed = (async () => {
    const id = token ? await tokenId(token) : null
    named.id = id?.hash ? id : null
    if (userToken === named) report()
  })()
  return named.hashed
}

async function configure() {
  try {
    // The token routes answer only the page of the current engine launch.
    const res = await fetch(`/developer-token?engine=${ENGINE}`)
    if (!res.ok) throw new Error(`developer token endpoint: HTTP ${res.status} ${await res.text()}`)
    const token = (await res.text()).trim()
    // Before configure(): from getInstance() on, nothing may wait until every listener is on.
    const id = await tokenId(token)
    await MusicKit.configure({
      developerToken: token,
      app: { name: 'am', build: '0.0.1' },
      bitrate: MusicKit.PlaybackBitrate.HIGH,
      suppressErrorDialog: true,
      // music.play() swallows most playback errors (no event, no rejection) once the error dialog is
      // suppressed; MusicKit's error log is the only trace. Its default level is ERROR.
      logHandler: (r) => note('mkError', `${r.message} ${(r.args ?? []).map(errText).join(' ')}`.slice(0, 400)),
    })
    music = MusicKit.getInstance()
    developerToken = id
    const E = MusicKit.Events
    const on = (name, fn) => music.addEventListener(E[name] ?? name, fn)
    on('authorizationStatusDidChange', () => note('authorizationStatusDidChange', `isAuthorized=${music.isAuthorized}`))
    on('playbackStateDidChange', (e) => {
      if (e.state !== MusicKit.PlaybackStates.seeking) stopSeekGaveUp = false
      note('playbackStateDidChange', `${enumName(MusicKit.PlaybackStates, e.oldState)} → ${enumName(MusicKit.PlaybackStates, e.state)}`)
    })
    on('nowPlayingItemDidChange', () => note('nowPlayingItemDidChange', music.nowPlayingItem?.title))
    on('mediaPlaybackError', (e) => note('mediaPlaybackError', errText(e)))
    on('drmUnsupported', () => note('drmUnsupported'))
    on('primaryPlayerDidChange', () => note('primaryPlayerDidChange'))
    on('playbackTimeDidChange', render)
    // The TUI shows these; each sends a fresh report.
    for (const name of [
      'queueItemsDidChange',
      'queuePositionDidChange',
      'repeatModeDidChange',
      'shuffleModeDidChange',
      'playbackVolumeDidChange',
      'capabilitiesChanged',
      'autoplayEnabledDidChange',
    ])
      on(name, () => report())
    on('nowPlayingItemWillChange', () => (timed = null))
    on('timedMetadataDidChange', (md) => {
      timed = md ?? null
      note('timedMetadata', `${md?.title ?? '?'} — ${md?.performer ?? '?'}`)
    })
    if (!SIGNIN) {
      // The CLI owns the Music User Token (~/.config/am); inject it so sign-in can happen in any browser.
      const stored = await fetch(`/user-token?engine=${ENGINE}`)
      const token = stored.status === 200 ? (await stored.text()).trim() : null
      if (token && music.musicUserToken !== token) music.musicUserToken = token
      // Setting the token doesn't load the account: without this, MusicKit's storefront stays 'us'
      // until the first play. It also tells us whether the subscription is active (else: previews).
      if (music.isAuthorized) {
        try {
          subscription.active = !!(await music.me())?.subscription?.active
        } catch (err) {
          subscription.error = errText(err)
        }
      }
      // As the Apple Music app does; it also keeps a queue from running into MusicKit's stop().
      music.autoplayEnabled = autoplay
    }
    // Before the page says configured: the daemon decides on that report whether the page has
    // the stored Music User Token.
    await hashUserToken()
    ready = true
    note('configured', `isAuthorized=${music.isAuthorized} drm=${music.browserSupportsVideoDrm} storefront=${music.storefrontId}`)
  } catch (err) {
    configureError = errText(err)
    note('configureError', configureError)
  }
  render()
}

async function signIn() {
  try {
    const token = await music.authorize()
    if (!token) throw new Error('authorize() returned no token (cancelled?)')
    // Named before it is posted: the daemon looks at the page once it has stored the token.
    await hashUserToken()
    const res = await fetch(`/user-token?engine=${ENGINE}`, { method: 'POST', body: JSON.stringify({ token }) })
    const r = await res.json()
    note('signin', r.ok ? `token accepted, storefront ${r.storefront}` : `Apple rejected the token (HTTP ${r.status}); click again`)
    if (r.ok && SIGNIN) document.getElementById('done').hidden = false
    // authorize() returns any stored token without asking Apple, so drop a rejected one first.
    if (!r.ok) await music.unauthorize()
  } catch (err) {
    note('authorizeError', errText(err))
  }
}

const configured = () => !!music && ready

function requireMusic() {
  if (!configured()) throw new Error('MusicKit is not configured yet')
  return music
}

// `requireMusic` for the play entry points: on a cold page, a play older than a stop that
// succeeded answers STOPPED_BEFORE_START first, as `load` answers it on a configured one.
function requireMusicFor(gen) {
  if (!configured() && Number.isInteger(gen) && gen < cancelledBelow) throw { message: STOPPED_BEFORE_START }
  return requireMusic()
}

function isLive() {
  return !!music?.nowPlayingItem?.isLiveRadioStation
}

// Station queues (continuous) can't be edited, shuffled or repeated, and never run out.
function isStationQueue() {
  return music?.playbackController?.type === 'continuous'
}

const containerPaths = {
  albums: (id) => `/v1/catalog/{{storefrontId}}/albums/${encodeURIComponent(id)}/tracks`,
  playlists: (id) => `/v1/catalog/{{storefrontId}}/playlists/${encodeURIComponent(id)}/tracks`,
  'library-albums': (id) => `/v1/me/library/albums/${encodeURIComponent(id)}/tracks`,
  'library-playlists': (id) => `/v1/me/library/playlists/${encodeURIComponent(id)}/tracks`,
}

// All of a container's tracks, PAGE at a time (MusicKit's setQueue({playlist}) stops at 100).
// `check` (a load's) runs after each page.
async function containerTracks(type, id, check) {
  const path = containerPaths[type]
  if (!path) throw new Error(`unknown container type ${type}`)
  let next = { path: path(id), query: { limit: PAGE } }
  const tracks = []
  for (let page = 0; next && page < 200; page++) {
    const res = await music.api.music(next.path, next.query)
    await check?.()
    const body = res?.data
    tracks.push(...(body?.data ?? []))
    next = null
    if (body?.next) {
      const url = new URL(body.next, 'https://api.music.apple.com')
      const query = Object.fromEntries(url.searchParams)
      next = { path: url.pathname, query: { limit: PAGE, ...query } }
    }
  }
  return tracks
}

// Songs only: a music video would play as video in a headless engine.
function playable(resource) {
  const p = resource?.attributes?.playParams
  return !!p && (p.kind === 'song' || resource.type === 'songs' || resource.type === 'library-songs')
}

// The MusicKit setQueue options for a {songs} or {container} request, the ids in queue order,
// and where to start in them.
async function descriptor(req, check) {
  if (req.songs) {
    if (!Array.isArray(req.songs) || req.songs.length === 0) throw new Error('no songs given')
    if (req.songs.length > MAX_SONGS) throw new Error(`more than ${MAX_SONGS} songs`)
    return { opts: { songs: req.songs.map(String) }, ids: req.songs.map(String), byIndex: req.songs.map(String), ctx: null }
  }
  if (req.container) {
    const { type, id, name } = req.container
    const all = await containerTracks(type, id, check)
    const tracks = all.filter(playable)
    if (tracks.length === 0) throw new Error(`no playable tracks in ${type} ${id}`)
    // startIndex counts every track the API lists, playable or not: an unplayable one starts at
    // the next playable one. One pass from the end.
    const byIndex = new Array(all.length)
    let after = null
    for (let i = all.length - 1; i >= 0; i--) {
      if (playable(all[i])) after = all[i].id
      byIndex[i] = after
    }
    return { opts: { items: tracks }, ids: tracks.map((t) => t.id), byIndex, ctx: { type, id, name: name ?? null } }
  }
  throw new Error('expected songs or container')
}

// Replaces the queue and plays it. MusicKit quirks handled here: shuffle moves the start item to
// index 0 without moving the queue position, so the position is put back on it by id; and
// startWith takes a numeric string as an index, so it always gets the index.
async function loadAndPlay(req, d, { check, playing, takeMusic }) {
  await takeMusic()
  const startGiven = req.startId != null || req.startIndex != null
  let startId = req.startId ?? null
  if (startId == null) {
    let i = req.startIndex ?? 0
    if (req.shuffle && !startGiven) i = Math.floor(Math.random() * d.byIndex.length)
    startId = d.byIndex[i] ?? null
  }
  const opts = { ...d.opts, startWith: Math.max(0, d.ids.indexOf(startId)) }
  if (req.shuffle !== undefined) opts.shuffleMode = req.shuffle ? MusicKit.PlayerShuffleMode.songs : MusicKit.PlayerShuffleMode.off
  if (req.repeat !== undefined) opts.repeatMode = MusicKit.PlayerRepeatMode[req.repeat]
  music.autoplayEnabled = autoplay
  context = d.ctx
  stoppedLive = null
  await music.setQueue(opts)
  await check()
  const q = music.queue
  if (q && startId != null) {
    const i = q.indexForItem(startId)
    if (i >= 0 && i !== q.position) q.position = i
  }
  keepVolume()
  const late = []
  await settle(late, 'play()', playing(music.play()), START_MS)
  await check()
  if (typeof req.startTime === 'number' && req.startTime > 0) await settle(late, `seekToTime(${req.startTime})`, music.seekToTime(req.startTime), START_MS)
  return answer(late)
}

// A new player may start at its default volume.
function keepVolume() {
  if (volume != null && music.volume !== volume) music.volume = volume
}

// MusicKit's pause() and play() can resolve before its playback state moves; a snapshot taken at
// once would show the old state. Waits up to `ms` for `check`.
async function until(check, ms = 1000) {
  for (let t = 0; t < ms && !check(); t += 50) await new Promise((resolve) => setTimeout(resolve, 50))
}

const playing = () => music.isPlaying
const notPlaying = () => !music.isPlaying

// How long a page call waits on a MusicKit step that can stay pending. A call that never answers
// holds its daemon request for the daemon's whole timeout (10 s for the transport controls).
// Every pause, seek, skip, jump, stop and play is bounded. Loading a queue (setQueue,
// setStationQueue, playNext, playLater and the API reads before them) is not, except re-queuing
// stopped live radio on resume: it reads from Apple and may take long for a big container, under
// the daemon's 60-120 s timeouts for those calls.
const SETTLE_MS = 2000
// For steps that start an item (play, resume, skip, jump, a start time): they may fetch a licence
// or audio first.
const START_MS = 5000

// Waits for a MusicKit promise at most `ms`; true if it settled, false if it gave up. Some never
// settle (musickit.js 3.2526.0): its buffered seek resolves only once the target time is buffered
// again, and pause() first waits for a pending play(). `am stop` on a song paused at 0:12 never
// answered (2026-10-20). Giving up doesn't cancel the step; MusicKit may still finish it later.
// Each give-up goes into `late`, which the answer carries as `gaveUp` for the daemon's log, and
// into the page's events. A rejection still throws.
async function settle(late, what, promise, ms = SETTLE_MS) {
  let timer
  const gaveUp = new Promise((resolve) => (timer = setTimeout(resolve, ms, false)))
  try {
    if (await Promise.race([Promise.resolve(promise).then(() => true), gaveUp])) return true
  } finally {
    clearTimeout(timer)
  }
  const line = `${what} after ${ms / 1000} s`
  late.push(line)
  note('gaveUp', line)
  return false
}

// A method's answer: the snapshot, plus what it gave up waiting on, if anything.
function answer(late) {
  const s = snapshot()
  return late.length ? { ...s, gaveUp: late } : s
}

// Nothing plays, nor is about to: no pause() needed (and none to wait on).
function atRest() {
  const S = MusicKit.PlaybackStates
  return [S.none, S.paused, S.stopped, S.ended, S.completed].includes(music.playbackState)
}

async function pauseNow(late) {
  if (!atRest()) await settle(late, 'pause()', music.pause())
}

// Before MusicKit names the item (a cancelled restart), the station stays the one to restart.
async function stopLive(late) {
  const item = music.nowPlayingItem
  if (item?.id != null) stoppedLive = { id: item.id, name: item.title ?? item.attributes?.name ?? context?.name ?? null }
  await settle(late, 'stop()', music.stop())
}

// Before a station. As a station replaces a song, MusicKit stop()s the song's player, and on a
// song past 0:00 (playing, or paused mid-way) that keeps Firefox at ~120 % CPU until a page reload
// or the next song (macOS, Firefox 159). On one paused at 0:00, as `am stop` leaves it, it doesn't.
// So a loaded song is paused and rewound first, as a stop does it and within its bounds. Live radio
// plays in a player of its own and can't pause. A give-up doesn't fail the station: it goes into
// `late`, and a song still playing after the pause isn't sought; the station replaces it as before.
async function rewindSong(late) {
  if (!music.nowPlayingItem || isLive()) return
  await pauseNow(late)
  await until(notPlaying)
  if (!music.isPlaying && music.currentPlaybackTime !== 0) await settle(late, 'seekToTime(0)', music.seekToTime(0))
}

// A pause or stop that leaves MusicKit playing failed, whatever its steps answered: it throws, with
// what it gave up on first (the daemon logs page errors that start "gave up waiting on").
function requireSilent(late, step) {
  if (!music.isPlaying) return
  throw new Error(late.length ? `gave up waiting on ${late.join(', ')}; MusicKit still plays` : `MusicKit still plays after ${step}`)
}

// A reloaded or relaunched page has an empty queue. Play and toggle then fail with exactly this
// text, which the daemon turns into engine-not-running, so the TUI queues its music again.
const NOTHING_QUEUED = 'nothing-queued'

const hasQueue = () => music?.queue?.length > 0

function requireQueue() {
  if (!stoppedLive && !hasQueue()) throw { message: NOTHING_QUEUED }
}

function checkIndex(index) {
  const q = music.queue
  if (!q || !Number.isInteger(index) || index < 0 || index >= q.length) throw new Error(`no queue item ${index}`)
  return q
}

// A stop while a queue loads (the API reads, setQueue, play()) cancels it: until then nothing is
// loaded, so the stop has nothing to pause, and the song would start a second or two later. A
// load fails with exactly this text, which the daemon answers as stopped, not as an error.
const STOPPED_BEFORE_START = 'stopped before it started'
// One cancel generation, the daemon's (src/daemon/host.zig `Plays`): every play call carries
// the generation it took, and a stop the one it took. A stop that succeeds cancels every load
// of an older generation, here or still on its way here; a load begun after the stop has the
// stop's generation, so that stop never cancels it, however long it takes.
let cancelledBelow = 0
const stopsInFlight = new Set() // stops still running: a load waits for their outcome
const loads = new Set() // loads in flight
let loadSeq = 0 // loads begun, so a cancelled one knows whether a newer one has begun since
let lastPlayed = 0 // the newest load (its seq) that sent play()
const silencing = new Set() // cancelled loads' silences still running (`silence`)

// Runs a load of generation `gen` (none: as new as the last stop). It checks at its start and
// hands `fn` a ctx whose `check` it awaits after each MusicKit step: it throws once a stop that
// began after the load began has succeeded. A stop still running is waited for first, so only
// one that succeeds cancels (one that fails leaves the music playing, and the load carries on).
// `playing(promise, live)` sends play() through: it can stay pending for seconds (live radio
// loads its stream in it), so a stop that cancels the load meanwhile doesn't wait for it. A
// cancelled load whose play() was sent silences the music at once and again should play() start
// it later, unless a newer load has taken the music since (`takeMusic`, which a load awaits right
// before its first setQueue, setStationQueue or play()). While a newer load only reads from
// Apple, the music is still the cancelled load's to silence. A new load waits a moment for
// cancelled ones to end, so their last step doesn't land on its queue, and again for their
// silences, so that none lands on its music.
// An insert (play-next/later) runs here too, with `asInsert`. It reads its songs first, and is a
// load only while the queue it would add to is empty (`cancellable`). It then either adds to the
// queue, which is no load, or calls `begin` and starts the queue, as a load like any other. It
// takes its seq in `begin`: an insert that only adds is no newer load.
async function load(gen, fn, asInsert = false) {
  let done, wake
  const self = {
    gen: Number.isInteger(gen) ? gen : cancelledBelow,
    seq: asInsert ? 0 : ++loadSeq,
    // 'loading'; an insert is 'reading' until it decides, then 'adding' or 'loading'.
    phase: asInsert ? 'reading' : 'loading',
    stopped: false, // a stop cancelled it while it was cancellable
    played: false,
    live: false,
    tookMusic: false, // has taken the music (`takeMusic`)
    ended: new Promise((r) => (done = r)),
    woken: new Promise((r) => (wake = r)),
    cancellable: () => self.phase === 'loading' || (self.phase === 'reading' && !hasQueue()),
    cancelled: () => self.stopped || (self.gen < cancelledBelow && self.cancellable()),
    // A load a stop can still cancel: what `loadPending` reports.
    pending: () => self.cancellable() && !self.cancelled(),
    // A stop cancels it, and wakes it from its waits.
    cancel: () => {
      self.stopped = true
      wake()
    },
    // The music is still this load's to silence.
    mine: () => lastPlayed === self.seq && ![...loads].some((l) => l.seq > self.seq && l.tookMusic),
  }
  loads.add(self)
  const check = async () => {
    while (stopsInFlight.size) await Promise.allSettled([...stopsInFlight])
    if (!self.cancelled()) return
    if (self.played && self.mine()) await silence(self.live)
    throw { message: STOPPED_BEFORE_START }
  }
  const playing = (promise, live = false) => {
    self.played = true
    self.live = live
    lastPlayed = Math.max(lastPlayed, self.seq)
    Promise.resolve(promise).then(
      () => {
        if (!loads.has(self) && self.cancelled() && self.mine()) silence(self.live)
      },
      () => {},
    )
    return Promise.race([promise, self.woken])
  }
  const begin = async () => {
    if (asInsert) self.seq = ++loadSeq
    self.phase = 'loading'
    const draining = [...loads].filter((l) => l !== self && l.cancelled()).map((l) => l.ended)
    if (draining.length) {
      await settle([], 'the cancelled loads', Promise.all(draining))
      await check()
    }
    userMoves()
  }
  // Bounded, as `begin` is: past the bound a late pause may still land on this load's music. One
  // wait is enough: a silence that starts during it needs an earlier bounded wait to have given up.
  const takeMusic = async () => {
    if (silencing.size) {
      await settle([], 'the cancelled loads\' silences', Promise.all(silencing))
      await check()
    }
    self.tookMusic = true
  }
  try {
    await check()
    if (!asInsert) await begin()
    return await fn({ check, playing, takeMusic, self, begin })
  } finally {
    loads.delete(self)
    done()
  }
}

// What a cancelled load started stops again: live radio with stop() (`live`: it was, though
// MusicKit may name no item yet), anything else paused. A failure is noted, not thrown. In
// `silencing` until it ends.
function silence(live) {
  const s = (async () => {
    const late = []
    if (live || isLive()) await stopLive(late)
    else await pauseNow(late)
    await until(notPlaying)
  })()
    .catch((err) => note('silenceFailed', errText(err)))
    .finally(() => silencing.delete(s))
  silencing.add(s)
  return s
}

// playNext/playLater: with nothing queued they start playing, so they're a load; adding to a
// queue starts nothing, so a stop doesn't cancel that. Each runs in `load` from its start: while
// the queue is empty, its API read shows as loadPending and a stop cancels it between pages. Inserts decide in the order they arrived, each once the one before it ended and
// no load is under way: concurrent ones on an empty queue start one queue, the first, and add the
// others to it in order.
let insertTurn = Promise.resolve() // the last insert's end, once those before it ended too

async function insert(req, gen, add) {
  const turn = insertTurn
  let release
  insertTurn = new Promise((r) => (release = r))
  try {
    return await load(
      gen,
      async (ctx) => {
        const { check, self, begin } = ctx
        const d = await descriptor(req, check)
        // A stop that cancels it wakes it from these waits.
        await Promise.race([turn, self.woken])
        await check()
        for (;;) {
          const underWay = [...loads].filter((l) => l !== self && l.phase === 'loading' && !l.cancelled()).map((l) => l.ended)
          if (!underWay.length) break
          await Promise.race([Promise.allSettled(underWay), self.woken])
          await check()
        }
        if (hasQueue()) {
          self.phase = 'adding'
          await add(d.opts)
          return snapshot()
        }
        await begin()
        return loadAndPlay({}, d, ctx)
      },
      true,
    )
  } finally {
    turn.then(release)
  }
}

// Methods the daemon may call (also handy from DevTools). Each returns a snapshot or plain JSON.
const am = {
  snapshot,
  drmProbe,
  // Whether Apple refuses the developer token MusicKit was configured with. MusicKit only finds
  // out by using it: a refused one signs the page out on its next account check, without an
  // event, and plays fall back to previews. api.music() is the one call that answers with the
  // HTTP status: 401 is the developer token, 403 the Music User Token.
  async checkDeveloperToken() {
    requireMusic()
    try {
      await music.api.music(`/v1/storefronts/${music.storefrontId || 'us'}`)
      note('developerTokenCheck', 'accepted')
      return { refused: false }
    } catch (err) {
      const refused = err?.reason === 'UNAUTHORIZED_ERROR' || err?.data?.status === 401
      note('developerTokenCheck', `${refused ? 'refused' : 'unknown'}: ${errText(err)}`)
      return { refused, error: errText(err) }
    }
  },
  // `am play <song>`: that song alone, without autoplay after it. With no song: resume. `gen`
  // here and below: the play's cancel generation (`load`).
  async play(songId, gen) {
    requireMusicFor(gen)
    if (songId == null) {
      requireQueue()
      return am.resume(gen)
    }
    note('play', songId)
    return load(gen, async ({ check, playing, takeMusic }) => {
      await takeMusic()
      music.autoplayEnabled = false
      context = null
      stoppedLive = null
      await music.setQueue({ song: songId })
      await check()
      keepVolume()
      const late = []
      await settle(late, 'play()', playing(music.play()), START_MS)
      await check()
      return answer(late)
    })
  },
  // req: {songs:[id…]} | {container:{type, id, name?}} | {station: id} | {stationFor:{song|artist: id}},
  // plus startIndex, startId, startTime (s), shuffle (bool), repeat ('none'|'one'|'all'), volume (0..1).
  async playQueue(req, gen) {
    requireMusicFor(gen)
    note('playQueue', JSON.stringify(req).slice(0, 200))
    // Before play(): a new page would start at full volume.
    if (typeof req.volume === 'number') volume = Math.min(1, Math.max(0, req.volume))
    return load(gen, async (ctx) => {
      const { check, playing, takeMusic } = ctx
      if (req.station || req.stationFor) {
        // Before the rewind: a request that can't play leaves the song alone.
        if (!req.station && !req.stationFor.song && !req.stationFor.artist) throw new Error('stationFor needs a song or an artist')
        await takeMusic()
        const late = []
        await rewindSong(late)
        await check()
        music.autoplayEnabled = autoplay
        stoppedLive = null
        if (req.station) {
          context = { type: 'stations', id: req.station, name: null }
          await music.setQueue({ station: req.station })
        } else {
          const [kind, id] = req.stationFor.song ? ['song', req.stationFor.song] : ['artist', req.stationFor.artist]
          context = null
          await music.setStationQueue({ [kind]: id })
        }
        await check()
        keepVolume()
        await settle(late, 'play()', playing(music.play()), START_MS)
        await check()
        return answer(late)
      }
      const d = await descriptor(req, check)
      await check()
      return loadAndPlay(req, d, ctx)
    })
  },
  async toggle(gen) {
    requireMusicFor(gen)
    if (music.isPlaying) return am.pause()
    requireQueue()
    return am.resume(gen)
  },
  // Live radio can't pause; it stops.
  async pause() {
    requireMusic()
    const late = []
    const live = isLive()
    if (live) await stopLive(late)
    else await pauseNow(late)
    await until(notPlaying)
    requireSilent(late, live ? 'stop()' : 'pause()')
    return answer(late)
  },
  // Continues the loaded item where it was, without re-queuing it (live radio excepted).
  async resume(gen) {
    requireMusicFor(gen)
    const late = []
    if (stoppedLive && !music.isPlaying) {
      const station = stoppedLive
      stoppedLive = null
      // MusicKit's play() doesn't restart live radio: it is queued again and played, in one bound.
      // It's a load of the resume's generation: past the bound it carries on, and a stop
      // meanwhile still cancels it. Cancelled (at any step, its start included), the station
      // stays the one a resume restarts, unless a newer load has begun since.
      let awaited = true
      const seq = loadSeq + 1 // the restart's (`load` takes it at once)
      const restart = load(gen, async ({ check, playing, takeMusic }) => {
        await takeMusic()
        await music.setQueue({ station: station.id })
        await check()
        keepVolume()
        await playing(music.play(), true)
        await check()
      })
      // Past the bound nobody awaits it: a late failure lands here, not as an unhandled
      // rejection, and only that one is noted (within it, the resume fails with it; a cancel
      // is no failure). Registered first, so the station is back before the resume answers.
      restart.catch((err) => {
        if (errText(err) === STOPPED_BEFORE_START) {
          if (loadSeq === seq) stoppedLive ??= station
        } else if (!awaited) note('restartFailed', errText(err))
      })
      awaited = await settle(late, 'setQueue({station}) and play()', restart, START_MS)
    } else {
      // A load too: a stop that took a newer generation than this resume's, here first or
      // while its play() is pending, keeps the music from starting.
      await load(gen, async ({ check, playing, takeMusic }) => {
        await takeMusic()
        await settle(late, 'play()', playing(music.play()), START_MS)
        await check()
      })
    }
    await until(playing)
    return answer(late)
  },
  // Not music.stop(): after it, Firefox's content process and Widevine helper often keep messaging
  // each other at ~120 % CPU (macOS, Firefox 158 and 159) until a page reload, the next song or the
  // engine's close. The song stays loaded.
  // Live radio has no pause, so it does stop.
  // Every wait is bounded (at most about 5 s in all). Still playing after the pause, it fails with
  // the reason and doesn't seek. Silent, it answers as stopped: paused at 0:00 when the seek lands,
  // else paused where it was. Paused is silent, which is what stop is for; failing it over the
  // position would leave a stop that can't succeed until the engine closes. A seek that lands
  // late still rewinds; one that gave up reports paused meanwhile (`reportedState`). At 0:00
  // already, it doesn't seek. With the stop's generation `gen`, it then cancels every older load
  // (`load`), and answers once those still in flight here ended (they silence what they started;
  // at most 2 s more, under the daemon's 10 s), counting them as `cancelled`.
  // Before MusicKit is configured (a cold engine), nothing has started: every play call needs it
  // (`requireMusicFor`), so no load runs and nothing plays. The stop succeeds there without
  // touching MusicKit and raises the cancel floor for a play older than it that gets here later:
  // still cold, the play answers STOPPED_BEFORE_START; configured by then, `load` cancels it as
  // after any stop.
  async stop(gen) {
    if (!configured()) {
      if (Number.isInteger(gen)) cancelledBelow = Math.max(cancelledBelow, gen)
      return { ...snapshot(), cancelled: 0 }
    }
    let cancelled = []
    const run = (async () => {
      const late = []
      if (isLive()) {
        await stopLive(late)
        await until(notPlaying)
        requireSilent(late, 'stop()')
      } else {
        await pauseNow(late)
        await until(notPlaying)
        requireSilent(late, 'pause()')
        if (music.nowPlayingItem && music.currentPlaybackTime !== 0) {
          const before = moves
          const landed = await settle(late, 'seekToTime(0)', music.seekToTime(0))
          // A call that moved MusicKit meanwhile owns what it shows now.
          if (!landed && moves === before) stopSeekGaveUp = true
        }
      }
      if (Number.isInteger(gen) && gen > cancelledBelow) {
        // An insert that adds to a queue is no load: a stop leaves it alone.
        cancelled = [...loads].filter((l) => l.gen < gen && l.pending())
        cancelledBelow = gen
        for (const l of cancelled) l.cancel()
      }
      return late
    })()
    stopsInFlight.add(run)
    let late
    try {
      late = await run
    } finally {
      stopsInFlight.delete(run)
    }
    // Not while in stopsInFlight: the loads wait for that to empty before they look.
    if (cancelled.length) await settle(late, 'the cancelled loads', Promise.all(cancelled.map((l) => l.ended)))
    return { ...answer(late), cancelled: cancelled.length }
  },
  async next() {
    requireMusic()
    if (!music.capabilities.canSkipToNextItem) return snapshot()
    const q = music.queue
    // On the last item MusicKit would stop() (the CPU-spin path above): pause at 0:00 instead.
    const last = q && q.nextPlayableItemIndex === -1
    if (last && !isStationQueue() && music.repeatMode === MusicKit.PlayerRepeatMode.none) return am.stop()
    const late = []
    userMoves()
    await settle(late, 'skipToNextItem()', music.skipToNextItem(), START_MS)
    return answer(late)
  },
  // More than 3 s in: back to the start of this track, as music apps do.
  async prev() {
    requireMusic()
    const late = []
    const c = music.capabilities
    if (c.canSeek && (music.currentPlaybackTime > PREV_RESTART_SEC || !c.canSkipToPreviousItem)) {
      userMoves()
      await settle(late, 'seekToTime(0)', music.seekToTime(0))
    } else if (c.canSkipToPreviousItem) {
      userMoves()
      await settle(late, 'skipToPreviousItem()', music.skipToPreviousItem(), START_MS)
    }
    return answer(late)
  },
  async seek(seconds) {
    requireMusic()
    const late = []
    const to = Math.max(0, Number(seconds) || 0)
    if (music.capabilities.canSeek) {
      userMoves()
      await settle(late, `seekToTime(${to})`, music.seekToTime(to))
    }
    return answer(late)
  },
  async seekBy(delta) {
    requireMusic()
    return am.seek((music.currentPlaybackTime ?? 0) + (Number(delta) || 0))
  },
  setVolume(v) {
    requireMusic()
    volume = Math.min(1, Math.max(0, Number(v) || 0))
    music.volume = volume
    return snapshot()
  },
  setShuffle(on) {
    requireMusic()
    music.shuffleMode = on ? MusicKit.PlayerShuffleMode.songs : MusicKit.PlayerShuffleMode.off
    return snapshot()
  },
  setRepeat(mode) {
    requireMusic()
    const value = MusicKit.PlayerRepeatMode[mode]
    if (value === undefined) throw new Error(`unknown repeat mode ${mode}`)
    music.repeatMode = value
    return snapshot()
  },
  setAutoplay(on) {
    requireMusic()
    autoplay = !!on
    music.autoplayEnabled = autoplay
    return snapshot()
  },
  async jump(index) {
    requireMusic()
    checkIndex(index)
    const late = []
    userMoves()
    await settle(late, `changeToMediaAtIndex(${index})`, music.changeToMediaAtIndex(index), START_MS)
    return answer(late)
  },
  // req: {songs:[…]} or {container:{type, id}}. With nothing queued, they start playing.
  async playNext(req, gen) {
    requireMusicFor(gen)
    return insert(req, gen, (opts) => music.playNext(opts))
  },
  // Adds before autoplay's items, after the user's own.
  async playLater(req, gen) {
    requireMusicFor(gen)
    return insert(req, gen, (opts) => music.playLater(opts))
  },
  removeAt(index) {
    requireMusic()
    const q = checkIndex(index)
    if (index === q.position) throw new Error('the playing item cannot be removed')
    q.splice(index, 1)
    return snapshot()
  },
  // Everything after the current item; autoplay refills its part.
  clearUpcoming() {
    requireMusic()
    music.queue?.clearAfterCurrent()
    return snapshot()
  },
  // A window of the queue, for scrolling it without bloating every report.
  queueWindow(offset, limit) {
    requireMusic()
    const q = music.queue
    if (!q) return null
    const from = Math.max(0, Math.floor(Number(offset) || 0))
    const count = Math.min(200, Math.max(0, Math.floor(Number(limit) || 0)))
    return { position: q.position, length: q.length, items: queueItems(q, from, count) }
  },
  reload: () => setTimeout(() => location.reload(), 100),
}
window.am = am

function connect() {
  const source = new EventSource(`/events?engine=${ENGINE}`)
  source.onmessage = async (msg) => {
    const { id, method, args } = JSON.parse(msg.data)
    let reply
    try {
      reply = { id, ok: true, value: await am[method](...args) }
    } catch (err) {
      reply = { id, ok: false, error: errText(err) }
    }
    fetch('/result', { method: 'POST', body: JSON.stringify(reply) })
  }
  let last = 0
  let trailing = null
  report = () => {
    // At most ~4 reports a second; one inside the 250 ms is sent at its end, so a burst of
    // events always ends with a fresh report. The interval below sends one every second.
    const wait = 250 - (Date.now() - last)
    if (wait > 0) {
      trailing ??= setTimeout(() => {
        trailing = null
        report()
      }, wait)
      return
    }
    last = Date.now()
    fetch('/report', { method: 'POST', body: JSON.stringify(snapshot()), keepalive: true }).catch(() => {})
  }
  setInterval(report, 1000)
}

// Engine pages must hold the current launch nonce; a stale restored copy unloads itself.
const claimed = SIGNIN ? Promise.resolve(false) : fetch(`/claim?engine=${ENGINE}`).then((r) => r.status === 204)

document.addEventListener('musickitloaded', async () => {
  if (!SIGNIN) {
    if (!(await claimed)) return location.replace('about:blank')
    // Firefox fetches its Widevine CDM on the first request (5-20 s on a new profile). Do that before
    // configure(), which decides DRM support once and would otherwise settle for previews on a timeout.
    const probe = await drmProbe()
    note('drmProbe', probe.widevine ? 'widevine ok' : probe.widevineError)
  }
  await configure()
})

document.addEventListener('DOMContentLoaded', async () => {
  render()
  document.getElementById('signin').addEventListener('click', signIn)
  if (SIGNIN) document.body.classList.add('signin')
  else if (await claimed) connect()
})
