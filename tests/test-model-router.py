#!/usr/bin/env python3
import importlib.util
import json
import sqlite3
import tempfile
import threading
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

ROOT = Path(__file__).resolve().parents[1]
router_path = ROOT / "scripts" / "model-router.py"
spec = importlib.util.spec_from_file_location("model_router", router_path)
router = importlib.util.module_from_spec(spec)
assert spec and spec.loader
spec.loader.exec_module(router)


def rewrite(payload):
    return json.loads(
        router.rewrite_model_payload(
            json.dumps(payload, ensure_ascii=False).encode(), route_by_intent=True
        )
    )


# Single-turn anchors: Chinese -> Chinese conversation model; other text -> multilingual.
payload = {"model": router.PUBLIC_MODEL, "prompt": "你好，介绍一下奥斯陆。", "stream": False}
assert rewrite(payload)["model"] == router.KNOWLEDGE_MODEL
payload = {"model": router.PUBLIC_MODEL, "prompt": "Hello, tell me about Oslo.", "stream": False}
rewritten = rewrite(payload)
assert rewritten["model"] == router.TRANSLATION_MODEL
assert rewritten["think"] is False

# Open WebUI Native mode may inject built-in tools (including create_tasks).
# The curated router must strip all client tool/function schemas before Ollama
# so ordinary chat cannot accidentally trigger UI-side agentic actions.
tool_injected = {
    "model": router.PUBLIC_MODEL,
    "messages": [{"role": "user", "content": "空山不见人，但闻人语响。"}],
    "stream": False,
    "tools": [{"type": "function", "function": {"name": "create_tasks", "parameters": {"type": "object"}}}],
    "tool_choice": "auto",
    "parallel_tool_calls": True,
    "functions": [{"name": "legacy_tool", "parameters": {"type": "object"}}],
    "function_call": "auto",
}
stripped = rewrite(tool_injected)
for forbidden in router._CLIENT_TOOL_FIELDS:
    assert forbidden not in stripped
assert stripped["messages"] == tool_injected["messages"]

# A conversation is sticky to the first substantive user turn. Ordinary follow-ups
# stay on the anchor; contextual translation is a tool handoff that first resolves
# the source through that anchor and then uses the multilingual translator.
cn_history = [
    {"role": "user", "content": "孤帆远影碧空尽，唯见长江天际流。请说明出处。"},
    {"role": "assistant", "content": "李白《黄鹤楼送孟浩然之广陵》。"},
    {"role": "user", "content": "翻译全诗成英文。"},
]
payload = {"model": router.PUBLIC_MODEL, "messages": cn_history, "stream": False}
rewritten = rewrite(payload)
assert router.route_kind(payload) == "translation-context-tool"
assert router.contextual_translation(payload)
assert rewritten["model"] == router.TRANSLATION_MODEL
resolver = router.build_context_resolution_payload(payload)
assert resolver["model"] == router.KNOWLEDGE_MODEL
assert resolver["messages"][1:] == cn_history
assert resolver["format"] == "json"
source = "故人西辞黄鹤楼，烟花三月下扬州。\n孤帆远影碧空尽，唯见长江天际流。"
resolved = router.parse_context_resolution({"message": {"content": json.dumps({"status": "ok", "source": source}, ensure_ascii=False)}})
assert resolved == source
assert router.full_context_translation_request(payload)
assert "李白" in router.context_referent_hint(payload)
snippets = router.context_source_snippets(payload)
assert any("孤帆远影碧空尽" in item for item in snippets)
retrieval = router.build_full_source_retrieval_payload(payload, router.KNOWLEDGE_MODEL)
assert retrieval["model"] == router.KNOWLEDGE_MODEL
assert "李白" in retrieval["messages"][-1]["content"]
assert "孤帆远影碧空尽" in retrieval["messages"][-1]["content"]
assert router.parse_full_source_retrieval({"message": {"content": source}}, payload) == source
assert router.parse_full_source_retrieval({"message": {"content": "孤帆远影碧空尽，唯见长江天际流。"}}, payload) is None
assert router.parse_full_source_retrieval({"message": {"content": "NEED_SOURCE"}}, payload) is None

# Whole-work contextual translation prefers an exact local corpus over asking a
# small model to recreate missing source text from memory.
corpus_tmp = tempfile.TemporaryDirectory()
corpus_db = Path(corpus_tmp.name) / "poetry.sqlite3"
con = sqlite3.connect(corpus_db)
con.execute("""CREATE TABLE works (
    id TEXT PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, dynasty TEXT NOT NULL,
    content TEXT NOT NULL, title_norm TEXT NOT NULL, author_norm TEXT NOT NULL, content_norm TEXT NOT NULL
)""")
# Deliberately store a common edition variant (惟) while the user supplied 唯.
# Exact substring matching would reject the right work even though title, author,
# and every other character agree.
corpus_source = "故人西辞黄鹤楼，烟花三月下扬州。\n孤帆远影碧空尽，惟见长江天际流。"
con.execute(
    "INSERT INTO works VALUES (?,?,?,?,?,?,?,?)",
    (
        "fixture-1", "黄鹤楼送孟浩然之广陵", "李白", "唐", corpus_source,
        router._normalized_source_text("黄鹤楼送孟浩然之广陵"),
        router._normalized_source_text("李白"),
        router._normalized_source_text(corpus_source),
    ),
)
# Nearby but unrelated work protects the fuzzy matcher from over-accepting.
other_source = "孤帆一片日边来，两岸青山相对出。"
con.execute(
    "INSERT INTO works VALUES (?,?,?,?,?,?,?,?)",
    (
        "fixture-2", "望天门山", "李白", "唐", other_source,
        router._normalized_source_text("望天门山"),
        router._normalized_source_text("李白"),
        router._normalized_source_text(other_source),
    ),
)
con.commit(); con.close()
router.LITERATURE_CORPUS_DB = str(corpus_db)
assert router.corpus_ready()
assert router._source_matches_snippet(corpus_source, "孤帆远影碧空尽，唯见长江天际流")
assert not router._source_matches_snippet(other_source, "孤帆远影碧空尽，唯见长江天际流")
work = router.corpus_lookup_full_work(payload)
assert work is not None
assert work["source"] == corpus_source
assert work["title"] == "黄鹤楼送孟浩然之广陵"
assert work["author"] == "李白"
assert router.corpus_lookup_full_source(payload) == corpus_source

# Even a bad assistant title hint must not block recovery from literal user text.
wrong_hint_payload = {
    "model": router.PUBLIC_MODEL,
    "messages": [
        {"role": "user", "content": "孤帆远影碧空尽，唯见长江天际流。请说明出处。"},
        {"role": "assistant", "content": "杜甫《登高》。"},
        {"role": "user", "content": "翻译全诗成英文。"},
    ],
    "stream": False,
}
assert router.corpus_lookup_full_source(wrong_hint_payload) == corpus_source

tool_payload = router.build_context_translation_payload(payload, resolved, work)
assert tool_payload["model"] == router.TRANSLATION_MODEL
assert source in tool_payload["messages"][-1]["content"]
assert "翻译全诗成英文" in tool_payload["messages"][-1]["content"]
assert "Title: 黄鹤楼送孟浩然之广陵" in tool_payload["messages"][-1]["content"]
assert "Author: 李白" in tool_payload["messages"][-1]["content"]
assert tool_payload["options"]["temperature"] == 0
assert "Never replace one named entity with another" in tool_payload["messages"][0]["content"]
assert "LOCAL_POLYGLOT_LITERARY_DRAFT" in tool_payload["messages"][0]["content"]

# Whole-work translation is grounded in the verified corpus source and trusted
# identity metadata. It stays single-pass so release quality is not made dependent
# on repeated hidden rewrites of the same small local model.
multi_history = [
    {"role": "user", "content": "Remember that my project code is K7-219."},
    {"role": "assistant", "content": "Got it."},
    {"role": "user", "content": "王维是谁？"},
]
payload = {"model": router.PUBLIC_MODEL, "messages": multi_history, "stream": False}
rewritten = rewrite(payload)
assert router.route_kind(payload) == "conversation-multi"
assert rewritten["model"] == router.TRANSLATION_MODEL
assert rewritten["messages"] == multi_history

# Self-contained translation bypasses directly. Contextual translation with prior
# turns enters the resolve-then-translate tool pipeline.
for prompt in (
    "翻译成英文：你好，世界。",
    "Translate into Chinese: Good morning.",
    "翻译成英文：\n我明天去奥斯陆。",
    "把‘我明天去奥斯陆’翻译成英文。",
):
    payload = {"model": router.PUBLIC_MODEL, "prompt": prompt}
    assert router.self_contained_translation(payload), prompt
    assert rewrite(payload)["model"] == router.TRANSLATION_MODEL

for prompt in (
    "翻译全诗",
    "把刚才那个翻成英文",
    "继续翻译",
    "Translate that into Norwegian",
):
    payload = {
        "model": router.PUBLIC_MODEL,
        "messages": [
            {"role": "user", "content": "这是上下文。"},
            {"role": "assistant", "content": "好的。"},
            {"role": "user", "content": prompt},
        ],
    }
    assert not router.self_contained_translation(payload), prompt
    assert router.contextual_translation(payload), prompt
    assert router.route_kind(payload) == "translation-context-tool"
    assert rewrite(payload)["model"] == router.TRANSLATION_MODEL

# Minimal UX guard: obviously underspecified commands get one concise
# clarification locally instead of consuming a model turn or guessing. The guard
# stays narrow; contextual explain/continue commands still go to the sticky anchor.
ux_history = [
    {"role": "user", "content": "相看两不厌，唯有敬亭山。"},
    {"role": "assistant", "content": "这是李白《独坐敬亭山》中的诗句。"},
]
assert router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "翻译"}],
}) == "想翻译成哪种语言？例如英文、挪威语或其他语言。"
assert "语气" in router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "改一下"}],
})
assert router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "解释一下"}],
}) is None
assert router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "继续"}],
}) is None
assert router.ux_guard_response({"model": router.PUBLIC_MODEL, "prompt": "解释一下"}) == "想让我解释什么内容？"
assert router.ux_guard_response({"model": router.PUBLIC_MODEL, "prompt": "继续"}) == "想继续什么内容？"
assert router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "翻译成英文"}],
}) is None
assert router.ux_guard_response({
    "model": router.PUBLIC_MODEL,
    "messages": [*ux_history, {"role": "user", "content": "Translate this"}],
}) == "Which language would you like it translated into?"

# Explicit numbered-sentence references are deterministic when the user already
# supplied labelled source text. They must not depend on the small anchor model
# returning a resolver JSON object correctly on every run.
ordinal_payload = {
    "model": router.PUBLIC_MODEL,
    "messages": [
        {"role": "user", "content": "请记住两句话：第一句是“天气很好”。第二句是“我明天去奥斯陆”。先只回复“记住了”。"},
        {"role": "assistant", "content": "记住了。"},
        {"role": "user", "content": "把第二句翻成英文，只输出译文。"},
    ],
}
assert router.deterministic_context_source(ordinal_payload) == "我明天去奥斯陆"
ordinal_plain = {
    "model": router.PUBLIC_MODEL,
    "messages": [
        {"role": "user", "content": "第一句是天气很好，第二句是我明天去奥斯陆。"},
        {"role": "assistant", "content": "好的。"},
        {"role": "user", "content": "把第2句翻成英文。"},
    ],
}
assert router.deterministic_context_source(ordinal_plain) == "我明天去奥斯陆"
ordinal_tool = router.build_context_translation_payload(
    ordinal_plain, router.deterministic_context_source(ordinal_plain)
)
assert "faithful literary-translation" not in ordinal_tool["messages"][0]["content"]
assert "Authoritative source identity metadata" not in ordinal_tool["messages"][-1]["content"]
assert "temperature" not in ordinal_tool.get("options", {})

ambiguous_payload = {
    "model": router.PUBLIC_MODEL,
    "messages": [
        {"role": "user", "content": "这是一段文本。"},
        {"role": "assistant", "content": "好的。"},
        {"role": "user", "content": "把刚才那个翻成英文。"},
    ],
}
assert router.deterministic_context_source(ambiguous_payload) is None

# A first-turn translation command with no source has no context to resolve and
# must remain a normal conversation turn rather than inventing source material.
payload = {"model": router.PUBLIC_MODEL, "prompt": "翻译全诗"}
assert not router.contextual_translation(payload)
assert rewrite(payload)["model"] == router.KNOWLEDGE_MODEL

# A self-contained translation can bypass a Chinese conversation for that tool
# turn, while the history itself remains untouched.
payload = {
    "model": router.PUBLIC_MODEL,
    "messages": [
        {"role": "user", "content": "我在整理一份中英笔记。"},
        {"role": "assistant", "content": "好的。"},
        {"role": "user", "content": "翻译成英文：我明天去奥斯陆。"},
    ],
}
original_messages = json.loads(json.dumps(payload["messages"], ensure_ascii=False))
rewritten = rewrite(payload)
assert rewritten["model"] == router.TRANSLATION_MODEL
assert rewritten["messages"] == original_messages

# Images bypass text anchoring entirely.
payload = {
    "model": router.PUBLIC_MODEL,
    "messages": [{"role": "user", "content": "这是什么", "images": ["abc"]}],
    "think": True,
}
rewritten = rewrite(payload)
assert rewritten["model"] == router.VISION_MODEL
assert "think" not in rewritten

# Explicit client thinking is preserved only when the routed model supports the
# multilingual Qwen path; direct Chinese/vision routes strip it.
payload = {"model": router.PUBLIC_MODEL, "prompt": "Reason carefully", "think": True}
assert rewrite(payload)["think"] is True
payload = {"model": router.PUBLIC_MODEL, "prompt": "仔细想想这个问题", "think": True}
assert "think" not in rewrite(payload)

# A caller naming a hidden/non-public model is never silently rewritten.
payload = {"model": "other:latest", "images": ["abc"]}
assert rewrite(payload)["model"] == "other:latest"

# Curated model list exposes exactly one public model using multilingual metadata
# plus the aggregate vision capability.
tags = {
    "models": [
        {"name": router.TRANSLATION_MODEL, "model": router.TRANSLATION_MODEL, "size": 6600000000},
        {"name": router.KNOWLEDGE_MODEL, "model": router.KNOWLEDGE_MODEL, "size": 4700000000},
        {"name": router.VISION_MODEL, "model": router.VISION_MODEL, "size": 4400000000},
    ]
}
filtered = json.loads(router.filter_tags(json.dumps(tags).encode()))
assert len(filtered["models"]) == 1
assert filtered["models"][0]["name"] == router.PUBLIC_MODEL
assert "vision" in filtered["models"][0]["capabilities"]

for internal in (router.TRANSLATION_MODEL, router.KNOWLEDGE_MODEL, router.VISION_MODEL):
    ps = {"models": [{"name": internal, "model": internal, "size": 1}]}
    filtered_ps = json.loads(router.filter_ps(json.dumps(ps).encode()))
    assert filtered_ps["models"][0]["name"] == router.PUBLIC_MODEL

compose = (ROOT / "compose.yaml").read_text()
assert "OLLAMA_BASE_URL: http://model-router:11434" in compose
assert "RAG_OLLAMA_BASE_URL: http://ollama:11434" in compose
assert 'ENABLE_EVALUATION_ARENA_MODELS: "false"' in compose
assert 'ENABLE_MODEL_FILTER: "true"' in compose
assert "MODEL_FILTER_LIST: ${AGENT_MODEL:-polyglot-agent:latest}" in compose
assert "KNOWLEDGE_MODEL: ${KNOWLEDGE_AGENT_MODEL:-polyglot-agent-knowledge:latest}" in compose

print("model router unit test passed")

# Minimal HTTP integration: verify tags, sticky anchoring, direct translation,
# contextual resolve-then-translate handoff, vision bypass, and hidden-model isolation.
seen_models = []
seen_payloads = []


class FakeOllama(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def _json(self, obj, status=200):
        data = json.dumps(obj, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):  # noqa: N802
        if self.path == "/api/tags":
            self._json(
                {
                    "models": [
                        {"name": router.TRANSLATION_MODEL, "model": router.TRANSLATION_MODEL, "size": 8},
                        {"name": router.KNOWLEDGE_MODEL, "model": router.KNOWLEDGE_MODEL, "size": 6},
                        {"name": router.VISION_MODEL, "model": router.VISION_MODEL, "size": 4},
                    ]
                }
            )
        elif self.path == "/api/version":
            self._json({"version": "test"})
        elif self.path == "/api/ps":
            self._json({"models": []})
        else:
            self._json({"error": "not found"}, 404)

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b"{}"
        payload = json.loads(body)
        seen_models.append(payload.get("model"))
        seen_payloads.append(payload)
        if self.path.startswith("/api/chat"):
            messages = payload.get("messages") if isinstance(payload.get("messages"), list) else []
            first_system = ""
            if messages and isinstance(messages[0], dict) and messages[0].get("role") == "system":
                first_system = str(messages[0].get("content") or "")
            if "LOCAL_POLYGLOT_CONTEXT_RESOLVER" in first_system:
                # Exercise the production fallback: the conversational resolver
                # returns only the excerpt already present in chat. A whole-work
                # request must detect that this is incomplete and retrieve clean
                # source text before translating.
                content = json.dumps(
                    {"status": "ok", "source": "孤帆远影碧空尽，唯见长江天际流。"},
                    ensure_ascii=False,
                )
            elif "LOCAL_POLYGLOT_PUBLIC_DOMAIN_SOURCE_RETRIEVER" in first_system:
                source = "故人西辞黄鹤楼，烟花三月下扬州。\n孤帆远影碧空尽，唯见长江天际流。"
                # Exercise both local text models: the Chinese anchor may decline
                # exact-text retrieval, after which the multilingual model gets a
                # clean second chance before the actual translation call.
                content = "NEED_SOURCE" if payload.get("model") == router.KNOWLEDGE_MODEL else source
            elif "LOCAL_POLYGLOT_LITERARY_DRAFT" in first_system:
                # A whole-work translation may use the attested 碧山 textual
                # variant. The router's job is to ground it in the complete corpus
                # source and preserve conversation continuity, not run hidden
                # rewrite loops to force one critical edition.
                content = (
                    "Farewell to an old friend at the Yellow Crane Tower; in misty March he sails for Yangzhou. "
                    "A lone sail disappears beyond the green hills; only the Yangtze River flows to the horizon."
                )
            elif payload.get("model") == router.TRANSLATION_MODEL and any(
                isinstance(m, dict) and "Resolved source text:" in str(m.get("content") or "") for m in messages
            ):
                content = "I will go to Oslo tomorrow."
            else:
                content = "ok"
            data = (json.dumps({"message": {"role": "assistant", "content": content}, "done": True}, ensure_ascii=False, separators=(",", ":")) + "\n").encode()
        else:
            data = b'{"response":"ok","done":true}\n'
        self.send_response(200)
        self.send_header("Content-Type", "application/x-ndjson")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


fake = ThreadingHTTPServer(("127.0.0.1", 0), FakeOllama)
fake_thread = threading.Thread(target=fake.serve_forever, daemon=True)
fake_thread.start()
router.UPSTREAM = urlsplit(f"http://127.0.0.1:{fake.server_address[1]}")
proxy = ThreadingHTTPServer(("127.0.0.1", 0), router.RouterHandler)
proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
proxy_thread.start()
proxy_url = f"http://127.0.0.1:{proxy.server_address[1]}"


def post(path, body):
    req = urllib.request.Request(
        proxy_url + path,
        data=json.dumps(body, ensure_ascii=False).encode(),
        headers={"Content-Type": "application/json"},
    )
    return urllib.request.urlopen(req, timeout=3).read()


try:
    tags_out = json.loads(urllib.request.urlopen(proxy_url + "/api/tags", timeout=3).read())
    assert [m["name"] for m in tags_out["models"]] == [router.PUBLIC_MODEL]

    # Defense in depth at the deployed HTTP boundary: even if Open WebUI sends
    # Native tool schemas, the upstream Ollama request must contain none of them.
    before = len(seen_payloads)
    post(
        "/api/chat",
        {
            "model": router.PUBLIC_MODEL,
            "messages": [{"role": "user", "content": "空山不见人，但闻人语响。"}],
            "stream": False,
            "tools": [{"type": "function", "function": {"name": "create_tasks", "parameters": {"type": "object"}}}],
            "tool_choice": "auto",
            "parallel_tool_calls": True,
        },
    )
    assert len(seen_payloads) == before + 1
    forwarded = seen_payloads[-1]
    for forbidden in router._CLIENT_TOOL_FIELDS:
        assert forbidden not in forwarded

    # The deployed router itself must short-circuit bare commands without
    # touching Ollama. This is a UX guard, not another model-routing heuristic.
    before = len(seen_models)
    ux_out = json.loads(post(
        "/api/chat",
        {
            "model": router.PUBLIC_MODEL,
            "messages": [
                {"role": "user", "content": "相看两不厌，唯有敬亭山。"},
                {"role": "assistant", "content": "这是李白《独坐敬亭山》中的诗句。"},
                {"role": "user", "content": "翻译"},
            ],
            "stream": False,
        },
    ))
    assert "哪种语言" in ux_out["message"]["content"]
    assert len(seen_models) == before

    before = len(seen_models)
    ux_stream = post(
        "/api/chat",
        {
            "model": router.PUBLIC_MODEL,
            "messages": [
                {"role": "user", "content": "相看两不厌，唯有敬亭山。"},
                {"role": "assistant", "content": "这是李白《独坐敬亭山》中的诗句。"},
                {"role": "user", "content": "翻译"},
            ],
            "stream": True,
        },
    ).decode().strip()
    assert "哪种语言" in json.loads(ux_stream)["message"]["content"]
    assert len(seen_models) == before

    # Whole-work contextual translation prefers the exact local corpus before any
    # conversational resolver. This makes source identity deterministic and gives
    # the translator trusted title/author metadata for proper-noun fidelity.
    sticky = {
        "model": router.PUBLIC_MODEL,
        "messages": cn_history,
        "stream": False,
    }
    before = len(seen_models)
    contextual_out = json.loads(post("/api/chat", sticky))
    # Whole-work translation is one grounded multilingual tool call. The corpus
    # source and identity metadata are supplied directly; no hidden literary
    # rewrite loop is allowed.
    assert seen_models[before:] == [router.TRANSLATION_MODEL]
    literary_payload = seen_payloads[-1]
    assert "LOCAL_POLYGLOT_LITERARY_DRAFT" in literary_payload["messages"][0]["content"]
    literary_messages = literary_payload["messages"]
    assert any("故人西辞黄鹤楼" in str(m.get("content") or "") for m in literary_messages)
    assert any("惟见长江天际流" in str(m.get("content") or "") for m in literary_messages)
    assert any("Title: 黄鹤楼送孟浩然之广陵" in str(m.get("content") or "") for m in literary_messages)
    assert any("Author: 李白" in str(m.get("content") or "") for m in literary_messages)
    assert literary_payload["options"]["temperature"] == 0
    assert "Yellow Crane Tower" in contextual_out["message"]["content"]
    assert "green hills" in contextual_out["message"]["content"]

    # Explicit numbered-sentence context is resolved locally from prior user text.
    # Only the translation tool should hit Ollama; the Chinese anchor resolver is
    # deliberately not called, making this handoff deterministic for smoke/release.
    ordinal_chat = {
        "model": router.PUBLIC_MODEL,
        "messages": [
            {"role": "user", "content": "第一句是天气很好，第二句是我明天去奥斯陆。"},
            {"role": "assistant", "content": "记住了。"},
            {"role": "user", "content": "把第二句翻成英文，只输出译文。"},
        ],
        "stream": False,
    }
    before = len(seen_models)
    post("/api/chat", ordinal_chat)
    assert seen_models[before:] == [router.TRANSLATION_MODEL]
    assert any("我明天去奥斯陆" in str(m.get("content") or "") for m in seen_payloads[-1]["messages"])

    # Self-contained translation bypasses to Qwen3.5 without rewriting history.
    translate = {
        "model": router.PUBLIC_MODEL,
        "messages": [
            {"role": "user", "content": "我在整理笔记。"},
            {"role": "assistant", "content": "好的。"},
            {"role": "user", "content": "翻译成英文：我明天去奥斯陆。"},
        ],
        "stream": False,
    }
    post("/api/chat", translate)
    assert seen_models[-1] == router.TRANSLATION_MODEL
    assert seen_payloads[-1]["messages"] == translate["messages"]

    post("/api/generate", {"model": router.PUBLIC_MODEL, "prompt": "hello", "stream": False})
    assert seen_models[-1] == router.TRANSLATION_MODEL
    post("/api/generate", {"model": router.PUBLIC_MODEL, "prompt": "你好", "stream": False})
    assert seen_models[-1] == router.KNOWLEDGE_MODEL
    post("/api/generate", {"model": router.PUBLIC_MODEL, "prompt": "read", "images": ["abc"], "stream": False})
    assert seen_models[-1] == router.VISION_MODEL

    hidden_req = urllib.request.Request(
        proxy_url + "/api/generate",
        data=json.dumps({"model": router.KNOWLEDGE_MODEL, "prompt": "bypass"}).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        urllib.request.urlopen(hidden_req, timeout=3)
        raise AssertionError("hidden model bypass unexpectedly succeeded")
    except urllib.error.HTTPError as exc:
        assert exc.code == 404
finally:
    proxy.shutdown()
    corpus_tmp.cleanup()
    fake.shutdown()

print("model router HTTP integration test passed")
