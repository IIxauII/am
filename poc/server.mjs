// Local server for the engine page, and the only channel between the CLI and the browser:
// commands go to the page over Server-Sent Events, state and results come back as POSTs.
// No browser automation protocol is involved, so any browser that runs the page works.
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

  async function handle(req, res) {
    const path = new URL(req.url, 'http://x').pathname
    const headers = { 'Cache-Control': 'no-store' }
    // Refuse DNS-rebinding requests: only loopback host names may talk to the engine.
    if (!/^(localhost|127\.0\.0\.1|\[::1\]):\d+$/.test(req.headers.host ?? '')) return res.writeHead(403, headers).end()

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
    if (path === '/report' && req.method === 'POST') {
      const report = await readJson(req)
      if (report.engine !== session) return res.writeHead(409, headers).end()
      lastReport = report
      lastReportAt = Date.now()
      for (const fn of listeners.report) fn(lastReport)
      return res.writeHead(204, headers).end()
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
