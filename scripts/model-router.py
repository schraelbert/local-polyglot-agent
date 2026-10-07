#!/usr/bin/env python3
"""Curated Ollama API router for Local Polyglot Agent.

The router intentionally optimizes for *conversation continuity*, not per-turn
benchmark specialization:

* A text conversation gets a sticky anchor model chosen from the first user
  turn. Chinese-first conversations use the Chinese conversation model;
  other text conversations use the multilingual conversation model.
* Full chat history is forwarded unchanged on every normal text turn. The router
  does not sanitize, flatten, replay, or replace prior messages.
* Self-contained translation jobs bypass directly to the multilingual translation
  model. Context-dependent translation jobs resolve an exact source first: explicit
  numbered references are extracted locally, whole public-domain works prefer the
  exact local corpus (with trusted title/author metadata), and only genuinely
  ambiguous references use the sticky conversation anchor. The multilingual model
  then translates the verified source under deterministic fidelity constraints.
* Image-bearing requests bypass text routing and use the vision model.

This keeps ordinary follow-ups such as "第二个呢", "继续", or "你刚才为什么
这么说" on the same model that owns the conversation, while contextual
translation requests such as "翻译全诗" can still use the stronger translation
model without losing their referent.
"""

from __future__ import annotations

import difflib
import http.client
import json
import os
import re
import sqlite3
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit

UPSTREAM = urlsplit(os.environ.get("OLLAMA_UPSTREAM", "http://ollama:11434"))
PUBLIC_MODEL = os.environ.get("PUBLIC_MODEL", "polyglot-agent:latest")
# Keep the historical variable names so existing .env/.runtime.env files remain
# compatible. TRANSLATION_MODEL is also the multilingual conversation anchor.
TRANSLATION_MODEL = os.environ.get(
    "TRANSLATION_MODEL", os.environ.get("TEXT_MODEL", PUBLIC_MODEL)
)
TEXT_MODEL = TRANSLATION_MODEL
# The former "knowledge expert" is now the Chinese conversation anchor. It is
# not selected turn-by-turn from factual intent.
KNOWLEDGE_MODEL = os.environ.get(
    "KNOWLEDGE_MODEL", "polyglot-agent-knowledge:latest"
)
VISION_MODEL = os.environ.get("VISION_MODEL", "polyglot-agent-vision:latest")
LISTEN_HOST = os.environ.get("ROUTER_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("ROUTER_PORT", "11434"))
TIMEOUT = float(os.environ.get("ROUTER_UPSTREAM_TIMEOUT", "900"))
CONTEXT_SOURCE_MAX_CHARS = int(os.environ.get("CONTEXT_SOURCE_MAX_CHARS", "12000"))
CONTEXT_RESOLVE_NUM_PREDICT = int(os.environ.get("CONTEXT_RESOLVE_NUM_PREDICT", "1024"))
LITERATURE_CORPUS_DB = os.environ.get("LITERATURE_CORPUS_DB", "/corpus/poetry.sqlite3")


def env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


TEXT_THINKING_DEFAULT = env_bool("TEXT_THINKING_DEFAULT", False)

if UPSTREAM.scheme not in {"http", ""}:
    raise SystemExit("model-router supports an internal HTTP Ollama upstream only")
if not UPSTREAM.hostname:
    raise SystemExit("OLLAMA_UPSTREAM must include a hostname")

_TRANSLATION_RE = re.compile(
    r"(?:翻译|翻成|译成|译为|翻译成|转成|转换成|英译|中译|"
    r"\btranslate\b|\btranslation\b|\btranslator\b|"
    r"\boversett\w*\b|\bomset\w*\b|\bset\s+om\b)",
    re.IGNORECASE,
)
_CJK_RE = re.compile(r"[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
_CONTEXT_REFERENCE_RE = re.compile(
    r"(?:全诗|全文|整首|整篇|这首|這首|这段|這段|这句|這句|刚才|剛才|"
    r"前面|上面|之前|前一个|前一個|后一个|後一個|那个|那個|这个|這個|"
    r"第一句|第二句|第一段|第二段|继续|繼續|对话记录|對話記錄|"
    r"\b(?:that|this|it|those|these|above|previous|earlier|same|continue|rest|"
    r"full\s+poem|whole\s+poem|conversation|context)\b)",
    re.IGNORECASE,
)
_QUOTED_SOURCE_RE = re.compile(
    r"[\"'“”‘’「」『』](.{2,}?)[\"'“”‘’「」『』]",
    re.DOTALL,
)

_FULL_CONTEXT_TRANSLATION_RE = re.compile(
    r"(?:全诗|全文|整首|整篇|全篇|完整(?:原文|诗|文章)|"
    r"\b(?:full|whole|entire)\s+(?:poem|text|work|piece|article)\b)",
    re.IGNORECASE,
)
_SOURCE_INSTRUCTION_RE = re.compile(
    r"(?:请|回答|告诉|说明|解释|翻译|译成|翻成|记住|只(?:回答|回复|输出)|"
    r"please|reply|answer|tell|explain|translate|remember)",
    re.IGNORECASE,
)

# Small deterministic UX guard for commands that are missing a required
# parameter. Keep this intentionally narrow: it should prevent obvious dead-end
# behavior (for example echoing text after a bare “翻译”) without turning the
# router into another intent engine. Commands with enough information, and
# ordinary contextual follow-ups, continue to the sticky conversation anchor.
_UX_BARE_TRANSLATE_RE = re.compile(
    r"^(?:(?:请|麻烦|帮我|请帮我)\s*)?(?:翻译|翻译一下|翻一下|译一下)\s*[。.!！?？]*$|"
    r"^(?:please\s+)?translate(?:\s+(?:this|that))?\s*[.!?]*$|"
    r"^(?:vennligst\s+)?oversett(?:\s+(?:dette|det))?\s*[.!?]*$",
    re.IGNORECASE,
)
_UX_BARE_EDIT_RE = re.compile(
    r"^(?:(?:请|麻烦|帮我|请帮我)\s*)?(?:改一下|修改一下|改改|调整一下)\s*[。.!！?？]*$|"
    r"^(?:please\s+)?(?:edit|revise|change)(?:\s+(?:this|that|it))?\s*[.!?]*$|"
    r"^(?:vennligst\s+)?(?:endre|rediger)(?:\s+(?:dette|det))?\s*[.!?]*$",
    re.IGNORECASE,
)
_UX_BARE_EXPLAIN_RE = re.compile(
    r"^(?:(?:请|麻烦|帮我|请帮我)\s*)?(?:解释一下|说明一下|解释|说明)\s*[。.!！?？]*$|"
    r"^(?:please\s+)?explain(?:\s+(?:this|that|it))?\s*[.!?]*$|"
    r"^(?:vennligst\s+)?forklar(?:\s+(?:dette|det))?\s*[.!?]*$",
    re.IGNORECASE,
)
_UX_BARE_CONTINUE_RE = re.compile(
    r"^(?:继续|继续吧|接着|接着说|往下说)\s*[。.!！?？]*$|"
    r"^(?:continue|go\s+on)\s*[.!?]*$|"
    r"^(?:fortsett|fortsett\s+videre)\s*[.!?]*$",
    re.IGNORECASE,
)
_NORWEGIAN_UX_RE = re.compile(r"\b(?:oversett|endre|rediger|forklar|fortsett)\b", re.IGNORECASE)


def _has_prior_conversation_context(payload: dict) -> bool:
    messages = _chat_messages(payload)
    latest_user = None
    for idx in range(len(messages) - 1, -1, -1):
        if messages[idx].get("role") == "user" and _content_text(messages[idx].get("content")).strip():
            latest_user = idx
            break
    if latest_user is None:
        return False
    for message in messages[:latest_user]:
        if message.get("role") not in {"user", "assistant"}:
            continue
        if _content_text(message.get("content")).strip():
            return True
    return False


def ux_guard_response(payload: dict) -> str | None:
    """Return a concise local clarification for obviously underspecified commands.

    The guard is deliberately deterministic and narrow. It never rewrites user
    history and never handles commands that already include the missing detail.
    """
    if has_images(payload):
        return None
    text = user_text(payload).strip()
    if not text:
        return None
    has_prior = _has_prior_conversation_context(payload)
    chinese = bool(_CJK_RE.search(text))
    norwegian = bool(_NORWEGIAN_UX_RE.search(text))

    if _UX_BARE_TRANSLATE_RE.fullmatch(text):
        if chinese:
            if has_prior:
                return "想翻译成哪种语言？例如英文、挪威语或其他语言。"
            return "请告诉我想翻译什么，以及要翻译成哪种语言。"
        if norwegian:
            if has_prior:
                return "Hvilket språk vil du oversette til?"
            return "Hva vil du oversette, og hvilket språk skal det oversettes til?"
        if has_prior:
            return "Which language would you like it translated into?"
        return "What would you like me to translate, and into which language?"

    if _UX_BARE_EDIT_RE.fullmatch(text):
        if chinese:
            if has_prior:
                return "想改哪一方面？例如语气、长度、措辞或内容。"
            return "请提供要修改的内容，并告诉我想改哪一方面。"
        if norwegian:
            if has_prior:
                return "Hva vil du endre, for eksempel tone, lengde, formulering eller innhold?"
            return "Send teksten du vil endre, og si hva du vil justere."
        if has_prior:
            return "What would you like changed—for example tone, length, wording, or content?"
        return "Please provide the text to change and tell me what you want adjusted."

    if _UX_BARE_EXPLAIN_RE.fullmatch(text) and not has_prior:
        if chinese:
            return "想让我解释什么内容？"
        if norwegian:
            return "Hva vil du at jeg skal forklare?"
        return "What would you like me to explain?"

    if _UX_BARE_CONTINUE_RE.fullmatch(text) and not has_prior:
        if chinese:
            return "想继续什么内容？"
        if norwegian:
            return "Hva vil du fortsette med?"
        return "What would you like to continue?"

    return None


def has_images(value) -> bool:
    """Return True when an Ollama request contains a non-empty images array."""
    if isinstance(value, dict):
        images = value.get("images")
        if isinstance(images, list) and len(images) > 0:
            return True
        return any(has_images(child) for child in value.values())
    if isinstance(value, list):
        return any(has_images(child) for child in value)
    return False


def _content_text(value) -> str:
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        parts: list[str] = []
        for item in value:
            if isinstance(item, str):
                parts.append(item)
            elif isinstance(item, dict):
                text = item.get("text") or item.get("content")
                if isinstance(text, str):
                    parts.append(text)
        return "\n".join(parts)
    return ""


def _chat_messages(payload: dict) -> list[dict]:
    messages = payload.get("messages")
    if not isinstance(messages, list):
        return []
    return [message for message in messages if isinstance(message, dict)]


def user_text(payload: dict) -> str:
    """Return the latest user turn."""
    prompt = payload.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        return prompt
    for message in reversed(_chat_messages(payload)):
        if message.get("role") != "user":
            continue
        text = _content_text(message.get("content"))
        if text.strip():
            return text
    return ""


def first_user_text(payload: dict) -> str:
    """Return the first substantive user turn, the sticky conversation anchor."""
    prompt = payload.get("prompt")
    if isinstance(prompt, str) and prompt.strip():
        return prompt
    for message in _chat_messages(payload):
        if message.get("role") != "user":
            continue
        text = _content_text(message.get("content"))
        if text.strip():
            return text
    return ""


def looks_like_translation(payload: dict) -> bool:
    return bool(_TRANSLATION_RE.search(user_text(payload)))


def _tail_after_source_delimiter(text: str) -> str:
    """Return likely inline source text after an instruction delimiter."""
    # Prefer full-width/ASCII colon because project translation prompts use this
    # form and it cleanly separates instruction from source.
    positions = [pos for pos in (text.find("："), text.find(":")) if pos >= 0]
    if positions:
        tail = text[min(positions) + 1 :].strip()
        if len(tail) >= 2:
            return tail
    if "\n" in text:
        tail = text.split("\n", 1)[1].strip()
        if len(tail) >= 2:
            return tail
    return ""


def self_contained_translation(payload: dict) -> bool:
    """True only when this turn contains both translation intent and source text.

    Context-dependent commands such as "翻译全诗", "把刚才那个翻成英文",
    "translate that", or "continue translating" deliberately return False so
    they can enter the contextual-translation tool pipeline.
    """
    text = user_text(payload).strip()
    if not text or not _TRANSLATION_RE.search(text):
        return False

    inline = _tail_after_source_delimiter(text)
    if inline:
        return True

    # Quoted material can be a self-contained source even without a colon.
    for match in _QUOTED_SOURCE_RE.finditer(text):
        quoted = match.group(1).strip()
        if len(quoted) >= 2 and not _TRANSLATION_RE.search(quoted):
            return True

    # Chinese "把 <source> 翻译成..." form. Exclude short contextual pronouns.
    match = re.search(
        r"把\s*(?P<src>.+?)\s*(?:翻译|翻成|译成|译为|转成|转换成)", text, re.IGNORECASE
    )
    if match:
        source = match.group("src").strip(" \t\r\n，,。.!！？?\"'“”‘’")
        if len(source) >= 2:
            # Short referential phrases such as “刚才那个” are context pointers,
            # not source material. Longer literal text may naturally contain words
            # like “这个”, so only apply this guard to short source candidates.
            if len(source) <= 24 and _CONTEXT_REFERENCE_RE.search(source):
                return False
            return True

    # Without explicit source material, a translation command may become a
    # contextual-translation tool call when earlier turns exist.
    return False


def contextual_translation(payload: dict) -> bool:
    """Return True for translation instructions whose source must come from history."""
    if not looks_like_translation(payload) or self_contained_translation(payload):
        return False
    messages = _chat_messages(payload)
    if not messages:
        return False
    user_turns = [m for m in messages if m.get("role") == "user" and _content_text(m.get("content")).strip()]
    return len(user_turns) >= 2



def full_context_translation_request(payload: dict) -> bool:
    """True when the current contextual translation asks for an entire work."""
    return bool(_FULL_CONTEXT_TRANSLATION_RE.search(user_text(payload)))


_ORDINAL_SENTENCE_RE = re.compile(
    r"第\s*(?P<num>[0-9一二三四五六七八九十两]+)\s*句", re.IGNORECASE
)
_EN_ORDINAL_SENTENCE_RE = re.compile(
    r"\b(?P<num>first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth|[0-9]+(?:st|nd|rd|th)?)\s+sentence\b",
    re.IGNORECASE,
)


def _small_ordinal_number(token: str) -> int | None:
    token = token.strip().lower()
    if token.isdigit():
        value = int(token)
        return value if 1 <= value <= 99 else None
    match = re.fullmatch(r"([0-9]+)(?:st|nd|rd|th)", token)
    if match:
        value = int(match.group(1))
        return value if 1 <= value <= 99 else None
    english = {
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5,
        "sixth": 6, "seventh": 7, "eighth": 8, "ninth": 9, "tenth": 10,
    }
    if token in english:
        return english[token]
    chinese_digit = {"一": 1, "二": 2, "两": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9}
    if token in chinese_digit:
        return chinese_digit[token]
    if token == "十":
        return 10
    if token.startswith("十") and token[1:] in chinese_digit:
        return 10 + chinese_digit[token[1:]]
    if token.endswith("十") and token[:-1] in chinese_digit:
        return chinese_digit[token[:-1]] * 10
    if "十" in token:
        left, right = token.split("十", 1)
        if left in chinese_digit and right in chinese_digit:
            return chinese_digit[left] * 10 + chinese_digit[right]
    return None


def _requested_sentence_ordinal(payload: dict) -> int | None:
    latest = user_text(payload)
    match = _ORDINAL_SENTENCE_RE.search(latest)
    if match:
        return _small_ordinal_number(match.group("num"))
    match = _EN_ORDINAL_SENTENCE_RE.search(latest)
    if match:
        return _small_ordinal_number(match.group("num"))
    return None


def _clean_labelled_sentence_source(text: str) -> str:
    text = text.strip(" \t\r\n，,：:")
    quote_pairs = (("“", "”"), ("‘", "’"), ('"', '"'), ("'", "'"), ("「", "」"), ("『", "』"))
    for left, right in quote_pairs:
        if text.startswith(left):
            end = text.find(right, len(left))
            if end > len(left):
                return text[len(left):end].strip()
    # For unquoted labelled material, take the first complete sentence/line and
    # discard any following instruction such as “先只回复…”.
    text = re.split(r"[。！？!?;；\n]", text, maxsplit=1)[0]
    return text.strip(" \t\r\n，,。.!！？?;；\"'“”‘’「」『』")


def _labelled_sentences(text: str) -> dict[int, str]:
    matches = list(_ORDINAL_SENTENCE_RE.finditer(text))
    if not matches:
        return {}
    out: dict[int, str] = {}
    for idx, match in enumerate(matches):
        number = _small_ordinal_number(match.group("num"))
        if number is None:
            continue
        start = match.end()
        # Optional Chinese copula/delimiter is part of the label, not the source.
        tail = text[start:]
        prefix = re.match(r"\s*(?:是|为|[:：])?\s*", tail)
        if prefix:
            start += prefix.end()
        end = matches[idx + 1].start() if idx + 1 < len(matches) else len(text)
        candidate = _clean_labelled_sentence_source(text[start:end])
        if len(candidate.strip()) >= 2:
            out[number] = candidate
    return out


def deterministic_context_source(payload: dict) -> str | None:
    """Resolve explicit numbered-sentence references from prior user text.

    This is intentionally narrow. A request such as “把第二句翻成英文” should
    not depend on a language model to rediscover text the user already supplied.
    Ambiguous references (“那个”, “刚才的”, etc.) still use the conversation
    anchor resolver, and whole-work requests still use the exact-text corpus.
    """
    ordinal = _requested_sentence_ordinal(payload)
    if ordinal is None:
        return None
    for message in reversed(_history_before_latest_user(payload)):
        if message.get("role") != "user":
            continue
        text = _content_text(message.get("content")).strip()
        if not text:
            continue
        source = _labelled_sentences(text).get(ordinal)
        if source and len(source) <= CONTEXT_SOURCE_MAX_CHARS:
            return source
    return None


def _history_before_latest_user(payload: dict) -> list[dict]:
    """Return chat history before the latest user turn."""
    messages = _chat_messages(payload)
    latest_index = None
    for idx in range(len(messages) - 1, -1, -1):
        if messages[idx].get("role") == "user" and _content_text(messages[idx].get("content")).strip():
            latest_index = idx
            break
    return messages[:latest_index] if latest_index is not None else messages


def context_referent_hint(payload: dict) -> str:
    """Return the most recent assistant identification that can name a referent.

    The text is used only as a hint for a clean source-retrieval call. It is not
    trusted as source material and is never translated directly.
    """
    for message in reversed(_history_before_latest_user(payload)):
        if message.get("role") != "assistant":
            continue
        text = _content_text(message.get("content")).strip()
        if text:
            return text[:1200]
    return ""


def context_source_snippets(payload: dict) -> list[str]:
    """Extract literal user-provided snippets useful for validating retrieved text.

    This intentionally ignores instruction-like clauses ("请告诉我...", "reply...")
    so a retrieved public-domain work can be checked against what the user really
    supplied without hard-coding any title, author, or benchmark answer.
    """
    snippets: list[str] = []
    for message in _history_before_latest_user(payload):
        if message.get("role") != "user":
            continue
        text = _content_text(message.get("content")).strip()
        if not text:
            continue
        # Keep commas inside a sentence/verse pair but split at sentence/paragraph
        # boundaries. This preserves e.g. two Chinese poetic lines joined by '，'.
        for clause in re.split(r"[。！？!?；;\n]+", text):
            clause = clause.strip(" \t\r\n，,：:\"'“”‘’「」『』()（）[]【】")
            if len(clause) < 4 or _SOURCE_INSTRUCTION_RE.search(clause):
                continue
            # Avoid treating tiny acknowledgements or pure labels as source text.
            normalized = re.sub(r"[^0-9A-Za-z\u3400-\u4dbf\u4e00-\u9fff]+", "", clause)
            if len(normalized) >= 4:
                snippets.append(clause)
    # Prefer recent material and cap prompt size.
    return snippets[-4:]


_SOURCE_RETRIEVER_SYSTEM = """LOCAL_POLYGLOT_PUBLIC_DOMAIN_SOURCE_RETRIEVER
You retrieve exact original source text for a context-dependent translation tool.

Return ONLY the exact original source text, with no title, author, commentary, markdown, or translation.
If you are not confident that you know the complete exact original text, return exactly NEED_SOURCE.

Rules:
- The referent hint may identify the work but is not itself trusted source text.
- Known user-provided snippets are authoritative and the complete text must contain them verbatim apart from punctuation/spacing.
- Retrieve a complete short public-domain work only when the identity is unambiguous and the exact text is known.
- Never invent or paraphrase missing lines.
"""


def build_full_source_retrieval_payload(payload: dict, model: str) -> dict:
    hint = context_referent_hint(payload)
    snippets = context_source_snippets(payload)
    known = "\n".join(f"- {item}" for item in snippets) if snippets else "- (none)"
    latest = user_text(payload).strip()
    prompt = (
        "Latest request:\n" + latest +
        "\n\nReferent hint from the prior assistant turn:\n" + (hint or "(none)") +
        "\n\nKnown literal snippets supplied by the user:\n" + known +
        "\n\nReturn the complete exact original source text only, or NEED_SOURCE."
    )
    return {
        "model": model,
        "messages": [
            {"role": "system", "content": _SOURCE_RETRIEVER_SYSTEM},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "think": False,
        "options": {"temperature": 0, "num_predict": CONTEXT_RESOLVE_NUM_PREDICT},
    }


def _normalized_source_text(text: str) -> str:
    return re.sub(r"[^0-9A-Za-z\u3400-\u4dbf\u4e00-\u9fff]+", "", text).lower()


# Public-domain Chinese texts often have harmless orthographic variants across
# editions. Keep this deliberately small and use it only for corpus/source
# validation, never for generating or rewriting user-visible text.
_TEXT_VARIANT_MAP = str.maketrans({
    "惟": "唯",
    "閒": "闲",
    "裏": "里",
    "裡": "里",
    "臺": "台",
    "於": "于",
})


def _comparison_source_text(text: str) -> str:
    return _normalized_source_text(text).translate(_TEXT_VARIANT_MAP)


def _best_snippet_similarity(snippet: str, source: str) -> float:
    """Return conservative best-substring similarity for corpus validation.

    Exact and known orthographic-variant matches score 1.0. For other minor
    edition differences, compare the short user snippet against similarly sized
    windows of the candidate source. This is intentionally used only after a
    candidate set has been narrowed by title/author or literal anchors.
    """
    needle = _comparison_source_text(snippet)
    haystack = _comparison_source_text(source)
    if not needle or not haystack:
        return 0.0
    if needle in haystack:
        return 1.0
    if len(needle) < 8:
        return 0.0
    if len(haystack) <= len(needle) + 2:
        return difflib.SequenceMatcher(None, needle, haystack, autojunk=False).ratio()

    # Chinese poems are short, so a tiny local sliding comparison is cheap and
    # much safer than fuzzy-searching all 369k corpus rows. Allow +/-1 character
    # to tolerate an edition that inserts or omits a particle.
    best = 0.0
    for width in (len(needle) - 1, len(needle), len(needle) + 1):
        if width < 4 or width > len(haystack):
            continue
        for start in range(0, len(haystack) - width + 1):
            ratio = difflib.SequenceMatcher(
                None, needle, haystack[start:start + width], autojunk=False
            ).ratio()
            if ratio > best:
                best = ratio
            if best >= 0.97:
                return best
    return best


def _source_matches_snippet(source: str, snippet: str) -> bool:
    normalized = _comparison_source_text(snippet)
    if len(normalized) < 4:
        return False
    if normalized in _comparison_source_text(source):
        return True
    # Only tolerate fuzzy differences for reasonably informative snippets.
    return len(normalized) >= 8 and _best_snippet_similarity(snippet, source) >= 0.88


def _corpus_search_anchors(snippet: str) -> list[str]:
    """Return a few literal anchors for recovering candidates without title.

    The SQL database stores exact normalized text. Searching several short
    windows means a one-character edition variant cannot make the entire user
    excerpt undiscoverable. Final acceptance still uses conservative similarity.
    """
    normalized = _normalized_source_text(snippet)
    if len(normalized) < 6:
        return [normalized] if normalized else []
    width = 6 if len(normalized) < 24 else 8
    positions = {0, max(0, (len(normalized) - width) // 2), max(0, len(normalized) - width)}
    # One extra quarter-position helps when the variant happens to land in the
    # middle/end windows. Keep the query count bounded.
    positions.add(max(0, (len(normalized) - width) // 4))
    return [normalized[pos:pos + width] for pos in sorted(positions) if normalized[pos:pos + width]]


def source_satisfies_full_request(source: str, payload: dict) -> bool:
    """Heuristic completeness check for a resolver result on whole-work requests.

    A short source that merely repeats the literal excerpt already in history is
    not enough for "translate the whole poem/text". Long user-supplied bodies
    are allowed through because they may already be the complete source.
    """
    if not full_context_translation_request(payload):
        return True
    normalized_source = _normalized_source_text(source)
    if not normalized_source:
        return False
    snippets = context_source_snippets(payload)
    normalized_snippets = [
        _normalized_source_text(item) for item in snippets if len(_normalized_source_text(item)) >= 4
    ]
    matching = [
        item for item, raw in zip(normalized_snippets, snippets)
        if _source_matches_snippet(source, raw)
    ]
    if not matching:
        # The resolver may have reconstructed a work from an unquoted referent;
        # let the clean retrieval validator decide later rather than assuming it
        # is complete here.
        return len(normalized_source) >= 120
    longest = max(len(item) for item in matching)
    if len(normalized_source) > longest + 4:
        return True
    # A substantial body already pasted by the user can itself be the full text.
    return len(normalized_source) >= 120


def parse_full_source_retrieval(response_payload: dict, payload: dict) -> str | None:
    """Validate a clean full-work retrieval against literal prior-user snippets."""
    message = response_payload.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        content = response_payload.get("response")
    if not isinstance(content, str):
        return None
    source = content.strip()
    if not source or source.upper() == "NEED_SOURCE":
        return None
    if len(source) > CONTEXT_SOURCE_MAX_CHARS:
        return None

    normalized_source = _normalized_source_text(source)
    if len(normalized_source) < 8:
        return None
    snippets = context_source_snippets(payload)
    normalized_snippets = [
        _normalized_source_text(item) for item in snippets if len(_normalized_source_text(item)) >= 4
    ]
    if normalized_snippets:
        matching = [
            item for item, raw in zip(normalized_snippets, snippets)
            if _source_matches_snippet(source, raw)
        ]
        if not matching:
            return None
        # A request for the whole work must produce materially more source than
        # the longest literal excerpt already present in the conversation.
        if len(normalized_source) <= max(len(item) for item in matching) + 4:
            return None

    # Reject obvious explanatory wrappers despite the source-only instruction.
    first_line = source.splitlines()[0].strip() if source.splitlines() else source
    if re.search(r"^(?:作者|篇名|标题|原文|全文|以下|这首|這首|here(?:'s| is)|the (?:poem|text))\b", first_line, re.IGNORECASE):
        return None
    return source


def corpus_ready() -> bool:
    try:
        if not os.path.isfile(LITERATURE_CORPUS_DB):
            return False
        con = sqlite3.connect(f"file:{LITERATURE_CORPUS_DB}?mode=ro", uri=True, timeout=2)
        try:
            row = con.execute("SELECT COUNT(*) FROM works").fetchone()
            return bool(row and int(row[0]) > 0)
        finally:
            con.close()
    except Exception:
        return False


def _corpus_candidate_score(
    row: tuple, hint_norm: str, snippets: list[str]
) -> tuple[int, int, int, int]:
    _uid, title, author, _dynasty, content, title_norm, author_norm, _content_norm = row
    snippet_scores = [int(round(_best_snippet_similarity(snippet, content) * 100)) for snippet in snippets]
    best_snippet = max(snippet_scores, default=0)
    exactish_hits = sum(1 for score in snippet_scores if score >= 88)
    hint_hits = int(bool(title_norm and title_norm in hint_norm)) * 4 + int(bool(author_norm and author_norm in hint_norm)) * 2
    # Snippet evidence dominates; title/author break ties and protect against a
    # common short line shared by unrelated works.
    return (exactish_hits * 1000 + best_snippet * 10 + hint_hits, hint_hits, len(title_norm), len(content))


def corpus_lookup_full_work(payload: dict) -> dict | None:
    """Retrieve a complete public-domain work plus trusted corpus metadata.

    The lookup never trusts a model-generated title alone: candidates are scored
    against literal snippets supplied by the user whenever such snippets exist.
    Returning the corpus title/author alongside the exact source gives the
    translation tool authoritative identity metadata for proper-noun fidelity.
    """
    if not full_context_translation_request(payload) or not corpus_ready():
        return None
    hint_norm = _normalized_source_text(context_referent_hint(payload))
    snippets = [
        item for item in context_source_snippets(payload)
        if len(_normalized_source_text(item)) >= 4
    ]
    snippet_norms = [_normalized_source_text(item) for item in snippets]
    longest_snippet_raw = max(snippets, key=lambda item: len(_normalized_source_text(item)), default="")
    longest_snippet = _normalized_source_text(longest_snippet_raw)
    con = None
    try:
        con = sqlite3.connect(f"file:{LITERATURE_CORPUS_DB}?mode=ro", uri=True, timeout=5)
        rows: list[tuple] = []
        if hint_norm:
            rows.extend(
                con.execute(
                    """SELECT id,title,author,dynasty,content,title_norm,author_norm,content_norm
                       FROM works
                       WHERE length(title_norm) >= 2 AND instr(?, title_norm) > 0
                       ORDER BY length(title_norm) DESC LIMIT 80""",
                    (hint_norm,),
                ).fetchall()
            )
        # Literal user text is stronger evidence than the assistant's prior
        # identification. Avoid a full-corpus content scan when the title hint
        # already produced a candidate that contains the user's exact snippet;
        # otherwise use the longest snippet to recover from a wrong/missing title.
        title_rows_validate = bool(
            longest_snippet_raw and any(_source_matches_snippet(row[4], longest_snippet_raw) for row in rows)
        )
        if longest_snippet_raw and not title_rows_validate:
            # An exact full-snippet search is too brittle for common edition
            # variants (e.g. 唯/惟). Search a few literal anchors to recover a
            # small candidate set, then use conservative similarity below.
            for anchor in _corpus_search_anchors(longest_snippet_raw):
                rows.extend(
                    con.execute(
                        """SELECT id,title,author,dynasty,content,title_norm,author_norm,content_norm
                           FROM works WHERE instr(content_norm, ?) > 0 LIMIT 40""",
                        (anchor,),
                    ).fetchall()
                )
        if not rows:
            return None
        unique = {}
        for row in rows:
            unique[row[0]] = row
        ranked = sorted(
            unique.values(),
            key=lambda row: _corpus_candidate_score(row, hint_norm, snippets),
            reverse=True,
        )
        best = ranked[0]
        best_score = _corpus_candidate_score(best, hint_norm, snippets)
        if best_score[0] <= 0:
            return None
        # When the user supplied literal text, require a conservative exact,
        # orthographic-variant, or near-exact match. This prevents a wrong
        # assistant title from selecting an unrelated work while tolerating
        # edition variants such as 唯/惟.
        if snippets and not any(_source_matches_snippet(best[4], snippet) for snippet in snippets):
            return None
        source = str(best[4]).strip()
        if len(source) > CONTEXT_SOURCE_MAX_CHARS:
            return None
        if not source_satisfies_full_request(source, payload):
            return None
        return {
            "id": str(best[0]),
            "title": str(best[1]).strip(),
            "author": str(best[2]).strip(),
            "dynasty": str(best[3]).strip(),
            "source": source,
        }
    except Exception as exc:  # noqa: BLE001
        sys.stderr.write(f"model-router: local literature corpus lookup failed: {exc}\n")
        return None
    finally:
        if con is not None:
            con.close()


def corpus_lookup_full_source(payload: dict) -> str | None:
    """Compatibility wrapper returning only the exact corpus source text."""
    work = corpus_lookup_full_work(payload)
    if not work:
        return None
    source = work.get("source")
    return source if isinstance(source, str) else None


def full_source_retrieval_models(payload: dict) -> list[str]:
    """Try the sticky anchor first, then the other local text model as fallback."""
    anchor = conversation_anchor_model(payload)
    models = [anchor]
    alternate = TRANSLATION_MODEL if anchor != TRANSLATION_MODEL else KNOWLEDGE_MODEL
    if alternate not in models:
        models.append(alternate)
    return models


_CONTEXT_RESOLVER_SYSTEM = """LOCAL_POLYGLOT_CONTEXT_RESOLVER
You are a source-resolution helper inside a local assistant. The latest user turn asks to translate something referenced by the earlier conversation. Resolve the exact source material that should be translated.

Return JSON only in one of these forms:
{"status":"ok","source":"exact complete original source text"}
{"status":"need_source","source":""}

Rules:
- Do not translate.
- Use the full conversation to resolve references such as the whole poem, the previous paragraph, the second sentence, that text, or continue.
- If the user asks for the whole/full/entire short public-domain work and only an excerpt is present, you may supply the authentic complete original text only when you are confident it is exact. Otherwise return need_source.
- Never invent missing copyrighted or uncertain source text.
- If a numbered sentence or quoted fragment is already present in the user history, copy that exact text.
- Ignore formatting-only assistant chatter; use assistant content only to help identify the referent.
"""

_CONTEXT_TRANSLATION_TOOL_SYSTEM = """You are the translation tool for a multilingual local assistant. Translate the resolved source text according to the user's latest instruction. The resolved source below is authoritative for this tool call. Follow the requested output language and output-only constraints. Do not ask the user to repeat context that has already been resolved for you."""

_LITERARY_TRANSLATION_TOOL_SYSTEM = """LOCAL_POLYGLOT_LITERARY_DRAFT
You are the faithful literary-translation tool for a multilingual local assistant. Translate the verified complete source text according to the user's latest instruction.

Fidelity rules:
- The resolved source text is authoritative. Translate every semantic unit in source order; do not add, omit, substitute, or rewrite facts, images, directions, colors, places, people, buildings, rivers, or other named entities.
- Preserve line/paragraph order for verse and other structured text. Do not silently replace a source image with a more familiar one.
- Translate from the supplied source, not from a memorized published translation or from recollection of the work. Prefer literal semantic accuracy over poetic elegance.
- For proper nouns, use a well-established target-language name only when confident. Otherwise use a faithful romanization/transliteration rather than inventing a literal name from the characters. Never replace one named entity with another.
- Source identity metadata, when supplied, is authoritative identity context for disambiguating names; it is not extra text to translate.
- If the instruction asks for the whole/full source, translate the entire resolved source.
- Follow requested output-language and output-only constraints. Do not add commentary unless requested.
- Check that each source line/clause has a corresponding faithful target-language rendering and that named entities still refer to the same entities.
- Do not ask the user to repeat context that has already been resolved for you."""


def build_context_resolution_payload(payload: dict) -> dict:
    messages = _chat_messages(payload)
    return {
        "model": conversation_anchor_model(payload),
        "messages": [{"role": "system", "content": _CONTEXT_RESOLVER_SYSTEM}, *messages],
        "stream": False,
        "think": False,
        "format": "json",
        "options": {"temperature": 0, "num_predict": CONTEXT_RESOLVE_NUM_PREDICT},
    }


def parse_context_resolution(response_payload: dict) -> str | None:
    message = response_payload.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        content = response_payload.get("response")
    if not isinstance(content, str):
        return None
    text = content.strip()
    if not text:
        return None
    try:
        decoded = json.loads(text)
    except json.JSONDecodeError:
        if text == "NEED_SOURCE":
            return None
        return None
    if not isinstance(decoded, dict) or decoded.get("status") != "ok":
        return None
    source = decoded.get("source")
    if not isinstance(source, str):
        return None
    source = source.strip()
    if len(source) < 2 or len(source) > CONTEXT_SOURCE_MAX_CHARS:
        return None
    return source


def _chat_response_content(response_payload: dict | None) -> str | None:
    if not isinstance(response_payload, dict):
        return None
    message = response_payload.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, str):
        content = response_payload.get("response")
    if not isinstance(content, str):
        return None
    content = content.strip()
    return content or None


def build_context_translation_payload(payload: dict, source: str, source_meta: dict | None = None) -> dict:
    latest = user_text(payload).strip()
    out = {
        k: v
        for k, v in payload.items()
        if k not in {"messages", "prompt", "model", "name", "format", *_CLIENT_TOOL_FIELDS}
    }
    out["model"] = TRANSLATION_MODEL

    # Keep ordinary contextual translation deliberately small. The previous
    # compact tool prompt is already proven reliable for short references such
    # as “the second sentence”. Literary whole-work translation needs stronger
    # identity/fidelity constraints, but applying that large prompt to every
    # contextual translation made the smallest smoke path less reliable.
    literary_mode = full_context_translation_request(payload) or isinstance(source_meta, dict)
    if literary_mode:
        metadata_lines: list[str] = []
        if isinstance(source_meta, dict):
            for key, label in (("title", "Title"), ("author", "Author"), ("dynasty", "Era/Dynasty")):
                value = source_meta.get(key)
                if isinstance(value, str) and value.strip():
                    metadata_lines.append(f"{label}: {value.strip()}")
        metadata = "\n".join(metadata_lines) if metadata_lines else "(not available)"
        user_content = (
            "Latest translation instruction:\n" + latest +
            "\n\nAuthoritative source identity metadata:\n" + metadata +
            "\n\nResolved source text:\n---SOURCE---\n" + source +
            "\n---END SOURCE---"
        )
        system_content = _LITERARY_TRANSLATION_TOOL_SYSTEM
    else:
        user_content = (
            "Latest translation instruction:\n" + latest +
            "\n\nResolved source text:\n---SOURCE---\n" + source +
            "\n---END SOURCE---"
        )
        system_content = _CONTEXT_TRANSLATION_TOOL_SYSTEM

    out["messages"] = [
        {"role": "system", "content": system_content},
        {"role": "user", "content": user_content},
    ]
    if "stream" not in out:
        out["stream"] = False
    if "think" not in out:
        out["think"] = TEXT_THINKING_DEFAULT

    # Whole literary works need deterministic fidelity. Ordinary contextual
    # translation preserves the caller's sampling settings, matching the
    # previously stable path used by smoke and interactive chat.
    if literary_mode:
        options = dict(out.get("options") or {})
        options["temperature"] = 0
        out["options"] = options
    return out


def conversation_anchor_model(payload: dict) -> str:
    first = first_user_text(payload)
    if _CJK_RE.search(first):
        return KNOWLEDGE_MODEL
    return TRANSLATION_MODEL


def route_kind(payload: dict) -> str:
    if has_images(payload):
        return "vision"
    if self_contained_translation(payload):
        return "translation-tool"
    if contextual_translation(payload):
        return "translation-context-tool"
    return "conversation-cn" if conversation_anchor_model(payload) == KNOWLEDGE_MODEL else "conversation-multi"


def routed_model(payload: dict) -> str:
    kind = route_kind(payload)
    if kind == "vision":
        return VISION_MODEL
    if kind in {"translation-tool", "translation-context-tool"}:
        return TRANSLATION_MODEL
    return conversation_anchor_model(payload)


def decode_payload(raw: bytes) -> dict | None:
    if not raw:
        return None
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return None
    return payload if isinstance(payload, dict) else None


def requested_model(raw: bytes) -> str | None:
    payload = decode_payload(raw)
    if payload is None:
        return None
    model = payload.get("model", payload.get("name"))
    return model if isinstance(model, str) else None


_CLIENT_TOOL_FIELDS = (
    "tools",
    "tool_choice",
    "parallel_tool_calls",
    "functions",
    "function_call",
)


def strip_client_tooling(payload: dict) -> dict:
    """Remove external/client tool schemas from the curated public assistant.

    Open WebUI 0.10+ enables Native built-in tools by default. Small local models
    can spuriously call tools such as create_tasks for ordinary chat. This
    deployment implements its own deterministic routing/tool handoffs, so no
    client-supplied function/tool schema is allowed through to Ollama.
    """
    for key in _CLIENT_TOOL_FIELDS:
        payload.pop(key, None)
    return payload


def rewrite_model_payload(raw: bytes, *, route_by_intent: bool = False, force_text: bool = False) -> bytes:
    payload = decode_payload(raw)
    if payload is None:
        return raw
    model_key = "model" if "model" in payload else "name" if "name" in payload else None
    if model_key is None or payload.get(model_key) != PUBLIC_MODEL:
        return raw

    # Defense in depth: even if the UI/model metadata accidentally re-enables
    # Native built-in tools, the curated router never forwards their schemas.
    strip_client_tooling(payload)

    if route_by_intent:
        target = routed_model(payload)
        payload[model_key] = target
        # Critical invariant: normal chat history is forwarded byte-for-byte at
        # the message level. No challenge replay, facts-only flattening, or
        # assistant-history deletion happens here.
        if target == TRANSLATION_MODEL:
            if "think" not in payload:
                payload["think"] = TEXT_THINKING_DEFAULT
        else:
            payload.pop("think", None)
    elif force_text:
        # Metadata can use the multilingual model as the public representative.
        payload[model_key] = TRANSLATION_MODEL

    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _advertise_public_capabilities(item: dict) -> dict:
    out = dict(item)
    capabilities = out.get("capabilities")
    caps = list(capabilities) if isinstance(capabilities, list) else []
    for capability in ("completion", "vision"):
        if capability not in caps:
            caps.append(capability)
    out["capabilities"] = caps
    return out


def filter_tags(raw: bytes) -> bytes:
    """Expose one public model using multilingual metadata plus vision capability."""
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    models = payload.get("models") if isinstance(payload, dict) else None
    if not isinstance(models, list):
        return raw
    selected = []
    for model in models:
        if not isinstance(model, dict):
            continue
        name = model.get("name") or model.get("model")
        if name == TRANSLATION_MODEL:
            item = _advertise_public_capabilities(model)
            item["name"] = PUBLIC_MODEL
            item["model"] = PUBLIC_MODEL
            selected.append(item)
            break
    return json.dumps({"models": selected}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def filter_show(raw: bytes) -> bytes:
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    if not isinstance(payload, dict):
        return raw
    payload = _advertise_public_capabilities(payload)
    return json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def filter_ps(raw: bytes) -> bytes:
    """Hide which internal anchor/specialist is currently loaded."""
    try:
        payload = json.loads(raw)
    except json.JSONDecodeError:
        return raw
    models = payload.get("models") if isinstance(payload, dict) else None
    if not isinstance(models, list):
        return raw
    visible = []
    internal = {TRANSLATION_MODEL, KNOWLEDGE_MODEL, VISION_MODEL}
    for model in models:
        if not isinstance(model, dict):
            continue
        name = model.get("name") or model.get("model")
        if name not in internal:
            continue
        item = dict(model)
        item["name"] = PUBLIC_MODEL
        item["model"] = PUBLIC_MODEL
        visible.append(item)
        break
    return json.dumps({"models": visible}, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


class RouterHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "LocalPolyglotRouter/2.0"

    def log_message(self, fmt: str, *args) -> None:
        sys.stderr.write("model-router: " + (fmt % args) + "\n")

    def _upstream(self, method: str, path: str, body: bytes = b""):
        conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=TIMEOUT)
        headers = {}
        for key, value in self.headers.items():
            if key.lower() in {"host", "content-length", "connection", "accept-encoding"}:
                continue
            headers[key] = value
        if body:
            headers["Content-Length"] = str(len(body))
        headers["Host"] = f"{UPSTREAM.hostname}:{UPSTREAM.port or 80}"
        headers["Connection"] = "close"
        conn.request(method, path, body=body if body else None, headers=headers)
        return conn, conn.getresponse()

    def _send_bytes(self, status: int, headers, body: bytes) -> None:
        self.send_response(status)
        for key, value in headers:
            if key.lower() in {"content-length", "transfer-encoding", "connection", "content-encoding"}:
                continue
            self.send_header(key, value)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if body:
            self.wfile.write(body)
        self.close_connection = True

    def _send_local_assistant_response(self, path: str, payload: dict, content: str) -> None:
        """Return a deterministic assistant response without calling Ollama."""
        if path.startswith("/api/chat"):
            response = {
                "model": PUBLIC_MODEL,
                "created_at": "",
                "message": {"role": "assistant", "content": content},
                "done": True,
                "done_reason": "stop",
            }
        else:
            response = {
                "model": PUBLIC_MODEL,
                "created_at": "",
                "response": content,
                "done": True,
                "done_reason": "stop",
            }
        data = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        if payload.get("stream") is True:
            data += b"\n"
            content_type = "application/x-ndjson"
        else:
            content_type = "application/json"
        self._send_bytes(200, [("Content-Type", content_type)], data)

    def _proxy_buffered(self, method: str, path: str, body: bytes = b"", transform=None) -> None:
        conn = None
        try:
            conn, resp = self._upstream(method, path, body)
            data = resp.read()
            if transform is not None and 200 <= resp.status < 300:
                data = transform(data)
            self._send_bytes(resp.status, resp.getheaders(), data)
        except Exception as exc:  # noqa: BLE001
            payload = json.dumps({"error": f"model router upstream failure: {exc}"}).encode()
            self._send_bytes(502, [("Content-Type", "application/json")], payload)
        finally:
            if conn is not None:
                conn.close()

    def _proxy_stream(self, method: str, path: str, body: bytes) -> None:
        conn = None
        headers_sent = False
        try:
            conn, resp = self._upstream(method, path, body)
            self.send_response(resp.status)
            for key, value in resp.getheaders():
                if key.lower() in {"content-length", "transfer-encoding", "connection", "content-encoding"}:
                    continue
                self.send_header(key, value)
            self.send_header("Connection", "close")
            self.end_headers()
            headers_sent = True
            while True:
                chunk = resp.readline()
                if not chunk:
                    break
                self.wfile.write(chunk)
                self.wfile.flush()
            self.close_connection = True
        except Exception as exc:  # noqa: BLE001
            payload = json.dumps({"error": f"model router upstream failure: {exc}"}).encode()
            if not headers_sent:
                self._send_bytes(502, [("Content-Type", "application/json")], payload)
            else:
                try:
                    self.wfile.write(payload)
                    self.wfile.flush()
                except OSError:
                    pass
                self.close_connection = True
        finally:
            if conn is not None:
                conn.close()

    def do_GET(self) -> None:  # noqa: N802
        if self.path == "/health":
            self._proxy_buffered(
                "GET",
                "/api/version",
                transform=lambda _raw: b'{"status":"ok","external_tools":"disabled"}',
            )
            return
        if self.path.startswith("/api/tags"):
            self._proxy_buffered("GET", self.path, transform=filter_tags)
            return
        if self.path.startswith("/api/ps"):
            self._proxy_buffered("GET", self.path, transform=filter_ps)
            return
        if self.path == "/" or self.path.startswith("/api/version"):
            self._proxy_buffered("GET", self.path)
            return
        payload = json.dumps({"error": "unsupported curated router endpoint"}).encode()
        self._send_bytes(404, [("Content-Type", "application/json")], payload)

    def do_HEAD(self) -> None:  # noqa: N802
        if self.path == "/":
            self._send_bytes(200, [("Content-Type", "text/plain")], b"")
            return
        self._proxy_buffered("HEAD", self.path)

    def _reject_model(self, body: bytes) -> bool:
        model = requested_model(body)
        if model == PUBLIC_MODEL:
            return False
        payload = json.dumps(
            {"error": f"model not available on curated endpoint: {model or '<missing>'}"}
        ).encode()
        self._send_bytes(404, [("Content-Type", "application/json")], payload)
        return True

    def _internal_chat_json(self, payload: dict) -> dict | None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        conn = None
        try:
            conn = http.client.HTTPConnection(UPSTREAM.hostname, UPSTREAM.port or 80, timeout=TIMEOUT)
            conn.request(
                "POST",
                "/api/chat",
                body=body,
                headers={
                    "Content-Type": "application/json",
                    "Content-Length": str(len(body)),
                    "Host": f"{UPSTREAM.hostname}:{UPSTREAM.port or 80}",
                    "Connection": "close",
                },
            )
            resp = conn.getresponse()
            raw = resp.read()
            if not (200 <= resp.status < 300):
                self.log_message("context resolver upstream status=%s body=%r", resp.status, raw[:200])
                return None
            decoded = json.loads(raw)
            return decoded if isinstance(decoded, dict) else None
        except Exception as exc:  # noqa: BLE001
            self.log_message("context resolver failed: %s", exc)
            return None
        finally:
            if conn is not None:
                conn.close()

    def _proxy_contextual_translation(self, payload: dict) -> bool:
        source_meta: dict | None = None
        source = deterministic_context_source(payload)
        if source is not None:
            self.log_message("contextual translation source resolved deterministically from prior user text")

        # For whole-work requests, prefer the exact local corpus before asking a
        # model to recreate or resolve the missing text. Besides exact source, the
        # corpus provides title/author metadata that helps the translator preserve
        # proper nouns and work identity.
        if source is None and full_context_translation_request(payload):
            corpus_work = corpus_lookup_full_work(payload)
            if corpus_work is not None:
                source = corpus_work.get("source")
                source_meta = corpus_work
                self.log_message(
                    "contextual full-source retrieval via local literature corpus: %s / %s",
                    corpus_work.get("author", ""),
                    corpus_work.get("title", ""),
                )

        if source is None:
            resolver_payload = build_context_resolution_payload(payload)
            self.log_message(
                "contextual translation resolve via %s -> %s",
                resolver_payload["model"],
                TRANSLATION_MODEL,
            )
            resolved_response = self._internal_chat_json(resolver_payload)
            source = parse_context_resolution(resolved_response or {})
            if source is not None and not source_satisfies_full_request(source, payload):
                self.log_message("context resolver returned only a partial whole-work source; retrieving clean full source")
                source = None

        # Keep the prior model-based retriever only as a last-resort fallback for
        # works that are absent from the local corpus. Its output must still pass
        # the strict snippet/completeness validator.
        if source is None and full_context_translation_request(payload):
            for model in full_source_retrieval_models(payload):
                retrieval_payload = build_full_source_retrieval_payload(payload, model)
                self.log_message("contextual full-source fallback retrieval via %s", model)
                retrieval_response = self._internal_chat_json(retrieval_payload)
                source = parse_full_source_retrieval(retrieval_response or {}, payload)
                if source is not None:
                    break

        if source is None:
            self.log_message("contextual translation source unresolved; refusing to invent missing source")
            return False

        # Contextual literary translation is deliberately a single grounded tool
        # call. The local corpus supplies the complete source and identity metadata;
        # the translator is instructed to prefer source fidelity at temperature 0.
        # Do not add hidden rewrite loops here: they add latency and can amplify a
        # memorized textual variant without improving conversation continuity.
        translated_payload = build_context_translation_payload(payload, source, source_meta)
        body = json.dumps(translated_payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self._proxy_stream("POST", "/api/chat", body)
        return True

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        if self.path.startswith("/api/generate") or self.path.startswith("/api/chat"):
            if self._reject_model(body):
                return
            payload = decode_payload(body) or {}
            guard_message = ux_guard_response(payload)
            if guard_message is not None:
                self.log_message("UX guard handled underspecified command locally")
                self._send_local_assistant_response(self.path, payload, guard_message)
                return
            kind = route_kind(payload)
            target = routed_model(payload)
            self.log_message("route %s (%s) -> %s", PUBLIC_MODEL, kind, target)
            if self.path.startswith("/api/chat") and kind == "translation-context-tool":
                if self._proxy_contextual_translation(payload):
                    return
                # Do not silently drop back into ordinary chat: that recreates
                # the exact user-visible failure where "translate the whole poem"
                # becomes a partial translation or a request to repeat context.
                if conversation_anchor_model(payload) == KNOWLEDGE_MODEL:
                    message = (
                        "我能判断你指的是哪段内容，但当前无法可靠取得完整且经过校验的原文。"
                        "请提供完整原文后再翻译，以免我补写或编造缺失内容。"
                    )
                else:
                    message = (
                        "I can resolve what you are referring to, but I do not have a "
                        "verified complete source text to translate. Please provide the "
                        "complete source text so I do not invent missing material."
                    )
                response = {
                    "model": PUBLIC_MODEL,
                    "created_at": "",
                    "message": {"role": "assistant", "content": message},
                    "done": True,
                    "done_reason": "stop",
                }
                data = json.dumps(response, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
                self._send_bytes(200, [("Content-Type", "application/json")], data)
                return
            body = rewrite_model_payload(body, route_by_intent=True)
            self._proxy_stream("POST", self.path, body)
            return
        if self.path.startswith("/api/show"):
            if self._reject_model(body):
                return
            body = rewrite_model_payload(body, force_text=True)
            self._proxy_buffered("POST", self.path, body, transform=filter_show)
            return
        if any(
            self.path.startswith(p)
            for p in (
                "/api/pull",
                "/api/push",
                "/api/create",
                "/api/copy",
                "/api/delete",
                "/api/embed",
                "/api/embeddings",
            )
        ):
            payload = json.dumps({"error": "endpoint disabled on the curated model router"}).encode()
            self._send_bytes(403, [("Content-Type", "application/json")], payload)
            return
        payload = json.dumps({"error": "unsupported curated router endpoint"}).encode()
        self._send_bytes(404, [("Content-Type", "application/json")], payload)


if __name__ == "__main__":
    server = ThreadingHTTPServer((LISTEN_HOST, LISTEN_PORT), RouterHandler)
    print(
        f"model-router listening on {LISTEN_HOST}:{LISTEN_PORT}; "
        f"public={PUBLIC_MODEL} multilingual_anchor={TRANSLATION_MODEL} "
        f"chinese_anchor={KNOWLEDGE_MODEL} vision={VISION_MODEL} "
        f"policy=sticky-first-user-language translation_tools=self-contained+context-resolved "
        f"text_thinking_default={TEXT_THINKING_DEFAULT} upstream={UPSTREAM.geturl()}",
        flush=True,
    )
    server.serve_forever()
