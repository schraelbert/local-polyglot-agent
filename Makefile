SHELL := /bin/bash
COMPOSE := docker compose --env-file .env $(if $(wildcard .runtime.env),--env-file .runtime.env,) --env-file versions.env

.PHONY: bootstrap up debug-up down logs ps check disk-check smoke-test benchmark wait-ready release-gate gpu-diagnose pull-models pull-docling-models pull-literature-corpus backup backup-user-data restore upgrade rollback reset config config-debug

bootstrap:
	./scripts/bootstrap-macos.sh

up:
	./scripts/up.sh

debug-up:
	./scripts/debug-up.sh

down:
	./scripts/down.sh

logs:
	$(COMPOSE) -f compose.yaml logs -f --tail=200

ps:
	$(COMPOSE) -f compose.yaml ps

check:
	./scripts/check.sh

disk-check:
	./scripts/disk-check.sh

smoke-test:
	./scripts/smoke-test.sh

benchmark:
	./scripts/benchmark.sh

wait-ready:
	./scripts/wait-ready.sh

release-gate:
	./scripts/release-gate.sh

gpu-diagnose:
	./scripts/gpu-diagnose.sh

pull-models:
	$(COMPOSE) -f compose.yaml run --rm model-init

pull-docling-models:
	FORCE_DOCLING_MODEL_UPDATE=1 $(COMPOSE) -f compose.yaml run --rm docling-model-init

pull-literature-corpus:
	FORCE_LITERATURE_CORPUS_UPDATE=1 $(COMPOSE) -f compose.yaml run --rm literature-corpus-init

backup:
	./scripts/backup.sh full

backup-user-data:
	./scripts/backup.sh user-data

restore:
	./scripts/restore.sh

upgrade:
	./scripts/upgrade.sh

rollback:
	./scripts/rollback.sh

config:
	$(COMPOSE) -f compose.yaml -f compose.macos-gpu.yaml config

config-debug:
	$(COMPOSE) -f compose.yaml -f compose.debug.yaml -f compose.macos-gpu.yaml config

reset:
	@echo "This deletes all project-scoped local models, chats, Docling artifacts, and the rebuildable literature corpus cache."
	@read -p "Type DELETE to continue: " ans; [[ "$$ans" == "DELETE" ]]
	$(COMPOSE) -f compose.yaml -f compose.macos-gpu.yaml down -v --remove-orphans
