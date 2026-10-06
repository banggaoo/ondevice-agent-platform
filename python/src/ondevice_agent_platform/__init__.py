"""ondevice-agent-platform: deterministic local agent/model serving core.

Cross-platform Python port of the Swift reference implementation. The core
is stdlib-only; providers are optional imports (mlx-lm on macOS, llama.cpp
everywhere, Apple Foundation Models via a macOS bridge helper).
"""

__version__ = "0.2.0"
