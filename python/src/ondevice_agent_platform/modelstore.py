"""Governed artifact acquisition, mirroring ModelStore.swift.

`model pull` is the only acquisition path: it downloads a declared (or
explicit repo+revision) artifact from Hugging Face into `<root>/models/`
with staging, per-file size checks, and sha256 verification recorded in
a `manifest.json`. Inference never downloads; a directory without a
complete verified manifest is never treated as ready. Optional `file`
in the source selects one artifact (llama.cpp GGUF routes); unset pulls
the whole repo.

On-disk contract is identical to the Swift store so artifacts pulled by
either implementation are interchangeable:
  models/<repo--owner__revision>/manifest.json
  models/.staging-<dirName>-<pid>/   - in-flight pull
"""
from __future__ import annotations

import hashlib
import json
import os
import shutil
import time
import urllib.error
import urllib.request

from .errors import ErrorCode, PlatformError
from .profiles import ModelSource

HF_API = "https://huggingface.co/api/models"
HF_RESOLVE = "https://huggingface.co"
MANIFEST_NAME = "manifest.json"
_STAGING_PREFIX = ".staging-"
_CHUNK = 1 << 20
_TIMEOUT = 60


def _dir_name(source: ModelSource, artifact_file: str | None = None) -> str:
    base = (source.repo.replace("/", "--")
            + "__" + source.revision.replace("/", "-"))
    if artifact_file:
        base += "__" + artifact_file.replace(".gguf", "")
    return base


def _safe_relative(path: str) -> bool:
    """Swift isSafeRelativePath: non-empty, no leading/trailing '/', no
    NUL, and no segment that is '.', '..', or empty. Dotfiles like
    .gitattributes are legal filenames."""
    if not isinstance(path, str) or not path or "\x00" in path \
            or path.startswith("/") or path.endswith("/") or "\\" in path:
        return False
    return not any(seg in (".", "..", "") for seg in path.split("/"))


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
                            MANIFEST_NAME)
        try:
            with open(path) as f:
                manifest = json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
        if (manifest.get("repo") != source.repo
                or manifest.get("revision") != source.revision):
            return None
        return manifest

    def _validated_manifest(self, dir_name: str):
        """Swift validatedManifest: parse, schemaVersion, safe relative
        paths, no symlinks/dirs, size match. Returns manifest or None."""
        directory = os.path.join(self._root.models_path, dir_name)
        if os.path.islink(directory):
            return None
        try:
            with open(os.path.join(directory, MANIFEST_NAME)) as f:
                manifest = json.load(f)
        except (OSError, json.JSONDecodeError):
            return None
        if manifest.get("schemaVersion") != 1:
            return None
        for entry in manifest.get("files", []):
            rel = entry.get("path")
            if not _safe_relative(rel):
                return None
            path = os.path.join(directory, rel)
            if os.path.islink(path) or not os.path.isfile(path):
                return None
            try:
                if os.path.getsize(path) != entry.get("size"):
                    return None
            except OSError:
                return None
        return manifest

    def is_ready(self, source: ModelSource,
                 artifact_file: str | None = None) -> bool:
        """Stat-only readiness: manifest parses, matches the source, and
        every listed file exists as a regular file with matching size.
        Hash verification happens once at pull time."""
        dir_name = _dir_name(source, artifact_file)
        manifest = self._validated_manifest(dir_name)
        if not manifest:
            return False
        return (manifest.get("repo") == source.repo
                and manifest.get("revision") == source.revision)

    def list_installed(self) -> list[tuple[str, dict]]:
        out = []
        base = self._root.models_path
        if not os.path.isdir(base):
            return out
        for name in sorted(os.listdir(base)):
            if name.startswith(".") or name.startswith(_STAGING_PREFIX):
                continue
            manifest = self._validated_manifest(name)
            if manifest:
                out.append((name, manifest))
        return out

    def remove(self, source: ModelSource,
               artifact_file: str | None = None) -> None:
        directory = self.directory(source, artifact_file)
        if os.path.isdir(directory) and not os.path.islink(directory):
            shutil.rmtree(directory)

    def pull(self, source: ModelSource, artifact_file: str | None = None,
             progress=None, should_stop=None) -> dict:
        """Enumerate the repo tree, download each needed file into staging,
        verify size + sha256 (LFS pointer when the hub reports one), record
        a manifest, then rename into place. `should_stop` is consulted
        between chunks and files; a true answer aborts the pull as
        CANCELLED and cleans staging."""
        listing = self._list_files(source)
        if artifact_file:
            listing = [f for f in listing if f["name"] == artifact_file]
            if not listing:
                raise PlatformError(ErrorCode.NOT_FOUND,
                                    f"file not in repo: {artifact_file}")
        directory = self.directory(source, artifact_file)
        staging = os.path.join(
            self._root.models_path,
            _STAGING_PREFIX + os.path.basename(directory)
            + "-" + str(os.getpid()))
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
                if should_stop is not None and should_stop():
                    raise PlatformError(ErrorCode.CANCELLED)
                name = info["name"]
                if not _safe_relative(name):
                    raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                        f"unsafe path in listing: {name}")
                dest = os.path.join(staging, name)
                os.makedirs(os.path.dirname(dest), exist_ok=True)
                sha = self._download(source, name, dest,
                                     info.get("oid"), info.get("size"),
                                     report, should_stop)
                if info.get("size") is not None \
                        and os.path.getsize(dest) != info["size"]:
                    raise PlatformError(ErrorCode.STORAGE_FAILURE,
                                        f"size mismatch: {name}")
                manifest_files.append({"path": name,
                                       "size": os.path.getsize(dest),
                                       "sha256": sha,
                                       "oid": info.get("oid")})
            resolved = self._resolve_revision(source)
            manifest = {"schemaVersion": 1,
                        "repo": source.repo, "revision": source.revision,
                        "resolvedRevision": resolved,
                        "pulledAt": time.time(),
                        "file": artifact_file,
                        "files": manifest_files}
            with open(os.path.join(staging, MANIFEST_NAME), "w") as f:
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
                  expected_oid, expected_size, progress,
                  should_stop=None) -> str:
        url = f"{HF_RESOLVE}/{source.repo}/resolve/{source.revision}/{name}"
        req = urllib.request.Request(url, headers={"User-Agent": "oap/1.0"})
        digest = hashlib.sha256()
        received = 0
        try:
            with urllib.request.urlopen(req, timeout=_TIMEOUT) as r, \
                    open(dest, "wb") as out:
                while True:
                    if should_stop is not None and should_stop():
                        raise PlatformError(ErrorCode.CANCELLED)
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
