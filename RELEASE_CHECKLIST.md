# Release Checklist

Use this checklist for every release candidate and final release. The goal is to keep the repository reproducible **without publishing local secrets, chats, backups, model weights, or generated runtime state**.

## 1. Start from a clean release candidate

- Confirm `versions.env` contains the intended `STACK_RELEASE` and pinned container images.
- Do not change model/router behavior after the final release-gate run unless the release candidate is restarted and validated again.
- Keep `.env.example` public-safe; real credentials belong only in the ignored `.env`.

```bash
cat versions.env
git status --short
```

## 2. Secret and generated-data check

The following must **not** be tracked:

- `.env`, `.runtime.env`, `.running.env`, `.env.pre-restore.*`
- `backups/` — backup bundles contain local secrets
- `benchmark-results/`
- chats, user uploads, local exports, Docker volume contents
- model weights, Docling caches, local literature-corpus databases

Before committing:

```bash
git status --ignored
git ls-files '.env' '.runtime.env' '.running.env' 'backups/*' 'benchmark-results/*'
```

The second command should print nothing. Also inspect the staged diff rather than relying only on `.gitignore`:

```bash
git diff --cached --stat
git diff --cached
```

## 3. Static repository checks

```bash
bash -n scripts/*.sh
python3 -m py_compile scripts/*.py

docker compose --env-file .env --env-file versions.env -f compose.yaml config >/dev/null
docker compose --env-file .env --env-file versions.env -f compose.yaml -f compose.macos-gpu.yaml config >/dev/null
docker compose --env-file .env --env-file versions.env -f compose.yaml -f compose.debug.yaml config >/dev/null
docker compose --env-file .env --env-file versions.env -f compose.yaml -f compose.test.yaml --profile test config >/dev/null
```

Run the repository regression tests as well:

```bash
for t in tests/*.sh; do bash "$t"; done
python3 tests/test-model-router.py
```

## 4. Real deployment release gate

Run this on the target Apple Silicon Mac; static checks or a development container cannot replace the real deployment gate:

```bash
make up
make release-gate
```

A release candidate is acceptable only when the release gate completes successfully. For the current RC6 policy this includes:

- service/readiness checks
- local literature corpus health
- Open WebUI agentic-tool isolation
- multilingual smoke tests
- translation critical cases
- component knowledge critical cases
- sequential E2E dialogue critical cases
- OCR critical cases
- vision critical case
- automatic full backup at the end

The supported CPU fallback may emit GPU warnings. `SMOKE_REQUIRE_GPU=1 make release-gate` is a separate strict-GPU diagnostic and is **not** required for the standard 16 GB-class release path.

## 5. Manual UI sanity check

Open a **new** chat in Open WebUI and verify a few normal interactions that are intentionally more human than the benchmark:

```text
空山不见人，但闻人语响。
```

It should answer normally and must not create task cards or call Open WebUI agentic tools.

Then try:

```text
翻译
```

It should ask for the missing target language rather than echoing the source or guessing.

Continue with something like:

```text
翻译成英文和挪威语
```

Also upload one representative document/image if the release changes anything related to RAG, Docling, OCR, or vision.

## 6. Commit and tag

For the first repository publication:

```bash
git init -b main
git add .
git status
git commit -m "Initial release candidate: local polyglot agent"
```

Create a **blank** GitHub repository (no generated README, `.gitignore`, or license), then add it as the remote:

```bash
git remote add origin git@github.com:<owner>/local-polyglot-agent.git
git push -u origin main
```

Tag the exact commit that passed the release gate:

```bash
git tag -a v0.1.0-rc6 -m "v0.1.0-rc6 - release gate passed"
git push origin v0.1.0-rc6
```

For the final release, create the final tag only from a commit that has completed the release gate unchanged:

```bash
git tag -a v0.1.0 -m "v0.1.0"
git push origin v0.1.0
```

## 7. GitHub release notes

Keep release notes short and factual. Suggested structure:

```text
Local Polyglot Agent v0.1.0-rc6

Validated profile:
- Apple Silicon, 16 GB-class host
- ~10 GiB Colima VM
- CPU-compatible Ollama fallback when the pinned ARM64 image lacks a usable Vulkan runner

Included:
- sticky multilingual conversation routing
- contextual translation with local exact-text literature retrieval
- Chinese/English/Bokmål/Nynorsk translation coverage
- OCR, vision, Docling, and local RAG
- Open WebUI agentic tools disabled for the curated assistant

Validation:
- make release-gate: PASS
```

Do **not** upload `backups/`, `.env`, raw benchmark logs containing private prompts, user documents, model weights, or Docker volume exports as release assets.

## 8. Keep the release backup private

`make release-gate` creates a timestamped backup. It is useful for rollback but contains the local environment/secrets. Store it securely outside the public repository.
