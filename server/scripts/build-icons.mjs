import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

const icons = [
  "hand-helping", "life-buoy", "wifi", "wifi-off", "triangle-alert", "ice-cream-cone", "check", "circle-check",
  "volume-2", "volume-x", "log-out", "battery", "battery-low", "battery-charging", "credit-card", "tablet",
  "store", "book-open", "clock", "refresh-cw", "circle-alert", "loader-circle", "chevron-down", "user",
];

const require = createRequire(import.meta.url);
const dir = join(dirname(require.resolve("lucide-static/package.json")), "icons");
const symbols = icons.map((name) => {
  const svg = readFileSync(join(dir, `${name}.svg`), "utf8");
  const body = svg.replace(/<!--[\s\S]*?-->/g, "").replace(/^[\s\S]*?<svg[^>]*>/, "").replace(/<\/svg>\s*$/, "").trim();
  return `<symbol id="${name}" viewBox="0 0 24 24">${body.replace(/\s*\n\s*/g, "")}</symbol>`;
});
const sprite = `<svg xmlns="http://www.w3.org/2000/svg">\n${symbols.join("\n")}\n</svg>\n`;
writeFileSync(new URL("../public/icons.svg", import.meta.url), sprite);
console.log(`Wrote ${icons.length} icons`);
