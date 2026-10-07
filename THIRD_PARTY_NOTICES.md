# Third-party licenses and notices

This repository's own scripts, documentation, and configuration are licensed under MIT. It orchestrates third-party software and models that retain their own licenses.

| Component | Baseline used by this repo | Upstream license / important condition |
|---|---|---|
| Ollama | 0.34.4 | MIT |
| Qwen3.5 9B Q4_K_M | `qwen3.5:9b-q4_K_M` | Apache-2.0 |
| Qwen2.5 7B | `qwen2.5:7b` | Apache-2.0 |
| Qwen3 14B | `qwen3:14b` | Apache-2.0 |
| Qwen3-VL 4B Instruct | `qwen3-vl:4b-instruct` | Apache-2.0 |
| Qwen3 8B (legacy development tier) | `qwen3:8b` | Apache-2.0 |
| Qwen3-VL 8B Instruct (legacy/custom text option) | `qwen3-vl:8b-instruct` | Apache-2.0 |
| BGE-M3 | `bge-m3` | MIT |
| Docling Serve | 1.35.0 | MIT |
| Colima | current Homebrew package | MIT |
| Krunkit | current Homebrew package | Apache-2.0 |
| Open WebUI | 0.11.4 | Open WebUI license; v0.6.6+ includes a branding-protection clause |
| Alpine Linux helper image | 3.22.1 | MIT-style / mixed package licenses; maintenance-only helper |
| curlimages/curl helper image | 8.16.0 | curl license plus image base/package licenses; test-only helper |
| open-chinese/poetry-collection | local exact-text corpus source | MIT repository license; review upstream data provenance |

## Open WebUI branding

Open WebUI can be used without a subscription when its license terms are followed. For current releases, do not remove, alter, obscure, or improperly co-brand the Open WebUI branding unless you qualify for an exception in its license (including the small-deployment exception) or obtain the required permission/license.

Because of this upstream condition, it is more accurate to describe this project as an **MIT-licensed orchestration repository using separately licensed dependencies**, not as a stack in which every dependency is MIT/BSD with no additional conditions.

## Model weights

Model weights are not redistributed by this repository. They are downloaded by Ollama and remain subject to the model publisher's license. The standard Qwen3.5 9B, Qwen2.5 7B, and Qwen3/Qwen3-VL models used by this profile are published under Apache-2.0; review each upstream model card/license before redistribution or commercial deployment. Record the exact model manifests/digests you deploy if you require strict reproducibility.

This file is informational, not legal advice. Review upstream license texts before redistribution, white-labelling, or commercial deployment.
## open-chinese/poetry-collection

- Purpose here: source dataset for the rebuildable local exact-text literature index used by contextual whole-work translation.
- Upstream: `https://github.com/open-chinese/poetry-collection`
- Upstream repository license: MIT.
- The upstream repository describes a simplified-Chinese corpus of roughly 370,000 works across 370 volume JSON files. Review upstream provenance/license information for your deployment requirements; this project does not relicense upstream data.

