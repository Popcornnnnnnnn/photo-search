import { PhotoSearchGrid } from "./components/PhotoSearchGrid";

export default function Command() {
  return (
    <PhotoSearchGrid
      fixedSection="video"
      searchBarPlaceholder="Search videos by action, scene, transcript, or visible text…"
    />
  );
}
