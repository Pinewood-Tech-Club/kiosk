import { NOTO_SERIF_REGULAR_WOFF2, NOTO_SERIF_SEMIBOLD_WOFF2 } from "./staff-font";

const STYLE = String.raw`
@font-face{font-family:"Kiosk Serif";src:url(data:font/woff2;base64,${NOTO_SERIF_SEMIBOLD_WOFF2}) format("woff2");font-weight:500 700;font-display:block}
@font-face{font-family:"Kiosk Serif";src:url(data:font/woff2;base64,${NOTO_SERIF_REGULAR_WOFF2}) format("woff2");font-weight:400;font-display:block}
:root{--bg:#fff;--fg:#000;--accent:#000;--btn:clamp(22px,2.6vw,34px);--serif:"Kiosk Serif","Noto Serif",Georgia,serif}
*{box-sizing:border-box}
html,body{height:100%;margin:0}
body{background:var(--bg);color:var(--fg);font-family:var(--serif);font-weight:600;font-size:24px;line-height:1.4;-webkit-font-smoothing:antialiased;-webkit-tap-highlight-color:transparent;overflow:hidden;user-select:none;touch-action:manipulation}
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
.btn,.link{outline:none;font:inherit;font-size:var(--btn);line-height:1.2;padding:.45em 1.3em;border:.09em solid var(--fg);background:var(--bg);color:var(--fg);cursor:pointer;transition:background .12s,color .12s,transform .12s}
.btn{background:var(--accent);color:var(--bg);border-color:var(--accent)}
.btn:hover{background:var(--bg);color:var(--fg);border-color:var(--fg)}
.link:hover{background:var(--fg);color:var(--bg)}
.btn:active,.link:active{transform:scale(.97)}
.btn:disabled,.link:disabled{opacity:.4;cursor:default;transform:none}
.actions.row{flex-direction:row;flex-wrap:wrap;justify-content:center;gap:22px}
@property --ft{syntax:"<length>";inherits:false;initial-value:0px}
@property --fb{syntax:"<length>";inherits:false;initial-value:0px}
.screen.name{justify-content:flex-start;padding:0 0 calc(max(16px,2.2vh) + 52px)}
.top{flex:none;padding:max(136px,16vh) 24px 0}
.top .ask{margin-bottom:max(18px,2.6vh)}
.results{list-style:none;margin:0;padding:6px 0 18px;width:min(92vw,680px);flex:1;min-height:0;overflow-y:auto;overscroll-behavior:contain;scrollbar-width:none;--ft:0px;--fb:0px;-webkit-mask-image:linear-gradient(transparent,#000 var(--ft),#000 calc(100% - var(--fb)),transparent);mask-image:linear-gradient(transparent,#000 var(--ft),#000 calc(100% - var(--fb)),transparent);transition:--ft .2s,--fb .2s}
.results.ft{--ft:64px}
.results.fb{--fb:64px}
.results::-webkit-scrollbar{display:none}
.results button{display:block;width:100%;min-height:64px;text-align:center;font:inherit;background:var(--bg);color:var(--fg);border:0;padding:14px 20px 15px;cursor:pointer;line-height:1.15;outline:none;transition:background .08s,color .08s}
@media (hover:hover){.results:not(.still) button:hover{background:var(--accent);color:var(--bg)}}
.results .n{font-size:var(--btn);display:block}
.who{font-size:clamp(40px,6vw,80px);font-weight:700;line-height:1.1;margin:0;max-width:90vw}
.choices{margin-top:48px;display:flex;flex-wrap:wrap;justify-content:center;gap:22px}
.choice{font:inherit;min-width:clamp(150px,17vw,220px);padding:20px 26px 18px;border:.09em solid var(--fg);background:var(--bg);color:var(--fg);cursor:pointer;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;outline:none;transition:background .12s,color .12s,transform .12s}
.choice:hover{background:var(--fg);color:var(--bg)}
.choice.all{background:var(--accent);color:var(--bg);border-color:var(--accent)}
.choice.all:hover{background:var(--bg);color:var(--fg);border-color:var(--fg)}
.choice:active{transform:scale(.97)}
.choice b{font-size:clamp(40px,5.4vw,72px);line-height:1.05;font-weight:700;font-variant-numeric:lining-nums}
.choice span{font-size:clamp(16px,1.8vw,22px);min-height:1.4em}
.corner{position:absolute;top:28px;left:32px;z-index:3}
.screen.step{justify-content:flex-start;padding:0 24px calc(max(16px,2.2vh) + 52px)}
.step .body{flex:1;min-height:0;display:flex;flex-direction:column;align-items:center;justify-content:center;padding-top:max(136px,16vh)}
.foot{flex:none;display:flex;flex-direction:column;align-items:center;gap:18px;padding-top:24px}
.pair{min-width:7.5em}
#s-scan{justify-content:flex-start;padding-top:max(32px,5vh)}
#s-scan .ask{margin-bottom:0;padding:0 12vw}
#s-scan .hint{margin-top:2.4vh}
#scan-type{margin-top:2vh}
.gan{font:inherit;font-size:clamp(40px,6vw,84px);font-weight:700;font-variant-numeric:tabular-nums lining-nums;letter-spacing:.02em;width:min(92vw,12.5em);text-align:center;color:var(--fg);background:var(--bg);border:0;border-bottom:.06em solid var(--fg);border-radius:0;padding:.1em 0 .15em;outline:none;caret-color:var(--fg);user-select:text;-webkit-user-select:text}
.thanks-left{margin-top:5vh;margin-bottom:6px}
.thanks-amount{font-size:clamp(64px,9vw,128px);font-variant-numeric:lining-nums}
#s-thanks .actions{margin-top:5vh}
.finder{position:relative;width:100%;height:100%;border:.09em solid var(--fg);border-radius:28px;background:var(--bg);overflow:hidden;flex:none;isolation:isolate}
.finder video{position:absolute;inset:0;width:100%;height:100%;object-fit:cover;opacity:0;transition:opacity .3s}
.finder video.live{opacity:1}
.finder video.mirror{transform:scaleX(-1)}
.finder canvas{position:absolute;inset:0;width:100%;height:100%}
.stage{position:relative;width:min(58vh,86vw);height:min(58vh,86vw);margin-top:3.2vh;flex:none}
.stage .finder{margin:0;transition:opacity .35s ease}
.stage.busy .finder{opacity:0}
.checking{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;white-space:nowrap;font-size:clamp(26px,3.4vw,44px);opacity:0;pointer-events:none;transition:opacity .3s ease}
.busy>.checking{opacity:1;transition-delay:.25s}
.checking i{font-style:normal;animation:dot 1.2s infinite both}
.checking i:nth-child(2){animation-delay:.2s}
.checking i:nth-child(3){animation-delay:.4s}
@keyframes dot{0%,75%,100%{visibility:hidden}25%{visibility:visible}}
.credit{position:fixed;left:0;right:0;bottom:max(16px,2.2vh);z-index:21;margin:0;text-align:center;font-size:clamp(15px,1.6vw,20px);font-weight:400;pointer-events:none}
.credit b{font-weight:700}
#warn{position:fixed;inset:0;z-index:20;background:var(--bg);display:flex;flex-direction:column;align-items:center;justify-content:center;text-align:center;padding:24px}
#warn[hidden]{display:none}
#warn .count{font-size:clamp(120px,24vw,320px);font-weight:700;line-height:1;margin:8px 0 22px;font-variant-numeric:lining-nums}
#cursor{display:none;position:fixed;left:0;top:0;width:56px;height:56px;pointer-events:none;z-index:9999;opacity:0;transition:opacity .2s;transform-origin:3px 3px;will-change:transform}
#cursor.on{opacity:1}
#cursor.down path{fill:var(--accent)}
#cursor path{fill:var(--bg);stroke:var(--fg);stroke-width:2.8;stroke-linejoin:round;stroke-linecap:round;transition:fill .1s}
@media (pointer:fine){*{cursor:none!important}#cursor{display:block}}
@media (prefers-reduced-motion:reduce){.checking i{animation:none}}
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
<script src="/giftcard/confetti.js"></script>
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
    </div>
    <p class="checking" aria-live="polite">Checking your balance<i>.</i><i>.</i><i>.</i></p>
  </div>
  <p class="hint">Line up the barcode or QR code inside the square</p>
  <button class="link" id="scan-type">Enter card number</button>
</section>

<section class="screen step" id="s-type" hidden>
  <button class="link corner start-over">Start Over</button>
  <div class="body">
    <p class="ask">Type your gift card number</p>
    <input class="gan" id="type-gan" inputmode="numeric" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" aria-label="Gift card number">
  </div>
  <div class="foot"><button class="btn pair" id="type-check" disabled>Check balance</button><button class="link pair" id="back-type">Back</button></div>
</section>

<section class="screen" id="s-result" hidden>
  <button class="link corner start-over">Start Over</button>
  <p class="ask" id="result-ask">Your gift card balance is</p>
  <p class="amount" id="result-amount"></p>
  <p class="sub" id="result-sub"></p>
  <div class="actions row"><button class="link" id="result-donate" hidden>Donate to Club</button></div>
</section>

<section class="screen name" id="s-org" hidden>
  <button class="link corner start-over">Start Over</button>
  <div class="top">
    <p class="ask">Who should get your donation?</p>
  </div>
  <ul class="results" id="org-results"></ul>
  <div class="foot"><button class="link pair" id="back-org">Back</button></div>
</section>

<section class="screen step" id="s-amount" hidden>
  <button class="link corner start-over">Start Over</button>
  <div class="body">
    <p class="ask">How much would you like to give to</p>
    <p class="who" id="amount-org"></p>
    <div class="choices" id="amount-choices"></div>
  </div>
  <div class="foot"><button class="link pair" id="back-amount">Back</button></div>
</section>

<section class="screen step" id="s-confirm" hidden>
  <button class="link corner start-over" id="confirm-restart">Start Over</button>
  <div class="body">
    <p class="who" id="confirm-text"></p>
    <p class="sub" style="margin-top:18px">It comes off your gift card balance.</p>
  </div>
  <div class="foot"><button class="btn pair" id="confirm-yes">Confirm</button><button class="link pair" id="back-confirm">Back</button></div>
</section>

<section class="screen" id="s-thanks" hidden>
  <button class="link corner start-over">Start Over</button>
  <h1>Thank you.</h1>
  <p class="sub" id="thanks-sub"></p>
  <p class="ask thanks-left">Your gift card balance is now</p>
  <p class="who thanks-amount" id="thanks-balance"></p>
  <div class="actions row"><button class="link" id="thanks-donate" hidden>Donate to Club</button><button class="btn" id="thanks-done">Done</button></div>
</section>

<section class="screen" id="s-error" hidden>
  <button class="link corner start-over">Start Over</button>
  <span id="error-icon"></span>
  <h1 id="error-title"></h1>
  <p class="sub" id="error-sub"></p>
  <div class="actions">
    <button class="btn" id="error-retry">Try again</button>
    <button class="link" id="error-done">Start over</button>
  </div>
</section>

<section id="warn" hidden>
  <p class="ask">Are you still there?</p>
  <p class="count" id="warn-count">5</p>
  <p class="sub">Tap anywhere to keep going</p>
</section>
<p class="credit">From the <b>Pinewood Tech Club</b></p>
<template id="icon-camera-off">${ICON_CAMERA_OFF}</template>`;
}

export function giftCardScript(debug = false, catalog: { orgs: { id: string; name: string }[]; featured: string[] } | null = null): string {
  const inline = JSON.stringify(catalog).replace(/</g, "\\u003c").replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
  return `const DEBUG = ${debug};\nconst ORGS_INIT = ${inline};` + String.raw`
const IDLE_MS = 20000, WARN_AT_MS = 15000, SCAN_MAX_SIDE = 1920, CAMERA_RETRY_MS = 3000;
const FORMATS = ["qr_code", "code_128", "code_39", "code_93", "itf", "codabar", "data_matrix", "pdf417", "aztec"];
const $ = (id) => document.getElementById(id);
const SCREENS = ["s-scan", "s-type", "s-result", "s-error", "s-org", "s-amount", "s-confirm", "s-thanks"];
const money = new Intl.NumberFormat("en-US", { style: "currency", currency: "USD" });

let current = "s-scan", resetting = false, swallowClick = 0, retryAction = null, lookupRun = 0;
let idleTimer = null, warnTimer = null, warnDeadline = 0;
let stream = null, cameraOpening = null, cameraRetry = null, scanRun = 0, busy = false;
let engine = null, scannerLoading = null;
let card = null, donation = null, donating = false;


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
  if (!busy) $("stage").classList.remove("busy");
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
  retryAction = null; card = null; donation = null;
  refreshOrgs();
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

for (const b of document.querySelectorAll(".start-over")) b.onclick = () => { if (!donating) reset(); };
$("thanks-done").onclick = reset;
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
    nocamera: ["No camera found", "This screen can't see a camera. Ask at the table.", false],
    camera: ["Camera won't start", "Something else may be using it. Try again, or ask at the table.", true],
    notfound: ["Card not found", "We couldn't find that gift card. Check that it is the right card and try again.", true],
    network: ["Couldn't check right now", "Something went wrong on our end. Try again, or ask at the table.", true],
    donate: ["Donation didn't go through", "No money was taken from your card. Try again, or ask at the table.", true],
    short: ["Not enough on the card", "Your balance is lower than that amount. Ask at the table.", false],
    unconfirmed: ["We couldn't confirm it", "Try again. You won't be charged twice.", true],
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

function showResult(found, gan) {
  const active = found.state === "ACTIVE";
  card = active ? { gan, balanceCents: found.balanceCents } : null;
  $("result-donate").hidden = !(card && card.balanceCents > 0 && orgs.length);
  const notes = { PENDING: "This card hasn't been activated yet. Ask at the table.", BLOCKED: "This card is blocked. Ask at the table.", DEACTIVATED: "This card has been turned off. Ask at the table." };
  if (active) {
    $("result-ask").textContent = "Your gift card balance is";
    $("result-amount").textContent = money.format(found.balanceCents / 100);
    $("result-sub").textContent = found.balanceCents === 0 ? "This card is empty." : "";
  } else {
    $("result-ask").textContent = "This card can't be used right now";
    $("result-amount").textContent = "";
    $("result-sub").textContent = notes[found.state] || "Ask at the table.";
  }
  swap("s-scan", "s-result", "forward");
}

async function lookup(gan) {
  busy = true;
  const run = ++lookupRun;
  $("stage").classList.add("busy");
  const minimum = new Promise((resolve) => setTimeout(resolve, 600));
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
  if (run !== lookupRun || current !== "s-scan") return;
  if (typeof outcome === "string") fail(outcome); else showResult(outcome, gan);
}

document.addEventListener("keydown", (e) => { if (e.key === "Escape") reset(); });

const ganInput = $("type-gan");
function typedDigits() {
  return ganInput.value.trim().replace(/^sqgc:\/\//i, "").replace(/\D/g, "").slice(0, 16);
}
function paintTyped() {
  const digits = typedDigits();
  ganInput.value = digits.replace(/(\d{4})(?=\d)/g, "$1 ");
  $("type-check").disabled = digits.length !== 16;
}
function submitTyped() {
  const digits = typedDigits();
  if (digits.length !== 16 || busy || current !== "s-type") return;
  ganInput.blur();
  swap("s-type", "s-scan", "back");
  lookup(digits);
}
ganInput.addEventListener("input", () => { paintTyped(); bump(); });
ganInput.addEventListener("keydown", (e) => { if (e.key === "Enter") { e.preventDefault(); submitTyped(); } });
$("type-check").onclick = submitTyped;
$("scan-type").onclick = () => {
  if (current !== "s-scan" || busy) return;
  ganInput.value = "";
  paintTyped();
  swap("s-scan", "s-type", "forward");
  ganInput.focus();
};
$("back-type").onclick = () => { if (current === "s-type") { swap("s-type", "s-scan", "back"); startScan(); } };

const ORGS_REFRESH_MS = 3 * 60000;
const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const collate = new Intl.Collator(undefined, { numeric: true, sensitivity: "base" }).compare;

let orgs = [], orgsAt = 0, orgsRefreshing = false;
function takeOrgs(catalog) {
  const list = catalog && Array.isArray(catalog.orgs) ? catalog : { orgs: [], featured: [] };
  const rank = new Map((list.featured || []).map((id, i) => [id, i]));
  orgs = list.orgs.map((o) => ({ ...o, rank: rank.has(o.id) ? rank.get(o.id) : -1 }));
  orgsAt = Date.now();
}
function refreshOrgs() {
  if (orgsRefreshing || Date.now() - orgsAt < ORGS_REFRESH_MS) return;
  orgsRefreshing = true;
  fetch("/giftcard/orgs")
    .then((res) => (res.ok ? res.json() : null))
    .then((body) => { if (body && Array.isArray(body.orgs)) takeOrgs(body); }, () => {})
    .finally(() => { orgsRefreshing = false; });
}
takeOrgs(ORGS_INIT);

const orgList = $("org-results");
function renderOrgs() {
  const featured = orgs.filter((o) => o.rank >= 0).sort((a, b) => a.rank - b.rank);
  const rest = orgs.filter((o) => o.rank < 0).sort((a, b) => collate(a.name, b.name));
  const row = (o) => {
    const li = document.createElement("li"), b = document.createElement("button"), n = document.createElement("span");
    n.className = "n"; n.textContent = o.name;
    b.append(n); b.org = o;
    li.appendChild(b);
    return li;
  };
  const items = [...featured, ...rest].map(row);
  orgList.replaceChildren(...items);
}

function edgeFades() {
  const max = orgList.scrollHeight - orgList.clientHeight;
  orgList.classList.toggle("ft", orgList.scrollTop > 1);
  orgList.classList.toggle("fb", orgList.scrollTop < max - 1);
}

let openAt = { x: 0, y: 0 }, resumeAt = 0;
orgList.addEventListener("pointermove", (e) => {
  if (e.clientX !== openAt.x || e.clientY !== openAt.y) orgList.classList.remove("still");
});
orgList.addEventListener("scroll", () => { edgeFades(); bump(); }, { passive: true });
orgList.addEventListener("wheel", bump, { passive: true });
orgList.addEventListener("click", (e) => {
  const b = e.target.closest("button");
  if (!b) return;
  resumeAt = orgList.scrollTop;
  pickOrg(b.org);
});
window.addEventListener("resize", () => { if (current === "s-org") edgeFades(); });

function openOrgs(from) {
  const keep = from === "s-amount" ? resumeAt : 0;
  renderOrgs();
  openAt = { x: c.x, y: c.y };
  orgList.classList.add("still");
  swap(from, "s-org", from === "s-amount" ? "back" : "forward");
  orgList.scrollTop = keep;
  edgeFades();
}

$("result-donate").onclick = () => { if (card && orgs.length && current === "s-result") openOrgs("s-result"); };
$("thanks-donate").onclick = () => { if (card && card.balanceCents > 0 && orgs.length && current === "s-thanks") openOrgs("s-thanks"); };
$("back-org").onclick = () => swap("s-org", "s-result", "back");

function pickOrg(o) {
  if (!card || current !== "s-org") return;
  donation = { org: o };
  $("amount-org").textContent = o.name;
  const box = $("amount-choices");
  box.replaceChildren();
  const options = [500, 1000].filter((c) => c < card.balanceCents).map((c) => [c, ""]);
  options.push([card.balanceCents, "Donate it all"]);
  for (const [cents, label] of options) {
    const b = document.createElement("button"), amt = document.createElement("b"), cap = document.createElement("span");
    b.className = "choice" + (label ? " all" : "");
    amt.textContent = cents % 100 ? money.format(cents / 100) : "$" + cents / 100;
    cap.textContent = label;
    b.append(amt, cap);
    b.onclick = () => pickAmount(cents);
    box.appendChild(b);
  }
  swap("s-org", "s-amount", "forward");
}
$("back-amount").onclick = () => openOrgs("s-amount");

let fire = null;
function celebrate() {
  if (typeof confetti !== "function") return;
  // The page CSP blocks the blob: worker that the default confetti() cannon spins up.
  fire = fire || confetti.create(null, { resize: true, useWorker: false });
  const end = Date.now() + 1400;
  (function burst() {
    fire({ particleCount: 4, angle: 60, spread: 55, startVelocity: 55, origin: { x: 0, y: 0.7 } });
    fire({ particleCount: 4, angle: 120, spread: 55, startVelocity: 55, origin: { x: 1, y: 0.7 } });
    if (Date.now() < end) requestAnimationFrame(burst);
  })();
}

function newKey() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  return [...bytes].map((b) => b.toString(16).padStart(2, "0")).join("");
}

function pickAmount(cents) {
  if (!donation || current !== "s-amount") return;
  donation.cents = cents;
  donation.key = newKey();
  $("confirm-text").textContent = "Donate " + money.format(cents / 100) + " to " + donation.org.name + "?";
  swap("s-amount", "s-confirm", "forward");
}
$("back-confirm").onclick = () => { if (!donating && current === "s-confirm") swap("s-confirm", "s-amount", "back"); };

function confirmBusy(on) {
  donating = on;
  $("confirm-yes").disabled = on; $("back-confirm").disabled = on; $("confirm-restart").disabled = on;
  $("confirm-yes").textContent = on ? "Donating..." : "Confirm";
}

async function sendDonation(d) {
  if (DEBUG) return { balanceCents: card.balanceCents - d.cents };
  try {
    const res = await fetch("/giftcard/donate", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ gan: card.gan, variationId: d.org.id, amountCents: d.cents, idempotencyKey: d.key }),
    });
    const body = await res.json().catch(() => null);
    if (res.ok && body && typeof body.balanceCents === "number") return body;
    const code = body && body.error && body.error.code;
    if (res.status === 429) return "limit";
    if (code === "insufficient_balance") return "short";
    if (["donation_failed", "giftcard_inactive", "unknown_organization", "giftcard_not_found", "invalid_gan", "bad_request"].includes(code)) return "donate";
    return "unconfirmed";
  } catch (e) {
    return "unconfirmed";
  }
}

$("confirm-yes").onclick = async () => {
  if (!donation || !card || donating || current !== "s-confirm") return;
  const d = donation;
  confirmBusy(true);
  const [outcome] = await Promise.all([sendDonation(d), wait(600)]);
  confirmBusy(false);
  if (donation !== d || current !== "s-confirm") return;
  if (typeof outcome === "string") {
    if (outcome === "donate") d.key = newKey();
    retryAction = () => { swap("s-error", "s-confirm", "back"); };
    fail(outcome);
    return;
  }
  card.balanceCents = outcome.balanceCents;
  $("thanks-sub").textContent = "Your " + money.format(d.cents / 100) + " donation to " + d.org.name + " went through.";
  $("thanks-balance").textContent = money.format(outcome.balanceCents / 100);
  $("thanks-donate").hidden = !(outcome.balanceCents > 0 && orgs.length);
  $("result-amount").textContent = money.format(outcome.balanceCents / 100);
  $("result-sub").textContent = outcome.balanceCents === 0 ? "This card is empty." : "";
  $("result-donate").hidden = !(outcome.balanceCents > 0 && orgs.length);
  donation = null;
  swap("s-confirm", "s-thanks", "forward");
  celebrate();
};

function extractGan(raw) {
  let text = String(raw).trim().replace(/^sqgc:\/\//i, "");
  if (/^[\d\s-]+$/.test(text)) text = text.replace(/[\s-]/g, "");
  const m = text.match(/(?<!\d)\d{16}(?!\d)/);
  return m ? m[0] : null;
}

function loadScanner() {
  if (!scannerLoading) scannerLoading = new Promise((resolve, reject) => {
    const worker = new Worker("/giftcard/scan-worker.js");
    const pending = new Map();
    let seq = 0, dead = false;
    const die = () => {
      dead = true;
      worker.terminate();
      scannerLoading = null;
      if (engine && engine.worker === worker) engine = null;
      for (const settle of pending.values()) settle(null);
      pending.clear();
    };
    worker.onmessage = (e) => {
      const m = e.data;
      if ("ready" in m) {
        if (!m.ready) { die(); reject(new Error("scanner")); return; }
        resolve({
          name: "zxing",
          worker,
          detect: (canvas, ctx) => new Promise((ok, bad) => {
            if (dead) { bad(new Error("scanner")); return; }
            const id = ++seq;
            pending.set(id, (texts) => texts ? ok(texts) : bad(new Error("scanner")));
            const { data, width, height } = ctx.getImageData(0, 0, canvas.width, canvas.height);
            worker.postMessage({ id, data, width, height }, [data.buffer]);
          }),
        });
        return;
      }
      const settle = pending.get(m.id);
      if (settle) { pending.delete(m.id); settle(m.texts); }
    };
    worker.onerror = () => { die(); reject(new Error("scanner")); };
  });
  return scannerLoading;
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
  try { engine = await loadScanner(); } catch (e) { scannerLoading = null; throw e; }
  return engine;
}

function stopScan() {
  scanRun++;
  lookupRun++;
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
      const media = await navigator.mediaDevices.getUserMedia({ audio: false, video: { facingMode: { ideal: "environment" }, width: { ideal: 1920 }, height: { ideal: 1080 } } });
      stream = media;
      const track = media.getVideoTracks()[0];
      track.onended = () => { releaseCamera(); scheduleCameraRetry(); };
      try { await track.applyConstraints({ advanced: [{ focusMode: "continuous" }] }); } catch (e) {}
      const mirror = track.getSettings().facingMode !== "environment";
      const v = $("video");
      v.srcObject = media;
      try { await v.play(); } catch (e) {}
      v.classList.toggle("mirror", mirror);
      v.classList.add("live");
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
      const k = Math.min(1, SCAN_MAX_SIDE / Math.max(v.videoWidth, v.videoHeight));
      const w = Math.round(v.videoWidth * k), h = Math.round(v.videoHeight * k);
      if (canvas.width !== w || canvas.height !== h) { canvas.width = w; canvas.height = h; }
      ctx.drawImage(v, 0, 0, w, h);
      let values = [];
      try { values = await eng.detect(canvas, ctx); } catch (e) {
        if (eng.worker) { if (run === scanRun) fail("camera"); return; }
      }
      if (run !== scanRun) return;
      let gan = null;
      for (const raw of values) { gan = extractGan(raw); if (gan) break; }
      if (gan) { bump(); await lookup(gan); return; }
    }
    requestAnimationFrame(loop);
  };
  loop();
}

const DEMO_GAN = "7783320000001234", DEMO_BALANCE_CENTS = 1250;
const SIM_ENTER = 200, SIM_SLIDE = 800, SIM_SETTLE = 450, SIM_HOLD = 450;
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
  const canvas = $("sim"), t0 = performance.now();
  const foundAt = SIM_ENTER + SIM_SLIDE + SIM_SETTLE;
  canvas.hidden = false;
  (function frame(now) {
    if (run !== scanRun) return;
    const t = now - t0;
    drawSim(canvas, t);
    if (t >= foundAt + SIM_HOLD && !busy) { bump(); lookup(DEMO_GAN); return; }
    requestAnimationFrame(frame);
  })(t0);
}

show("s-scan");
startScan();
if (!DEBUG) makeEngine().catch(() => {});

document.addEventListener("visibilitychange", () => { if (document.hidden && current !== "s-scan") reset(); });
`;
}
