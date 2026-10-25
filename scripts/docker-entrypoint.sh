#!/bin/sh
# ENTRYPOINT for comfyui-arc.
#
# 1) Provisioner HTTP API (model control over LAN, no shell needed):
#    provision.py serve on :8189 — GET /sets, GET /status,
#    POST /models {"set":...}, DELETE /models?set=... Keyless by design
#    (LAN-only, strata convention). Disable with PROVISIONER_DISABLE=1.
# 2) Strata-style first-run provisioning: fetch FETCH_MODELS sets (default
#    z-image; "0"/none disables) before serving. Idempotent + resumable.
# 3) Only the default server launch (first CMD arg starts with "--")
#    provisions; any other first argument (python -c ..., sh -c ...,
#    --entrypoint overrides) execs verbatim WITHOUT network, so CI smokes
#    and diagnostics never download anything.
set -eu

first="${1:-}"

if [ "${PROVISIONER_DISABLE:-0}" != "1" ] && [ -f /app/scripts/provision.py ]; then
    python /app/scripts/provision.py serve &
fi

if [ "${first#--}" != "$first" ]; then
    sets="${FETCH_MODELS:-z-image}"
    if [ "$sets" != "0" ] && [ "$sets" != "none" ]; then
        sh /app/scripts/fetch_models.sh "$sets"
    fi
    exec python /app/main.py "$@"
else
    exec "$@"
fi
