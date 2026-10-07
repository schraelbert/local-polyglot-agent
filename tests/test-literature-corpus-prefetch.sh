#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/archive/poetry-collection-main/volumes" "$tmp/corpus"
cat >"$tmp/archive/poetry-collection-main/volumes/volume_001.json" <<'JSON'
[
  {"uuid":"1","title":"黄鹤楼送孟浩然之广陵","author":"李白","dynasty":"唐","content":"故人西辞黄鹤楼，烟花三月下扬州。\n孤帆远影碧空尽，惟见长江天际流。"},
  {"uuid":"2","title":"山中","author":"王维","dynasty":"唐","content":"荆溪白石出，天寒红叶稀。\n山路元无雨，空翠湿人衣。"}
]
JSON
python3 - "$tmp/archive" "$tmp/corpus.tar.gz" <<'PY'
import sys, tarfile
root, out = sys.argv[1:]
with tarfile.open(out, 'w:gz') as tf:
    tf.add(root + '/poetry-collection-main', arcname='poetry-collection-main')
PY

LITERATURE_CORPUS_DIR="$tmp/corpus" \
LITERATURE_CORPUS_ARCHIVE="$tmp/corpus.tar.gz" \
LITERATURE_CORPUS_MIN_WORKS=2 \
LITERATURE_CORPUS_REV=test \
python3 scripts/prefetch-literature-corpus.py >/dev/null

python3 - "$tmp/corpus/poetry.sqlite3" <<'PY'
import sqlite3, sys
con=sqlite3.connect(sys.argv[1])
rows=con.execute('select title,author,content from works order by id').fetchall()
assert len(rows)==2, rows
assert rows[0][0]=='黄鹤楼送孟浩然之广陵'
assert '孤帆远影碧空尽' in rows[0][2]
con.close()
PY

python3 - "$tmp/corpus/.literature-corpus-ready.json" <<'PY'
import json, sys
marker=json.load(open(sys.argv[1], encoding='utf-8'))
assert marker['count'] == 2, marker
assert len(marker['archive_sha256']) == 64, marker
PY

# Second run must reuse the local marker and not need the source archive.
rm "$tmp/corpus.tar.gz"
out="$(LITERATURE_CORPUS_DIR="$tmp/corpus" LITERATURE_CORPUS_ARCHIVE="$tmp/missing.tar.gz" LITERATURE_CORPUS_MIN_WORKS=2 LITERATURE_CORPUS_REV=test python3 scripts/prefetch-literature-corpus.py)"
grep -Fq 'already provisioned' <<<"$out"

# Deployment wiring: corpus is a first-class one-shot provisioned dependency and
# both check/smoke enforce its readiness.
grep -q '^  literature-corpus-init:' compose.yaml
grep -q 'literature-corpus:/corpus:ro' compose.yaml
grep -q 'up --no-deps --force-recreate literature-corpus-init' scripts/up.sh
grep -q 'local literature corpus' scripts/check.sh
grep -q 'local literature corpus ready' scripts/smoke-test.sh

echo 'literature corpus prefetch test passed'
