#!/usr/bin/env bash
#
# lofi247 — operator status at a glance.
#
# Shows: service state, last streamer log lines, current now-playing track,
# and Icecast listener count. Every section fails soft — a down service
# prints "unavailable" instead of aborting the report.
#
# Usage: ./scripts/status.sh

set -u  # deliberately no -e: sections must tolerate failure

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "${SCRIPT_DIR}")"
STREAMER_LOG_LINES=20
CURL_TIMEOUT=5

cd "${REPO_DIR}" || { echo "ERROR: cannot cd to ${REPO_DIR}" >&2; exit 1; }

if docker compose version >/dev/null 2>&1; then
  COMPOSE=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE=(docker-compose)
else
  echo "ERROR: docker compose not found — is Docker installed?" >&2
  exit 1
fi

section() { printf '\n=== %s ===\n' "$*"; }

# --- Services ---------------------------------------------------------------
section "Services (docker compose ps)"
if ! "${COMPOSE[@]}" ps 2>/dev/null; then
  echo "unavailable (is the Docker daemon running?)"
fi

# --- Streamer logs ----------------------------------------------------------
section "Streamer — last ${STREAMER_LOG_LINES} log lines"
if ! "${COMPOSE[@]}" logs --tail "${STREAMER_LOG_LINES}" streamer 2>/dev/null; then
  echo "unavailable (streamer not running?)"
fi

# --- Now playing ------------------------------------------------------------
section "Now playing"
NOWPLAYING="$("${COMPOSE[@]}" exec -T liquidsoap cat /data/nowplaying.txt 2>/dev/null)"
if [[ -n "${NOWPLAYING}" ]]; then
  echo "${NOWPLAYING}"
else
  echo "unavailable (liquidsoap down, or no track change written yet)"
fi

# --- Icecast listeners ------------------------------------------------------
section "Icecast listeners"
# Try host port 8000 first (only works if published), then fall back to
# querying from inside the compose network via the streamer container
# (its image ships curl for the entrypoint's readiness check).
STATUS_JSON="$(curl -fsS -m "${CURL_TIMEOUT}" http://localhost:8000/status-json.xsl 2>/dev/null)"
if [[ -z "${STATUS_JSON}" ]]; then
  STATUS_JSON="$("${COMPOSE[@]}" exec -T streamer \
    curl -fsS -m "${CURL_TIMEOUT}" http://icecast:8000/status-json.xsl 2>/dev/null)"
fi
if [[ -n "${STATUS_JSON}" ]]; then
  LISTENERS="$(printf '%s' "${STATUS_JSON}" \
    | grep -o '"listeners":[0-9]*' \
    | cut -d: -f2 \
    | awk '{ sum += $1 } END { print sum + 0 }')"
  echo "listeners: ${LISTENERS:-0}"
  if printf '%s' "${STATUS_JSON}" | grep -q '"listenurl"'; then
    echo "mount:     up (/radio)"
  else
    echo "mount:     NO SOURCE CONNECTED (liquidsoap not feeding icecast?)"
  fi
else
  echo "unavailable (icecast down, or curl missing in streamer image)"
fi

printf '\n'
