// Draws the dashboard's app icons (the CronWatch clock on the dark rounded
// square of cronwatch.dev's favicon) and writes them into the SDK, the gem,
// the Python, PHP and Go packages as constants, so the dashboard serves them
// from memory with no files and no dependencies, and into the Rust crate as
// files it reads with include_bytes! (a published crate cannot reach outside
// its own directory):
//
//   packages/sdk/src/routes/icons.ts
//   packages/ruby/lib/cronwatch/web/icons.rb
//   packages/python/src/cronwatch/web/_icons.py
//   packages/php/src/Web/Icons.php
//   packages/go/routes_icons.go
//   packages/rust/cronwatch/src/web/assets/icons/*
//
// Run from the repo root after changing the drawing:
//
//   node scripts/make-dashboard-icons.mjs            write the five files and the Rust icons
//   node scripts/make-dashboard-icons.mjs --check    exit 1 when any is stale
//   node scripts/make-dashboard-icons.mjs --out DIR  also write the PNGs and SVGs to DIR
//
// The PNGs are rasterised here in plain JavaScript (signed distances, so the
// edges are antialiased) and encoded with node:zlib, so the output is the
// same byte for byte on every machine. Icon file names are served with a
// year-long cache: give a changed drawing new names.
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { crc32, deflateSync } from "node:zlib";

const ROOT = path.join(path.dirname(fileURLToPath(import.meta.url)), "..");
const TS_OUT = path.join(ROOT, "packages/sdk/src/routes/icons.ts");
const RB_OUT = path.join(ROOT, "packages/ruby/lib/cronwatch/web/icons.rb");
const PY_OUT = path.join(ROOT, "packages/python/src/cronwatch/web/_icons.py");
const PHP_OUT = path.join(ROOT, "packages/php/src/Web/Icons.php");
const GO_OUT = path.join(ROOT, "packages/go/routes_icons.go");
const RUST_OUT = path.join(ROOT, "packages/rust/cronwatch/src/web/assets/icons");

// The favicon's colours (site/src/assets/favicon.svg).
const SQUARE = [0x14, 0x14, 0x17];
const EDGE = [0x2a, 0x2a, 0x2f];
const HANDS = [0xf3, 0xf3, 0xf1];

const CLOCK = `<circle cx="20" cy="20" r="10.5" fill="none" stroke="#f3f3f1" stroke-width="2"/><path d="M20 12.5V20h6" fill="none" stroke="#f3f3f1" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>`;
/** The favicon: a rounded square with a faint edge, the clock inside. */
const ICON_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" rx="10" fill="#141417"/><rect x="0.5" y="0.5" width="39" height="39" rx="9.5" fill="none" stroke="#2a2a2f"/>${CLOCK}</svg>`;
/**
 * For masks (Android's circles and squircles, iOS's rounded square): the
 * square to every edge, the clock well inside the safe zone (the middle
 * circle of 80%; the clock reaches 11.5 of its 16).
 */
const MASKABLE_SVG = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 40"><rect width="40" height="40" fill="#141417"/>${CLOCK}</svg>`;

// Signed distances in the 40 unit box: negative inside.
function roundedRect(x, y, cx, cy, half, r) {
  const qx = Math.abs(x - cx) - half + r;
  const qy = Math.abs(y - cy) - half + r;
  return Math.hypot(Math.max(qx, 0), Math.max(qy, 0)) + Math.min(Math.max(qx, qy), 0) - r;
}
function segment(x, y, ax, ay, bx, by) {
  const dx = bx - ax, dy = by - ay;
  const t = Math.max(0, Math.min(1, ((x - ax) * dx + (y - ay) * dy) / (dx * dx + dy * dy)));
  return Math.hypot(x - ax - t * dx, y - ay - t * dy);
}
/** The clock: the ring (r 10.5) and the hands (M20 12.5V20h6), stroke 2 with round caps. */
function clock(x, y) {
  const ring = Math.abs(Math.hypot(x - 20, y - 20) - 10.5) - 1;
  const hands = Math.min(segment(x, y, 20, 12.5, 20, 20), segment(x, y, 20, 20, 26, 20)) - 1;
  return Math.min(ring, hands);
}
/**
 * Coverage of a pixel by a shape whose edge is `d` units away, for a pixel
 * `unit` units wide, in sixteenths: few enough shades that every icon fits a
 * palette, which keeps the PNGs small.
 */
const cover = (d, unit) => Math.round(Math.max(0, Math.min(1, 0.5 - d / unit)) * 16) / 16;
const mix = (a, b, t) => a.map((v, i) => v + (b[i] - v) * t);

/** RGBA rows for one icon, `size` pixels square. */
function draw(size, maskable) {
  const unit = 40 / size;
  const rows = [];
  for (let py = 0; py < size; py++) {
    const row = [];
    for (let px = 0; px < size; px++) {
      const x = (px + 0.5) * unit, y = (py + 0.5) * unit;
      let alpha = 1;
      let color = SQUARE;
      if (!maskable) {
        alpha = cover(roundedRect(x, y, 20, 20, 20, 10), unit);
        color = mix(color, EDGE, cover(Math.abs(roundedRect(x, y, 20, 20, 19.5, 9.5)) - 0.5, unit));
      }
      color = mix(color, HANDS, cover(clock(x, y), unit));
      row.push(...color.map(Math.round), Math.round(alpha * 255));
    }
    rows.push(row);
  }
  return rows;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, "latin1");
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, crc]);
}

/**
 * A PNG with a palette (and a tRNS chunk for the transparent corners), one
 * byte a pixel; each row takes the filter that leaves the least.
 */
function png(rows) {
  const size = rows.length;
  const palette = new Map();
  const lines = rows.map((row) => {
    const line = [];
    for (let i = 0; i < row.length; i += 4) {
      const key = row.slice(i, i + 4).join(",");
      if (!palette.has(key)) palette.set(key, palette.size);
      line.push(palette.get(key));
    }
    return line;
  });
  if (palette.size > 256) throw new Error(`${palette.size} colours do not fit a palette`);
  const colours = [...palette.keys()].map((key) => key.split(",").map(Number));
  const alphas = colours.map((c) => c[3]);
  while (alphas.length && alphas[alphas.length - 1] === 255) alphas.pop();
  const channels = 1;
  const raw = [];
  let previous = new Array(size * channels).fill(0);
  for (const line of lines) {
    const left = (i) => (i >= channels ? line[i - channels] : 0);
    const upLeft = (i) => (i >= channels ? previous[i - channels] : 0);
    const paeth = (i) => {
      const a = left(i), b = previous[i], c = upLeft(i);
      const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c);
      return pa <= pb && pa <= pc ? a : pb <= pc ? b : c;
    };
    const candidates = [
      line,
      line.map((v, i) => (v - left(i)) & 255),
      line.map((v, i) => (v - previous[i]) & 255),
      line.map((v, i) => (v - ((left(i) + previous[i]) >> 1)) & 255),
      line.map((v, i) => (v - paeth(i)) & 255),
    ];
    const cost = (c) => c.reduce((sum, v) => sum + (v < 128 ? v : 256 - v), 0);
    let best = 0;
    for (let f = 1; f < 5; f++) if (cost(candidates[f]) < cost(candidates[best])) best = f;
    raw.push(best, ...candidates[best]);
    previous = line;
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8;
  header[9] = 3;
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("PLTE", Buffer.from(colours.flatMap((c) => c.slice(0, 3)))),
    ...(alphas.length ? [chunk("tRNS", Buffer.from(alphas))] : []),
    chunk("IDAT", deflateSync(Buffer.from(raw), { level: 9, memLevel: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

const pngs = {
  "icon-192.png": png(draw(192, false)),
  "icon-512.png": png(draw(512, false)),
  "maskable-512.png": png(draw(512, true)),
  // iOS rounds the corners itself and shows transparency as black, so the
  // home screen icon is the full square.
  "apple-touch-icon.png": png(draw(180, true)),
};

const NOTE = "Generated by scripts/make-dashboard-icons.mjs. Do not edit; change the drawing there and run it.";
const b64 = (name) => pngs[name].toString("base64");
const ts = `// ${NOTE}

/** The favicon: the clock on a dark rounded square. */
export const ICON_SVG = ${JSON.stringify(ICON_SVG)};
/** The same square to every edge, for masks. */
export const MASKABLE_SVG = ${JSON.stringify(MASKABLE_SVG)};
/** PNGs, base64: 192 and 512 for the manifest, a maskable 512, and iOS's 180 home screen icon. */
export const ICON_192_PNG = ${JSON.stringify(b64("icon-192.png"))};
export const ICON_512_PNG = ${JSON.stringify(b64("icon-512.png"))};
export const MASKABLE_512_PNG = ${JSON.stringify(b64("maskable-512.png"))};
export const APPLE_TOUCH_ICON_PNG = ${JSON.stringify(b64("apple-touch-icon.png"))};
`;
const rb = `# frozen_string_literal: true

# ${NOTE}
module Cronwatch
  class Web
    # The dashboard's app icons, as the SDK's routes/icons.ts has them.
    module Icons
      # The favicon: the clock on a dark rounded square.
      ICON_SVG = ${JSON.stringify(ICON_SVG).replace(/#/g, "\\#")}
      # The same square to every edge, for masks.
      MASKABLE_SVG = ${JSON.stringify(MASKABLE_SVG).replace(/#/g, "\\#")}
      # PNGs, base64: 192 and 512 for the manifest, a maskable 512, and iOS's 180 home screen icon.
      ICON_192_PNG = "${b64("icon-192.png")}"
      ICON_512_PNG = "${b64("icon-512.png")}"
      MASKABLE_512_PNG = "${b64("maskable-512.png")}"
      APPLE_TOUCH_ICON_PNG = "${b64("apple-touch-icon.png")}"
    end
  end
end
`;
const py = `# ${NOTE}
"""The dashboard's app icons, as the SDK's routes/icons.ts has them."""

#: The favicon: the clock on a dark rounded square.
ICON_SVG = ${JSON.stringify(ICON_SVG)}
#: The same square to every edge, for masks.
MASKABLE_SVG = ${JSON.stringify(MASKABLE_SVG)}
#: PNGs, base64: 192 and 512 for the manifest, a maskable 512, and iOS's 180 home screen icon.
ICON_192_PNG = "${b64("icon-192.png")}"
ICON_512_PNG = "${b64("icon-512.png")}"
MASKABLE_512_PNG = "${b64("maskable-512.png")}"
APPLE_TOUCH_ICON_PNG = "${b64("apple-touch-icon.png")}"
`;

/** A PHP single-quoted string: only the backslash and the quote are special there. */
const phpString = (text) => `'${text.replace(/[\\']/g, (c) => `\\${c}`)}'`;
const php = `<?php

// ${NOTE}

declare(strict_types=1);

namespace Cronwatch\\Web;

/**
 * The dashboard's app icons, as the SDK's routes/icons.ts has them.
 *
 * @internal
 */
final class Icons
{
    /** The favicon: the clock on a dark rounded square. */
    public const ICON_SVG = ${phpString(ICON_SVG)};
    /** The same square to every edge, for masks. */
    public const MASKABLE_SVG = ${phpString(MASKABLE_SVG)};
    /** PNGs, base64: 192 and 512 for the manifest, a maskable 512, and iOS's 180 home screen icon. */
    public const ICON_192_PNG = '${b64("icon-192.png")}';
    public const ICON_512_PNG = '${b64("icon-512.png")}';
    public const MASKABLE_512_PNG = '${b64("maskable-512.png")}';
    public const APPLE_TOUCH_ICON_PNG = '${b64("apple-touch-icon.png")}';
}
`;

// Go's generated-file line comes first, so gofmt, vet and linters know it.
const go = `// Code generated by scripts/make-dashboard-icons.mjs. DO NOT EDIT.

package cronwatch

// ${NOTE}

// The dashboard's app icons, as the SDK's routes/icons.ts has them.
const (
	// iconSVG is the favicon: the clock on a dark rounded square.
	iconSVG = ${JSON.stringify(ICON_SVG)}
	// maskableSVG is the same square to every edge, for masks.
	maskableSVG = ${JSON.stringify(MASKABLE_SVG)}
	// PNGs, base64: 192 and 512 for the manifest, a maskable 512, and iOS's 180 home screen icon.
	icon192PNG        = "${b64("icon-192.png")}"
	icon512PNG        = "${b64("icon-512.png")}"
	maskable512PNG    = "${b64("maskable-512.png")}"
	appleTouchIconPNG = "${b64("apple-touch-icon.png")}"
)
`;

// The Rust crate's icons, each a file of its own, byte for byte.
const rustFiles = [...Object.entries(pngs), ["icon.svg", Buffer.from(ICON_SVG)], ["maskable.svg", Buffer.from(MASKABLE_SVG)]]
  .map(([name, data]) => [path.join(RUST_OUT, name), data]);

const outDir = process.argv.includes("--out") ? process.argv[process.argv.indexOf("--out") + 1] : null;
if (outDir) {
  mkdirSync(outDir, { recursive: true });
  for (const [name, data] of Object.entries(pngs)) writeFileSync(path.join(outDir, name), data);
  writeFileSync(path.join(outDir, "icon.svg"), ICON_SVG);
  writeFileSync(path.join(outDir, "maskable.svg"), MASKABLE_SVG);
}

const sizes = Object.entries(pngs).map(([name, data]) => `${name} ${data.length} bytes`).join(", ");
if (process.argv.includes("--check")) {
  const stale = [[TS_OUT, ts], [RB_OUT, rb], [PY_OUT, py], [PHP_OUT, php], [GO_OUT, go], ...rustFiles].filter(([file, text]) => {
    try {
      return typeof text === "string" ? readFileSync(file, "utf8") !== text : !readFileSync(file).equals(text);
    } catch {
      return true;
    }
  });
  if (stale.length) {
    console.error(`stale: ${stale.map(([f]) => path.relative(ROOT, f)).join(", ")}. Run node scripts/make-dashboard-icons.mjs`);
    process.exit(1);
  }
  console.log(`dashboard icons are up to date (${sizes})`);
} else {
  writeFileSync(TS_OUT, ts);
  writeFileSync(RB_OUT, rb);
  writeFileSync(PY_OUT, py);
  mkdirSync(path.dirname(PHP_OUT), { recursive: true });
  writeFileSync(PHP_OUT, php);
  writeFileSync(GO_OUT, go);
  mkdirSync(RUST_OUT, { recursive: true });
  for (const [file, data] of rustFiles) writeFileSync(file, data);
  const written = [TS_OUT, RB_OUT, PY_OUT, PHP_OUT, GO_OUT].map((file) => path.relative(ROOT, file)).join(", ");
  console.log(`wrote ${written} and ${path.relative(ROOT, RUST_OUT)} (${sizes})`);
}
