# am

Apple Music in the terminal.

Playback via headless Firefox or Google Chrome.

## Build

```bash
zig build -Doptimize=ReleaseSafe    # → zig-out/bin/am (Zig 0.17)
```

## Use

```bash
am signin    # once
am           # player; ? for keys
am play <song id or search term>
am --help
```

## License

GPL-3.0-only
