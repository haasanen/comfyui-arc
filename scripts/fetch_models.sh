#!/bin/sh
# One-shot model fetch with named model SETS (comma-separated, default:
# z-image). Idempotent: each set checks its main file and skips when
# already present; partial downloads resume (curl -C -).
#
# Which sets the container fetches at start is controlled by the
# FETCH_MODELS env var in compose (default "z-image"; "0"/"none" = never).
# To add a set: verify exact HF URLs + sizes against the A770's 16 GB
# FIRST, then add a case below — never ship unverified URLs.
set -eu

fetch_z_image() {
    # Official Comfy-Org files, Apache-2.0, native formats — no custom nodes.
    # Chosen for A770 16 GB:
    #   diffusion: int8_convrot 6.2 GB (native int8, faster than GGUF per upstream)
    #   text enc:  qwen_3_4b_fp8_mixed 5.63 GB
    #   vae:       ae.safetensors 0.34 GB
    [ -f /models/diffusion_models/z_image_turbo_int8_convrot.safetensors ] && {
        echo "[fetch] z-image already present, skipping."; return 0; }
    BASE="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files"
    mkdir -p /models/diffusion_models /models/text_encoders /models/vae
    cd /models
    curl -fL --retry 3 -C - -o diffusion_models/z_image_turbo_int8_convrot.safetensors "$BASE/diffusion_models/z_image_turbo_int8_convrot.safetensors"
    curl -fL --retry 3 -C - -o text_encoders/qwen_3_4b_fp8_mixed.safetensors "$BASE/text_encoders/qwen_3_4b_fp8_mixed.safetensors"
    curl -fL --retry 3 -C - -o vae/ae.safetensors "$BASE/vae/ae.safetensors"
    echo "[fetch] z-image done."
}

wanted="${1:-z-image}"
OLDIFS=$IFS; IFS=','
for s in $wanted; do
    case "$s" in
        z-image) fetch_z_image ;;
        none|0) : ;;
        *) echo "[fetch] unknown model set: $s (known: z-image)" >&2; exit 1 ;;
    esac
done
IFS=$OLDIFS
echo "model sets ready:"
du -sh /models/diffusion_models/* /models/text_encoders/* /models/vae/*
