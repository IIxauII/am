// The PR title check that .github/workflows/pr-title.yml runs: `node tools/pr-title.mjs` checks
// $PR_TITLE. The release each type makes is in docs/releasing.md.
import { realpathSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const types = ['feat', 'fix', 'perf', 'revert', 'docs', 'style', 'refactor', 'test', 'build', 'ci', 'chore']
const conventionalTitle = new RegExp(`^(${types.join('|')})(\\([^()]+\\))?!?: \\S`)
// What GitHub's Revert button titles its PR. Its commit says "This reverts commit <sha>.", which
// semantic-release reads as a revert.
const githubRevertTitle = /^Revert ".+"$/

/** null for a conventional commit title, else what's wrong with it and how to write one. */
export function prTitleError(title) {
  if (conventionalTitle.test(title) || githubRevertTitle.test(title)) return null
  return `PR title "${title}" isn't a conventional commit: <type>[(scope)][!]: <description>.
  feat: …                       releases a minor version
  fix: …, perf: …               releases a patch version, as does a revert ("This reverts commit <sha>.")
  <type>!: … (feat!:, fix!: …)  releases a major version
  ${types.filter((t) => !['feat', 'fix', 'perf', 'revert'].includes(t)).join(': …, ')}: …  release nothing`
}

// Run as a script, not imported by the tests. (import.meta.main would do, but needs Node 24.2.)
if (process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const error = prTitleError(process.env.PR_TITLE ?? '')
  if (error) {
    // A workflow annotation takes one line; the details follow in the log.
    console.log("::error::The PR title isn't a conventional commit, which semantic-release needs")
    console.log(error)
    process.exit(1)
  }
  console.log(`PR title "${process.env.PR_TITLE}" is a conventional commit`)
}
