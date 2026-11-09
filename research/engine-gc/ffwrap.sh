#!/bin/bash
# FIREFOX_PATH for the research engines. am writes <profile>/user.js just before it starts the
# engine; this appends the instance's extra prefs ($EGC_PREFS, a file of user_pref lines) to it,
# then execs the private Firefox copy with am's argv unchanged. Research only: am's code and
# prefs stay as on main.
ulimit -f 2000000
prof="" prev=""
for a in "$@"; do
  [ "$prev" = "--profile" ] && prof=$a
  prev=$a
done
if [ -n "$EGC_PREFS" ] && [ -n "$prof" ] && [ -f "$EGC_PREFS" ]; then
  cat "$EGC_PREFS" >> "$prof/user.js"
fi
exec "${EGC_FIREFOX:?set EGC_FIREFOX to the private Firefox binary}" "$@"
