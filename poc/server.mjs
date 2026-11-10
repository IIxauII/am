// Local server for the engine page, and the only channel between the CLI and the browser:
// commands go to the page over Server-Sent Events, state comes back over a WebSocket and
// results as POSTs. No browser automation protocol is involved, so any browser that runs the
// page works.
import { createHash } from 'node:crypto'
import { createServer } from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname, join } from 'node:path'
import { api, readUserToken, saveUserToken } from './api.mjs'
import { PORT } from './config.mjs'
import { getDeveloperToken } from './token.mjs'

const WEB_DIR = join(import.meta.dirname, 'web')
const TYPES = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8' }
const FILES = new Set(['/index.html', '/app.js'])

async function readJson(req) {
  let body = ''
  for await (const chunk of req) body += chunk
  return JSON.parse(body)
}

export async function startServer() {
  let session = null // nonce of the engine launch we expect; pages with another one are stale
  const listeners = { report: new Set(), signin: new Set() }
  const pending = new Map() // command id -> { resolve, reject, timer }
  const streams = new Set() // open SSE responses (one per engine page)
  let nextId = 1
  let lastReport = null
  let lastReportAt = 0

  function settle(id, fn, value) {
    const p = pending.get(id)
    if (!p) return
    pending.delete(id)
    clearTimeout(p.timer)
    p[fn](value)
  }

  // Refuse DNS-rebinding requests: only loopback host names may talk to the engine.
  const hostAllowed = (req) => /^(localhost|127\.0\.0\.1|\[::1\]):\d+$/.test(req.headers.host ?? '')

  // A report from the current page; one from another launch's is stale.
  function takeReport(report) {
    if (report?.engine !== session) return false
    lastReport = report
    lastReportAt = Date.now()
    for (const fn of listeners.report) fn(lastReport)
    return true
  }

  // The page's report socket (`/reports?engine=<nonce>`): each message is a report. A minimal
  // WebSocket: it reads the page's masked frames and joins fragments, and sends only a pong for
  // a ping and a close for a close or another launch's report.
  function upgrade(req, socket) {
    const url = new URL(req.url, 'http://x')
    const key = req.headers['sec-websocket-key']
    const refuse = (status) => socket.end(`HTTP/1.1 ${status}\r\nConnection: close\r\n\r\n`)
    if (!hostAllowed(req)) return refuse('403 Forbidden')
    if (url.pathname !== '/reports' || !key) return refuse('404 Not Found')
    if (!session || url.searchParams.get('engine') !== session) return refuse('409 Conflict')
    const accept = createHash('sha1').update(key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`)
    const frame = (opcode, payload) => socket.write(Buffer.concat([Buffer.from([0x80 | opcode, payload.length]), payload]))
    let input = Buffer.alloc(0)
    let fragments = []
    socket.on('error', () => {})
    socket.on('data', (chunk) => {
      input = Buffer.concat([input, chunk])
      while (input.length >= 2) {
        let len = input[1] & 0x7f
        let at = 2
        if (len === 126) [len, at] = input.length < 4 ? [Infinity, 4] : [input.readUInt16BE(2), 4]
        else if (len === 127) [len, at] = input.length < 10 ? [Infinity, 10] : [Number(input.readBigUInt64BE(2)), 10]
        if (input.length < at + 4 + len) return
        const mask = input.subarray(at, at + 4)
        const payload = input.subarray(at + 4, at + 4 + len).map((b, i) => b ^ mask[i % 4])
        const [fin, opcode] = [input[0] & 0x80, input[0] & 0x0f]
        input = input.subarray(at + 4 + len)
        if (opcode === 0x8) return frame(0x8, payload.subarray(0, 2)), socket.end()
        if (opcode === 0x9) frame(0xa, payload)
        if (opcode > 0x2) continue
        fragments.push(payload)
        if (!fin) continue
        const text = Buffer.concat(fragments).toString()
        fragments = []
        let report
        try {
          report = JSON.parse(text)
        } catch {
          continue
        }
        // The launch is over: so is its socket.
        if (!takeReport(report)) return frame(0x8, Buffer.from([0x03, 0xf0])), socket.end()
      }
    })
  }

  async function handle(req, res) {
    const path = new URL(req.url, 'http://x').pathname
    const headers = { 'Cache-Control': 'no-store' }
    if (!hostAllowed(req)) return res.writeHead(403, headers).end()

    const fromSession = new URL(req.url, 'http://x').searchParams.get('engine')
    if (path === '/claim') {
      // A relaunched Firefox may restore the previous engine page next to the new one;
      // only the page carrying this launch's nonce may run.
      return res.writeHead(session && fromSession === session ? 204 : 409, headers).end()
    }
    if (path === '/events') {
      if (!session || fromSession !== session) return res.writeHead(409, headers).end()
      res.writeHead(200, { ...headers, 'Content-Type': 'text/event-stream', Connection: 'keep-alive' })
      res.write(': connected\n\n')
      streams.add(res)
      req.on('close', () => {
        streams.delete(res)
        // Nobody is left to answer: fail pending calls now rather than at their timeout.
        if (!streams.size) for (const id of [...pending.keys()]) settle(id, 'reject', new Error('engine page disconnected'))
      })
      return
    }
    if (path === '/result' && req.method === 'POST') {
      const { id, ok, value, error } = await readJson(req)
      ok ? settle(id, 'resolve', value) : settle(id, 'reject', new Error(`page: ${error}`))
      return res.writeHead(204, headers).end()
    }
    if (path === '/developer-token') {
      return res.writeHead(200, { ...headers, 'Content-Type': 'text/plain' }).end(getDeveloperToken())
    }
    if (path === '/user-token' && req.method === 'GET') {
      const token = readUserToken()
      return token ? res.writeHead(200, { ...headers, 'Content-Type': 'text/plain' }).end(token) : res.writeHead(204, headers).end()
    }
    if (path === '/user-token' && req.method === 'POST') {
      // The sign-in page hands over a fresh Music User Token. Keep it only if Apple accepts it.
      const { token } = await readJson(req)
      const { status, body } = await api('/v1/me/storefront', { userToken: token })
      const ok = status === 200
      if (ok) saveUserToken(token)
      const result = { ok, status, storefront: ok ? body.data[0].id : null }
      for (const fn of listeners.signin) fn(result)
      return res.writeHead(200, { ...headers, 'Content-Type': 'application/json' }).end(JSON.stringify(result))
    }

    const file = path === '/' ? '/index.html' : path
    if (!FILES.has(file)) return res.writeHead(404, headers).end('not found')
    const body = await readFile(join(WEB_DIR, file))
    res.writeHead(200, { ...headers, 'Content-Type': TYPES[extname(file)] }).end(body)
  }

  // Chrome may resolve "localhost" to either loopback address, so listen on both (never on a public interface).
  const servers = []
  for (const host of ['127.0.0.1', '::1']) {
    const server = createServer((req, res) => handle(req, res).catch((err) => res.writeHead(500).end(String(err))))
    server.on('upgrade', upgrade)
    try {
      await new Promise((resolve, reject) => server.once('error', reject).listen(PORT, host, resolve))
      servers.push(server)
    } catch (err) {
      if (host === '::1' && err.code === 'EADDRNOTAVAIL') continue // IPv6 disabled
      for (const s of servers) s.close()
      if (err.code === 'EADDRINUSE') throw new Error(`port ${PORT} is busy (another am process running?)`)
      throw err
    }
  }

  return {
    setSession: (nonce) => (session = nonce),
    on: (event, fn) => listeners[event].add(fn),
    off: (event, fn) => listeners[event].delete(fn),
    lastReport: () => lastReport,
    lastReportAt: () => lastReportAt,
    // Runs window.am[method](...args) in the engine page and resolves with its return value.
    call(method, args = [], timeoutMs = 30000) {
      if (!streams.size) return Promise.reject(new Error('no engine page connected'))
      const id = nextId++
      const msg = `data: ${JSON.stringify({ id, method, args })}\n\n`
      for (const s of streams) s.write(msg)
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => settle(id, 'reject', new Error(`page did not answer ${method} within ${timeoutMs / 1000}s`)), timeoutMs)
        pending.set(id, { resolve, reject, timer })
      })
    },
    close() {
      for (const s of streams) s.end()
      return Promise.all(servers.map((s) => new Promise((r) => (s.closeAllConnections(), s.close(r)))))
    },
  }
}
