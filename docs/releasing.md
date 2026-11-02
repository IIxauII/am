# Releasing am

A release is a `v<version>` tag on `IIxauII/am`. The tag's GitHub Release carries the binaries
(for mise), and the tap [`IIxauII/homebrew-am`](https://github.com/IIxauII/homebrew-am) builds
the formula from the tag's source, with bottles (ready-made binaries) from the tap's own CI.

A pushed tag and a published release are public and permanent: check the version before tagging.

## 1. Bump the version

Set `.version` in `build.zig.zon`. It is the only place the version lives: `am --version`
prints it, and `zig build test` checks that the built binary does.

Open a PR with the bump and merge it once the `test` workflow passes.

## 2. Tag

From an up-to-date `main`, with `0.2.0` standing for the new version:

```bash
git switch main
git pull --ff-only
git tag v0.2.0
git push origin v0.2.0
```

The `release` workflow (`.github/workflows/release.yml`) then:

- fails if the tag is not `v` + `.version`;
- builds ReleaseSafe binaries for macOS arm64 and x86_64 and static, stripped Linux arm64 and
  x86_64;
- publishes them to a GitHub Release as `am-<version>-<os>-<arch>.tar.gz`, with
  `am-<version>-checksums.txt`.

Watch it with `gh run watch --repo IIxauII/am`. To try the build without publishing, run the
workflow by hand (`gh workflow run release.yml --repo IIxauII/am`): it uploads the four archives
as a workflow artifact only.

## 3. Bump the formula

```bash
brew bump-formula-pr --no-fork --no-browse \
  --url https://github.com/IIxauII/am/archive/refs/tags/v0.2.0.tar.gz \
  iixauii/am/am
```

This opens a PR on the tap that updates `url` and `sha256` in `Formula/am.rb`. The tap's daily
`brew bump` workflow opens the same PR on its own if you skip this step.

## 4. Wait for the bottle CI

The PR's `brew test-bot` workflow builds and tests the formula on macOS and Linux and uploads
the bottles as workflow artifacts. Wait until it is green:

```bash
gh pr checks <pr number> --repo IIxauII/homebrew-am --watch
```

Don't merge the PR by hand: the next step does.

## 5. Publish the bottles

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
