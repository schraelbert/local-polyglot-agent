#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
# shellcheck disable=SC1091
source scripts/common.sh

require_docker_daemon || exit 1

AGENT_MODEL="$(env_get AGENT_MODEL polyglot-agent:latest)"
DOCLING_API_KEY="$(env_get DOCLING_API_KEY)"
MODEL_TIMEOUT="$(env_get SMOKE_MODEL_TIMEOUT 300)"
DOCLING_TIMEOUT="$(env_get SMOKE_DOCLING_TIMEOUT 600)"
MIN_SCORE="${BENCH_MIN_SCORE:-95}"
KNOWLEDGE_NUM_PREDICT="${BENCH_KNOWLEDGE_NUM_PREDICT:-512}"
KNOWLEDGE_CHAT_MODEL="$(effective_env_get KNOWLEDGE_CHAT_MODEL qwen2.5:7b)"
VISION_FIXTURE="tests/fixtures/vision-42.png"

if [[ ! "$MIN_SCORE" =~ ^[0-9]+$ ]] || (( MIN_SCORE < 95 || MIN_SCORE > 100 )); then
  printf 'BENCH_MIN_SCORE must be an integer from 95 to 100 for the production quality gate (got: %s).\n' "$MIN_SCORE" >&2
  exit 2
fi

if [[ ! "$KNOWLEDGE_NUM_PREDICT" =~ ^[0-9]+$ ]] || (( KNOWLEDGE_NUM_PREDICT < 64 || KNOWLEDGE_NUM_PREDICT > 1024 )); then
  printf 'BENCH_KNOWLEDGE_NUM_PREDICT must be an integer from 64 to 1024 for component-knowledge direct mode (got: %s).\n' "$KNOWLEDGE_NUM_PREDICT" >&2
  exit 2
fi

mkdir -p benchmark-results
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
report="benchmark-results/${stamp}.txt"

pass=0
total=0
infra_fail=0
critical_pass=0
critical_total=0
translation_pass=0
translation_total=0
translation_critical_pass=0
translation_critical_total=0
ocr_pass=0
ocr_total=0
vision_pass=0
vision_total=0
knowledge_pass=0
knowledge_total=0
knowledge_critical_pass=0
knowledge_critical_total=0
e2e_pass=0
e2e_total=0
e2e_critical_pass=0
e2e_critical_total=0

log() { printf '%s\n' "$*" | tee -a "$report"; }

dcurl() {
  dc -f compose.yaml -f compose.test.yaml --profile test \
    run --rm --no-deps -T smoke-helper "$@"
}

record_case() {
  local category="$1" critical="$2" result="$3"
  total=$((total + 1))
  case "$category" in
    translation) translation_total=$((translation_total + 1)) ;;
    ocr) ocr_total=$((ocr_total + 1)) ;;
    vision) vision_total=$((vision_total + 1)) ;;
    knowledge) knowledge_total=$((knowledge_total + 1)) ;;
    e2e) e2e_total=$((e2e_total + 1)) ;;
    *) printf 'Unknown benchmark category: %s\n' "$category" >&2; exit 2 ;;
  esac
  if [[ "$critical" == "1" ]]; then
    critical_total=$((critical_total + 1))
    if [[ "$category" == "translation" ]]; then
      translation_critical_total=$((translation_critical_total + 1))
    elif [[ "$category" == "knowledge" ]]; then
      knowledge_critical_total=$((knowledge_critical_total + 1))
    elif [[ "$category" == "e2e" ]]; then
      e2e_critical_total=$((e2e_critical_total + 1))
    fi
  fi
  if [[ "$result" == "pass" ]]; then
    pass=$((pass + 1))
    case "$category" in
      translation) translation_pass=$((translation_pass + 1)) ;;
      ocr) ocr_pass=$((ocr_pass + 1)) ;;
      vision) vision_pass=$((vision_pass + 1)) ;;
      knowledge) knowledge_pass=$((knowledge_pass + 1)) ;;
      e2e) e2e_pass=$((e2e_pass + 1)) ;;
    esac
    if [[ "$critical" == "1" ]]; then
      critical_pass=$((critical_pass + 1))
      if [[ "$category" == "translation" ]]; then
        translation_critical_pass=$((translation_critical_pass + 1))
      elif [[ "$category" == "knowledge" ]]; then
        knowledge_critical_pass=$((knowledge_critical_pass + 1))
      elif [[ "$category" == "e2e" ]]; then
        e2e_critical_pass=$((e2e_critical_pass + 1))
      fi
    fi
  fi
}

score_text_case() {
  local category="$1" critical="$2" label="$3" field="$4"
  shift 4
  local regex missing=0
  for regex in "$@"; do
    if ! grep -Eiq "$regex" <<<"$field"; then
      missing=1
      break
    fi
  done
  if (( missing == 0 )) && [[ -n "$field" ]]; then
    record_case "$category" "$critical" pass
    log "[pass] $label"
  else
    record_case "$category" "$critical" fail
    if [[ "$critical" == "1" ]]; then
      log "[CRITICAL FAIL] $label"
    else
      log "[fail] $label"
    fi
    log "       required semantic invariants: $*"
    if [[ -n "$field" ]]; then
      log "       observed field: $(printf '%.500s' "$field")"
    else
      log "       observed field: <empty or missing>"
    fi
  fi
}

score_ollama_case() {
  local critical="$1" label="$2" response="$3"
  shift 3
  local response_field
  response_field="$(printf '%s\n' "$response" | ollama_generate_response_field || true)"
  score_text_case translation "$critical" "$label" "$response_field" "$@"
  if [[ -z "$response_field" ]]; then
    log "       raw response: $(printf '%.300s' "$response")"
  fi
}


# Component knowledge cases are still useful regressions, but they are not used
# as a proxy for natural chat quality. Real sequential conversation quality is
# release-blocked separately by the E2E dialogue suite below.

score_docling_case() {
  local label="$1" response="$2"
  shift 2
  local text_field
  text_field="$(printf '%s\n' "$response" | docling_text_content_field || true)"
  score_text_case ocr 1 "$label" "$text_field" "$@"
  if [[ -z "$text_field" ]]; then
    log "       raw response: $(printf '%.300s' "$response")"
  fi
}

translation_case() {
  local critical="$1" label="$2" prompt="$3"
  shift 3
  local response
  response="$(dcurl -fsS --max-time "$MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"${prompt}\",\"stream\":false,\"think\":false,\"options\":{\"temperature\":0,\"num_predict\":128}}" \
    http://model-router:11434/api/generate 2>/dev/null)" || {
      infra_fail=$((infra_fail + 1))
      record_case translation "$critical" fail
      log "[infra-fail] $label request failed"
      return
    }
  score_ollama_case "$critical" "$label" "$response" "$@"
}

knowledge_case() {
  local critical="$1" label="$2" prompt="$3"
  shift 3
  local response response_field
  response="$(dcurl -fsS --max-time "$MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"${AGENT_MODEL}\",\"prompt\":\"${prompt}\",\"stream\":false,\"options\":{\"num_predict\":${KNOWLEDGE_NUM_PREDICT}}}" \
    http://model-router:11434/api/generate 2>/dev/null)" || {
      infra_fail=$((infra_fail + 1))
      record_case knowledge "$critical" fail
      log "[infra-fail] $label request failed"
      return
    }
  response_field="$(printf '%s\n' "$response" | ollama_generate_response_field || true)"
  score_text_case knowledge "$critical" "$label" "$response_field" "$@"
  if [[ -z "$response_field" ]]; then
    log "       raw response: $(printf '%.300s' "$response")"
  fi
}

knowledge_chat_case() {
  local critical="$1" label="$2" payload="$3"
  shift 3
  local response content_field
  payload="${payload/__MODEL__/${AGENT_MODEL}}"
  payload="${payload//__KNOWLEDGE_NUM_PREDICT__/${KNOWLEDGE_NUM_PREDICT}}"
  response="$(printf '%s' "$payload" | dcurl -fsS --max-time "$MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary @- \
    http://model-router:11434/api/chat 2>/dev/null)" || {
      infra_fail=$((infra_fail + 1))
      record_case knowledge "$critical" fail
      log "[infra-fail] $label request failed"
      return
    }
  content_field="$(printf '%s\n' "$response" | ollama_chat_content_field || true)"
  score_text_case knowledge "$critical" "$label" "$content_field" "$@"
  if [[ -z "$content_field" ]]; then
    log "       raw response: $(printf '%.300s' "$response")"
  fi
}

e2e_dialogue_suite() {
  local output rc line status label detail seen=0
  output="$(dc -f compose.yaml exec -T model-router env E2E_TIMEOUT="$MODEL_TIMEOUT" python3 /app/e2e-dialogue-benchmark.py 2>&1)"
  rc=$?

  while IFS='|' read -r status label detail; do
    [[ -n "$status" ]] || continue
    case "$status" in
      PASS)
        seen=$((seen + 1))
        record_case e2e 1 pass
        log "[pass] $label"
        [[ -n "$detail" ]] && log "       $detail"
        ;;
      FAIL)
        seen=$((seen + 1))
        record_case e2e 1 fail
        log "[CRITICAL FAIL] $label"
        [[ -n "$detail" ]] && log "       $detail"
        ;;
      INFRA)
        seen=$((seen + 1))
        infra_fail=$((infra_fail + 1))
        record_case e2e 1 fail
        log "[infra-fail] $label"
        [[ -n "$detail" ]] && log "       $detail"
        ;;
      *)
        log "       e2e probe: $line"
        ;;
    esac
  done <<< "$output"

  if (( seen != 3 )); then
    local emitted="$seen"
    infra_fail=$((infra_fail + 1))
    # Keep totals honest if the probe crashed before emitting all cases.
    while (( seen < 3 )); do
      record_case e2e 1 fail
      seen=$((seen + 1))
    done
    log "[infra-fail] E2E dialogue probe emitted ${emitted}/3 cases (exit ${rc})"
    log "       raw probe output: $(printf '%.500s' "$output")"
  elif (( rc == 2 )); then
    # INFRA lines above already incremented infra_fail.
    :
  elif (( rc != 0 && rc != 1 )); then
    infra_fail=$((infra_fail + 1))
    log "[infra-fail] E2E dialogue probe exited unexpectedly with ${rc}"
  fi
}

ocr_case() {
  local label="$1" file="$2" from_format="$3" lang="$4"
  shift 4
  local response
  response="$(dcurl -fsS --max-time "$DOCLING_TIMEOUT" \
    -X POST http://docling:5001/v1/convert/file \
    -H 'accept: application/json' -H "X-Api-Key: ${DOCLING_API_KEY}" \
    -F "from_formats=${from_format}" -F 'to_formats=text' -F 'do_ocr=true' -F 'force_ocr=true' \
    -F "ocr_preset=rapidocr" -F "ocr_lang=${lang}" -F "files=@/fixtures/ocr/${file}" 2>/dev/null)" || {
      infra_fail=$((infra_fail + 1))
      record_case ocr 1 fail
      log "[infra-fail] $label request failed"
      return
    }
  score_docling_case "$label" "$response" "$@"
}

vision_case() {
  local label="$1" response response_field img64 payload
  if [[ ! -s "$VISION_FIXTURE" ]]; then
    record_case vision 1 fail
    log "[CRITICAL FAIL] $label"
    log "       vision fixture missing: $VISION_FIXTURE"
    return
  fi
  img64="$(base64 <"$VISION_FIXTURE" | tr -d '\r\n')"
  payload="$(printf '{\"model\":\"%s\",\"prompt\":\"Read the large number in this image. Reply with only the number.\",\"images\":[\"%s\"],\"stream\":false,\"think\":false,\"options\":{\"temperature\":0,\"num_predict\":32}}' "$AGENT_MODEL" "$img64")"
  response="$(printf '%s' "$payload" | dcurl -sS --max-time "$MODEL_TIMEOUT" \
    -H 'Content-Type: application/json' --data-binary @- http://model-router:11434/api/generate 2>/dev/null)" || {
      infra_fail=$((infra_fail + 1))
      record_case vision 1 fail
      log "[infra-fail] $label request failed"
      return
    }
  response_field="$(printf '%s\n' "$response" | ollama_generate_response_field || true)"
  if [[ -n "$response_field" ]] && grep -Eq '42' <<<"$response_field"; then
    record_case vision 1 pass
    log "[pass] $label"
  else
    record_case vision 1 fail
    log "[CRITICAL FAIL] $label"
    log "       expected marker 42 in the response field"
    log "       raw response: $(printf '%.500s' "$response")"
  fi
}

log "Local Polyglot Agent production benchmark"
log "UTC: ${stamp}"
log "Agent model: ${AGENT_MODEL}"
log "Overall minimum score: ${MIN_SCORE}%"
log "Critical policy: 100% of critical translation, component knowledge, E2E dialogue, OCR, and vision cases"
log "Conversation routing: sticky first-user-language anchor; Chinese-first -> ${KNOWLEDGE_CHAT_MODEL}; other text -> Qwen3.5; contextual translation resolves on the anchor then hands off to Qwen3.5"
log "Component knowledge answer budget: ${KNOWLEDGE_NUM_PREDICT} generated tokens"
log ""
log "== Critical translation semantics =="

# Chinese -> English: preserve entities, time/numbers, negation and contrast.
translation_case 1 "Chinese -> English / time + place" \
  "Translate into natural English and output only the translation: 我明天去奥斯陆，火车14:30出发。" \
  'Oslo' '14[:.]30'
translation_case 1 "Chinese -> English / negated residence" \
  "Translate into natural English and output only the translation: 我不住在卑尔根，我住在特隆赫姆。" \
  'Bergen' 'Trondheim' 'not|don.t|do not|rather than|instead of'
translation_case 1 "Chinese -> English / numeric correction" \
  "Translate into natural English and output only the translation: 发票金额是530克朗，不是350克朗。" \
  '530' '350' 'not|isn.t|is not|rather than|instead of'
translation_case 1 "Chinese -> English / named entities" \
  "Translate into natural English and output only the translation: Anna周五13:05在卑尔根与Erik见面。" \
  'Anna' 'Erik' 'Bergen' 'Friday' '13[:.]05|1[:.]05[[:space:]]*([Pp][.]?[Mm][.]?)'

# English -> Chinese.
translation_case 1 "English -> Chinese / time + weekday" \
  "翻译成简体中文，只输出译文：The meeting in Bergen starts at 09:15 on Friday." \
  '0?9[:.]15|上午[[:space:]]*0?9(:|\.|点|时)15(分)?' '星期五|周五' 'Bergen|卑尔根'
translation_case 1 "English -> Chinese / negated residence" \
  "翻译成简体中文，只输出译文：I do not live in Oslo; I live in Bergen." \
  '奥斯陆|Oslo' '卑尔根|Bergen' '不|不是|而非|而不是'
translation_case 1 "English -> Chinese / numeric correction" \
  "翻译成简体中文，只输出译文：The invoice amount is 530 kroner, not 350 kroner." \
  '530' '350' '不|不是|而非|而不是'
translation_case 1 "English -> Chinese / named entities" \
  "翻译成简体中文，只输出译文：Anna will meet Erik in Bergen at 13:05 on Friday." \
  'Anna|安娜' 'Erik|埃里克' 'Bergen|卑尔根' '星期五|周五' '13[:.]05|下午[[:space:]]*0?1[[:space:]]*(:|\.|点|时)[[:space:]]*0?5[[:space:]]*(分)?'

# Bokmål -> English.
translation_case 1 "Bokmål -> English / residence semantics" \
  "Translate this Bokmål sentence into English, output only the translation: Jeg bor ikke i Norge." \
  'liv(e|ing)|resid(e|ing)' 'Norway' 'not|don.t|do not|rather than|instead of'
translation_case 1 "Bokmål -> English / time + place" \
  "Translate this Bokmål sentence into English, output only the translation: Møtet begynner fredag klokken 08:45 i Oslo." \
  'Friday' '0?8[:.]45' 'Oslo'
translation_case 1 "Bokmål -> English / numeric negation" \
  "Translate this Bokmål sentence into English, output only the translation: Pakken veier 12,5 kilo, ikke 21,5 kilo." \
  '12[.,]5' '21[.,]5' 'not|isn.t|doesn.t|rather than|instead of'
translation_case 1 "Bokmål -> English / named entities" \
  "Translate this Bokmål sentence into English, output only the translation: Anna møter Erik i Bergen fredag klokken 13:05." \
  'Anna' 'Erik' 'Bergen' 'Friday' '13[:.]05|1[:.]05[[:space:]]*([Pp][.]?[Mm][.]?)'

# Nynorsk -> English. The first case intentionally guards the prior semantic regression.
translation_case 1 "Nynorsk -> English / residence semantics" \
  "Translate this Nynorsk sentence into English, output only the translation: Eg bur ikkje i Noreg." \
  'liv(e|ing)|resid(e|ing)' 'Norway' 'not|don.t|do not|rather than|instead of'
translation_case 1 "Nynorsk -> English / time + place" \
  "Translate this Nynorsk sentence into English, output only the translation: Møtet byrjar fredag klokka 08:45 i Oslo." \
  'Friday' '0?8[:.]45' 'Oslo'
translation_case 1 "Nynorsk -> English / numeric negation" \
  "Translate this Nynorsk sentence into English, output only the translation: Pakka veg 12,5 kilo, ikkje 21,5 kilo." \
  '12[.,]5' '21[.,]5' 'not|isn.t|doesn.t|rather than|instead of'
translation_case 1 "Nynorsk -> English / named entities" \
  "Translate this Nynorsk sentence into English, output only the translation: Anna møter Erik i Bergen fredag klokka 13:05." \
  'Anna' 'Erik' 'Bergen' 'Friday' '13[:.]05|1[:.]05[[:space:]]*([Pp][.]?[Mm][.]?)'

# English -> Bokmål.
translation_case 1 "English -> Bokmål / negation + today" \
  "Translate into Norwegian Bokmål and output only the translation: I am not going to Oslo today." \
  'Oslo' 'ikke' 'i dag|idag'
translation_case 1 "English -> Bokmål / time + place" \
  "Translate into Norwegian Bokmål and output only the translation: The meeting starts Friday at 08:45 in Bergen." \
  'fredag' '0?8[:.]45' 'Bergen'
translation_case 1 "English -> Bokmål / numeric negation" \
  "Translate into Norwegian Bokmål and output only the translation: The package weighs 12.5 kilograms, not 21.5 kilograms." \
  '12[.,]5' '21[.,]5' 'ikke'
translation_case 1 "English -> Bokmål / named entities" \
  "Translate into Norwegian Bokmål and output only the translation: Anna will meet Erik in Bergen at 13:05 on Friday." \
  'Anna' 'Erik' 'Bergen' 'fredag' '13[:.]05'

# English -> Nynorsk.
translation_case 1 "English -> Nynorsk / negation + today" \
  "Translate into Norwegian Nynorsk and output only the translation: I am not going to Oslo today." \
  'Oslo' 'ikkje' 'i dag|idag'
translation_case 1 "English -> Nynorsk / time + place" \
  "Translate into Norwegian Nynorsk and output only the translation: The meeting starts Friday at 08:45 in Bergen." \
  'fredag' '0?8[:.]45' 'Bergen'
translation_case 1 "English -> Nynorsk / numeric negation" \
  "Translate into Norwegian Nynorsk and output only the translation: The package weighs 12.5 kilograms, not 21.5 kilograms." \
  '12[.,]5' '21[.,]5' 'ikkje'
translation_case 1 "English -> Nynorsk / named entities" \
  "Translate into Norwegian Nynorsk and output only the translation: Anna will meet Erik in Bergen at 13:05 on Friday." \
  'Anna' 'Erik' 'Bergen' 'fredag' '13[:.]05'

log ""
log "== Extended translation regression =="
# These cases count toward the >=95% overall score but are not individually release-blocking.
translation_case 0 "Chinese -> English / weekday delivery" \
  "Translate into natural English and output only the translation: 请把文件在周三下午16:20发给Anna。" \
  'Wednesday' '16[:.]20|4[:.]20[[:space:]]*([Pp][.]?[Mm][.]?)' 'Anna'
translation_case 0 "Chinese -> English / room-number correction" \
  "Translate into natural English and output only the translation: 房间号是407，不是470。" \
  '407' '470' 'not|isn.t|is not|rather than|instead of'
translation_case 0 "English -> Chinese / weekday delivery" \
  "翻译成简体中文，只输出译文：Send the file to Anna at 16:20 on Wednesday." \
  'Anna|安娜' '16[:.]20|下午[[:space:]]*0?4[[:space:]]*(:|\.|点|时)[[:space:]]*20[[:space:]]*(分)?' '星期三|周三'
translation_case 0 "English -> Chinese / room-number correction" \
  "翻译成简体中文，只输出译文：The room number is 407, not 470." \
  '407' '470' '不|不是|而非|而不是'
translation_case 0 "Bokmål -> English / weekday contrast" \
  "Translate this Bokmål sentence into English, output only the translation: Hun kommer ikke på mandag, men på tirsdag." \
  'Monday' 'Tuesday' 'not|isn.t|doesn.t|rather than|instead of'
translation_case 0 "Bokmål -> English / serial number" \
  "Translate this Bokmål sentence into English, output only the translation: Serienummeret er AX-2047." \
  'AX-2047' 'serial'
translation_case 0 "Nynorsk -> English / weekday contrast" \
  "Translate this Nynorsk sentence into English, output only the translation: Ho kjem ikkje måndag, men tysdag." \
  'Monday' 'Tuesday' 'not|isn.t|doesn.t|rather than|instead of'
translation_case 0 "Nynorsk -> English / serial number" \
  "Translate this Nynorsk sentence into English, output only the translation: Serienummeret er AX-2047." \
  'AX-2047' 'serial'
translation_case 0 "English -> Bokmål / weekday contrast" \
  "Translate into Norwegian Bokmål and output only the translation: She is not coming Monday, but Tuesday." \
  'mandag' 'tirsdag' 'ikke'
translation_case 0 "English -> Bokmål / serial number" \
  "Translate into Norwegian Bokmål and output only the translation: The serial number is AX-2047." \
  'AX-2047' 'serienummer'
translation_case 0 "English -> Nynorsk / weekday contrast" \
  "Translate into Norwegian Nynorsk and output only the translation: She is not coming Monday, but Tuesday." \
  'måndag|mandag' 'tysdag|tirsdag' 'ikkje'
translation_case 0 "English -> Nynorsk / serial number" \
  "Translate into Norwegian Nynorsk and output only the translation: The serial number is AX-2047." \
  'AX-2047' 'serienummer'

log ""
log "== Critical component knowledge =="
# Literary attribution and anti-hallucination: this directly guards the real
# regression where the model fabricated a Wang Wei-style poem and denied the
# authentic source.
knowledge_case 1 "Chinese literature / Wang Wei attribution" \
  "山路元无雨，空翠湿人衣。请只回答作者和篇名。" \
  '王维' '山中'
knowledge_case 1 "Chinese literature / reject false premise" \
  "有人说‘山路元无雨，空翠湿人衣’并不是王维《山中》的原句。这个说法对吗？请一句话纠正。" \
  '王维' '山中' '不对|错误|不正确|确实.*原句|是.*原句'
# False-premise resistance and stable common knowledge.
knowledge_case 1 "False premise / Norway capital" \
  "挪威的首都是卑尔根，对吗？请简短纠正。" \
  '奥斯陆|Oslo' '不对|不是|错误|首都.*奥斯陆|首都.*Oslo'
knowledge_case 1 "Chinese history / Zizhi Tongjian" \
  "《资治通鉴》主要由谁主持编纂？只回答人名。" \
  '司马光'
knowledge_case 1 "Unknown fictional manufacturer" \
  "Zyphora-17 是我刚刚虚构的设备名，我没有提供任何制造商信息。它的制造商是谁？请不要猜。" \
  '无法确定|不能确定|无法判断|未提供|不知道|不清楚|信息不足|无法得知|不存在|没有现实世界|没有.*制造商|虚构.*制造商|不会.*猜|不.*猜'

# Multi-turn context retention and basic reasoning.
knowledge_case 1 "Logical contradiction" \
  "如果所有 lume 都是 vex，并且没有 vex 是 tarn，那么是否可能有一个 lume 同时是 tarn？只回答‘可能’或‘不可能’。" \
  '不可能'
knowledge_case 1 "Decimal comparison" \
  "0.9 和 0.11 哪个数更大？只回答更大的数。" \
  '0[.]9'

log ""
log "== Critical E2E multi-turn conversation =="
e2e_dialogue_suite

log ""
log "== Critical OCR / scanned documents =="
ocr_case "Chinese image OCR" "zh-hans.png" "image" "ch" 'ZH-731' '奥斯陆'
ocr_case "English image OCR" "en.png" "image" "en" 'EN-482' 'English'
ocr_case "Bokmål image OCR" "nb.png" "image" "no" 'NB-593' 'Norge'
ocr_case "Nynorsk image OCR" "nn.png" "image" "no" 'NN-614' 'Noreg'
ocr_case "Latin 3-page scanned PDF" "scan-latin.pdf" "pdf" "no" 'EN-482' 'NB-593' 'NN-614'
ocr_case "Chinese scanned PDF" "scan-zh.pdf" "pdf" "ch" 'ZH-731' '奥斯陆'

log ""
log "== Critical vision =="
vision_case "Vision fixture marker 42"

if (( total == 0 )); then
  score=0
else
  score=$((100 * pass / total))
fi

critical_fail=$((critical_total - critical_pass))
translation_critical_fail=$((translation_critical_total - translation_critical_pass))
ocr_fail=$((ocr_total - ocr_pass))
vision_fail=$((vision_total - vision_pass))
knowledge_critical_fail=$((knowledge_critical_total - knowledge_critical_pass))
e2e_critical_fail=$((e2e_critical_total - e2e_critical_pass))

log ""
log "== Summary =="
log "overall: ${pass}/${total} (${score}%)"
log "translation: ${translation_pass}/${translation_total}"
log "critical translation: ${translation_critical_pass}/${translation_critical_total}"
log "component knowledge critical: ${knowledge_critical_pass}/${knowledge_critical_total}"
log "E2E dialogue critical: ${e2e_critical_pass}/${e2e_critical_total}"
log "OCR critical: ${ocr_pass}/${ocr_total}"
log "vision critical: ${vision_pass}/${vision_total}"
log "all critical: ${critical_pass}/${critical_total}"
log "infrastructure failures: ${infra_fail}"
log "report: ${report}"

if (( infra_fail > 0 )); then
  log "RESULT: FAIL (infrastructure)"
  exit 2
fi
if (( translation_critical_fail > 0 )); then
  log "RESULT: FAIL (${translation_critical_fail} critical translation semantic failure(s))"
  exit 1
fi
if (( knowledge_critical_fail > 0 )); then
  log "RESULT: FAIL (${knowledge_critical_fail} critical component-knowledge failure(s))"
  exit 1
fi
if (( e2e_critical_fail > 0 )); then
  log "RESULT: FAIL (${e2e_critical_fail} critical E2E dialogue failure(s))"
  exit 1
fi
if (( ocr_fail > 0 )); then
  log "RESULT: FAIL (${ocr_fail} critical OCR failure(s))"
  exit 1
fi
if (( vision_fail > 0 )); then
  log "RESULT: FAIL (${vision_fail} critical vision failure(s))"
  exit 1
fi
if (( critical_fail > 0 )); then
  log "RESULT: FAIL (${critical_fail} critical failure(s))"
  exit 1
fi
if (( score < MIN_SCORE )); then
  log "RESULT: FAIL (overall quality ${score}% < ${MIN_SCORE}%)"
  exit 1
fi
log "RESULT: PASS"
