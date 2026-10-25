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

# Trixie base ON PURPOSE (2026-10-25): Intel's GitHub-release GPU debs
# (libze-intel-gpu1, intel-igc-core-2) need glibc >= 2.38; Debian bookworm
# ships 2.36, trixie ships 2.41. Also repositories.intel.com's apt repo is
# CloudFront-blocked from CI (403 for every dist from runner IPs) — so no
# Intel apt repo at all; we install Intel's own release .debs, hash-locked.
FROM python:3.12-slim-trixie

ARG COMFY_REF=v0.42.1

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        libgl1 libglib2.0-0 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Intel GPU userspace compute stack (Level Zero driver for the Arc). The
# +xpu torch wheels ship only the Level Zero LOADER; without the driver
# (libze_intel_gpu.so) torch.xpu.device_count() is 0 and ComfyUI crash-loops
# (observed live 2026-10-25). Intel's apt repo is CloudFront-blocked from CI
# (403 on all dists), so we install the SAME debs Intel publishes on its
# official GitHub releases, hash-locked in scripts/intel_debs.lock (driver
# hashes cross-checked against Intel's published ww35.sum). Versions pinned:
# loader 1.34.0, driver 26.35.39758.10, IGC 2.41.5, gmm 22.10.0 — driver
# hard-pins IGC == 2.41.5, keep them in step (see intel/compute-runtime).
# The driver supports DG2 (A770) on both i915 and xe kernel drivers, so the
# NAS host stays on i915 (Jellyfin/Frigate share that card).
COPY scripts/intel_debs.lock /tmp/intel_debs.lock
RUN mkdir -p /tmp/intel-debs && cd /tmp/intel-debs \
    && while read -r sha url name; do \
         curl -fsSL -o "$name" "$url" \
         && echo "$sha  $name" | sha256sum -c -; \
       done < /tmp/intel_debs.lock \
    && dpkg -i libigdgmm12_22.10.0_amd64.deb intel-igc-core-2_2.41.5+22716_amd64.deb \
              intel-igc-opencl-2_2.41.5+22716_amd64.deb \
              libze1_1.34.0+u22.04_amd64.deb libze-intel-gpu1_26.35.39758.10-0_amd64.deb \
              intel-opencl-icd_26.35.39758.10-0_amd64.deb \
    && ldconfig -p | grep -q libze_intel_gpu \
    && ldconfig -p | grep -q libintelcl \
    && rm -rf /tmp/intel-debs /tmp/intel_debs.lock

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

# Helper scripts (provisioner API + entrypoint) — model control over LAN HTTP.
COPY scripts/ /app/scripts/

# Minimal first-party custom node: ArcAttentionBackend. torch SDPA with a
# mask crashes on XPU/oneDNN ("could not create a primitive", oneDNN -6;
# ComfyUI issue #5270) — this exposes ComfyUI's registered chunked
# pure-torch backends (split/sub_quad) that never touch SDPA. No third-party
# code; it is a two-line patch call against ComfyUI's own attention registry.
COPY custom_nodes/arc_attention.py /app/custom_nodes/arc_attention.py

EXPOSE 8188

# --oneapi-device-selector level_zero:0 = the only Intel GPU visible in the
# container (compose maps ONLY the Arc's render node, so index 0 is the A770).
ENTRYPOINT ["/app/scripts/docker-entrypoint.sh"]
CMD ["--listen", "0.0.0.0", \
     "--models-directory", "/models", \
     "--oneapi-device-selector", "level_zero:0"]
