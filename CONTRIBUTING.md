# Contributing

Thanks for contributing.

1. Do not commit `.env`, backups, benchmark results from private material, model weights, chat exports, uploaded user documents, or Docker volume contents.
2. Keep `compose.yaml` CPU-compatible and keep Ollama/Docling un-published there. Hardware/debug/test behavior belongs in override files.
3. Prefer upstream container images and documented environment variables over custom forks.
4. Keep application/helper image tags pinned to explicit versions.
5. Update README/docs when changing ports, services, model defaults, bootstrap requirements, backup format, or security posture.
6. If Docling artifact requirements change, bump `DOCLING_PREFETCH_REV`.
7. Add or update smoke/benchmark fixtures for language/OCR behavior changes.

Before opening a pull request:

```bash
bash -n scripts/*.sh
shellcheck scripts/*.sh
docker compose -f compose.yaml config >/dev/null
docker compose -f compose.yaml -f compose.macos-gpu.yaml config >/dev/null
docker compose -f compose.yaml -f compose.debug.yaml config >/dev/null
docker compose -f compose.yaml -f compose.test.yaml --profile test config >/dev/null
```

When changing runtime behavior, also run on a real deployment:

```bash
make check
make smoke-test
make benchmark
```
## Runtime version changes

Do not add container image version pins back to `.env.example`. Runtime image selections belong in the Git-tracked `versions.env`. A version bump should update `STACK_RELEASE`, pass static validation, and be exercised through `make upgrade` plus smoke/benchmark gates on a target Mac before release.
