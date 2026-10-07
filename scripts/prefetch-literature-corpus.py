#!/usr/bin/env python3
"""Provision a local exact-text corpus for public-domain Chinese poetry.

The corpus is a reproducible cache, not a network service. On first provision it
fetches the upstream archive, builds a compact SQLite index, and writes a marker.
Later starts reuse the local database and therefore work offline.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import re
import shutil
import sqlite3
import sys
import tarfile
import tempfile
import urllib.request
from pathlib import Path

CORPUS_DIR = Path(os.environ.get("LITERATURE_CORPUS_DIR", "/corpus"))
DB_PATH = CORPUS_DIR / "poetry.sqlite3"
MARKER_PATH = CORPUS_DIR / ".literature-corpus-ready.json"
SOURCE_URL = os.environ.get(
    "LITERATURE_CORPUS_URL",
    "https://codeload.github.com/open-chinese/poetry-collection/tar.gz/refs/heads/main",
)
SOURCE_NAME = os.environ.get("LITERATURE_CORPUS_SOURCE", "open-chinese/poetry-collection")
CORPUS_REV = os.environ.get("LITERATURE_CORPUS_REV", "1")
MIN_WORKS = int(os.environ.get("LITERATURE_CORPUS_MIN_WORKS", "100000"))
FORCE = os.environ.get("FORCE_LITERATURE_CORPUS_UPDATE", "0").strip().lower() in {
    "1", "true", "yes", "on"
}
ARCHIVE_OVERRIDE = os.environ.get("LITERATURE_CORPUS_ARCHIVE", "").strip()


def normalize(text: str) -> str:
    return re.sub(r"[^0-9A-Za-z\u3400-\u4dbf\u4e00-\u9fff]+", "", text or "").lower()


def marker_valid() -> bool:
    if FORCE or not DB_PATH.is_file() or not MARKER_PATH.is_file():
        return False
    try:
        marker = json.loads(MARKER_PATH.read_text(encoding="utf-8"))
        if marker.get("rev") != CORPUS_REV:
            return False
        con = sqlite3.connect(f"file:{DB_PATH}?mode=ro", uri=True)
        try:
            count = int(con.execute("SELECT COUNT(*) FROM works").fetchone()[0])
        finally:
            con.close()
        return count >= MIN_WORKS
    except Exception:
        return False


def download_archive(destination: Path) -> None:
    if ARCHIVE_OVERRIDE:
        src = Path(ARCHIVE_OVERRIDE)
        if not src.is_file():
            raise RuntimeError(f"LITERATURE_CORPUS_ARCHIVE not found: {src}")
        shutil.copyfile(src, destination)
        return
    req = urllib.request.Request(
        SOURCE_URL,
        headers={"User-Agent": "local-polyglot-agent-literature-corpus/1"},
    )
    with urllib.request.urlopen(req, timeout=120) as resp, destination.open("wb") as out:
        shutil.copyfileobj(resp, out, length=1024 * 1024)


def iter_works(archive_path: Path):
    with tarfile.open(archive_path, "r:gz") as tf:
        members = [
            m for m in tf.getmembers()
            if m.isfile() and "/volumes/volume_" in m.name and m.name.endswith(".json")
        ]
        if not members:
            raise RuntimeError("corpus archive contained no volumes/volume_*.json files")
        members.sort(key=lambda m: m.name)
        for member in members:
            extracted = tf.extractfile(member)
            if extracted is None:
                continue
            try:
                payload = json.load(io.TextIOWrapper(extracted, encoding="utf-8"))
            except Exception as exc:
                raise RuntimeError(f"invalid corpus JSON in {member.name}: {exc}") from exc
            if isinstance(payload, dict):
                candidates = payload.get("data") or payload.get("poems") or payload.get("items") or []
            else:
                candidates = payload
            if not isinstance(candidates, list):
                continue
            for item in candidates:
                if not isinstance(item, dict):
                    continue
                title = str(item.get("title") or "").strip()
                author = str(item.get("author") or "").strip()
                dynasty = str(item.get("dynasty") or "").strip()
                content = item.get("content")
                if not isinstance(content, str):
                    paragraphs = item.get("paragraphs")
                    if isinstance(paragraphs, list):
                        content = "\n".join(str(x).strip() for x in paragraphs if str(x).strip())
                content = str(content or "").strip()
                if len(normalize(content)) < 4:
                    continue
                uid = str(item.get("uuid") or item.get("id") or "").strip()
                if not uid:
                    uid = hashlib.sha256(f"{author}\0{title}\0{content}".encode("utf-8")).hexdigest()
                yield uid, title, author, dynasty, content


def build_db(archive_path: Path, destination: Path) -> int:
    tmp_db = destination.with_suffix(".sqlite3.tmp")
    tmp_db.unlink(missing_ok=True)
    con = sqlite3.connect(tmp_db)
    try:
        con.execute("PRAGMA journal_mode=OFF")
        con.execute("PRAGMA synchronous=OFF")
        con.execute("PRAGMA temp_store=MEMORY")
        con.execute(
            """CREATE TABLE works (
                id TEXT PRIMARY KEY,
                title TEXT NOT NULL,
                author TEXT NOT NULL,
                dynasty TEXT NOT NULL,
                content TEXT NOT NULL,
                title_norm TEXT NOT NULL,
                author_norm TEXT NOT NULL,
                content_norm TEXT NOT NULL
            )"""
        )
        batch = []
        count = 0
        for uid, title, author, dynasty, content in iter_works(archive_path):
            batch.append((uid, title, author, dynasty, content, normalize(title), normalize(author), normalize(content)))
            if len(batch) >= 2000:
                con.executemany(
                    "INSERT OR IGNORE INTO works VALUES (?,?,?,?,?,?,?,?)", batch
                )
                count += con.execute("SELECT changes()").fetchone()[0]
                batch.clear()
        if batch:
            con.executemany("INSERT OR IGNORE INTO works VALUES (?,?,?,?,?,?,?,?)", batch)
        con.execute("CREATE INDEX idx_works_title_norm ON works(title_norm)")
        con.execute("CREATE INDEX idx_works_author_norm ON works(author_norm)")
        con.execute("CREATE INDEX idx_works_dynasty ON works(dynasty)")
        con.execute("ANALYZE")
        count = int(con.execute("SELECT COUNT(*) FROM works").fetchone()[0])
        con.commit()
    finally:
        con.close()
    if count < MIN_WORKS:
        tmp_db.unlink(missing_ok=True)
        raise RuntimeError(f"corpus validation failed: indexed {count} works, expected at least {MIN_WORKS}")
    os.replace(tmp_db, destination)
    return count


def main() -> int:
    CORPUS_DIR.mkdir(parents=True, exist_ok=True)
    if marker_valid():
        marker = json.loads(MARKER_PATH.read_text(encoding="utf-8"))
        print(f"Literature corpus already provisioned: {marker.get('count')} works ({SOURCE_NAME}).")
        return 0

    with tempfile.TemporaryDirectory(prefix="lpa-literature-") as td:
        archive = Path(td) / "corpus.tar.gz"
        print(f"Provisioning local literature corpus from {SOURCE_NAME} ...", flush=True)
        download_archive(archive)
        archive_sha256 = hashlib.sha256()
        with archive.open("rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                archive_sha256.update(chunk)
        count = build_db(archive, DB_PATH)

    marker = {
        "rev": CORPUS_REV,
        "source": SOURCE_NAME,
        "url": SOURCE_URL,
        "archive_sha256": archive_sha256.hexdigest(),
        "count": count,
        "schema": 1,
    }
    MARKER_PATH.write_text(json.dumps(marker, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"Literature corpus ready: {count} works indexed locally.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"Literature corpus provisioning failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
