# Random browsing

“Browse randomly” brings a locally available image to the viewer without ranking it for beauty, meaning, or personal value. It includes screenshots and all other available assets, even when their search description is not ready. The feature does not run AI analysis or infer a story.

## Navigation

- The entry is beside search and on the landing screen. Closing restores the existing search or library view and its scroll position. The large viewer shows the capture date, existing indexed description when available, and Copy Image.
- Locate in Library opens the exact indexed card at its timeline position. For an available image without a search document, it opens the nearest indexed date and says that the exact image is not in the grid yet.
- Left returns along the current viewing path. Right takes a fresh candidate; returning from A → B → C to B and going right produces D, not C. C remains in the viewing record.
- Subtle arrows sit inside the image canvas, with keyboard arrows and horizontal trackpad movement using the same directions. The left arrow is absent before there is history.
- The current image stays on screen while the next one is prepared; the slide begins only once a decoded neighbor is ready. Selection and offset reset in one transaction after the slide. No image is counted merely because it was queued or decoded.

## Selection and history

- On entry, the app reads lightweight IDs and paths from all available assets and shuffles the IDs. It decodes only a small window of local originals or previews (up to 3200 pixels), keeping a bounded cache for nearby candidates and backtracking. This does not establish that an iCloud original is present.
- A photo enters the persistent viewing record when its decoded image actually appears in the large viewer. Search matches, grid thumbnails, and selecting a card do not count. The ordinary large viewer uses the same record.
- For each candidate, the last actual viewing time is checked against a rolling seven-day window immediately before display, including after preloading. Deliberate backtracking is always allowed and updates the time.
- Exhaustion asks the user to start another round. That round may revisit recently seen photos once each; it does not delete or rewrite the viewing record to make them eligible. The exception lasts only for the current browsing session.
