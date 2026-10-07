# Upgrade and rollback model

Local Polyglot Agent treats application/runtime versions separately from user state.

- `versions.env` is Git-tracked and selects container images.
- `.env` is untracked and stores local settings/secrets.
- backup format v2 records both the selected target versions and the actual images that were running when the backup began.

This separation prevents an old `.env` or restored backup from silently pinning an old Open WebUI/Ollama/Docling version.

## Upgrade

After checking out/pulling the target repository release:

```bash
make upgrade
```

The command creates a pre-upgrade full backup by default, pulls target images, starts the stack, then runs health/integration validation. Use `UPGRADE_BACKUP_KIND=user-data make upgrade` only when you deliberately accept a lighter rollback scope to save disk/time. The pre-upgrade backup is retained even when validation succeeds.

If validation fails, do not keep repeatedly booting the failed target against the old database. Use the printed rollback command.

## Restore compatibility guard

Open WebUI owns a persistent application database and may apply migrations at startup. Backup v2 therefore records the image that actually owned the database when it was copied.

A normal `make restore` refuses a version mismatch by default. An intentional forward migration can be acknowledged with:

```bash
RESTORE_ALLOW_VERSION_MISMATCH=1 BACKUP=... make restore
```

This flag is not a guarantee of compatibility; it only confirms that the operator has chosen to cross the recorded version boundary.

## Rollback

```bash
BACKUP=backups/<backup> RESTORE_CONFIRM=RESTORE make rollback
```

Rollback selects the backup's `versions.running.env`, restores the pre-upgrade data, and starts those recorded runtime images. For long-term operation, also check out the repository release/commit matching that runtime before the next ordinary `make up`.

## Backup archive safety

Restore verifies SHA-256 checksums before changing services. It accepts only regular files/directories under the expected volume roots and rejects parent traversal, absolute paths, symlinks, hardlinks, device nodes, FIFOs, sockets, and unexpected roots.
