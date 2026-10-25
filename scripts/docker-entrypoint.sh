#!/bin/sh
# ENTRYPOINT for comfyui-arc.
#
# The container NEVER fetches models itself (owner call 2026-10-25: startup
# pulls are not wanted). It boots straight into serving. Model provisioning
# happens ONLY via the provisioner HTTP API, driven by the agent that
# operates ComfyUI:
#   provision.py serve on :8189 — GET /sets, GET /status,
#   POST /models {"set":...}, DELETE /models?set=... Keyless by design
#   (LAN-only, strata convention). Disable with PROVISIONER_DISABLE=1.
#
# Any non-server first argument (python -c ..., sh -c ..., --entrypoint
# overrides) execs verbatim so CI smokes and diagnostics stay network-free.
set -eu

first="${1:-}"

if [ "${PROVISIONER_DISABLE:-0}" != "1" ] && [ -f /app/scripts/provision.py ]; then
    python /app/scripts/provision.py serve &
fi

if [ "${first#--}" != "$first" ]; then
    exec python /app/main.py "$@"
else
    exec "$@"
fi
