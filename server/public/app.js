"use strict";

const $ = (id) => document.getElementById(id);

const prefs = {
  get pin() { return localStorage.getItem("booth.pin"); },
  set pin(value) { value ? localStorage.setItem("booth.pin", value) : localStorage.removeItem("booth.pin"); },
  get name() { return localStorage.getItem("booth.name") || ""; },
  set name(value) { value ? localStorage.setItem("booth.name", value) : localStorage.removeItem("booth.name"); },
  get sound() { return localStorage.getItem("booth.sound") !== "off"; },
  set sound(on) { localStorage.setItem("booth.sound", on ? "on" : "off"); },
};

const PING_EVERY = 20_000;
const PONG_TIMEOUT = 8_000;
const REMIND_EVERY = 20_000;
const MAX_BACKOFF = 15_000;

let booth = null;
let clockOffset = 0;
let socket = null;
let connection = "connecting";
let retryCount = 0;
let failedOpens = 0;
let retryTimer = null;
let retryAt = 0;
let pingTimer = null;
let pongTimer = null;
let wakeLock = null;
let audio = null;
const seen = new Map();
const pendingFlavors = new Map();
const pendingAcks = new Set();
const ownToggles = new Map();
let firstSnapshot = true;

const ICONS = { help: "hand-helping", offline: "wifi-off", soldout: "ice-cream-cone" };
const HEALTH_ICONS = {
  "health:reader": "credit-card",
  "health:reader-battery": "battery-low",
  "health:ipad-battery": "battery-low",
  "health:catalog": "book-open",
  "health:auth": "circle-alert",
};

function icon(name, cls = "icon") {
  return `<svg class="${cls}" aria-hidden="true"><use href="/icons.svg#${name}"></use></svg>`;
}

function esc(value) {
  return String(value ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
}

function serverNow() {
  return Date.now() + clockOffset;
}

function ago(ms) {
  if (!ms) return "never";
  const s = Math.max(0, Math.round((serverNow() - ms) / 1000));
  if (s < 5) return "just now";
  if (s < 60) return `${s} s ago`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min ago`;
  return `${Math.floor(m / 60)} h ${m % 60} min ago`;
}

function base64url(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

/* Sound, vibration, wake lock */

function unlockAudio() {
  try {
    audio ??= new (window.AudioContext || window.webkitAudioContext)();
    if (audio.state !== "running") audio.resume();
  } catch {}
  renderSound();
}

function tone(frequency, start, duration, gain, type = "triangle") {
  const osc = audio.createOscillator();
  const amp = audio.createGain();
  osc.type = type;
  osc.frequency.value = frequency;
  amp.gain.setValueAtTime(0.0001, start);
  amp.gain.exponentialRampToValueAtTime(gain, start + 0.02);
  amp.gain.exponentialRampToValueAtTime(0.0001, start + duration);
  osc.connect(amp).connect(audio.destination);
  osc.start(start);
  osc.stop(start + duration + 0.05);
}

function chime(severity) {
  if (!prefs.sound || !audio || audio.state !== "running") return;
  const t = audio.currentTime + 0.02;
  if (severity === "urgent") {
    [659, 784, 1047, 784, 1047].forEach((f, i) => tone(f, t + i * 0.16, 0.32, 0.5));
  } else if (severity === "warning") {
    [784, 659].forEach((f, i) => tone(f, t + i * 0.2, 0.4, 0.35));
  } else {
    tone(880, t, 0.5, 0.18, "sine");
  }
}

function buzz(severity) {
  if (!navigator.vibrate) return;
  if (severity === "urgent") navigator.vibrate([300, 120, 300, 120, 300]);
  else if (severity === "warning") navigator.vibrate([250, 120, 250]);
}

async function keepAwake() {
  if (!("wakeLock" in navigator) || document.visibilityState !== "visible" || wakeLock) return;
  try {
    wakeLock = await navigator.wakeLock.request("screen");
    wakeLock.addEventListener("release", () => { wakeLock = null; });
  } catch {}
}

/* Connection */

async function checkPin(pin) {
  try {
    const response = await fetch("/v1/staff/login", { method: "POST", headers: { Authorization: `PIN ${pin}` } });
    return response.status;
  } catch {
    return 0;
  }
}

function connect() {
  clearTimeout(retryTimer);
  retryTimer = null;
  if (!prefs.pin) return;
  setConnection("connecting");
  const scheme = location.protocol === "https:" ? "wss:" : "ws:";
  const ws = new WebSocket(`${scheme}//${location.host}/v1/ws`, ["booth.v1", `pin.${base64url(prefs.pin)}`]);
  socket = ws;
  let opened = false;

  ws.onopen = () => {
    opened = true;
    retryCount = 0;
    failedOpens = 0;
    setConnection("live");
    startPinging(ws);
  };
  ws.onmessage = (event) => {
    if (socket !== ws) return;
    if (event.data === "pong") {
      clearTimeout(pongTimer);
      return;
    }
    try {
      handle(JSON.parse(event.data));
    } catch (error) {
      console.warn("Bad message", error);
    }
  };
  ws.onclose = () => {
    if (socket !== ws) return;
    if (!opened) failedOpens++;
    dropSocket();
    scheduleReconnect();
  };
}

function dropSocket() {
  clearInterval(pingTimer);
  clearTimeout(pongTimer);
  const ws = socket;
  socket = null;
  if (ws && ws.readyState <= WebSocket.OPEN) {
    try { ws.close(); } catch {}
  }
}

function ping(ws) {
  if (socket !== ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send("ping");
  clearTimeout(pongTimer);
  pongTimer = setTimeout(() => {
    if (socket !== ws) return;
    dropSocket();
    scheduleReconnect();
  }, PONG_TIMEOUT);
}

function startPinging(ws) {
  clearInterval(pingTimer);
  pingTimer = setInterval(() => ping(ws), PING_EVERY);
}

async function scheduleReconnect() {
  if (failedOpens >= 2 && navigator.onLine !== false) {
    const status = await checkPin(prefs.pin);
    if (status === 401) {
      signOut("That PIN no longer works. Enter the current booth PIN.");
      return;
    }
  }
  const delay = Math.min(MAX_BACKOFF, 1000 * 2 ** retryCount) * (0.7 + Math.random() * 0.6);
  retryCount++;
  retryAt = Date.now() + delay;
  setConnection(navigator.onLine === false ? "offline" : "waiting");
  clearTimeout(retryTimer);
  retryTimer = setTimeout(connect, delay);
}

function reconnectNow() {
  if (!prefs.pin || socket) return;
  retryCount = 0;
  connect();
}

function send(message) {
  if (!socket || socket.readyState !== WebSocket.OPEN) return false;
  socket.send(JSON.stringify(message));
  return true;
}

function setConnection(next) {
  connection = next;
  renderConnection();
  renderAll();
}

/* Messages */

function handle(message) {
  switch (message.type) {
    case "snapshot": {
      booth = message.state;
      clockOffset = message.state.serverTime - Date.now();
      for (const alert of booth.alerts) {
        if (firstSnapshot) seen.set(alert.id, alert.count);
        else notify(alert);
      }
      firstSnapshot = false;
      pendingAcks.clear();
      pendingFlavors.clear();
      renderAll();
      break;
    }
    case "alert": {
      if (!booth) return;
      const index = booth.alerts.findIndex((a) => a.id === message.alert.id);
      if (index >= 0) booth.alerts[index] = message.alert;
      else booth.alerts.unshift(message.alert);
      if (message.alert.ackedAt) pendingAcks.delete(message.alert.id);
      notify(message.alert);
      renderAlerts();
      break;
    }
    case "kiosk":
      if (!booth) return;
      booth.kiosk = message.kiosk;
      renderKiosk();
      break;
    case "soldOut":
      if (!booth) return;
      booth.soldOut = message.soldOut;
      booth.flavors = booth.flavors.map((f) => ({ ...f, soldOut: message.soldOut[f.id] ?? false }));
      pendingFlavors.delete(message.flavor);
      renderFlavors();
      break;
    case "error":
      console.warn("Booth:", message.message);
      pendingFlavors.clear();
      renderFlavors();
      break;
  }
}

function isActive(alert) {
  return !alert.ackedAt && !alert.resolvedAt;
}

function notify(alert) {
  const previous = seen.get(alert.id);
  seen.set(alert.id, alert.count);
  if (previous !== undefined && alert.count <= previous) return;
  if (!isActive(alert)) return;
  if (alert.kind === "soldout") {
    const flavor = alert.key.slice("soldout:".length);
    if (Date.now() - (ownToggles.get(flavor) ?? 0) < 5000) return;
  }
  chime(alert.severity);
  buzz(alert.severity);
}

function remind() {
  if (!booth) return;
  const urgent = booth.alerts.filter((a) => isActive(a) && a.severity === "urgent");
  if (urgent.length > 0) {
    chime("urgent");
    buzz("urgent");
  }
}

/* Rendering */

function renderConnection() {
  const pill = $("connection");
  const label = {
    live: "Live",
    connecting: "Connecting",
    waiting: `Reconnecting in ${Math.max(1, Math.ceil((retryAt - Date.now()) / 1000))} s`,
    offline: "No internet",
  }[connection];
  pill.className = `pill ${connection === "live" ? "live" : connection === "offline" ? "down" : "connecting"}`;
  pill.innerHTML = connection === "live" || connection === "offline"
    ? `<span class="dot"></span>${label}`
    : `${icon("refresh-cw")}${label}`;
  const stale = connection !== "live";
  $("stale").hidden = !stale || !booth;
  $("app").classList.toggle("is-stale", stale && !!booth);
}

function renderSound() {
  const button = $("sound");
  const on = prefs.sound && audio && audio.state === "running";
  button.classList.toggle("off", !on);
  button.innerHTML = icon(on ? "volume-2" : "volume-x");
  button.setAttribute("aria-label", on ? "Sound on. Tap to mute." : prefs.sound ? "Tap to turn sound on" : "Sound off. Tap to unmute.");
  button.title = button.getAttribute("aria-label");
}

function alertIcon(alert) {
  if (alert.kind === "health") return HEALTH_ICONS[alert.key] ?? "triangle-alert";
  return ICONS[alert.kind] ?? "circle-alert";
}

function renderAlerts() {
  const alerts = booth?.alerts ?? [];
  const rank = { urgent: 0, warning: 1, info: 2 };
  const active = alerts.filter(isActive).sort((a, b) => rank[a.severity] - rank[b.severity] || b.updatedAt - a.updatedAt);
  const recent = alerts.filter((a) => !isActive(a)).sort((a, b) => b.updatedAt - a.updatedAt).slice(0, 20);
  const live = connection === "live";

  $("alerts").innerHTML = active.length === 0
    ? `<div class="empty">${icon("circle-check")}<div><strong>All quiet</strong>${booth ? "No one needs anything right now." : "Waiting for the booth."}</div></div>`
    : active.map((a) => {
        const pending = pendingAcks.has(a.id);
        return `<article class="alert ${a.severity}">
          <div class="badge">${icon(alertIcon(a))}</div>
          <h3>${esc(a.title)}</h3>
          <p class="detail">${esc(a.detail)}</p>
          <div class="meta">
            <span>${icon("clock")}<span data-ago="${a.createdAt}">${ago(a.createdAt)}</span></span>
            ${a.count > 1 ? `<span class="count">×${a.count}</span>` : ""}
          </div>
          <button class="button ${a.severity === "urgent" ? "primary" : ""} ${a.severity === "info" ? "" : "big"} ack" type="button" data-ack="${esc(a.id)}" ${!live || pending ? "disabled" : ""}>
            ${icon("check")}<span>${pending ? "Acknowledging" : a.kind === "help" ? "On my way" : "Got it"}</span>
          </button>
        </article>`;
      }).join("");

  $("recent-wrap").hidden = recent.length === 0;
  $("recent").innerHTML = recent.map((a) => {
    const how = a.ackedAt
      ? `${a.ackedBy ? `${esc(a.ackedBy)} acknowledged` : "Acknowledged"} <span data-ago="${a.ackedAt}">${ago(a.ackedAt)}</span>`
      : `${a.kind === "offline" ? "Back online" : a.kind === "soldout" ? "Replaced" : "Cleared on its own"} <span data-ago="${a.resolvedAt}">${ago(a.resolvedAt)}</span>`;
    return `<div class="recent-item">${icon(alertIcon(a))}<strong>${esc(a.title)}</strong><span>${how}</span></div>`;
  }).join("");

  const count = active.filter((a) => a.severity !== "info").length;
  document.title = count > 0 ? `(${count}) Booth` : "Booth";
}

function tile({ label, iconName, value, sub = "", tone = "", wide = false, html = "" }) {
  return `<div class="tile ${tone} ${wide ? "wide" : ""}">
    <div class="label">${icon(iconName)}${esc(label)}</div>
    <div class="value">${esc(value)}</div>
    ${sub ? `<div class="sub">${sub}</div>` : ""}
    ${html}
  </div>`;
}

function batteryText(percent, charging) {
  if (typeof percent !== "number" || percent < 0) return "";
  return `${percent}%${charging ? ", charging" : ""}`;
}

function renderKiosk() {
  if (!booth) {
    $("kiosk").innerHTML = "";
    return;
  }
  const k = booth.kiosk;
  const h = k.health;
  const tiles = [];

  if (k.online) {
    tiles.push(tile({
      label: "Kiosk", iconName: "wifi", value: "Online", tone: "good",
      sub: `Heartbeat <span data-ago="${k.lastHeartbeatAt}">${ago(k.lastHeartbeatAt)}</span>${k.screen ? `, on ${esc(k.screen)}` : ""}`,
    }));
  } else {
    tiles.push(tile({
      label: "Kiosk", iconName: "wifi-off", value: k.lastHeartbeatAt ? "Offline" : "Not connected yet", tone: "bad",
      sub: k.lastHeartbeatAt ? `Last heartbeat <span data-ago="${k.lastHeartbeatAt}">${ago(k.lastHeartbeatAt)}</span>` : "",
    }));
  }

  if (!h) {
    tiles.push(tile({ label: "Health", iconName: "tablet", value: "No report yet", wide: true }));
  } else {
    const configured = h.environment && h.environment !== "No credentials";
    tiles.push(tile({
      label: "Square", iconName: "store",
      value: !configured ? "Not set up" : h.authorized ? "Authorized" : "Not authorized",
      tone: !configured ? "warn" : h.authorized ? "good" : "bad",
      sub: [h.environment, h.simulatePayment ? "simulated payments" : ""].filter(Boolean).map(esc).join(", "),
    }));

    const readers = h.readers ?? [];
    const reader = readers.find((r) => r.state === "ready") ?? readers[0];
    tiles.push(tile({
      label: "Card reader", iconName: "credit-card",
      value: reader ? (h.readerReady ? "Ready" : reader.state) : "None paired",
      tone: h.readerReady ? "good" : configured && !h.simulatePayment ? "bad" : "warn",
      sub: reader
        ? [reader.name, batteryText(reader.batteryPercent, reader.isCharging)].filter(Boolean).map(esc).join(", ")
          + (readers.length > 1 ? `, +${readers.length - 1} more` : "")
        : "",
    }));

    const battery = h.deviceBattery;
    tiles.push(tile({
      label: "iPad battery", iconName: battery?.charging ? "battery-charging" : battery && battery.percent <= 20 ? "battery-low" : "battery",
      value: battery ? `${battery.percent}%` : "Unknown",
      tone: battery && battery.percent <= 20 && !battery.charging ? "bad" : "",
      sub: battery ? (battery.charging ? "Charging" : "On battery") : "",
    }));

    tiles.push(tile({
      label: "Catalog", iconName: "book-open",
      value: h.catalog ? (h.catalog.ok ? (h.catalog.status || "OK") : "Error") : "Unknown",
      tone: h.catalog && !h.catalog.ok ? "bad" : "",
      sub: h.catalog && !h.catalog.ok ? esc(h.catalog.error || h.catalog.status || "") : "",
    }));

    tiles.push(tile({
      label: "App", iconName: "tablet", value: h.appVersion || "Unknown",
      sub: `Report <span data-ago="${k.healthAt}">${ago(k.healthAt)}</span>`,
    }));

    if (h.lastError) {
      tiles.push(tile({
        label: "Last error", iconName: "circle-alert", value: "", wide: true,
        html: `<div class="error-text">${esc(h.lastError)}</div>${h.lastErrorAt ? `<div class="sub">${esc(new Date(h.lastErrorAt).toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }))}</div>` : ""}`,
      }));
    }
  }
  $("kiosk").innerHTML = tiles.join("");
}

function renderFlavors() {
  const flavors = booth?.flavors ?? [];
  const live = connection === "live";
  $("flavors").innerHTML = flavors.map((f) => {
    const pending = pendingFlavors.has(f.id);
    const sold = pending ? pendingFlavors.get(f.id) : f.soldOut;
    return `<button type="button" class="flavor ${sold ? "sold" : ""} ${pending ? "pending" : ""}" data-flavor="${esc(f.id)}"
        role="switch" aria-checked="${!sold}" aria-label="${esc(f.name)} available" ${!live || pending ? "disabled" : ""}>
      <span><span class="name">${esc(f.name)}</span><span class="state">${sold ? "Sold out" : "Available"}</span></span>
      <span class="switch" aria-hidden="true"></span>
    </button>`;
  }).join("");
}

function renderAll() {
  renderAlerts();
  renderKiosk();
  renderFlavors();
  $("who").textContent = prefs.name ? `Signed in as ${prefs.name}` : "Signed in";
}

function tick() {
  for (const el of document.querySelectorAll("[data-ago]")) {
    el.textContent = ago(Number(el.dataset.ago));
  }
  if (connection === "waiting") renderConnection();
}

/* Screens */

function showLogin(message) {
  $("app").hidden = true;
  $("login").hidden = false;
  $("name").value = prefs.name;
  $("login-error").hidden = !message;
  $("login-error").textContent = message || "";
  $("pin").focus();
}

function showApp() {
  $("login").hidden = true;
  $("app").hidden = false;
  renderSound();
  renderConnection();
  renderAll();
  keepAwake();
  connect();
}

function signOut(message) {
  prefs.pin = null;
  clearTimeout(retryTimer);
  dropSocket();
  booth = null;
  firstSnapshot = true;
  seen.clear();
  showLogin(message);
}

$("login-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  unlockAudio();
  const pin = $("pin").value.trim();
  const button = event.submitter ?? $("login-form").querySelector("button");
  button.disabled = true;
  const status = await checkPin(pin);
  button.disabled = false;
  if (status === 200) {
    prefs.pin = pin;
    prefs.name = $("name").value.trim();
    $("pin").value = "";
    showApp();
  } else {
    showLogin(status === 401 ? "That PIN didn't work." : status === 429 ? "Too many tries. Wait a minute, then try again."
      : "Can't reach the booth server. Check your connection.");
  }
});

$("alerts").addEventListener("click", (event) => {
  const button = event.target.closest("[data-ack]");
  if (!button) return;
  const id = button.dataset.ack;
  if (send({ type: "ack", id, by: prefs.name || undefined })) {
    pendingAcks.add(id);
    renderAlerts();
  }
});

$("flavors").addEventListener("click", (event) => {
  const button = event.target.closest("[data-flavor]");
  if (!button || !booth) return;
  const id = button.dataset.flavor;
  const flavor = booth.flavors.find((f) => f.id === id);
  if (!flavor || pendingFlavors.has(id)) return;
  const soldOut = !flavor.soldOut;
  if (send({ type: "setSoldOut", flavor: id, soldOut, by: prefs.name || undefined })) {
    pendingFlavors.set(id, soldOut);
    ownToggles.set(id, Date.now());
    renderFlavors();
    setTimeout(() => {
      if (pendingFlavors.get(id) === soldOut) {
        pendingFlavors.delete(id);
        renderFlavors();
      }
    }, 6000);
  }
});

$("sound").addEventListener("click", () => {
  const running = audio && audio.state === "running";
  if (!running) {
    prefs.sound = true;
    unlockAudio();
    setTimeout(() => { renderSound(); chime("info"); }, 50);
    return;
  }
  prefs.sound = !prefs.sound;
  renderSound();
  if (prefs.sound) chime("info");
});

$("logout").addEventListener("click", () => signOut());

document.addEventListener("pointerdown", () => {
  if (prefs.sound && (!audio || audio.state !== "running")) {
    unlockAudio();
    setTimeout(renderSound, 50);
  }
}, { passive: true });

document.addEventListener("visibilitychange", () => {
  if (document.visibilityState !== "visible") return;
  keepAwake();
  if (socket && socket.readyState === WebSocket.OPEN) ping(socket);
  else reconnectNow();
});

window.addEventListener("online", () => {
  clearTimeout(retryTimer);
  reconnectNow();
});
window.addEventListener("offline", () => {
  if (connection !== "live") setConnection("offline");
});

setInterval(tick, 1000);
setInterval(remind, REMIND_EVERY);

if (prefs.pin) showApp();
else showLogin();
