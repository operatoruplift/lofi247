#!/usr/bin/env bash
#
# ingest-music.sh — normalize audio files and add them to the LOFI 247 library.
#
# For each input file (mp3/flac/wav/m4a/ogg):
#   1. Pass 1: measure loudness with ffmpeg loudnorm (I=-14, TP=-1.5, LRA=11)
#   2. Pass 2: apply linear two-pass normalization, encode 320 kbps MP3,
#      preserve ID3/tag metadata (artist/title drive the on-stream overlay)
#   3. Write atomically into the music library (temp file, then rename)
#
# Usage:
#   scripts/ingest-music.sh <file> [file ...]
#
# Environment:
#   MUSIC_DIR   Output directory (default: <repo>/music)
#
# Files whose normalized .mp3 already exists in MUSIC_DIR are skipped.
# Exits non-zero if any file failed; already-present skips are not failures.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
MUSIC_DIR="${MUSIC_DIR:-$REPO_ROOT/music}"

TARGET_I="-14"     # integrated loudness (LUFS)
TARGET_TP="-1.5"   # true peak (dBTP)
TARGET_LRA="11"    # loudness range (LU)
OUT_BITRATE="320k"
OUT_SAMPLE_RATE="44100"

usage() {
  echo "Usage: $0 <audio file> [audio file ...]"
  echo "Supported formats: mp3 flac wav m4a ogg"
  echo "Output dir: $MUSIC_DIR (override with MUSIC_DIR=...)"
}

if [ "$#" -lt 1 ]; then
  usage
  exit 1
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "ERROR: ffmpeg not found on PATH. Install ffmpeg first." >&2
  exit 1
fi

mkdir -p "$MUSIC_DIR"

# Extract a "key" : "value" field from loudnorm's JSON block.
json_val() {
  printf '%s\n' "$1" | sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | tail -n 1
}

is_number() {
  printf '%s' "$1" | grep -Eq '^-?[0-9]+(\.[0-9]+)?$'
}

total="$#"
idx=0
ingested=0
skipped=0
failed=0
failed_files=""

for src in "$@"; do
  idx=$((idx + 1))
  base="$(basename "$src")"
  prefix="[$idx/$total] $base:"

  if [ ! -f "$src" ]; then
    echo "$prefix FAILED (file not found)"
    failed=$((failed + 1)); failed_files="$failed_files  - $src (not found)\n"
    continue
  fi

  ext="$(printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]')"
  case "$ext" in
    mp3|flac|wav|m4a|ogg) ;;
    *)
      echo "$prefix FAILED (unsupported extension .$ext — want mp3/flac/wav/m4a/ogg)"
      failed=$((failed + 1)); failed_files="$failed_files  - $src (unsupported format)\n"
      continue
      ;;
  esac

  name="${base%.*}"
  out="$MUSIC_DIR/$name.mp3"
  if [ -e "$out" ]; then
    echo "$prefix skipped (already in library: $out)"
    skipped=$((skipped + 1))
    continue
  fi

  # ---- Pass 1: measure ------------------------------------------------------
  echo "$prefix measuring loudness (pass 1/2)..."
  measure_json=""
  if ! measure_json="$(ffmpeg -hide_banner -nostdin -i "$src" -map 0:a:0 \
        -af "loudnorm=I=$TARGET_I:TP=$TARGET_TP:LRA=$TARGET_LRA:print_format=json" \
        -f null - 2>&1 | awk '/^\{/{f=1} f{print} /^\}/{f=0}')" || [ -z "$measure_json" ]; then
    echo "$prefix FAILED (loudness measurement pass failed — is this a valid audio file?)"
    failed=$((failed + 1)); failed_files="$failed_files  - $src (measure pass failed)\n"
    continue
  fi

  m_i="$(json_val "$measure_json" input_i)"
  m_tp="$(json_val "$measure_json" input_tp)"
  m_lra="$(json_val "$measure_json" input_lra)"
  m_thresh="$(json_val "$measure_json" input_thresh)"
  m_offset="$(json_val "$measure_json" target_offset)"

  if ! is_number "$m_i" || ! is_number "$m_tp" || ! is_number "$m_lra" \
     || ! is_number "$m_thresh" || ! is_number "$m_offset"; then
    echo "$prefix FAILED (unusable loudness measurements: I=$m_i TP=$m_tp — silent or corrupt file?)"
    failed=$((failed + 1)); failed_files="$failed_files  - $src (bad measurements)\n"
    continue
  fi

  # ---- Pass 2: normalize + encode ------------------------------------------
  echo "$prefix normalizing to ${TARGET_I} LUFS and encoding MP3 (pass 2/2)..."
  tmp_out="$MUSIC_DIR/.ingest-tmp.$$.$name.mp3"
  err_log="$MUSIC_DIR/.ingest-tmp.$$.log"
  trap 'rm -f "$tmp_out" "$err_log"' EXIT

  if ffmpeg -hide_banner -nostdin -y -i "$src" -map 0:a:0 -map_metadata 0 -vn \
       -af "loudnorm=I=$TARGET_I:TP=$TARGET_TP:LRA=$TARGET_LRA:measured_I=$m_i:measured_TP=$m_tp:measured_LRA=$m_lra:measured_thresh=$m_thresh:offset=$m_offset:linear=true" \
       -ar "$OUT_SAMPLE_RATE" -c:a libmp3lame -b:a "$OUT_BITRATE" -id3v2_version 3 \
       -f mp3 "$tmp_out" >"$err_log" 2>&1; then
    mv "$tmp_out" "$out"
    rm -f "$err_log"
    echo "$prefix done -> $out (was ${m_i} LUFS)"
    ingested=$((ingested + 1))
  else
    echo "$prefix FAILED (encode pass failed; ffmpeg output below)"
    sed 's/^/    | /' "$err_log" | tail -n 15
    rm -f "$tmp_out" "$err_log"
    failed=$((failed + 1)); failed_files="$failed_files  - $src (encode pass failed)\n"
  fi
  trap - EXIT
done

echo ""
echo "==============================================="
echo " Ingest summary"
echo "   ingested: $ingested"
echo "   skipped (already present): $skipped"
echo "   failed:   $failed"
if [ "$failed" -gt 0 ]; then
  printf '%b' "$failed_files"
fi
echo "==============================================="
if [ "$ingested" -gt 0 ]; then
  echo "Liquidsoap watches the music dir — new tracks join the rotation automatically."
fi

[ "$failed" -eq 0 ]
