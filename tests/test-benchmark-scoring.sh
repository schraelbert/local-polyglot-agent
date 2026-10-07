#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Validate the two regressions from the real benchmark output:
# 1) Chinese may naturally omit a leading zero from 09:15.
printf '%s\n' '"response":" Bergen的会议周五上午9:15开始。"' | grep -Eiq '0?9:15'
printf '%s\n' '"response":" Bergen的会议周五上午9:15开始。"' | grep -Eiq '星期五|周五'
# 2) Equivalent 12-hour English time is accepted for a 24-hour source time.
printf '%s\n' '"response":"Please send the file to Anna at 4:20 PM on Wednesday."' | grep -Eiq '16[:.]20|4[:.]20[[:space:]]*([Pp][.]?[Mm][.]?)'
printf '%s\n' '"response":"安娜周五下午1点05分将在卑尔根与埃里克见面。"' | grep -Eiq '13[:.]05|下午[[:space:]]*0?1[[:space:]]*(:|\.|点|时)[[:space:]]*0?5[[:space:]]*(分)?'
printf '%s\n' '"response":"周三下午4点20分将文件发送给安娜。"' | grep -Eiq '16[:.]20|下午[[:space:]]*0?4[[:space:]]*(:|\.|点|时)[[:space:]]*20[[:space:]]*(分)?'
printf '%s\n' '"response":"周三下午 4 点 20 分将文件发送给安娜。"' | grep -Eiq '16[:.]20|下午[[:space:]]*0?4[[:space:]]*(:|\.|点|时)[[:space:]]*20[[:space:]]*(分)?'
# 3) OCR is scored from Docling document.text_content, not an Ollama response.
# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/common.sh"
raw='{"document":{"text_content":"English OCR test\\nOslo 2026\\nCode EN-482"},"status":"success"}'
field="$(printf '%s\n' "$raw" | docling_text_content_field)"
grep -Fq 'EN-482' <<<"$field"
grep -Fq 'English' <<<"$field"
# 4) Knowledge multi-turn cases score /api/chat message.content, not thinking.
chat_raw='{"message":{"role":"assistant","content":"王维《山中》","thinking":"ignore this"},"done":true}'
chat_field="$(printf '%s\n' "$chat_raw" | ollama_chat_content_field)"
grep -Fq '王维' <<<"$chat_field"
grep -Fq '山中' <<<"$chat_field"
# 5) A semantically correct refusal to invent a manufacturer must pass even if
# it does not use the stock phrase "无法确定".
fictional='根据您提供的信息，Zyphora-17 是您虚构的设备名称。因此，它并没有现实世界中的制造商，我不会猜测或编造制造商信息。'
grep -Eiq '无法确定|不能确定|无法判断|未提供|不知道|不清楚|信息不足|无法得知|不存在|没有现实世界|没有.*制造商|虚构.*制造商|不会.*猜|不.*猜' <<<"$fictional"
echo 'benchmark scoring regression test passed'
