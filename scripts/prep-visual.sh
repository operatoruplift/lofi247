#!/usr/bin/env bash
#
# prep-visual.sh — normalize any video into a LOFI247 background clip.
#
# Re-encodes the input to the exact spec the streamer's concat demuxer
# requires: H.264, yuv420p, 1920x1080, constant 30 fps, NO audio track,
# mp4 container with faststart. Every clip in visuals/ must go through
# this script — the concat demuxer needs identical stream layouts.
#
# Usage:
#   scripts/prep-visual.sh <input-video> <output-name>
#
#   <output-name> with no directory component is written to <repo>/visuals/.
#   A path (contains "/") is used as-is. ".mp4" is appended if missing.
#
# Examples:
#   scripts/prep-visual.sh ~/Downloads/seedance-rainy-desk.mp4 01-rainy-desk
#   scripts/prep-visual.sh raw.mov /tmp/preview.mp4

set -euo pipefail

readonly TARGET_WIDTH=1920
readonly TARGET_HEIGHT=1080
readonly TARGET_FPS=30
readonly X264_CRF=20
readonly X264_PRESET="slow"
readonly MIN_DURATION_SECONDS=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

err() { printf 'prep-visual: ERROR: %s\n' "$*" >&2; }
info() { printf 'prep-visual: %s\n' "$*"; }

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 1
}

require_tools() {
  local tool
  for tool in ffmpeg ffprobe; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      err "'$tool' not found in PATH. Install ffmpeg first."
      exit 1
    fi
  done
}

# Refuse anything that is not a real video: no file, no video stream,
# still images (image2/png/etc. demuxers), or clips shorter than 1s.
validate_input() {
  local input="$1"
  local codec_type format_name duration

  if [[ ! -f "$input" ]]; then
    err "input file not found: $input"
    exit 1
  fi

  codec_type="$(ffprobe -v error -select_streams v:0 \
    -show_entries stream=codec_type -of csv=p=0 "$input" 2>/dev/null || true)"
  if [[ "$codec_type" != "video" ]]; then
    err "no video stream in: $input (not a video file?)"
    exit 1
  fi

  format_name="$(ffprobe -v error -show_entries format=format_name \
    -of csv=p=0 "$input" 2>/dev/null || true)"
  case "$format_name" in
    *image2*|*_pipe*|*png*|*jpeg*|*webp*|*gif*)
      err "still image or animated image detected ($format_name); need a real video"
      exit 1
      ;;
  esac

  duration="$(ffprobe -v error -show_entries format=duration \
    -of csv=p=0 "$input" 2>/dev/null || true)"
  if ! [[ "$duration" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    err "could not read a duration from: $input"
    exit 1
  fi
  if awk -v d="$duration" -v m="$MIN_DURATION_SECONDS" 'BEGIN { exit !(d < m) }'; then
    err "clip is shorter than ${MIN_DURATION_SECONDS}s (${duration}s); refusing"
    exit 1
  fi

  info "input OK: video stream, ${duration}s, container=${format_name}"
}

resolve_output_path() {
  local name="$1"
  local out
  if [[ "$name" == */* ]]; then
    out="$name"
  else
    out="${REPO_ROOT}/visuals/${name}"
  fi
  [[ "$out" == *.mp4 ]] || out="${out}.mp4"
  printf '%s\n' "$out"
}

encode() {
  local input="$1"
  local output="$2"

  # scale-to-cover + center crop guarantees exactly 1920x1080 for any
  # input aspect ratio; fps=30 forces constant frame rate; -an strips audio.
  ffmpeg -hide_banner -loglevel warning -y \
    -i "$input" \
    -an \
    -vf "scale=${TARGET_WIDTH}:${TARGET_HEIGHT}:force_original_aspect_ratio=increase:flags=lanczos,crop=${TARGET_WIDTH}:${TARGET_HEIGHT},fps=${TARGET_FPS},format=yuv420p" \
    -c:v libx264 -preset "$X264_PRESET" -crf "$X264_CRF" \
    -profile:v high -level 4.1 -pix_fmt yuv420p \
    -color_primaries bt709 -color_trc bt709 -colorspace bt709 \
    -g $((TARGET_FPS * 2)) \
    -movflags +faststart \
    "$output"
}

verify_and_summarize() {
  local output="$1"
  local summary audio_streams width height pix_fmt codec r_rate avg_rate

  summary="$(ffprobe -v error -select_streams v:0 -show_entries \
    stream=codec_name,width,height,pix_fmt,r_frame_rate,avg_frame_rate \
    -show_entries format=duration,bit_rate,size \
    -of default=noprint_wrappers=1 "$output")"

  codec="$(sed -n 's/^codec_name=//p' <<<"$summary")"
  width="$(sed -n 's/^width=//p' <<<"$summary")"
  height="$(sed -n 's/^height=//p' <<<"$summary")"
  pix_fmt="$(sed -n 's/^pix_fmt=//p' <<<"$summary")"
  r_rate="$(sed -n 's/^r_frame_rate=//p' <<<"$summary")"
  avg_rate="$(sed -n 's/^avg_frame_rate=//p' <<<"$summary")"
  audio_streams="$(ffprobe -v error -select_streams a \
    -show_entries stream=index -of csv=p=0 "$output" | wc -l | tr -d ' ')"

  echo
  info "ffprobe summary of ${output}:"
  printf '%s\n' "$summary" | sed 's/^/  /'
  printf '  audio_streams=%s\n' "$audio_streams"
  echo

  local failed=0
  [[ "$codec" == "h264" ]] || { err "codec is '$codec', expected h264"; failed=1; }
  [[ "$width" == "$TARGET_WIDTH" && "$height" == "$TARGET_HEIGHT" ]] \
    || { err "resolution ${width}x${height}, expected ${TARGET_WIDTH}x${TARGET_HEIGHT}"; failed=1; }
  [[ "$pix_fmt" == "yuv420p" ]] || { err "pix_fmt is '$pix_fmt', expected yuv420p"; failed=1; }
  [[ "$r_rate" == "${TARGET_FPS}/1" && "$avg_rate" == "${TARGET_FPS}/1" ]] \
    || { err "frame rate r=${r_rate} avg=${avg_rate}, expected ${TARGET_FPS}/1 (CFR)"; failed=1; }
  [[ "$audio_streams" == "0" ]] || { err "output still has ${audio_streams} audio stream(s)"; failed=1; }

  if [[ "$failed" -ne 0 ]]; then
    err "output does not meet the LOFI247 clip spec; see errors above"
    exit 1
  fi
  info "PASS: clip meets spec (h264 / yuv420p / ${TARGET_WIDTH}x${TARGET_HEIGHT} / ${TARGET_FPS}fps CFR / no audio)"
}

main() {
  if [[ $# -ne 2 ]]; then
    usage
  fi

  local input="$1"
  local output
  output="$(resolve_output_path "$2")"

  require_tools
  validate_input "$input"

  mkdir -p "$(dirname "$output")"
  info "encoding -> $output (this can take a while at preset=${X264_PRESET})"
  encode "$input" "$output"
  verify_and_summarize "$output"
}

main "$@"
