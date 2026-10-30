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
    # Device-wait guard: the A770 is shared (Jellyfin/Frigate); if the render
    # node is briefly contended at container start, zeInit can report zero
    # devices and ComfyUI dies instantly under restart:unless-stopped. Wait
    # up to 90 s for the device to answer instead of crash-looping. Skip with
    # COMFY_GPU_GUARD=0.
    if [ "${COMFY_GPU_GUARD:-1}" = "1" ]; then
        w=0
        until python -c "import torch,sys; sys.exit(0 if torch.xpu.device_count()>0 else 1)" 2>/dev/null; do
            w=$((w+10))
            if [ "$w" -ge 90 ]; then
                echo "[entrypoint] WARNING: still no XPU device after 90s, starting anyway" >&2
                break
            fi
            echo "[entrypoint] no XPU device yet, retrying in 10s ($w/90)" >&2
            sleep 10
        done
    fi
    exec python /app/main.py "$@"
else
    exec "$@"
fi
