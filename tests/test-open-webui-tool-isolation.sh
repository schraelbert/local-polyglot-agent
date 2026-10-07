#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { echo "[fail] $*" >&2; exit 1; }

grep -Fq 'DEFAULT_MODEL_METADATA:' compose.yaml || fail "DEFAULT_MODEL_METADATA missing from Open WebUI deployment"
grep -Fq '"builtin_tools":false' compose.yaml || fail "Open WebUI builtin_tools master switch is not disabled"
grep -Fq '"file_context":true' compose.yaml || fail "File Context/RAG should remain enabled"
grep -Fq 'ENABLE_PLUGINS: "false"' compose.yaml || fail "Workspace plugins are not disabled"

grep -Fq 'strip_client_tooling(payload)' scripts/model-router.py || fail "router does not strip client tool schemas"
for field in tools tool_choice parallel_tool_calls functions function_call; do
  grep -Fq "\"${field}\"" scripts/model-router.py || fail "router strip policy missing ${field}"
done

python3 - <<'PY'
import importlib.util, json
from pathlib import Path
p = Path('scripts/model-router.py')
spec = importlib.util.spec_from_file_location('router', p)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
payload = {
    'model': mod.PUBLIC_MODEL,
    'messages': [{'role': 'user', 'content': '空山不见人，但闻人语响。'}],
    'tools': [{'type':'function','function':{'name':'create_tasks','parameters':{'type':'object'}}}],
    'tool_choice': 'auto',
    'parallel_tool_calls': True,
    'functions': [{'name':'legacy_tool'}],
    'function_call': 'auto',
}
out = json.loads(mod.rewrite_model_payload(json.dumps(payload, ensure_ascii=False).encode(), route_by_intent=True))
assert all(k not in out for k in mod._CLIENT_TOOL_FIELDS), out
assert out['messages'] == payload['messages']
PY

echo "Open WebUI/model-router tool isolation regression test passed"
