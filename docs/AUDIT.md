# Architecture and deployment audit

Audited: 2026-10-07.

## Current hardened baseline

1. **Backend host isolation and curated model surface:** base Compose publishes only Open WebUI. Raw Ollama, the internal `model-router`, and Docling are reachable only through the Compose network. Open WebUI talks to `model-router`, which exposes only `polyglot-agent:latest`; raw base models, BGE-M3, and the hidden knowledge/vision agents are not offered as chat choices. `compose.debug.yaml` provides explicit opt-in localhost ports for raw Ollama/Docling troubleshooting.
2. **First-admin race removed for fresh installs:** Open WebUI is bootstrapped using generated `WEBUI_ADMIN_EMAIL` / `WEBUI_ADMIN_PASSWORD`; signup is disabled by default. Existing databases retain their existing users/configuration.
3. **Exact-source corpus is explicit:** contextual whole-work translation uses a locally indexed SQLite literature corpus before any model-memory reconstruction; first provisioning downloads/indexes it, later starts reuse the named volume offline.
4. **Docling artifact cache is explicit:** a one-shot initializer prefetches model artifacts into a named volume, and Docling uses `DOCLING_SERVE_ARTIFACTS_PATH` so document conversion does not silently depend on first-use model downloads.
5. **Docling API hardened:** API key required; remote services and external plugins disabled; metrics/prometheus surface disabled; file/page limits configured.
6. **Ollama cloud features disabled:** `OLLAMA_NO_CLOUD=1` disables Ollama remote inference/web-search features in the local profile.
7. **Memory-pressure defaults and sticky conversation inference:** one loaded Ollama model and one parallel request by default. A small deterministic UX guard answers only obviously underspecified bare commands locally (for example asking for the missing target language after `翻译`) so these cases do not consume a model turn or get mistaken for new routing heuristics. On the standard 16 GB-class tier, the first substantive user turn chooses one text anchor for the whole conversation: Chinese-first sessions use hidden Qwen2.5 7B, while other text sessions use Qwen3.5 9B. The complete message history stays on that anchor across later turns; self-contained translations bypass directly to Qwen3.5, while contextual translations resolve the referenced source before handing it to Qwen3.5; explicit numbered-sentence references are recovered deterministically from prior user text, and only ambiguous references require the sticky anchor resolver. High-memory hosts/VMs can converge both text anchors on Qwen3 14B. If the Colima guest is below the standard-tier minimum, normal startup fails rather than silently lowering quality. Image-bearing requests are routed to a hidden 4B Instruct vision agent. On CPU fallback all routed inference uses a conservative 4K context and swaps through the single Ollama slot instead of remaining resident together. Bootstrap chooses a conservative Colima memory size from installed Mac RAM unless overridden.
8. **Log growth bounded:** long-running service logs use Docker `json-file` rotation limits.
9. **Backups/upgrades hardened:** backup format v2 records actual running images separately from target versions; full/user-data backup, version-aware restore, upgrade, and rollback workflows are available. Restore verifies checksums and rejects traversal, links, special files, and unexpected archive roots.
10. **Production quality gate expanded:** smoke test includes Nynorsk and verifies the multilingual anchor, Chinese-first anchor, self-contained translation bypass, deterministic numbered-sentence resolve-then-translate handoff, and vision route. Benchmark runs 36 translation regressions across all six directions, requires 100% of 24 critical translation semantic cases plus 7 component-knowledge cases and 3 sequential E2E dialogue scenarios, requires 100% OCR and vision critical cases, and requires an aggregate score of at least 95%. The E2E cases feed real assistant outputs into later turns so reference resolution and conversation continuity are release-blocking behaviors, not inferred from isolated API calls.
11. **Multiple checkouts:** no fixed `container_name` and no fixed top-level Compose project name.

## Important caveats

1. **Krunkit remains experimental.** Real Apple GPU validation must happen on each supported target Mac. Static repository checks cannot certify the current Colima/Krunkit/Vulkan/Ollama combination.
2. **Docling is mainly CPU-bound in this topology.** The Apple GPU bridge is for Ollama; Linux Docling containers do not gain native macOS MPS acceleration.
3. **Long-document RAG is not unlimited context.** Open WebUI normally retrieves selected chunks. Very large full-report summarization should use staged processing.
4. **Open WebUI ConfigVars are intentionally environment-authoritative.** `ENABLE_PERSISTENT_CONFIG=false` prevents stale database config from overriding the audited RAG/security profile. Admin UI edits to ConfigVars therefore do not persist across restart; edit `.env` instead.
5. **Admin bootstrap is fresh-database only.** `WEBUI_ADMIN_PASSWORD` is not a password-reset mechanism after users already exist.
6. **Docling prefetch revision is operator-managed.** When a Docling upgrade requires a different artifact set, bump `DOCLING_PREFETCH_REV` or explicitly run `make pull-docling-models`.
7. **The production benchmark is still regression evidence, not statistical certification.** The stricter gate catches semantic regressions such as lost negation/verb meaning and requires perfect synthetic OCR/vision critical cases, but real scans with skew, handwriting, noise, tables, mixed scripts, and domain terminology still need representative validation. RapidOCR is single-language per conversion, and Open WebUI has one global Docling parameter set, so automatic Chinese-vs-Latin OCR language routing is not implemented.
8. **Model tags remain mutable upstream references.** Record Ollama manifests/digests for benchmarked releases if reproducibility matters.
9. **Container images are selected from Git-tracked `versions.env` but remain version-tag pinned, not digest pinned.** High-assurance deployments should pin OCI digests and verify signatures/SBOMs.
10. **Backups contain secrets.** Backup directories include `.env`; secure/encrypt them when leaving the local machine.
11. **No strict air-gap firewall yet.** Paid/cloud inference is disabled, but container egress itself is not blocked. First provisioning and intentional updates need network access.
12. **No hosted CI workflow is included in this release candidate.** Repository regression tests and the heavyweight release gate are run explicitly by the maintainer; multi-gigabyte model/GPU validation remains a target-Mac release gate.

## Release gates

Functional release:

```bash
make up
make check
make smoke-test
make benchmark
```

Apple GPU validated release:

```bash
SMOKE_REQUIRE_GPU=1 make release-gate
```

Recovery/upgrade validation:

```bash
make backup
make upgrade
# rehearse against a disposable checkout/project when possible
BACKUP=backups/<pre-upgrade-backup> RESTORE_CONFIRM=RESTORE make rollback
make check
```


### ARM64 Ollama fallback note

The pinned official Linux ARM64 Ollama image is capability-probed before GPU mapping. If it lacks a Vulkan runner, `make up` intentionally keeps `/dev/dri` unmapped and applies `OLLAMA_CPU_CONTEXT_LENGTH` (4096 by default). The curated router uses a sticky text anchor per conversation: non-Chinese-first sessions use Qwen3.5 9B and Chinese-first sessions use hidden Qwen2.5 7B on the standard tier (both may converge on Qwen3 14B on high-memory hosts); self-contained translation bypasses directly to Qwen3.5, while contextual translation resolves exact prior-user/corpus source first (using the sticky anchor only for ambiguous references) and then hands verified source to Qwen3.5 translation; corpus/whole-work translation uses a deterministic literary-fidelity profile with identity metadata in one source-grounded Qwen3.5 call, while short resolved snippets use the compact single-pass translator profile. Image-bearing requests use the hidden 4B Instruct agent. With one loaded Ollama model at a time, these routes fit the 16 GB-class memory budget while avoiding the unstable 8B VL CPU vision path.

## Open WebUI built-in tool isolation

Release policy now treats Open WebUI's agentic tool surface as out of scope for the curated assistant. The deployment disables built-in tools and workspace plugins, while retaining File Context/RAG. The router enforces the same boundary independently by stripping incoming OpenAI/Ollama tool/function schema fields. This prevents accidental `create_tasks`/similar calls from small local models and reduces unnecessary tool-schema context overhead.
