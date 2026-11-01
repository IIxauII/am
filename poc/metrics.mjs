// Observing the Chrome engine from outside: its process tree's memory/CPU and its PipeWire audio stream.
import { execFile } from 'node:child_process'
import { readdirSync, readFileSync } from 'node:fs'
import { promisify } from 'node:util'

const CLK_TCK = 100 // USER_HZ on Linux x86_64

function readProc(pid, file) {
  try {
    return readFileSync(`/proc/${pid}/${file}`, 'utf8')
  } catch {
    return null
  }
}

// /proc/<pid>/stat: comm may contain spaces, so split after the closing paren.
function statFields(pid) {
  const stat = readProc(pid, 'stat')
  if (!stat) return null
  const rest = stat.slice(stat.lastIndexOf(')') + 2).split(' ')
  return { ppid: Number(rest[1]), cpuTicks: Number(rest[11]) + Number(rest[12]) }
}

export function processTree(rootPid) {
  const children = new Map()
  for (const name of readdirSync('/proc')) {
    if (!/^\d+$/.test(name)) continue
    const f = statFields(name)
    if (!f) continue
    if (!children.has(f.ppid)) children.set(f.ppid, [])
    children.get(f.ppid).push(Number(name))
  }
  const pids = []
  const queue = [rootPid]
  while (queue.length) {
    const pid = queue.shift()
    pids.push(pid)
    queue.push(...(children.get(pid) ?? []))
  }
  return pids
}

// Sandboxed Chrome children are non-dumpable, so their smaps_rollup (PSS) is unreadable.
// Fall back to RSS from /proc/<pid>/status, which over-counts shared pages.
function memoryKiB(pid) {
  const rollup = readProc(pid, 'smaps_rollup')
  const pss = rollup?.match(/^Pss:\s+(\d+) kB/m)
  if (pss) return { kib: Number(pss[1]), kind: 'pss' }
  const rss = readProc(pid, 'status')?.match(/^VmRSS:\s+(\d+) kB/m)
  return { kib: rss ? Number(rss[1]) : 0, kind: 'rss' }
}

// Samples CPU over `ms` and reports memory for the whole tree under rootPid.
export async function measureTree(rootPid, ms = 5000) {
  const pids = processTree(rootPid)
  const before = new Map(pids.map((p) => [p, statFields(p)?.cpuTicks ?? 0]))
  await new Promise((r) => setTimeout(r, ms))
  let ticks = 0
  let pssKiB = 0
  let rssKiB = 0
  let rssProcs = 0
  for (const pid of pids) {
    const after = statFields(pid)
    if (!after) continue
    ticks += after.cpuTicks - before.get(pid)
    const mem = memoryKiB(pid)
    if (mem.kind === 'pss') pssKiB += mem.kib
    else {
      rssKiB += mem.kib
      rssProcs++
    }
  }
  return {
    processes: pids.length,
    cpuPercent: (ticks / CLK_TCK / (ms / 1000)) * 100,
    memoryMiB: (pssKiB + rssKiB) / 1024,
    rssOnlyProcesses: rssProcs,
  }
}

// The engine's playback streams as PipeWire-Pulse sees them. Only metadata, never audio samples.
// Matched by process id, so streams of the user's own browser are ignored.
export async function engineSinkInputs(rootPid) {
  try {
    const pids = new Set(processTree(rootPid))
    const { stdout } = await promisify(execFile)('pactl', ['-f', 'json', 'list', 'sink-inputs'])
    return JSON.parse(stdout)
      .filter((s) => pids.has(Number(s.properties?.['application.process.id'])))
      .map((s) => ({
        index: s.index,
        app: s.properties['application.name'],
        media: s.properties['media.name'],
        corked: s.corked,
        mute: s.mute,
        volume: Object.values(s.volume ?? {})[0]?.value_percent,
        sink: s.sink,
      }))
  } catch (err) {
    return { error: String(err.message ?? err) }
  }
}
