#!/usr/bin/env python3
"""End-to-end multi-turn conversation quality probes.

Run inside the model-router container. Each scenario sends real sequential chat
requests through the public model endpoint and appends the assistant's actual
output to the next turn. It also checks the underlying loaded Ollama model.
Normal conversation turns must stay on the sticky anchor; contextual translation
may intentionally hand off to the multilingual translation tool after the anchor
resolves the referenced source, then later conversation turns return to the anchor.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.error
import urllib.request

PUBLIC_MODEL = os.environ.get("PUBLIC_MODEL", "polyglot-agent:latest")
MULTILINGUAL_MODEL = os.environ.get("TRANSLATION_MODEL", os.environ.get("TEXT_MODEL", PUBLIC_MODEL))
CHINESE_MODEL = os.environ.get("KNOWLEDGE_MODEL", "polyglot-agent-knowledge:latest")
ROUTER_URL = os.environ.get("E2E_ROUTER_URL", "http://127.0.0.1:11434")
OLLAMA_URL = os.environ.get("OLLAMA_UPSTREAM", "http://ollama:11434")
TIMEOUT = float(os.environ.get("E2E_TIMEOUT", os.environ.get("ROUTER_UPSTREAM_TIMEOUT", "300")))


class InfraError(RuntimeError):
    pass


def request_json(url: str, payload: dict | None = None) -> dict:
    try:
        if payload is None:
            req = urllib.request.Request(url)
        else:
            data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
            req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            raw = resp.read()
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise InfraError(str(exc)) from exc
    try:
        decoded = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise InfraError(f"invalid JSON from {url}: {raw[:200]!r}") from exc
    if not isinstance(decoded, dict):
        raise InfraError(f"unexpected non-object JSON from {url}")
    if decoded.get("error"):
        raise InfraError(str(decoded["error"]))
    return decoded


def loaded_model() -> str:
    payload = request_json(OLLAMA_URL.rstrip("/") + "/api/ps")
    models = payload.get("models")
    if not isinstance(models, list) or not models:
        return ""
    item = models[0]
    if not isinstance(item, dict):
        return ""
    return str(item.get("name") or item.get("model") or "")


def chat(messages: list[dict], num_predict: int = 512) -> tuple[str, str]:
    payload = {
        "model": PUBLIC_MODEL,
        "messages": messages,
        "stream": False,
        "options": {"num_predict": num_predict},
    }
    response = request_json(ROUTER_URL.rstrip("/") + "/api/chat", payload)
    message = response.get("message")
    if not isinstance(message, dict) or not isinstance(message.get("content"), str):
        raise InfraError(f"missing assistant content: {json.dumps(response, ensure_ascii=False)[:300]}")
    return message["content"].strip(), loaded_model()


def has(text: str, pattern: str) -> bool:
    return re.search(pattern, text, flags=re.IGNORECASE | re.DOTALL) is not None


def short(text: str, limit: int = 220) -> str:
    return re.sub(r"\s+", " ", text).strip()[:limit]


def emit(status: str, label: str, detail: str = "") -> None:
    detail = detail.replace("|", "/").replace("\n", " ")
    print(f"{status}|{label}|{detail}")


def case_poem_context() -> tuple[bool, str]:
    """Regression for the real UI failure: identify -> translate full poem -> resolve referent."""
    messages: list[dict] = []

    messages.append({
        "role": "user",
        "content": "孤帆远影碧空尽，唯见长江天际流。请告诉我这句诗的作者和篇名，只回答作者和篇名。",
    })
    first, route1 = chat(messages, 160)
    if route1 != CHINESE_MODEL:
        return False, f"turn1 route={route1 or '<none>'}, expected Chinese anchor {CHINESE_MODEL}"
    if not (has(first, r"李白") and has(first, r"黄鹤楼.*孟浩然.*广陵")):
        return False, f"turn1 attribution={short(first)!r}"
    messages.append({"role": "assistant", "content": first})

    messages.append({
        "role": "user",
        "content": "翻译全诗成英文，只输出英文译文。",
    })
    translated, route2 = chat(messages, 512)
    if route2 != MULTILINGUAL_MODEL:
        return False, f"contextual translation did not hand off to translation tool: {route2 or '<none>'}"
    translation_checks = (
        r"Yellow\s+Crane|Crane\s+Tower|Huang\s*He(?:\s*Lou)?|Huanghe(?:lou)?",
        r"Yangzhou",
        r"sail|boat|ship",
        r"river|Yangtze",
        r"horizon|distance|far\s+away|vanish|disappear",
    )
    # The third line has a long-attested textual variant: 碧空尽 / 碧山尽.
    # This E2E gate exists to catch the real product failure (losing the referent
    # and translating only the quoted excerpt), not to enforce one critical
    # edition of a classical work. Accept either coherent rendering, while still
    # rejecting a genuinely wrong named entity such as White Goose Tower.
    third_line_variant = has(translated, r"sky|heaven|azure|blue") or has(
        translated, r"(?:green\s+)?(?:hills?|mountains?)"
    )
    semantic_corruptions = (r"white\s+goose",)
    if (
        not all(has(translated, pattern) for pattern in translation_checks)
        or not third_line_variant
        or any(has(translated, pattern) for pattern in semantic_corruptions)
    ):
        return False, f"turn2 did not faithfully translate the referenced full poem: {short(translated)!r}"
    messages.append({"role": "assistant", "content": translated})

    messages.append({
        "role": "user",
        "content": "你能根据当前对话记录判断我刚才说的“全诗”指哪首诗吗？只回答作者和篇名。",
    })
    final, route3 = chat(messages, 160)
    if route3 != CHINESE_MODEL:
        return False, f"turn3 route={route3 or '<none>'}, expected sticky {CHINESE_MODEL}"
    if not (has(final, r"李白") and has(final, r"黄鹤楼.*孟浩然.*广陵")):
        return False, f"turn3 lost conversation referent: {short(final)!r}"
    return True, f"anchor={CHINESE_MODEL}; contextual translation tool={MULTILINGUAL_MODEL}; final={short(final)!r}"


def case_contextual_second_sentence() -> tuple[bool, str]:
    messages = [
        {
            "role": "user",
            "content": "请记住两句话：第一句是“天气很好”。第二句是“我明天去奥斯陆”。先只回复“记住了”。",
        }
    ]
    first, route1 = chat(messages, 64)
    if route1 != CHINESE_MODEL:
        return False, f"turn1 route={route1 or '<none>'}"
    messages.append({"role": "assistant", "content": first})
    messages.append({"role": "user", "content": "把第二句翻成英文，只输出译文。"})
    answer, route2 = chat(messages, 96)
    if route2 != MULTILINGUAL_MODEL:
        return False, f"contextual translation did not hand off to translation tool: {route2 or '<none>'}"
    if not (has(answer, r"Oslo") and has(answer, r"tomorrow")):
        return False, f"failed to resolve ‘第二句’: {short(answer)!r}"
    return True, f"anchor resolved context, translation tool={MULTILINGUAL_MODEL}; answer={short(answer)!r}"


def case_english_sticky_memory() -> tuple[bool, str]:
    messages = [{"role": "user", "content": "Remember this exact code: K7-219. Reply only OK."}]
    first, route1 = chat(messages, 48)
    if route1 != MULTILINGUAL_MODEL:
        return False, f"turn1 route={route1 or '<none>'}, expected {MULTILINGUAL_MODEL}"
    messages.append({"role": "assistant", "content": first})
    messages.append({"role": "user", "content": "What was the code? Reply only with the code."})
    answer, route2 = chat(messages, 48)
    if route2 != MULTILINGUAL_MODEL:
        return False, f"turn2 route={route2 or '<none>'}, expected sticky {MULTILINGUAL_MODEL}"
    if not has(answer, r"K7-219"):
        return False, f"lost cross-turn code: {short(answer)!r}"
    return True, f"route stayed on {MULTILINGUAL_MODEL}; answer={short(answer)!r}"


CASES = (
    ("E2E / poem referent + contextual full-poem translation", case_poem_context),
    ("E2E / contextual ‘second sentence’ translation", case_contextual_second_sentence),
    ("E2E / English sticky cross-turn memory", case_english_sticky_memory),
)


def main() -> int:
    quality_fail = 0
    infra_fail = 0
    for label, fn in CASES:
        try:
            ok, detail = fn()
        except InfraError as exc:
            infra_fail += 1
            emit("INFRA", label, str(exc))
            continue
        except Exception as exc:  # noqa: BLE001
            infra_fail += 1
            emit("INFRA", label, f"unexpected probe error: {exc}")
            continue
        if ok:
            emit("PASS", label, detail)
        else:
            quality_fail += 1
            emit("FAIL", label, detail)

    if infra_fail:
        return 2
    if quality_fail:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
