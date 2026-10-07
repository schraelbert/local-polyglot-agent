# Deep pre-release audit

Audit date: 2026-10-07.

## Fixed across the deep-audit passes

- Homebrew `docker-compose` discovery is repaired without overwriting `~/.docker/config.json`.
- Homebrew third-party trust is narrowed to the transitive `libkrun/krun` formula dependency closure required by `krunkit`, rather than trusting the entire tap.
- Fixed container names and the fixed Compose project name were removed.
- Open WebUI's Ollama RAG URL is explicit.
- Open WebUI version checks, web search, generic OpenAI API use, and code execution are disabled by default.
- Open WebUI CORS is restricted to the local UI origins.
- Fresh instances bootstrap a generated administrator and disable signup.
- Ollama, the internal model router, and Docling are not published to the host in the default profile.
- An opt-in debug Compose file provides localhost APIs when needed.
- Ollama cloud inference/web-search features are disabled.
- Ollama concurrency/loading defaults are conservative for Mac memory pressure; the router uses Qwen3.5 9B for non-Chinese conversation anchoring and translation-tool execution, hidden Qwen2.5 7B for Chinese-first conversation anchoring on the standard tier (Qwen3 14B can serve both text roles on high-memory hosts), and a hidden 4B vision agent while keeping only one model resident.
- Docling requires an API key, disables remote services/plugins, and caps per-file size/page count.
- Docling model artifacts are prefetched to a persistent named volume for offline-capable conversions.
- A public classical-literature corpus is prefetched/indexed into a persistent local SQLite volume so contextual whole-work translation can recover exact text without relying on model memory or runtime web search.
- Docling UI is disabled in the normal profile and enabled only in debug mode.
- Docling metrics/prometheus surface is disabled in the normal profile.
- Application logs rotate instead of growing without bound.
- `make backup-user-data`, `make backup`, and `make restore` were added; restore verifies checksums and archive path scope before overwriting volumes.
- Smoke tests access private backend APIs through an ephemeral Compose-network helper.
- Nynorsk inference was added to smoke testing.
- Synthetic raster OCR fixtures now cover Chinese, English, Bokmål, and Nynorsk plus scanned PDFs.
- `make benchmark` is a production regression gate: 24 critical translation semantic cases, 7 critical component-knowledge cases, and 3 sequential E2E dialogue scenarios must all pass; OCR and vision critical cases must all pass; the aggregate score must be at least 95%.
- Open WebUI uses a curated Ollama-compatible `model-router`: only `polyglot-agent:latest` is exposed as a chat model; the first substantive text turn selects a sticky conversation anchor (non-Chinese-first -> Qwen3.5 9B, Chinese-first -> hidden Qwen2.5 7B on the standard tier), complete history remains on that anchor, self-contained translation bypasses directly to Qwen3.5, while contextual translation resolves exact prior-user/corpus source first (using the sticky anchor only for ambiguous references) and then hands verified source to Qwen3.5 translation (a single source-grounded literary-fidelity profile with identity metadata for corpus/whole-work translation, and a compact profile for short resolved snippets), image-bearing requests route to the hidden 4B Instruct agent, high-memory hosts can converge both text anchors on Qwen3 14B, raw specialist/BGE tags stay hidden, and the Arena model is disabled.

## Remaining release risks

1. **Real Apple GPU validation remains mandatory for a “Mac GPU validated” claim, but is not required for the supported CPU-fallback release gate.** Run `SMOKE_REQUIRE_GPU=1 make release-gate` on supported Mac generations. Colima 0.10.3 has a known Krunkit mount negotiation bug; bootstrap currently defaults to the `sshfs` CLI workaround (mapped to `reverse-sshfs`) until a stable Colima release contains the upstream fix.
2. **Krunkit GPU support is experimental.** Keep CPU fallback documented and do not promise native Metal performance parity.
3. **Images are pinned by version tag, not OCI digest.** A registry owner can theoretically move a tag.
4. **Model tags are mutable.** Capture Ollama model digests/manifests in formal releases if benchmark reproducibility matters.
5. **Open WebUI stored configuration can override future environment defaults** for an existing volume.
6. **The stricter synthetic quality gate is necessary but still insufficient for domain certification.** Add anonymized representative translations/documents and statistically meaningful evaluation sets before claiming measured accuracy on a real production workload. RapidOCR is single-language per conversion; automatic Chinese-vs-Latin OCR selection inside Open WebUI is not yet implemented.
7. **Strict offline networking is not enforced.** `OLLAMA_NO_CLOUD` and Docling remote-service settings prevent intended cloud paths, but they are not a firewall.
8. **Backup encryption is not built in.** Backup folders include secrets; use filesystem encryption or an external tool such as `age` if copies leave the Mac.
9. **Restore should be exercised before important upgrades.** A backup that has never been restored is not a proven recovery plan.
10. **Dependency/license drift needs periodic review.** Repository code is MIT while upstream software/models keep separate terms.

## Recommended release sequence

```bash
make bootstrap
make up
make release-gate
```

The standard release gate supports the documented CPU fallback. Use `SMOKE_REQUIRE_GPU=1 make release-gate` only when making a strict Apple-GPU/Vulkan validation claim. Before tagging, manually test at least one representative document/image workflow through Open WebUI and keep the generated backup private.

### ARM64 Ollama fallback note

The pinned official Linux ARM64 Ollama image is capability-probed before GPU mapping. If it lacks a Vulkan runner, `make up` intentionally keeps `/dev/dri` unmapped and applies `OLLAMA_CPU_CONTEXT_LENGTH` (4096 by default) to prevent Qwen3-VL KV-cache OOM during CPU inference.
