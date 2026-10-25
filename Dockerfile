# ComfyUI for Intel Arc — built ONLY from vendor-official sources:
#   - base:    python:3.12-slim (Docker Hub official image)
#   - torch:   PyTorch's own XPU wheel index (download.pytorch.org)
#   - ComfyUI: official Comfy-Org GitHub release tag (pinned, checksum-verified in CI)
# No third-party "prebuilt for Arc" images anywhere.
#
# Verified against ComfyUI v0.39.0 source (2026-10-12):
#   - models dir flag is --models-directory (NOT --models)
#   - Arc device pin flag is --oneapi-device-selector (there is no --device)
#   - requirements.txt lists bare torch/torchvision, so the XPU wheels are
#     installed AFTER requirements to win (otherwise PyPI wheels clobber them)

# Bookworm base ON PURPOSE: Intel's GPU apt repo serves bookworm but not
# trixie (CI proved: https://repositories.intel.com/gpu/dists/trixie/InRelease
# -> 403, 2026-10-25). Do not bump this base without checking Intel repo support.
FROM python:3.12-slim-bookworm

ARG COMFY_REF=v0.42.1

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 curl ca-certificates gnupg \
    && rm -rf /var/lib/apt/lists/*

# Intel GPU userspace compute stack (Level Zero driver for the Arc) from
# Intel's own apt repo — the +xpu torch wheels ship only the Level Zero
# LOADER; without libze_intel_gpu.so the kernel driver has nothing to
# talk to and torch.xpu.device_count() is 0 (observed live 2026-10-25:
# ComfyUI crash-loop "XPU device count is zero"). Vendor-official repo;
# intel-level-zero-gpu supports DG2 (A770) on both i915 and xe KMDs, so
# the NAS host can stay on i915 (Jellyfin/Frigate share that card).
RUN . /etc/os-release \
    && curl -fsSL https://repositories.intel.com/gpu/intel-graphics.key \
        | gpg --dearmor --output /usr/share/keyrings/intel-graphics.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/intel-graphics.gpg] https://repositories.intel.com/gpu/ ${VERSION_CODENAME} release" \
        > /etc/apt/sources.list.d/intel-gpu.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends level-zero intel-level-zero-gpu \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ComfyUI from the official release tarball (pinned ref; CI verifies sha256).
RUN curl -fsSL "https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/${COMFY_REF}.tar.gz" \
        -o /tmp/comfy.tar.gz \
    && echo "8fb71e51c10c6261fe8dcfdbebe550a1d4ec6b74b6c57515e1b7313dbe4a215b  /tmp/comfy.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/comfy.tar.gz -C /app --strip-components=1 \
    && rm /tmp/comfy.tar.gz

# 1) ComfyUI's deps first (this pulls CPU torch from PyPI — replaced next).
RUN pip install -r /app/requirements.txt

# 2) Official PyTorch XPU wheels on top, pinned, from PyTorch's own index.
RUN pip install --index-url https://download.pytorch.org/whl/xpu \
        torch==2.14.1+xpu torchvision==0.29.1+xpu \
    && python -c "import torch; assert hasattr(torch, 'xpu'), 'XPU backend missing'"

VOLUME ["/models"]

# Helper scripts (fetch_models.sh) — baked in so model setup against a
# running container is ONE command: docker exec comfyui sh /app/scripts/fetch_models.sh
COPY scripts/ /app/scripts/

EXPOSE 8188

# --oneapi-device-selector level_zero:0 = the only Intel GPU visible in the
# container (compose maps ONLY the Arc's render node, so index 0 is the A770).
ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
CMD ["--listen", "0.0.0.0", \
     "--models-directory", "/models", \
     "--oneapi-device-selector", "level_zero:0"]
