# Security Policy

This project is intended for local/private deployment by default.

## Reporting a vulnerability

Before a public release, maintainers should enable **GitHub Private Vulnerability Reporting** for the repository. When available, use the repository's **Security → Report a vulnerability** flow rather than opening a public issue with exploit details.

If private vulnerability reporting is not enabled, contact the maintainer through a non-public channel listed on the maintainer's GitHub profile. Do not post secrets, exploit payloads, private documents, or working attack details in a public issue.

## Operational guidance

- Keep the default profile: only Open WebUI is published on `127.0.0.1`; raw Ollama, the curated model router, and Docling remain internal.
- Use `make debug-up` only temporarily; it publishes the raw Ollama and Docling localhost ports. Open WebUI itself should continue to use the curated model router.
- Never commit `.env`, backup bundles, user data, benchmark data from private documents, or model weights.
- Treat `backups/` as secret-bearing data because it includes the local `.env`.
- Review upstream image/model releases and security advisories before upgrades.
- Run `make check`, `make smoke-test`, and `make benchmark` after dependency changes.
- Do not expose the stack to a LAN/public network without a separate threat model, TLS/reverse proxy, authentication review, and network controls.
## Backups and recovery

Backup directories contain local secrets and may contain private chats/documents. Store them with permissions appropriate for sensitive data. Restore verifies checksums and rejects links/special archive members before extraction, but you should still avoid accepting backup bundles from untrusted parties.

Runtime versions are selected by the Git-tracked `versions.env`, not restored from `.env`. Cross-version Open WebUI database restores are blocked by default; use the explicit compatibility override only for a deliberate forward migration.
## Literature corpus supply-chain note

Contextual whole-work translation can provision a local exact-text corpus from the configured `LITERATURE_CORPUS_URL`. This is a first-provision/update supply-chain input, not a runtime web-search dependency. The provisioner indexes the archive into a project-scoped SQLite volume and records the downloaded archive SHA-256 in its readiness marker; later normal starts reuse the local copy. Operators that require fully reproducible/audited inputs should mirror and pin the corpus archive internally, set `LITERATURE_CORPUS_URL` accordingly, and review the recorded checksum before release.


## Open WebUI agentic tool surface

This deployment disables Open WebUI built-in agentic tools for the curated local model (`DEFAULT_MODEL_METADATA` sets `capabilities.builtin_tools=false`) and disables Workspace plugins (`ENABLE_PLUGINS=false`). File Context/RAG is kept enabled as a separate capability. As defense in depth, `model-router` removes client-provided tool/function schemas before forwarding requests to Ollama. This prevents small local models from accidentally invoking state-changing UI tools such as task creation during ordinary conversation.
