import { NOTO_SERIF_SEMIBOLD_WOFF2 } from "./staff-font";

const STYLE = String.raw`
@font-face{font-family:"Kiosk Serif";src:url(data:font/woff2;base64,${NOTO_SERIF_SEMIBOLD_WOFF2}) format("woff2");font-weight:400 700;font-display:block}
:root{--bg:#fff;--fg:#000;--accent:#000;--serif:"Kiosk Serif","Noto Serif",Georgia,serif}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--fg);font-family:var(--serif);font-size:24px;line-height:1.4;-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;overflow:hidden;user-select:none;touch-action:manipulation}
.screen{position:absolute;inset:0;background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;padding:24px;text-align:center}
.screen[hidden]{display:none}
#s-scan.revealing{z-index:2}
#ring{position:fixed;left:0;top:0;width:0;height:0;border:4px solid var(--accent);border-radius:50%;transform:translate(-50%,-50%);pointer-events:none;z-index:3;display:none}
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
.small{font-size:clamp(15px,1.6vw,20px);padding:.4em 1em}
.corner{position:absolute;top:28px;left:32px}
#s-scan{justify-content:flex-start;padding-top:max(32px,5vh)}
#s-scan .ask{margin-bottom:0;padding:0 12vw}
.finder{position:relative;width:min(62vh,86vw);height:min(62vh,86vw);margin-top:3.2vh;border:.09em solid var(--fg);border-radius:28px;background:#f3f3f3;overflow:hidden;flex:none;isolation:isolate}
.finder video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .3s}
.finder video.live{opacity:1}
.finder video.mirror{transform:scaleX(-1)}
.finder .sweep{position:absolute;left:0;right:0;top:0;height:3px;background:var(--accent);animation:sweep 2.4s ease-in-out infinite alternate;opacity:0;transition:opacity .3s}
.finder.live .sweep{opacity:.85}
.finder.busy video{filter:blur(6px) grayscale(1);transform:scale(1.04)}
.finder.busy.mirror video{transform:scaleX(-1) scale(1.04)}
.finder.busy .sweep{animation-play-state:paused;opacity:0}
@keyframes sweep{from{top:0}to{top:calc(100% - 3px)}}
#warn{position:fixed;inset:0;z-index:20;background:rgba(255,255,255,.93);-webkit-backdrop-filter:blur(14px);backdrop-filter:blur(14px);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:24px}
#warn[hidden]{display:none}
#warn .count{font-size:clamp(120px,24vw,320px);font-weight:700;line-height:1;margin:8px 0 22px;font-variant-numeric:lining-nums}
#cursor{display:none;position:fixed;left:0;top:0;width:56px;height:56px;pointer-events:none;z-index:9999;opacity:0;transition:opacity .2s;transform-origin:3px 3px;will-change:transform}
#cursor.on{opacity:1}
#cursor.down path{fill:var(--accent)}
#cursor path{fill:var(--bg);stroke:var(--fg);stroke-width:2.8;stroke-linejoin:round;stroke-linecap:round;transition:fill .1s}
@media (pointer:fine){*{cursor:none!important}#cursor{display:block}}
@media (prefers-reduced-motion:reduce){.finder .sweep{animation:none}}
`;

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
<div id="ring"></div>

<section class="screen" id="s-idle">
  <h1>Gift Card Balance</h1>
  <p class="sub" id="idle-sub">Tap anywhere to check your gift card balance</p>
</section>

<section class="screen" id="s-scan" hidden>
  <button class="link small corner" id="back-scan">Start over</button>
  <p class="ask">Hold your gift card up to the camera</p>
  <div class="finder" id="finder">
    <video id="video" playsinline muted></video>
    <div class="sweep"></div>
  </div>
  <p class="hint" id="scan-hint">Line up the barcode or QR code inside the square</p>
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

export function giftCardScript(): string {
  return String.raw`
const IDLE_MS = 20000, WARN_AT_MS = 15000, SCAN_EVERY_MS = 140, CAMERA_RETRY_MS = 3000;
const FORMATS = ["qr_code", "code_128", "code_39", "code_93", "ean_13", "ean_8", "itf", "codabar", "upc_a", "upc_e", "data_matrix", "pdf417", "aztec"];
const $ = (id) => document.getElementById(id);
const SCREENS = ["s-idle", "s-scan", "s-result", "s-error"];
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

let current = "s-idle", resetting = false, swallowClick = 0;
let idleTimer = null, warnTimer = null, warnDeadline = 0;
let stream = null, cameraOpening = null, cameraRetry = null, scanTimer = null, scanRun = 0, busy = false, hintTimer = null;
let engine = null, zxingLoading = null;

$("idle-sub").textContent = matchMedia("(pointer: coarse)").matches ? "Tap anywhere to check your gift card balance" : "Click anywhere to check your gift card balance";

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
  if (current !== "s-idle") idleTimer = setTimeout(startWarning, WARN_AT_MS);
}
function onActivity(e) {
  if (!$("warn").hidden) {
    e.stopPropagation(); e.preventDefault();
    swallowClick = Date.now() + 500;
    bump();
    return;
  }
  if (current !== "s-idle") bump();
}
for (const type of ["pointerdown", "keydown", "touchstart"]) document.addEventListener(type, onActivity, true);
document.addEventListener("click", (e) => { if (Date.now() < swallowClick) { e.stopPropagation(); e.preventDefault(); } }, true);

function show(id) {
  const leaving = current;
  current = id;
  for (const s of SCREENS) $(s).hidden = s !== id;
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
  const from = SCREENS.map($).find((el) => !el.hidden);
  if (!from || from.id === "s-idle") { show("s-idle"); return; }
  resetting = true;
  stopScan();
  const out = from.animate(
    [{ transform: "scale(1)", filter: "blur(0px)", opacity: 1 }, { transform: "scale(1.1)", filter: "blur(14px)", opacity: 0 }],
    { duration: 380, easing: "cubic-bezier(.4, 0, 1, 1)", fill: "forwards" });
  out.onfinish = () => {
    show("s-idle"); out.cancel();
    const back = $("s-idle").animate(
      [{ transform: "scale(1.1)", filter: "blur(14px)", opacity: 0 }, { transform: "scale(1)", filter: "blur(0px)", opacity: 1 }],
      { duration: 420, easing: "cubic-bezier(0, 0, .2, 1)" });
    back.onfinish = () => { resetting = false; };
  };
}

function reveal(x, y) {
  const scan = $("s-scan"), ring = $("ring");
  if (!scan.hidden || resetting || current !== "s-idle") return;
  const RING_MIN = 4, RING_MAX = 48;
  const R = Math.hypot(Math.max(x, innerWidth - x), Math.max(y, innerHeight - y)) + RING_MAX + 4;
  scan.classList.add("revealing"); scan.hidden = false;
  ring.style.left = x + "px"; ring.style.top = y + "px"; ring.style.display = "block";
  startScan();
  const t0 = performance.now(), D = 520;
  (function frame(now) {
    const p = Math.min(1, (now - t0) / D), e = p * p * p, r = R * e;
    scan.style.clipPath = "circle(" + r + "px at " + x + "px " + y + "px)";
    ring.style.width = ring.style.height = 2 * r + "px";
    ring.style.borderWidth = (RING_MIN + (RING_MAX - RING_MIN) * e) + "px";
    if (p < 1) return requestAnimationFrame(frame);
    scan.style.clipPath = ""; scan.classList.remove("revealing"); ring.style.display = "none";
    if (current === "s-scan") show("s-scan");
  })(t0);
  current = "s-scan";
  bump();
}

$("s-idle").addEventListener("click", (e) => reveal(e.clientX || innerWidth / 2, e.clientY || innerHeight / 2));
document.addEventListener("keydown", (e) => {
  if (e.key === "Escape") reset();
  else if (current === "s-idle" && e.key.length === 1) reveal(innerWidth / 2, innerHeight / 2);
});
$("back-scan").onclick = reset;
$("result-done").onclick = reset;
$("error-done").onclick = reset;
$("error-retry").onclick = () => { $("s-error").hidden = true; swapToScan(); };

function swapToScan() {
  $("s-scan").hidden = false;
  $("s-error").hidden = true;
  show("s-scan");
  startScan();
}

function setHint(text, ms) {
  clearTimeout(hintTimer);
  $("scan-hint").textContent = text;
  if (ms) hintTimer = setTimeout(() => { $("scan-hint").textContent = DEFAULT_HINT; }, ms);
}
const DEFAULT_HINT = "Line up the barcode or QR code inside the square";

function fail(kind) {
  const cases = {
    denied: ["Camera is turned off", "Allow camera access for this page, then try again. Or ask at the table.", true],
    nocamera: ["No camera found", "This screen can't see a camera. Ask at the table.", false],
    camera: ["Camera won't start", "Something else may be using it. Try again, or ask at the table.", true],
    notfound: ["Card not found", "We couldn't find that gift card. Check that it is the right card and try again.", true],
    limit: ["Too many tries", "Wait a minute, then try again. Or ask at the table.", false],
    network: ["Couldn't check right now", "Something went wrong on our end. Try again, or ask at the table.", true],
  };
  const [title, sub, retry] = cases[kind] || cases.network;
  $("error-icon").replaceChildren(kind === "denied" || kind === "nocamera" || kind === "camera" ? document.getElementById("icon-camera-off").content.cloneNode(true) : "");
  $("error-title").textContent = title;
  $("error-title").style.fontSize = "clamp(40px, 6.5vw, 96px)";
  $("error-sub").textContent = sub;
  $("error-retry").hidden = !retry;
  if (current === "s-scan" && !$("s-scan").hidden) swap("s-scan", "s-error", "forward");
  else show("s-error");
}

function showResult(card) {
  const active = card.state === "ACTIVE";
  const notes = { PENDING: "This card hasn't been activated yet. Ask at the table.", BLOCKED: "This card is blocked. Ask at the table.", DEACTIVATED: "This card has been turned off. Ask at the table." };
  if (active) {
    $("result-ask").textContent = "Your gift card balance is";
    $("result-amount").textContent = money.format(card.balanceCents / 100);
    $("result-sub").textContent = card.balanceCents === 0 ? "This card is empty." : "Thanks for supporting Tech Club.";
  } else {
    $("result-ask").textContent = "This card can't be used right now";
    $("result-amount").textContent = "";
    $("result-sub").textContent = notes[card.state] || "Ask at the table.";
  }
  swap("s-scan", "s-result", "forward");
}

async function lookup(gan) {
  busy = true;
  $("finder").classList.add("busy");
  setHint("Checking balance");
  try {
    const res = await fetch("/giftcard/balance", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ gan }) });
    if (res.ok) { showResult(await res.json()); return; }
    fail(res.status === 404 ? "notfound" : res.status === 429 ? "limit" : "network");
  } catch (e) {
    fail("network");
  } finally {
    busy = false;
    $("finder").classList.remove("busy");
  }
}

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
  clearTimeout(scanTimer); scanTimer = null;
  $("finder").classList.remove("busy");
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
  setHint(DEFAULT_HINT);
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
  let lastOther = "";
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
      let gan = null, other = null;
      for (const raw of values) { gan = extractGan(raw); if (gan) break; other = raw; }
      if (gan) { bump(); await lookup(gan); return; }
      if (other && other !== lastOther) { lastOther = other; setHint("That code isn't a gift card. Try the barcode on the card.", 3500); }
    }
    scanTimer = setTimeout(loop, SCAN_EVERY_MS);
  };
  loop();
}

openCamera().catch(() => {});

document.addEventListener("visibilitychange", () => { if (document.hidden && current === "s-scan") reset(); });
`;
}
