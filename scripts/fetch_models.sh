#!/bin/sh
# CLI for model-set provisioning — thin wrapper over provision.py (the
# single source of truth: model_sets.json + HTTP API on :8189).
# Usage: sh /app/scripts/fetch_models.sh [z-image,...]  (default: z-image;
# 0/none = no-op). Idempotent + resumable; which sets the container fetches
# at start is set by FETCH_MODELS in compose. To add a set: verify exact HF
# URLs + sizes against the A770's 16 GB FIRST, then add it to
# /app/scripts/model_sets.json — never ship unverified URLs.
exec python /app/scripts/provision.py fetch "${1:-z-image}"
