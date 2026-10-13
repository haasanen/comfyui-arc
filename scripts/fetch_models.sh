#!/bin/sh
# One-shot model fetch for Z-Image Turbo (official Comfy-Org files, Apache-2.0).
# Run INSIDE the comfyui container with the models volume mounted:
#   docker run --rm -v /ssd/comfyui-data/models:/models \
#     ghcr.io/haasanen/comfyui-arc:0.1.0 sh /app/scripts/fetch_models.sh
# or: docker cp this script into the running container and exec it.
#
# Chosen for A770 16 GB (no custom nodes needed — all native ComfyUI formats):
#   diffusion: int8_convrot 6.2 GB (native int8, faster than GGUF per upstream)
#   text enc:  qwen_3_4b_fp8_mixed 5.63 GB
#   vae:       ae.safetensors 0.34 GB
set -eu
BASE="https://huggingface.co/Comfy-Org/z_image_turbo/resolve/main/split_files"
cd /models
mkdir -p diffusion_models text_encoders vae
curl -fL --retry 3 -C - -o diffusion_models/z_image_turbo_int8_convrot.safetensors "$BASE/diffusion_models/z_image_turbo_int8_convrot.safetensors"
curl -fL --retry 3 -C - -o text_encoders/qwen_3_4b_fp8_mixed.safetensors "$BASE/text_encoders/qwen_3_4b_fp8_mixed.safetensors"
curl -fL --retry 3 -C - -o vae/ae.safetensors "$BASE/vae/ae.safetensors"
echo "models ready:"
du -sh diffusion_models/* text_encoders/* vae/*
