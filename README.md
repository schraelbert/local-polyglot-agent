# Local Polyglot Agent

A local-first multilingual AI workspace for **Chinese, English, and Norwegian (Bokmål + Nynorsk)** with private chat, contextual translation, image understanding, OCR, long-document reading, and local RAG.

> **Status: `v0.1.0-rc6` release candidate.** The current standard 16 GB-class Apple Silicon profile has passed the repository release gate, including sequential E2E dialogue, OCR, vision, and multilingual translation checks. See [`RELEASE_CHECKLIST.md`](RELEASE_CHECKLIST.md) before tagging or publishing a release.

## What this project is

Local Polyglot Agent packages a deliberately small local stack behind a single Open WebUI model name. It is designed for a Mac where privacy, predictable memory use, and useful multilingual/document workflows matter more than matching a frontier cloud model.

- **One public assistant:** Open WebUI exposes only `polyglot-agent:latest`.
- **Sticky conversations:** Chinese-first chats stay on Qwen2.5 7B; other text chats stay on Qwen3.5 9B on the standard tier.
- **Context-aware translation:** explicit and follow-up translation requests can recover prior source text; whole public-domain literary works can be completed from a local exact-text corpus before translation.
- **Multimodal/document support:** Qwen3-VL 4B handles images; Docling handles structured document extraction/OCR; BGE-M3 provides local embeddings/RAG.
- **Private backends:** normal operation publishes only Open WebUI on `127.0.0.1:3000`; Ollama and Docling remain inside the Compose network.
- **Conservative UX:** underspecified commands such as bare `翻译` ask only for the missing parameter instead of guessing. Open WebUI agentic/built-in tool calls are disabled for the curated assistant, while File Context/RAG remains available.

## Architecture at a glance

```text
Browser
  │
  ▼
Open WebUI (127.0.0.1:3000)
  │
  ▼
polyglot-agent:latest
  │
  ▼
model-router
  ├─ Chinese-first conversation ──► Qwen2.5 7B
  ├─ Other text / translation ────► Qwen3.5 9B Q4_K_M
  ├─ Image input ─────────────────► Qwen3-VL 4B Instruct
  ├─ Local embeddings ────────────► BGE-M3
  ├─ Whole-work source lookup ────► local SQLite literature corpus
  └─ Documents / OCR ─────────────► Docling Serve
```

The standard 16 GB-class profile keeps only one Ollama model loaded at a time. On the currently pinned `ollama/ollama:0.34.4` ARM64 image, the supported path on this hardware class is CPU-compatible fallback when no usable Vulkan runner is present; GPU diagnostics remain available separately.

The repository does **not** redistribute model weights. Models and the local literature corpus are provisioned from their upstream sources and retain their upstream licenses. Local `.env`, backups, chats, benchmark output, model/data volumes, and generated runtime state are intentionally excluded from Git; see [`.gitignore`](.gitignore) and [`SECURITY.md`](SECURITY.md).

## Requirements

Recommended Mac GPU path:

- Apple Silicon Mac
- **macOS 14+** for the current Krunkit GPU path
- Homebrew
- **16 GB host RAM is supported** by the standard sticky-conversation tier: Chinese-first chats stay on Qwen2.5 7B, other text chats stay on Qwen3.5 9B, and only one Ollama model is resident at a time. The bootstrap uses a 10 GiB Colima VM on 16 GB Macs and a 120 GiB Krunkit root disk by default. Hosts with **24 GB+** and a Colima VM at or above the high-memory threshold automatically move to Qwen3 14B.
- Free disk space for container images, model weights, Docling artifacts, backups, and user data. `make up` now performs a Colima disk preflight before large pulls; use `make disk-check` to inspect the same gate directly.

A CPU-compatible Docker path is also available.

## Quick start

```bash
git clone <your-repository-url>
cd local-polyglot-agent

make bootstrap
make up
```

`make bootstrap` installs/sets up Colima, Docker CLI, Docker Compose, and Krunkit, then starts Colima using the Docker runtime and Krunkit VM type. Unless `COLIMA_MEMORY` is explicitly set, the script chooses a conservative VM memory size from the Mac's installed RAM. On Colima 0.10.3 the bootstrap defaults to `COLIMA_MOUNT_TYPE=sshfs`; Colima maps that to Krunkit's supported `reverse-sshfs` path and avoids a known 0.10.3 bug where even an explicit `virtiofs` request can incorrectly arrive as `9p`. Once a stable Colima release includes the upstream fix, advanced users can retry `COLIMA_MOUNT_TYPE=virtiofs make bootstrap`.

If `make bootstrap` fails, stop there and fix that error before running any later targets. `make up`, checks, model provisioning, benchmarks, and backups all require a reachable Colima Docker daemon. The bootstrap grants Homebrew trust only to the transitive `libkrun/krun` formulae required by `krunkit`, rather than trusting the entire third-party tap.

### Colima disk budget

The stack is disk-heavy: Docling/Open WebUI images and local Ollama weights require substantial extracted working space. `make up` requires **30 GiB free when one of the core runtime images is missing** (fresh install, interrupted pull, or version change) and **16 GiB free when those images are already present**. Override only deliberately with `COLIMA_MIN_FREE_DISK_GIB`.

Run `make disk-check` before provisioning when storage is tight. If the VM is full, inspect `docker system df` and `colima ssh -- df -h /var/lib/containerd`. On a Colima VM dedicated to this project, `docker image prune -af` and `docker builder prune -af` reclaim unused image/build cache without deleting named volumes; follow with `colima ssh -- sudo fstrim -a`. On the Krunkit path used by this project, grow the **root disk** with `colima stop && colima start --memory 10 --root-disk 120` when cleanup is insufficient. Current Krunkit/Colima releases can fail to remount the secondary `disk:` volume after restart, leaving `/var/lib/containerd` on the default ~20 GiB root filesystem; using `rootDisk` avoids that failure mode. Non-Krunkit profiles can continue using Colima's normal `--disk` growth path. Never use `docker volume prune` or `docker system prune --volumes` unless you intentionally want to risk deleting persistent chats/models/artifacts.

If you are migrating from an earlier local bundle, use the version-aware backup/restore guidance in [`docs/UPGRADE_ROLLBACK.md`](docs/UPGRADE_ROLLBACK.md) rather than relying on old RC-specific workarounds.

`make up` creates `.env` if needed, generates strong local secrets, performs a Colima container-disk preflight **before** large image/model pulls, probes both `/dev/dri` **and** the pinned Ollama image for a usable Vulkan runner, enables the GPU override only when both prerequisites are present, and otherwise launches a memory-safe CPU fallback. It also launches one-shot initializers for Ollama models, a local exact-text literature corpus, and Docling model artifacts. Known earlier RC defaults (`qwen3-vl:8b`, `qwen3-vl:8b-instruct`, and the previous `qwen3:14b` default) are migrated to the standard `qwen3.5:9b-q4_K_M` tier; explicitly configured custom/thinking variants are left untouched. `make up` measures both host and Colima memory: the standard 16 GB-class tier requires a VM configured around 10 GiB, while the 14B tier is selected only when the host and guest both meet the configured high-memory thresholds. Linux `MemTotal` is normally a little below the Colima `--memory` request, so runtime detection rounds the guest value to the nearest GiB instead of truncating it (for example, a real `--memory 10` VM is treated as the 10 GiB class rather than being mislabeled as 9 GiB). It also force-recreates only the lightweight `model-router` service on each run so updates to the bind-mounted Python router are guaranteed to be imported; Ollama, Docling, and Open WebUI are not needlessly recreated for a router-code-only upgrade.

Open WebUI exposes only `polyglot-agent:latest`. Behind that single name, `model-router` prioritizes **conversation continuity over per-turn specialization**. The first substantive user turn selects a sticky text anchor for the conversation: Chinese-first chats stay on `qwen2.5:7b`, while other text chats stay on `qwen3.5:9b-q4_K_M`. Every ordinary follow-up forwards the complete message history unchanged to that same anchor. A deliberately small UX guard handles only obviously underspecified bare commands: for example, `翻译` with recoverable prior context asks which target language is wanted instead of guessing or echoing the source, and bare `改一下` asks which aspect to change. Contextual `解释一下` / `继续` still stay on the sticky anchor when a referent exists. Translation is treated as a tool operation: self-contained translation goes directly to Qwen3.5, while contextual requests such as `翻译全诗`, `把刚才那个翻成英文`, or `第二句翻成英文` resolve the exact source text before translation. Explicit numbered-sentence references (`第一句` / `第二句` / `第 N 句`) are recovered deterministically from prior user-provided labelled text, so they do not depend on a small model successfully emitting resolver JSON; ambiguous references still use the sticky anchor resolver. For whole-work requests where chat contains only an excerpt, the router first looks up the exact source in a local SQLite literature corpus using the already-identified title/author hints plus literal user-provided snippets. The retrieved record must match the known snippet and be materially more complete than the excerpt before it can be handed to Qwen3.5. Snippet validation is exact-first but tolerates a very small set of common textual/orthographic edition variants (for example `唯/惟`) plus conservative near-exact matching after title/author or literal-anchor candidate narrowing; it never fuzzy-searches the whole corpus indiscriminately. Model-memory reconstruction remains only a last-resort fallback when the corpus has no match; it is never preferred over an exact corpus hit. Whole-work literary translation uses one source-grounded Qwen3.5 tool call at temperature 0 with the verified corpus text plus title/author/dynasty metadata. It does not run hidden rewrite loops: the release gate is intended to measure conversation continuity and useful translation behavior rather than force one critical edition of a classical text. Short contextual translations remain single-pass. Later normal dialogue returns to the original sticky anchor. Requests containing images bypass to `qwen3-vl:4b-instruct`. On high-memory hosts both text anchors can converge on the configured 14B model. Only one Ollama model is kept loaded at a time, so the two-stage translation handoff swaps through the same single model slot instead of increasing steady-state model RAM.

The sticky-conversation profile defaults text generation to direct mode (`TEXT_THINKING_DEFAULT=false`). Earlier always-on Qwen3.5 thinking could fill the 4K CPU context or exceed the 300-second request budget on short prompts before producing a final answer. An explicit client `think=true` is still preserved when the multilingual Qwen route is active. The release gate now requires sticky-conversation runtime metadata **and** separate E2E multi-turn dialogue blockers; isolated component tests are no longer treated as proof of chat intelligence.

The WebUI connection points at the curated router rather than raw Ollama, so base models, the hidden vision agent, and BGE-M3 are not offered in the chat model selector. The evaluation Arena model is disabled for this single-agent deployment.


On a first install, model/artifact/corpus downloads can take a while. Run `make wait-ready` before individual smoke/benchmark commands, or use `make release-gate`, which waits automatically and fails if any provisioning job exits unsuccessfully. `wait-ready` monitors the Ollama model, literature-corpus, and Docling one-shot jobs concurrently, so a fast provisioning failure is reported immediately instead of being hidden behind a larger download.


### Readiness and Apple GPU diagnostics

`make wait-ready` now waits for both provisioning jobs **and** Open WebUI's `/health` endpoint.
A started container is not treated as a ready web application, which avoids false failures during first-run database migration.

If startup prints that the Krunkit VM is running but `/dev/dri/renderD128` is absent, run:

```bash
make gpu-diagnose
```

The diagnostic safely probes/loads the guest `virtio_gpu` kernel module, reports DRI/DRM state, and checks whether the running Ollama container actually contains a Vulkan runner payload. Missing acceleration is reported as a warning and exits successfully by default; use `GPU_DIAG_REQUIRE_ACCEL=1 make gpu-diagnose` when absence of GPU acceleration must fail automation.
If `/dev/dri/renderD128` remains absent in the VM, Compose cannot expose Apple GPU acceleration to the Ollama container; CPU mode remains functional.

There is a second independent upstream constraint: at the time of this RC, Ollama's official Linux ARM64 release workflow does not build/package the `llama-server-vulkan` payload even though the generic Docker documentation describes Vulkan device passthrough. Therefore this repository treats the pinned official ARM64 Ollama image as **CPU-compatible by default** and does not claim Apple GPU validation merely because `/dev/dri` appears. `SMOKE_REQUIRE_GPU=1` requires both the DRI device and an actual Vulkan runner payload. A future GPU profile may use a separately audited ARM64 Vulkan Ollama image/build once that path is reproducible.

Open:

- **Open WebUI:** http://localhost:3000

Only Open WebUI is published to macOS in the default profile. Ollama and Docling stay on the Compose network and are not reachable through host ports.

### First-run admin

A fresh Open WebUI database is bootstrapped with a local admin account. Signup is disabled by default.

```bash
grep '^WEBUI_ADMIN_EMAIL=' .env
grep '^WEBUI_ADMIN_PASSWORD=' .env
```

The generated password is stored only in the untracked local `.env`. Open WebUI creates the admin from `WEBUI_ADMIN_EMAIL` + `WEBUI_ADMIN_PASSWORD` only when no users exist; restoring an existing WebUI database does not reset that user's password.

### First-run downloads

Follow the one-shot provisioning jobs with:

```bash
make logs
```

They prepare:

- `qwen3.5:9b-q4_K_M` for non-Chinese conversation anchoring and translation-tool execution
- `qwen2.5:7b` for Chinese-first conversation anchoring
- `qwen3:14b` for both text roles automatically on high-memory hosts/VMs
- `qwen3-vl:4b-instruct` for image/vision requests
- `bge-m3` for embeddings/RAG
- public `polyglot-agent:latest` derived from the multilingual base
- hidden `polyglot-agent-knowledge:latest` used as the Chinese conversation anchor
- hidden `polyglot-agent-vision:latest` derived from the 4B vision model
- Docling standard layout/table/OCR artifacts plus explicit RapidOCR Chinese, English, and Norwegian recognizers

After they finish:

```bash
make check
make smoke-test
make benchmark
```

## Commands

```bash
make up                  # normal private-backend profile
make debug-up            # opt-in localhost Ollama + Docling ports/UI
make down
make ps
make logs
make check               # quick internal service/model checks
make wait-ready          # wait for Ollama/Docling one-shot provisioning to finish
make smoke-test          # integration + language + vision + PDF + GPU checks
make benchmark           # production translation + component knowledge + E2E dialogue + OCR + vision quality gate
make release-gate        # wait -> check -> smoke -> production benchmark (critical=100%, overall>=95%) -> backup

make pull-models         # ensure Ollama models/agent exist
make pull-docling-models # explicitly refresh Docling artifact cache
make pull-literature-corpus # explicitly refresh the local exact-text literature corpus
make backup-user-data    # WebUI users/chats/knowledge + local config/secrets
make backup              # WebUI + Ollama models + Docling artifacts + local config
make restore             # same-version/explicit forward restore via BACKUP=...
make upgrade             # backup -> pull tracked versions -> validate
make rollback            # restore backup using its recorded pre-upgrade runtime
make config
make config-debug
make reset               # DESTRUCTIVE: remove this checkout's named volumes
```

The production benchmark deliberately separates component correctness from actual conversation behavior. Translation semantics, component knowledge, sequential E2E dialogue, OCR, and vision each have release-blocking critical cases that must pass 100%; the aggregate score must also remain at least 95%. The E2E dialogue suite sends real consecutive turns through the public `polyglot-agent:latest` endpoint and feeds each real assistant answer into the next turn, so contextual commands such as “翻译全诗”, “第二句”, and cross-turn memory are tested as conversations rather than isolated prompts.

To deliberately refresh mutable Ollama model tags:

```bash
FORCE_MODEL_UPDATE=1 make pull-models
```

## Default backend isolation

The normal profile publishes only:

```text
127.0.0.1:3000 -> Open WebUI
```

The internal services are reachable only by service name inside the Compose network:

```text
http://model-router:11434   # curated chat endpoint used by Open WebUI
http://ollama:11434         # raw inference/embedding backend, not exposed in the model picker
http://docling:5001
```

This removes the unauthenticated Ollama API from the macOS localhost attack surface and keeps the Docling API private as well.

For troubleshooting only:

```bash
make debug-up
```

That temporarily adds:

```text
127.0.0.1:11434 -> Ollama
127.0.0.1:5001  -> Docling
```

Run `make up` again to return to the default private-backend profile.

## Models

Defaults live in `.env`:

```dotenv
CHAT_MODEL=qwen3.5:9b-q4_K_M
KNOWLEDGE_CHAT_MODEL=qwen2.5:7b
HIGH_MEMORY_CHAT_MODEL=qwen3:14b
HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL=qwen3:14b
STANDARD_VM_THRESHOLD_GIB=10
HIGH_MEMORY_HOST_THRESHOLD_GIB=24
HIGH_MEMORY_VM_THRESHOLD_GIB=14
VISION_CHAT_MODEL=qwen3-vl:4b-instruct
AGENT_MODEL=polyglot-agent:latest
KNOWLEDGE_AGENT_MODEL=polyglot-agent-knowledge:latest
VISION_AGENT_MODEL=polyglot-agent-vision:latest
EMBEDDING_MODEL=bge-m3
OLLAMA_CONTEXT_LENGTH=16384
OLLAMA_CPU_CONTEXT_LENGTH=4096
OLLAMA_MAX_LOADED_MODELS=1
OLLAMA_NUM_PARALLEL=1
OLLAMA_NO_CLOUD=1
```

The conservative scheduler keeps only one loaded model and one parallel Ollama request. On the standard 16 GB-class tier, `CHAT_MODEL` is the multilingual conversation anchor and translation-tool model, `KNOWLEDGE_CHAT_MODEL` is the Chinese-first conversation anchor, and `VISION_CHAT_MODEL` is the image base. `model-router` still presents one public `AGENT_MODEL`, but normal text routing is **sticky**: the first substantive user turn selects the conversation anchor, and later ordinary follow-ups keep that model and the full message history. Self-contained translation bypasses directly to `CHAT_MODEL`; contextual translation first resolves an exact source. Explicit numbered sentences are extracted deterministically from prior user text, whole public-domain works prefer the local exact-text SQLite literature corpus (indexed from `open-chinese/poetry-collection`), and only genuinely ambiguous references use the sticky anchor. Corpus/whole-work hits carry trusted title/author metadata into a dedicated literary translation profile, which runs at temperature 0 with line/order and named-entity fidelity constraints. That path performs one grounded translation call; if a proper name has no confident conventional translation, romanization is preferred over inventing a literal substitute. The E2E release case accepts documented classical textual variants (for example the attested 碧空/碧山 reading) instead of treating edition choice as a conversation failure. Short contextual references such as `第二句` use a compact single-pass translation-tool prompt instead of paying the reliability/latency cost of the literary profile. A model-memory retrieval is only a fallback on corpus miss; if no verified complete source can be recovered, the router explicitly asks for the missing source instead of silently doing a partial translation. Image-bearing requests bypass to the vision agent. On high-memory hosts, `HIGH_MEMORY_CHAT_MODEL` and `HIGH_MEMORY_KNOWLEDGE_CHAT_MODEL` can both use the 14B tier. When no usable Vulkan runner exists, `make up` caps Ollama at `OLLAMA_CPU_CONTEXT_LENGTH=4096`. A guest genuinely below the `STANDARD_VM_THRESHOLD_GIB=10` memory class is rejected; guest `MemTotal` is rounded to the nearest GiB to account for VM/kernel reservation.

Container/application versions are **not** stored in `.env`. They live in the Git-tracked [`versions.env`](versions.env), so restoring user configuration cannot silently downgrade the software stack. `versions.env` has higher Compose interpolation precedence than `.env`; legacy `*_IMAGE=` lines left in an older `.env` are therefore ignored.

For a smaller Mac, the text tier is selected automatically. You can still reduce the vision base explicitly if necessary:

```dotenv
VISION_CHAT_MODEL=qwen3-vl:2b-instruct
OLLAMA_CPU_CONTEXT_LENGTH=4096
```

On a 16 GB Mac, keep Colima around **10 GiB** so macOS retains useful headroom. `make up` records `RUNTIME_MODEL_TIER=standard`. On a 24 GB+ host with a sufficiently large guest it records `RUNTIME_MODEL_TIER=high-memory` and selects the 14B text model automatically. Both tiers must pass the same production benchmark; the quality gate is not relaxed for the smaller hardware tier.

For larger-memory Macs, raise context length gradually. A model's advertised maximum context is not a promise that it fits efficiently in available memory.

## Multilingual Agent

[`config/agent/system-prompt.md`](config/agent/system-prompt.md) is embedded into all three routed agents: public `AGENT_MODEL` (multilingual conversation/translation), hidden `KNOWLEDGE_AGENT_MODEL` (Chinese conversation anchor), and hidden `VISION_AGENT_MODEL` (4B vision by default). Ollama reuses base-model blobs for derived tags rather than downloading duplicate full copies.

The prompt is tuned for:

- Simplified and Traditional Chinese
- English
- Norwegian Bokmål
- Norwegian Nynorsk
- translation with terminology/date/number preservation
- factuality, false-premise resistance, self-correction, and multi-turn context tracking
- image understanding and OCR
- document analysis and RAG

If you edit the prompt:

```bash
make pull-models
```

## Literature corpus and offline exact-source retrieval

Contextual requests such as `翻译全诗` need the exact missing source, not another model guess. `literature-corpus-init` therefore downloads the configured `open-chinese/poetry-collection` archive on first provision, streams its `volumes/volume_*.json` records into a compact SQLite index, and stores that index in the project-scoped `literature-corpus` named volume. The provisioner validates a minimum work count and records the downloaded archive SHA-256 in its readiness marker. Later starts reuse the local database and do not contact the corpus source unless `FORCE_LITERATURE_CORPUS_UPDATE=1` / `make pull-literature-corpus` is requested.

The router uses the corpus only for exact-source recovery when the dialogue clearly asks for a complete referenced work whose full text is absent from chat. Literal snippets already supplied by the user are used as validation constraints, so an unrelated work with a similar title is not silently substituted. Validation is edition-aware: exact matches are preferred, while a bounded matcher tolerates common orthographic variants such as `唯/惟` and only applies conservative near-exact comparison after the candidate set has already been narrowed by title/author or literal six-to-eight-character anchors. The corpus is a rebuildable cache and is intentionally not treated as user-secret backup state.

## Docling artifacts and offline readiness

Docling uses a dedicated named volume mounted as `/artifacts` and `DOCLING_SERVE_ARTIFACTS_PATH=/artifacts`. `docling-model-init` seeds the persistent volume from the standard models already baked into the upstream Docling Serve image, then adds the Chinese/English/Norwegian RapidOCR checkpoints used by this project and writes a revision marker.

This matters because setting an artifacts path tells Docling to use local prefetched model files instead of silently fetching missing model weights during conversion.

If the required artifact set changes, bump `DOCLING_PREFETCH_REV` and run:

```bash
make pull-docling-models
```

The normal inference/document-processing path can then operate without paid cloud APIs. Container egress is not blocked by a firewall; strict air-gap operation is a separate deployment mode.

## Long documents

Open WebUI sends extraction to Docling and generates embeddings locally with BGE-M3. By default Open WebUI uses **RAG**, so it normally supplies selected relevant chunks rather than an arbitrarily large full document to the chat model.

For smaller documents, Full Context / Use Entire Document can be useful. For very large reports, staged summarization remains preferable to pretending the context window is unlimited.

The repository pins a deterministic local RAG profile in `.env.example` that fits the conservative 4K CPU fallback while still working with a larger accelerator context:

```dotenv
ENABLE_PERSISTENT_CONFIG=false
RAG_TEXT_SPLITTER=character
ENABLE_MARKDOWN_HEADER_TEXT_SPLITTER=true
CHUNK_SIZE=1200
CHUNK_OVERLAP=150
RAG_TOP_K=5
RAG_FILE_MAX_SIZE=250
RAG_FILE_MAX_COUNT=10
```

`ENABLE_PERSISTENT_CONFIG=false` deliberately makes environment/repository configuration authoritative instead of stale Open WebUI `ConfigVar` values saved in its database. The tradeoff is that Admin UI changes to those persistent settings do not survive restart; edit `.env` instead. The WebUI 250 MB upload limit is aligned with the Docling 250 MiB parser ceiling closely enough that oversized uploads are rejected before expensive processing.

## Smoke test

```bash
make smoke-test
```

The smoke test uses an ephemeral curl helper **inside the Compose network**, so it does not need to expose Ollama or Docling to the host. It verifies:

- Open WebUI host reachability
- internal Ollama/Docling reachability
- local literature-corpus readiness and minimum indexed work count
- backend host ports are closed in the normal profile
- chat, embedding, and derived-agent model presence
- derived system prompt presence
- Chinese, English, Bokmål, and Nynorsk inference
- local embeddings
- Qwen3-VL image input
- Docling PDF extraction
- Colima/Ollama GPU device path

GPU absence is a warning because CPU fallback is supported. A normal `make release-gate` explicitly uses that supported policy even if an older `.env` contains `SMOKE_REQUIRE_GPU=1`. To make GPU mandatory, opt in from the invoking shell:

```bash
SMOKE_REQUIRE_GPU=1 make release-gate
```

For a one-off strict smoke test, `SMOKE_REQUIRE_GPU=1 make smoke-test` remains available.

## Production quality benchmark

```bash
make benchmark
```

The benchmark is intentionally separate from the smoke test and acts as a **production regression gate**, not a claim that a small local model is generally intelligent. It runs 36 deterministic translation cases, 7 critical single-turn/component knowledge checks, **3 sequential end-to-end dialogue scenarios**, Docling OCR fixtures, and a multimodal vision fixture. Translation coverage is split into:

- **24 critical semantic cases**: negation, residence/verb meaning, time, weekday, place names, numeric corrections, and named-entity fidelity. Every critical translation case must pass.
- **12 extended regression cases**: additional weekday, identifier, and contrast checks. These contribute to the aggregate quality score.

The **7 component knowledge cases** remain release-blocking, but they are explicitly treated as isolated regressions rather than a proxy for conversation quality. They cover literary attribution, false-premise resistance, common factual knowledge, refusal to invent missing attributes, logic, and numeric comparison.

Natural chat quality is guarded separately by **3 E2E dialogue blockers**. These send real sequential `/api/chat` turns through the public `polyglot-agent` and append each actual assistant response to the next request. They verify sticky conversational continuity **and** the controlled contextual-translation tool handoff. The first scenario is the real regression that exposed the old architecture: identify `孤帆远影碧空尽，唯见长江天际流` → user says `翻译全诗` → the sticky anchor resolves the referent; if the dialogue only contains the excerpt, a clean local retrieval step reconstructs and validates the complete public-domain source before Qwen3.5 translates it → user asks what `全诗` referred to and the conversation returns to the original anchor. The other scenarios cover a contextual “第二句” translation (resolved deterministically from user-provided labelled text rather than probabilistically by the anchor) and cross-turn memory in an English-started conversation. A release fails if any E2E scenario loses the referent, asks the user to resupply recoverable context, fails to translate the complete resolved work with its core identity/semantic anchors intact (while allowing documented textual variants), or fails to return to the sticky anchor for subsequent ordinary dialogue. The small deterministic UX guard is covered in router integration/smoke checks rather than inflating the model-quality benchmark with another synthetic case.

Component knowledge requests use a bounded **512-token answer budget** by default (`BENCH_KNOWLEDGE_NUM_PREDICT`, allowed range 64–1024). Translation remains deterministic with `think=false` and `temperature=0`. Hidden chain-of-thought is never accepted as a final answer.

OCR remains release-critical and covers:

- Simplified Chinese image
- English image
- Bokmål image
- Nynorsk image
- three-page scanned Latin-script PDF
- scanned Chinese PDF

Vision is also release-critical through the bundled marker fixture. The production policy is:

- critical translation: **100% required**
- component knowledge critical: **100% required**
- E2E dialogue critical: **100% required**
- OCR critical cases: **100% required**
- vision critical cases: **100% required**
- infrastructure failures: **0 required**
- overall benchmark score: **>=95% required**

Results are written to the ignored `benchmark-results/` directory. You may raise the overall threshold, but not lower it below 95%:

```bash
BENCH_MIN_SCORE=98 make benchmark
# Optional direct-answer budget override for component knowledge checks (64..1024):
BENCH_KNOWLEDGE_NUM_PREDICT=768 make benchmark
```

`make release-gate` enforces the same minimum and rejects `BENCH_MIN_SCORE<95`. This is still a deterministic regression suite rather than a statistical certification study: before making domain-specific production accuracy claims, add anonymized representative documents and translations from the real workload.

### OCR language-routing limitation

Docling RapidOCR runs **one recognition language per conversion**. The benchmark therefore sends explicit `ch`, `en`, or `no` per fixture, and all three recognizers are prefetched for offline use. The Open WebUI Docling integration, however, exposes one global `DOCLING_PARAMS` configuration rather than automatically choosing an OCR language per uploaded scan. With no explicit `ocr_lang`, RapidOCR's default is Simplified Chinese.

That means digital PDFs and direct image understanding remain multilingual, but a scanned PDF whose text is mainly Norwegian/English may need a deliberate OCR-language override for best results. Examples:

```dotenv
# Simplified Chinese scans
DOCLING_PARAMS={"do_ocr":true,"force_ocr":false,"ocr_preset":"rapidocr","ocr_lang":["ch"],"pdf_backend":"docling_parse","table_mode":"accurate","pipeline":"standard"}

# Norwegian scans (also useful for Bokmål/Nynorsk)
DOCLING_PARAMS={"do_ocr":true,"force_ocr":false,"ocr_preset":"rapidocr","ocr_lang":["no"],"pdf_backend":"docling_parse","table_mode":"accurate","pipeline":"standard"}
```

A future language-aware document router would be needed for truly automatic Chinese-vs-Latin OCR selection inside the single Open WebUI upload path. The repository does not claim that behavior today.

## Backups, upgrade, restore, and rollback

Lightweight user-data backup:

```bash
make backup-user-data
```

Full migration-style backup:

```bash
make backup
```

Each creates a timestamped ignored directory under `backups/`. Backup format v2 contains:

- `volumes.tar.gz`
- local `env` (secrets/configuration, but not software versions)
- tracked target `versions.env` for audit history
- `versions.running.env` containing the **actual container images running when the backup started**
- `manifest.txt` with runtime/target versions and Git commit
- `SHA256SUMS` covering the bundle

Because `env` contains secrets and the generated local admin password, treat backup directories as sensitive data. Before copying, backup performs a conservative free-space check based on the source volume sizes. A full backup can be large because it includes Ollama model blobs. `BACKUP_SKIP_SPACE_CHECK=1` exists only for deliberate expert override.

Backup temporarily stops the relevant services for consistency, then restarts the **exact pre-backup container IDs** rather than running `compose up`. This matters after `git pull`: taking a backup must not accidentally recreate Open WebUI at a newer image and trigger a database migration before the upgrade begins.

### Safe upgrade

After updating the repository to the release you want to run:

```bash
make upgrade
```

The upgrade flow:

1. creates a pre-upgrade **full backup** by default and records the actual old runtime images;
2. pulls the images selected by the new Git-tracked `versions.env`;
3. starts the target stack;
4. runs `make check` and, by default, `make smoke-test`.

The full backup makes rollback include Open WebUI data, Ollama model state, and Docling artifacts. On a space-constrained machine you can deliberately choose the lighter database/user-data rollback scope with `UPGRADE_BACKUP_KIND=user-data make upgrade`.

Set `UPGRADE_RUN_SMOKE=0 make upgrade` only when you intentionally want to skip the longer integration gate. Translation/OCR quality remains a separate `make benchmark` release gate.

### Normal restore

```bash
BACKUP=backups/20261002T120000Z-user-data make restore
```

Before touching the running stack, restore verifies checksums and rejects absolute/parent-traversal paths, unexpected top-level paths, symbolic links, hard links, device nodes, FIFOs, and other special tar members. The command then requires typing `RESTORE` before overwriting current volume data. For scripted recovery:

```bash
RESTORE_CONFIRM=RESTORE BACKUP=/absolute/path/to/backup make restore
```

By default the local `env` is restored too, while any existing `.env` is copied to `.env.pre-restore.<timestamp>`. Set `RESTORE_ENV=0` to retain current local configuration/secrets. The Git-tracked runtime `versions.env` is **never** restored by normal restore.

Backup v2 also guards Open WebUI database compatibility. If the backup was created under a different Open WebUI image than the selected version lock, restore refuses by default because application database migrations can be one-way. An intentional forward migration requires explicit acknowledgement:

```bash
RESTORE_ALLOW_VERSION_MISMATCH=1 BACKUP=... make restore
```

### Upgrade rollback

If `make upgrade` fails, use the pre-upgrade backup it prints:

```bash
BACKUP=backups/<pre-upgrade-backup> RESTORE_CONFIRM=RESTORE make rollback
```

Rollback uses the backup's `versions.running.env`, restores the pre-upgrade data, and starts the exact runtime image versions recorded when the backup was taken. This is an emergency runtime pin for that invocation; for a durable rollback, also check out the matching repository release/commit before later normal `make up` runs.

Legacy v1 backups do not contain runtime-version metadata and therefore require `RESTORE_ALLOW_VERSION_MISMATCH=1` after manual compatibility review.

## Apple Silicon GPU notes

The GPU path depends on **Colima 0.10+** and the **Krunkit** VM type. Krunkit currently requires macOS 14+. Colima marks the Krunkit path as experimental. Colima 0.10.3 also has a known Krunkit mount negotiation bug; this repository defaults to the `sshfs` CLI mount option because Colima translates it to Krunkit's supported `reverse-sshfs`.

```text
macOS Apple GPU
  -> Colima/Krunkit VM
  -> /dev/dri
  -> Ollama container
  -> Vulkan backend
```

Docling remains primarily a CPU workload in this Linux-container topology; the Apple GPU bridge described here is for Ollama. The official Ollama Linux ARM64 image currently lacks the Vulkan runner payload in its release assembly, so the GPU path is experimental and may require a future custom/audited ARM64 Vulkan image even when Krunkit exposes `/dev/dri`. `make up` therefore does not map `/dev/dri` merely because the VM exposes it; it first probes the pinned Ollama image and uses a 4K CPU context when the runner is absent. Text uses sticky conversation routing: Chinese-first chats stay on Qwen2.5 7B and other text chats stay on Qwen3.5 9B for ordinary dialogue. Translation is a controlled tool path: self-contained source text goes directly to Qwen3.5; contextual translation resolves the referenced source through the sticky anchor first. Whole-work requests first use the local exact-text SQLite corpus when the chat only contains an excerpt; only a corpus miss falls back to model-memory retrieval, and any recovered source must pass snippet/completeness validation before Qwen3.5 receives it. If source validation fails, the user is asked for the complete original instead of receiving a guessed or partial translation. Image requests route to the smaller 4B vision agent.

The normal release gate validates the supported runtime, including ARM64 CPU fallback when the pinned Ollama image has no Vulkan runner. A release should not be called “Mac GPU validated” until the target Mac passes the stricter opt-in gate:

```bash
SMOKE_REQUIRE_GPU=1 make release-gate
```

Using the one-shot target is intentional: it stops immediately on the first failing prerequisite instead of producing cascading Docker/model/backup errors after an earlier bootstrap or service failure.

## Security / privacy

- Only Open WebUI is published by default, on `127.0.0.1`.
- Ollama and Docling remain private Compose services unless `make debug-up` is used.
- Docling additionally requires a generated API key.
- Open WebUI's first admin is created from local generated credentials; signup defaults to disabled.
- Open WebUI CORS is restricted to its localhost origins.
- Docling remote services/external plugins are disabled and per-document limits are configured.
- Docling telemetry metrics/export surface is disabled in this profile.
- Ollama cloud inference/web-search features are disabled with `OLLAMA_NO_CLOUD=1`.
- Open WebUI OpenAI integration, version checks, web search, and code execution are disabled.
- Open WebUI persistent Admin config is disabled by default so audited environment values remain authoritative across restarts/upgrades.
- Upload size/count, RAG chunking, and retrieval limits are pinned for the local 16K profile.
- Container logs are rotated to avoid unbounded disk growth.
- `.env`, backups, benchmark output, model data, and local application data are ignored by Git.

This is still not a kernel-level network sandbox. First start and updates need network access to fetch images/models, and containers retain outbound networking unless you enforce separate firewall rules.

## Cost

The intended baseline has **$0 recurring software/API subscription cost** if you already own the Mac: no paid model API and no Docker Desktop requirement. It is not literally zero economic cost: electricity, bandwidth, SSD usage, hardware/depreciation, backups, and optional paid services remain real costs. See [`docs/COSTS.md`](docs/COSTS.md).

## Licensing

Repository-owned code/configuration is MIT. Upstream applications and models retain separate licenses. In particular, current Open WebUI releases include a branding-protection condition; do not describe the entire dependency stack as unrestricted MIT/BSD. See [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

## Audit notes

- [`docs/AUDIT.md`](docs/AUDIT.md)
- [`docs/DEEP_AUDIT.md`](docs/DEEP_AUDIT.md)
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)
- [`docs/UPGRADE_ROLLBACK.md`](docs/UPGRADE_ROLLBACK.md)

## Repository layout

```text
.
├── README.md
├── RELEASE_CHECKLIST.md
├── SECURITY.md
├── CONTRIBUTING.md
├── .gitignore
├── .env.example
├── versions.env
├── Makefile
├── compose.yaml
├── compose.macos-gpu.yaml
├── compose.debug.yaml
├── compose.test.yaml
├── config/agent/system-prompt.md
├── scripts/
│   ├── bootstrap-macos.sh
│   ├── up.sh
│   ├── debug-up.sh
│   ├── down.sh
│   ├── check.sh
│   ├── smoke-test.sh
│   ├── benchmark.sh
│   ├── backup.sh
│   ├── restore.sh
│   ├── upgrade.sh
│   ├── rollback.sh
│   ├── prefetch-docling.sh
│   ├── common.sh
│   └── pull-models.sh
├── tests/fixtures/
│   ├── vision-42.png
│   ├── docling-smoke.pdf
│   └── ocr/
└── docs/
```

## Contributing

Issues and pull requests are welcome. Never commit `.env`, generated backups, user data, model weights, benchmark outputs containing private documents, or local Docker volumes.


### Open WebUI tool-surface policy

The curated assistant is intentionally non-agentic at the Open WebUI layer. Built-in system tools and workspace plugins are disabled; File Context/RAG remains enabled. The model router strips client-supplied tool/function schemas before forwarding chat requests to Ollama, preventing accidental calls such as `create_tasks` on ordinary prompts.
