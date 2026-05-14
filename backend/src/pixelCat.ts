// Pixel-cat avatar generator — TypeScript port of the iOS
// `PixelCatGenerator` (see `non-bank/Views/PixelCatView.swift`). Produces
// an SVG string of the same 10×10 cat for the same friend ID, so a
// share-link recipient sees the **identical** avatar on the web preview
// as in the iOS app.
//
// Why a port (not pre-rendered images): pre-rendering would require
// every sharer to upload avatars per friend, with cache invalidation
// when a friend is renamed/upgraded. The generator is fully
// deterministic and tiny (~200 lines), so re-implementing it on the
// Worker is cleaner.
//
// Algorithm parity with the Swift original is verified by mirroring
// every public seed string verbatim — `adj + code`, `noun + code`, etc.
// Any drift here would produce a different cat on the web vs. in-app
// for the same ID, which immediately reads as "broken".

interface ParsedID {
  adj: string;
  noun: string;
  code: string;
}

interface HSL {
  hue: number;
  s: number;
  l: number;
}

interface RGB {
  r: number;
  g: number;
  b: number;
}

const GRID_SIZE = 10;

/// Build an SVG string for a friend ID. `size` is the rendered pixel
/// size (the SVG itself is unitless; the caller decides the px size in
/// CSS / the `width` attribute we emit).
export function pixelCatSVG(id: string, size: number, blackAndWhite = false): string {
  const cat = build(id, blackAndWhite);
  const cellSize = size / GRID_SIZE;
  const cornerRadius = size * 0.18;

  const bgRect = `<rect width="${size}" height="${size}" rx="${cornerRadius}" ry="${cornerRadius}" fill="${rgbToHex(cat.background)}" />`;

  const cellRects: string[] = [];
  for (let y = 0; y < GRID_SIZE; y++) {
    for (let x = 0; x < GRID_SIZE; x++) {
      const color = cat.grid[y][x];
      if (!color) continue;
      // `Math.ceil(cellSize)` matches the Swift Canvas which fills with
      // ceil(cell) — without it, sub-pixel gaps appear between cells
      // because integer-aligned rects don't quite tile a fractional
      // cell width.
      const w = Math.ceil(cellSize);
      cellRects.push(
        `<rect x="${(x * cellSize).toFixed(2)}" y="${(y * cellSize).toFixed(2)}" width="${w}" height="${w}" fill="${rgbToHex(color)}" />`,
      );
    }
  }

  // The clip-path handles rounded corners on the cells when they spill
  // over the rounded background edge. SVG `<clipPath>` is the
  // equivalent of the Swift `context.clip(to: bgPath)`.
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" shape-rendering="crispEdges">
<defs><clipPath id="r${djb2(id) & 0xFFFFFF}"><rect width="${size}" height="${size}" rx="${cornerRadius}" ry="${cornerRadius}" /></clipPath></defs>
${bgRect}
<g clip-path="url(#r${djb2(id) & 0xFFFFFF})">${cellRects.join("")}</g>
</svg>`;
}

// ─── Generator (mirror of Swift PixelCatGenerator.build) ──────────────

interface Cat {
  grid: (RGB | null)[][];
  background: RGB;
}

function build(id: string, blackAndWhite: boolean): Cat {
  const { adj, noun, code } = parseId(id);

  const fur = hslFrom(adj + code, 50, 92, 40, 70);
  const eye = hslFrom(noun + code, 70, 100, 50, 80);
  const nose = hslFrom(code + adj, 60, 100, 58, 78);
  const belly = hslFrom(noun + adj, 20, 55, 70, 90);
  const accent = hslFrom(code + noun + adj, 60, 100, 45, 72);

  const furDarkL = blackAndWhite
    ? Math.max(8, fur.l - 22)
    : Math.max(15, fur.l - 20);
  const furDark: HSL = { hue: fur.hue, s: fur.s, l: furDarkL };

  const bgHue = rng(code + "H", 360);
  const bgL = 10 + rng(code + "L", 10);
  const bgS = blackAndWhite ? 18 : 18 + rng(code + "S", 18);
  const bg: HSL = { hue: bgHue, s: bgS, l: bgL };

  const cFur = color(fur, blackAndWhite);
  const cFurDark = color(furDark, blackAndWhite);
  const cEye = color(eye, blackAndWhite);
  const cNose = color(nose, blackAndWhite);
  const cBelly = color(belly, blackAndWhite);
  const cAccent = color(accent, blackAndWhite);
  const cBg = color(bg, blackAndWhite);

  const hasCollar = rng(adj + "collar", 3) !== 0;
  const hasSpot = rng(adj + noun + code, 2) === 0;
  const tailSide = rng(noun + code + "tail", 2);
  const eyeShape = rng(noun + code + "shape", 3);
  const whiskerLen = rng(code + "wsk", 2);
  const earTip = rng(adj + "ear", 3);

  const g: (RGB | null)[][] = Array.from({ length: 10 }, () =>
    Array.from({ length: 10 }, () => null),
  );

  // Ears
  g[0][2] = cFur; g[0][3] = cFur; g[0][6] = cFur; g[0][7] = cFur;
  const et: RGB = earTip === 2 ? cAccent : earTip === 1 ? cFurDark : cFur;
  g[1][2] = et; g[1][3] = cFur; g[1][6] = cFur; g[1][7] = et;

  // Head
  for (let x = 2; x <= 7; x++) {
    g[2][x] = cFur; g[3][x] = cFur; g[4][x] = cFur;
  }

  // Eyes
  g[3][3] = cEye; g[3][6] = cEye;
  if (eyeShape === 2) { g[3][2] = cEye; g[3][7] = cEye; }
  if (eyeShape === 1) { g[3][3] = cFurDark; g[3][6] = cFurDark; }

  // Forehead spot
  if (hasSpot) g[2][4] = cFurDark;

  // Nose
  g[4][4] = cNose; g[4][5] = cNose;

  // Body
  for (let x = 2; x <= 7; x++) {
    g[5][x] = cFur; g[6][x] = cFur; g[7][x] = cFur;
  }

  // Belly patch
  g[6][4] = cBelly; g[6][5] = cBelly;
  g[7][3] = cBelly; g[7][4] = cBelly; g[7][5] = cBelly; g[7][6] = cBelly;

  // Collar
  if (hasCollar) {
    for (let x = 2; x <= 7; x++) g[5][x] = cAccent;
  }

  // Front paws
  g[8][3] = cFur; g[8][4] = cFur; g[8][5] = cFur; g[8][6] = cFur;

  // Tail
  if (tailSide === 0) {
    g[6][8] = cFur; g[7][8] = cFur; g[7][9] = cFur; g[8][9] = cFur;
  } else {
    g[6][1] = cFur; g[7][1] = cFur; g[7][0] = cFur; g[8][0] = cFur;
  }

  // Whiskers
  g[4][1] = cFurDark;
  g[4][8] = cFurDark;
  if (whiskerLen === 1) { g[4][0] = cFurDark; g[4][9] = cFurDark; }

  return { grid: g, background: cBg };
}

// ─── Hashing & RNG ────────────────────────────────────────────────────
//
// Must match the Swift `hash(_:)` exactly. Swift uses Int32 wrap-around
// arithmetic with `&*` / `&+`, which we replicate by masking to 32 bits
// and using `Math.imul` for the multiply. Result then has its sign
// stripped (`magnitude`) before the modulo.

function djb2(str: string): number {
  let h = 5381;
  for (let i = 0; i < str.length; i++) {
    // Match Swift's `for scalar in str.unicodeScalars` — JavaScript's
    // `codePointAt` returns the same scalar value (UTF-32 code point)
    // for the leading surrogate, and we step `i` past pairs explicitly.
    const cp = str.codePointAt(i)!;
    h = (Math.imul(31, h) + cp) | 0;
    if (cp > 0xFFFF) i++; // skip surrogate pair low half
  }
  // `Int(Int(h).magnitude)` — absolute value as unsigned 32-bit. Swift's
  // truncatingIfNeeded then magnitude gives a non-negative Int.
  return Math.abs(h);
}

function rng(seed: string, max: number): number {
  return djb2(seed) % max;
}

// ─── Colour ──────────────────────────────────────────────────────────

function hslFrom(seed: string, sMin: number, sMax: number, lMin: number, lMax: number): HSL {
  const hue = rng(seed + "H", 360);
  const s = sMin + rng(seed + "S", sMax - sMin);
  const l = lMin + rng(seed + "L", lMax - lMin);
  return { hue, s, l };
}

function color(hsl: HSL, bw: boolean): RGB {
  if (bw) {
    const warmBias = Math.sin((hsl.hue / 360) * Math.PI * 2) * 6;
    const grey = Math.round(Math.min(95, Math.max(8, hsl.l + warmBias)));
    return hslToRGB(0, 0, grey);
  }
  return hslToRGB(hsl.hue, hsl.s, hsl.l);
}

function hslToRGB(h: number, s: number, l: number): RGB {
  const sNorm = s / 100;
  const lNorm = l / 100;
  const c = (1 - Math.abs(2 * lNorm - 1)) * sNorm;
  const hPrime = h / 60;
  const x = c * (1 - Math.abs((hPrime % 2) - 1));

  let r = 0, g = 0, b = 0;
  switch (Math.floor(hPrime)) {
    case 0: r = c; g = x; b = 0; break;
    case 1: r = x; g = c; b = 0; break;
    case 2: r = 0; g = c; b = x; break;
    case 3: r = 0; g = x; b = c; break;
    case 4: r = x; g = 0; b = c; break;
    default: r = c; g = 0; b = x; break;
  }
  const m = lNorm - c / 2;
  return { r: r + m, g: g + m, b: b + m };
}

function rgbToHex(c: RGB): string {
  const r = clamp01(c.r), g = clamp01(c.g), b = clamp01(c.b);
  const toHex = (v: number) => Math.round(v * 255).toString(16).padStart(2, "0");
  return `#${toHex(r)}${toHex(g)}${toHex(b)}`;
}

function clamp01(v: number): number {
  return Math.max(0, Math.min(1, v));
}

// ─── ID parsing ──────────────────────────────────────────────────────

function parseId(id: string): ParsedID {
  const trimmed = id.trim();
  const parts = trimmed.split("-");
  if (parts.length < 3) {
    return { adj: trimmed, noun: trimmed, code: trimmed };
  }
  const code = parts[parts.length - 1];
  const noun = parts[parts.length - 2];
  const adj = parts.slice(0, parts.length - 2).join("-");
  return { adj, noun, code };
}
