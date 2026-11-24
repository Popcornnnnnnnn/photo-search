import { PhotoSearchGrid } from "./components/PhotoSearchGrid";

export default function Command() {
  return (
    <PhotoSearchGrid
      excludeVideos
      searchBarPlaceholder="Search photos, screenshots, and documents by description or text…"
    />
  );
}
