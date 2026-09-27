// Coordinate math for Gemini Computer Use (spec §4.4).
// Gemini returns normalized coordinates in 0–1000 space; these scale them to
// pixels with flooring. Pure functions — no clamping here (executors clamp to
// their own viewport after calling these).
export function denormalizeX(x, screenWidth) {
  return Math.floor((Number(x) / 1000) * screenWidth);
}

export function denormalizeY(y, screenHeight) {
  return Math.floor((Number(y) / 1000) * screenHeight);
}
