// Tests for the release tooling that semantic-release and the PR title check run (docs/releasing.md).
// Run with `npm run test:release` (or `zig build test`).
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { setVersion } from './set-version.mjs'
import { prTitleError } from './pr-title.mjs'

const zon = `.{
    .name = .am,
    // The one place am's version is set.
    .version = "0.1.0",
    .fingerprint = 0xe3c55fc4a18f344,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{},
}
`

test('setVersion writes the new version into the .version line and leaves the rest alone', () => {
  assert.equal(
    setVersion(zon, '0.2.0'),
    `.{
    .name = .am,
    // The one place am's version is set.
    .version = "0.2.0",
    .fingerprint = 0xe3c55fc4a18f344,
    .minimum_zig_version = "0.17.0",
    .dependencies = .{},
}
`,
  )
})

test('setVersion fails when build.zig.zon has no .version line, so no release goes out with the old one', () => {
  const noVersion = zon.replace('    .version = "0.1.0",\n', '')
  assert.throws(() => setVersion(noVersion, '0.2.0'), /no `\.version = "…",` line/)
})

test('a conventional PR title passes the check, with or without a scope or a !', () => {
  for (const title of [
    'feat: am queue shows the album',
    'fix(daemon): reconnect after the browser restarts',
    'feat!: drop the --legacy flag',
    'fix(token-worker)!: sign with the new key id',
    'chore: bump wrangler',
    'docs: release runbook',
    'ci: release with semantic-release',
  ]) {
    assert.equal(prTitleError(title), null, title)
  }
})

test('a free-form PR title fails the check, and the message shows the format', () => {
  assert.match(prTitleError('Update README for clarity'), /isn't a conventional commit/)
  assert.match(prTitleError('Update README for clarity'), /feat: /)
})

test('a near miss fails the check, since semantic-release would read it as no release at all', () => {
  for (const title of ['Feat: am queue shows the album', 'feature: am queue', 'fix:no space', 'fix: ', 'fix(): empty scope', 'fix(daemon) missing colon']) {
    assert.notEqual(prTitleError(title), null, title)
  }
})

test("GitHub's own title for a revert PR passes the check", () => {
  assert.equal(prTitleError('Revert "feat: am queue shows the album"'), null)
})
