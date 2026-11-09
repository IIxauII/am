#!/bin/bash
# Starts one research engine with am doctor: launch.sh <name> <port> <am-binary>
# Config dir <TMP>/mem-<name> holds symlinks to the real tokens and env file, its own fresh
# firefox-profile (with a prefs.js that turns on Firefox's memory-report FIFO in dumps/) and dumps/.
# The idle close is off (keep-alive simulated). Firefox is a private copy of the installed app
# (<TMP>/ff/Firefox.app), so it never applies the installed app's pending self-update.
ulimit -f 2000000
TMP=${TMP_ROOT:?set TMP_ROOT to the throwaway dir that holds mem-<name>/ and ff/Firefox.app}
name=$1 port=$2 bin=$3
dir=$TMP/mem-$name
rm -rf "$dir/firefox-profile"
mkdir -p -m 700 "$dir/firefox-profile" "$dir/dumps"
printf 'user_pref("memory_info_dumper.watch_fifo.directory", "%s/dumps");\nuser_pref("memory_info_dumper.watch_fifo.enabled", true);\n' "$dir" > "$dir/firefox-profile/prefs.js"
AM_CONFIG_DIR=$dir AM_PORT=$port ENGINE_IDLE_MINUTES=100000 MOZ_UPLOAD_DIR=$dir/dumps \
  FIREFOX_PATH=$TMP/ff/Firefox.app/Contents/MacOS/firefox \
  "$bin" doctor > "$dir/doctor.out" 2>&1
echo "rc=$?" >> "$dir/doctor.out"
