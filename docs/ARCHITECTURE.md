# Architecture

```text
Browser
  |
  v
Open WebUI 127.0.0.1:3000
  |--- chat ------------> model-router :11434 --- Chinese-first sticky anchor --> Ollama ---> polyglot-agent-knowledge:latest (Qwen2.5 7B standard; Qwen3 14B high-memory)
  |                                      |--- other-text sticky anchor --------> Ollama ---> polyglot-agent:latest (Qwen3.5 9B standard; Qwen3 14B high-memory)
  |                                      |--- translation tool ---------------> Ollama ---> polyglot-agent:latest
  |                                      |      ^ contextual source: sticky anchor -> local exact-text corpus -> translation
  |                                      |        (model-memory retrieval only on corpus miss)
  |                                      `--- images --------------------------> Ollama ---> polyglot-agent-vision:latest (Qwen3-VL 4B)
  |--- embeddings -----------------------------------------------> Ollama ---> bge-m3
  |--- document extraction -------------------------------------> Docling :5001
  |
  `--- local persisted data --> Docker named volume

Open WebUI sees only polyglot-agent:latest. Base models, embeddings, and the
hidden knowledge/vision agents stay behind the internal router/raw Ollama endpoint.

Default host exposure:
  Open WebUI only

Optional debug exposure:
  Ollama 127.0.0.1:11434
  Docling 127.0.0.1:5001

Apple Silicon GPU path:
macOS Apple GPU
  -> Krunkit VM (Colima)
  -> /dev/dri/renderD128
  -> Ollama container
  -> Vulkan backend
```

### Open WebUI tool boundary

The public assistant is deliberately **not** an Open WebUI agentic-tool model. Open WebUI built-in tools are disabled by default and workspace plugins are disabled. File Context/RAG remains available because it is a separate model capability. The router also strips `tools`, `tool_choice`, `parallel_tool_calls`, legacy `functions`, and `function_call` from public requests before Ollama sees them. Internal translation/corpus routing is implemented inside the router and does not depend on Open WebUI function calling.

## Design goals

- All application services run as containers.
- No Docker Desktop dependency.
- Only the browser UI is published by default.
- Ollama and Docling remain on the Compose network unless debug mode is enabled.
- CPU-compatible baseline plus a capability-gated Apple Silicon GPU override. The override requires both a Krunkit DRI render node and a Vulkan runner in the pinned Ollama image; otherwise `make up` forces the memory-safe CPU context.
- Multilingual retrieval through BGE-M3.
- Pre-seeded sticky-conversation agents: Qwen3.5 9B for non-Chinese conversation anchoring plus translation-tool execution, Qwen2.5 7B for Chinese-first conversation anchoring on the 16 GB-class profile, and Qwen3-VL 4B for image/vision; high-memory hosts can converge both text routes on Qwen3 14B. Only one public model is exposed.
- Layout-aware long-document parsing through Docling.
- Exact-text classical-literature corpus prefetched into a local SQLite named volume for offline contextual whole-work recovery.
- Explicitly prefetched Docling artifacts for offline-capable document processing.
- Project-scoped named volumes so separate checkouts do not share state accidentally.
- Git-tracked runtime version lock (`versions.env`) separated from untracked user configuration/secrets (`.env`).
- Environment-authoritative RAG/security ConfigVars for deterministic local behavior.

## Compose files

- `compose.yaml`: normal deployment.
- `compose.macos-gpu.yaml`: adds `/dev/dri` to Ollama.
- `compose.debug.yaml`: opt-in host ports for Ollama/Docling and Docling UI.
- `compose.test.yaml`: ephemeral curl helper used by internal smoke/benchmark requests.

The base file intentionally has no top-level fixed Compose project name. Docker Compose therefore scopes the network/volumes to the checkout/project directory unless the operator overrides the project name explicitly.

## Data locations

Docker named volumes store:

- `ollama-data`: model manifests/blobs and derived agent metadata.
- `open-webui-data`: accounts, chats, knowledge bases, settings, and local WebUI state.
- `docling-artifacts`: prefetched Docling model artifacts.
- `literature-corpus`: rebuildable SQLite exact-text index used for contextual whole-work source recovery.

Tracked runtime control:

- `versions.env`: audited container image selection; normal restore never overwrites it.

Untracked host directories:

- `backups/`: backup bundles containing volume archives, local `.env` secrets, target-version history, and actual-running-image metadata.
- `benchmark-results/`: local quality-regression reports.

`make reset` intentionally destroys the current Compose project's named volumes.

## Agent provisioning

`model-init` ensures `CHAT_MODEL`, `KNOWLEDGE_CHAT_MODEL`, `VISION_CHAT_MODEL`, and `EMBEDDING_MODEL` exist, then creates three derived agents with the same repository system prompt. `AGENT_MODEL` is the public model identity and multilingual conversation anchor, `KNOWLEDGE_AGENT_MODEL` is the hidden Chinese-first conversation anchor, and `VISION_AGENT_MODEL` is the hidden 4B multimodal agent. Text routing is conversation-sticky: the first substantive user turn chooses the anchor for the whole text conversation (Chinese-first -> Qwen2.5 7B on the standard 16 GB-class tier; other text -> Qwen3.5 9B), and subsequent turns keep the complete message history on that same anchor. The router does not delete assistant turns, replay challenged questions, or flatten ordinary dialogue history into facts. Before model routing, a narrow deterministic UX guard intercepts only commands that are missing an obvious required parameter (for example bare `翻译` asks for the target language and bare `改一下` asks what aspect to change); it does not rewrite history or handle adequately specified follow-ups. Translation is the controlled exception to sticky routing: a self-contained translation request bypasses directly to the multilingual Qwen3.5 route, while contextual translation resolves an exact source before the Qwen3.5 tool call. Explicit numbered-sentence references such as “第二句” are extracted deterministically from prior user-provided labelled text; a whole-work request first queries the local SQLite literature corpus using prior referent identification plus literal snippets supplied by the user; only genuinely ambiguous references such as “刚才那个” use the sticky anchor in a hidden source-resolution step. A corpus hit must match the known snippet and be materially more complete before it can be handed to Qwen3.5. Trusted corpus title/author/dynasty metadata accompanies whole-work source text so a dedicated literary translation profile can preserve work identity and proper nouns. That literary path uses temperature 0 and a single source-grounded tool call over the verified corpus text plus identity metadata. The router intentionally avoids hidden rewrite loops; E2E policy focuses on retaining the correct work/referent and producing a coherent complete translation, while allowing documented textual variants of classical works. Ordinary contextual snippets such as an explicitly numbered prior sentence use a compact single-pass translator profile and preserve the caller's normal sampling settings. Exact snippet matching is preferred, but validation tolerates a small set of common edition/orthographic variants (for example `唯/惟`) and conservative near-exact matching only after title/author or literal-anchor candidate narrowing. Only a corpus miss may invoke a clean model-memory retrieval fallback, which is subjected to the same validation. If no verified source is recovered, the router asks for the complete source rather than silently falling back to partial translation. Non-translation references such as “第二个呢” and “继续” stay entirely on the conversation anchor. Requests containing images route to Qwen3-VL 4B. On high-memory hosts both text anchors can converge on Qwen3 14B. Direct mode is the production default because always-on deep thinking exhausted the 4K CPU context on short factual prompts; an explicit client `think=true` is preserved only on the multilingual Qwen route. On CPU fallback `.runtime.env` records the selected `sticky-conversation` profile and caps the shared Ollama context to a memory-safe value. `OLLAMA_MAX_LOADED_MODELS=1` keeps only one model resident at a time. If Colima RAM is below the standard-tier minimum, normal startup stops rather than silently lowering model quality. Underlying blobs are reused.

## Literature corpus provisioning

`literature-corpus-init` runs as a one-shot provisioner before the model router is considered ready for release validation. It downloads the configured corpus archive on first use, streams `volumes/volume_*.json` into `/corpus/poetry.sqlite3`, validates the minimum row count, records the source URL and archive SHA-256 in a marker, and then exits. The named volume is mounted read-only into `model-router`. Subsequent starts reuse the marker/database and therefore do not require corpus network access unless an explicit refresh is requested.

The corpus is rebuildable cache state, not user data. Full backup/restore remains focused on chats, models, and Docling artifacts; deleting the corpus volume merely causes the provisioner to rebuild it on the next start.

## Docling provisioning

`docling-model-init` uses `docling-tools models download` to populate `/artifacts` before Docling starts. A revision marker avoids unnecessary network work on later boots. `DOCLING_SERVE_ARTIFACTS_PATH=/artifacts` makes the service use this local artifact set.

The current prefetch includes the standard Docling model set plus explicit RapidOCR `ch`, `en`, and `no` recognizers used by the multilingual OCR regression tests. RapidOCR is single-language per conversion, so automatic per-upload Chinese-vs-Latin scan routing is not provided by the global Open WebUI Docling configuration.

## Authentication bootstrap

Open WebUI receives `WEBUI_ADMIN_EMAIL`, `WEBUI_ADMIN_PASSWORD`, and `WEBUI_ADMIN_NAME`. On an empty WebUI database it creates the first admin at startup and disables signup. Secrets are generated into untracked `.env` by `scripts/up.sh`.

Docling requires `X-Api-Key` for conversion requests. The same generated key is injected into Open WebUI.

Ollama has no application-layer API key in this topology; instead, its host port is absent from the default profile.

## Smoke and benchmark paths

`make smoke-test` uses `smoke-helper` from `compose.test.yaml` to reach the curated model router, raw Ollama, and Docling from inside the Compose network. It verifies non-Chinese and Chinese sticky anchors, local literature-corpus readiness, direct translation, deterministic numbered-sentence contextual handoff, the bare-command UX guard, image routing, and that the router model list exposes only `AGENT_MODEL`. Ambiguous-reference behavior is covered by the E2E benchmark rather than making smoke depend on probabilistic resolver output. This avoids weakening the default network posture merely to test it.

`make benchmark` adds a production regression gate: 36 translation cases across all six supported language directions, 24 release-critical translation semantic cases, 7 release-critical component-knowledge cases, 3 release-critical sequential E2E dialogue scenarios, critical OCR fixtures for Simplified Chinese/English/Bokmål/Nynorsk and scanned PDFs, and a critical multimodal vision fixture. The E2E suite makes real sequential requests through the public model endpoint and feeds each real assistant response into the next turn; it therefore release-blocks failures in reference resolution such as identifying a poem and then understanding “翻译全诗”. Every critical category requires 100% and the aggregate score must be at least 95%.

## Backup architecture

`backup-helper` is behind the `maintenance` profile and is never started by normal `docker compose up`. It mounts the logical named volumes and creates/restores archives without hard-coding Docker's physical volume names.

User-data backup stops only Open WebUI. Full backup stops Open WebUI, Docling, and Ollama so files are not changing during archive creation. Backup restarts the exact pre-backup container IDs rather than reconciling Compose, preventing an accidental version/DB migration immediately after a git pull.

Backup v2 stores both the repository target versions and the actual images that were running. Restore verifies checksums, archive member types/paths, and runtime compatibility before overwriting volumes. `make upgrade` creates a pre-upgrade full backup by default; `make rollback` selects the backup's actual runtime image lock for emergency recovery.
