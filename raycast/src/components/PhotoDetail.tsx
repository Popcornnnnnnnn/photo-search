import {
  Action,
  ActionPanel,
  Color,
  Detail,
  Icon,
  Keyboard,
  open,
} from "@raycast/api";
import { pathToFileURL } from "node:url";
import { copyItemImage, openItemInPhotos } from "../lib/actions";
import {
  buildDeepLink,
  copyableImagePath,
  previewImagePath,
} from "../lib/protocol";
import type { BridgePhotoItem } from "../lib/types";

export interface PhotoDetailProps {
  item: BridgePhotoItem;
}

export function PhotoDetail({ item }: PhotoDetailProps) {
  const previewPath = previewImagePath(item);
  const copyPath = copyableImagePath(item);
  const revealPath = previewPath || copyPath;
  const title = item.shortCaption || item.filename;
  const safeAlt = title.replace(/[[\]]/g, "");

  const markdownSections: string[] = [];
  if (previewPath) {
    markdownSections.push(`![${safeAlt}](${pathToFileURL(previewPath).href})`);
  }
  markdownSections.push(`## ${title}`);
  if (item.detailedDescription) {
    markdownSections.push(item.detailedDescription);
  }

  return (
    <Detail
      navigationTitle={title}
      markdown={markdownSections.join("\n\n")}
      metadata={
        <Detail.Metadata>
          <Detail.Metadata.Label
            title="Type"
            text={
              item.isVideo && item.displayDuration
                ? `${item.displayAssetType} (${item.displayDuration})`
                : item.displayAssetType
            }
          />
          <Detail.Metadata.Label
            title="Captured"
            text={item.displayCapturedAt || "Unknown"}
          />
          {item.width && item.height ? (
            <Detail.Metadata.Label
              title="Dimensions"
              text={`${item.width} × ${item.height}`}
            />
          ) : null}
          {item.matchLabel ? (
            <Detail.Metadata.TagList title="Match">
              <Detail.Metadata.TagList.Item
                text={item.matchLabel}
                color={item.matchVisual ? Color.Blue : Color.Green}
              />
            </Detail.Metadata.TagList>
          ) : null}
          {item.scene ? (
            <Detail.Metadata.Label title="Scene" text={item.scene} />
          ) : null}
          {item.topics.length > 0 ? (
            <Detail.Metadata.TagList title="Topics">
              {item.topics.slice(0, 10).map((topic, index) => (
                <Detail.Metadata.TagList.Item
                  key={`${topic}-${index}`}
                  text={topic}
                />
              ))}
            </Detail.Metadata.TagList>
          ) : null}
          {item.entities.length > 0 ? (
            <Detail.Metadata.TagList title="Entities">
              {item.entities.slice(0, 12).map((entity, index) => (
                <Detail.Metadata.TagList.Item
                  key={`${entity}-${index}`}
                  text={entity}
                  color={Color.SecondaryText}
                />
              ))}
            </Detail.Metadata.TagList>
          ) : null}
          <Detail.Metadata.Separator />
          <Detail.Metadata.Label title="Filename" text={item.filename} />
        </Detail.Metadata>
      }
      actions={
        <ActionPanel>
          <ActionPanel.Section>
            {item.isVideo ? (
              <>
                <Action
                  title="Play in Photo Search"
                  icon={Icon.Play}
                  onAction={() => open(buildDeepLink("asset", { id: item.id }))}
                />
                {item.canOpenInPhotos ? (
                  <Action
                    title="Open in Apple Photos"
                    icon={Icon.AppWindow}
                    shortcut={Keyboard.Shortcut.Common.Open}
                    onAction={() => void openItemInPhotos(item)}
                  />
                ) : null}
                {copyPath ? (
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
                  onAction={() => open(buildDeepLink("asset", { id: item.id }))}
                />
                {item.canOpenInPhotos ? (
                  <Action
                    title="Open in Apple Photos"
                    icon={Icon.Image}
                    shortcut={Keyboard.Shortcut.Common.Open}
                    onAction={() => void openItemInPhotos(item)}
                  />
                ) : null}
              </>
            )}
          </ActionPanel.Section>
          <ActionPanel.Section>
            {item.shortCaption ? (
              <Action.CopyToClipboard
                title="Copy Caption"
                content={item.shortCaption}
                shortcut={Keyboard.Shortcut.Common.CopyName}
              />
            ) : null}
            {revealPath ? (
              <Action.ShowInFinder
                title="Show in Finder"
                path={revealPath}
                shortcut={Keyboard.Shortcut.Common.OpenWith}
              />
            ) : null}
          </ActionPanel.Section>
        </ActionPanel>
      }
    />
  );
}
