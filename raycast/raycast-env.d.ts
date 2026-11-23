/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {
  /** Search Mode - Hybrid shows instant text/OCR hits first and reranks with local visual AI via the running Photo Search app. */
  "searchMode": "hybrid" | "lexical",
  /** Auto-Start Photo Search in Background - Launch Photo Search silently in the background when hybrid visual search is needed. */
  "autoStartCompanion": boolean,
  /** Photo Search App Path - Path to the installed Photo Search companion app bundle. */
  "appPath": string,
  /** Results Limit - Maximum number of results to display per query. */
  "resultLimit": "20" | "40" | "60" | "100"
}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `search-photos` command */
  export type SearchPhotos = ExtensionPreferences & {}
  /** Preferences accessible in the `search-videos` command */
  export type SearchVideos = ExtensionPreferences & {}
  /** Preferences accessible in the `visual-search-status` command */
  export type VisualSearchStatus = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `search-photos` command */
  export type SearchPhotos = {}
  /** Arguments passed to the `search-videos` command */
  export type SearchVideos = {}
  /** Arguments passed to the `visual-search-status` command */
  export type VisualSearchStatus = {}
}

