# Photo Search

**English** · [简体中文](README.zh-CN.md)

Local-first semantic search for an Apple Photos library.

## Demo

Search by what you remember: people, scenes, visible text, or a natural-language
description of the moment.

![Photo Search demo](docs/photo-search-demo.webp)

This is the single repository for both parts of the product:

- `Sources/`, `Tests/`, `Package.swift`, and `scripts/`: native SwiftUI macOS app.
- `backend/`: PhotoKit export, Apple Vision OCR, model annotations, SQLite index,
  local image/text embeddings, hybrid retrieval, and background services.
- `~/Library/Application Support/PhotoSearch/`: private runtime data, previews,
  model-provider configuration, worker state, and logs.

Search, indexing, and browsing read Apple Photos through public APIs. **Review
photos** can delete only the items you mark and explicitly confirm, through
PhotoKit; a search or indexing run never deletes library items. Derived artifacts are versioned by model, prompt, schema,
preprocessing version, and input hash.

## Build the app

```bash
swift test
scripts/build_app.sh --version 0.1.0 --build <build-number>
open "dist/Photo Search.app"
```

## Run the backend

```bash
cd backend
.venv/bin/python -m unittest discover -s tests
.venv/bin/photo-search doctor
scripts/install_background_services.sh
```

Background services:

- `com.popcornnn.photo-search.worker`
- `com.popcornnn.photo-search.network`

The App's **Settings → Models** page manages local and cloud
OpenAI-compatible providers. Endpoint and model configuration is stored in the
private runtime directory; API keys are stored in macOS Keychain.

See [backend/README.md](backend/README.md) for CLI and indexing details.

The app searches the shared SQLite index directly and runs no loopback service.
Text ranking and hybrid fusion are ported to Swift (`PhotoSearchEngine.swift`).
Visual search needs a query vector, so the app starts the encoder host itself
(`photo-search encoder-serve`, spoken to over stdin/stdout) and keeps the 2B
model resident. **Settings → Visual Search** can offload it, and macOS memory
pressure offloads it automatically; the next search reloads it with a progress
bar. Text search keeps working when the model is unavailable.

## Search and browsing

Press **Return** or click the search arrow to submit. Typing edits a draft;
changing a category or date range applies to the last submitted query. Both
submission controls use the same text/visual ranking, with text fallback when
the local encoder cannot answer. Failed or cancelled helper requests are
bounded and the next search can restart the helper.

The calendar menu filters by **Any date**, **Last 30 days**, **This year**, or
**Last year** using your local calendar. Undated items appear only under Any date.
Library browsing loads 200 items at a time; **Load more**, viewer navigation, and
**Locate in Library** load older pages as needed. Background checks reload data
only after a committed index change, preserving the pages already loaded.

Result cards distinguish text matches, visual matches, and video-description
matches. These labels identify contributing retrieval paths, not confidence
percentages or verified facts about an image. Videos remain one result per video.

**Settings → Indexing** separates text, visual, and video coverage. Waiting for
a scheduled batch, a stale status, skipped items, and errors have distinct labels;
a missing count is shown as unknown rather than zero. Long worker stages refresh
a heartbeat every 30 seconds.

## Validation and local checkpoints

Swift and backend tests both run in CI. They share synthetic ranking fixtures
at `Tests/LiquidGlassDemoTests/Fixtures/search-ranking.json`, covering synonyms,
literal identifiers, irrelevant queries, video thresholds, and tie ordering.
No Photos access, private library, or model download is needed for those fixtures.
Runtime data under Application Support is not included in source control.

The current `origin` repository is public. Local checkpoints must not be pushed
there under the project's private-remote handoff policy.


<!-- workspace-maintenance:start -->
## 本地维护入口

工作目录：`/Users/forge/Workspace/photo-search`。代码与必要文档备份到 [私有仓库](https://github.com/Popcornnnnnnnn/photo-search-private)；[问题入口](https://github.com/Popcornnnnnnnn/photo-search-private/issues)。
日常分支：`main`，私有远端：`backup`。需跟进的问题先查重，进展与完成条件留在 Issue；项目功能和验收沿用现有记录。
既有公开问题仍从[原 Issue 入口](https://github.com/Popcornnnnnnnn/photo-search/issues)接续；本地未发布工作使用私有入口，避免重复建单。
<!-- workspace-maintenance:end -->
