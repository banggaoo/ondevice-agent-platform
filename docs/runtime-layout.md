# Proposed runtime storage layout

**Status:** root and SQLite engine confirmed by the user (2026-10-03); implemented in M1 for `config.json`, `registry.json`, `state.sqlite3`, the exclusive `lock.fd`, and the nonsecret `daemon.json` port marker, all under the resolved root (default `~/.ondevice-agent-platform`, overridable by absolute `--data-root`), plus `models/` for pulled open-weight artifacts (2026-10-04). Owned directories are 0700, owned files 0600; symlinks, non-owned state, and unrelated nonempty roots are refused. One resolved application-data root per installation; directory placement does not establish a sandbox. The platform repository and the separate ARTEMIS source checkout are not runtime state directories.

## Root selection

The user has selected `~/.ondevice-agent-platform/` as the runtime-data root, superseding the earlier Application Support recommendation. This document does not create the directory. A hidden path is organization, not secrecy or confinement, and the selected root does not grant general home-directory access or prove process isolation.

Packaging must be compatible with this location: an unsandboxed per-user utility uses normal account permissions, while a sandboxed distribution needs verified user-granted access or a separately agreed root design. For the chosen GitHub-downloadable executable delivery, an unsandboxed per-user utility is a proposed packaging candidate, not an accepted confinement design. Signing, notarization, sandboxing, and PCC compatibility still require evaluation. Do not silently move authoritative approval state to Application Support or bypass sandbox restrictions. Foundation-resolved cache locations remain appropriate for future owned artifacts. [Apple support-directory API](https://developer.apple.com/documentation/foundation/url/applicationsupportdirectory), [App Sandbox file access](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox).

## Logical layout

```text
~/.ondevice-agent-platform/
├── config.json                 # Versioned nonsecret settings; user-managed changes
├── registry.json               # Validated model declarations (builtin.linear ml entries and mlx llm source entries; agent/harness metadata stays compiled-in)
├── models/                     # Pulled open-weight artifacts (explicit `model pull` only)
│   ├── .staging-*/             # In-flight download; renamed into place on success, never served
│   └── <owner--name__rev>/     # Verified snapshot + manifest.json (repo, revision, files, sha256)
├── state.sqlite3               # Selected SQLite store; core jobs, config metadata, optional agent checkpoints/proposals; schema/protocol proposed
├── proposals/                  # Regenerable Markdown views of immutable records
├── exports/                    # Explicitly previewed local review packages
├── logs/
│   ├── telemetry/              # Bounded content-free resource/task metrics
│   └── diagnostics/            # Optional redacted capture; opt-in and quota
└── sessions/                   # OPTIONAL per-consumer scratch, created only when needed
    ├── agent/<agent-id>/<session-id>/    # ACP-agent scratch for declared sessions
    └── external/<consumer-id>/<session-id>/  # external-consumer scratch for declared jobs
```

This is a documentation example, not executable configuration. Simple status operations need no per-session directory, and durable authorization/decision records do not depend on session folders. Session identifiers are opaque validated values scoped to a consumer, not arbitrary caller-supplied paths, and a session directory is not a sandbox or an authority boundary. Provider, model, agent, and harness-profile definitions are distinct versioned logical namespaces in the registry; an agent or harness version reference is a reviewed registry record, not a code downloader or a training directory. A model entry records kind (`llm` or `ml`), task, and input/output schema metadata in addition to its identity and capacity fields. An ACP session maps logically to a pinned agent/harness run record; the baseline serving facility does not require the Operator or a per-session folder. Embedded SQLite is the selected engine for core jobs, configuration metadata, and optional agent checkpoints/proposals; the Operator is not a prerequisite for any of it, and no file-only alternative is currently required.

Apple-managed model weights live under OS management, not in this tree. Owned open-weight weights live under `models/` and are populated only by the explicit `model pull` command: downloads land in a `.staging-*` sibling, every manifest-listed file is verified (size, and sha256 for LFS objects) before the directory is renamed into place, and a directory without a complete manifest is never treated as ready. Manifest paths are validated as safe relative paths; symlinked files or directories and traversal paths are refused. Do not create training folders/datasets merely because a future roadmap mentions them.

## State and isolation

The `PlatformSupervisor` is the authoritative state writer. Validate configuration and capability inventory before use; a JSON edit does not automatically promote a model, route, or permission. A future change needs versioning, review, validation, and rollback. Exports/views are not an approval database.

Restrict owned directories/files to the intended account; never store secrets in JSON or diagnostic content. The current product stores no API credentials at all (D50): owned-directory permissions and the bounded local APIs remain, but they do not isolate the root from another process running as the same account, and no directory or peer-user isolation is claimed. Logical per-consumer IDs, access checks, and bounded queries prevent accidental cross-consumer sharing; directories alone do not.

File locks coordinate competing writers and atomic publication prevents partial views. Neither prevents an unrestricted same-user process from reading or changing other files. Optional worker confinement and broker scopes remain separate OS/application boundaries. A folder named `sandboxes` cannot authorize generated-code execution or prove confinement.

The browser sees bounded local API responses rather than the root directory: under D50, trusted-local status/registry/job reads need no session, while SSE events, console Operator chat, and browser mutations retain the automatic session/CSRF guards. Runtime records and selected proposal evidence are not served as arbitrary static files. Preserve the [retention and closure policy](safety-and-approvals.md) across restarts and account for journals, temporary files, and owned exports during deletion.

No automatic migration between roots is planned in MVP. If a later installation changes roots, require a deliberate quiescent migration with version/record verification and recoverable backup; do not split authoritative approval state across two roots.
