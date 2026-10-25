#!/bin/sh
# Manual CLI for model-set provisioning — thin wrapper over provision.py
# (the single source of truth: model_sets.json + HTTP API on :8189).
# The container itself NEVER fetches at start (owner call); the normal path
# is POST /models over HTTP. This CLI exists for in-container debugging only.
# Usage: sh /app/scripts/fetch_models.sh [z-image,...] (default: z-image).
# Idempotent + resumable. To add a set: verify exact HF URLs + sizes against
# the A770's 16 GB FIRST, then add it to /app/scripts/model_sets.json —
# never ship unverified URLs.
exec python /app/scripts/provision.py fetch "${1:-z-image}"
