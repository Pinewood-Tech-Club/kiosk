import { escapeHtml } from "./http";
import { TOPPING_TITLES } from "./pricing";

const ICONS: Record<string, string> = {
  lock: '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  logOut: '<path d="m16 17 5-5-5-5"/><path d="M21 12H9"/><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>',
  layout: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
  tablet: '<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><line x1="12" x2="12.01" y1="18" y2="18"/>',
  scroll: '<path d="M15 12h-5"/><path d="M15 8h-5"/><path d="M19 17V5a2 2 0 0 0-2-2H4"/><path d="M8 21h12a2 2 0 0 0 2-2v-1a1 1 0 0 0-1-1H11a1 1 0 0 0-1 1v1a2 2 0 1 1-4 0V5a2 2 0 1 0-4 0v2a1 1 0 0 0 1 1h3"/>',
  card: '<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/><path d="M6 14h2"/>',
  receipt: '<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z"/><path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8"/><path d="M12 17.5v-11"/>',
  stethoscope: '<path d="M11 2v2"/><path d="M5 2v2"/><path d="M5 3H4a2 2 0 0 0-2 2v4a6 6 0 0 0 12 0V5a2 2 0 0 0-2-2h-1"/><path d="M8 15a6 6 0 0 0 12 0v-3"/><circle cx="20" cy="10" r="2"/>',
  eraser: '<path d="m7 21-4.3-4.3c-1-1-1-2.5 0-3.4l9.6-9.6c1-1 2.5-1 3.4 0l5.6 5.6c1 1 1 2.5 0 3.4L13 21"/><path d="M22 21H7"/><path d="m5 11 9 9"/>',
  rotate: '<path d="M3 12a9 9 0 1 0 9-9 9.75 9.75 0 0 0-6.74 2.74L3 8"/><path d="M3 3v5h5"/>',
  refresh: '<path d="M3 12a9 9 0 0 1 9-9 9.75 9.75 0 0 1 6.74 2.74L21 8"/><path d="M21 3v5h-5"/><path d="M21 12a9 9 0 0 1-9 9 9.75 9.75 0 0 1-6.74-2.74L3 16"/><path d="M8 16H3v5"/>',
  chevron: '<path d="m9 18 6-6-6-6"/>',
  chevronLeft: '<path d="m15 18-6-6 6-6"/>',
  chevronDown: '<path d="m6 9 6 6 6-6"/>',
  updown: '<path d="m7 15 5 5 5-5"/><path d="m7 9 5-5 5 5"/>',
  search: '<circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  circleCheck: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  circleX: '<circle cx="12" cy="12" r="10"/><path d="m15 9-6 6"/><path d="m9 9 6 6"/>',
  external: '<path d="M15 3h6v6"/><path d="M10 14 21 3"/><path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6"/>',
  download: '<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>',
  loader: '<path d="M21 12a9 9 0 1 1-6.219-8.56"/>',
  alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
};

function icon(name: string, cls = ""): string {
  return `<svg class="i${cls ? ` ${cls}` : ""}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

const SECTIONS: { id: string; title: string; icon: string; group: number }[] = [
  { id: "kiosks", title: "Kiosks", icon: "tablet", group: 0 },
  { id: "logs", title: "Logs", icon: "scroll", group: 0 },
  { id: "square", title: "Square", icon: "card", group: 1 },
  { id: "orders", title: "Orders", icon: "receipt", group: 1 },
  { id: "selftest", title: "Self-test", icon: "stethoscope", group: 2 },
  { id: "cleanup", title: "Cleanup", icon: "eraser", group: 2 },
  { id: "reset", title: "Reset", icon: "rotate", group: 3 },
];

const STYLE = `
.signin .appicon.admin{background:#636366;box-shadow:0 10px 24px -12px rgba(0,0,0,.45)}
a.srow{color:inherit}
.signin .navbtn{justify-self:center}
.sv{position:fixed;inset:0;display:grid;grid-template-columns:320px minmax(0,1fr);background:var(--bg)}
.side,.detail{overflow-y:auto;overscroll-behavior:contain;-webkit-overflow-scrolling:touch;padding-top:env(safe-area-inset-top);padding-bottom:calc(48px + env(safe-area-inset-bottom))}
.side{padding-left:max(20px,env(safe-area-inset-left));padding-right:20px;border-right:.5px solid var(--sep)}
.detail{padding-left:40px;padding-right:max(40px,env(safe-area-inset-right))}
.sbar{height:50px;display:flex;align-items:center;justify-content:space-between;gap:16px;padding:0 4px}
.sbar .navbtn{font-size:17px}
.sbar .navbtn svg{font-size:19px}
.side h1{font-size:40px;font-weight:700;letter-spacing:-.025em;line-height:1;margin:6px 4px 20px}
.slist{border-radius:14px}
.slist+.slist{margin-top:22px}
.srow{display:flex;align-items:center;gap:14px;width:100%;min-height:50px;padding:0 14px 0 12px;text-align:left;font-size:17px;font-weight:500;letter-spacing:-.015em}
.list>.srow+.srow::before{left:56px}
.srow .stile{width:30px;height:30px;border-radius:8px;background:#8E8E93;color:#fff;display:grid;place-items:center;font-size:18px;flex:none}
.srow .stile svg{stroke-width:2.25}
.srow.danger .stile{background:var(--red)}
.srow .sname{flex:1;min-width:0}
.srow .sval{font-size:16px;font-weight:400;color:var(--label-2);white-space:nowrap}
.srow .chev{display:none;color:var(--label-3);font-size:18px}
.srow:active{background:rgba(0,0,0,.05)}
.srow.sel{background:var(--tint);color:#fff}
.srow.sel .sval{color:rgba(255,255,255,.85)}
.list>.srow.sel::before,.list>.srow.sel+.srow::before{display:none}
.sfoot{font-size:14px;color:var(--label-2);margin:14px 16px 0;line-height:1.35;overflow-wrap:anywhere}
.sfoot b{font-weight:600;color:var(--label)}
.pane{max-width:820px;margin:0 auto}
.pbar{height:50px;display:flex;align-items:center;justify-content:space-between;gap:16px}
.pbar .back{visibility:hidden;margin-left:-6px}
.pbar .back svg{font-size:24px;stroke-width:2.5}
.pbar .right{display:flex;align-items:center;gap:20px;margin-left:auto}
.pane>h1{font-size:40px;font-weight:700;letter-spacing:-.025em;line-height:1.05;margin:6px 4px 0}
.lede{font-size:17px;color:var(--label-2);margin:8px 4px 0;line-height:1.4;max-width:640px}
.gh{display:flex;align-items:baseline;justify-content:space-between;gap:16px;margin:30px 20px 8px;font-size:15px;font-weight:600;color:var(--label-2)}
.gh .r{font-weight:500;text-align:right}
.ag{border-radius:22px}
.list.ag>*+*::before{left:20px}
.ac{display:flex;align-items:center;gap:14px;min-height:50px;padding:11px 20px}
.ac .k{font-size:17px;letter-spacing:-.01em;flex:none;max-width:52%}
.ac .grow{flex:1;min-width:0}
.ac .grow .k{max-width:none}
.ac .s{font-size:14px;color:var(--label-2);margin-top:2px;line-height:1.3}
.ac .v{margin-left:auto;font-size:17px;color:var(--label-2);text-align:right;overflow-wrap:anywhere;min-width:0}
.ac .v small{display:block;font-size:14px;color:var(--label-3);margin-top:1px}
.mono{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:.88em;letter-spacing:0}
.ok{color:var(--label-2)}
.good{color:#248A3D}
.bad{color:var(--red-ink)!important;font-weight:550}
.warn{color:var(--orange-ink)!important;font-weight:550}
.dot{display:inline-flex;align-items:center;gap:8px}
.dot::before{content:"";width:9px;height:9px;border-radius:50%;background:var(--green);flex:none}
.dot.off::before{background:var(--label-3)}
.dot.red::before{background:var(--red)}
.btnrow{display:flex;align-items:center;gap:14px;width:100%;min-height:50px;padding:11px 20px;text-align:left}
.btnrow .k{font-size:17px;font-weight:500;color:var(--tint-ink);letter-spacing:-.01em}
.btnrow.danger .k{color:var(--red)}
.btnrow .grow{flex:1;min-width:0}
.btnrow .s{font-size:14px;color:var(--label-2);margin-top:2px;line-height:1.3;font-weight:400}
.btnrow .res{margin-left:auto;font-size:15px;color:var(--label-2);text-align:right;display:inline-flex;align-items:center;gap:6px;max-width:48%}
.btnrow:active:not(:disabled){background:rgba(0,0,0,.04)}
.btnrow:disabled .k,.btnrow:disabled .s{opacity:.4}
.btnrow .lead{font-size:20px;color:var(--tint);flex:none}
.btnrow.danger .lead{color:var(--red)}
.kh{display:flex;align-items:baseline;flex-wrap:wrap;gap:6px 12px;margin:38px 20px 10px}
.kh h2{font-size:26px;font-weight:700;letter-spacing:-.02em;line-height:1.1;min-width:0;overflow-wrap:anywhere}
.kh .tagid{font-size:15px;color:var(--label-3);font-weight:500;font-variant-numeric:tabular-nums}
.kh .dot{margin-left:auto;font-size:16px;font-weight:600;color:var(--label-2);white-space:nowrap}
.kh .dbg{display:inline-flex;align-items:center;gap:10px;font-size:15px;font-weight:500;color:var(--label-2);white-space:nowrap;margin-left:8px}
.kh+.ag{margin-top:0}
.ag+.ag{margin-top:16px}
.ag+.footnote{margin-top:8px}
.aempty{padding:22px 20px;font-size:17px;color:var(--label-2);display:flex;align-items:center;gap:10px}
.seg{display:grid;grid-auto-flow:column;grid-auto-columns:minmax(0,1fr);gap:2px;padding:2px;border-radius:10px;background:rgba(118,118,128,.12);flex:1;max-width:440px;margin-left:auto}
.seg button{min-height:36px;border-radius:8px;font-size:15px;font-weight:500;padding:0 8px;white-space:nowrap}
.seg button.sel{background:#fff;font-weight:600;box-shadow:0 3px 8px rgba(0,0,0,.12),0 0 0 .5px rgba(0,0,0,.04)}
.search{display:flex;align-items:center;gap:8px;height:44px;padding:0 12px;border-radius:12px;background:rgba(118,118,128,.12);margin-top:18px;color:var(--label-2)}
.search svg{font-size:19px}
.search input{font:inherit;font-size:17px;border:0;background:none;color:var(--label);flex:1;min-width:0;height:44px;-webkit-appearance:none;appearance:none}
.search input:focus{outline:none}
.search input::-webkit-search-cancel-button{display:none}
.search .clear{width:28px;height:28px;display:grid;place-items:center;color:var(--label-3);font-size:18px}
.picker{position:relative}
.picker select{position:absolute;inset:0;width:100%;height:100%;opacity:0;font-size:16px;cursor:pointer;-webkit-appearance:none;appearance:none}
.picker .v{display:inline-flex;align-items:center;gap:6px;color:var(--tint-ink);font-weight:500}
.picker .v svg{font-size:16px}
.lg{display:grid;grid-template-columns:104px minmax(0,1fr);column-gap:14px;padding:11px 20px;width:100%;text-align:left;font:inherit;color:inherit}
.lg[data-ctx]{cursor:pointer}
.lg[data-ctx]:active{background:rgba(0,0,0,.04)}
.lg .t{font-size:14px;color:var(--label-2);font-variant-numeric:tabular-nums;padding-top:1px;white-space:nowrap}
.lg .t small{display:block;font-size:13px;color:var(--label-3)}
.lg .meta{font-size:13px;font-weight:600;color:var(--label-2);display:flex;align-items:center;gap:6px}
.lg .meta svg{font-size:13px;color:var(--label-3);transition:transform .2s}
.lg.open .meta svg{transform:rotate(90deg)}
.lv-debug{color:var(--label-3)}
.lv-warn{color:var(--orange-ink)}
.lv-error{color:var(--red-ink)}
.lg .m{font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:14px;line-height:1.42;margin-top:3px;white-space:pre-wrap;overflow-wrap:anywhere;letter-spacing:0}
.lg pre{grid-column:2;margin-top:10px;padding:12px 14px;border-radius:12px;background:var(--bg);font-family:ui-monospace,"SF Mono",SFMono-Regular,Menlo,monospace;font-size:13px;line-height:1.45;white-space:pre-wrap;overflow-wrap:anywhere;letter-spacing:0;color:var(--label)}
.more{width:100%;min-height:50px;font-size:17px;font-weight:500;color:var(--tint-ink)}
.orow{display:flex;align-items:center;gap:16px;width:100%;padding:14px 16px 14px 20px;text-align:left}
.orow:active{background:rgba(0,0,0,.04)}
.orow .grow{flex:1;min-width:0}
.orow .nm{font-family:var(--serif);font-size:24px;font-weight:600;line-height:1.15;letter-spacing:-.01em;overflow-wrap:anywhere}
.orow .s{font-size:14px;color:var(--label-2);margin-top:3px;font-variant-numeric:tabular-nums}
.orow .r{display:grid;justify-items:end;gap:2px;flex:none}
.orow .tot{font-size:17px;font-weight:600;font-variant-numeric:tabular-nums}
.orow .chev{color:var(--label-3);font-size:18px;flex:none}
.st{font-size:14px;font-weight:600;color:var(--label-2)}
.st.s-ready{color:var(--tint-ink)}.st.s-preparing{color:var(--label)}.st.s-collected{color:var(--label-3)}.st.s-canceled{color:var(--red-ink)}
.orow.sim .nm{color:var(--label-2)}
.test{font-size:13px;font-weight:600;color:var(--label-3)}
.glyph{font-size:24px;flex:none}
.glyph.good{color:var(--green)}
.glyph.bad{color:var(--red)}
.glyph.none{color:var(--label-3)}
.mt16{margin-top:16px}.mt20{margin-top:20px}.mt24{margin-top:24px}.mt28{margin-top:28px}
dialog:focus,dialog:focus-visible{outline:none}
.detail .footnote{margin:8px 20px 0}
.ms{font-size:15px;color:var(--label-3);font-variant-numeric:tabular-nums;white-space:nowrap}
.rtile{width:44px;height:44px;border-radius:12px;display:grid;place-items:center;font-size:24px;color:#fff;background:var(--red);flex:none}
.intro{align-items:flex-start;padding:18px 20px}
.intro .k{font-size:19px;font-weight:650}
.intro .s{font-size:16px;line-height:1.4;margin-top:4px}
.big{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;min-height:56px;font-size:18px;font-weight:600;color:var(--tint-ink)}
.big.danger{color:var(--red)}
.big:disabled{opacity:.4}
.big:active:not(:disabled){background:rgba(0,0,0,.04)}
dialog.sheet .ag{background:var(--cell)}
dialog.sheet .gh{margin:22px 16px 8px}
.osheet .ohead{min-width:0}
.osheet .oname{font-family:var(--serif);font-size:34px;font-weight:600;line-height:1.1;letter-spacing:-.01em;overflow-wrap:anywhere}
.osheet .osub{font-size:16px;color:var(--label-2);margin-top:4px}
.choice{display:flex;align-items:center;gap:14px;width:100%;min-height:50px;padding:0 20px;text-align:left;font-size:17px}
.choice .ck{margin-left:auto;color:var(--tint);font-size:20px;stroke-width:2.75}
.choice:active:not(:disabled){background:rgba(0,0,0,.04)}
.choice.on{font-weight:600}
.item .k{font-weight:600}
.lines .ac{min-height:44px;padding:9px 20px}
.lines .k{font-size:16px}
.lines .v{font-size:16px;font-variant-numeric:tabular-nums;color:var(--label)}
.lines .total .k,.lines .total .v{font-weight:700;font-size:17px}
dialog.wide{width:min(560px,calc(100vw - 32px));max-height:calc(100vh - 48px);overflow:auto}
.dl{margin-top:16px;border-radius:18px;background:rgba(118,118,128,.08);overflow:hidden}
.dl .ac{min-height:42px;padding:8px 16px}
.dl .k{font-size:16px;max-width:70%}
.dl .v{font-size:16px;font-variant-numeric:tabular-nums}
.dl.list>*+*::before{left:16px}
dialog .dh{font-size:14px;font-weight:600;color:var(--label-2);margin:18px 6px 0}
dialog .fine{font-size:15px;color:var(--label-2);line-height:1.4;margin-top:14px;padding:0 6px}
.typed{font:inherit;font-size:28px;font-weight:600;letter-spacing:.2em;text-indent:.2em;text-align:center;height:64px;border-radius:18px;border:0;background:var(--fill);color:var(--label);width:100%;margin-top:18px;-webkit-appearance:none;appearance:none}
.typed:focus{outline:none;box-shadow:0 0 0 3px rgba(255,59,48,.35)}
.swrow{display:flex;align-items:center;gap:14px;margin-top:16px;padding:12px 16px;border-radius:18px;background:rgba(118,118,128,.08)}
.swrow .grow{flex:1;min-width:0}
.swrow .k{font-size:17px;font-weight:500}
.swrow .s{font-size:14px;color:var(--label-2);margin-top:2px}
.dialog-actions button:disabled{opacity:.4;transform:none}
.derr{color:var(--red-ink);font-weight:600;font-size:16px;margin-top:12px;padding:0 6px;display:flex;gap:8px;align-items:flex-start}
.derr svg{margin-top:3px}
.dialog-actions.one{grid-template-columns:1fr}
@media (max-width:1100px){.sv{grid-template-columns:300px minmax(0,1fr)}.detail{padding-left:28px;padding-right:max(28px,env(safe-area-inset-right))}}
@media (max-width:899px){
.sv{grid-template-columns:minmax(0,1fr)}
.side,.detail{grid-area:1/1}
.side{border-right:0;padding-right:max(20px,env(safe-area-inset-right))}
.detail{padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right))}
.sv.push .side{visibility:hidden}
.sv:not(.push) .detail{display:none}
.sv.push .detail{animation:pushin .32s cubic-bezier(.2,.9,.3,1)}
.srow.sel{background:none;color:inherit}
.srow.sel .sval{color:var(--label-2)}
.list>.srow.sel::before,.list>.srow.sel+.srow::before{display:block}
.srow .chev{display:block}
.pbar .back{visibility:visible}
.pane>h1,.side h1{font-size:34px}
.lg{grid-template-columns:minmax(0,1fr);row-gap:2px}
.lg .t{display:flex;gap:8px}
.lg .t small{display:inline}
.lg pre{grid-column:1}
.ac .k{max-width:60%}
}
@keyframes pushin{from{transform:translateX(48px);opacity:0}}
@media (prefers-reduced-motion:reduce){.sv.push .detail{animation:none}}
`;

function bar(right = ""): string {
  return `<div class="pbar"><button class="navbtn back" type="button" data-back>${icon("chevronLeft")}Admin</button><div class="right">${right}</div></div>`;
}

function pane(id: string, title: string, inner: string, right = ""): string {
  return `<section class="pane" data-pane="${id}" hidden aria-labelledby="t-${id}">${bar(right)}<h1 id="t-${id}">${title}</h1>${inner}</section>`;
}

function sidebar(email: string): string {
  const groups = [0, 1, 2, 3].map((g) =>
    `<nav class="group list slist">${SECTIONS.filter((s) => s.group === g).map((s) =>
      `<button class="srow${s.id === "reset" ? " danger" : ""}" type="button" data-sec="${s.id}"><span class="stile">${icon(s.icon)}</span><span class="sname">${s.title}</span><span class="sval" id="sv-${s.id}"></span>${icon("chevron", "chev")}</button>`).join("")}</nav>`).join("");
  const top = `<div class="sbar"><span><a class="navbtn web-only" href="/staff">${icon("layout")}Pages</a><button class="navbtn app-only" type="button" data-exit>${icon("logOut")}Exit staff mode</button></span></div>`;
  const account = `<nav class="group list slist"><a class="srow" href="/cdn-cgi/access/logout"><span class="stile">${icon("logOut")}</span><span class="sname">Sign out</span>${icon("chevron", "chev")}</a></nav>`;
  return `<aside class="side" id="side">${top}<h1>Admin</h1>${groups}${account}<p class="sfoot">Signed in as <b id="who">${escapeHtml(email)}</b>. Cloudflare Access signs you out after 24 hours.</p></aside>`;
}

function gate(id: string, title: string, text: string, action: string, hidden: boolean): string {
  return `<main class="signin" id="${id}"${hidden ? " hidden" : ""}><form method="get" action="/staff/admin"><div class="appicon admin">${icon("lock")}</div><h1>${title}</h1><p>${text}</p><button class="primary" type="submit">${action}</button><a class="navbtn" href="/cdn-cgi/access/logout">Sign out</a></form></main>`;
}

export function forbiddenBody(): string {
  return gate("forbidden", "No access", "This page is for the booth owners. Sign in with an authorized account to open the admin tools.", "Try again", false);
}

export function adminBody(email: string): string {
  const kiosks = pane("kiosks", "Kiosks", `<p class="lede">Live status of every kiosk, updated every few seconds. Controls reach a kiosk only while it's connected.</p><div id="kList"></div>`);
  const logs = pane("logs", "Logs", `<label class="search">${icon("search")}<input id="logQ" type="search" placeholder="Search messages and context" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"><button class="clear" type="button" id="logQClear" hidden aria-label="Clear search">${icon("circleX")}</button></label>
<div class="gh">Filters</div><div class="group list ag">
<div class="ac picker"><span class="k">Device</span><span class="v" id="logDevLabel">All devices${icon("updown")}</span><select id="logDev" aria-label="Device"><option value="">All devices</option></select></div>
<div class="ac"><span class="k">Level</span><div class="seg" role="radiogroup" aria-label="Level" id="logLevel"><button type="button" data-level="debug" class="sel">All</button><button type="button" data-level="info">Info</button><button type="button" data-level="warn">Warnings</button><button type="button" data-level="error">Errors</button></div></div>
<div class="ac"><span class="k">Time</span><div class="seg" role="radiogroup" aria-label="Time" id="logWin"><button type="button" data-win="15m">15 min</button><button type="button" data-win="1h" class="sel">1 hour</button><button type="button" data-win="today">Today</button><button type="button" data-win="all">All</button></div></div>
</div><div class="gh"><span>Newest first</span><span class="r" id="logCount"></span></div><div id="logList"></div>`, `<button class="navbtn" type="button" id="logRefresh">${icon("refresh")}Refresh</button>`);
  const square = pane("square", "Square", `<div id="sqBody"></div>`, `<button class="navbtn" type="button" id="sqCheck">${icon("refresh")}Check again</button>`);
  const orders = pane("orders", "Orders", `<label class="search">${icon("search")}<input id="ordQ" type="search" placeholder="Name, receipt link, reference, number or payment ID" autocomplete="off" autocapitalize="off" spellcheck="false" enterkeyhint="search"><button class="clear" type="button" id="ordQClear" hidden aria-label="Clear search">${icon("circleX")}</button></label><div class="gh"><span id="ordHead">Newest</span><span class="r" id="ordCount"></span></div><div id="ordList"></div>`);
  const selftest = pane("selftest", "Self-test", `<p class="lede">Checks that the booth can reach its database, the live hub, Square's API and the Square catalog. Takes a few seconds and changes nothing.</p><div class="group ag mt24"><button class="big" type="button" id="runTest">${icon("play")}Run self-test</button></div><div id="testBody"></div>`);
  const cleanup = pane("cleanup", "Cleanup", `<div id="cleanBody"></div>`);
  const reset = pane("reset", "Reset", `<div id="resetBody"></div>`);
  const dialogs = `<div id="toast" class="toast plain" hidden role="status"></div>
<dialog id="confirm" aria-labelledby="confirmTitle" aria-describedby="confirmText"><h3 id="confirmTitle"></h3><p id="confirmText"></p><div class="dialog-actions"><button class="cancel" id="confirmNo" type="button">Cancel</button><button class="confirm" id="confirmYes" type="button">Confirm</button></div></dialog>
<dialog id="orderSheet" class="sheet osheet" aria-labelledby="osName"><div class="sheet-head"><div class="ohead"><h3 class="oname" id="osName"></h3><div class="osub" id="osSub"></div></div><button class="link" id="osDone" type="button">Done</button></div><div id="osBody"></div></dialog>
<dialog id="reset1" class="wide" aria-labelledby="r1Title"><h3 id="r1Title">Reset everything?</h3><div id="r1Body"></div><div class="dialog-actions"><button class="cancel" type="button" data-close="reset1">Cancel</button><button class="confirm danger" type="button" id="r1Go">Continue</button></div></dialog>
<dialog id="reset2" aria-labelledby="r2Title"><h3 id="r2Title">Type RESET to confirm</h3><p>This can't be undone. Make sure no customer is paying on any kiosk.</p><label for="r2Input" class="vh">Type RESET</label><input id="r2Input" class="typed" autocomplete="off" autocapitalize="characters" autocorrect="off" spellcheck="false" placeholder="RESET" enterkeyhint="done"><div class="swrow"><div class="grow"><div class="k">Download a backup first</div><div class="s">Orders, kiosks, alerts and stats as a JSON file.</div></div><button class="switch" role="switch" type="button" id="r2Backup" aria-checked="true" aria-label="Download a backup first"></button></div><div class="derr" id="r2Err" role="alert" hidden></div><div class="dialog-actions"><button class="cancel" type="button" id="r2Cancel">Cancel</button><button class="confirm danger" type="button" id="r2Go" disabled>Reset everything</button></div></dialog>
<dialog id="reset3" class="wide" aria-labelledby="r3Title"><h3 id="r3Title">The booth was reset</h3><div id="r3Body"></div><div class="dialog-actions one"><button class="confirm" type="button" data-close="reset3">Done</button></div></dialog>`;
  return `<div class="sv" id="app">${sidebar(email)}<main class="detail" id="detail">${kiosks}${logs}${square}${orders}${selftest}${cleanup}${reset}</main></div>${gate("expired", "Session ended", "Your admin sign-in has ended. Reload to sign in again.", "Reload", true)}${dialogs}`;
}

const SCRIPT = String.raw`
(function(){
"use strict";
var ICONS = __ICONS__;
var TOPPINGS = __TOPPINGS__;
var IN_APP = /BoothStaffApp\//.test(navigator.userAgent);
var NET_MSG = "Can't reach the booth. Check the connection and try again.";
var STATUSES = ["paid","preparing","ready","collected","canceled"];
var STATUS_LABEL = {paid:"Waiting",preparing:"Scooping",ready:"Ready",collected:"Handed off",canceled:"Canceled"};
var SCREEN_LABEL = {attract:"Welcome screen",builder:"Building an order",summary:"Reviewing the order",name:"Entering a name",confirmation:"Receipt",roleSetup:"Role picker",staff:"Staff page",payment:"Paying",checkout:"Paying"};
var CONTROL_TIMEOUT = 15000;

function ico(n,c){return '<svg class="i'+(c?" "+c:"")+'" viewBox="0 0 24 24" aria-hidden="true">'+ICONS[n]+"</svg>";}
var $ = function(id){return document.getElementById(id);};
function esc(s){return String(s==null?"":s).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function money(c){if(c==null)return "";var neg=c<0;c=Math.abs(c);return (neg?"-":"")+"$"+(c/100).toFixed(2);}
function plural(n,w,ws){return n+" "+(n===1?w:(ws||w+"s"));}
function titleCase(s){return String(s).replace(/[-_]/g," ").replace(/\b\w/g,function(c){return c.toUpperCase();});}
function dis(b){return b?" disabled":"";}
if(IN_APP)document.body.classList.add("app");

var ended=false, current=null;
var state=null, stateAt=0, serverOffset=0, polling=false, lastPoll=0;
var ctl={}, debugWant={};
var narrowQuery=window.matchMedia?window.matchMedia("(max-width: 899px)"):null;
function narrow(){return !!(narrowQuery&&narrowQuery.matches);}

function now(){return Date.now()+serverOffset;}
function span(ms){
  var s=Math.max(0,Math.round(ms/1000));
  if(s<60)return s+" s";var m=Math.floor(s/60);if(m<60)return m+" min";
  var h=Math.floor(m/60);if(h<48)return h+" h"+(m%60?" "+(m%60)+" min":"");
  return Math.floor(h/24)+" days";
}
function ago(ms){
  if(ms==null)return "Never";
  var d=now()-ms;
  if(d<10000)return "Just now";
  return span(d)+" ago";
}
function fromNow(ms){
  var d=ms-now();
  if(Math.abs(d)<30000)return "now";
  return d>0?"in "+span(d):span(-d)+" ago";
}
function agoSpan(ms){return '<span data-ago="'+(ms==null?"":ms)+'">'+ago(ms)+"</span>";}
function relSpan(ms){return '<span data-rel="'+ms+'">'+fromNow(ms)+"</span>";}
function sameDay(a,b){var x=new Date(a),y=new Date(b);return x.getFullYear()===y.getFullYear()&&x.getMonth()===y.getMonth()&&x.getDate()===y.getDate();}
function clock(ms){return new Date(ms).toLocaleTimeString([],{hour:"numeric",minute:"2-digit"});}
function clockSec(ms){return new Date(ms).toLocaleTimeString([],{hour:"numeric",minute:"2-digit",second:"2-digit"});}
function day(ms){return new Date(ms).toLocaleDateString([],{month:"short",day:"numeric"});}
function when(ms){if(ms==null)return "";return sameDay(ms,Date.now())?clock(ms):day(ms)+", "+clock(ms);}
function fullWhen(ms){return new Date(ms).toLocaleString([],{weekday:"short",month:"short",day:"numeric",year:"numeric",hour:"numeric",minute:"2-digit",second:"2-digit"});}
function dayStart(){var d=new Date();d.setHours(0,0,0,0);return d.getTime();}
function spinner(text){return '<div class="aempty">'+ico("loader","spin")+esc(text||"Loading")+"</div>";}
function emptyGroup(text){return '<div class="group ag"><div class="aempty">'+esc(text)+"</div></div>";}
function errGroup(msg){return '<div class="group ag"><div class="aempty bad">'+ico("alert")+esc(msg)+"</div></div>";}

function row(k,v,cls,sub){
  return '<div class="ac">'+(sub!=null?'<div class="grow"><div class="k">'+esc(k)+'</div><div class="s">'+sub+"</div></div>":'<span class="k">'+esc(k)+"</span>")+'<span class="v'+(cls?" "+cls:"")+'">'+v+"</span></div>";
}
function gh(left,right){return '<div class="gh"><span>'+esc(left)+"</span>"+(right?'<span class="r">'+right+"</span>":"")+"</div>";}

function Ended(){this.ended=true;this.message="Session ended";}

function api(method,path,body){
  if(ended)return Promise.reject(new Ended());
  var h={};
  if(body!==undefined)h["Content-Type"]="application/json";
  return fetch(path,{method:method,headers:h,cache:"no-store",credentials:"same-origin",redirect:"manual",body:body===undefined?undefined:JSON.stringify(body)}).then(function(r){
    if(ended)throw new Ended();
    if(r.type==="opaqueredirect"||r.status===401||r.status===403){endSession();throw new Ended();}
    return r.text().then(function(text){
      var j=null;try{j=text?JSON.parse(text):null;}catch(e){}
      var err=j&&j.error;
      if(!r.ok){
        var e=new Error((err&&err.message)||(typeof err==="string"?err:"")||("The booth answered with an error ("+r.status+")."));
        e.status=r.status;e.code=err&&err.code;e.body=j;throw e;
      }
      return {body:j,response:r};
    });
  },function(e){if(e&&e.ended)throw e;throw new Error(NET_MSG);});
}
function get(path){return api("GET",path).then(function(x){return x.body;});}
function post(path,body){return api("POST",path,body===undefined?{}:body).then(function(x){return x.body;});}

var toastTimer=null;
function toast(text){
  var t=$("toast");clearTimeout(toastTimer);
  var host=document.querySelector("dialog[open]")||document.body;
  if(t.parentNode!==host)host.appendChild(t);
  t.textContent=text;t.hidden=false;
  toastTimer=setTimeout(function(){t.hidden=true;},6000);
}
function fail(e){if(e&&e.ended)return;toast(e&&e.message||NET_MSG);}

function showDialog(d){
  if(d.showModal){if(!d.open)d.showModal();}else d.setAttribute("open","");
  if(!d.hasAttribute("tabindex"))d.setAttribute("tabindex","-1");
  var f=document.activeElement;if(f&&f.tagName==="BUTTON"&&d.contains(f))d.focus();
}
function hideDialog(d){if(d.close){if(d.open)d.close();}else d.removeAttribute("open");}
var pendingConfirm=null;
function ask(title,text,yes,danger,onYes,no){
  pendingConfirm=onYes;
  $("confirmTitle").textContent=title;
  $("confirmText").textContent=text;
  $("confirmYes").className="confirm"+(danger?" danger":"");
  $("confirmYes").textContent=yes;
  $("confirmNo").textContent=no||"Cancel";
  showDialog($("confirm"));
}

function askExit(){
  ask("Exit staff mode?","This iPad goes back to the role picker, where it can start as a kiosk or open a staff page again.","Exit",false,function(){
    var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.boothApp;
    if(h)h.postMessage({type:"exitStaffMode"});
    else toast("This version of the app can't switch roles from here. Relaunch it to pick a role.");
  });
}

function endSession(){
  if(ended)return;
  ended=true;
  document.querySelectorAll("dialog").forEach(hideDialog);
  pendingConfirm=null;
  $("app").hidden=true;$("expired").hidden=false;
}

function show(id){
  current=id;
  document.querySelectorAll("[data-sec]").forEach(function(b){
    var on=b.getAttribute("data-sec")===id;
    b.classList.toggle("sel",on);
    if(on)b.setAttribute("aria-current","page");else b.removeAttribute("aria-current");
  });
  document.querySelectorAll("[data-pane]").forEach(function(p){p.hidden=p.getAttribute("data-pane")!==id;});
  $("app").classList.add("push");
  $("detail").scrollTop=0;
  enter(id);
}
function back(){
  current=null;
  $("app").classList.remove("push");
  document.querySelectorAll("[data-sec]").forEach(function(b){b.classList.remove("sel");b.removeAttribute("aria-current");});
}
if(narrowQuery){
  var onNarrow=function(){if(!ended&&!narrow()&&!current)show("kiosks");};
  if(narrowQuery.addEventListener)narrowQuery.addEventListener("change",onNarrow);else if(narrowQuery.addListener)narrowQuery.addListener(onNarrow);
}

function enter(id){
  if(id==="kiosks"){renderKiosks();loadState();}
  else if(id==="logs"){if(!state||Date.now()-stateAt>30000)loadState();if(!logs.loaded)loadLogs(true);}
  else if(id==="square"){if(!square)loadSquare();}
  else if(id==="orders"){if(!state)loadState();if(!orders.loaded)loadOrders();}
  else if(id==="cleanup")loadCleanup();
  else if(id==="reset")loadReset();
}

function loadState(){
  if(polling)return Promise.resolve();
  polling=true;lastPoll=Date.now();
  return get("/v1/admin/state").then(function(s){
    polling=false;
    state=s;stateAt=Date.now();
    if(s.serverTime)serverOffset=s.serverTime-Date.now();
    checkControls();
    Object.keys(debugWant).forEach(function(id){var k=kioskById(id);if(!k||k.debug===debugWant[id])delete debugWant[id];});
    renderSide();
    if(current==="kiosks")renderKiosks();
    if(current==="logs")renderLogFilters();
  },function(e){
    polling=false;
    if(e&&e.ended)return;
    if(current==="kiosks"&&!state)$("kList").innerHTML=errGroup(e.message);
  });
}

function renderSide(){
  if(!state)return;
  var list=state.kiosks||[],on=list.filter(function(k){return k.online;}).length;
  $("sv-kiosks").textContent=list.length?(on===list.length?on+" online":on+" of "+list.length+" online"):"None";
}

function kioskById(id){return state&&state.kiosks.filter(function(k){return k.id===id;})[0]||null;}
function kioskSession(id){return state&&state.sessions?state.sessions.filter(function(s){return s.kiosk===id;})[0]||null:null;}
function deviceLabel(id){
  if(id==="booth-admin")return "Booth server";
  var k=kioskById(id);
  return k?k.name:id;
}
function flavorName(id){
  var f=state&&state.flavors&&state.flavors.filter(function(x){return x.id===id;})[0];
  return f?f.name:titleCase(id);
}
function toppingName(id){return Object.prototype.hasOwnProperty.call(TOPPINGS,id)?TOPPINGS[id]:titleCase(id);}
function vesselName(v){return v==="cone"?"Waffle cone":v==="cup"?"Cup":titleCase(v);}

function battery(pct,charging){return Math.round(pct)+"%"+(charging?", charging":"");}

function kioskRows(k){
  var h=k.health,s=kioskSession(k.id),rows=[];
  rows.push(row("Last seen",k.connected?"Now":agoSpan(k.lastSeenAt),k.online?"":"warn"));
  rows.push(row("Live connection",k.connected?"Connected":"Not connected",k.connected?"":"warn"));
  var scr=s?(s.paying?"Paying":(SCREEN_LABEL[s.screen]||titleCase(s.screen))):(k.screen?(SCREEN_LABEL[k.screen]||titleCase(k.screen)):"Unknown");
  rows.push(row("Current screen",esc(scr),""));
  if(!h){rows.push(row("Health","No report yet","warn"));return rows.join("");}
  rows.push(row("App version",esc(h.appVersion||"Unknown"),""));
  var env=h.environment?titleCase(h.environment):"Unknown environment";
  rows.push(row("Square",esc(env+", "+(h.authorized?"authorized":(h.authorizationState?h.authorizationState.toLowerCase():"not authorized"))),h.authorized?"":"bad"));
  rows.push(row("Payments",h.simulatePayment?"Simulated":"Real card payments",h.simulatePayment?"warn":""));
  rows.push(row("Card reader",h.readerReady?"Ready":"Not ready",h.readerReady||h.simulatePayment?"":"bad"));
  (h.readers||[]).forEach(function(r){
    var parts=[titleCase(r.state||"unknown")];
    if(r.batteryPercent!=null&&r.batteryPercent>=0)parts.push(battery(r.batteryPercent,r.isCharging));
    var low=r.batteryPercent!=null&&r.batteryPercent>=0&&r.batteryPercent<=20&&!r.isCharging;
    rows.push(row(r.name||"Reader",esc(parts.join(", ")),low?"bad":"",r.model?esc(r.model):null));
  });
  if(h.deviceBattery&&h.deviceBattery.percent>=0){
    var b=h.deviceBattery;
    rows.push(row("iPad battery",battery(b.percent,b.charging),b.percent<=20&&!b.charging?"bad":""));
  } else rows.push(row("iPad battery","Unknown",""));
  var o=h.outbox;
  if(!o)rows.push(row("Outbox","Unknown",""));
  else if(!o.orders&&!o.events)rows.push(row("Outbox","Empty",""));
  else rows.push(row("Outbox",esc([o.orders?plural(o.orders,"order"):"",o.events?plural(o.events,"event"):""].filter(Boolean).join(", ")+" waiting"),"warn"));
  var c=h.catalog||{ok:true,status:"",error:null};
  rows.push(row("Catalog",esc(c.ok?(c.status?titleCase(c.status):"OK"):(c.error||c.status||"Not loaded")),c.ok?"":"warn"));
  if(h.lastError){
    var at=h.lastErrorAt?Date.parse(h.lastErrorAt):NaN;
    rows.push(row("Last error",esc(h.lastError)+(isNaN(at)?"":"<small>"+esc(when(at))+"</small>"),"warn"));
  }
  if(h.epoch!=null&&state.epoch!=null&&h.epoch<state.epoch)rows.push(row("Reset pending","Kiosk hasn't picked up the reset yet","warn"));
  return rows.join("");
}

var CONTROLS=[
  ["attract","Send back to welcome screen","Cancels the customer's current order. A payment in progress is never interrupted."],
  ["reloadCatalog","Reload catalog","Fetches items and prices from Square again."],
  ["resync","Force resync","Refetches the booth state and sends anything the kiosk is holding."]
];

function controlResult(k,op){
  var c=ctl[k.id+":"+op];
  if(!c)return "";
  if(c.status==="sending")return '<span class="res">'+ico("loader","spin")+"Sending</span>";
  if(c.status==="sent")return '<span class="res">'+ico("loader","spin")+"Sent</span>";
  if(c.status==="applied")return '<span class="res good">'+ico("check")+"Done</span>";
  if(c.status==="rejected")return '<span class="res warn">'+esc(c.message||"The kiosk refused")+"</span>";
  if(c.status==="timeout")return '<span class="res warn">No answer from the kiosk</span>';
  return '<span class="res bad">'+esc(c.message||"Didn't send")+"</span>";
}

function kioskBlock(k){
  var debug=Object.prototype.hasOwnProperty.call(debugWant,k.id)?debugWant[k.id]:k.debug;
  var tag=k.name===("Kiosk "+k.tag)?"":'<span class="tagid">'+esc(k.tag)+"</span>";
  var head='<div class="kh"><h2>'+esc(k.name)+"</h2>"+tag+'<span class="dot'+(k.online?"":" off")+'">'+(k.online?"Online":"Offline")+'</span><span class="dbg">Debug tools<button class="switch" role="switch" type="button" data-debug="'+esc(k.id)+'" aria-checked="'+(!!debug)+'" aria-label="Debug tools on '+esc(k.name)+'"></button></span></div>';
  var acts=CONTROLS.map(function(c){
    return '<button class="btnrow" type="button" data-ctl="'+c[0]+'" data-k="'+esc(k.id)+'"'+dis(!k.connected)+'><div class="grow"><div class="k">'+c[1]+'</div><div class="s">'+c[2]+"</div></div>"+controlResult(k,c[0])+"</button>";
  }).join("");
  var note=k.connected?"":'<p class="footnote">Controls need a live connection, and '+esc(k.name)+" isn't connected.</p>";
  return head+'<div class="group list ag">'+kioskRows(k)+row("Device ID",'<span class="mono">'+esc(k.id)+"</span>","")+'</div><div class="gh">Controls</div><div class="group list ag">'+acts+"</div>"+note+
    '<div class="group ag mt16"><button class="btnrow danger" type="button" data-forget="'+esc(k.id)+'"><div class="grow"><div class="k">Forget kiosk</div><div class="s">Removes it from the kiosk list and closes its alerts.</div></div></button></div>';
}

function renderKiosks(){
  var el=$("kList");
  if(!state){if(!el.innerHTML)el.innerHTML='<div class="group ag mt28">'+spinner()+"</div>";return;}
  var list=state.kiosks||[];
  if(!list.length){el.innerHTML='<div class="mt28">'+emptyGroup("No kiosk has connected yet.")+"</div>";return;}
  el.innerHTML=list.slice().sort(function(a,b){return (b.online-a.online)||a.name.localeCompare(b.name);}).map(kioskBlock).join("");
}

function checkControls(){
  var t=Date.now();
  Object.keys(ctl).forEach(function(key){
    var c=ctl[key];
    if(c.status!=="sent")return;
    var s=kioskSession(c.kiosk),r=s&&s.results&&s.results.filter(function(x){return x.id===c.id;})[0];
    if(r){c.status=r.status==="rejected"?"rejected":"applied";c.message=r.message||"";}
    else if(t-c.at>CONTROL_TIMEOUT)c.status="timeout";
  });
}
function controlsPending(){return Object.keys(ctl).some(function(k){return ctl[k].status==="sent"||ctl[k].status==="sending";});}

function sendControl(id,op){
  var key=id+":"+op;
  ctl[key]={kiosk:id,op:op,status:"sending",at:Date.now()};
  renderKiosks();
  post("/v1/admin/kiosks/"+encodeURIComponent(id)+"/control",{op:op}).then(function(r){
    ctl[key]={kiosk:id,op:op,id:r.id,status:"sent",at:Date.now()};
    renderKiosks();
    setTimeout(loadState,700);
  },function(e){
    if(e&&e.ended)return;
    ctl[key]={kiosk:id,op:op,status:"error",message:e.code==="kiosk_offline"?"Not connected":e.message,at:Date.now()};
    renderKiosks();
    if(e.code!=="kiosk_offline")toast(e.message);
  });
}

function askControl(id,op){
  var k=kioskById(id);if(!k)return;
  if(op==="attract")ask("Send "+k.name+" back to the welcome screen?","This cancels the customer's current order on "+k.name+". A payment in progress is never interrupted; the kiosk refuses instead.","Send back",true,function(){sendControl(id,op);});
  else sendControl(id,op);
}

function toggleDebug(id){
  var k=kioskById(id);if(!k)return;
  var want=!(Object.prototype.hasOwnProperty.call(debugWant,id)?debugWant[id]:k.debug);
  debugWant[id]=want;renderKiosks();
  post("/v1/admin/kiosks/"+encodeURIComponent(id)+"/debug",{debug:want}).then(function(){loadState();},function(e){delete debugWant[id];renderKiosks();fail(e);});
}

function askForget(id){
  var k=kioskById(id);if(!k)return;
  ask("Forget "+k.name+"?","It leaves the kiosk list and its alerts close. If the iPad connects again it comes back as Kiosk "+k.tag+".","Forget",true,function(){
    post("/v1/admin/kiosks/"+encodeURIComponent(id)+"/forget").then(function(){
      if(state)state.kiosks=state.kiosks.filter(function(x){return x.id!==id;});
      renderKiosks();renderSide();loadState();
      toast(k.name+" was forgotten.");
    },fail);
  });
}

function freshLogs(){return {device:"",level:"debug",win:"1h",q:"",since:0,lines:[],next:null,devices:[],loaded:false,loading:false,seq:0,open:{}};}
var logs=freshLogs(), logTimer=null;

function logSince(){
  var t=Date.now();
  return logs.win==="15m"?t-15*60000:logs.win==="1h"?t-60*60000:logs.win==="today"?dayStart():0;
}
function loadLogs(fresh){
  var seq=++logs.seq;
  if(fresh){logs.since=logSince();logs.open={};}
  var p=["limit=100"];
  if(logs.device)p.push("device="+encodeURIComponent(logs.device));
  if(logs.level!=="debug")p.push("level="+logs.level);
  if(logs.since)p.push("since="+logs.since);
  if(logs.q)p.push("q="+encodeURIComponent(logs.q));
  if(!fresh&&logs.next)p.push("before="+encodeURIComponent(logs.next));
  logs.loading=true;
  if(fresh&&!logs.lines.length)$("logList").innerHTML='<div class="group ag">'+spinner()+"</div>";
  else renderLogs();
  get("/v1/admin/logs?"+p.join("&")).then(function(r){
    if(seq!==logs.seq)return;
    logs.loading=false;logs.loaded=true;
    logs.lines=fresh?r.lines:logs.lines.concat(r.lines);
    logs.next=r.next;
    if(r.devices)logs.devices=r.devices;
    renderLogFilters();renderLogs();
  },function(e){
    if(seq!==logs.seq||(e&&e.ended))return;
    logs.loading=false;
    if(fresh){logs.lines=[];$("logList").innerHTML=errGroup(e.message);$("logCount").textContent="";}
    else{renderLogs();toast(e.message);}
  });
}

function renderLogFilters(){
  var sel=$("logDev"),opts=[["","All devices"]],seen={};
  logs.devices.forEach(function(d){seen[d.device]=1;opts.push([d.device,deviceLabel(d.device)+" ("+d.lines+")"]);});
  if(logs.device&&!seen[logs.device])opts.push([logs.device,deviceLabel(logs.device)]);
  sel.innerHTML=opts.map(function(o){return '<option value="'+esc(o[0])+'"'+(o[0]===logs.device?" selected":"")+">"+esc(o[1])+"</option>";}).join("");
  $("logDevLabel").innerHTML=esc(logs.device?deviceLabel(logs.device):"All devices")+ico("updown");
  document.querySelectorAll("[data-level]").forEach(function(b){var on=b.getAttribute("data-level")===logs.level;b.classList.toggle("sel",on);b.setAttribute("aria-checked",on);b.setAttribute("role","radio");});
  document.querySelectorAll("[data-win]").forEach(function(b){var on=b.getAttribute("data-win")===logs.win;b.classList.toggle("sel",on);b.setAttribute("aria-checked",on);b.setAttribute("role","radio");});
  $("logQClear").hidden=!$("logQ").value;
}

var LEVEL_LABEL={debug:"Debug",info:"Info",warn:"Warning",error:"Error"};
function logLine(l){
  var has=l.context!=null&&!(typeof l.context==="object"&&!Object.keys(l.context).length);
  var open=has&&logs.open[l.id];
  var today=sameDay(l.ts,Date.now());
  var meta='<div class="meta"><span class="lv-'+esc(l.level)+'">'+(LEVEL_LABEL[l.level]||esc(l.level))+"</span><span>"+esc(deviceLabel(l.device))+"</span>"+(l.app_version?"<span>"+esc(l.app_version)+"</span>":"")+(has?ico("chevron"):"")+"</div>";
  var attrs=has?' data-ctx="'+esc(l.id)+'" role="button" tabindex="0" aria-expanded="'+(!!open)+'"':"";
  return '<div class="lg'+(open?" open":"")+'"'+attrs+'><span class="t">'+clockSec(l.ts)+(today?"":"<small>"+esc(day(l.ts))+"</small>")+'</span><div>'+meta+'<div class="m">'+esc(l.message)+"</div></div>"+(open?"<pre>"+esc(JSON.stringify(l.context,null,2))+"</pre>":"")+"</div>";
}
function renderLogs(){
  var n=logs.lines.length;
  $("logCount").textContent=n?(logs.next?"Showing "+n:plural(n,"line")):"";
  if(!n){
    $("logList").innerHTML=emptyGroup(logs.q||logs.device||logs.level!=="debug"||logs.win!=="all"?"No log lines match these filters.":"No log lines yet.");
    return;
  }
  var more=logs.next?'<button class="more" type="button" id="logMore"'+dis(logs.loading)+">"+(logs.loading?ico("loader","spin")+" Loading":"Load older")+"</button>":"";
  $("logList").innerHTML='<div class="group list ag">'+logs.lines.map(logLine).join("")+more+"</div>";
}
function toggleLog(id){
  logs.open[id]=!logs.open[id];
  renderLogs();
}

var square=null, sqLoading=false, sqRefresh=null;
function loadSquare(){
  if(sqLoading)return;
  sqLoading=true;
  if(!square)$("sqBody").innerHTML='<div class="group ag mt28">'+spinner("Checking Square")+"</div>";
  $("sqCheck").disabled=true;$("sqCheck").innerHTML=ico("loader","spin")+"Checking";
  get("/v1/admin/square").then(function(s){
    sqLoading=false;square=s;renderSquare();
  },function(e){
    sqLoading=false;
    if(e&&e.ended)return;
    if(!square)$("sqBody").innerHTML='<div class="mt28">'+errGroup(e.message)+"</div>";else toast(e.message);
    resetSqButton();
  });
}
function resetSqButton(){$("sqCheck").disabled=false;$("sqCheck").innerHTML=ico("refresh")+"Check again";}

function renderSquare(){
  resetSqButton();
  var s=square;if(!s)return;
  $("sv-square").textContent=s.connected?"Connected":"Not connected";
  var o=s.oauth,html=gh("Connection");
  html+='<div class="group list ag">';
  html+=row("Status",s.connected?'<span class="dot">Connected</span>':'<span class="dot red">Not connected</span>',s.connected?"":"bad");
  html+=row("Source",s.source==="oauth"?"OAuth":s.source==="static"?"Static token":"None","");
  html+=row("Environment",s.environment==="sandbox"?"Sandbox":"Production",s.environment==="sandbox"?"warn":"");
  if(s.location)html+=row("Location",esc(s.location.name||"Unnamed")+'<small class="mono">'+esc(s.location.id)+"</small>","");
  else if(s.locationId)html+=row("Location",'<span class="mono">'+esc(s.locationId)+"</span>","");
  if(s.reachable)html+=row("Square API",s.reachable.ok?"Reachable":esc(s.reachable.error||"Not reachable"),s.reachable.ok?"":"bad");
  html+="</div>";
  html+=gh("Token")+'<div class="group list ag">';
  if(s.source==="static")html+=row("Expires","Static token, doesn't expire","");
  else if(s.expiresAt)html+=row("Expires",esc(when(s.expiresAt))+"<small>"+relSpan(s.expiresAt)+"</small>",s.expiresAt-now()<3*86400000?"warn":"");
  else html+=row("Expires",s.connected?"No expiry":"Not connected","");
  if(o){
    var outcome=o.lastRefreshError?'<span class="bad">'+esc(o.lastRefreshError)+"</span>":"OK";
    html+=row("Last refresh",esc(when(o.refreshedAt))+"<small>"+(o.lastRefreshError?"Last attempt "+esc(when(o.lastRefreshAttemptAt||o.refreshedAt))+": ":"")+outcome+"</small>",o.lastRefreshError?"bad":"");
    html+=row("Refresh due",esc(when(o.refreshDueAt))+"<small>"+relSpan(o.refreshDueAt)+"</small>","");
    if(o.merchantId)html+=row("Merchant",'<span class="mono">'+esc(o.merchantId)+"</span>","");
  } else html+=row("OAuth","No stored connection","");
  var res="";
  if(sqRefresh){
    res=sqRefresh.pending?'<span class="res">'+ico("loader","spin")+"Refreshing</span>":'<span class="res '+(sqRefresh.cls||"")+'">'+esc(sqRefresh.text)+"</span>";
  }
  html+='</div><div class="group list ag mt16"><button class="btnrow" type="button" id="sqRefresh"'+dis(sqRefresh&&sqRefresh.pending)+'><div class="grow"><div class="k">Refresh token now</div><div class="s">Asks Square for a new access token right away.</div></div>'+res+'</button><button class="btnrow" type="button" id="sqConnect"><div class="grow"><div class="k">Connect Square</div><div class="s">Signs in to Square and replaces the stored connection.</div></div>'+ico("external","lead")+"</button></div>";
  var c=s.catalog;
  if(!c){html+=gh("Catalog")+emptyGroup(s.connected?"The catalog couldn't be checked.":"Connect Square to check the catalog.");}
  else{
    html+=gh("Catalog, category "+(c.categoryName||"not set"),c.ok?'<span class="good">'+ico("circleCheck")+" All items match</span>":"");
    html+='<div class="group list ag">';
    if(c.error)html+='<div class="ac"><span class="glyph bad">'+ico("circleX")+'</span><div class="grow"><div class="k bad">'+esc(c.error)+"</div></div></div>";
    c.items.forEach(function(i){
      var right=i.ok?money(i.foundCents)+'</span><span class="glyph good">'+ico("circleCheck"):(i.problem?'<span class="bad">'+esc(i.problem)+(i.foundCents!=null?", found "+money(i.foundCents):"")+"</span>":"Not checked")+'</span><span class="glyph '+(i.problem?"bad":"none")+'">'+ico("circleX");
      html+='<div class="ac"><div class="grow"><div class="k">'+esc(i.name)+'</div><div class="s">Expected '+money(i.expectedCents)+'</div></div><span class="v">'+right+"</span></div>";
    });
    html+="</div>";
    if(c.extras&&c.extras.length)html+='<p class="footnote">Also in the category: '+esc(c.extras.join(", "))+". Kiosks ignore these.</p>";
  }
  $("sqBody").innerHTML=html;
}

function refreshToken(){
  sqRefresh={pending:true};renderSquare();
  api("POST","/v1/admin/square/refresh",{}).then(function(x){
    var r=x.body;
    sqRefresh=r.status==="refreshed"?{text:"Refreshed"+(r.expiresAt?", expires "+when(r.expiresAt):""),cls:"good"}:{text:"Not refreshed: "+(r.reason||"skipped"),cls:"warn"};
    renderSquare();loadSquare();
  },function(e){
    if(e&&e.ended)return;
    sqRefresh={text:"Failed: "+e.message,cls:"bad"};renderSquare();loadSquare();
  });
}

function askConnect(){
  ask("Connect Square?","This opens Square's sign-in. When you approve, the new connection replaces the one stored now, and kiosks pick it up on their next checkout.","Open Square",false,function(){
    post("/v1/admin/square/connect",{}).then(function(r){
      if(r&&r.url)location.href=r.url;else toast("Square didn't return a sign-in link.");
    },fail);
  });
}

function freshOrders(){return {q:"",list:[],loaded:false,seq:0,detail:null,detailId:null};}
var orders=freshOrders(), ordTimer=null;

function loadOrders(){
  var seq=++orders.seq,q=orders.q;
  if(!orders.list.length)$("ordList").innerHTML='<div class="group ag">'+spinner("Searching")+"</div>";
  get("/v1/admin/orders?q="+encodeURIComponent(q)).then(function(r){
    if(seq!==orders.seq)return;
    orders.loaded=true;orders.list=r.orders;renderOrders();
  },function(e){
    if(seq!==orders.seq||(e&&e.ended))return;
    orders.list=[];$("ordList").innerHTML=errGroup(e.message);
  });
}

function orderKiosk(o){return o.device?deviceLabel(o.device):"";}
function orderRef(o){return o.order_ref||(o.order_number!=null?"#"+o.order_number:"");}

function renderOrders(){
  var list=orders.list;
  $("ordHead").textContent=orders.q?"Results":"Newest orders";
  $("ordCount").textContent=list.length?plural(list.length,"order"):"";
  $("ordQClear").hidden=!$("ordQ").value;
  if(!list.length){$("ordList").innerHTML=emptyGroup(orders.q?"No order matches that search.":"No orders yet.");return;}
  $("ordList").innerHTML='<div class="group list ag">'+list.map(function(o){
    var fine=[orderRef(o),orderKiosk(o),when(o.paid_at)].filter(Boolean).join(" · ");
    return '<button class="orow'+(o.simulated?" sim":"")+'" type="button" data-order="'+esc(o.id)+'"><div class="grow"><div class="nm">'+esc(o.customer_name||"Guest")+'</div><div class="s">'+esc(fine)+'</div></div><div class="r"><span class="tot">'+money(o.total_cents)+'</span><span class="st s-'+esc(o.status)+'">'+(o.simulated?'<span class="test">Test</span> ':"")+esc(STATUS_LABEL[o.status]||o.status)+"</span></div>"+ico("chevron","chev")+"</button>";
  }).join("")+"</div>";
}

function openOrder(id){
  orders.detailId=id;orders.detail=null;
  var o=orders.list.filter(function(x){return x.id===id;})[0];
  $("osName").textContent=o?(o.customer_name||"Guest"):"Order";
  $("osSub").textContent=o?[orderRef(o),money(o.total_cents)].filter(Boolean).join(" · "):"";
  $("osBody").innerHTML='<div class="group ag mt20">'+spinner()+"</div>";
  showDialog($("orderSheet"));
  loadOrder(id);
}
function loadOrder(id){
  get("/v1/admin/orders/"+encodeURIComponent(id)).then(function(d){
    if(orders.detailId!==id)return;
    orders.detail=d;renderOrder();
  },function(e){
    if(e&&e.ended||orders.detailId!==id)return;
    $("osBody").innerHTML='<div class="mt20">'+errGroup(e.message)+"</div>";
  });
}

function renderOrder(){
  var d=orders.detail;if(!d)return;
  var o=d.order;
  $("osName").textContent=o.customer_name||"Guest";
  $("osSub").textContent=[orderRef(o),orderKiosk(o),when(o.paid_at)].filter(Boolean).join(" · ")+(o.simulated?" · Test order":"");
  var html=gh("Items")+'<div class="group list ag">';
  (o.items||[]).forEach(function(it,i){
    var fl=(it.flavors||[]).map(flavorName).join(", ")||"No flavor";
    var tp=(it.toppings||[]).map(toppingName).join(", ");
    html+='<div class="ac item"><div class="grow"><div class="k">'+esc(vesselName(it.vessel))+'</div><div class="s">'+esc(fl)+(tp?"<br>With "+esc(tp):"")+"</div></div></div>";
  });
  if(!(o.items||[]).length)html+='<div class="aempty">No items recorded</div>';
  html+="</div>"+gh("Payment")+'<div class="group list ag lines">';
  (o.lines||[]).forEach(function(l){html+=row(l.title,money(l.cents),"",l.detail?esc(l.detail):null);});
  if(o.subtotal_cents!=null)html+=row("Subtotal",money(o.subtotal_cents),"");
  if(o.tax_cents!=null)html+=row("Tax",money(o.tax_cents),"");
  html+='<div class="ac total"><span class="k">Total</span><span class="v">'+money(o.total_cents)+"</span></div>";
  var gift=o.gift_card_cents||0;
  if(gift)html+=row("Gift card"+(o.gift_card_last4?" ending "+o.gift_card_last4:""),money(gift),"");
  if(o.total_cents-gift>0||o.card)html+=row(o.card||"Card",money(o.total_cents-gift),"");
  html+=row("Paid",esc(fullWhen(o.paid_at)),"");
  html+="</div>";
  html+=gh("Status",o.status_by?"Set by "+esc(o.status_by)+(o.status_at?", "+esc(when(o.status_at)):""):"")+'<div class="group list ag">';
  STATUSES.forEach(function(s){
    var on=o.status===s;
    html+='<button class="choice'+(on?" on":"")+'" type="button" data-status="'+s+'" role="radio" aria-checked="'+on+'"'+dis(on)+'><span>'+STATUS_LABEL[s]+"</span>"+(on?ico("check","ck"):"")+"</button>";
  });
  html+="</div>";
  html+=gh("Details")+'<div class="group list ag">';
  html+=row("Kiosk",esc(o.device?deviceLabel(o.device):"Unknown"),"");
  html+=row("App version",esc(o.app_version||"Unknown"),"");
  if(o.order_number!=null)html+=row("Order number","#"+esc(o.order_number),"");
  if(o.order_ref)html+=row("Reference",esc(o.order_ref),"");
  html+=row("Square order",o.square_order_id?'<span class="mono">'+esc(o.square_order_id)+"</span>":"None","");
  html+=row("Square payment",o.square_payment_id?'<span class="mono">'+esc(o.square_payment_id)+"</span>":"None","");
  if(o.gift_card_payment_id)html+=row("Gift card payment",'<span class="mono">'+esc(o.gift_card_payment_id)+"</span>","");
  html+=row("Order ID",'<span class="mono">'+esc(o.id)+"</span>","");
  html+="</div>";
  html+='<div class="group list ag mt16">';
  if(o.receiptUrl)html+='<a class="btnrow" href="'+esc(o.receiptUrl)+'" target="_blank" rel="noopener"><div class="grow"><div class="k">Open receipt</div></div>'+ico("external","lead")+"</a>";
  html+='<a class="btnrow" href="'+esc(o.squareUrl)+'" target="_blank" rel="noopener"><div class="grow"><div class="k">Open in Square Dashboard</div><div class="s">Refunds happen in Square.</div></div>'+ico("external","lead")+"</a></div>";
  $("osBody").innerHTML=html;
}

function askStatus(s){
  var d=orders.detail;if(!d)return;
  var o=d.order,name=o.customer_name||"Guest",label=STATUS_LABEL[s];
  var text=s==="canceled"?"It leaves the queue and stops counting in totals. Any refund is done separately in Square.":"Staff pages and the pickup board show it as "+label+" right away.";
  ask("Mark "+name+"'s order "+label+"?",text,s==="canceled"?"Cancel order":"Mark "+label,s==="canceled",function(){
    post("/v1/admin/orders/"+encodeURIComponent(o.id)+"/status",{status:s}).then(function(){
      toast(name+": "+label);
      loadOrder(o.id);loadOrders();
    },fail);
  },s==="canceled"?"Keep order":"Cancel");
}

var testing=false;
function runTest(){
  if(testing)return;
  testing=true;
  var b=$("runTest");b.disabled=true;b.innerHTML=ico("loader","spin")+"Running";
  var done=function(){testing=false;b.disabled=false;b.innerHTML=ico("play")+"Run again";};
  post("/v1/admin/selftest",{}).then(function(r){
    done();
    var failed=r.checks.filter(function(c){return !c.ok;}).length;
    var summary=failed?'<span class="bad">'+plural(failed,"check")+" failed</span>":'<span class="good">All '+r.checks.length+" checks passed</span>";
    $("sv-selftest").textContent=failed?failed+" failed":"Passed";
    $("testBody").innerHTML=gh("Results, "+clockSec(r.at),summary)+'<div class="group list ag">'+r.checks.map(function(c){
      return '<div class="ac"><span class="glyph '+(c.ok?"good":"bad")+'">'+ico(c.ok?"circleCheck":"circleX")+'</span><div class="grow"><div class="k">'+esc(c.name)+'</div><div class="s'+(c.ok?"":" bad")+'">'+esc(c.detail)+'</div></div><span class="ms">'+c.ms+" ms</span></div>";
    }).join("")+"</div>";
  },function(e){done();if(e&&e.ended)return;$("testBody").innerHTML='<div class="mt24">'+errGroup(e.message)+"</div>";});
}

var cleanup=null, cleanResult={};
function loadCleanup(){
  if(!cleanup)$("cleanBody").innerHTML='<div class="group ag mt28">'+spinner()+"</div>";
  get("/v1/admin/cleanup").then(function(c){cleanup=c;renderCleanup();},function(e){if(e&&e.ended)return;$("cleanBody").innerHTML='<div class="mt28">'+errGroup(e.message)+"</div>";});
}
function renderCleanup(){
  var c=cleanup;if(!c)return;
  $("sv-cleanup").textContent=c.openAlerts?plural(c.openAlerts,"alert"):"";
  var t=cleanResult.test,a=cleanResult.ack;
  var html=gh("Test data")+'<div class="group list ag">';
  html+=row("Test orders",String(c.testOrders),"",'Simulated, smoke-test and chaos-test orders');
  html+=row("Test checkouts",String(c.testCheckouts),"");
  html+='<button class="btnrow danger" type="button" id="delTest"'+dis(!c.testOrders&&!c.testCheckouts)+'><div class="grow"><div class="k">Delete test orders</div></div>'+(t?'<span class="res">'+esc(t)+"</span>":"")+"</button></div>";
  html+='<p class="footnote">Real orders are never touched. Test orders also leave the staff pages and the stats.</p>';
  html+=gh("Alerts")+'<div class="group list ag">';
  html+=row("Open alerts",String(c.openAlerts),c.openAlerts?"warn":"");
  html+='<button class="btnrow" type="button" id="ackAll"'+dis(!c.openAlerts)+'><div class="grow"><div class="k">Acknowledge all alerts</div></div>'+(a?'<span class="res">'+esc(a)+"</span>":"")+"</button></div>";
  html+='<p class="footnote">Clears every open alert on the staff pages. A kiosk that still has the problem raises it again.</p>';
  $("cleanBody").innerHTML=html;
}
function askDeleteTest(){
  var c=cleanup;if(!c)return;
  ask("Delete "+plural(c.testOrders,"test order")+"?","Simulated, smoke-test and chaos-test orders and their checkouts are erased for good. Real orders stay.","Delete",true,function(){
    post("/v1/admin/cleanup/test-orders").then(function(r){
      cleanResult.test="Removed "+plural(r.orders,"order")+", "+plural(r.checkouts,"checkout");
      loadCleanup();
    },fail);
  });
}
function ackAll(){
  var c=cleanup;if(!c)return;
  ask("Acknowledge "+plural(c.openAlerts,"alert")+"?","They close on every staff page and the chime stops.","Acknowledge",false,function(){
    post("/v1/admin/alerts/ack-all").then(function(r){
      cleanResult.ack="Acknowledged "+r.acknowledged;
      loadCleanup();
    },fail);
  });
}

var resetPreview=null;
function eraseRows(e){
  return [
    ["Orders",e.orders,e.testOrders?"Including "+e.testOrders+" test":""],
    ["Checkouts and receipt links",e.checkouts,""],
    ["Log lines",e.logs,""],
    ["Alerts",e.alerts,""],
    ["Kiosks and their names",e.kiosks,""],
    ["Sold-out and open/closed flags",e.soldOut,"Every item comes back available, every kiosk open"],
    ["Hub's memory of processed IDs",e.processedIds,""],
    ["Assist sessions",e.assistSessions,""],
    ["Completed and canceled gift card records",e.giftCardRecords,""]
  ];
}
function keepRows(k){
  return [["Square connection and tokens","Kept",""],["Open gift card holds",String(k.giftCardHolds),"Still settled or released by the kiosk"],["Admin audit trail","Kept",""]];
}
function loadReset(){
  if(!resetPreview)$("resetBody").innerHTML='<div class="group ag mt28">'+spinner()+"</div>";
  get("/v1/admin/reset").then(function(r){resetPreview=r;renderReset();},function(e){if(e&&e.ended)return;$("resetBody").innerHTML='<div class="mt28">'+errGroup(e.message)+"</div>";});
}
function renderReset(){
  var r=resetPreview;if(!r)return;
  var html='<div class="group ag mt24"><div class="ac intro"><span class="rtile">'+ico("rotate")+'</span><div class="grow"><div class="k">Start the booth fresh</div><div class="s">Erases this event\'s orders, logs, alerts and kiosk list so the booth starts empty, as if new. Use it between events, never while customers are ordering. The Square connection stays.</div></div></div></div>';
  html+=gh("Erased")+'<div class="group list ag">'+eraseRows(r.erase).map(function(x){return row(x[0],String(x[1]),"",x[2]?esc(x[2]):null);}).join("")+"</div>";
  html+=gh("Kept")+'<div class="group list ag">'+keepRows(r.keep).map(function(x){return row(x[0],esc(x[1]),"",x[2]?esc(x[2]):null);}).join("")+"</div>";
  html+='<p class="footnote">Connected kiosks reset their order numbers, cached flags and anything queued before the reset right away; offline kiosks do it when they reconnect. Reset epoch now: '+r.epoch+".</p>";
  html+='<div class="group ag mt24"><button class="big danger" type="button" id="resetGo">'+ico("rotate")+"Reset everything</button></div>";
  $("resetBody").innerHTML=html;
}
function dlist(rows){return '<div class="dl list">'+rows.map(function(x){return row(x[0],esc(x[1]),"",x[2]?esc(x[2]):null);}).join("")+"</div>";}

function resetStep1(){
  var r=resetPreview;if(!r)return;
  $("r1Body").innerHTML='<p>Only do this when no customer is paying on any kiosk.</p><div class="dh">Erased</div>'+dlist(eraseRows(r.erase))+'<div class="dh">Kept</div>'+dlist(keepRows(r.keep))+'<p class="fine">Connected kiosks reset their order numbers, cached flags and pre-reset outbox right away. Offline kiosks do it when they reconnect.</p>';
  showDialog($("reset1"));
  get("/v1/admin/reset").then(function(x){resetPreview=x;if($("reset1").open)$("r1Body").querySelectorAll(".dl")[0].outerHTML=dlist(eraseRows(x.erase));renderReset();},function(){});
}
function resetStep2(){
  hideDialog($("reset1"));
  $("r2Input").value="";$("r2Err").hidden=true;
  $("r2Backup").setAttribute("aria-checked","true");
  r2Busy(false);
  showDialog($("reset2"));
  setTimeout(function(){try{$("r2Input").focus();}catch(e){}},60);
}
var resetting=false;
function r2Busy(text){
  resetting=!!text;
  $("r2Go").textContent=text||"Reset everything";
  $("r2Go").disabled=!!text||$("r2Input").value!=="RESET";
  $("r2Cancel").disabled=!!text;$("r2Input").disabled=!!text;$("r2Backup").disabled=!!text;
}
function r2Error(text){var e=$("r2Err");e.innerHTML=ico("alert")+"<span>"+esc(text)+"</span>";e.hidden=false;r2Busy(false);}

function downloadBackup(){
  return api("GET","/v1/admin/backup").then(function(x){
    var cd=x.response.headers.get("Content-Disposition")||"",m=/filename="([^"]+)"/.exec(cd);
    var name=m?m[1]:"booth-backup-"+new Date().toISOString().replace(/[:.]/g,"-")+".json";
    var blob=new Blob([JSON.stringify(x.body,null,2)],{type:"application/json"});
    var url=URL.createObjectURL(blob),a=document.createElement("a");
    a.href=url;a.download=name;a.rel="noopener";a.style.display="none";
    document.body.appendChild(a);a.click();
    setTimeout(function(){URL.revokeObjectURL(url);a.remove();},60000);
    if(IN_APP&&window.File&&navigator.share&&navigator.canShare){
      var file=new File([blob],name,{type:"application/json"});
      if(navigator.canShare({files:[file]}))return navigator.share({files:[file],title:name}).catch(function(){});
    }
  });
}

function doReset(){
  if(resetting||$("r2Input").value!=="RESET")return;
  $("r2Err").hidden=true;
  var withBackup=$("r2Backup").getAttribute("aria-checked")==="true";
  var step=withBackup?(r2Busy("Saving backup"),downloadBackup().catch(function(e){if(e&&e.ended)throw e;var x=new Error("The backup couldn't be saved, so nothing was reset. "+e.message);x.backup=true;throw x;})):Promise.resolve();
  step.then(function(){
    r2Busy("Resetting");
    return post("/v1/admin/reset",{confirm:"RESET"});
  }).then(function(r){
    r2Busy(false);hideDialog($("reset2"));
    resetDone(r,withBackup);
    resetPreview=null;cleanup=null;state=null;logs=freshLogs();orders=freshOrders();ctl={};
    renderLogFilters();
    loadState();if(current==="reset")loadReset();
  },function(e){if(e&&e.ended)return;r2Error(e.message);});
}

function resetDone(r,withBackup){
  var e=r.erased||{},d=e.d1||{};
  $("r3Body").innerHTML='<p>The booth is now on reset epoch '+esc(r.epoch)+(r.resetAt?" ("+esc(clockSec(r.resetAt))+")":"")+". Connected kiosks are resetting now."+(withBackup?" The backup was saved first.":"")+'</p><div class="dh">Erased</div>'+dlist([
    ["Orders",d.orders||0],["Checkouts and receipt links",d.checkouts||0],["Log lines",d.logs||0],["Gift card records",d.giftCardRecords||0],
    ["Alerts",e.alerts||0],["Kiosks",e.kiosks||0],["Orders on staff pages",e.orders||0],["Sold-out flags",e.soldOut||0],["Processed IDs",e.processed||0],["Assist sessions",e.sessions||0]
  ]);
  showDialog($("reset3"));
}

function refreshTimes(){
  document.querySelectorAll("[data-ago]").forEach(function(el){var v=el.getAttribute("data-ago");el.textContent=ago(v===""?null:Number(v));});
  document.querySelectorAll("[data-rel]").forEach(function(el){el.textContent=fromNow(Number(el.getAttribute("data-rel")));});
}

setInterval(function(){
  if(ended)return;
  refreshTimes();
  if(current==="kiosks"&&document.visibilityState!=="hidden"){
    var before=JSON.stringify(ctl);
    checkControls();
    if(JSON.stringify(ctl)!==before)renderKiosks();
    if(Date.now()-lastPoll>=(controlsPending()?1500:3000))loadState();
  }
},1000);

document.addEventListener("click",function(e){
  var el=e.target.closest&&e.target.closest("button,[data-ctx]");
  if(!el||el.disabled)return;
  var d=el.dataset;
  if(el.id==="confirmYes"){var go=pendingConfirm;pendingConfirm=null;hideDialog($("confirm"));if(go)go();return;}
  if(el.id==="confirmNo"){pendingConfirm=null;hideDialog($("confirm"));return;}
  if(d.exit!=null){askExit();return;}
  if(ended)return;
  if(d.sec){show(d.sec);return;}
  if(d.back!=null){back();return;}
  if(d.close){hideDialog($(d.close));return;}
  if(d.ctl){askControl(d.k,d.ctl);return;}
  if(d.debug){toggleDebug(d.debug);return;}
  if(d.forget){askForget(d.forget);return;}
  if(d.level){if(logs.level!==d.level){logs.level=d.level;renderLogFilters();loadLogs(true);}return;}
  if(d.win){if(logs.win!==d.win){logs.win=d.win;renderLogFilters();loadLogs(true);}return;}
  if(d.ctx){toggleLog(d.ctx);return;}
  if(el.id==="logMore"){loadLogs(false);return;}
  if(el.id==="logRefresh"){loadState();loadLogs(true);return;}
  if(el.id==="logQClear"){$("logQ").value="";logs.q="";renderLogFilters();loadLogs(true);return;}
  if(el.id==="sqCheck"){loadSquare();return;}
  if(el.id==="sqRefresh"){refreshToken();return;}
  if(el.id==="sqConnect"){askConnect();return;}
  if(d.order){openOrder(d.order);return;}
  if(el.id==="osDone"){hideDialog($("orderSheet"));return;}
  if(d.status){askStatus(d.status);return;}
  if(el.id==="ordQClear"){$("ordQ").value="";orders.q="";loadOrders();renderOrders();return;}
  if(el.id==="runTest"){runTest();return;}
  if(el.id==="delTest"){askDeleteTest();return;}
  if(el.id==="ackAll"){ackAll();return;}
  if(el.id==="resetGo"){resetStep1();return;}
  if(el.id==="r1Go"){resetStep2();return;}
  if(el.id==="r2Cancel"){hideDialog($("reset2"));return;}
  if(el.id==="r2Backup"){el.setAttribute("aria-checked",el.getAttribute("aria-checked")==="true"?"false":"true");return;}
  if(el.id==="r2Go"){doReset();return;}
});
document.addEventListener("keydown",function(e){
  if((e.key==="Enter"||e.key===" ")&&e.target&&e.target.dataset&&e.target.dataset.ctx){e.preventDefault();toggleLog(e.target.dataset.ctx);}
});

$("logDev").addEventListener("change",function(){logs.device=this.value;renderLogFilters();loadLogs(true);});
$("logQ").addEventListener("input",function(){
  $("logQClear").hidden=!this.value;
  clearTimeout(logTimer);
  var v=this.value.trim();
  logTimer=setTimeout(function(){if(v!==logs.q){logs.q=v;loadLogs(true);}},350);
});
$("ordQ").addEventListener("input",function(){
  $("ordQClear").hidden=!this.value;
  clearTimeout(ordTimer);
  var v=this.value.trim();
  ordTimer=setTimeout(function(){if(v!==orders.q){orders.q=v;loadOrders();}},350);
});
["logQ","ordQ"].forEach(function(id){
  $(id).addEventListener("keydown",function(e){if(e.key==="Enter"){e.preventDefault();this.blur();this.dispatchEvent(new Event("input"));}});
});
$("r2Input").addEventListener("input",function(){if(!resetting)$("r2Go").disabled=this.value!=="RESET";});
$("r2Input").addEventListener("keydown",function(e){if(e.key==="Enter"){e.preventDefault();doReset();}});
$("confirm").addEventListener("close",function(){pendingConfirm=null;});
$("reset2").addEventListener("cancel",function(e){if(resetting)e.preventDefault();});
$("orderSheet").addEventListener("close",function(){orders.detailId=null;orders.detail=null;});

renderLogFilters();
if(narrow())back();else show("kiosks");
loadState();
})();
`;

export function adminScript(): string {
  return SCRIPT.replace("__ICONS__", () => JSON.stringify(ICONS)).replace("__TOPPINGS__", () => JSON.stringify(TOPPING_TITLES));
}

export function adminStyle(): string {
  return STYLE;
}
