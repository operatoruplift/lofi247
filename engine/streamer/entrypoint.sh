#!/usr/bin/env bash
# LOFI 247 streamer entrypoint.
#
# Composites looping ambient visuals (/visuals/*.mp4) with the icecast audio
# stream and a now-playing text overlay, then pushes FLV to X via RTMP.
#
# Behavior:
#   - waits for the icecast mount before starting ffmpeg
#   - if /visuals is empty, generates a procedural fallback loop once
#   - wraps ffmpeg in an infinite restart loop with a 5s backoff
#   - if X_RTMP_URL / X_STREAM_KEY are missing, logs and sleeps (no crash loop)

set -uo pipefail

log() { printf '[streamer] %s\n' "$*" >&2; }

# --- configuration (environment with safe defaults) --------------------------

STREAM_WIDTH="${STREAM_WIDTH:-1280}"
STREAM_HEIGHT="${STREAM_HEIGHT:-720}"
STREAM_FPS="${STREAM_FPS:-30}"
VIDEO_BITRATE="${VIDEO_BITRATE:-3500k}"
AUDIO_BITRATE="${AUDIO_BITRATE:-160k}"
STATION_NAME="${STATION_NAME:-LOFI 247}"
OVERLAY_HANDLE="${OVERLAY_HANDLE:-@yourhandle}"
X_RTMP_URL="${X_RTMP_URL:-}"
X_STREAM_KEY="${X_STREAM_KEY:-}"

AUDIO_URL="${AUDIO_URL:-http://icecast:8000/radio}"
ICECAST_STATUS_URL="${ICECAST_STATUS_URL:-http://icecast:8000/status-json.xsl}"
VISUALS_DIR="${VISUALS_DIR:-/visuals}"
DATA_NOWPLAYING="${DATA_NOWPLAYING:-/data/nowplaying.txt}"

WORK_DIR="/tmp/streamer"
CONCAT_LIST="${WORK_DIR}/visuals.txt"
FALLBACK_MP4="${WORK_DIR}/fallback-loop.mp4"
BUG_FILE="${WORK_DIR}/bug.txt"
# drawtext always reads this local copy; a background loop mirrors the
# liquidsoap-written /data file into it (see start_nowplaying_refresher).
NOWPLAYING_FILE="${WORK_DIR}/nowplaying.txt"

RESTART_DELAY=5
MISSING_KEY_SLEEP=300

mkdir -p "${WORK_DIR}"

# --- signal handling (we are PID 1) -------------------------------------------
# Forward stop signals to ffmpeg so X gets a clean FLV teardown instead of a
# SIGKILLed connection after docker's grace period.

FFMPEG_PID=""
REFRESHER_PID=""

on_signal() {
  log "Caught stop signal; shutting down."
  if [ -n "${FFMPEG_PID}" ]; then
    kill -TERM "${FFMPEG_PID}" 2>/dev/null || true
    wait "${FFMPEG_PID}" 2>/dev/null || true
  fi
  if [ -n "${REFRESHER_PID}" ]; then
    kill "${REFRESHER_PID}" 2>/dev/null || true
  fi
  exit 0
}
trap on_signal TERM INT

# Interruptible sleep: plain 'sleep' is an external child, and bash defers
# traps until the foreground child exits — this variant lets signals through.
snooze() {
  sleep "$1" &
  wait $! 2>/dev/null || true
}

# --- input validation --------------------------------------------------------

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }

if ! is_uint "${STREAM_WIDTH}" || ! is_uint "${STREAM_HEIGHT}" \
  || ! is_uint "${STREAM_FPS}"; then
  log "WARNING: non-numeric STREAM_WIDTH/STREAM_HEIGHT/STREAM_FPS; using 1280x720@30"
  STREAM_WIDTH=1280
  STREAM_HEIGHT=720
  STREAM_FPS=30
fi

# x264 + yuv420p needs even dimensions; fps=0 kills both -g and the fps filter.
if [ "${STREAM_FPS}" -lt 1 ] || [ "${STREAM_WIDTH}" -lt 2 ] || [ "${STREAM_HEIGHT}" -lt 2 ] \
  || [ "$((STREAM_WIDTH % 2))" -ne 0 ] || [ "$((STREAM_HEIGHT % 2))" -ne 0 ]; then
  log "WARNING: STREAM dims must be even and >= 2 with fps >= 1 (got ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS}); using 1280x720@30"
  STREAM_WIDTH=1280
  STREAM_HEIGHT=720
  STREAM_FPS=30
fi

if ! [[ "${VIDEO_BITRATE}" =~ ^[0-9]+[kM]?$ ]]; then
  log "WARNING: unparsable VIDEO_BITRATE '${VIDEO_BITRATE}'; using 3500k"
  VIDEO_BITRATE="3500k"
fi

# -bufsize = 2x the video bitrate.
case "${VIDEO_BITRATE}" in
  *k) BUFSIZE="$((2 * ${VIDEO_BITRATE%k}))k" ;;
  *M) BUFSIZE="$((2 * ${VIDEO_BITRATE%M}))M" ;;
  *) BUFSIZE="$((2 * VIDEO_BITRATE))" ;;
esac

GOP="$((2 * STREAM_FPS))"

FONT_FILE="$(find /usr/share/fonts -name 'DejaVuSans.ttf' -print -quit 2>/dev/null || true)"
if [ -z "${FONT_FILE}" ]; then
  FONT_FILE="$(find /usr/share/fonts -name '*.ttf' -print -quit 2>/dev/null || true)"
fi
if [ -z "${FONT_FILE}" ]; then
  log "ERROR: no TTF font found under /usr/share/fonts; cannot draw overlays."
  exit 1
fi

# Overlay geometry derived from the canvas so other resolutions stay readable.
NP_FONTSIZE="$((STREAM_HEIGHT / 26))"
BUG_FONTSIZE="$((STREAM_HEIGHT / 36))"
NP_MARGIN="$((STREAM_HEIGHT / 16))"
BUG_MARGIN="$((STREAM_HEIGHT / 28))"

# Station bug text goes through a file so no drawtext escaping is needed.
printf '%s · %s\n' "${STATION_NAME}" "${OVERLAY_HANDLE}" > "${BUG_FILE}"

# --- helpers -----------------------------------------------------------------

wait_for_icecast() {
  log "Waiting for icecast mount at ${AUDIO_URL} ..."
  until curl -fsS --max-time 5 "${ICECAST_STATUS_URL}" 2>/dev/null | grep -q '/radio'; do
    snooze 5
  done
  log "Icecast mount is up."
}

# Generate a 60s procedural loop (animated dark gradient + film grain) once.
ensure_fallback_visual() {
  if [ -s "${FALLBACK_MP4}" ]; then
    return 0
  fi
  log "No visuals in ${VISUALS_DIR}; generating procedural fallback loop (60s)..."
  if ! ffmpeg -y -hide_banner -nostdin -loglevel error \
    -f lavfi \
    -i "gradients=size=${STREAM_WIDTH}x${STREAM_HEIGHT}:rate=${STREAM_FPS}:speed=0.015:nb_colors=4:c0=0x0B0A12:c1=0x1B1430:c2=0x241A3A:c3=0x101822:duration=60" \
    -vf "noise=alls=6:allf=t+u,vignette,format=yuv420p" \
    -c:v libx264 -preset veryfast -crf 22 -g "${GOP}" -pix_fmt yuv420p \
    "${FALLBACK_MP4}"; then
    log "ERROR: failed to generate the fallback visual."
    return 1
  fi
  log "Fallback visual ready: ${FALLBACK_MP4}"
}

# Build the concat list from all *.mp4 in /visuals (glob order = sorted,
# case-insensitive so .MP4 airs too).
build_concat_list() {
  local f esc files ignored
  local q="'"
  shopt -s nullglob nocaseglob
  files=("${VISUALS_DIR}"/*.mp4)
  shopt -u nullglob nocaseglob
  ignored="$(find "${VISUALS_DIR}" -maxdepth 1 -type f ! -iname '*.mp4' 2>/dev/null || true)"
  if [ -n "${ignored}" ]; then
    log "WARNING: ignoring non-mp4 files in ${VISUALS_DIR} — run scripts/prep-visual.sh on them:"
    printf '%s\n' "${ignored}" >&2
  fi
  if [ "${#files[@]}" -eq 0 ]; then
    ensure_fallback_visual || return 1
    files=("${FALLBACK_MP4}")
  fi
  : > "${CONCAT_LIST}"
  for f in "${files[@]}"; do
    esc=${f//${q}/${q}\\${q}${q}} # ' -> '\'' for the concat demuxer
    printf "file '%s'\n" "${esc}" >> "${CONCAT_LIST}"
  done
  log "Visual playlist: ${#files[@]} clip(s)."
}

# Mirror the liquidsoap-written now-playing file into WORK_DIR every few
# seconds (tmp+rename so drawtext never reads a partial line). Seeded with
# the station name, so the overlay is correct even before liquidsoap writes —
# and it heals if /data/nowplaying.txt only appears later.
start_nowplaying_refresher() {
  if [ -s "${DATA_NOWPLAYING}" ]; then
    cp -f "${DATA_NOWPLAYING}" "${NOWPLAYING_FILE}"
  else
    printf '%s\n' "${STATION_NAME}" > "${NOWPLAYING_FILE}"
    log "WARNING: ${DATA_NOWPLAYING} not there yet; overlay shows the station name until it appears."
  fi
  (
    while :; do
      if [ -s "${DATA_NOWPLAYING}" ] && ! cmp -s "${DATA_NOWPLAYING}" "${NOWPLAYING_FILE}"; then
        cp -f "${DATA_NOWPLAYING}" "${NOWPLAYING_FILE}.tmp" \
          && mv -f "${NOWPLAYING_FILE}.tmp" "${NOWPLAYING_FILE}"
      fi
      sleep 3
    done
  ) &
  REFRESHER_PID=$!
}

build_filters() {
  FILTERS="scale=w=${STREAM_WIDTH}:h=${STREAM_HEIGHT}:force_original_aspect_ratio=decrease"
  FILTERS+=",pad=w=${STREAM_WIDTH}:h=${STREAM_HEIGHT}:x=(ow-iw)/2:y=(oh-ih)/2:color=black"
  FILTERS+=",setsar=1,fps=${STREAM_FPS}"
  # Now playing — lower left, semi-transparent box, re-read every 30 frames.
  FILTERS+=",drawtext=fontfile=${FONT_FILE}:textfile=${NOWPLAYING_FILE}:reload=30"
  FILTERS+=":expansion=none:fontsize=${NP_FONTSIZE}:fontcolor=0xF5F1E8"
  FILTERS+=":box=1:boxcolor=0x0B0A12@0.55:boxborderw=14"
  FILTERS+=":x=${NP_MARGIN}:y=h-th-${NP_MARGIN}"
  # Station bug — top right, small.
  FILTERS+=",drawtext=fontfile=${FONT_FILE}:textfile=${BUG_FILE}:reload=300"
  FILTERS+=":expansion=none:fontsize=${BUG_FONTSIZE}:fontcolor=0xF5F1E8@0.9"
  FILTERS+=":box=1:boxcolor=0x0B0A12@0.35:boxborderw=10"
  FILTERS+=":x=w-tw-${BUG_MARGIN}:y=${BUG_MARGIN}"
}

# ffmpeg prints the full output URL (stream key included) in its own error
# messages; scrub the key before anything reaches the container log.
redact_key() {
  if [ -n "${X_STREAM_KEY}" ]; then
    local pattern
    pattern="$(printf '%s' "${X_STREAM_KEY}" | sed 's/[][\\.*^$#]/\\&/g')"
    sed "s#${pattern}#<stream-key>#g" >&2
  else
    cat >&2
  fi
}

run_ffmpeg() {
  # -rw_timeout: a silently hung icecast TCP read would otherwise freeze the
  # stream forever without ever tripping the restart loop.
  ffmpeg -hide_banner -nostdin -loglevel warning \
    -re -stream_loop -1 -f concat -safe 0 -i "${CONCAT_LIST}" \
    -reconnect 1 -reconnect_streamed 1 -reconnect_delay_max 5 \
    -rw_timeout 15000000 \
    -i "${AUDIO_URL}" \
    -map 0:v:0 -map 1:a:0 \
    -vf "${FILTERS}" \
    -c:v libx264 -preset veryfast -pix_fmt yuv420p \
    -b:v "${VIDEO_BITRATE}" -maxrate "${VIDEO_BITRATE}" -bufsize "${BUFSIZE}" \
    -g "${GOP}" -keyint_min "${STREAM_FPS}" -sc_threshold 0 \
    -c:a aac -b:a "${AUDIO_BITRATE}" -ar 44100 -ac 2 \
    -f flv "${RTMP_TARGET}" > >(redact_key) 2>&1 &
  FFMPEG_PID=$!
  wait "${FFMPEG_PID}"
  local rc=$?
  FFMPEG_PID=""
  return "${rc}"
}

# --- main loop ---------------------------------------------------------------

main() {
  local rc
  start_nowplaying_refresher
  build_filters
  while :; do
    if [ -z "${X_RTMP_URL}" ] || [ -z "${X_STREAM_KEY}" ]; then
      log "ERROR: X_RTMP_URL and/or X_STREAM_KEY are not set — cannot stream to X."
      log "       Fill them in .env (see .env.example), then restart this service."
      snooze "${MISSING_KEY_SLEEP}"
      continue
    fi
    RTMP_TARGET="${X_RTMP_URL%/}/${X_STREAM_KEY}"

    wait_for_icecast
    if ! build_concat_list; then
      snooze "${RESTART_DELAY}"
      continue
    fi

    log "Starting ffmpeg: ${STREAM_WIDTH}x${STREAM_HEIGHT}@${STREAM_FPS} -> ${X_RTMP_URL}/<hidden>"
    run_ffmpeg
    rc=$?
    log "ffmpeg exited (code ${rc}); restarting in ${RESTART_DELAY}s."
    snooze "${RESTART_DELAY}"
  done
}

main
