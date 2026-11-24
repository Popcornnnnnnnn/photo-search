import {
  Clipboard,
  getPreferenceValues,
  showHUD,
  showToast,
  Toast,
} from "@raycast/api";
import {
  copyableImagePath,
  defaultSocketPath,
  inspectEnvironment,
  openInPhotosViaBridge,
  startCompanionInBackground,
} from "./protocol";
import type { BridgePhotoItem, ExtensionPreferences } from "./types";

export async function copyItemImage(item: BridgePhotoItem): Promise<void> {
  const file = copyableImagePath(item);
  if (!file) {
    await showToast({
      style: Toast.Style.Failure,
      title: "Preview File Not Found",
      message: "The local preview for this item is missing on disk.",
    });
    return;
  }
  await Clipboard.copy({ file });
  await showHUD(
    item.isVideo ? "Copied Video Poster Frame" : "Copied Image to Clipboard",
  );
}

export async function openItemInPhotos(item: BridgePhotoItem): Promise<void> {
  const prefs = getPreferenceValues<ExtensionPreferences>();
  const toast = await showToast({
    style: Toast.Style.Animated,
    title: "Opening in Apple Photos…",
  });

  try {
    const socketPath = defaultSocketPath();
    const env = await inspectEnvironment(prefs.appPath, socketPath);
    if (!env.socketReachable) {
      if (prefs.autoStartCompanion !== false && env.appInstalled) {
        const started = await startCompanionInBackground(
          prefs.appPath,
          socketPath,
        );
        if (!started) {
          throw new Error(
            "Could not connect to the Photo Search companion bridge.",
          );
        }
      } else {
        throw new Error(
          "Open Photo Search.app first to jump directly to Apple Photos.",
        );
      }
    }

    const res = await openInPhotosViaBridge(item.id, socketPath);
    if (!res.ok) {
      throw new Error(res.error || "Apple Photos could not open this item.");
    }
    toast.hide();
  } catch (error) {
    toast.style = Toast.Style.Failure;
    toast.title = "Unable to Open in Apple Photos";
    toast.message = error instanceof Error ? error.message : String(error);
  }
}
