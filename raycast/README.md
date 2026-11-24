# Photo Search for Raycast

Search your local Apple Photos and video library right inside Raycast using natural language captions, OCR text, and local visual embeddings — powered by the [Photo Search](https://github.com/Popcornnnnnnnn/photo-search) companion macOS app.

## Features

- **Instant Two-Stage Search:** Paints fast caption, tag, and OCR matches immediately (<200 ms), then upgrades results with local `Qwen3-VL-Embedding-2B` visual similarity via a single shared companion instance (no duplicated 4 GB RAM load).
- **Photos, Screenshots, & Videos:** Filter by category (`Photos`, `Videos`, `Screenshots`, `Chats`, `Documents`, `Posters & Memes`) and date (`Last 30 Days`, `This Year`, `Last Year`).
- **Quick Actions:** Copy an image straight to your clipboard, preview with Quick Look (`⌘Y`), open any video directly in Photo Search to play (`↵`), or jump to the original item in Apple Photos (`⌘O`).
- **Local & Private:** Everything queries your local SQLite index and private Unix socket (`~/Library/Application Support/PhotoSearch/search.sock`).

## Requirements

1. macOS 15 or later with **[Photo Search.app](https://github.com/Popcornnnnnnnn/photo-search/releases)** installed from the signed, notarized GitHub Release DMG (default path: `/Applications/Photo Search.app`).
2. A local library index created inside **Photo Search**: launch the app, grant Photos access, and follow the built-in on-device Apple Vision onboarding (no terminal setup required; optional local `Qwen3-VL-Embedding-2B` or VLM enrichment can be configured in Settings).

## Commands

| Command | Description |
| --- | --- |
| **Search Photos** | Grid search across photos, screenshots, chats, documents, and memes with category and date filters. |
| **Search Videos** | Video-focused search by description, scene, and visible text, with `↵` launching playback in Photo Search. |
| **Visual Search Status** | Inspect index coverage, check bridge connectivity, and warm up or offload the local visual model from RAM. |

## Preferences

- **Search Mode:** `Hybrid (Text + Visual)` (default) or `Fast Text Only (Captions & OCR)`.
- **Auto-Start Photo Search in Background:** Automatically wakes `Photo Search.app --background` without stealing focus when hybrid search is needed.
- **Photo Search App Path:** Override if `Photo Search.app` is installed outside `/Applications`.
- **Results Limit:** `20`, `40` (default), `60`, or `100`.

## Local Development & Loading into Raycast

```bash
cd raycast
npm install
npm test
npm run lint
npm run build
npm run dev
```

Or open Raycast → **Import Extension** and select the `raycast/` folder.

## Privacy & Store Metadata

- Search requests communicate exclusively over the local Unix domain socket (`~/Library/Application Support/PhotoSearch/search.sock`).
- No personal photos leave your Mac during default on-device Vision indexing; Store screenshots in `metadata/` use synthetic sample imagery.
