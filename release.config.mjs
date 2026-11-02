// semantic-release, run on every push to main by .github/workflows/semantic-release.yml. Runbook:
// docs/releasing.md. The commands below are lodash templates: ${…} is filled in by semantic-release.
export default {
  branches: ['main'],
  plugins: [
    // Since the last v* tag: a feat releases a minor, a fix, perf or revert a patch, and a `!` or
    // a BREAKING CHANGE footer a major. Anything else releases nothing. The conventionalcommits
    // preset is the one that reads the `!`.
    ['@semantic-release/commit-analyzer', { preset: 'conventionalcommits' }],
    [
      '@semantic-release/exec',
      {
        // build.zig.zon's .version, which `am --version` prints and release.yml checks the tag
        // against, so the tag's tree and its source tarball (the Homebrew formula's) say it.
        prepareCmd: 'node tools/set-version.mjs ${nextRelease.version}',
        // Hands the new tag to the workflow's build and publish job (release.yml).
        publishCmd: 'echo "tag=${nextRelease.gitTag}" >> "$GITHUB_OUTPUT"',
      },
    ],
    // The release commit, which the tag points at. Pushed with GITHUB_TOKEN, it starts no workflow.
    ['@semantic-release/git', { assets: ['build.zig.zon'], message: 'chore(release): ${nextRelease.version} [skip ci]' }],
    // No @semantic-release/github: release.yml creates the GitHub Release once the binaries are
    // built, so it never shows without them.
  ],
}
