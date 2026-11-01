## Agent skills

### Issue tracker

Issues live in GitHub Issues on `IIxauII/am`, managed via the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical labels: `needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`. See `docs/agents/triage-labels.md`.

### Domain docs

Single-context: one root `GLOSSARY.md` plus `docs/adr/`. See `docs/agents/domain.md`.

## Zig

Check each std API and builtin against the installed toolchain's own docs before using it. Run `zig env` and take `lib_dir` from it.

- **Standard library:** `<lib_dir>/std/`. The doc comments in the source are the std docs; grep it for signatures, including `std.Build` for `build.zig`.
- **Language and builtins:** `langref.html` in the install's `doc/` directory (beside `lib/` in the official tarball). It is one large HTML file: grep it for the builtin or keyword you need.
- **Project layout:** `<lib_dir>/init/` holds Zig's own 0.17 `build.zig` / `build.zig.zon` template.
