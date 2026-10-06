"""Symlink overlay for artifacts that declare a ForConditionalGeneration
(VLM) architecture while carrying text-only weights.

Engines route on the declared arch, not the weights: vllm-mlx diverts
them to the uncached multimodal path, and mlx-lm cannot resolve the VLM
label on a text artifact. The overlay links every verified file and
patches config.json to the matching CausalLM arch - the store stays
byte-verified; the shadow dir lives inside models/ as a dot directory
(ignored by listing and the root safety whitelist).
"""
from __future__ import annotations

import json
import os
import shutil

# vllm-mlx's _config_indicates_vlm markers (vllm_mlx/api/utils.py) plus
# the vision-token keys this family of artifacts carries.
_VLM_MARKER_KEYS = {
    "vision_config", "audio_config", "vision_tower", "mm_vision_tower",
    "vision_start_token_id", "vision_end_token_id",
}


def serve_text_dir(models_path: str, directory: str) -> str:
    """Directory an engine should load for a text profile: the artifact
    itself, or an overlay with the arch rewritten when VLM routing would
    otherwise trigger."""
    config_path = os.path.join(directory, "config.json")
    try:
        with open(config_path) as f:
            config = json.load(f)
    except (OSError, json.JSONDecodeError):
        return directory
    archs = config.get("architectures") or []
    patched = [a[:-len("ForConditionalGeneration")] + "ForCausalLM"
               if a.endswith("ForConditionalGeneration") else a
               for a in archs]
    # vllm-mlx also flags VLM on config keys (image_token_id etc.); a
    # text-routed artifact must not carry those markers.
    vlm_keys = {k for k in config
                if k in _VLM_MARKER_KEYS
                or k.endswith(("_token_id", "_token_index"))
                and ("image" in k or "video" in k or "audio" in k
                     or "vision" in k)}
    if patched == list(archs) and not vlm_keys:
        return directory
    overlay = os.path.join(models_path,
                           ".oap-overlay-" + os.path.basename(directory))
    shutil.rmtree(overlay, ignore_errors=True)
    os.makedirs(overlay)
    for name in os.listdir(directory):
        if name == "config.json":
            continue
        os.symlink(os.path.join(directory, name),
                   os.path.join(overlay, name))
    config["architectures"] = patched
    for key in vlm_keys:
        config.pop(key, None)
    with open(os.path.join(overlay, "config.json"), "w") as f:
        json.dump(config, f)
    return overlay
