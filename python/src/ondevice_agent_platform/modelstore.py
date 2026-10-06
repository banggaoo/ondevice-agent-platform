"""Governed artifact acquisition, mirroring ModelStore.swift.

`model pull` is the only acquisition path: it downloads a declared (or
explicit repo+revision) artifact from Hugging Face into `<root>/models/`
with staging, per-file size checks, and sha256 verification recorded in a
manifest. Inference never downloads; a directory without a complete
verified manifest is never treated as ready. Optional `file` in the source
selects one artifact (llama.cpp GGUF routes); unset pulls the whole repo.
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import urllib.error
import urllib.request

from .errors import ErrorCode, PlatformError
from .profiles import ModelSource

HF_API = "https://huggingface.co/api/models"
HF_RESOLVE = "https://huggingface.co"
_CHUNK = 1 << 20
_TIMEOUT = 60


def _dir_name(source: ModelSource, artifact_file: str | None = None) -> str:
    base = f"{source.repo.replace('/', '--')}__{source.revision}"
    if artifact_file:
        base += f"__{artifact_file.replace('.gguf', '')}"
    return base


class ModelStore:
    def __init__(self, root) -> None:
        self._root = root
        os.makedirs(root.models_path, exist_ok=True)
        try:
            os.chmod(root.models_path, 0o700)
        except OSError:
            pass

    def directory(self, source: ModelSource,
                  artifact_file: str | None = None) -> str:
        return os.path.join(self._root.models_path,
                            _dir_name(source, artifact_file))

    def manifest_of(self, source: ModelSource,
                    artifact_file: str | None = None):
        path = os.path.join(self.directory(source, artifact_file),
                            ".oap-manifest.json")
        try:
            with open(path) as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return None

    def is_ready(self, source: ModelSource,
                 artifact_file: str | None = None) -> bool:
        """True only with a complete verified manifest and every file."""
        manifest = self.manifest_of(source, artifact_file)
        if not manifest:
            return False
        directory = self.directory(source, artifact_file)
        for entry in manifest.get("files", []):
            path = os.path.join(directory, entry["name"])
            try:
                if os.path.getsize(path) != entry["size"]:
                    return False
            except OSError:
                return False
        return True

    def list_installed(self) -> list[tuple[str, dict]]:
        out = []
        base = self._root.models_path
        if not os.path.isdir(base):
            return out
        for name in sorted(os.listdir(base)):
            mpath = os.path.join(base, name, ".oap-manifest.json")
            try:
                with open(mpath) as f:
                    out.append((name, json.load(f)))
            except (OSError, json.JSONDecodeError):
                continue
        return out

    def remove(self, source: ModelSource,
               artifact_file: str | None = None) -> None:
        directory = self.directory(source, artifact_file)
        if os.path.isdir(directory):
            shutil.rmtree(directory)

    def pull(self, source: ModelSource, artifact_file: str | None = None,
             progress=None) -> dict:
        """Enumerate the repo tree, download each needed file into staging,
        verify size + sha256 (LFS pointer when the hub reports one), record
        a manifest, then rename into place."""
        listing = self._list_files(source)
        if artifact_file:
            listing = [f for f in listing if f["name"] == artifact_file]
            if not listing:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    f"file not in repo: {artifact_file}")
        directory = self.directory(source, artifact_file)
        staging = directory + ".staging-" + str(os.getpid())
        if os.path.isdir(staging):
            shutil.rmtree(staging)
        os.makedirs(staging)
        total = sum(f.get("size") or 0 for f in listing)
        received_all = [0]

        def report(n: int) -> None:
            if progress and total:
                received_all[0] += n
                progress(min(1.0, received_all[0] / total))

        manifest_files = []
        try:
            for info in listing:
                name = info["name"]
                dest = os.path.join(staging, name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                sha = self._download(source, name, dest,
                                     info.get("oid"), info.get("size"),
                                     report)
                if info.get("size") is not None \
                        and os.path.getsize(dest) != info["size"]:
                    raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                        f"size mismatch: {name}")
                manifest_files.append({"name": name,
                                       "size": os.path.getsize(dest),
                                       "sha256": sha})
            resolved = self._resolve_revision(source)
            manifest = {"repo": source.repo, "revision": source.revision,
                        "resolvedRevision": resolved,
                        "file": artifact_file,
                        "files": manifest_files}
            with open(os.path.join(staging, ".oap-manifest.json"),
                      "w") as f:
                json.dump(manifest, f)
            if os.path.isdir(directory):
                shutil.rmtree(directory)
            os.rename(staging, directory)
            try:
                os.chmod(directory, 0o700)
            except OSError:
                pass
            return manifest
        except BaseException:
            shutil.rmtree(staging, ignore_errors=True)
            raise

    def _list_files(self, source: ModelSource) -> list[dict]:
        """Recursive file listing via the hub API with per-file size + oid."""
        url = (f"{HF_API}/{source.repo}/tree/{source.revision}"
               "?recursive=true&expand=true")
        files: list[dict] = []
        req = urllib.request.Request(url, headers={"User-Agent": "oap/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
                tree = json.loads(r.read())
        except (urllib.error.URLError, json.JSONDecodeError) as e:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                f"hub listing failed: {e}")
        for node in tree:
            if node.get("type") == "file":
                files.append({
                    "name": node["path"],
                    "size": node.get("size"),
                    "oid": node.get("lfs", {}).get("oid"),
                })
        return files

    def _resolve_revision(self, source: ModelSource) -> str | None:
        req = urllib.request.Request(f"{HF_API}/{source.repo}",
                                     headers={"User-Agent": "oap/1.0"})
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as r:
                return json.loads(r.read()).get("sha")
        except (urllib.error.URLError, json.JSONDecodeError):
            return None

    def _download(self, source: ModelSource, name: str, dest: str,
                  expected_oid, expected_size, progress) -> str:
        url = f"{HF_RESOLVE}/{source.repo}/resolve/{source.revision}/{name}"
        req = urllib.request.Request(url, headers={"User-Agent": "oap/1.0"})
        digest = hashlib.sha256()
        received = 0
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as r, \
                    open(dest, "wb") as out:
                while True:
                    chunk = r.read(_CHUNK)
                    if not chunk:
                        break
                    out.write(chunk)
                    digest.update(chunk)
                    received += len(chunk)
                    if progress:
                        progress(len(chunk))
        except urllib.error.URLError as e:
            raise PlatformError(ErrorCode.PROVIDER_UNAVAILABLE,
                                f"download failed: {e}")
        sha = digest.hexdigest()
        # LFS oid is the sha256 of the file; verify when the hub reports it.
        if expected_oid and sha != expected_oid:
            raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                f"sha256 mismatch: {name}")
        if expected_size is not None and received != expected_size:
            raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                f"size mismatch: {name}")
        return sha
