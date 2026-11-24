# Public Release & First-Run Onboarding Design

This document outlines the path from a signed developer-machine build to a one-click public DMG release of **Photo Search.app** that any macOS user — and Raycast Store reviewers — can install and run without manual terminal setup.

---

## 1. Current Gap Between Local Setup & Public Installer

Today, **Photo Search.app** builds cleanly as a hardened, Developer ID-signed bundle with Sparkle auto-updates configured in `app.yml`, but first-time library indexing and local visual embeddings still assume developer setup under `backend/.venv/` and manually installed `LaunchAgents`:

- `Sources/LiquidGlassDemo/OnboardingView.swift` currently shows generic template copy (`onboardingThemes`, `onboardingMenuBar`, `onboardingUpdates`) rather than Photo Search setup steps.
- `PhotoEncoderCommand.resolve()` checks `~/Library/Application Support/PhotoSearch/backend.json` and `<repo>/backend/.venv/bin/photo-search`; neither exists on a clean user's Mac when installing `Photo Search.app` from a DMG into `/Applications/`.
- Full-library indexing (`com.popcornnn.photo-search.worker`) is currently installed via `backend/scripts/install_background_services.sh`.

Text/OCR search still degrades gracefully when no visual encoder is installed, but shipping a true one-click companion experience requires bundling or automating those dependencies.

---

## 2. Four-Step First-Run Onboarding Flow (`OnboardingView.swift`)

Replace the placeholder welcome checklist with an interactive, resumable 4-step wizard backed by persistent setup state:

1. **Welcome & Library Access (Apple Photos):**
   - Explain the privacy contract clearly: read-only access to Apple Photos, private local previews stored in `~/Library/Application Support/PhotoSearch/`, and zero edits/deletions inside Photos.
   - Trigger `PHPhotoLibrary.requestAuthorization(for: .readWrite)` (or `.addOnly` read check via PhotoKit helper) directly from a primary **Allow Photos Access** button, showing live System Settings recovery guidance if denied.
2. **Captioning & OCR Engine Setup:**
   - **Zero-config fast mode (recommended default):** Use on-device Apple Vision OCR + metadata (`search_fts` + `PhotoSearchEngine.swift`), which works immediately on every Mac with zero downloads or API keys.
   - **Rich AI captions (optional):** Offer preset setup for a local OpenAI-compatible VLM server (e.g., LM Studio / Ollama on `127.0.0.1`), a custom API-key provider (Keychain-backed), or ChatGPT Plan authentication.
3. **Optional Visual Search Model (~4.6 GB `Qwen3-VL-Embedding-2B`):**
   - Explain clearly that caption + OCR search works at `<50 ms` with zero extra RAM, while visual AI enables semantic appearance search (`~4.6 GB` on disk and in RAM when loaded; auto-offloaded after 10 min when woken in the background by Raycast).
   - Provide **Download & Verify Visual Model** (resumable Hugging Face download into `~/Library/Application Support/PhotoSearch/models/Qwen3-VL-Embedding-2B/` with SHA-256 verification and live progress) alongside **Skip for Now** (can be enabled later in **Settings → Visual Search**).
4. **Initial Indexing & Optional Raycast Integration:**
   - Start background indexing immediately with live progress (`Photos · Videos · OCR · Visual`) and show a deep link / instruction card for installing the companion Raycast extension (`sp` / `sv`).

---

## 3. Eliminating Manual Python `.venv` & `LaunchAgents`

For public DMG distribution inside `/Applications/Photo Search.app`:

1. **In-app / helper background indexing (`SMAppService`):**
   - Register the indexer using `SMAppService.agent(plistName:)` (or run incremental indexing via an XPC/helper owned by `Photo Search.app`) instead of loose `~/Library/LaunchAgents/` shell scripts.
2. **Self-contained runtime for Vision OCR & Vector Encoding:**
   - **Short-term bridge:** Bundle or bootstrap a pinned standalone Python/MLX or PyTorch runtime inside `~/Library/Application Support/PhotoSearch/runtime/` on first opt-in for visual search, managed directly by `Photo Search.app`.
   - **Long-term native target:** Move Apple Vision OCR (`VNRecognizeTextRequest`), PhotoKit export, and CoreML / MLX Swift query embedding into native Swift helpers embedded inside `Photo Search.app/Contents/Helpers/` so the `.app` has zero external Python dependency.
3. **Raycast Store Companion Alignment:**
   - Ensure `Search Photos` and `Search Videos` remain usable even during initial indexing or when the user skips the 4.6 GB visual model download (`Stage 1` SQLite FTS5 + Aho-Corasick lexical search handles natural-language captions and OCR with zero encoder dependency).

---

## 4. Public Release & Raycast Store Checklist

Before cutting the first public release (`v0.1.0`) and opening the PR to `raycast/extensions`:

- [ ] **Merge & verify clean `main` / `development`:** Merge the feature branch and ensure `git status --porcelain` is empty.
- [ ] **Verify `app.yml` & notarization profile:** Confirm `developer_id_application`, `apple_team_id`, `feed_url`, `download_base_url`, and `sparkle_public_ed_key` in `app.yml`, and verify the local `notarytool` profile (`PHOTO_SEARCH_NOTARY_PROFILE=port-tools-notary` or `xcrun notarytool store-credentials "photo-search-notary"`).
- [ ] **Cut notarized DMG + GitHub Release:** Run `PHOTO_SEARCH_NOTARY_PROFILE=port-tools-notary scripts/release.sh --version 0.1.0 --build <N>`, verify stapling with `xcrun stapler validate`, and commit the updated `appcast.xml`.
- [ ] **Update Raycast extension download link & metadata:** Point `raycast/README.md` at the public GitHub Release download URL and add 3–4 sample-photo screenshots in `raycast/metadata/` (never using personal photos).
- [ ] **Submit Raycast Store PR:** Run `cd raycast && npm ci && npm test && npm run lint && npm run build`, then open the PR under `extensions/photo-search/` in `raycast/extensions`.
