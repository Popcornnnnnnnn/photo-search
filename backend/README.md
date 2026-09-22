# Photo Search Pilot

A private, local-first pilot for searching a personal Apple Photos library with:

- the Photos scripting API for an explicitly selected pilot sample
- a compiled PhotoKit helper reserved for the future full-library app
- Apple Vision OCR for exact visible text
- a private Qwen endpoint for versioned structured annotations
- SQLite for durable metadata, artifacts, future embeddings, and search documents
- a minimal local web query page

The project never modifies the Photos library. The pilot exports 1600-pixel JPEG previews into its private runtime directory and keeps every derived artifact versioned by model, prompt, schema, preprocessing version, and input hash.

## Boundaries of v0.1

This is deliberately a small validation build:

- It imports only an explicitly selected set of Photos assets.
- It has OCR plus semantic query expansion over Qwen annotations.
- It does not start a full-library background crawl.
- It includes a small, repeatable image/text embedding benchmark using the official
  `Qwen3-VL-Embedding-2B` wrapper on the private 4090 host.
- It does not read Photos' private database.

If the pilot's retrieval quality is promising, the next increment is image/text embeddings and resumable background ingestion.

## Runtime data

Source code lives here. Private runtime data lives outside the repository:

```text
~/Library/Application Support/PhotoSearch/
├── photo-search.sqlite3
├── assets/
└── imports/
```

The directory is mode `0700`; the SQLite database is mode `0600`.

## Setup

```bash
cd backend
chmod +x scripts/build_native.sh
python3 -m venv .venv
.venv/bin/pip install -e .
.venv/bin/photo-search build-native
.venv/bin/photo-search doctor
```

The Qwen API defaults to the existing local SSH tunnel:

```text
http://127.0.0.1:18000/v1
```

Override it with `PHOTO_SEARCH_QWEN_URL` or change the model with `PHOTO_SEARCH_QWEN_MODEL`.

## Run the pilot

Select a small, representative set in Photos, then import and index up to twelve selected assets:

```bash
.venv/bin/photo-search sample --limit 12 --index
```

For a larger read-only validation set, the library sampler takes a deterministic
time-spread sample and explicitly adds screenshots (25% target, filling from the
general library when needed):

```bash
.venv/bin/photo-search sample-library --limit 100
.venv/bin/photo-search index --limit 100
```

macOS must grant **Full Access** to `Photo Search Exporter`. The helper exports
previews only and never writes to the Photos library.

macOS may ask whether the local process can automate Photos. The pilot uses Photos' public export command and never modifies the library. Exported originals remain in the private runtime import cache; 1600-pixel JPEG previews are used for OCR, Qwen, and the result grid.

Search in the terminal:

```bash
.venv/bin/photo-search search "之前 OpenCode 连接失败的截图"
```

Run the local query page:

```bash
.venv/bin/photo-search serve
```

Then open <http://127.0.0.1:8766>.

## Import a folder instead of Photos

```bash
.venv/bin/photo-search ingest ~/Pictures/sample --limit 20 --index
```

## Upgrade model or prompt

Old artifacts are append-only. Updating `ANNOTATION_PROMPT_VERSION`, `ANNOTATION_SCHEMA_VERSION`, the model identifier, or the preprocessing version creates a new artifact generation. Previous results remain available for comparison and rollback.

The future embedding layer follows the same rule: vectors from different models or instructions live in distinct namespaces and are never mixed.

## Repeat the embedding benchmark

Prepare the current private sample without uploading it to a third party:

```bash
.venv/bin/photo-search benchmark-prepare ./benchmark-run \
  --source-kind apple-photos-benchmark \
  --cases ./cases.json
```

Copy that directory and `remote/embed_items.py` to the private 4090 host, run the
official Qwen embedding wrapper there, copy `vectors.jsonl` back, then evaluate:

```bash
.venv/bin/photo-search benchmark-evaluate ./benchmark-run
```

The report records Hit@1/Hit@3 against fixed queries and keeps the image vectors
in the versioned SQLite namespace `image-retrieval-v1`. This makes later model,
prompt, and preprocessing comparisons repeatable rather than overwriting old work.

## Unattended full-library worker

The installed user LaunchAgents keep the local page running, keep the Mac awake
while a batch is active, resume the worker every minute, and recover the
Tailscale/SSH bridge for providers that opt into it:

```text
~/Library/LaunchAgents/com.popcornnn.photo-search.web.plist
~/Library/LaunchAgents/com.popcornnn.photo-search.worker.plist
~/Library/LaunchAgents/com.popcornnn.photo-search.network.plist
```

Check progress either on <http://127.0.0.1:8766> or from the terminal:

```bash
.venv/bin/photo-search worker-status
.venv/bin/photo-search network-status
```

Each scheduled run first performs a read-only, resumable Photos scan; existing
1600 px previews are skipped. It then processes a bounded batch (12 by default)
and releases its lock, so the next run can discover newly synced iCloud Photos
as well as continue model indexing. Indexing stops on the first
service/network error, records it, and is retried by launchd instead of marking
every remaining photo as failed. Full-library image embeddings are deliberately
deferred so the unattended worker never stores a sudo password or automatically
interrupts the 27B OpenCode service.

The native Photo Search app writes the active OpenAI-compatible provider to
`~/Library/Application Support/PhotoSearch/model-providers.json`. API keys are
stored separately in macOS Keychain. Existing annotations remain active when a
provider changes unless **Reprocess Existing Photos** is enabled.
