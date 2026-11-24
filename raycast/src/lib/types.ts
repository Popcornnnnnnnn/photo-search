export type PhotoSection =
  | "all"
  | "photo"
  | "video"
  | "uiScreenshot"
  | "chatScreenshot"
  | "document"
  | "posterOrMeme";

export type PhotoTimeFilter = "all" | "last30Days" | "thisYear" | "lastYear";

export type SearchMode = "hybrid" | "lexical";

export interface BridgeRequest {
  op: "ping" | "search" | "load" | "offload" | "open-in-photos";
  query?: string;
  section?: PhotoSection;
  time?: PhotoTimeFilter;
  limit?: number;
  mode?: SearchMode;
  loadEncoder?: boolean;
  assetId?: string;
}

export interface BridgeEncoderStatus {
  available: boolean;
  state: "ready" | "loading" | "offloaded" | "unavailable" | string;
  residentBytes: number;
  loadProgress: number;
  loadStage: string;
  lastFailure?: string | null;
}

export interface BridgeStats {
  total: number;
  indexed: number;
  failed: number;
}

export interface BridgePhotoItem {
  id: string;
  filename: string;
  thumbnailPath: string;
  filePath: string;
  capturedAt?: string | null;
  displayCapturedAt?: string | null;
  assetType: string;
  displayAssetType: string;
  isVideo: boolean;
  durationSeconds?: number | null;
  displayDuration?: string | null;
  shortCaption: string;
  detailedDescription?: string | null;
  scene?: string | null;
  entities: string[];
  topics: string[];
  width?: number | null;
  height?: number | null;
  matchText: boolean;
  matchVisual: boolean;
  matchLabel: string;
  canOpenInPhotos: boolean;
}

export interface BridgeResponse {
  ok: boolean;
  protocolVersion: number;
  appVersion?: string | null;
  error?: string | null;
  databaseAvailable?: boolean | null;
  mode?: string | null;
  visualSearchRan?: boolean | null;
  matchedCount?: number | null;
  elapsedMs?: number | null;
  stats?: BridgeStats | null;
  encoder?: BridgeEncoderStatus | null;
  notice?: string | null;
  noticeTitle?: string | null;
  items?: BridgePhotoItem[] | null;
}

export interface ExtensionPreferences {
  searchMode: SearchMode;
  autoStartCompanion: boolean;
  appPath?: string;
  resultLimit: string;
}

export interface EnvironmentStatus {
  appPath: string;
  appInstalled: boolean;
  binaryPath: string;
  databasePath: string;
  databaseAvailable: boolean;
  socketPath: string;
  socketReachable: boolean;
  pingResponse?: BridgeResponse;
}
