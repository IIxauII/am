#!/bin/bash
# The baseline: the same Firefox copy, flags, env, am's user.js prefs and the same logging as the
# research engines, on about:blank (no engine page, no MusicKit, no daemon). Runs until killed.
#   launch-bare.sh <name> <extra prefs file | -> <seed profile dir | ->
ulimit -f 2000000
TMP=${TMP_ROOT:?set TMP_ROOT to the throwaway dir that holds ff/Firefox.app}
H=$(cd "$(dirname "$0")" && pwd)
name=$1 prefs=$2 seed=$3
dir=$TMP/mem-$name
mkdir -p -m 700 "$dir/dumps"
rm -rf "$dir/firefox-profile"
if [ "$seed" != "-" ]; then
  cp -Rc "$seed" "$dir/firefox-profile"
  grep -v -e 'dom.push.userAgentID' -e 'memory_info_dumper' "$seed/prefs.js" > "$dir/firefox-profile/prefs.js"
  rm -f "$dir/firefox-profile/.parentlock" "$dir/firefox-profile/lock"
else
  mkdir -p -m 700 "$dir/firefox-profile"
  : > "$dir/firefox-profile/prefs.js"
fi
printf 'user_pref("memory_info_dumper.watch_fifo.directory", "%s/dumps");\nuser_pref("memory_info_dumper.watch_fifo.enabled", true);\n' "$dir" >> "$dir/firefox-profile/prefs.js"
cat "$H/user.js" "$H/log.prefs" > "$dir/firefox-profile/user.js"
[ "$prefs" != "-" ] && cat "$prefs" >> "$dir/firefox-profile/user.js"
MOZ_CRASHREPORTER_DISABLE=1 MOZ_DISABLE_AUTO_SAFE_MODE=1 MOZ_UPLOAD_DIR=$dir/dumps \
  JS_GC_PROFILE=0 MOZ_GCTIMER=stderr MOZ_LOG=timestamp,PageMessages:5,nsHttp:1 \
  exec "$TMP/ff/Firefox.app/Contents/MacOS/firefox" --new-instance --profile "$dir/firefox-profile" --headless about:blank \
  > "$dir/engine.log" 2>&1
