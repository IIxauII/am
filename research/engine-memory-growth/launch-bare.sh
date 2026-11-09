#!/bin/bash
# The baseline: the same Firefox copy, flags, env and user.js prefs as am's engine, on about:blank
# (no engine page, no MusicKit, no daemon). Runs in the foreground until killed.
# usage: launch-bare.sh <user.js to copy>
ulimit -f 2000000
TMP=${TMP_ROOT:?set TMP_ROOT to the throwaway dir that holds mem-bare/ and ff/Firefox.app}
dir=$TMP/mem-bare
rm -rf "$dir/firefox-profile"
mkdir -p -m 700 "$dir/firefox-profile" "$dir/dumps"
cp "$1" "$dir/firefox-profile/user.js"
printf 'user_pref("memory_info_dumper.watch_fifo.directory", "%s/dumps");\nuser_pref("memory_info_dumper.watch_fifo.enabled", true);\n' "$dir" > "$dir/firefox-profile/prefs.js"
MOZ_CRASHREPORTER_DISABLE=1 MOZ_DISABLE_AUTO_SAFE_MODE=1 MOZ_UPLOAD_DIR=$dir/dumps \
  exec "$TMP/ff/Firefox.app/Contents/MacOS/firefox" --new-instance --profile "$dir/firefox-profile" --headless about:blank \
  > "$dir/firefox.out" 2>&1
