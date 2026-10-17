import { NOTO_SERIF_SEMIBOLD_WOFF2 } from "./staff-font";

const STYLE = String.raw`
@font-face{font-family:"Kiosk Serif";src:url(data:font/woff2;base64,${NOTO_SERIF_SEMIBOLD_WOFF2}) format("woff2");font-weight:400 700;font-display:block}
:root{--bg:#fff;--fg:#000;--accent:#000;--serif:"Kiosk Serif","Noto Serif",Georgia,serif}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--fg);font-family:var(--serif);font-size:24px;line-height:1.4;-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;overflow:hidden;user-select:none;touch-action:manipulation}
.screen{position:absolute;inset:0;background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;text-align:center}
.screen[hidden]{display:none}
h1{font-size:clamp(56px,10vw,140px);font-weight:700;line-height:1.05;margin:0 0 14px}
p{margin:0}
.sub{font-size:clamp(20px,2.4vw,32px)}
.ask{font-size:clamp(26px,3.4vw,44px);margin-bottom:22px}
.hint{font-size:clamp(18px,2vw,28px);margin-top:22px;min-height:1.4em}
.amount{font-size:clamp(88px,18vw,260px);font-weight:700;line-height:1;margin:0 0 18px;font-variant-numeric:lining-nums}
.glyph{width:clamp(56px,7vw,96px);height:clamp(56px,7vw,96px);margin-bottom:26px;fill:none;stroke:currentColor;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}
.actions{margin-top:48px;display:flex;flex-direction:column;align-items:center;gap:18px}
.btn,.link{outline:none;font:inherit;font-size:clamp(22px,2.6vw,34px);line-height:1.2;padding:.45em 1.3em;border:.09em solid var(--fg);background:var(--bg);color:var(--fg);cursor:pointer;transition:background .12s,color .12s,transform .12s}
.btn{background:var(--accent);color:var(--bg);border-color:var(--accent)}
.btn:hover{background:var(--bg);color:var(--fg);border-color:var(--fg)}
.link:hover{background:var(--fg);color:var(--bg)}
.btn:active,.link:active{transform:scale(.97)}
.btn:disabled,.link:disabled{opacity:.4;cursor:default;transform:none}
.small{font-size:clamp(15px,1.6vw,20px);padding:.4em 1em}
.corner{position:absolute;top:28px;left:32px}
#s-scan{justify-content:flex-start;padding-top:max(32px,5vh)}
#s-scan .ask{margin-bottom:0;padding:0 12vw}
#s-scan .hint{margin-top:2.4vh}
#s-scan .link{margin-top:1.8vh}
.finder{position:relative;width:100%;height:100%;border:.09em solid var(--fg);border-radius:28px;background:#f3f3f3;overflow:hidden;flex:none;isolation:isolate}
.finder video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .3s}
.finder video.live{opacity:1}
.finder video.mirror{transform:scaleX(-1)}
.finder canvas{position:absolute;inset:0;width:100%;height:100%}
.finder .sweep{position:absolute;left:0;right:0;top:0;height:3px;background:var(--accent);animation:sweep 2.4s ease-in-out infinite alternate;opacity:0;transition:opacity .3s}
.finder.live .sweep{opacity:.85}
.stage{position:relative;width:min(62vh,86vw);height:min(62vh,86vw);margin-top:3.2vh;flex:none}
.stage .finder{margin:0;transition:opacity .35s ease}
.stage.busy .finder,.kstage.busy .pad{opacity:0}
.checking{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;white-space:nowrap;font-size:clamp(26px,3.4vw,44px);opacity:0;pointer-events:none;transition:opacity .3s ease}
.busy>.checking{opacity:1;transition-delay:.25s}
.checking i{font-style:normal;animation:dot 1.2s infinite both}
.checking i:nth-child(2){animation-delay:.2s}
.checking i:nth-child(3){animation-delay:.4s}
#s-keypad{justify-content:flex-start;padding-top:max(28px,4.5vh)}
#s-keypad .ask{margin-bottom:0}
.digits{font-size:clamp(34px,5.4vw,64px);font-weight:700;line-height:1.1;margin:2.2vh 0 0;font-variant-numeric:tabular-nums lining-nums;white-space:pre;letter-spacing:.02em}
.digits .rest{opacity:.18}
.kstage{position:relative;margin-top:2.8vh;flex:none}
.pad{display:grid;grid-template-columns:repeat(3,min(13vh,17vw));gap:min(1.6vh,2vw);justify-content:center;transition:opacity .35s ease}
.key{font:inherit;font-size:clamp(30px,4.6vh,52px);height:min(10.5vh,14vw);border:.09em solid var(--fg);background:var(--bg);color:var(--fg);cursor:pointer;display:flex;align-items:center;justify-content:center;outline:none;transition:background .08s,color .08s,transform .08s;font-variant-numeric:lining-nums}
.key:active,.key.down{background:var(--fg);color:var(--bg);transform:scale(.96)}
.key.quiet{border-color:transparent}
.key.quiet:active,.key.quiet.down{background:var(--bg);color:var(--fg)}
.key svg{width:.85em;height:.85em;fill:none;stroke:currentColor;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}
.key:disabled{opacity:.25;cursor:default;transform:none}
.pad .btn{grid-column:1/-1;margin-top:min(1.2vh,1.5vw);font-size:clamp(22px,3.4vh,34px)}
@keyframes dot{0%,60%,100%{opacity:.2}30%{opacity:1}}
@keyframes sweep{from{top:0}to{top:calc(100% - 3px)}}
#warn{position:fixed;inset:0;z-index:20;background:rgba(255,255,255,.93);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:24px}
#warn[hidden]{display:none}
#warn .count{font-size:clamp(120px,24vw,320px);font-weight:700;line-height:1;margin:8px 0 22px;font-variant-numeric:lining-nums}
#cursor{display:none;position:fixed;left:0;top:0;width:56px;height:56px;pointer-events:none;z-index:9999;opacity:0;transition:opacity .2s;transform-origin:3px 3px;will-change:transform}
#cursor.on{opacity:1}
#cursor.down path{fill:var(--accent)}
#cursor path{fill:var(--bg);stroke:var(--fg);stroke-width:2.8;stroke-linejoin:round;stroke-linecap:round;transition:fill .1s}
@media (pointer:fine){*{cursor:none!important}#cursor{display:block}}
@media (prefers-reduced-motion:reduce){.finder .sweep,.checking i{animation:none}}
`;

const ICON_DELETE = `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M10 5a2 2 0 0 0-1.344.519l-6.328 5.74a1 1 0 0 0 0 1.481l6.328 5.741A2 2 0 0 0 10 19h10a2 2 0 0 0 2-2V7a2 2 0 0 0-2-2z"/><path d="m12 9 6 6"/><path d="m18 9-6 6"/></svg>`;

const ICON_CAMERA_OFF = `<svg class="glyph" viewBox="0 0 24 24" aria-hidden="true"><path d="M14.564 14.558a3 3 0 1 1-4.122-4.121"/><path d="m2 2 20 20"/><path d="M20 20H4a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h1.997a2 2 0 0 0 .819-.175"/><path d="M9.695 4.024A2 2 0 0 1 10.004 4h3.993a2 2 0 0 1 1.76 1.05l.486.9A2 2 0 0 0 18.003 7H20a2 2 0 0 1 2 2v7.344"/></svg>`;

export function giftCardShell(body: string, nonce: string, script: string): string {
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
<meta name="robots" content="noindex">
<title>Gift card balance</title>
<style nonce="${nonce}">${STYLE}</style>
</head>
<body>
${body}
<script nonce="${nonce}">${script}</script>
</body>
</html>`;
}

export function giftCardBody(): string {
  return `<svg id="cursor" viewBox="0 0 56 56" aria-hidden="true"><path d="M3.85 5.46 Q3.00 3.00 5.23 4.34 L41.92 26.38 Q44.14 27.72 42.12 29.36 L20.65 46.75 Q18.63 48.38 17.78 45.93 Z"/></svg>

<section class="screen" id="s-scan">
  <p class="ask">Hold your gift card up to the camera</p>
  <div class="stage" id="stage">
    <div class="finder" id="finder">
      <video id="video" playsinline muted></video>
      <canvas id="sim" hidden></canvas>
      <div class="sweep"></div>
    </div>
    <p class="checking" aria-live="polite">Checking your balance<i>.</i><i>.</i><i>.</i></p>
  </div>
  <p class="hint">Line up the barcode or QR code inside the square</p>
  <button class="link small" id="open-keypad">Enter card number</button>
</section>

<section class="screen" id="s-keypad" hidden>
  <button class="link small corner" id="back-keypad">Back</button>
  <p class="ask">Type the 16-digit card number</p>
  <p class="digits" id="kp-digits" aria-live="polite"></p>
  <div class="kstage" id="kstage">
    <div class="pad" id="pad">
      <button class="key" data-key="1">1</button><button class="key" data-key="2">2</button><button class="key" data-key="3">3</button>
      <button class="key" data-key="4">4</button><button class="key" data-key="5">5</button><button class="key" data-key="6">6</button>
      <button class="key" data-key="7">7</button><button class="key" data-key="8">8</button><button class="key" data-key="9">9</button>
      <span></span><button class="key" data-key="0">0</button><button class="key quiet" data-key="back" aria-label="Delete">${ICON_DELETE}</button>
      <button class="btn" id="kp-check" disabled>Check balance</button>
    </div>
    <p class="checking" aria-live="polite">Checking your balance<i>.</i><i>.</i><i>.</i></p>
  </div>
</section>

<section class="screen" id="s-result" hidden>
  <p class="ask" id="result-ask">Your gift card balance is</p>
  <p class="amount" id="result-amount"></p>
  <p class="sub" id="result-sub"></p>
  <div class="actions"><button class="btn" id="result-done">Done</button></div>
</section>

<section class="screen" id="s-error" hidden>
  <span id="error-icon"></span>
  <h1 id="error-title"></h1>
  <p class="sub" id="error-sub"></p>
  <div class="actions">
    <button class="btn" id="error-retry">Try again</button>
    <button class="link small" id="error-done">Start over</button>
  </div>
</section>

<section id="warn" hidden>
  <p class="ask">Are you still there?</p>
  <p class="count" id="warn-count">5</p>
  <p class="sub">Tap anywhere to keep going</p>
</section>
<template id="icon-camera-off">${ICON_CAMERA_OFF}</template>`;
}

export function giftCardScript(debug = false): string {
  return `const DEBUG = ${debug};` + String.raw`
const IDLE_MS = 20000, WARN_AT_MS = 15000, SCAN_EVERY_MS = 140, CAMERA_RETRY_MS = 3000;
const FORMATS = ["qr_code", "code_128", "code_39", "code_93", "ean_13", "ean_8", "itf", "codabar", "upc_a", "upc_e", "data_matrix", "pdf417", "aztec"];
const $ = (id) => document.getElementById(id);
const SCREENS = ["s-scan", "s-keypad", "s-result", "s-error"];
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

let current = "s-scan", resetting = false, swallowClick = 0, retryAction = null, lookupRun = 0;
let idleTimer = null, warnTimer = null, warnDeadline = 0;
let stream = null, cameraOpening = null, cameraRetry = null, scanTimer = null, scanRun = 0, busy = false;
let engine = null, zxingLoading = null;


const cur = $("cursor");
const c = { x: -100, y: -100, px: -100, py: -100, vx: 0, vy: 0, rot: 0, rv: 0, scale: 1, down: false, t: performance.now() };
const AXIS = { x: Math.cos(51 * Math.PI / 180), y: Math.sin(51 * Math.PI / 180) };
window.addEventListener("pointermove", (e) => { c.x = e.clientX; c.y = e.clientY; cur.classList.add("on"); }, { passive: true });
window.addEventListener("pointerdown", () => { c.down = true; cur.classList.add("down"); }, { passive: true });
window.addEventListener("pointerup", () => { c.down = false; cur.classList.remove("down"); }, { passive: true });
document.addEventListener("mouseleave", () => cur.classList.remove("on"));
(function tick(now) {
  const dt = Math.max(0.25, Math.min((now - c.t) / 16.7, 3)); c.t = now;
  const vx = (c.x - c.px) / dt, vy = (c.y - c.py) / dt;
  c.vx += (vx - c.vx) * 0.35; c.vy += (vy - c.vy) * 0.35;
  c.px = c.x; c.py = c.y;
  const lag = AXIS.y * c.vx - AXIS.x * c.vy;
  const target = Math.max(-28, Math.min(28, lag * 0.9));
  c.rv += ((target - c.rot) * 0.09 - c.rv * 0.22) * dt;
  c.rot += c.rv * dt;
  c.scale += ((c.down ? 0.82 : 1) - c.scale) * Math.min(1, 0.3 * dt);
  if (!isFinite(c.rot + c.rv + c.vx + c.vy)) { c.rot = c.rv = c.vx = c.vy = 0; }
  cur.style.transform = "translate(" + c.x + "px," + c.y + "px) rotate(" + c.rot.toFixed(2) + "deg) scale(" + c.scale.toFixed(3) + ")";
  requestAnimationFrame(tick);
})(performance.now());

function stopWarning() {
  clearInterval(warnTimer); warnTimer = null;
  $("warn").hidden = true;
}
function startWarning() {
  warnDeadline = Date.now() + (IDLE_MS - WARN_AT_MS);
  const paint = () => {
    const left = Math.ceil((warnDeadline - Date.now()) / 1000);
    if (left <= 0) { stopWarning(); reset(); return; }
    $("warn-count").textContent = String(left);
  };
  paint();
  $("warn").hidden = false;
  warnTimer = setInterval(paint, 100);
}
function bump() {
  clearTimeout(idleTimer); idleTimer = null;
  stopWarning();
  if (current !== "s-scan") idleTimer = setTimeout(startWarning, WARN_AT_MS);
}
function onActivity(e) {
  if (!$("warn").hidden) {
    e.stopPropagation(); e.preventDefault();
    swallowClick = Date.now() + 500;
    bump();
    return;
  }
  bump();
}
for (const type of ["pointerdown", "keydown", "touchstart"]) document.addEventListener(type, onActivity, true);
document.addEventListener("click", (e) => { if (Date.now() < swallowClick) { e.stopPropagation(); e.preventDefault(); } }, true);

function show(id) {
  const leaving = current;
  current = id;
  for (const s of SCREENS) $(s).hidden = s !== id;
  $("stage").classList.remove("busy");
  $("kstage").classList.remove("busy");
  if (leaving === "s-scan" && id !== "s-scan") stopScan();
  bump();
}

function swap(from, to, tone) {
  const f = $(from), t = $(to);
  t.hidden = false; t.style.zIndex = 2;
  const out = f.animate(
    [{ transform: "scale(1)", filter: "blur(0px)", opacity: 1 }, { transform: "scale(" + (tone === "back" ? 1.1 : 0.7) + ")", filter: "blur(12px)", opacity: 0 }],
    { duration: 320, easing: "cubic-bezier(.4, 0, 1, 1)", fill: "forwards" });
  t.animate(
    [{ transform: "scale(1.2)", filter: "blur(14px)", opacity: 0 }, { transform: "scale(1)", filter: "blur(0px)", opacity: 1 }],
    { duration: 380, easing: "cubic-bezier(0, 0, .2, 1)" });
  out.onfinish = () => { out.cancel(); t.style.zIndex = ""; show(to); };
  current = to;
  if (from === "s-scan") stopScan();
  bump();
}

function reset() {
  if (resetting) return;
  stopWarning();
  retryAction = null;
  const from = SCREENS.map($).find((el) => !el.hidden && el.id !== "s-scan");
  if (!from) { if (current !== "s-scan") { show("s-scan"); startScan(); } return; }
  resetting = true;
  stopScan();
  current = "s-scan";
  const out = from.animate(
    [{ transform: "scale(1)", filter: "blur(0px)", opacity: 1 }, { transform: "scale(1.1)", filter: "blur(14px)", opacity: 0 }],
    { duration: 380, easing: "cubic-bezier(.4, 0, 1, 1)", fill: "forwards" });
  out.onfinish = () => {
    show("s-scan"); out.cancel();
    startScan();
    const back = $("s-scan").animate(
      [{ transform: "scale(1.1)", filter: "blur(14px)", opacity: 0 }, { transform: "scale(1)", filter: "blur(0px)", opacity: 1 }],
      { duration: 420, easing: "cubic-bezier(0, 0, .2, 1)" });
    back.onfinish = () => { resetting = false; };
  };
}

$("result-done").onclick = reset;
$("error-done").onclick = reset;
$("error-retry").onclick = () => {
  const again = retryAction;
  retryAction = null;
  if (again) { again(); return; }
  $("s-error").hidden = true; swapToScan();
};

function swapToScan() {
  $("s-scan").hidden = false;
  $("s-error").hidden = true;
  show("s-scan");
  startScan();
}

function fail(kind) {
  const cases = {
    denied: ["Camera is turned off", "Allow camera access for this page, then try again. Or ask at the table.", true],
    nocamera: ["No camera found", "This screen can't see a camera. Type the card number instead, or ask at the table.", false],
    camera: ["Camera won't start", "Something else may be using it. Try again, or ask at the table.", true],
    notfound: ["Card not found", "We couldn't find that gift card. Check that it is the right card and try again.", true],
    network: ["Couldn't check right now", "Something went wrong on our end. Try again, or ask at the table.", true],
  };
  const [title, sub, retry] = cases[kind] || cases.network;
  $("error-icon").replaceChildren(kind === "denied" || kind === "nocamera" || kind === "camera" ? document.getElementById("icon-camera-off").content.cloneNode(true) : "");
  $("error-title").textContent = title;
  $("error-title").style.fontSize = "clamp(40px, 6.5vw, 96px)";
  $("error-sub").textContent = sub;
  $("error-retry").hidden = !retry;
  if (!retry) retryAction = null;
  if (current !== "s-error" && SCREENS.includes(current) && !$(current).hidden) swap(current, "s-error", "forward");
  else show("s-error");
}

function showResult(found, gan, from) {
  const active = found.state === "ACTIVE";
  const notes = { PENDING: "This card hasn't been activated yet. Ask at the table.", BLOCKED: "This card is blocked. Ask at the table.", DEACTIVATED: "This card has been turned off. Ask at the table." };
  if (active) {
    $("result-ask").textContent = "Your gift card balance is";
    $("result-amount").textContent = money.format(found.balanceCents / 100);
    $("result-sub").textContent = found.balanceCents === 0 ? "This card is empty." : "Thanks for supporting Tech Club.";
  } else {
    $("result-ask").textContent = "This card can't be used right now";
    $("result-amount").textContent = "";
    $("result-sub").textContent = notes[found.state] || "Ask at the table.";
  }
  swap(from, "s-result", "forward");
}

async function lookup(gan, from = "s-scan") {
  busy = true;
  const run = ++lookupRun;
  (from === "s-keypad" ? $("kstage") : $("stage")).classList.add("busy");
  const minimum = new Promise((resolve) => setTimeout(resolve, DEBUG ? 1500 : 600));
  let outcome;
  if (DEBUG) outcome = { balanceCents: DEMO_BALANCE_CENTS, state: "ACTIVE" };
  else try {
    const res = await fetch("/giftcard/balance", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ gan }) });
    outcome = res.ok ? await res.json() : res.status === 404 ? "notfound" : "network";
  } catch (e) {
    outcome = "network";
  }
  await minimum;
  busy = false;
  if (run !== lookupRun || current !== from) return;
  if (from === "s-keypad") retryAction = () => { $("kstage").classList.remove("busy"); swap("s-error", "s-keypad", "back"); };
  if (typeof outcome === "string") fail(outcome); else showResult(outcome, gan, from);
}

let typed = "";
function paintKeypad() {
  let done = "", left = "";
  for (let i = 0; i < 16; i++) {
    const gap = i && i % 4 === 0 ? " " : "";
    if (i < typed.length) done += gap + typed[i]; else left += gap + "\u2022";
  }
  const shown = document.createElement("span"), rest = document.createElement("span");
  shown.textContent = done; rest.className = "rest"; rest.textContent = left;
  $("kp-digits").replaceChildren(shown, rest);
  $("kp-check").disabled = typed.length !== 16;
  for (const k of $("pad").querySelectorAll("[data-key]")) k.disabled = k.dataset.key === "back" ? !typed.length : typed.length >= 16;
}
function press(key) {
  if (current !== "s-keypad" || busy) return;
  if (key === "back") typed = typed.slice(0, -1);
  else if (/^\d$/.test(key) && typed.length < 16) typed += key;
  paintKeypad();
}
function flash(key) {
  const el = $("pad").querySelector('[data-key="' + key + '"]');
  if (!el) return;
  el.classList.add("down");
  setTimeout(() => el.classList.remove("down"), 120);
}
function checkTyped() {
  if (current !== "s-keypad" || busy || typed.length !== 16) return;
  lookup(typed, "s-keypad");
}
function openKeypad(first) {
  if (current !== "s-scan" || busy || resetting) return;
  typed = first || "";
  paintKeypad();
  $("kstage").classList.remove("busy");
  swap("s-scan", "s-keypad", "forward");
}
$("open-keypad").onclick = () => openKeypad("");
$("back-keypad").onclick = () => { if (!busy) { typed = ""; swap("s-keypad", "s-scan", "back"); startScan(); } };
$("pad").addEventListener("click", (e) => { const k = e.target.closest("[data-key]"); if (k) press(k.dataset.key); });
$("kp-check").onclick = checkTyped;
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") { reset(); return; }
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  if (current === "s-scan" && /^\d$/.test(e.key)) { e.preventDefault(); openKeypad(e.key); return; }
  if (current !== "s-keypad") return;
  if (/^\d$/.test(e.key)) { e.preventDefault(); flash(e.key); press(e.key); }
  else if (e.key === "Backspace" || e.key === "Delete") { e.preventDefault(); flash("back"); press("back"); }
  else if (e.key === "Enter") { e.preventDefault(); checkTyped(); }
});

function extractGan(raw) {
  let text = String(raw);
  if (/^[\d\s-]+$/.test(text)) text = text.replace(/[\s-]/g, "");
  const m = text.match(/(?<!\d)\d{16}(?!\d)/);
  return m ? m[0] : null;
}

function loadZxing() {
  if (!zxingLoading) zxingLoading = new Promise((resolve, reject) => {
    const s = document.createElement("script");
    s.src = "/giftcard/zxing.js";
    s.onload = resolve; s.onerror = () => reject(new Error("zxing"));
    document.head.appendChild(s);
  });
  return zxingLoading;
}

async function makeEngine() {
  if (engine) return engine;
  if ("BarcodeDetector" in window) {
    try {
      const supported = await BarcodeDetector.getSupportedFormats();
      const formats = FORMATS.filter((f) => supported.includes(f));
      if (formats.length) {
        const detector = new BarcodeDetector({ formats });
        engine = { name: "native", detect: async (canvas) => (await detector.detect(canvas)).map((b) => b.rawValue) };
        return engine;
      }
    } catch (e) {}
  }
  await loadZxing();
  const Z = window.ZXing;
  const hints = new Map();
  hints.set(Z.DecodeHintType.POSSIBLE_FORMATS, [Z.BarcodeFormat.QR_CODE, Z.BarcodeFormat.CODE_128, Z.BarcodeFormat.CODE_39, Z.BarcodeFormat.CODE_93, Z.BarcodeFormat.EAN_13, Z.BarcodeFormat.EAN_8, Z.BarcodeFormat.ITF, Z.BarcodeFormat.CODABAR, Z.BarcodeFormat.UPC_A, Z.BarcodeFormat.UPC_E, Z.BarcodeFormat.DATA_MATRIX, Z.BarcodeFormat.PDF_417, Z.BarcodeFormat.AZTEC]);
  hints.set(Z.DecodeHintType.TRY_HARDER, true);
  const reader = new Z.MultiFormatReader();
  reader.setHints(hints);
  engine = {
    name: "zxing",
    detect: async (canvas) => {
      try {
        const bitmap = new Z.BinaryBitmap(new Z.HybridBinarizer(new Z.HTMLCanvasElementLuminanceSource(canvas)));
        return [reader.decode(bitmap).getText()];
      } catch (e) {
        return [];
      }
    },
  };
  return engine;
}

function stopScan() {
  scanRun++;
  lookupRun++;
  clearTimeout(scanTimer); scanTimer = null;
  busy = false;
}

function cameraErrorKind(e) {
  const name = e && e.name;
  return name === "NotAllowedError" || name === "SecurityError" ? "denied" : name === "NotFoundError" || name === "OverconstrainedError" ? "nocamera" : "camera";
}

function releaseCamera() {
  if (stream) { for (const t of stream.getTracks()) { t.onended = null; t.stop(); } stream = null; }
  const v = $("video");
  v.pause(); v.srcObject = null; v.classList.remove("live", "mirror");
  $("finder").classList.remove("live", "mirror");
}

function scheduleCameraRetry() {
  if (cameraRetry) return;
  cameraRetry = setTimeout(() => { cameraRetry = null; openCamera().catch(() => {}); }, CAMERA_RETRY_MS);
}

function openCamera() {
  if (stream && stream.getVideoTracks().some((t) => t.readyState === "live")) return Promise.resolve();
  if (cameraOpening) return cameraOpening;
  cameraOpening = (async () => {
    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) throw Object.assign(new Error("no camera"), { name: "NotFoundError" });
      releaseCamera();
      const media = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" }, width: { ideal: 1280 }, height: { ideal: 720 } } });
      stream = media;
      const track = media.getVideoTracks()[0];
      track.onended = () => { releaseCamera(); scheduleCameraRetry(); };
      try { await track.applyConstraints({ advanced: [{ focusMode: "continuous" }] }); } catch (e) {}
      const mirror = track.getSettings().facingMode !== "environment";
      const v = $("video");
      v.srcObject = media;
      try { await v.play(); } catch (e) {}
      v.classList.toggle("mirror", mirror); $("finder").classList.toggle("mirror", mirror);
      v.classList.add("live"); $("finder").classList.add("live");
    } catch (e) {
      scheduleCameraRetry();
      throw e;
    } finally {
      cameraOpening = null;
    }
  })();
  return cameraOpening;
}

async function startScan() {
  stopScan();
  const run = scanRun;
  if (DEBUG) { simulate(run); return; }
  try { await openCamera(); } catch (e) {
    if (run === scanRun) fail(cameraErrorKind(e));
    return;
  }
  if (run !== scanRun) return;
  const v = $("video");
  let eng;
  try { eng = await makeEngine(); } catch (e) { if (run === scanRun) fail("camera"); return; }
  const canvas = document.createElement("canvas");
  const ctx = canvas.getContext("2d", { willReadFrequently: true });
  const loop = async () => {
    if (run !== scanRun) return;
    if (!busy && v.readyState >= 2 && v.videoWidth) {
      const side = Math.min(v.videoWidth, v.videoHeight);
      const out = Math.min(side, 960);
      canvas.width = canvas.height = out;
      ctx.drawImage(v, (v.videoWidth - side) / 2, (v.videoHeight - side) / 2, side, side, 0, 0, out, out);
      let values = [];
      try { values = await eng.detect(canvas); } catch (e) {}
      if (run !== scanRun) return;
      let gan = null;
      for (const raw of values) { gan = extractGan(raw); if (gan) break; }
      if (gan) { bump(); await lookup(gan); return; }
    }
    scanTimer = setTimeout(loop, SCAN_EVERY_MS);
  };
  loop();
}

const DEMO_GAN = "7783320000001234", DEMO_BALANCE_CENTS = 1250;
const SIM_ENTER = 1400, SIM_SLIDE = 1250, SIM_SETTLE = 900, SIM_HOLD = 500;
let simBars = null, simGrain = null;

function simBarcode() {
  if (simBars) return simBars;
  let seed = 977;
  const rand = () => (seed = seed * 16807 % 2147483647) / 2147483647;
  const bars = [2, 1, 1, 2, 3, 2];
  for (let i = 0; i < 54; i++) bars.push(1 + Math.floor(rand() * rand() * 4));
  bars.push(2, 3, 3, 1, 1, 1, 2);
  return (simBars = bars);
}

function simNoise() {
  if (simGrain) return simGrain;
  const n = document.createElement("canvas");
  n.width = n.height = 128;
  const g = n.getContext("2d"), img = g.createImageData(128, 128);
  for (let i = 0; i < img.data.length; i += 4) {
    const v = Math.random() * 255;
    img.data[i] = img.data[i + 1] = img.data[i + 2] = v; img.data[i + 3] = 255;
  }
  g.putImageData(img, 0, 0);
  return (simGrain = n);
}

function roundRect(ctx, x, y, w, h, r) {
  ctx.beginPath();
  ctx.moveTo(x + r, y);
  ctx.arcTo(x + w, y, x + w, y + h, r);
  ctx.arcTo(x + w, y + h, x, y + h, r);
  ctx.arcTo(x, y + h, x, y, r);
  ctx.arcTo(x, y, x + w, y, r);
  ctx.closePath();
}

function drawCard(ctx, u, found) {
  const w = 100 * u, h = 63 * u, x = -w / 2, y = -h / 2;
  ctx.save();
  ctx.shadowColor = "rgba(0,0,0,.32)"; ctx.shadowBlur = 9 * u; ctx.shadowOffsetY = 4 * u;
  roundRect(ctx, x, y, w, h, 4 * u);
  const paper = ctx.createLinearGradient(x, y, x + w, y + h);
  paper.addColorStop(0, "#fbfaf7"); paper.addColorStop(1, "#e9e6df");
  ctx.fillStyle = paper; ctx.fill();
  ctx.restore();
  ctx.save();
  roundRect(ctx, x, y, w, h, 4 * u); ctx.clip();
  const band = ctx.createLinearGradient(x, y, x + w, y + 27 * u);
  band.addColorStop(0, "#34414c"); band.addColorStop(1, "#26313a");
  ctx.fillStyle = band; ctx.fillRect(x, y, w, 27 * u);
  ctx.strokeStyle = "rgba(255,255,255,.07)"; ctx.lineWidth = 0.6 * u;
  for (let i = -3; i < 9; i++) { ctx.beginPath(); ctx.arc(x + w * 0.86, y - 6 * u, (14 + i * 4.2) * u, 0, Math.PI * 2); ctx.stroke(); }
  ctx.fillStyle = "#f6f3ec"; ctx.textBaseline = "alphabetic";
  ctx.font = "600 " + (8.4 * u) + 'px "Kiosk Serif", Georgia, serif';
  ctx.fillText("Gift Card", x + 7 * u, y + 17.5 * u);
  ctx.font = (3.1 * u) + 'px "Kiosk Serif", Georgia, serif'; ctx.globalAlpha = 0.7;
  ctx.fillText("Redeemable for purchases", x + 7 * u, y + 22.5 * u);
  ctx.globalAlpha = 1;
  const bars = simBarcode(), modules = bars.reduce((a, b) => a + b, 0);
  const bx = x + 12 * u, bw = 76 * u, by = y + 33 * u, bh = 16 * u, m = bw / modules;
  ctx.fillStyle = "#16181a";
  let cx = bx;
  bars.forEach((wd, i) => { if (i % 2 === 0) ctx.fillRect(cx, by, wd * m + 0.15, bh); cx += wd * m; });
  ctx.font = (3.6 * u) + "px ui-monospace, Menlo, monospace"; ctx.textAlign = "center";
  ctx.fillText(DEMO_GAN.replace(/(\d{4})(?=\d)/g, "$1 "), 0, by + bh + 6 * u);
  ctx.restore();
  if (found > 0) {
    const pad = 3.2 * u, l = 6 * u, x0 = bx - pad, y0 = by - pad, x1 = bx + bw + pad, y1 = by + bh + pad;
    ctx.save();
    ctx.globalAlpha = Math.min(1, found * 3);
    ctx.strokeStyle = "#000"; ctx.lineWidth = 1.3 * u; ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath();
    for (const [px, py, sx, sy] of [[x0, y0, 1, 1], [x1, y0, -1, 1], [x1, y1, -1, -1], [x0, y1, 1, -1]]) {
      ctx.moveTo(px, py + sy * l); ctx.lineTo(px, py); ctx.lineTo(px + sx * l, py);
    }
    ctx.stroke();
    ctx.restore();
  }
}

function drawSim(canvas, t) {
  const dpr = Math.min(devicePixelRatio || 1, 2), W = canvas.clientWidth, H = canvas.clientHeight;
  if (!W || !H) return;
  if (canvas.width !== Math.round(W * dpr) || canvas.height !== Math.round(H * dpr)) { canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr); }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const bg = ctx.createLinearGradient(0, 0, 0, H);
  bg.addColorStop(0, "#d3cec6"); bg.addColorStop(0.6, "#c0bab1"); bg.addColorStop(1, "#aaa49b");
  ctx.fillStyle = bg; ctx.fillRect(0, 0, W, H);
  const glow = ctx.createRadialGradient(W * 0.22, H * 0.1, 0, W * 0.22, H * 0.1, W * 0.75);
  glow.addColorStop(0, "rgba(255,252,245,.55)"); glow.addColorStop(1, "rgba(255,252,245,0)");
  ctx.fillStyle = glow; ctx.fillRect(0, 0, W, H);
  ctx.fillStyle = "rgba(60,52,44,.16)"; ctx.fillRect(0, H * 0.78, W, H * 0.22);

  const k = Math.max(0, t - SIM_ENTER), p = Math.min(1, k / SIM_SLIDE), e = 1 - Math.pow(1 - p, 3);
  const s = Math.min(1, Math.max(0, (k - SIM_SLIDE) / SIM_SETTLE)), calm = 1 - s * 0.7;
  const shake = p < 1 ? 0 : 1;
  const u = W * 0.72 / 100 * (1.1 - 0.1 * (e * 0.5 + s * 0.5));
  const x = W / 2 + (1 - e) * W * 0.2 + shake * Math.sin(t / 210) * 2.2 * calm;
  const y = H * 0.5 + (1 - e) * H * 0.95 + shake * Math.cos(t / 260) * 1.8 * calm;
  const rot = (-17 + 13.5 * e + shake * Math.sin(t / 330) * 0.5 * calm) * Math.PI / 180;
  const foundAt = SIM_ENTER + SIM_SLIDE + SIM_SETTLE;
  const found = t >= foundAt ? (t - foundAt) / 1000 : 0;
  if (k > 0) {
    ctx.save(); ctx.translate(x, y); ctx.rotate(rot);
    drawCard(ctx, u, found);
    ctx.restore();
  }
  const vig = ctx.createRadialGradient(W / 2, H / 2, W * 0.3, W / 2, H / 2, W * 0.78);
  vig.addColorStop(0, "rgba(0,0,0,0)"); vig.addColorStop(1, "rgba(0,0,0,.3)");
  ctx.fillStyle = vig; ctx.fillRect(0, 0, W, H);
  ctx.globalAlpha = 0.05; ctx.globalCompositeOperation = "overlay";
  ctx.fillStyle = ctx.createPattern(simNoise(), "repeat");
  ctx.translate((t * 37) % 128, (t * 53) % 128); ctx.fillRect(-128, -128, W + 256, H + 256);
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0); ctx.globalCompositeOperation = "source-over"; ctx.globalAlpha = 1;
  if (found > 0 && found < 0.3) { ctx.fillStyle = "rgba(255,255,255," + (0.55 * (1 - found / 0.3)) + ")"; ctx.fillRect(0, 0, W, H); }
}

function simulate(run) {
  const canvas = $("sim"), finder = $("finder"), t0 = performance.now();
  const foundAt = SIM_ENTER + SIM_SLIDE + SIM_SETTLE;
  canvas.hidden = false;
  finder.classList.add("live");
  (function frame(now) {
    if (run !== scanRun) return;
    const t = now - t0;
    drawSim(canvas, t);
    if (t >= foundAt) finder.classList.remove("live");
    if (t >= foundAt + SIM_HOLD && !busy) { bump(); lookup(DEMO_GAN); return; }
    requestAnimationFrame(frame);
  })(t0);
}

paintKeypad();
show("s-scan");
startScan();
if (!DEBUG && !("BarcodeDetector" in window)) loadZxing().catch(() => {});

document.addEventListener("visibilitychange", () => { if (document.hidden && current !== "s-scan") reset(); });
`;
}
