/// The captured native window contour, not a circular border radius. JPEG flattens the outside to white; these
/// profiles follow that matte with only a one-source-pixel inset. Coordinates are measured from each corner.
type Profile = { width: number; height: number; edge: number[] };
const workspace: Profile = { width: 2600, height: 1520, edge: [63, 46, 40, 36, 33, 31, 28, 27, 25, 23, 22, 21, 19, 18, 17, 16, 15, 14, 13, 13, 12, 11, 10, 10, 9, 9, 8, 7, 7, 7, 6, 6, 5, 5, 5, 4, 4, 4, 4, 3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0] };
const connections: Profile = { width: 2000, height: 1280, edge: [36, 26, 22, 19, 17, 15, 14, 13, 12, 10, 10, 9, 8, 7, 6, 6, 5, 5, 4, 4, 4, 3, 3, 3, 2, 2, 2, 2, 2, 2, 2, 2, 2, 0] };

export type WindowShape = "workspace" | "connections";

/// A mirrored outline of the recorded native corners in percentage coordinates, so camera transforms scale it.
export const nativeWindowClip = (shape: WindowShape): string => {
  const { width, height, edge } = shape === "connections" ? connections : workspace;
  const corner = edge.map((x, y) => [x / width * 100, y / height * 100] as const);
  const points = [
    ...corner.slice().reverse(),
    ...corner.map(([x, y]) => [100 - x, y]),
    ...corner.slice().reverse().map(([x, y]) => [100 - x, 100 - y]),
    ...corner.map(([x, y]) => [x, 100 - y]),
  ];
  return `polygon(${points.map(([x, y]) => `${x}% ${y}%`).join(", ")})`;
};
