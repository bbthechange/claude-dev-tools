// CF.1 (claude-tools-7g0.1) — comment stripper for the §0.C source-discipline
// gate in run-differential.sh. A char-state scanner that tracks
// string/template/line/block-comment state, so a `//` or `/*` INSIDE a string
// or template literal NEVER truncates real code — the §0.C "no
// actor-discriminating branch" grep must be reliable, not fooled by prose in
// comments NOR weakened by stripping inside strings.
//
// Fail-closed: any read error, or empty output, exits non-zero so the harness
// treats it as a §0.C VIOLATION (a discipline gate must never fail open).
import { readFileSync } from "node:fs";

const SQ = String.fromCharCode(39); // '
const DQ = String.fromCharCode(34); // "
const BT = String.fromCharCode(96); // `

let src;
try {
  src = readFileSync(process.argv[2], "utf8");
} catch (e) {
  process.stderr.write(`strip-comments: cannot read ${process.argv[2]}: ${e.message}\n`);
  process.exit(2);
}

let out = "";
let i = 0;
let st = null; // null | "line" | "block" | SQ | DQ | BT
while (i < src.length) {
  const c = src[i];
  const d = src[i + 1];
  if (st === null) {
    if (c === "/" && d === "/") { st = "line"; i += 2; continue; }
    if (c === "/" && d === "*") { st = "block"; i += 2; continue; }
    if (c === SQ || c === DQ || c === BT) { st = c; out += c; i++; continue; }
    out += c; i++; continue;
  }
  if (st === "line") { if (c === "\n") { st = null; out += c; } i++; continue; }
  if (st === "block") { if (c === "*" && d === "/") { st = null; i += 2; } else i++; continue; }
  // inside a string / template literal — keep it verbatim
  out += c;
  if (c === "\\") { out += src[i + 1] || ""; i += 2; continue; }
  if (c === st) { st = null; }
  i++;
}

if (out.length === 0) process.exit(3);
process.stdout.write(out);
