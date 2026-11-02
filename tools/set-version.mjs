// Sets `.version` in build.zig.zon, the one place am's version lives. semantic-release runs
// `node tools/set-version.mjs <version>` from the repo root before its release commit
// (release.config.mjs).
import { readFileSync, writeFileSync } from 'node:fs'

const versionLine = /^(\s*\.version = ")[^"]*(",)$/m

/** build.zig.zon's text with `.version` set to `version`. Throws if it has no `.version` line. */
export function setVersion(zon, version) {
  if (!versionLine.test(zon)) throw new Error('build.zig.zon has no `.version = "…",` line')
  return zon.replace(versionLine, `$1${version}$2`)
}

if (import.meta.main) {
  const [version] = process.argv.slice(2)
  if (!version) {
    console.error('usage: node tools/set-version.mjs <version>')
    process.exit(2)
  }
  writeFileSync('build.zig.zon', setVersion(readFileSync('build.zig.zon', 'utf8'), version))
}
