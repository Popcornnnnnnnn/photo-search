import { execFile } from "node:child_process";
import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import type {
  BridgePhotoItem,
  BridgeRequest,
  BridgeResponse,
  EnvironmentStatus,
  PhotoSection,
  PhotoTimeFilter,
} from "./types";

export const DEFAULT_APP_PATH = "/Applications/Photo Search.app";
export const PHOTO_SEARCH_REPO_URL =
  "https://github.com/Popcornnnnnnnn/photo-search";

export function defaultSocketPath(): string {
  return path.join(
    os.homedir(),
    "Library/Application Support/PhotoSearch/search.sock",
  );
}

export function defaultDatabasePath(): string {
  return path.join(
    os.homedir(),
    "Library/Application Support/PhotoSearch/photo-search.sqlite3",
  );
}

export function resolveAppPath(appPath?: string): string {
  const trimmed = appPath?.trim();
  return trimmed && trimmed.length > 0 ? trimmed : DEFAULT_APP_PATH;
}

export function companionBinaryPath(appPath?: string): string {
  return path.join(resolveAppPath(appPath), "Contents/MacOS/LiquidGlassDemo");
}

export function buildDeepLink(
  kind: "asset" | "search",
  params: {
    id?: string;
    query?: string;
    section?: PhotoSection;
    time?: PhotoTimeFilter;
  },
): string {
  if (kind === "asset") {
    const id = (params.id ?? "").trim();
    if (!id) {
      throw new Error("Missing asset ID for deep link.");
    }
    return `photosearch://asset/${encodeURIComponent(id)}`;
  }

  const url = new URL("photosearch://search");
  const trimmedQuery = (params.query ?? "").trim();
  if (trimmedQuery) {
    url.searchParams.set("q", trimmedQuery);
  }
  if (params.section && params.section !== "all") {
    url.searchParams.set("section", params.section);
  }
  if (params.time && params.time !== "all") {
    url.searchParams.set("time", params.time);
  }
  return url.toString();
}

export function sendSocketRequest(
  socketPath: string,
  payload: BridgeRequest,
  options: { timeoutMs?: number; signal?: AbortSignal } = {},
): Promise<BridgeResponse> {
  const timeoutMs = options.timeoutMs ?? 5000;
  const { signal } = options;

  if (signal?.aborted) {
    return Promise.reject(new DOMException("Aborted", "AbortError"));
  }

  return new Promise((resolve, reject) => {
    const socket = net.createConnection(socketPath);
    const chunks: Buffer[] = [];
    let settled = false;
    let timer: NodeJS.Timeout | undefined;

    const cleanup = () => {
      if (timer) {
        clearTimeout(timer);
        timer = undefined;
      }
      if (signal) {
        signal.removeEventListener("abort", onAbort);
      }
    };

    const finishError = (error: Error) => {
      if (settled) return;
      settled = true;
      cleanup();
      socket.destroy();
      reject(error);
    };

    const finishSuccess = (response: BridgeResponse) => {
      if (settled) return;
      settled = true;
      cleanup();
      socket.end();
      resolve(response);
    };

    const onAbort = () => {
      finishError(new DOMException("Aborted", "AbortError"));
    };

    if (signal) {
      signal.addEventListener("abort", onAbort, { once: true });
    }

    timer = setTimeout(() => {
      finishError(
        new Error(`Photo Search bridge timed out after ${timeoutMs} ms.`),
      );
    }, timeoutMs);

    socket.once("connect", () => {
      socket.write(`${JSON.stringify(payload)}\n`);
    });

    socket.on("data", (chunk: Buffer) => {
      const nl = chunk.indexOf(0x0a);
      if (nl !== -1) {
        chunks.push(chunk.subarray(0, nl));
        const raw = Buffer.concat(chunks).toString("utf8");
        try {
          finishSuccess(JSON.parse(raw) as BridgeResponse);
        } catch (error) {
          finishError(
            error instanceof Error ? error : new Error(String(error)),
          );
        }
        return;
      }
      chunks.push(chunk);
    });

    socket.once("end", () => {
      if (settled) return;
      const raw = Buffer.concat(chunks).toString("utf8").trim();
      if (!raw) {
        finishError(
          new Error(
            "Photo Search bridge closed connection without a response.",
          ),
        );
        return;
      }
      try {
        finishSuccess(JSON.parse(raw) as BridgeResponse);
      } catch (error) {
        finishError(error instanceof Error ? error : new Error(String(error)));
      }
    });

    socket.once("error", (error: Error) => {
      finishError(error);
    });
  });
}

function execFileAsync(
  file: string,
  args: string[],
  options: {
    timeoutMs?: number;
    maxBuffer?: number;
    signal?: AbortSignal;
  } = {},
): Promise<{ stdout: string; stderr: string }> {
  return new Promise((resolve, reject) => {
    execFile(
      file,
      args,
      {
        encoding: "utf8",
        timeout: options.timeoutMs ?? 15000,
        maxBuffer: options.maxBuffer ?? 16 * 1024 * 1024,
        signal: options.signal,
      },
      (error, stdout, stderr) => {
        if (error) {
          const enriched = error as Error & {
            stdout?: string;
            stderr?: string;
          };
          enriched.stdout = stdout;
          enriched.stderr = stderr;
          reject(enriched);
          return;
        }
        resolve({ stdout, stderr });
      },
    );
  });
}

export async function searchViaCLI(
  appPath: string | undefined,
  params: {
    query: string;
    section: PhotoSection;
    time: PhotoTimeFilter;
    limit: number;
    databasePath?: string;
  },
  signal?: AbortSignal,
): Promise<BridgeResponse> {
  const binary = companionBinaryPath(appPath);
  if (!fs.existsSync(binary)) {
    return {
      ok: false,
      protocolVersion: 1,
      error: `Companion binary not found at ${binary}.`,
      databaseAvailable: fs.existsSync(
        params.databasePath ?? defaultDatabasePath(),
      ),
    };
  }

  const args = [
    "--search-json",
    "--query",
    params.query,
    "--section",
    params.section,
    "--time",
    params.time,
    "--limit",
    String(params.limit),
  ];
  if (params.databasePath) {
    args.push("--db", params.databasePath);
  }

  try {
    const { stdout } = await execFileAsync(binary, args, {
      signal,
      timeoutMs: 15000,
    });
    return JSON.parse(stdout.trim()) as BridgeResponse;
  } catch (error) {
    const err = error as Error & { stdout?: string; name?: string };
    if (err.name === "AbortError") throw error;
    if (err.stdout) {
      try {
        return JSON.parse(err.stdout.trim()) as BridgeResponse;
      } catch {
        // fall through to generic error
      }
    }
    return {
      ok: false,
      protocolVersion: 1,
      error: err.message || "Failed to run Photo Search CLI.",
    };
  }
}

export async function inspectEnvironment(
  appPath?: string,
  socketPath = defaultSocketPath(),
  databasePath = defaultDatabasePath(),
): Promise<EnvironmentStatus> {
  const resolvedApp = resolveAppPath(appPath);
  const binaryPath = companionBinaryPath(resolvedApp);
  const appInstalled = fs.existsSync(binaryPath);
  const databaseAvailable = fs.existsSync(databasePath);

  let socketReachable = false;
  let pingResponse: BridgeResponse | undefined;
  if (fs.existsSync(socketPath)) {
    try {
      pingResponse = await sendSocketRequest(
        socketPath,
        { op: "ping" },
        { timeoutMs: 1200 },
      );
      socketReachable = pingResponse.ok;
    } catch {
      socketReachable = false;
    }
  }

  return {
    appPath: resolvedApp,
    appInstalled,
    binaryPath,
    databasePath,
    databaseAvailable,
    socketPath,
    socketReachable,
    pingResponse,
  };
}

export async function startCompanionInBackground(
  appPath?: string,
  socketPath = defaultSocketPath(),
  signal?: AbortSignal,
): Promise<boolean> {
  const resolvedApp = resolveAppPath(appPath);
  if (!fs.existsSync(companionBinaryPath(resolvedApp))) {
    return false;
  }

  await execFileAsync(
    "open",
    ["-g", "-j", "-a", resolvedApp, "--args", "--background"],
    {
      timeoutMs: 5000,
      signal,
    },
  );

  const deadline = Date.now() + 6000;
  while (Date.now() < deadline) {
    if (signal?.aborted) return false;
    if (fs.existsSync(socketPath)) {
      try {
        const pong = await sendSocketRequest(
          socketPath,
          { op: "ping" },
          { timeoutMs: 800, signal },
        );
        if (pong.ok) return true;
      } catch (error) {
        if ((error as Error)?.name === "AbortError") throw error;
      }
    }
    await new Promise((r) => setTimeout(r, 250));
  }
  return false;
}

export async function searchStage1(params: {
  query: string;
  section: PhotoSection;
  time: PhotoTimeFilter;
  limit: number;
  appPath?: string;
  socketPath?: string;
  databasePath?: string;
  signal?: AbortSignal;
}): Promise<{ response: BridgeResponse; viaSocket: boolean }> {
  const socketPath = params.socketPath ?? defaultSocketPath();
  if (fs.existsSync(socketPath)) {
    try {
      const response = await sendSocketRequest(
        socketPath,
        {
          op: "search",
          query: params.query,
          section: params.section,
          time: params.time,
          limit: params.limit,
          mode: "lexical",
          loadEncoder: false,
        },
        { timeoutMs: 4000, signal: params.signal },
      );
      if (response.ok || response.databaseAvailable === false) {
        return { response, viaSocket: true };
      }
    } catch (error) {
      if ((error as Error)?.name === "AbortError") throw error;
      // Stale or restarting socket: fall back to direct CLI query seamlessly.
    }
  }

  const response = await searchViaCLI(
    params.appPath,
    {
      query: params.query,
      section: params.section,
      time: params.time,
      limit: params.limit,
      databasePath: params.databasePath,
    },
    params.signal,
  );
  return { response, viaSocket: false };
}

export async function searchStage2Hybrid(params: {
  query: string;
  section: PhotoSection;
  time: PhotoTimeFilter;
  limit: number;
  autoStartCompanion: boolean;
  appPath?: string;
  socketPath?: string;
  signal?: AbortSignal;
}): Promise<BridgeResponse> {
  const socketPath = params.socketPath ?? defaultSocketPath();
  let reachable = false;
  if (fs.existsSync(socketPath)) {
    try {
      const pong = await sendSocketRequest(
        socketPath,
        { op: "ping" },
        { timeoutMs: 1200, signal: params.signal },
      );
      reachable = pong.ok;
    } catch (error) {
      if ((error as Error)?.name === "AbortError") throw error;
      reachable = false;
    }
  }

  if (!reachable && params.autoStartCompanion) {
    reachable = await startCompanionInBackground(
      params.appPath,
      socketPath,
      params.signal,
    );
  }

  if (!reachable) {
    return {
      ok: false,
      protocolVersion: 1,
      error: "Photo Search companion bridge is not running.",
    };
  }

  return sendSocketRequest(
    socketPath,
    {
      op: "search",
      query: params.query,
      section: params.section,
      time: params.time,
      limit: params.limit,
      mode: "hybrid",
      loadEncoder: true,
    },
    { timeoutMs: 120000, signal: params.signal },
  );
}

export async function loadEncoder(
  socketPath = defaultSocketPath(),
  signal?: AbortSignal,
): Promise<BridgeResponse> {
  return sendSocketRequest(
    socketPath,
    { op: "load" },
    { timeoutMs: 180000, signal },
  );
}

export async function offloadEncoder(
  socketPath = defaultSocketPath(),
  signal?: AbortSignal,
): Promise<BridgeResponse> {
  return sendSocketRequest(
    socketPath,
    { op: "offload" },
    { timeoutMs: 15000, signal },
  );
}

export async function openInPhotosViaBridge(
  assetId: string,
  socketPath = defaultSocketPath(),
  signal?: AbortSignal,
): Promise<BridgeResponse> {
  return sendSocketRequest(
    socketPath,
    { op: "open-in-photos", assetId },
    { timeoutMs: 6000, signal },
  );
}

export function previewImagePath(item: BridgePhotoItem): string | undefined {
  for (const candidate of [item.thumbnailPath, item.filePath]) {
    if (candidate && fs.existsSync(candidate)) return candidate;
  }
  return item.thumbnailPath || item.filePath || undefined;
}

export function copyableImagePath(item: BridgePhotoItem): string | undefined {
  const candidates = item.isVideo
    ? [item.thumbnailPath]
    : [item.filePath, item.thumbnailPath];
  for (const candidate of candidates) {
    if (candidate && fs.existsSync(candidate)) return candidate;
  }
  return undefined;
}

export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return "0 B";
  const gb = bytes / (1024 * 1024 * 1024);
  if (gb >= 1) return `${gb.toFixed(1)} GB`;
  const mb = bytes / (1024 * 1024);
  if (mb >= 1) return `${Math.round(mb)} MB`;
  return `${Math.round(bytes / 1024)} KB`;
}
