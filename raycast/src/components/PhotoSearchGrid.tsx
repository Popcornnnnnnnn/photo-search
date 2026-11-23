import {
  Action,
  ActionPanel,
  Grid,
  Icon,
  Keyboard,
  getPreferenceValues,
  open,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { useEffect, useState } from "react";
import { copyItemImage, openItemInPhotos } from "../lib/actions";
import {
  PHOTO_SEARCH_REPO_URL,
  buildDeepLink,
  defaultSocketPath,
  inspectEnvironment,
  offloadEncoder,
  previewImagePath,
  searchStage1,
  searchStage2Hybrid,
} from "../lib/protocol";
import type {
  BridgeEncoderStatus,
  BridgePhotoItem,
  BridgeStats,
  EnvironmentStatus,
  ExtensionPreferences,
  PhotoSection,
  PhotoTimeFilter,
  SearchMode,
} from "../lib/types";
import { PhotoDetail } from "./PhotoDetail";

const SECTION_OPTIONS: { value: PhotoSection; title: string; icon: Icon }[] = [
  { value: "all", title: "All Items", icon: Icon.AppWindowGrid2x2 },
  { value: "photo", title: "Photos", icon: Icon.Image },
  { value: "video", title: "Videos", icon: Icon.Video },
  { value: "uiScreenshot", title: "Screenshots", icon: Icon.Window },
  { value: "chatScreenshot", title: "Chats", icon: Icon.Message },
  { value: "document", title: "Documents", icon: Icon.Document },
  { value: "posterOrMeme", title: "Posters & Memes", icon: Icon.Tag },
];

const SECTION_TITLES: Record<PhotoSection, string> = {
  all: "Indexed Items",
  photo: "Photos",
  video: "Videos",
  uiScreenshot: "Screenshots",
  chatScreenshot: "Chats",
  document: "Documents",
  posterOrMeme: "Posters & Memes",
};

const TIME_OPTIONS: { value: PhotoTimeFilter; title: string }[] = [
  { value: "all", title: "Any Date" },
  { value: "last30Days", title: "Last 30 Days" },
  { value: "thisYear", title: "This Year" },
  { value: "lastYear", title: "Last Year" },
];

const TIME_LABELS: Record<PhotoTimeFilter, string> = {
  all: "Any Date",
  last30Days: "Last 30 Days",
  thisYear: "This Year",
  lastYear: "Last Year",
};

export interface PhotoSearchGridProps {
  fixedSection?: PhotoSection;
  excludeVideos?: boolean;
  searchBarPlaceholder?: string;
}

export function PhotoSearchGrid({
  fixedSection,
  excludeVideos = false,
  searchBarPlaceholder = "Search photos and videos by description, scene, or text…",
}: PhotoSearchGridProps) {
  const prefs = getPreferenceValues<ExtensionPreferences>();
  const limit = Number.parseInt(prefs.resultLimit || "40", 10) || 40;
  const fetchLimit = excludeVideos ? Math.min(limit + 20, 200) : limit;
  const autoStart = prefs.autoStartCompanion !== false;
  const visibleSectionOptions = excludeVideos
    ? SECTION_OPTIONS.filter((option) => option.value !== "video").map(
        (option) =>
          option.value === "all"
            ? { ...option, title: "All Photos & Images" }
            : option,
      )
    : SECTION_OPTIONS;

  const [searchText, setSearchText] = useState("");
  const [debouncedQuery, setDebouncedQuery] = useState("");
  const [section, setSection] = useState<PhotoSection>(fixedSection ?? "all");
  const [timeFilter, setTimeFilter] = useState<PhotoTimeFilter>("all");
  const [sessionMode, setSessionMode] = useState<SearchMode>(
    prefs.searchMode === "lexical" ? "lexical" : "hybrid",
  );
  const [refreshNonce, setRefreshNonce] = useState(0);

  const [items, setItems] = useState<BridgePhotoItem[]>([]);
  const [stats, setStats] = useState<BridgeStats | null>(null);
  const [encoder, setEncoder] = useState<BridgeEncoderStatus | null>(null);
  const [env, setEnv] = useState<EnvironmentStatus | null>(null);
  const [searchPhase, setSearchPhase] = useState<
    "idle" | "searching" | "enhancing" | "done" | "error"
  >("idle");
  const [visualRan, setVisualRan] = useState(false);
  const [elapsedMs, setElapsedMs] = useState<number | null>(null);
  const [errorMessage, setErrorMessage] = useState<string | null>(null);

  useEffect(() => {
    const trimmed = searchText.trim();
    if (!trimmed) {
      setDebouncedQuery("");
      return;
    }
    const timer = setTimeout(() => {
      setDebouncedQuery(trimmed);
    }, 180);
    return () => clearTimeout(timer);
  }, [searchText]);

  useEffect(() => {
    let active = true;
    const controller = new AbortController();

    async function runSearch() {
      const currentEnv = await inspectEnvironment(prefs.appPath);
      if (!active) return;
      setEnv(currentEnv);

      if (!currentEnv.appInstalled || !currentEnv.databaseAvailable) {
        setItems([]);
        setStats(currentEnv.pingResponse?.stats ?? null);
        setEncoder(currentEnv.pingResponse?.encoder ?? null);
        setSearchPhase("done");
        setErrorMessage(null);
        return;
      }

      setSearchPhase("searching");
      setErrorMessage(null);

      try {
        const filterItems = (raw: BridgePhotoItem[] | null | undefined) =>
          excludeVideos
            ? (raw ?? []).filter((item) => !item.isVideo).slice(0, limit)
            : (raw ?? []);

        const stage1 = await searchStage1({
          query: debouncedQuery,
          section,
          time: timeFilter,
          limit: fetchLimit,
          appPath: prefs.appPath,
          signal: controller.signal,
        });
        if (!active || controller.signal.aborted) return;

        if (!stage1.response.ok) {
          setItems([]);
          setErrorMessage(stage1.response.error ?? "Search failed.");
          setSearchPhase("error");
          return;
        }

        setItems(filterItems(stage1.response.items));
        setStats(stage1.response.stats ?? null);
        setEncoder(stage1.response.encoder ?? null);
        setVisualRan(Boolean(stage1.response.visualSearchRan));
        setElapsedMs(stage1.response.elapsedMs ?? null);

        if (!debouncedQuery || sessionMode !== "hybrid") {
          setSearchPhase("done");
          return;
        }

        setSearchPhase("enhancing");
        try {
          const stage2 = await searchStage2Hybrid({
            query: debouncedQuery,
            section,
            time: timeFilter,
            limit: fetchLimit,
            autoStartCompanion: autoStart,
            appPath: prefs.appPath,
            signal: controller.signal,
          });
          if (!active || controller.signal.aborted) return;

          if (stage2.ok) {
            setItems(filterItems(stage2.items));
            setStats(stage2.stats ?? null);
            setEncoder(stage2.encoder ?? null);
            setVisualRan(Boolean(stage2.visualSearchRan));
            setElapsedMs(stage2.elapsedMs ?? null);
            setEnv((prev) =>
              prev ? { ...prev, socketReachable: true } : prev,
            );
          }
          setSearchPhase("done");
        } catch (stage2Error) {
          if (!active || controller.signal.aborted) return;
          if ((stage2Error as Error)?.name === "AbortError") return;
          // Preserve fast lexical hits if the visual model is unavailable or offloaded.
          setSearchPhase("done");
        }
      } catch (stage1Error) {
        if (!active || controller.signal.aborted) return;
        if ((stage1Error as Error)?.name === "AbortError") return;
        setItems([]);
        setErrorMessage(
          stage1Error instanceof Error
            ? stage1Error.message
            : String(stage1Error),
        );
        setSearchPhase("error");
      }
    }

    void runSearch();

    return () => {
      active = false;
      controller.abort();
    };
  }, [
    debouncedQuery,
    section,
    timeFilter,
    sessionMode,
    refreshNonce,
    limit,
    fetchLimit,
    excludeVideos,
    autoStart,
    prefs.appPath,
  ]);

  const handleOffloadEncoder = async () => {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Offloading Visual Search Model…",
    });
    try {
      const res = await offloadEncoder(defaultSocketPath());
      if (res.encoder) setEncoder(res.encoder);
      toast.style = Toast.Style.Success;
      toast.title = "Visual Model Offloaded";
      toast.message =
        "Freed memory while keeping fast text & OCR search active.";
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Unable to Offload Model";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  };

  const sectionTitle = !debouncedQuery
    ? excludeVideos && section === "all"
      ? "Recent Photos & Images"
      : `Recent ${SECTION_TITLES[section]}`
    : `${items.length} ${items.length === 1 ? "Match" : "Matches"}`;

  const subtitleParts: string[] = [];
  if (searchPhase === "enhancing") {
    subtitleParts.push(
      encoder?.state === "offloaded" || encoder?.state === "loading"
        ? "Loading local visual model…"
        : "Enhancing with visual AI…",
    );
  } else {
    if (debouncedQuery) {
      subtitleParts.push(visualRan ? "Text + Visual AI" : "Text & OCR");
    } else {
      subtitleParts.push("Browse");
    }
    if (timeFilter !== "all") {
      subtitleParts.push(TIME_LABELS[timeFilter]);
    }
    if (elapsedMs != null) {
      subtitleParts.push(`${Math.round(elapsedMs)} ms`);
    }
    if (stats) {
      subtitleParts.push(`${stats.indexed.toLocaleString()} indexed`);
    }
  }

  const isLoading =
    searchPhase === "idle" ||
    searchPhase === "searching" ||
    searchPhase === "enhancing";

  return (
    <Grid
      columns={4}
      fit={Grid.Fit.Fill}
      aspectRatio="4/3"
      filtering={false}
      isLoading={isLoading}
      searchText={searchText}
      onSearchTextChange={setSearchText}
      searchBarPlaceholder={searchBarPlaceholder}
      searchBarAccessory={
        fixedSection ? undefined : (
          <Grid.Dropdown
            tooltip="Filter by Category"
            value={section}
            onChange={(value) => setSection(value as PhotoSection)}
          >
            {visibleSectionOptions.map((option) => (
              <Grid.Dropdown.Item
                key={option.value}
                title={option.title}
                value={option.value}
                icon={option.icon}
              />
            ))}
          </Grid.Dropdown>
        )
      }
    >
      {env && !env.appInstalled ? (
        <Grid.EmptyView
          icon={Icon.Download}
          title="Photo Search Companion App Required"
          description="Install Photo Search.app and build your local index to search photos and videos from Raycast."
          actions={
            <ActionPanel>
              <Action.OpenInBrowser
                title="Open Photo Search on GitHub"
                url={PHOTO_SEARCH_REPO_URL}
              />
              <Action
                title="Open Extension Preferences"
                icon={Icon.Gear}
                onAction={openExtensionPreferences}
              />
              <Action
                title="Retry Check"
                icon={Icon.ArrowClockwise}
                onAction={() => setRefreshNonce((n) => n + 1)}
              />
            </ActionPanel>
          }
        />
      ) : env && !env.databaseAvailable ? (
        <Grid.EmptyView
          icon={Icon.HardDrive}
          title="No Indexed Library Found"
          description="Open Photo Search to connect Apple Photos and index your photos and videos."
          actions={
            <ActionPanel>
              <Action.Open
                title="Open Photo Search"
                target={buildDeepLink("search", {
                  query: debouncedQuery,
                  section,
                  time: timeFilter,
                })}
              />
              <Action
                title="Refresh Index Status"
                icon={Icon.ArrowClockwise}
                onAction={() => setRefreshNonce((n) => n + 1)}
              />
            </ActionPanel>
          }
        />
      ) : items.length === 0 && !isLoading ? (
        <Grid.EmptyView
          icon={
            searchPhase === "error"
              ? Icon.ExclamationMark
              : Icon.MagnifyingGlass
          }
          title={searchPhase === "error" ? "Search Error" : "No Matching Items"}
          description={
            errorMessage ??
            (debouncedQuery
              ? `No matches for "${debouncedQuery}" under the active filters.`
              : "No indexed items matched the current filters.")
          }
          actions={
            <ActionPanel>
              {section !== (fixedSection ?? "all") || timeFilter !== "all" ? (
                <Action
                  title="Reset Filters"
                  icon={Icon.XMarkCircle}
                  onAction={() => {
                    if (!fixedSection) setSection("all");
                    setTimeFilter("all");
                  }}
                />
              ) : null}
              <Action.Open
                title="Open Query in Photo Search"
                target={buildDeepLink("search", {
                  query: debouncedQuery,
                  section,
                  time: timeFilter,
                })}
              />
              <Action
                title={
                  sessionMode === "hybrid"
                    ? "Switch to Fast Text-Only Mode"
                    : "Switch to Hybrid Visual Mode"
                }
                icon={Icon.Switch}
                onAction={() =>
                  setSessionMode((m) => (m === "hybrid" ? "lexical" : "hybrid"))
                }
              />
            </ActionPanel>
          }
        />
      ) : (
        <Grid.Section title={sectionTitle} subtitle={subtitleParts.join(" · ")}>
          {items.map((item) => {
            const previewPath = previewImagePath(item);
            const itemTitle = item.shortCaption || item.filename;
            const itemSubtitleParts = [
              item.isVideo && item.displayDuration
                ? `Video · ${item.displayDuration}`
                : item.displayAssetType,
              item.displayCapturedAt,
              item.matchLabel || undefined,
            ].filter(Boolean);

            return (
              <Grid.Item
                key={item.id}
                content={previewPath ? { source: previewPath } : Icon.Image}
                title={itemTitle}
                subtitle={itemSubtitleParts.join(" · ")}
                accessory={
                  item.isVideo
                    ? {
                        icon: Icon.Video,
                        tooltip: item.displayDuration
                          ? `Video (${item.displayDuration})`
                          : "Video",
                      }
                    : undefined
                }
                quickLook={
                  previewPath
                    ? {
                        path: previewPath,
                        name: itemTitle,
                      }
                    : undefined
                }
                actions={
                  <ActionPanel>
                    <ActionPanel.Section
                      title={item.isVideo ? "Video Actions" : "Photo Actions"}
                    >
                      {item.isVideo ? (
                        <>
                          <Action
                            title="Play in Photo Search"
                            icon={Icon.Play}
                            onAction={() =>
                              void open(buildDeepLink("asset", { id: item.id }))
                            }
                          />
                          {item.canOpenInPhotos ? (
                            <Action
                              title="Open in Apple Photos"
                              icon={Icon.AppWindow}
                              shortcut={Keyboard.Shortcut.Common.Open}
                              onAction={() => void openItemInPhotos(item)}
                            />
                          ) : null}
                          <Action.Push
                            title="Inspect Details"
                            icon={Icon.Info}
                            shortcut={{ modifiers: ["cmd"], key: "i" }}
                            target={<PhotoDetail item={item} />}
                          />
                          {previewPath ? (
                            <Action
                              title="Copy Poster Frame"
                              icon={Icon.Clipboard}
                              shortcut={Keyboard.Shortcut.Common.Copy}
                              onAction={() => void copyItemImage(item)}
                            />
                          ) : null}
                        </>
                      ) : (
                        <>
                          <Action
                            title="Copy Image"
                            icon={Icon.Clipboard}
                            onAction={() => void copyItemImage(item)}
                          />
                          <Action
                            title="Open in Photo Search"
                            icon={Icon.AppWindow}
                            shortcut={{ modifiers: ["cmd"], key: "return" }}
                            onAction={() =>
                              void open(buildDeepLink("asset", { id: item.id }))
                            }
                          />
                          {item.canOpenInPhotos ? (
                            <Action
                              title="Open in Apple Photos"
                              icon={Icon.Image}
                              shortcut={Keyboard.Shortcut.Common.Open}
                              onAction={() => void openItemInPhotos(item)}
                            />
                          ) : null}
                          <Action.Push
                            title="Inspect Details"
                            icon={Icon.Info}
                            shortcut={{ modifiers: ["cmd"], key: "i" }}
                            target={<PhotoDetail item={item} />}
                          />
                        </>
                      )}
                      {previewPath ? (
                        <Action.ToggleQuickLook
                          title="Toggle Quick Look"
                          shortcut={Keyboard.Shortcut.Common.ToggleQuickLook}
                        />
                      ) : null}
                    </ActionPanel.Section>

                    <ActionPanel.Section title="Search & Filters">
                      <ActionPanel.Submenu
                        title="Time Filter"
                        icon={Icon.Calendar}
                      >
                        {TIME_OPTIONS.map((option) => (
                          <Action
                            key={option.value}
                            title={option.title}
                            icon={
                              timeFilter === option.value
                                ? Icon.CheckCircle
                                : Icon.Circle
                            }
                            onAction={() => setTimeFilter(option.value)}
                          />
                        ))}
                      </ActionPanel.Submenu>
                      <Action
                        title={
                          sessionMode === "hybrid"
                            ? "Switch to Fast Text-Only Mode"
                            : "Switch to Hybrid Visual Mode"
                        }
                        icon={Icon.Switch}
                        shortcut={{ modifiers: ["cmd", "shift"], key: "m" }}
                        onAction={() =>
                          setSessionMode((m) =>
                            m === "hybrid" ? "lexical" : "hybrid",
                          )
                        }
                      />
                      <Action
                        title="Open Query in Photo Search"
                        icon={Icon.MagnifyingGlass}
                        shortcut={{ modifiers: ["cmd", "opt"], key: "o" }}
                        onAction={() =>
                          void open(
                            buildDeepLink("search", {
                              query: debouncedQuery,
                              section,
                              time: timeFilter,
                            }),
                          )
                        }
                      />
                    </ActionPanel.Section>

                    <ActionPanel.Section title="Utilities">
                      {item.shortCaption ? (
                        <Action.CopyToClipboard
                          title="Copy Caption"
                          content={item.shortCaption}
                          shortcut={Keyboard.Shortcut.Common.CopyName}
                        />
                      ) : null}
                      {previewPath ? (
                        <Action.ShowInFinder
                          title="Show in Finder"
                          path={previewPath}
                          shortcut={Keyboard.Shortcut.Common.OpenWith}
                        />
                      ) : null}
                      {encoder?.state === "ready" ? (
                        <Action
                          title="Offload Visual Model"
                          icon={Icon.MemoryChip}
                          onAction={() => void handleOffloadEncoder()}
                        />
                      ) : null}
                      <Action
                        title="Refresh Results"
                        icon={Icon.ArrowClockwise}
                        shortcut={Keyboard.Shortcut.Common.Refresh}
                        onAction={() => setRefreshNonce((n) => n + 1)}
                      />
                    </ActionPanel.Section>
                  </ActionPanel>
                }
              />
            );
          })}
        </Grid.Section>
      )}
    </Grid>
  );
}
