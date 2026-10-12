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

FROM python:3.12-slim

ARG COMFY_REF=v0.39.0

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# ComfyUI from the official release tarball (pinned ref; CI verifies sha256).
RUN curl -fsSL "https://github.com/Comfy-Org/ComfyUI/archive/refs/tags/${COMFY_REF}.tar.gz" \
        -o /tmp/comfy.tar.gz \
    && echo "095d95805bdf36e73bbd15d6d2ee15fa627708679a2e67b5f467db4c57e7ff0a  /tmp/comfy.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/comfy.tar.gz -C /app --strip-components=1 \
    && rm /tmp/comfy.tar.gz

# 1) ComfyUI's deps first (this pulls CPU torch from PyPI — replaced next).
RUN pip install -r /app/requirements.txt

# 2) Official PyTorch XPU wheels on top, pinned, from PyTorch's own index.
RUN pip install --index-url https://download.pytorch.org/whl/xpu \
        torch==2.14.1+xpu torchvision==0.29.1+xpu \
    && python -c "import torch; assert hasattr(torch, 'xpu'), 'XPU backend missing'"

VOLUME ["/models"]
EXPOSE 8188

# --oneapi-device-selector level_zero:0 = the only Intel GPU visible in the
# container (compose maps ONLY the Arc's render node, so index 0 is the A770).
CMD ["python", "/app/main.py", "--listen", "0.0.0.0", \
     "--models-directory", "/models", \
     "--oneapi-device-selector", "level_zero:0"]
