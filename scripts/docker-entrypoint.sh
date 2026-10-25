#!/bin/sh
# ENTRYPOINT for comfyui-arc. Strata-style first-run: fetch the model sets
# named by FETCH_MODELS (default: z-image) once, then serve.
#
# Guards:
#  - Only the default server launch provisions: recognised by the first CMD
#    argument starting with "--" (CMD starts with --listen). Any other first
#    argument (python -c ..., sh -c ..., --entrypoint overrides) is a
#    diagnostic command and is exec'd verbatim WITHOUT downloading anything.
#  - FETCH_MODELS=0 (or none) disables provisioning entirely (pre-seeded
#    volume, offline host); the fetch script itself is idempotent + resumable.
set -eu

first="${1:-}"

if [ "${first#--}" != "$first" ]; then
    # default server launch
    sets="${FETCH_MODELS:-z-image}"
    if [ "$sets" != "0" ] && [ "$sets" != "none" ]; then
        sh /app/scripts/fetch_models.sh "$sets"
    fi
    exec python /app/main.py "$@"
else
    # explicit command override (diagnostics, shells)
    exec "$@"
fi
