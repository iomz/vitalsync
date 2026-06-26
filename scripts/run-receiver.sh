#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${VITALSYNC_HOST:-${HOST:-0.0.0.0}}"
PORT="${VITALSYNC_PORT:-${PORT:-8790}}"
DB="${VITALSYNC_DB:-${DB:-$ROOT/vitalsync.sqlite3}}"
PUBLIC_BASE_URL="${VITALSYNC_PUBLIC_BASE_URL:-${PUBLIC_BASE_URL:-http://127.0.0.1:$PORT}}"

PYTHONPATH="$ROOT/receiver/src${PYTHONPATH:+:$PYTHONPATH}" exec python3 -m vitalsync_receiver \
  --host "$HOST" \
  --port "$PORT" \
  --db "$DB" \
  --public-base-url "$PUBLIC_BASE_URL"
