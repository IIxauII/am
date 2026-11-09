#!/bin/bash
# Starts one research engine with am doctor:
#   launch.sh <name> <port> <am binary> <extra prefs file | -> <seed profile dir | ->
# Config dir $TMP_ROOT/mem-<name>: symlinks to the real token and env files (am replaces a file by
# rename, so the real ones are never written), its own profile and dumps/. The idle close is off
# (keep-alive simulated). FIREFOX_PATH is ffwrap.sh, which appends log.prefs and the extra prefs
# to the user.js am writes, then runs the private Firefox copy (updates off by policy).
# With a seed, the profile is a clone of it ("warm": Widevine, musickit.js cache, Remote Settings
# data), minus its push UAID (one UAID on several connections makes the push server drop all
# but one) and its FIFO prefs.
# GC/CC logging: JS_GC_PROFILE=0 (one line per major GC slice, with pid and reason, to stderr),
# MOZ_GCTIMER=stderr (each GC's details, incl. the trigger and threshold), and
# javascript.options.mem.log (GC and CC summaries to the console service), which
# MOZ_LOG=PageMessages:5 writes to stderr. nsHttp:1 logs every HTTP channel's URI.
# The engine's stderr is <config dir>/engine.log.
ulimit -f 2000000
TMP=${TMP_ROOT:?set TMP_ROOT to the throwaway dir that holds ff/Firefox.app}
H=$(cd "$(dirname "$0")" && pwd)
name=$1 port=$2 bin=$3 prefs=$4 seed=$5
dir=$TMP/mem-$name
mkdir -p -m 700 "$dir/dumps"
for f in developer-token.jwt music-user-token env; do ln -sf "$HOME/.config/am/$f" "$dir/$f"; done
rm -rf "$dir/firefox-profile"
if [ "$seed" != "-" ]; then
  cp -Rc "$seed" "$dir/firefox-profile"
  grep -v -e 'dom.push.userAgentID' -e 'memory_info_dumper' "$seed/prefs.js" > "$dir/firefox-profile/prefs.js"
  rm -f "$dir/firefox-profile/.parentlock" "$dir/firefox-profile/lock"
  # EGC_RESCAN_ADDONS=1: drop the add-on startup cache so Firefox reconciles the built-in add-ons
  # again and reads their extensions.<name>.enabled prefs (noaddons.prefs).
  [ -n "$EGC_RESCAN_ADDONS" ] && rm -f "$dir/firefox-profile/addonStartup.json.lz4"
else
  mkdir -p -m 700 "$dir/firefox-profile"
  : > "$dir/firefox-profile/prefs.js"
fi
printf 'user_pref("memory_info_dumper.watch_fifo.directory", "%s/dumps");\nuser_pref("memory_info_dumper.watch_fifo.enabled", true);\n' "$dir" >> "$dir/firefox-profile/prefs.js"
cat "$H/log.prefs" > "$dir/extra.prefs"
[ "$prefs" != "-" ] && cat "$prefs" >> "$dir/extra.prefs"
AM_CONFIG_DIR=$dir AM_PORT=$port ENGINE_IDLE_MINUTES=100000 MOZ_UPLOAD_DIR=$dir/dumps \
  FIREFOX_PATH=$H/ffwrap.sh EGC_FIREFOX=$TMP/ff/Firefox.app/Contents/MacOS/firefox EGC_PREFS=$dir/extra.prefs \
  JS_GC_PROFILE=0 MOZ_GCTIMER=stderr MOZ_LOG=timestamp,PageMessages:5,nsHttp:1 \
  "$bin" doctor > "$dir/doctor.out" 2>&1
echo "rc=$? $(date +%H:%M:%S)" >> "$dir/doctor.out"
