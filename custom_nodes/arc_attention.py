"""Arc Attention Backend — force a dense attention implementation that avoids
torch SDPA. On Intel Arc (XPU + oneDNN), masked SDPA dies with
"could not create a primitive" / "std::future_error: Broken promise"
(oneDNN error -6, see ComfyUI #5270). "split" and "sub_quad" are ComfyUI's
chunked pure-torch backends: slower, but they never call SDPA, so they work
on Arc. Select "split" for anything with masks (Lumina/Z-Image/Qwen).
"""
import comfy.ldm.modules.attention as attention  # noqa: E402 (resolved in-image only)

_AVAILABLE = [n for n in ("split", "sub_quad", "pytorch")
              if attention.get_attention_function(n, None) is not None]


class ArcAttentionBackend:
    @classmethod
    def INPUT_TYPES(cls):
        return {"required": {
            "model": ("MODEL",),
            "backend": (_AVAILABLE or ["pytorch"],),
        }}

    RETURN_TYPES = ("MODEL",)
    FUNCTION = "patch"
    CATEGORY = "model/patch"
    DESCRIPTION = ("Force dense attention implementation. Use 'split' on "
                   "Intel Arc: masked bf16 SDPA crashes on XPU/oneDNN.")

    def patch(self, model, backend):
        fn = attention.get_attention_function(backend, None)
        if fn is None:
            raise ValueError(f"attention backend {backend!r} unavailable")
        m = model.clone()
        m.set_model_optimized_attention(fn)
        return (m,)


NODE_CLASS_MAPPINGS = {"ArcAttentionBackend": ArcAttentionBackend}
NODE_DISPLAY_NAME_MAPPINGS = {"ArcAttentionBackend": "Arc Attention Backend (no SDPA)"}
