# am

Apple Music in the terminal.

Playback via headless Firefox or Google Chrome, so one of them must be installed (on macOS:
`brew install --cask firefox`).

## Install

With [Homebrew](https://brew.sh) (macOS 15 or later, or Linux):

```bash
brew install IIxauII/am/am
```

With [mise](https://mise.jdx.dev), from the release binaries:

```bash
mise use -g github:IIxauII/am
```

From source, with Zig 0.17:

```bash
zig build -Doptimize=ReleaseSafe    # → zig-out/bin/am
```

## Platforms

- **macOS**
- **Linux**

## Use

```bash
am signin    # once
am           # player; ? for keys
am play <song id or search term>
am --help
am --version
```

## Releasing

See [docs/releasing.md](docs/releasing.md).

## License

GPL-3.0-only
