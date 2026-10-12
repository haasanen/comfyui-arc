# comfyui-arc

ComfyUI container image for **Intel Arc GPUs** (built for the A770 16 GB in
the NAS), assembled exclusively from vendor-official sources:

| Component | Source | Pin |
|---|---|---|
| Base image | `python:3.12-slim` (Docker Hub official) | 3.12 |
| PyTorch XPU | `download.pytorch.org/whl/xpu` (PyTorch's own index) | `torch==2.9.1+xpu`, `torchvision==0.29.1+xpu` |
| ComfyUI | official `Comfy-Org/ComfyUI` GitHub release tarball | `v0.39.0`, sha256-pinned in the Dockerfile |

No third-party "prebuilt for Arc" images are involved. Upgrades = bump the
pins in the Dockerfile (the checksum is recomputed by CI failing loudly if
mismatched).

## Why not a prebuilt image?

Community ComfyUI-Arc images exist but have no publisher track record or
audits. This image's entire trust surface is: official Python base +
PyTorch's wheel index + a checksum-pinned GitHub release tarball — the same
sources you already trust for pip installs.

## Image

`ghcr.io/haasanen/comfyui-arc` — tags: `main`, `sha-<commit>`, `v<semver>`.

## Device notes (Intel Arc)

- ComfyUI v0.39.0 has **no `--device` flag**; the Arc is pinned via
  `--oneapi-device-selector level_zero:0` (baked into CMD).
- Models dir flag is `--models-directory` (not `--models`).
- Pass ONLY the Arc's render node into the container (stable by-path
  mapping), then `level_zero:0` is unambiguously the A770.
- Host prerequisite: Arc bound to the `xe` kernel driver + ReBAR enabled.

## Compose example

```yaml
  comfyui:
    image: ghcr.io/haasanen/comfyui-arc:main
    container_name: comfyui
    restart: unless-stopped
    ports:
      - 8188:8188
    devices:
      - source: /dev/dri/by-path/pci-0000:06:00.0-card
        target: /dev/dri/card0
        permissions: rwm
      - source: /dev/dri/by-path/pci-0000:06:00.0-render
        target: /dev/dri/renderD128
        permissions: rwm
    volumes:
      - /ssd/comfyui-data/models:/models
    networks:
      - hermes_net
```

Verify after start:

```
docker exec comfyui python -c "import torch; print(torch.xpu.device_count(), torch.xpu.get_device_name(0))"
# expect: 1 Intel Arc A770
```
