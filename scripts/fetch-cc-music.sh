#!/usr/bin/env bash
#
# fetch-cc-music.sh — download a vetted batch of Creative-Commons / public-domain
# instrumental tracks and add them to the LOFI 247 library.
#
# Every track below was license-checked against its source page and is one of:
#   CC0 / Public Domain  (no attribution legally required), or
#   CC BY 4.0 / 3.0      (attribution REQUIRED — see ATTRIBUTION.md).
# All are cleared for public rebroadcast in a commercial/monetizable context,
# which is what a 24/7 X channel needs. See docs/MUSIC.md for the licensing rules.
#
# It downloads each track, verifies it is real audio (ffprobe), tags it, and runs
# it through scripts/ingest-music.sh (loudness-normalize to -14 LUFS, 320k MP3).
# Idempotent: tracks already in music/ are skipped. Failed downloads are warned
# and skipped, not fatal.
#
# Usage:  ./scripts/fetch-cc-music.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MUSIC_DIR="${MUSIC_DIR:-${REPO_ROOT}/music}"
INGEST="${REPO_ROOT}/scripts/ingest-music.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36"

# slug | artist | title | license | url
# (pipe-separated; keep one track per line)
TRACKS='
holizna-morning-coffee|HoliznaCC0|Morning Coffee|CC0|https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/3oECfGbiMKRefansiQFDoumFo0fXknIhsLtlE3x4.mp3
holizna-peaceful-drift|HoliznaCC0|Peaceful Drift|CC0|https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/SQvtLguk6S1VSthv0oXWycoB6ipUS0pt8jzAxxPq.mp3
holizna-into-the-mist|HoliznaCC0|Into The Mist|CC0|https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/cI5iv9Xga0OOvGsS7mGZn9BlTshZdzAqLW7bmArA.mp3
putman-cort44|Joel Putman|Cort44|CC0|https://archive.org/download/Cort44/Cort.mp3
putman-settle|Joel Putman|Settle|CC0|https://archive.org/download/Settle/Settle.mp3
putman-central|Joel Putman|Central|CC0|https://archive.org/download/Central_911/Central.mp3
putman-localloop|Joel Putman|LocalLoop|CC0|https://archive.org/download/LocalLoop/LocalLoop.mp3
ketsa-reclaimed|Ketsa|Reclaimed|CC BY 4.0|https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/z18YleBSuZUcni4ciIuEdYuSLIXQsWvhYuXwdMus.mp3
ketsa-deep-waves|Ketsa|Deep Waves|CC BY 4.0|https://files.freemusicarchive.org/storage-freemusicarchive-org/tracks/s8WDPJgV2NlV4pQ4lCn6zHCxaqZONZ00Ibv9d2Jt.mp3
kmacleod-cattails|Kevin MacLeod|Cattails|CC BY 4.0|https://incompetech.com/music/royalty-free/mp3-royaltyfree/Cattails.mp3
kmacleod-angel-share|Kevin MacLeod|Angel Share|CC BY 4.0|https://incompetech.com/music/royalty-free/mp3-royaltyfree/Angel%20Share.mp3
kmacleod-sunday-dub|Kevin MacLeod|Sunday Dub|CC BY 4.0|https://incompetech.com/music/royalty-free/mp3-royaltyfree/Sunday%20Dub.mp3
kmacleod-easy-lemon|Kevin MacLeod|Easy Lemon|CC BY 4.0|https://incompetech.com/music/royalty-free/mp3-royaltyfree/Easy%20Lemon.mp3
'

command -v ffprobe >/dev/null || { echo "ffprobe not found (install ffmpeg)"; exit 1; }
[ -x "${INGEST}" ] || { echo "missing ${INGEST}"; exit 1; }
mkdir -p "${MUSIC_DIR}"

to_ingest=()
skipped=0 failed=0

echo "Fetching vetted CC / public-domain tracks into ${MUSIC_DIR}"
while IFS='|' read -r slug artist title license url; do
  [ -z "${slug:-}" ] && continue
  if [ -f "${MUSIC_DIR}/${slug}.mp3" ]; then
    echo "  skip (already present): ${artist} — ${title}"
    skipped=$((skipped + 1))
    continue
  fi
  raw="${WORK}/${slug}.download"
  if ! curl -fsSL --max-time 120 -A "${UA}" -e "https://google.com" -o "${raw}" "${url}"; then
    echo "  WARN download failed, skipping: ${artist} — ${title}"
    failed=$((failed + 1))
    continue
  fi
  dur="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "${raw}" 2>/dev/null | cut -d. -f1 || true)"
  has_audio="$(ffprobe -v error -select_streams a -show_entries stream=codec_type -of csv=p=0 "${raw}" 2>/dev/null | head -1 || true)"
  if [ "${has_audio}" != "audio" ] || [ "${dur:-0}" -lt 30 ] 2>/dev/null; then
    echo "  WARN not valid audio (>=30s), skipping: ${artist} — ${title}"
    failed=$((failed + 1))
    continue
  fi
  tagged="${WORK}/${slug}.mp3"
  ffmpeg -hide_banner -loglevel error -y -i "${raw}" -vn -c:a copy \
    -metadata artist="${artist}" -metadata title="${title}" -metadata comment="${license}" \
    -id3v2_version 3 "${tagged}" 2>/dev/null \
    || ffmpeg -hide_banner -loglevel error -y -i "${raw}" -vn -c:a libmp3lame -q:a 2 \
       -metadata artist="${artist}" -metadata title="${title}" -metadata comment="${license}" \
       -id3v2_version 3 "${tagged}"
  to_ingest+=("${tagged}")
  echo "  fetched: ${artist} — ${title} [${license}]"
done <<< "${TRACKS}"

if [ "${#to_ingest[@]}" -gt 0 ]; then
  echo
  echo "Normalizing + installing ${#to_ingest[@]} track(s) via ingest-music.sh ..."
  MUSIC_DIR="${MUSIC_DIR}" "${INGEST}" "${to_ingest[@]}"
fi

echo
echo "Done. added=${#to_ingest[@]} skipped=${skipped} failed=${failed}"
echo "Liquidsoap picks up new tracks automatically (watch mode) — no restart needed."
echo
echo "ATTRIBUTION: the CC BY tracks (Kevin MacLeod, Ketsa) REQUIRE credit."
echo "See ATTRIBUTION.md and put the credits in your channel's pinned post or bio."
