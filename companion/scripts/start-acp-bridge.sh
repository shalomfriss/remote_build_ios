#!/usr/bin/env bash
# Copyright (c) 2026 Pedro Shakour
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BRIDGE_PY="$ROOT/companion/scripts/acp_tcp_bridge.py"
NGROK_ENDPOINT_PY="$ROOT/companion/scripts/ngrok_endpoint.py"
HOST="${GROK_ACP_HOST:-0.0.0.0}"
PORT="${GROK_ACP_PORT:-7391}"
UPSTREAM="$ROOT/upstream-grok-build"
STUB=0
REAL=0
AGENT="${ACP_AGENT:-codex}"
MODEL="${ACP_MODEL:-}"
AGENT_COMMAND="${ACP_AGENT_COMMAND:-}"
ADVERTISE=1
NO_TLS=0
NO_PAIR=0
DNS_PID=""
BRIDGE_PID=""
NGROK_PID=""
NGROK_LOG=""
USE_NGROK=0
NGROK_URL="${GROK_NGROK_URL:-}"

usage() {
  cat <<'EOF'
Usage: start-acp-bridge.sh [options]

Starts the TLS ACP bridge for the iOS app. Prints PIN + cert fingerprint on start.

Remote access:
  --ngrok                    Expose the TLS bridge through an ngrok TCP endpoint
  --ngrok-url ADDRESS        Use a reserved ngrok TCP address (also GROK_NGROK_URL)

Agent options:
  --agent codex|claude|local   ACP backend (default: codex)
  --model MODEL               Codex/local model; local must start with ollama/
  --agent-command COMMAND     Custom ACP stdio command (overrides agent/model)
EOF
}

cleanup() {
  [[ -n "$BRIDGE_PID" ]] && kill -0 "$BRIDGE_PID" 2>/dev/null && kill "$BRIDGE_PID" 2>/dev/null || true
  [[ -n "$NGROK_PID" ]] && kill -0 "$NGROK_PID" 2>/dev/null && kill "$NGROK_PID" 2>/dev/null || true
  [[ -n "$DNS_PID" ]] && kill -0 "$DNS_PID" 2>/dev/null && kill "$DNS_PID" 2>/dev/null || true
  [[ -n "$NGROK_LOG" ]] && rm -f "$NGROK_LOG"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --stub) STUB=1; shift ;;
    --real) REAL=1; shift ;;
    --agent) AGENT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --agent-command) AGENT_COMMAND="$2"; shift 2 ;;
    --ngrok) USE_NGROK=1; shift ;;
    --ngrok-url) USE_NGROK=1; NGROK_URL="$2"; shift 2 ;;
    --no-tls) NO_TLS=1; shift ;;
    --no-pair) NO_PAIR=1; shift ;;
    --no-advertise) ADVERTISE=0; shift ;;
    --upstream) UPSTREAM="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown: $1" >&2; exit 1 ;;
  esac
done

export GROK_COMPANION_CWD="${GROK_COMPANION_CWD:-$(pwd)}"

ARGS=(--host "$HOST" --port "$PORT" --upstream "$UPSTREAM")
ARGS+=(--agent "$AGENT")
[[ -n "$MODEL" ]] && ARGS+=(--model "$MODEL")
[[ -n "$AGENT_COMMAND" ]] && ARGS+=(--agent-command "$AGENT_COMMAND")
[[ "$STUB" -eq 1 ]] && ARGS+=(--stub)
[[ "$REAL" -eq 1 ]] && ARGS+=(--real)
if [[ "$NO_TLS" -eq 1 || "$NO_PAIR" -eq 1 ]]; then
  if [[ "${GROK_COMPANION_INSECURE:-}" != "1" ]]; then
    echo "[start-acp-bridge] ERROR: --no-tls/--no-pair require GROK_COMPANION_INSECURE=1" >&2
    exit 1
  fi
fi
[[ "$NO_TLS" -eq 1 ]] && ARGS+=(--no-tls)
[[ "$NO_PAIR" -eq 1 ]] && ARGS+=(--no-pair)

# Prepare PIN + fingerprint for Bonjour (bridge reuses via env)
eval "$(python3 -c "
import sys
sys.path.insert(0, '$ROOT/companion/scripts')
from companion_tls import ensure_cert, fresh_pin
c,k,fp = ensure_cert()
pin = fresh_pin()
print(f'export GROK_COMPANION_PIN={pin}')
print(f'export GROK_COMPANION_FP={fp}')
print(f'export GROK_COMPANION_FP_SHORT={fp[:16]}')
")"

echo "[start-acp-bridge] PIN: ${GROK_COMPANION_PIN}"
echo "[start-acp-bridge] cert fingerprint: ${GROK_COMPANION_FP}"
echo "[start-acp-bridge] cert fingerprint (short): ${GROK_COMPANION_FP_SHORT}"

if [[ "$ADVERTISE" -eq 1 ]] && command -v dns-sd >/dev/null 2>&1; then
  # Full DER SHA-256 in TXT so the phone can pin without pasting.
  dns-sd -R "Coding Agent" _grok-build._tcp local "$PORT" "fp=${GROK_COMPANION_FP}" "fps=${GROK_COMPANION_FP_SHORT}" >/dev/null 2>&1 &
  DNS_PID=$!
  echo "[start-acp-bridge] Bonjour: Coding Agent _grok-build._tcp :${PORT} (fp in TXT)"
fi

echo "[start-acp-bridge] workspace=${GROK_COMPANION_CWD}"
echo "[start-acp-bridge] agent=${AGENT}${MODEL:+ model=${MODEL}}"

if [[ "$USE_NGROK" -eq 1 ]]; then
  if ! command -v ngrok >/dev/null 2>&1; then
    echo "[start-acp-bridge] ERROR: ngrok is not installed (https://ngrok.com/download)" >&2
    exit 1
  fi

  NGROK_LOG="$(mktemp -t grok-build-ngrok.XXXXXX)"
  NGROK_ARGS=(tcp "127.0.0.1:${PORT}" --name grok-build-acp --log stdout --log-format json)
  [[ -n "$NGROK_URL" ]] && NGROK_ARGS+=(--url "$NGROK_URL")
  ngrok "${NGROK_ARGS[@]}" >"$NGROK_LOG" 2>&1 &
  NGROK_PID=$!

  NGROK_ENDPOINT=""
  for _ in {1..150}; do
    NGROK_ENDPOINT="$(python3 "$NGROK_ENDPOINT_PY" "$NGROK_LOG" tcp)"
    [[ -n "$NGROK_ENDPOINT" ]] && break
    if ! kill -0 "$NGROK_PID" 2>/dev/null; then
      echo "[start-acp-bridge] ERROR: ngrok stopped before creating a tunnel" >&2
      tail -n 10 "$NGROK_LOG" >&2
      exit 1
    fi
    sleep 0.1
  done

  if [[ -z "$NGROK_ENDPOINT" ]]; then
    echo "[start-acp-bridge] ERROR: timed out waiting for the ngrok endpoint" >&2
    tail -n 10 "$NGROK_LOG" >&2
    exit 1
  fi

  echo "[start-acp-bridge] ngrok endpoint: ${NGROK_ENDPOINT}"
  echo "[start-acp-bridge] paste that endpoint and the PIN into the iOS app"
fi

python3 "$BRIDGE_PY" "${ARGS[@]}" &
BRIDGE_PID=$!
wait "$BRIDGE_PID"
