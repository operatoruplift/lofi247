#!/bin/sh
set -eu
mkdir -p /tmp/lofi
station="${STATION_NAME:-LOFI 247}"
handle="${OVERLAY_HANDLE:-@yourhandle}"
handle="${handle#@}"                       # store bare handle, no leading @
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }   # JSON-escape backslash and quote
printf '{"station":"%s","handle":"%s"}\n' "$(esc "$station")" "$(esc "$handle")" \
  > /tmp/lofi/config.json
