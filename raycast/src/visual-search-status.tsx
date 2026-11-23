import {
  Action,
  ActionPanel,
  Color,
  Icon,
  Keyboard,
  List,
  getPreferenceValues,
  open,
  openExtensionPreferences,
  showToast,
  Toast,
} from "@raycast/api";
import { useCallback, useEffect, useState } from "react";
import {
  PHOTO_SEARCH_REPO_URL,
  buildDeepLink,
  defaultSocketPath,
  formatBytes,
  inspectEnvironment,
  loadEncoder,
  offloadEncoder,
  startCompanionInBackground,
} from "./lib/protocol";
import type { EnvironmentStatus, ExtensionPreferences } from "./lib/types";

export default function Command() {
  const prefs = getPreferenceValues<ExtensionPreferences>();
  const [env, setEnv] = useState<EnvironmentStatus | null>(null);
  const [isLoading, setIsLoading] = useState(true);

  const refresh = useCallback(async () => {
    setIsLoading(true);
    try {
      const next = await inspectEnvironment(prefs.appPath);
      setEnv(next);
    } finally {
      setIsLoading(false);
    }
  }, [prefs.appPath]);

  useEffect(() => {
    void refresh();
  }, [refresh]);

  const handleStartBridge = async () => {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Starting Photo Search Bridge…",
    });
    try {
      const ok = await startCompanionInBackground(
        prefs.appPath,
        defaultSocketPath(),
      );
      if (!ok) throw new Error("Companion socket did not become reachable.");
      toast.style = Toast.Style.Success;
      toast.title = "Companion Bridge Ready";
      await refresh();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Failed to Start Bridge";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  };

  const handleWarmUp = async () => {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Loading Local Visual Model (~4.6 GB)…",
    });
    try {
      const sock = defaultSocketPath();
      if (!env?.socketReachable) {
        const started = await startCompanionInBackground(prefs.appPath, sock);
        if (!started)
          throw new Error("Could not start Photo Search companion bridge.");
      }
      const res = await loadEncoder(sock);
      if (!res.ok) throw new Error(res.error || "Failed to load encoder.");
      toast.style = Toast.Style.Success;
      toast.title = "Visual Model Ready";
      toast.message = res.encoder?.residentBytes
        ? `${formatBytes(res.encoder.residentBytes)} resident`
        : undefined;
      await refresh();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Warm-Up Failed";
      toast.message = error instanceof Error ? error.message : String(error);
      await refresh();
    }
  };

  const handleOffload = async () => {
    const toast = await showToast({
      style: Toast.Style.Animated,
      title: "Offloading Visual Model…",
    });
    try {
      const res = await offloadEncoder(defaultSocketPath());
      if (!res.ok) throw new Error(res.error || "Failed to offload encoder.");
      toast.style = Toast.Style.Success;
      toast.title = "Visual Model Offloaded";
      await refresh();
    } catch (error) {
      toast.style = Toast.Style.Failure;
      toast.title = "Offload Failed";
      toast.message = error instanceof Error ? error.message : String(error);
    }
  };

  const ping = env?.pingResponse;
  const stats = ping?.stats;
  const encoder = ping?.encoder;

  let encoderLabel = "Unknown (Bridge Offline)";
  let encoderColor = Color.SecondaryText;
  if (encoder) {
    if (!encoder.available || encoder.state === "unavailable") {
      encoderLabel = "Unavailable";
      encoderColor = Color.Red;
    } else if (encoder.state === "ready") {
      encoderLabel = `Ready (${formatBytes(encoder.residentBytes)} in RAM)`;
      encoderColor = Color.Green;
    } else if (encoder.state === "loading") {
      encoderLabel = `Loading (${Math.round(encoder.loadProgress * 100)}%)`;
      encoderColor = Color.Orange;
    } else {
      encoderLabel = "Offloaded (0 B)";
      encoderColor = Color.Yellow;
    }
  }

  return (
    <List isLoading={isLoading}>
      <List.Section title="Companion App & Index">
        <List.Item
          icon={Icon.AppWindow}
          title="Photo Search.app"
          subtitle={env?.appPath ?? "/Applications/Photo Search.app"}
          accessories={[
            {
              tag: {
                value: env?.appInstalled
                  ? ping?.appVersion || "Installed"
                  : "Not Installed",
                color: env?.appInstalled ? Color.Green : Color.Red,
              },
            },
          ]}
          actions={
            <ActionPanel>
              {env?.appInstalled ? (
                <Action
                  title="Open Photo Search"
                  icon={Icon.AppWindow}
                  onAction={() => void open(buildDeepLink("search", {}))}
                />
              ) : (
                <Action.OpenInBrowser
                  title="Open Photo Search on GitHub"
                  url={PHOTO_SEARCH_REPO_URL}
                />
              )}
              <Action
                title="Open Extension Preferences"
                icon={Icon.Gear}
                onAction={openExtensionPreferences}
              />
              <Action
                title="Refresh Status"
                icon={Icon.ArrowClockwise}
                shortcut={Keyboard.Shortcut.Common.Refresh}
                onAction={() => void refresh()}
              />
            </ActionPanel>
          }
        />

        <List.Item
          icon={Icon.Plug}
          title="Local Search Bridge Socket"
          subtitle={env?.socketPath}
          accessories={[
            {
              tag: {
                value: env?.socketReachable ? "Connected" : "Offline",
                color: env?.socketReachable ? Color.Green : Color.Orange,
              },
            },
          ]}
          actions={
            <ActionPanel>
              {!env?.socketReachable && env?.appInstalled ? (
                <Action
                  title="Start Companion Bridge in Background"
                  icon={Icon.Play}
                  onAction={() => void handleStartBridge()}
                />
              ) : null}
              <Action
                title="Refresh Status"
                icon={Icon.ArrowClockwise}
                shortcut={Keyboard.Shortcut.Common.Refresh}
                onAction={() => void refresh()}
              />
            </ActionPanel>
          }
        />

        <List.Item
          icon={Icon.HardDrive}
          title="Local Photos & Videos Index"
          subtitle={env?.databasePath}
          accessories={[
            stats
              ? {
                  text: `${stats.indexed.toLocaleString()} / ${stats.total.toLocaleString()} indexed`,
                }
              : {
                  tag: {
                    value: env?.databaseAvailable
                      ? "Available (Bridge Offline)"
                      : "Missing",
                    color: env?.databaseAvailable ? Color.Blue : Color.Red,
                  },
                },
          ]}
          actions={
            <ActionPanel>
              <Action
                title="Open Photo Search"
                icon={Icon.AppWindow}
                onAction={() => void open(buildDeepLink("search", {}))}
              />
              <Action
                title="Refresh Status"
                icon={Icon.ArrowClockwise}
                shortcut={Keyboard.Shortcut.Common.Refresh}
                onAction={() => void refresh()}
              />
            </ActionPanel>
          }
        />
      </List.Section>

      <List.Section title="Local Visual AI Encoder">
        <List.Item
          icon={Icon.MemoryChip}
          title="Qwen3-VL-Embedding-2B"
          subtitle={
            encoder?.loadStage ||
            "Powers hybrid semantic image and video search"
          }
          accessories={[{ tag: { value: encoderLabel, color: encoderColor } }]}
          actions={
            <ActionPanel>
              {encoder?.state === "ready" ? (
                <Action
                  title="Offload Visual Model"
                  icon={Icon.Eject}
                  onAction={() => void handleOffload()}
                />
              ) : env?.appInstalled ? (
                <Action
                  title="Warm up Visual Model"
                  icon={Icon.Bolt}
                  onAction={() => void handleWarmUp()}
                />
              ) : null}
              {encoder?.state !== "ready" &&
              env?.socketReachable &&
              encoder?.available ? (
                <Action
                  title="Offload Visual Model"
                  icon={Icon.Eject}
                  onAction={() => void handleOffload()}
                />
              ) : null}
              <Action
                title="Refresh Status"
                icon={Icon.ArrowClockwise}
                shortcut={Keyboard.Shortcut.Common.Refresh}
                onAction={() => void refresh()}
              />
            </ActionPanel>
          }
        />
      </List.Section>
    </List>
  );
}
