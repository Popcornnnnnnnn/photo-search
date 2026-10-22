# Photo Search Pilot

A private, local-first pilot for searching a personal Apple Photos library with:

- the Photos scripting API for an explicitly selected pilot sample
- a compiled PhotoKit helper reserved for the future full-library app
- Apple Vision OCR for exact visible text
- a private Qwen endpoint for versioned structured annotations
- SQLite for durable metadata, artifacts, future embeddings, and search documents

Backend ingestion and indexing never modify the Photos library. The native app has a separate, explicitly confirmed Review photos deletion flow through PhotoKit. The pilot exports 1600-pixel JPEG previews into its private runtime directory and keeps every derived artifact versioned by model, prompt, schema, preprocessing version, and input hash.

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

For a local Qwen 27B in LM Studio, choose **Settings → Models → Add Local
Qwen 27B** in the native app. The preset uses `http://127.0.0.1:1234/v1` and
`qwen3.8-27b-uncensored`. Install the vision model in LM Studio first, then add
the provider and choose **Use**. The background worker starts the loopback
server and loads that installed model automatically with a 16K context. It
reports the loading stage and a specific error if the model is missing; it
never downloads models or unloads other applications' models.

Choosing **Use** on Qwen 4090 makes it the preferred provider, with Local Qwen
27B as a fallback when that profile exists. Each batch retries the preferred
provider up to three times (20 seconds per probe) before falling back locally,
and returns to the 4090 on a later batch when it responds again. Selecting
Local Qwen 27B directly disables this preference. The Models page distinguishes
the preferred provider, fallback and current active provider. **Check Again**
also starts an idle worker without interrupting an active batch.

The local preset disables the Tailscale/SSH bridge and JSON Response Mode
(LM Studio rejects `json_object`); prompts still request JSON. Local requests
use LM Studio's `reasoning_effort: "none"` to disable thinking instead
of vLLM's `chat_template_kwargs`. Existing photo
annotations remain available unless **Reprocess Existing Photos** is enabled.
This changes the annotation and query-expansion model, not the separate
`Qwen3-VL-Embedding-2B` vector model.

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

## Hybrid search

The CLI and benchmark run the Python retrieval function directly. The native app
ports text and hybrid ranking to Swift (`PhotoSearchEngine.swift`) and reads the same SQLite index
directly, so no loopback service is involved. Search combines Chinese/English text matches with
image/text cosine similarity using reciprocal rank fusion, while preserving a
strongly leading text match. Category filters apply before ranking. Query
expansion through the annotation model is opt-in (`--expand`).

### The app's encoder host

Visual search needs the query encoded into the same space as the stored image
vectors. The app starts that encoder itself and talks to it over stdin/stdout:

```bash
.venv/bin/photo-search encoder-serve
```

The host answers newline-delimited JSON: `status`, `load`, `offload`, `embed`,
and `quit`. It listens on no port, so there is no service to keep alive or
uninstall separately, and it exits when the app closes its stdin. The model
stays resident after the first search; **Settings → Visual Search** offloads it
on demand, macOS memory pressure offloads it automatically, and the next search
reloads it while reporting the load stages. `install_background_services.sh`
writes `~/Library/Application Support/PhotoSearch/backend.json` so a relocated
checkout still resolves the command.

Install the optional local encoder into the backend environment:

```bash
.venv/bin/pip install -e '.[embeddings]'
```

Place `Qwen/Qwen3-VL-Embedding-2B` revision
`9f2f7e710d6d81056aa5c0a4f04764fec6bb7bda` in
`~/Library/Application Support/PhotoSearch/models/Qwen3-VL-Embedding-2B/`.
The encoder never downloads models during a search. It uses Metal on Apple
Silicon, CUDA where available, or CPU. Image preprocessing and query instructions
match the existing pinned benchmark; model/revision/prompt/dimensions must match
before vectors can be compared. The first query or indexing batch loads the model;
subsequent work reuses it, with a bounded in-memory query cache.

```bash
# Each completed image is saved; rerunning skips existing compatible vectors.
.venv/bin/photo-search index-embeddings --limit 100

# Evaluate the production search over the current index using saved cases.json.
.venv/bin/photo-search benchmark-search /path/to/benchmark-run

# Text-only comparison, without loading an embedding model.
.venv/bin/photo-search search "桥下骑车" --lexical-only
```

Vector batches are filled by the scheduled worker: each invocation runs one
bounded batch and shares a lock with the CLI, so duplicate batches cannot run.
In All, photos with vectors are searchable even before their text annotations
finish; category filters require an existing classification. Progress is in
`embedding-status.json`. An unreadable image is isolated using
`processing_skips`; changing its content makes it eligible again. Model failures
leave text search available.

The app shows visual-index coverage and explicitly reports text-only fallback
when the model is unavailable. A partial vector index does not prevent searching
the remaining OCR and annotations. Evaluation writes a separate `search-report.json`
and does not replace the original benchmark report.

Low-relevance candidates are filtered before results are returned. Visual-only
candidates require cosine similarity of at least 0.45 for image vectors without
text support. Images covering at least 25% of the meaningful query characters
retain the 0.40 gate so partially described scenes remain searchable.
Text-encoded video descriptions require 0.55 because their unrelated-query
baseline is higher. Text-only candidates need
at least 50% coverage of meaningful query characters. Exact-looking identifiers
such as `ECONNREFUSED` and `B0190` retain text matching, and structured identifiers
such as `ZXQ_TEST_ERROR` must occur literally. Similarity is not a probability.
The API's `plan.match_status` distinguishes `none`, `possible`, and `matches`;
the native app shows the distinction alongside coverage/fallback information.
These thresholds were chosen using the existing positive set and a separate
constructed negative set. `benchmark-search` accepts negative cases with an empty
`expected` array and reports their empty-result rate separately from positive recall.

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

The installed user LaunchAgents keep the Mac awake while a batch is active,
resume the worker every minute, and recover the Tailscale/SSH bridge for
providers that opt into it:

```text
~/Library/LaunchAgents/com.popcornnn.photo-search.worker.plist
~/Library/LaunchAgents/com.popcornnn.photo-search.network.plist
```

Check progress from the terminal:

```bash
.venv/bin/photo-search worker-status
.venv/bin/photo-search network-status
```

The worker checks Photos at most once every five minutes, independently of its
annotation batches. Unchanged previews are neither re-exported nor rehashed.
PhotoKit modification dates trigger versioned preview exports; changed content
hashes invalidate active OCR, annotations, and vectors while retaining their
history. Vector writes carry the input hash, so an in-flight result for an older
image cannot replace a newer one. Schema version 1 adds source availability and
the embedding input hash, preserving legacy vectors against existing cached previews.

Only an explicitly complete inventory with full Photos authorization can hide
deleted assets. Failed/partial/limited-access scans cannot imply deletion.
Missing assets are marked unavailable rather than removed from SQLite or disk;
restored assets become searchable again. A failed export of a changed asset in a
complete inventory is hidden until a successful import replaces it.

The annotation worker processes a bounded batch (12 by default)
and releases its lock, so the next run can discover newly synced iCloud Photos
as well as continue model indexing. Indexing stops on the first
service/network error, records it, and is retried by launchd instead of marking
every remaining photo as failed. Image embeddings are generated locally in small
batches; the remote 27B annotation service continues running independently.

The native Photo Search app writes the active OpenAI-compatible provider to
`~/Library/Application Support/PhotoSearch/model-providers.json`. API keys are
stored separately in macOS Keychain. Existing annotations remain active when a
provider changes unless **Reprocess Existing Photos** is enabled.

## Apple Photos video search

The full-library PhotoKit sync includes photos and videos. Each video produces one
search result: a cover image, duration, and a whole-video description. The viewer
plays the exported current version with native controls. Video indexing and playback never write to Apple Photos.

Before indexing videos on a new Mac:

```bash
scripts/setup_video.sh
.venv/bin/photo-search build-native
```

The setup installs FFmpeg and whisper.cpp and downloads the pinned multilingual
Whisper small model (about 466 MiB) into the private runtime model directory.
Speech recognition runs locally. Raw audio is never sent to a model provider.
Sampled video frames and recognized speech text use the existing annotation provider
for visual understanding and summarization.

The pipeline samples chronological frames every five seconds, including the end,
processes them in groups of eight, and combines every group's evidence into one
video annotation. This is sampled visual understanding; brief events between sampled
frames can be missed. Full speech text, sampled-frame OCR, and group descriptions
remain searchable even if the final summary omits a detail. Intermediate artifacts
are checkpointed in the existing artifact store, so an interrupted video resumes.
Videos without an audio track bypass speech recognition. Chinese transcripts include
locally normalized Simplified Chinese alongside the original recognition text.

Video description vectors use `video-retrieval-v1` and the document instruction of
the existing pinned Qwen encoder. Photo vectors retain `image-retrieval-v1`.
Video vectors become eligible after annotation and are invalidated when the source
video or its annotation changes. Search merges both contracts and returns one result
per asset. Image-only random browsing and photo review exclude videos.

The exporter retains one current video copy in its import cache and copies only its
JPEG cover to `assets/`. Its normal five-minute sync discovers video edits and
removals; only a complete authorized mixed-media inventory reconciles videos.
Legacy photo-only inventories cannot mark videos as deleted.

Scheduled runs never display a Photos consent dialog. If macOS requires renewed
access after rebuilding the exporter, open **Settings → Indexing → Allow Photos
Access** and grant access. The next scheduled run resumes. The same explicit action
is available from `.venv/bin/photo-search authorize-photos`.

## Native search validation

The native app submits searches explicitly, caches read-only documents and packed
float32 vectors, and invalidates that cache using a persistent SQLite connection's
`PRAGMA data_version`. Model/prompt/revision/input-hash checks still apply before
vectors can be compared. Categories and date ranges filter candidates before
ranking. Memory pressure clears the native cache.

Python benchmarks measure the Python retrieval path. Shared synthetic fixtures
at `Tests/LiquidGlassDemoTests/Fixtures/search-ranking.json` separately check that
Swift and Python return the same expected order. Run both test suites when ranking
rules change; Python benchmark timings do not establish native UI latency.

The worker status includes video annotation coverage and refreshes every 30 seconds
while a stage runs, including long local transcription and model requests. The
native status page distinguishes a waiting batch from active work, stale reports,
completed indexing, and completion with skipped items. Unknown coverage is not
reported as zero.
