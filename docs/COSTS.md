# Cost model

The default deployment is designed to require **no paid SaaS subscription and no metered model API**.

If you already own the Mac, the software/API bill can be $0:

- inference is local through Ollama;
- document extraction/OCR is local through Docling;
- exact-source recovery for referenced classical works uses a local SQLite corpus after first provisioning;
- embeddings are local through BGE-M3;
- the browser UI is self-hosted;
- no OpenAI, Anthropic, Google, Azure, AWS, or other paid model API is configured;
- Docker Desktop is not required;
- source hosting can be $0 on a free Git hosting plan; this repository does not currently include a hosted CI workflow.

"$0 software/API bill" is not the same as "zero total economic cost." Real-world costs can include electricity, internet bandwidth, SSD space, hardware purchase/depreciation, backup media/encryption services, and optional paid GitHub/cloud services chosen later.

## Network behavior

First provisioning needs network access to download container images, Ollama model weights, the exact-text literature corpus archive, and the prefetched Docling artifacts. Updates and forced refreshes need network access too.

After those artifacts are cached:

- the local chat/embedding path does not require a paid cloud model API;
- Ollama cloud inference/web-search features are disabled with `OLLAMA_NO_CLOUD=1`;
- contextual whole-work source retrieval reads the local literature SQLite index;
- Docling is pointed at local prefetched artifacts with remote services disabled;
- Open WebUI web search/OpenAI integration/version checks are disabled.

This still is not a strict air-gap firewall. Containers retain ordinary outbound networking unless the operator adds network/firewall restrictions.

## What “$0” means here

The checked-in default configuration contains no credential or endpoint for a metered model API. Normal chat, embeddings, OCR/document extraction, contextual source lookup, and image inference are local after provisioning. Upstream downloads (Homebrew packages, container images, Ollama model blobs, the literature archive, and Docling/RapidOCR artifacts) use ordinary public distribution services and may be subject to those providers' rate limits or future policy changes.

Open WebUI itself can be used without a subscription when its license terms are followed. Current releases protect Open WebUI branding; deployments that require branding removal outside the license exceptions may need separate permission or an enterprise license.
