# Releasing am

A release is a `v<version>` tag on `IIxauII/am`. The tag's GitHub Release carries the binaries
(for mise), and the tap [`IIxauII/homebrew-am`](https://github.com/IIxauII/homebrew-am) builds
the formula from the tag's source, with bottles (ready-made binaries) from the tap's own CI.

[semantic-release](https://semantic-release.gitbook.io) makes the tag: nobody bumps the version or
tags by hand. A release is public and permanent, so title each PR for what it is.

## 1. Merge a `feat` or `fix` PR

A PR title is a [conventional commit](https://www.conventionalcommits.org): the `pr-title` check
fails a PR whose title isn't. PRs merge by squash only, and the squash commit on `main` takes the
PR's title, which decides the release:

| PR title | Release |
| --- | --- |
| `feat: …` | minor: 0.1.0 → 0.2.0 |
| `fix: …`, `perf: …`, `revert: …` | patch: 0.1.0 → 0.1.1 |
| `feat!: …`, `fix!: …` (any type with `!`), or a `BREAKING CHANGE:` footer | major: 0.1.0 → 1.0.0 |
| `docs:`, `chore:`, `ci:`, `build:`, `test:`, `refactor:`, `style:` | none |

A scope is fine: `fix(daemon): …`. A breaking change takes 0.x to 1.0.0, not to the next 0.x.

On the push to `main`, the `semantic-release` workflow (`.github/workflows/semantic-release.yml`,
configured in `release.config.mjs`) reads every commit since the last `v*` tag. If one of them
releases, it:

- sets `.version` in `build.zig.zon`, the one place the version lives (`am --version` prints it),
  in a commit `chore(release): <version> [skip ci]` by `github-actions[bot]`, pushed to `main`;
- tags that commit `v<version>`;
- calls the `release` workflow (`.github/workflows/release.yml`), which checks out the tag, fails
  if it is not `v` + `.version`, builds ReleaseSafe binaries for macOS arm64 and x86_64 and static,
  stripped Linux arm64 and x86_64, and publishes them to a GitHub Release as
  `am-<version>-<os>-<arch>.tar.gz`, with `am-<version>-checksums.txt`. The release notes list the
  PRs merged since the last release.

The release commit and the tag are pushed with `GITHUB_TOKEN`, so they start no other workflow.
After a release, local `main` is one commit behind: `git pull --ff-only`.

Watch it with `gh run watch --repo IIxauII/am`. To try the build without publishing, run the
`release` workflow by hand: `gh workflow run release.yml --repo IIxauII/am` builds the branch, and
`-f tag=v0.2.0` builds that tag. Either uploads the four archives as a workflow artifact only.

If the run fails after the tag (in the build or the publish), the tag has no GitHub Release yet.
Re-run the failed jobs: `gh run rerun <run id> --failed --repo IIxauII/am`. If the tag itself
doesn't build, merge the `fix:` PR: it releases the next patch, and the tag without a release
stays.

The repo settings this relies on: squash merges only, with the PR title as the commit title.
To set them again:

```bash
gh api -X PATCH repos/IIxauII/am -F allow_merge_commit=false -F allow_rebase_merge=false \
  -F allow_squash_merge=true -f squash_merge_commit_title=PR_TITLE \
  -f squash_merge_commit_message=COMMIT_MESSAGES
```

## 2. Bump the formula

Once the GitHub Release is out, with the new version for `0.2.0`:

```bash
brew bump-formula-pr --no-fork --no-browse \
  --url https://github.com/IIxauII/am/archive/refs/tags/v0.2.0.tar.gz \
  iixauii/am/am
```

This opens a PR on the tap that updates `url` and `sha256` in `Formula/am.rb`. The tap's daily
`brew bump` workflow opens the same PR on its own if you skip this step, but opened with
`GITHUB_TOKEN`, that PR starts no bottle CI: close and reopen it to start it.

## 3. Wait for the bottle CI

The PR's `brew test-bot` workflow builds and tests the formula on macOS and Linux and uploads
the bottles as workflow artifacts. Wait until it is green:

```bash
gh pr checks <pr number> --repo IIxauII/homebrew-am --watch
```

Don't merge the PR by hand: the next step does.

## 4. Publish the bottles

```bash
gh workflow run publish.yml --repo IIxauII/homebrew-am -f pull_request=<pr number>
```

The tap's `brew pr-pull` workflow uploads the bottles to a release on the tap, adds the
`bottle do` block to the formula, pushes the result to the tap's `main` and closes the PR.
Check with `brew update && brew info iixauii/am/am`, which lists the new version and its bottles.

## Platform notes

- The tap's CI builds bottles for macOS 26 on Apple silicon and for x86_64 Linux. Elsewhere
  `brew install` builds from source; Homebrew installs Zig for that.
- The formula requires macOS 15 or later, because Zig 0.17's macOS build needs it.
- When Homebrew's `zig` moves past 0.17, change the formula's `depends_on "zig" => :build` to
  `"zig@0.17"`.
