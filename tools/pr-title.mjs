// The PR title check (.github/workflows/pr-title.yml): a squash merge makes the PR title the
// commit title on main, and semantic-release reads that title to decide the release.
// `node tools/pr-title.mjs` checks $PR_TITLE.

const types = ['feat', 'fix', 'perf', 'revert', 'docs', 'style', 'refactor', 'test', 'build', 'ci', 'chore']
const releasing = ['feat', 'fix', 'perf', 'revert']
const conventional = new RegExp(`^(${types.join('|')})(\\([^()]+\\))?!?: \\S`)
// What GitHub's Revert button titles its PR. Its commit says "This reverts commit <sha>.", which
// semantic-release reads as a revert.
const githubRevert = /^Revert ".+"$/

/** null for a conventional commit title, else what's wrong with it and how to write one. */
export function prTitleError(title) {
  if (conventional.test(title) || githubRevert.test(title)) return null
  return `PR title "${title}" isn't a conventional commit: <type>[(scope)][!]: <description>.
  feat: …                       releases a minor version
  fix: …, perf: …, revert: …    releases a patch version
  <type>!: … (feat!:, fix!: …)  releases a major version
  ${types.filter((t) => !releasing.includes(t)).join(': …, ')}: …  release nothing`
}

if (import.meta.main) {
  const error = prTitleError(process.env.PR_TITLE ?? '')
  if (error) {
    // A workflow annotation takes one line; the details follow in the log.
    console.log("::error::The PR title isn't a conventional commit, which semantic-release needs")
    console.log(error)
    process.exit(1)
  }
  console.log(`PR title "${process.env.PR_TITLE}" is a conventional commit`)
}
