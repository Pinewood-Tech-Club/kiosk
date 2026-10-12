import { escapeHtml } from "./http";
import { TOPPING_TITLES } from "./pricing";
import { NOTO_SERIF_SEMIBOLD_WOFF2 } from "./staff-font";
import type { SupplyKind } from "./schema";
import { STAFF_ROLES, type StaffRole, type StaffSection } from "./staff-roles";

const STYLE = `
@font-face{font-family:"Kiosk Serif";src:url(data:font/woff2;base64,${NOTO_SERIF_SEMIBOLD_WOFF2}) format("woff2");font-weight:600;font-display:block}
:root{color-scheme:only light;
--bg:#F2F2F7;--cell:#FFFFFF;--label:#000000;--label-2:rgba(60,60,67,.62);--label-3:rgba(60,60,67,.36);--sep:rgba(60,60,67,.16);--fill:rgba(120,120,128,.14);
--tint:#E8705E;--tint-soft:#F09080;--tint-wash:#FDEDEA;--tint-ink:#C4513F;--red:#FF3B30;--red-ink:#D70015;--orange:#FF9500;--orange-ink:#B25E00;--green:#34C759;
--sans:-apple-system,BlinkMacSystemFont,"SF Pro Display","SF Pro Text","Helvetica Neue",system-ui,sans-serif;
--serif:"Kiosk Serif","Noto Serif",Georgia,serif}
*{box-sizing:border-box;margin:0;padding:0}
html{background:var(--bg);-webkit-text-size-adjust:100%;touch-action:manipulation}
body{background:var(--bg);color:var(--label);font-family:var(--sans);-webkit-font-smoothing:antialiased;letter-spacing:-.01em;line-height:1.3;min-height:100vh;overscroll-behavior:none;-webkit-tap-highlight-color:transparent;
padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
button{font:inherit;color:inherit;letter-spacing:inherit;border:0;background:none;cursor:pointer;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}
button:disabled{cursor:default}
a{color:inherit;text-decoration:none}
button:focus-visible,a:focus-visible,summary:focus-visible,input:focus-visible{outline:3px solid var(--tint);outline-offset:3px}
[hidden]{display:none!important}
svg.i{width:1em;height:1em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
.vh{position:absolute;width:1px;height:1px;overflow:hidden;clip-path:inset(50%);white-space:nowrap}
.page{max-width:1032px;margin:0 auto;padding:0 40px 72px}
.page.wide{max-width:1720px;padding:0 48px 56px}
.nav .bar{height:50px;display:flex;align-items:center;justify-content:flex-end;gap:22px}
.wide .nav .bar{height:28px}
.navbtn{display:inline-flex;align-items:center;gap:7px;height:44px;font-size:17px;font-weight:500;color:var(--tint-ink)}
.navbtn svg{font-size:20px}
.navbtn.attn{height:38px;padding:0 16px;border-radius:19px;background:var(--tint);color:#fff;font-weight:600}
.navbtn.dim{color:var(--label-2)}
.nav form{display:contents}
.nav .title{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;padding-top:4px}
.nav h1{font-size:56px;font-weight:700;letter-spacing:-.025em;line-height:1}
.live{display:flex;align-items:center;gap:8px;font-size:17px;font-weight:500;color:var(--label-2);padding-bottom:8px;white-space:nowrap}
.live .dot{width:9px;height:9px;border-radius:50%;background:var(--green);flex:none}
.live.connecting .dot{background:var(--label-3)}
.live.off{color:var(--red-ink);font-weight:600}
.live.off .dot{background:var(--red)}
.float{position:sticky;top:env(safe-area-inset-top);z-index:10;display:flex;flex-direction:column}
#urgent{display:flex;flex-direction:column}
.banner{margin-top:24px;display:flex;align-items:center;gap:16px;padding:14px 24px 14px 14px;border-radius:28px;background:rgba(255,255,255,.8);
-webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);box-shadow:0 14px 36px -16px rgba(0,0,0,.3)}
.banner .glyph{width:46px;height:46px;border-radius:50%;display:grid;place-items:center;font-size:22px;color:#fff;background:var(--red);flex:none}
.banner.warn .glyph{background:var(--orange)}
.banner b{display:block;font-size:19px;font-weight:650;letter-spacing:-.015em}
.banner .sub{display:block;font-size:16px;color:var(--label-2);margin-top:2px}
.alert{margin-top:24px;padding:22px 22px 22px 28px;border-radius:30px;background:rgba(255,59,48,.94);-webkit-backdrop-filter:blur(24px) saturate(180%);backdrop-filter:blur(24px) saturate(180%);
color:#fff;display:flex;align-items:center;gap:20px;box-shadow:0 10px 30px -8px rgba(255,59,48,.55);animation:glow 2.4s ease-in-out infinite}
.alert+.alert{margin-top:12px}
@keyframes glow{0%,100%{box-shadow:0 10px 30px -8px rgba(255,59,48,.55)}50%{box-shadow:0 10px 44px -2px rgba(255,59,48,.75)}}
.alert .glyph{width:60px;height:60px;border-radius:50%;background:rgba(255,255,255,.2);display:grid;place-items:center;font-size:30px;flex:none}
.alert .text{flex:1;min-width:0}
.alert .title{font-size:30px;font-weight:700;letter-spacing:-.02em;line-height:1.1}
.alert .meta{font-size:18px;font-weight:500;opacity:.85;margin-top:4px}
.alert button{background:#fff;color:var(--red);font-size:20px;font-weight:650;height:60px;padding:0 30px;border-radius:30px;flex:none}
.times{font-weight:600;opacity:.8}
.section-head{margin:34px 0 14px;display:flex;align-items:baseline;justify-content:space-between;gap:16px}
.section-head h2{font-size:28px;font-weight:700;letter-spacing:-.02em}
.section-head>span{font-size:18px;color:var(--label-2);font-weight:500}
.section-head .link{font-size:18px;min-height:0}
.group{background:var(--cell);border-radius:28px;overflow:hidden}
.list>*{position:relative}
.list>*+*::before{content:"";position:absolute;top:0;left:24px;right:0;height:1px;background:var(--sep)}
.list>.row+.row::before{left:36px}
.empty{padding:26px 32px;font-size:19px;color:var(--label-2);display:flex;align-items:center;gap:10px}
.who{display:flex;flex-wrap:wrap;align-items:baseline;column-gap:12px;min-width:0}
.who .num{font-size:15px;font-weight:500;color:var(--label-3);font-variant-numeric:tabular-nums;white-space:nowrap}
.who .name{font-family:var(--serif);font-weight:600;letter-spacing:-.01em;line-height:1.05;min-width:0}
.base{display:flex;align-items:center;gap:10px;color:var(--label-2);font-weight:500}
.tops,.scoops{list-style:none}
.tops li{display:flex;align-items:center;font-weight:650;letter-spacing:-.02em}
.tops .plus{border-radius:50%;background:var(--tint-wash);color:var(--tint);display:grid;place-items:center;flex:none}
.tops .plus svg{stroke-width:3}
.none{color:var(--label-3);font-weight:500}
.scoops li{display:flex;align-items:baseline;gap:12px;font-weight:650;letter-spacing:-.02em;line-height:1.1}
.scoops .times{color:var(--tint-ink);font-size:.62em;font-weight:700;opacity:1}
.then{display:flex;align-items:center;gap:8px;color:var(--label-2);font-weight:500}
.then svg{color:var(--tint);stroke-width:3}
.tag{display:flex;align-items:center;gap:8px;font-weight:650;white-space:nowrap}
.tag.tint{color:var(--tint)}
.tag.dim{color:var(--label-3)}
.age{color:var(--label-3);font-weight:500;font-variant-numeric:tabular-nums;white-space:nowrap}
.pending{display:inline-flex;align-items:center;gap:6px;font-size:15px;font-weight:600;color:var(--label-2);white-space:nowrap}
.spin{animation:spin 1s linear infinite}
@keyframes spin{to{transform:rotate(360deg)}}
.hero{padding:32px 36px 30px}
.hero+.hero{margin-top:16px}
.hero .top{display:flex;align-items:flex-start;justify-content:space-between;gap:24px}
.hero .name{font-size:64px}
.hero .num{font-size:17px}
.hero .state{display:flex;flex-direction:column;align-items:flex-end;gap:6px;padding-top:14px}
.hero .tag{font-size:20px}
.hero .tag svg{font-size:24px;stroke-width:2.5}
.hero .age{font-size:17px}
.hero .foot{display:flex;align-items:flex-end;justify-content:space-between;gap:24px;margin-top:18px}
.hero .items{min-width:0}
.hero .item+.item{margin-top:30px}
.hero .base{font-size:21px}
.hero .base svg{font-size:22px}
.hero .tops{margin-top:22px;display:grid;gap:14px}
.hero .tops li{font-size:44px;gap:18px;line-height:1.1}
.hero .tops .plus{width:46px;height:46px;font-size:24px}
.hero .none{font-size:30px;margin-top:16px}
.hero .scoops{margin-top:12px;display:grid;gap:6px}
.hero .scoops li{font-size:48px}
.hero .then{font-size:21px;margin-top:14px}
.hero .acts{display:flex;flex-direction:column;align-items:center;gap:2px;margin-bottom:-10px;flex:none}
.plain{font-size:19px;font-weight:500;color:var(--label-2);padding:14px 4px}
.primary{display:inline-flex;align-items:center;gap:12px;height:76px;padding:0 44px 0 36px;border-radius:38px;background:var(--tint);color:#fff;font-size:26px;font-weight:700;letter-spacing:-.01em;box-shadow:0 8px 20px -10px rgba(232,112,94,.9);white-space:nowrap}
.primary svg{font-size:28px;stroke-width:2.75}
.tinted{display:inline-flex;align-items:center;gap:8px;height:56px;padding:0 28px 0 22px;border-radius:28px;background:var(--tint-wash);color:var(--tint-ink);font-size:21px;font-weight:700;white-space:nowrap}
.tinted svg{font-size:20px;stroke-width:2.5}
.link{display:inline-flex;align-items:center;gap:6px;min-height:44px;color:var(--tint-ink);font-size:19px;font-weight:600;white-space:nowrap}
.primary:active,.tinted:active,.alert button:active,.dialog-actions button:active{transform:scale(.97)}
.plain:active,.link:active,.navbtn:active,.destructive:active{opacity:.5}
.row{display:grid;grid-template-columns:236px minmax(0,1fr) auto;column-gap:24px;padding:24px 32px 24px 36px;align-items:start}
.row .name{font-size:38px}
.row .side{display:flex;flex-direction:column;align-items:flex-end;gap:8px;padding-top:6px}
.row .tag{font-size:18px;font-weight:600;color:var(--label-2)}
.row .tag svg{font-size:20px}
.row .tag.dim{color:var(--label-3)}
.row .age{font-size:16px}
.row .plain{padding:4px 0;font-size:17px;color:var(--label-3)}
.row .tinted{margin-top:6px}
.row .item+.item{margin-top:18px}
.row .base{font-size:18px}
.row .base svg{font-size:19px}
.row .tops{margin-top:8px;display:grid;gap:6px}
.row .tops li{font-size:28px;gap:12px}
.row .tops .plus{width:30px;height:30px;font-size:16px}
.row .none{font-size:22px;margin-top:8px}
.row .scoops{margin-top:6px;display:grid;gap:4px}
.row .scoops li{font-size:32px}
.row .then{font-size:17px;margin-top:8px}
details.finished summary{list-style:none;cursor:pointer}
details.finished summary::-webkit-details-marker{display:none}
details.finished summary h2{display:flex;align-items:center;gap:10px}
details.finished summary h2 svg{font-size:22px;color:var(--label-3);transition:transform .2s}
details.finished[open] summary h2 svg{transform:rotate(90deg)}
.drow{display:flex;align-items:center;gap:18px;min-height:76px;padding:12px 24px 12px 36px}
.drow .name{font-size:28px}
.drow .when{flex:1;font-size:17px;color:var(--label-2);text-align:right}
.drow .when.s-canceled{color:var(--red-ink)}
.split{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:24px;align-items:start}
.cell{min-height:74px;padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px}
.cell .grow{flex:1;min-width:0}
.cell .label{font-size:21px;font-weight:500}
.cell .sub{font-size:16px;color:var(--label-2);margin-top:3px;font-weight:450}
.cell .sub.bad{color:var(--red-ink);font-weight:550}
.cell .sub.warn{color:var(--orange-ink);font-weight:550}
.cell .value{font-size:19px;color:var(--label-2);text-align:right;overflow-wrap:anywhere}
.value.bad{color:var(--red-ink);font-weight:550}
.value.warn{color:var(--orange-ink);font-weight:550}
.status{display:flex;align-items:center;gap:10px}
.status::before{content:"";width:10px;height:10px;border-radius:50%;background:var(--green);flex:none}
.status.off{color:var(--red-ink)}
.status.off::before{background:var(--red)}
.destructive{color:var(--red);font-size:21px;font-weight:500;width:100%;text-align:left;min-height:44px}
.action{color:var(--tint-ink);font-size:21px;font-weight:600;width:100%;text-align:left;min-height:44px}
.soldout{color:var(--red);font-size:16px;font-weight:600;margin-top:3px}
.compact .cell{min-height:54px;padding:10px 24px}
.compact .label{font-size:18px}
.compact .value{font-size:17px}
.compact .none{font-size:18px;font-weight:450;color:var(--label-2)}
.cell .pending{margin-top:4px}
.footnote{font-size:15px;color:var(--label-2);margin:10px 24px 0;line-height:1.35}
.health{margin-top:20px}
.health .cell{min-height:58px;padding:12px 24px}
.health .label{font-size:19px}
.switch{width:64px;height:28px;border-radius:14px;background:rgba(120,120,128,.18);position:relative;flex:none;transition:background-color .2s}
.switch::after{content:"";position:absolute;top:2px;left:2px;width:38px;height:24px;border-radius:12px;background:#fff;box-shadow:0 2px 6px rgba(0,0,0,.14),0 0 0 .5px rgba(0,0,0,.04);transition:left .2s}
.switch[aria-checked="true"]{background:var(--green)}
.switch[aria-checked="true"]::after{left:24px}
.switch::before{content:"";position:absolute;inset:-14px -10px}
.acell{min-height:80px}
.aglyph{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;font-size:20px;color:#fff;background:var(--orange);flex:none}
.sev-urgent .aglyph{background:var(--red)}
.sev-info .aglyph{background:var(--tint-wash);color:var(--tint)}
.acell .label{font-size:20px;font-weight:600}
.acell .link{font-size:18px}
.more{min-height:56px;font-size:17px;color:var(--label-2)}
.cols{display:grid;gap:32px;align-items:start}
.cols-3{grid-template-columns:minmax(0,1.2fr) minmax(0,1.3fr) minmax(0,1fr)}
.tiles{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:1px;background:var(--sep)}
.tile.wide{grid-column:1/-1}
.tile.wide .v{font-size:64px}
.tile{background:var(--cell);padding:20px 24px 22px;min-width:0}
.tile .k{font-size:17px;color:var(--label-2);font-weight:500;white-space:nowrap}
.tile .v{font-size:44px;white-space:nowrap;font-weight:700;letter-spacing:-.03em;line-height:1.05;margin-top:6px;font-variant-numeric:tabular-nums}
.tile .s{font-size:15px;color:var(--label-2);margin-top:4px}
.bar{display:grid;grid-template-columns:minmax(0,9rem) minmax(0,1fr) 3rem;gap:14px;align-items:center;min-height:52px;padding:10px 24px;font-size:18px}
.bar .name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar .track{height:10px;border-radius:5px;background:var(--fill);overflow:hidden}
.bar .fill{display:block;height:100%;border-radius:5px;background:var(--tint-soft);min-width:4px}
.bar .n{text-align:right;font-weight:600;font-variant-numeric:tabular-nums}
.frow{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 20px;padding:16px 24px;align-items:center}
.frow .name{font-size:30px}
.frow .fitems{grid-column:1;font-size:17px;color:var(--label-2)}
.frow .fside{grid-column:2;grid-row:1/span 2;display:grid;gap:3px;justify-items:end}
.fstatus{font-size:18px;font-weight:650;color:var(--label-2)}
.fstatus.s-ready{color:var(--tint-ink)}.fstatus.s-preparing{color:var(--label)}.fstatus.s-collected{color:var(--label-3)}.fstatus.s-canceled{color:var(--red-ink)}
.frow .total{font-size:17px;color:var(--label-2);font-variant-numeric:tabular-nums}
.frow.sim{opacity:.45}
.board{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:32px;align-items:start}
.brow{display:flex;align-items:baseline;gap:16px;padding:22px 36px}
#boardReady .name{font-size:84px}
#boardReady.many{display:grid;grid-template-columns:1fr 1fr}
#boardReady.many .name{font-size:60px}
#boardReady.many>*+*::before{display:none}
#boardMaking .name{font-size:48px;color:rgba(0,0,0,.72)}
.board .section-head h2{font-size:34px}
.board .section-head>span{font-size:20px}
.board .empty{font-size:24px;padding:30px 36px}
.roles .role{display:flex;align-items:center;gap:18px;min-height:96px;padding:18px 24px 18px 20px}
.list>.role+.role::before{left:90px}
.role .ric{width:52px;height:52px;border-radius:14px;background:var(--tint);color:#fff;display:grid;place-items:center;font-size:28px;flex:none}
.role .rt{flex:1;display:grid;gap:3px;min-width:0}
.role b{font-size:22px;font-weight:600;letter-spacing:-.015em}
.role .rt span{font-size:16px;color:var(--label-2)}
.role .chev{color:var(--label-3);font-size:24px}
.role:active{background:rgba(0,0,0,.04)}
.err{color:var(--red-ink);font-weight:600;font-size:17px;display:flex;gap:8px;align-items:center}
.signin{min-height:calc(100vh - env(safe-area-inset-top) - env(safe-area-inset-bottom));display:grid;place-items:center;padding:40px 20px}
.signin form{width:min(440px,100%);background:var(--cell);border-radius:36px;padding:40px 32px 28px;display:grid;gap:12px;text-align:center;box-shadow:0 30px 80px -40px rgba(0,0,0,.25)}
.appicon{width:76px;height:76px;border-radius:20px;background:var(--tint);color:#fff;display:grid;place-items:center;font-size:40px;margin:0 auto 10px;box-shadow:0 10px 24px -12px rgba(232,112,94,.9)}
.signin h1{font-size:34px;font-weight:700;letter-spacing:-.02em}
.signin p{font-size:18px;color:var(--label-2)}
.signin .err{justify-content:center}
.signin input{font:inherit;font-size:34px;letter-spacing:.35em;text-indent:.35em;text-align:center;height:72px;border-radius:20px;border:0;background:var(--fill);color:var(--label);width:100%;margin-top:12px}
.signin input:focus{outline:none;box-shadow:0 0 0 3px var(--tint-soft)}
.signin .primary{justify-content:center;width:100%;height:64px;font-size:22px;margin-top:6px;padding:0 24px}
.toast{position:fixed;left:50%;bottom:calc(28px + env(safe-area-inset-bottom));transform:translateX(-50%);z-index:30;display:flex;align-items:center;gap:18px;min-height:64px;padding:9px 9px 9px 28px;border-radius:32px;max-width:calc(100vw - 32px);
background:rgba(30,30,32,.84);-webkit-backdrop-filter:blur(30px) saturate(180%);backdrop-filter:blur(30px) saturate(180%);color:#fff;font-size:19px;font-weight:600;box-shadow:0 20px 50px -18px rgba(0,0,0,.5)}
.toast.plain{padding:16px 28px}
.toast .undo{display:inline-flex;align-items:center;gap:8px;height:46px;padding:0 22px;border-radius:23px;background:rgba(255,255,255,.16);color:#fff;font-weight:650;flex:none}
dialog{margin:auto;border:0;width:min(470px,calc(100vw - 32px));padding:30px 26px 22px;border-radius:36px;color:var(--label);background:rgba(255,255,255,.94);
-webkit-backdrop-filter:blur(40px) saturate(180%);backdrop-filter:blur(40px) saturate(180%);box-shadow:0 30px 80px -20px rgba(0,0,0,.35)}
dialog[open]{animation:pop .28s cubic-bezier(.2,.9,.3,1.2)}
@keyframes pop{from{transform:scale(1.08);opacity:0}}
dialog::backdrop{background:rgba(0,0,0,.28);-webkit-backdrop-filter:blur(6px) saturate(120%);backdrop-filter:blur(6px) saturate(120%)}
dialog h3{font-size:26px;font-weight:700;letter-spacing:-.02em;line-height:1.15;padding:0 6px}
dialog p{font-size:18px;color:var(--label-2);line-height:1.4;margin-top:10px;padding:0 6px}
.dialog-actions{display:grid;grid-template-columns:1fr 1fr;gap:12px;margin-top:26px}
.dialog-actions button{height:60px;border-radius:30px;font-size:20px;font-weight:600;padding:0 12px}
.dialog-actions .cancel{background:var(--fill)}
.dialog-actions .confirm{background:var(--tint);color:#fff;font-weight:700}
.dialog-actions .confirm.danger{background:var(--red)}
body.app .web-only{display:none!important}
body:not(.app) .app-only{display:none!important}
.kcell{width:100%;text-align:left;min-height:84px}
button.kcell:active{background:rgba(0,0,0,.04)}
.kcell .chev{color:var(--label-3);font-size:22px}
.kglyph{width:40px;height:40px;border-radius:50%;display:grid;place-items:center;font-size:20px;color:#fff;background:var(--tint);flex:none}
.kglyph.off{background:var(--label-3)}
dialog.sheet{width:min(640px,calc(100vw - 32px));max-height:calc(100vh - 48px);overflow:auto;background:var(--bg);padding:22px 22px 28px;border-radius:32px}
.sheet-head{display:flex;align-items:center;justify-content:space-between;gap:16px}
.sheet-head h3{min-width:0;overflow-wrap:anywhere}
.sheet .section-head{margin:24px 0 10px}
.sheet .section-head h2{font-size:22px}
.sheet .group+.group{margin-top:16px}
.field{font:inherit;font-size:21px;border:0;background:none;color:var(--label);flex:1;min-width:0;height:44px}
.field:focus,.field:focus-visible{outline:none}
dialog.assist{width:100vw;height:100vh;max-width:100vw;max-height:100vh;margin:0;padding:0;border-radius:0;background:var(--bg);box-shadow:none;overflow:auto;overscroll-behavior:contain;-webkit-backdrop-filter:none;backdrop-filter:none}
dialog.assist:focus,dialog.assist:focus-visible{outline:none}
dialog.assist[open]{animation:rise .32s cubic-bezier(.2,.9,.3,1)}
@keyframes rise{from{transform:translateY(36px);opacity:0}}
.assist-page{max-width:1032px;margin:0 auto;padding:env(safe-area-inset-top) max(40px,env(safe-area-inset-right)) calc(72px + env(safe-area-inset-bottom)) max(40px,env(safe-area-inset-left))}
.assist .nav .bar{justify-content:space-between}
.as-eyebrow{font-size:17px;font-weight:600;color:var(--tint-ink);display:inline-flex;align-items:center;gap:8px}
.as-eyebrow svg{font-size:20px}
.navbtn.done{font-weight:700;font-size:19px;padding:0 4px}
.as-cols{display:grid;grid-template-columns:minmax(0,1.4fr) minmax(0,1fr);gap:28px;align-items:start}
.as-total{font-size:22px!important;font-weight:700!important;color:var(--label)!important;font-variant-numeric:tabular-nums}
.as-note{margin-top:24px;display:flex;align-items:center;gap:16px;padding:16px 22px;border-radius:24px;background:var(--cell)}
.as-note .aglyph{width:44px;height:44px;font-size:22px}
.as-note.info .aglyph{background:var(--tint-wash);color:var(--tint)}
.as-note.bad .aglyph{background:var(--red)}
.as-note.wait .aglyph{background:var(--fill);color:var(--label-2)}
.as-note b{display:block;font-size:20px;font-weight:650;letter-spacing:-.015em}
.as-note .sub{display:block;font-size:16px;color:var(--label-2);margin-top:2px}
.as-item+.as-item{margin-top:18px}
.as-item.cur{box-shadow:0 0 0 3px var(--tint-soft)}
.as-ihead{display:flex;align-items:center;gap:14px;padding:18px 14px 8px 24px}
.as-iname{font-size:24px;font-weight:700;letter-spacing:-.02em;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.as-ihead .sub{font-size:16px;color:var(--label-2);margin-top:3px}
.as-on{font-size:14px;font-weight:700;color:var(--tint-ink);background:var(--tint-wash);border-radius:9px;padding:3px 9px;letter-spacing:0}
.as-price{font-size:21px;font-weight:650;font-variant-numeric:tabular-nums}
.as-trash{width:52px;height:52px;border-radius:50%;color:var(--red);display:grid;place-items:center;font-size:23px;flex:none}
.as-trash:active{background:rgba(255,59,48,.1)}
.as-seg{display:grid;grid-template-columns:1fr 1fr;gap:4px;padding:4px;margin:8px 24px 4px;border-radius:18px;background:var(--fill)}
.as-seg button{min-height:56px;border-radius:14px;font-size:19px;font-weight:600;display:flex;align-items:center;justify-content:center;gap:8px;color:var(--label)}
.as-seg button svg{font-size:21px}
.as-seg button.sel{background:#fff;box-shadow:0 3px 8px rgba(0,0,0,.12),0 0 0 .5px rgba(0,0,0,.04)}
.as-seg small,.as-chip small{font-size:14px;font-weight:600;color:var(--red-ink)}
.as-label{display:flex;justify-content:space-between;gap:12px;padding:16px 24px 4px;font-size:15px;font-weight:600;color:var(--label-2)}
.as-flavors .cell{min-height:72px}
.as-flavors .label{font-size:21px;font-weight:550}
.as-step{display:flex;align-items:center;gap:12px;flex:none}
.as-step button{width:56px;height:56px;border-radius:50%;display:grid;place-items:center;font-size:24px;background:var(--fill);color:var(--label)}
.as-step button.plus{background:var(--tint-wash);color:var(--tint-ink)}
.as-step button svg{stroke-width:2.5}
.as-step .n{min-width:30px;text-align:center;font-size:24px;font-weight:650;font-variant-numeric:tabular-nums}
.as-chips{display:flex;flex-wrap:wrap;gap:10px;padding:8px 24px 22px}
.as-chip{min-height:52px;padding:0 20px;border-radius:26px;background:var(--fill);font-size:18px;font-weight:600;display:inline-flex;align-items:center;gap:8px}
.as-chip.on{background:var(--tint-wash);color:var(--tint-ink)}
.as-chip svg{stroke-width:2.75}
.as-add{margin-top:18px;width:100%;min-height:68px;border-radius:24px;background:var(--cell);color:var(--tint-ink);font-size:21px;font-weight:650;display:flex;align-items:center;justify-content:center;gap:10px}
.as-add svg{font-size:22px;stroke-width:2.5}
.as-nav{width:100%;text-align:left;min-height:68px}
.as-nav svg{color:var(--tint);font-size:24px;stroke-width:2.5}
.as-nav.here .label{font-weight:650}
.as-nav.here:disabled{opacity:1}
.assist button:disabled{opacity:.35;cursor:default}
.assist .as-seg button.sel:disabled{opacity:.55}
.as-note .tinted{margin-left:auto}
.ap-list{margin-top:14px}
@media (max-width:900px){.as-cols{grid-template-columns:minmax(0,1fr)}}
@media (prefers-reduced-motion:reduce){.alert,dialog[open],.spin{animation:none}.switch,.switch::after{transition:none}}
@media (max-width:1240px){.cols-3{grid-template-columns:minmax(0,1fr) minmax(0,1fr)}.cols-3>.col:nth-child(2){grid-row:span 2}}
@media (max-width:760px){
.page,.page.wide{padding:0 16px 56px}
.nav h1{font-size:40px}
.alert{flex-wrap:wrap;gap:14px;padding:16px 16px 16px 18px;border-radius:26px}.alert .glyph{width:44px;height:44px;font-size:22px}.alert .title{font-size:23px}.alert .meta{font-size:16px}.alert button{width:100%;height:54px}
.hero{padding:22px 22px 24px}.hero .top{flex-direction:column;gap:6px}.hero .state{align-items:flex-start;padding-top:0}.hero .name{font-size:44px}.hero .tops li,.hero .scoops li{font-size:32px}.hero .tops .plus{width:36px;height:36px;font-size:20px}
.hero .foot{flex-direction:column;align-items:stretch}.hero .acts{margin:8px 0 0}.primary{justify-content:center;width:100%}
.row{grid-template-columns:minmax(0,1fr) auto;padding:18px 20px;row-gap:10px}.row .items{grid-column:1/-1;grid-row:2}.row .name{font-size:32px}.row .side{grid-column:2;grid-row:1}
.list>.row+.row::before{left:20px}
.split,.cols,.cols-3,.board{grid-template-columns:minmax(0,1fr)}.cols-3>.col:nth-child(2){grid-row:auto}
#boardReady .name,#boardReady.many .name{font-size:52px}#boardReady.many{grid-template-columns:1fr}
.drow{padding-left:20px}
}
`;

const ICONS: Record<string, string> = {
  cone: '<path d="m7 11 4.08 10.35a1 1 0 0 0 1.84 0L17 11"/><path d="M17 7A5 5 0 0 0 7 7"/><path d="M17 7a2 2 0 0 1 0 4H7a2 2 0 0 1 0-4"/>',
  cup: '<path d="M5 8h14l-1.6 11.2a2 2 0 0 1-2 1.8H8.6a2 2 0 0 1-2-1.8z"/><path d="M4 8h16"/>',
  plus: '<path d="M5 12h14"/><path d="M12 5v14"/>',
  circleCheck: '<circle cx="12" cy="12" r="10"/><path d="m9 12 2 2 4-4"/>',
  bellRing: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M22 8c0-2.3-.8-4.3-2-6"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/><path d="M4 2C2.8 3.7 2 5.7 2 8"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  wifiOff: '<path d="M12 20h.01"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/><path d="M5 12.859a10 10 0 0 1 5.17-2.69"/><path d="M19 12.859a10 10 0 0 0-2.007-1.523"/><path d="M2 8.82a15 15 0 0 1 4.177-2.643"/><path d="M22 8.82a15 15 0 0 0-11.288-3.764"/><path d="m2 2 20 20"/>',
  clock: '<circle cx="12" cy="12" r="10"/><path d="M12 6v6l4 2"/>',
  hourglass: '<path d="M5 22h14"/><path d="M5 2h14"/><path d="M17 22v-4.172a2 2 0 0 0-.586-1.414L12 12l-4.414 4.414A2 2 0 0 0 7 17.828V22"/><path d="M7 2v4.172a2 2 0 0 0 .586 1.414L12 12l4.414-4.414A2 2 0 0 0 17 6.172V2"/>',
  logOut: '<path d="m16 17 5-5-5-5"/><path d="M21 12H9"/><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>',
  alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  ban: '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
  chart: '<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
  sparkles: '<path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/>',
  lock: '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  volume: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>',
  volumeX: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><line x1="22" x2="16" y1="9" y2="15"/><line x1="16" x2="22" y1="9" y2="15"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"/>',
  loader: '<path d="M21 12a9 9 0 1 1-6.219-8.56"/>',
  list: '<path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>',
  chevron: '<path d="m9 18 6-6-6-6"/>',
  tablet: '<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><line x1="12" x2="12.01" y1="18" y2="18"/>',
  layout: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
  handHelping: '<path d="M11 12h2a2 2 0 1 0 0-4h-3c-.6 0-1.1.2-1.4.6L3 14"/><path d="m7 18 1.6-1.4c.3-.4.8-.6 1.4-.6h4c1.1 0 2.1-.4 2.8-1.2l4.6-4.4a2 2 0 0 0-2.75-2.91l-4.2 3.9"/><path d="m2 13 6 6"/>',
  minus: '<path d="M5 12h14"/>',
  trash: '<path d="M10 11v6"/><path d="M14 11v6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6"/><path d="M3 6h18"/><path d="M8 6V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/>',
  card: '<rect width="20" height="14" x="2" y="5" rx="2"/><line x1="2" x2="22" y1="10" y2="10"/><path d="M6 14h2"/>',
};

export function icon(name: string, cls = ""): string {
  return `<svg class="i${cls ? ` ${cls}` : ""}" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

export function shell(title: string, body: string, nonce: string, script = ""): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex"><meta name="color-scheme" content="only light"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="format-detection" content="telephone=no">
<meta name="theme-color" content="#F2F2F7">
<title>${escapeHtml(title)}</title><style nonce="${nonce}">${STYLE}</style></head><body>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ""}</body></html>`;
}

export function loginBody(message: string | null, next = "/staff"): string {
  const error = message ? `<p class="err" role="alert">${icon("alert")} ${escapeHtml(message)}</p>` : "";
  return `<main class="signin"><form method="post" action="/dashboard/login"><div class="appicon">${icon("cone")}</div><h1>Booth staff</h1><p>Enter the staff PIN to continue.</p>${error}<input type="hidden" name="next" value="${escapeHtml(next)}"><label for="pin" class="vh">Staff PIN</label><input id="pin" name="pin" type="password" inputmode="numeric" autocomplete="current-password" required autofocus><button class="primary">${icon("lock")} Sign in</button></form></main>`;
}

function signOut(): string {
  return `<form method="post" action="/dashboard/logout" class="web-only"><button class="navbtn">${icon("logOut")}Sign out</button></form>`;
}

function nav(title: string, bar: string, live = true): string {
  return `<header class="nav"><div class="bar">${bar}</div><div class="title"><h1>${escapeHtml(title)}</h1>${live ? `<div class="live connecting" id="link" role="status"></div>` : ""}</div></header>`;
}

export function pickerBody(message: string | null = null): string {
  const group = (kind: StaffRole["kind"], heading: string) => {
    const rows = Object.entries(STAFF_ROLES).filter(([, role]) => role.kind === kind).map(([id, role]: [string, StaffRole]) =>
      `<a class="role" href="/staff/${id}"><span class="ric">${icon(role.icon)}</span><span class="rt"><b>${escapeHtml(role.title)}</b><span>${escapeHtml(role.summary)}</span></span>${icon("chevron", "chev")}</a>`).join("");
    return `<div class="section-head"><h2>${heading}</h2></div><nav class="group list roles">${rows}</nav>`;
  };
  const error = message ? `<div class="section-head"><p class="err" role="alert">${icon("alert")} ${escapeHtml(message)}</p></div>` : "";
  return `<div class="page">${nav("Booth staff", signOut(), false)}${error}${group("ipad", "iPads")}${group("display", "Laptop displays")}</div>`;
}

const SUPPLY_KINDS: SupplyKind[] = ["flavor", "vessel", "topping"];
const SUPPLY_TITLES: Record<SupplyKind, string> = { flavor: "Flavors", vessel: "Cups and cones", topping: "Toppings" };

function supplyGroup(kinds: SupplyKind[], mode: "edit" | "list" | "compact"): string {
  return `<div class="group list${mode === "edit" ? "" : " compact"}" data-supply="${kinds.join(",")}" data-mode="${mode}"></div>`;
}

function suppliesSection(display: boolean, role: StaffRole): string {
  if (display) return SUPPLY_KINDS.map((kind) => `<div class="section-head"><h2>${SUPPLY_TITLES[kind]}</h2></div>${supplyGroup([kind], "list")}`).join("");
  const owned = SUPPLY_KINDS.filter((kind) => role.owns.includes(kind));
  const others = SUPPLY_KINDS.filter((kind) => !role.owns.includes(kind));
  const note = owned.includes("vessel")
    ? "Switch an item off when it runs out. Customers can't choose it on the kiosks until it's back on; anything already in a cart stays. With no cups or cones left, the kiosks show Closed."
    : "Switch a topping off when it runs out. Customers can't add it on the kiosks until it's back on; toppings already in a cart stay.";
  const html = owned.map((kind) => `<div class="section-head"><h2>${SUPPLY_TITLES[kind]}</h2></div>${supplyGroup([kind], "edit")}`).join("")
    + (owned.length ? `<p class="footnote">${note}</p>` : "");
  if (!others.length) return html;
  const owner = Object.values(STAFF_ROLES as Record<string, StaffRole>).find((r) => r.kind === "ipad" && others.every((kind) => r.owns.includes(kind)));
  const title = others.map((kind, i) => (i === 0 ? SUPPLY_TITLES[kind] : SUPPLY_TITLES[kind].toLowerCase())).join(", ");
  return html + `<div class="section-head"><h2>${title}</h2></div>${supplyGroup(others, "compact")}${owner ? `<p class="footnote">Set on the ${escapeHtml(owner.title)} iPad.</p>` : ""}`;
}

const SECTIONS: Record<StaffSection, (display: boolean, role: StaffRole) => string> = {
  make: () => `<div id="make"></div>`,
  handoff: () => `<div id="handoff"></div><details class="finished" id="doneWrap" hidden><summary class="section-head"><h2>Finished${icon("chevron")}</h2><span id="doneTitle"></span></summary><div class="group list" id="done"></div></details>`,
  board: () => `<div class="board"><section><div class="section-head"><h2>Ready for pickup</h2><span id="readyCount"></span></div><div class="group list" id="boardReady"></div></section><section><div class="section-head"><h2>Being made</h2><span id="makingCount"></span></div><div class="group list" id="boardMaking"></div></section></div>`,
  feed: () => `<div class="section-head"><h2>Orders</h2><span id="feedCount"></span></div><div class="group list" id="feed"></div>`,
  supplies: (display, role) => `<div id="soldout">${suppliesSection(display, role)}</div>`,
  kiosks: (display) => `<div class="section-head"><h2>Kiosks</h2><span id="kioskCount"></span></div><div class="group list" id="kiosks"></div>${display ? "" : `<p class="footnote">Tap a kiosk to rename it, close or reopen it, or turn on its debug tools.</p>`}`,
  stats: () => `<div class="section-head"><h2>Today</h2><span id="updated"></span></div>
<div class="group tiles">
<div class="tile wide"><div class="k">Revenue</div><div class="v" id="tRevenue">$0</div><div class="s" id="tAvg"></div></div>
<div class="tile"><div class="k">Orders</div><div class="v" id="tOrders">0</div><div class="s" id="tOrdersSub"></div></div>
<div class="tile"><div class="k">Scoops</div><div class="v" id="tScoops">0</div><div class="s" id="tVessels"></div></div>
<div class="tile"><div class="k">Last 15 min</div><div class="v" id="tRecent">0</div><div class="s" id="tRecentSub"></div></div>
</div>
<div class="section-head"><h2>Scoops by flavor</h2></div><div class="group list" id="flavorBars"></div>
<div class="section-head"><h2>Toppings</h2></div><div class="group list" id="toppingBars"></div>
<div class="section-head"><h2>Orders per hour</h2></div><div class="group list" id="hourBars"></div>`,
};

export function dashboardBody(roleId: string, role: StaffRole): string {
  const display = role.kind === "display";
  const column = (sections: StaffSection[]) => `<div class="col">${sections.map((s) => SECTIONS[s](display, role)).join("")}</div>`;
  const [first, ...rest] = role.columns;
  const main = display
    ? `<main class="cols cols-${role.columns.length}">${role.columns.map(column).join("")}</main>`
    : `<main>${column(first)}${rest.length ? `<div class="split">${rest.map(column).join("")}</div>` : ""}</main>`;
  const bar = display ? "" : `<button class="navbtn" id="sound" type="button" hidden></button><button class="navbtn" id="assistOpen" type="button">${icon("handHelping")}Assist</button><a class="navbtn web-only" href="/staff">${icon("layout")}Pages</a>${signOut()}<button class="navbtn app-only" id="exitStaff" type="button">${icon("logOut")}Exit staff mode</button>`;
  return `<div class="page${display ? " wide" : ""} role-${escapeHtml(roleId)} kind-${role.kind}" id="wrap" data-title="${escapeHtml(role.title)}" data-kind="${role.kind}" data-alerts="${role.alerts}">
${nav(role.title, bar)}
<div class="float"><div id="banner" class="banner" hidden role="status"></div>${role.alerts === "none" ? "" : `<div id="urgent" aria-live="assertive"></div>`}</div>
${role.alerts === "none" ? "" : `<section id="alerts" aria-live="polite"></section>`}
${main}${role.alerts === "front" ? `<section id="updates" aria-live="polite"></section>` : ""}</div>
<div id="toast" class="toast" hidden role="status"></div>
${display ? "" : `<dialog id="kioskSheet" class="sheet" aria-labelledby="ksTitle"><div class="sheet-head"><h3 id="ksTitle"></h3><button class="link" id="ksDone" type="button">Done</button></div><div id="ksNameWrap"></div><div id="ksRest"></div></dialog>`}
${display ? "" : `<dialog id="assistPick" class="sheet" aria-labelledby="apTitle"><div class="sheet-head"><h3 id="apTitle">Assist a customer</h3><button class="link" id="apDone" type="button">Cancel</button></div><p class="footnote">Pick the kiosk the customer is standing at.</p><div class="group list ap-list" id="apList"></div></dialog>`}
${display ? "" : `<dialog id="assist" class="assist" aria-labelledby="asTitle"><div class="assist-page"><header class="nav"><div class="bar"><span class="as-eyebrow">${icon("handHelping")}Assisting</span><button class="navbtn done" id="asDone" type="button">Done</button></div><div class="title"><h1 id="asTitle"></h1><div class="live connecting" id="asLink" role="status"></div></div></header><div id="asAlerts" aria-live="assertive"></div><div id="asNote" aria-live="polite"></div><div class="as-cols"><section id="asOrder"></section><section><div id="asSide"></div><div id="asNameWrap"></div><div id="asEnd"></div></section></div></div></dialog>`}
${display ? "" : `<dialog id="confirm" aria-labelledby="confirmTitle" aria-describedby="confirmText"><h3 id="confirmTitle"></h3><p id="confirmText"></p><div class="dialog-actions"><button class="cancel" id="confirmNo" type="button">Cancel</button><button class="confirm" id="confirmYes" type="button">Confirm</button></div></dialog>`}`;
}

const SCRIPT = String.raw`
"use strict";
var ICONS = __ICONS__;
var TOPPINGS = __TOPPINGS__;
var BASE_TITLE = document.title;
var IN_APP = /BoothStaffApp\//.test(navigator.userAgent);
var WRAP = document.getElementById("wrap");
var ROLE_TITLE = WRAP.getAttribute("data-title"), READONLY = WRAP.getAttribute("data-kind") === "display", ALERTS = WRAP.getAttribute("data-alerts");
var ACTOR = ROLE_TITLE + (IN_APP ? " iPad" : " page");
var OUTBOX_KEY = "booth.outbox.v1", DEVICE_KEY = "booth.device", MUTE_KEY = "booth.muted";
var MAX_QUEUE_AGE = 60 * 60000, SETTLE_GRACE = 5000;
var NEXT = { paid: "preparing", preparing: "ready", ready: "collected" };
var STATUS_LABEL = { paid: "Waiting", preparing: "Scooping", ready: "Ready", collected: "Handed off", canceled: "Canceled" };

function ico(n,c){return '<svg class="i'+(c?" "+c:"")+'" viewBox="0 0 24 24" aria-hidden="true">'+ICONS[n]+'</svg>';}
var $ = function(id){return document.getElementById(id);};
function esc(s){return String(s).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function money(c){var d=c/100;return "$"+(c%100===0?d.toFixed(0):d.toFixed(2));}
function store(k,v){try{if(v==null)localStorage.removeItem(k);else localStorage.setItem(k,v);}catch(e){}}
function load(k){try{return localStorage.getItem(k);}catch(e){return null;}}
function uuid(){
  if(window.crypto&&crypto.randomUUID)return crypto.randomUUID();
  var b=new Uint8Array(16);crypto.getRandomValues(b);
  return Array.prototype.map.call(b,function(x){return (x+256).toString(16).slice(1);}).join("");
}

var deviceId = load(DEVICE_KEY);
if(!deviceId||!/^[A-Za-z0-9._-]{1,64}$/.test(deviceId)){deviceId="web-"+uuid().replace(/-/g,"").slice(0,20);store(DEVICE_KEY,deviceId);}
if(IN_APP)document.body.classList.add("app");

var state=null, stats=null, ws=null, everLive=false, attempt=0, retryTimer=null;
var lastMessageAt=0, connectStartedAt=0, lastPingAt=0, statsTimer=null, serverOffset=0;
var offlineSince=null, pageStartedAt=Date.now();
var outbox=[], settled={}, flushing=false, flushFailures=0, flushTimer=null;
var toastTimer=null;

function now(){return Date.now()+serverOffset;}
function span(ms){
  var s=Math.max(0,Math.round(ms/1000));
  if(s<60)return s+" s";var m=Math.floor(s/60);if(m<60)return m+" min";
  return Math.floor(m/60)+" h "+(m%60)+" min";
}
function ago(ms){
  if(ms==null)return "never";
  var s=Math.max(0,Math.round((now()-ms)/1000));
  if(s<10)return "just now";
  return span(s*1000)+" ago";
}
function clock(ms){return new Date(ms).toLocaleTimeString([],{hour:"numeric",minute:"2-digit"});}
function titleCase(s){return String(s).replace(/[-_]/g," ").replace(/\b\w/g,function(c){return c.toUpperCase();});}
function flavorName(id){
  var f=state&&state.flavors.filter(function(x){return x.id===id;})[0];
  return f?f.name:titleCase(id);
}
function toppingName(id){return Object.prototype.hasOwnProperty.call(TOPPINGS,id)?TOPPINGS[id]:titleCase(id);}
function agoSpan(ms){return '<span data-ago="'+(ms==null?"":ms)+'">'+ago(ms)+"</span>";}

function keyOf(a){
  switch(a.type){
    case "ack":return "ack:"+a.alertId;
    case "setSoldOut":return "supply:flavor:"+a.flavor;
    case "setSupply":return "supply:"+a.kind+":"+a.item;
    case "setKioskOpen":return a.kiosk?"open:"+a.kiosk:"open:*";
    case "renameKiosk":return "name:"+a.kiosk;
    case "setKioskDebug":return "debug:"+a.kiosk;
    case "removeKiosk":return "remove:"+a.kiosk;
    default:return "order:"+a.orderId;
  }
}
function valueOf(a){
  switch(a.type){
    case "ack":case "removeKiosk":return true;
    case "setSoldOut":case "setSupply":return a.soldOut;
    case "setKioskOpen":return a.open;
    case "renameKiosk":return a.name;
    case "setKioskDebug":return a.debug;
    default:return a.status;
  }
}
function supersedes(key,other){return other===key||(key==="open:*"&&other.indexOf("open:")===0);}

function restoreOutbox(){
  try{
    var raw=JSON.parse(load(OUTBOX_KEY)||"[]");
    if(Array.isArray(raw))outbox=raw.filter(function(e){return e&&e.action&&typeof e.action.id==="string";}).map(function(e){return {action:e.action,queuedAt:e.queuedAt||Date.now()};});
  }catch(e){outbox=[];}
}
function saveOutbox(){store(OUTBOX_KEY,outbox.length?JSON.stringify(outbox.map(function(e){return {action:e.action,queuedAt:e.queuedAt};})):null);}

function pendingFor(key){
  for(var i=outbox.length-1;i>=0;i--)if(keyOf(outbox[i].action)===key)return outbox[i];
  return null;
}
function intended(key){
  var p=pendingFor(key);
  if(p)return {value:valueOf(p.action),queued:true};
  var s=settled[key];
  return s?{value:s.value,queued:false}:null;
}

function enqueue(action){
  action.id=uuid();action.by=ACTOR;
  var key=keyOf(action);
  outbox=outbox.filter(function(e){return e.inFlight||!supersedes(key,keyOf(e.action));});
  Object.keys(settled).forEach(function(k){if(supersedes(key,k))delete settled[k];});
  outbox.push({action:action,queuedAt:Date.now()});
  saveOutbox();
  render();
  flush();
}

function expireQueue(){
  var cutoff=Date.now()-MAX_QUEUE_AGE,before=outbox.length;
  outbox=outbox.filter(function(e){return e.inFlight||e.queuedAt>=cutoff;});
  if(outbox.length!==before){
    saveOutbox();
    showToast((before-outbox.length)+" change"+(before-outbox.length===1?"":"s")+" couldn't reach the booth for an hour and "+(before-outbox.length===1?"was":"were")+" dropped. Check and redo if needed.");
  }
}

function scheduleFlush(){
  clearTimeout(flushTimer);
  var delay=Math.min(30000,1000*Math.pow(2,Math.max(0,flushFailures-1)))*(0.5+Math.random());
  flushTimer=setTimeout(flush,delay);
}

function flush(){
  if(flushing||!outbox.length)return;
  clearTimeout(flushTimer);
  expireQueue();
  if(!outbox.length)return render();
  flushing=true;
  var batch=outbox.slice(0,50);
  batch.forEach(function(e){e.inFlight=true;});
  var ctrl=window.AbortController?new AbortController():null;
  var timer=setTimeout(function(){if(ctrl)ctrl.abort();},12000);
  var finish=function(retry){
    clearTimeout(timer);
    batch.forEach(function(e){e.inFlight=false;});
    flushing=false;
    saveOutbox();
    render();
    if(retry){flushFailures++;scheduleFlush();}
    else{flushFailures=0;if(outbox.length)flush();}
  };
  fetch("/v1/actions",{method:"POST",credentials:"same-origin",cache:"no-store",signal:ctrl?ctrl.signal:undefined,
    headers:{"Content-Type":"application/json","X-Booth-Device":deviceId},body:JSON.stringify({actions:batch.map(function(e){return e.action;})})})
  .then(function(r){
    if(r.status===401){clearTimeout(timer);batch.forEach(function(e){e.inFlight=false;});saveOutbox();location.reload();return;}
    if(r.status===400||r.status===403||r.status===413){
      return r.json().catch(function(){return null;}).then(function(j){
        drop(batch);
        showToast("The booth refused "+(batch.length===1?"a change":"these changes")+": "+((j&&j.error&&j.error.message)||("HTTP "+r.status)));
        finish(false);
      });
    }
    if(!r.ok)return finish(true);
    return r.json().then(function(j){
      var rejected=[];
      (j.results||[]).forEach(function(res){
        var entry=batch.filter(function(e){return e.action.id===res.id;})[0];
        if(!entry)return;
        drop([entry]);
        if(res.status==="rejected")rejected.push(res.error&&res.error.message||"rejected");
        else{
          var key=keyOf(entry.action);
          if(!pendingFor(key))settled[key]={value:valueOf(entry.action),at:Date.now()};
        }
      });
      if(rejected.length)showToast("The booth didn't accept a change: "+rejected[0]);
      if(state&&j.rev>state.rev)send({type:"sync"});
      finish(false);
    });
  })
  .catch(function(){finish(true);});
}

function drop(entries){
  outbox=outbox.filter(function(e){return entries.indexOf(e)<0;});
}

function reconcile(){
  if(!state)return;
  var live=isLive(),t=Date.now(),changed=false;
  Object.keys(settled).forEach(function(key){
    var s=settled[key],match;
    var colon=key.indexOf(":"),kind=key.slice(0,colon),id=key.slice(colon+1),k=kioskById(id);
    if(kind==="supply"){var su=supplyByKey(id);match=!!su&&su.soldOut===s.value;}
    else if(kind==="order"){var o=state.orders.filter(function(x){return x.id===id;})[0];match=!!o&&o.status===s.value;}
    else if(key==="open:*"){match=allKiosks().every(function(x){return x.open===s.value;});}
    else if(kind==="open"){match=!!k&&k.open===s.value;}
    else if(kind==="name"){match=!!k&&(k.customName||"")===cleanName(s.value);}
    else if(kind==="debug"){match=!!k&&k.debug===s.value;}
    else if(kind==="remove"){match=!k;}
    else{var a=state.alerts.filter(function(x){return x.id===id;})[0];match=!a||a.ackedAt!=null||a.resolvedAt!=null;}
    if(match||(live&&t-s.at>SETTLE_GRACE)){delete settled[key];changed=true;}
  });
  return changed;
}

function supplies(){
  if(!state)return [];
  return state.supplies||state.flavors.map(function(f){return {kind:"flavor",id:f.id,name:f.name,soldOut:f.soldOut};});
}
function supplyByKey(k){return supplies().filter(function(x){return x.kind+":"+x.id===k;})[0]||null;}
function supplyOut(x){var i=intended("supply:"+x.kind+":"+x.id);return i?i.value:x.soldOut;}
function noVessels(){
  var v=supplies().filter(function(x){return x.kind==="vessel";});
  return v.length>0&&v.every(supplyOut);
}
function orderStatus(o){var i=intended("order:"+o.id);return i?i.value:o.status;}
function alertAcked(a){return !!intended("ack:"+a.id);}

function applyPatch(msg){
  if(!state)return send({type:"sync"});
  if(msg.rev<=state.rev)return;
  if(msg.rev!==state.rev+1)return send({type:"sync"});
  var c=msg.change;
  if(c.kind==="flavors")state.flavors=c.flavors;
  else if(c.kind==="supplies")state.supplies=c.supplies;
  else if(c.kind==="kiosk")state.kiosk=c.kiosk;
  else if(c.kind==="kioskOpen")state.kioskOpen=c.kioskOpen;
  else if(c.kind==="kiosks")state.kiosks=c.kiosks;
  else if(c.kind==="alert"){
    var i=state.alerts.findIndex(function(a){return a.id===c.alert.id;});
    if(i>=0)state.alerts[i]=c.alert;else state.alerts.unshift(c.alert);
    state.alerts.sort(function(a,b){return b.updatedAt-a.updatedAt;});
  } else if(c.kind==="order"){
    var j=state.orders.findIndex(function(o){return o.id===c.order.id;});
    if(j>=0)state.orders[j]=c.order;else state.orders.unshift(c.order);
    state.orders.sort(function(a,b){return b.paidAt-a.paidAt;});
    if(state.orders.length>100)state.orders.length=100;
    scheduleStats(800);
  }
  state.rev=msg.rev;
  reconcile();
  render();
}

function send(m){if(ws&&ws.readyState===1)ws.send(JSON.stringify(m));}

function isLive(){return !!(ws&&ws.readyState===1&&state&&state.liveSocket===ws);}

function onMessage(socket,event){
  lastMessageAt=Date.now();
  var msg;try{msg=JSON.parse(event.data);}catch(e){return;}
  if(msg.type==="snapshot"){
    state=msg.state;state.liveSocket=socket;
    setSessions(msg.state.sessions);
    if(assistKiosk)sendPresence();
    if(state.serverTime)serverOffset=state.serverTime-Date.now();
    everLive=true;offlineSince=null;
    reconcile();render();scheduleStats(0);flush();
  }
  else if(msg.type==="patch")applyPatch(msg);
  else if(msg.type==="session")sessionArrived(msg.kiosk,msg.session);
  else if(msg.type==="result"&&cmdPending[msg.id]&&msg.status==="rejected")commandDone(msg.id,"rejected",msg.error&&msg.error.message);
  else if(msg.type==="pong"){
    if(msg.serverTime)serverOffset=msg.serverTime-Date.now();
    if(state&&msg.rev>state.rev)send({type:"sync"});
  }
}

function markOffline(){
  if(offlineSince==null&&everLive)offlineSince=Date.now();
  render();
}

function connect(){
  clearTimeout(retryTimer);
  if(ws){var old=ws;ws=null;try{old.close();}catch(e){}}
  var url=(location.protocol==="https:"?"wss://":"ws://")+location.host+"/v1/ws";
  var socket;
  try{socket=new WebSocket(url);}catch(e){retryTimer=setTimeout(connect,backoffDelay());return;}
  ws=socket;
  connectStartedAt=Date.now();
  var opened=false;
  socket.onopen=function(){opened=true;attempt=0;lastMessageAt=Date.now();};
  socket.onmessage=function(e){if(ws===socket)onMessage(socket,e);};
  socket.onclose=function(){
    if(ws!==socket)return;
    ws=null;
    markOffline();
    if(!opened){
      fetch("/v1/state",{credentials:"same-origin",cache:"no-store"}).then(function(r){if(r.status===401)location.reload();}).catch(function(){});
    }
    retryTimer=setTimeout(connect,backoffDelay());
  };
  socket.onerror=function(){};
  render();
}

function backoffDelay(){return Math.min(30000,1000*Math.pow(2,attempt++))*(0.5+Math.random());}

function abandonSocket(){
  var dead=ws;ws=null;
  try{dead.close();}catch(e){}
  markOffline();
  clearTimeout(retryTimer);
  retryTimer=setTimeout(connect,backoffDelay());
}

function reconnectNow(){attempt=0;flushFailures=0;if(!ws||ws.readyState>1)connect();flush();}

setInterval(function(){
  if(!ws)return;
  if(ws.readyState===0&&Date.now()-connectStartedAt>10000)return abandonSocket();
  if(ws.readyState!==1)return;
  if(Date.now()-lastMessageAt>25000)return abandonSocket();
  if(Date.now()-lastPingAt>=10000){lastPingAt=Date.now();send({type:"ping",t:lastPingAt});}
},2500);
setInterval(function(){
  if(reconcile())render();
  else{renderLink();refreshTimes();}
  soundTick();
  assistTick();
},1000);
window.addEventListener("online",reconnectNow);
window.addEventListener("offline",function(){if(ws)abandonSocket();});
document.addEventListener("visibilitychange",function(){if(document.visibilityState==="visible")reconnectNow();});
window.addEventListener("pageshow",function(e){if(e.persisted)reconnectNow();});

function dayStart(){var d=new Date();d.setHours(0,0,0,0);return d.getTime();}
function scheduleStats(delay){clearTimeout(statsTimer);statsTimer=setTimeout(loadStats,delay);}
function loadStats(){
  if(!HAS.stats)return;
  clearTimeout(statsTimer);
  statsTimer=setTimeout(loadStats,30000);
  fetch("/v1/stats?since="+dayStart(),{credentials:"same-origin",cache:"no-store"}).then(function(r){
    if(r.status===401){location.reload();return null;}
    return r.ok?r.json():null;
  }).then(function(s){if(s){stats=s;renderStats();}}).catch(function(){});
}

var audio=null, audioURL=null, soundState=IN_APP?"on":"off", heard={}, lastChimeAt=0;
if(IN_APP&&load(MUTE_KEY)==="1")soundState="off";

function chimeURL(){
  if(audioURL)return audioURL;
  var rate=22050,dur=1.15,n=Math.floor(rate*dur),notes=[[880,0],[1318.5,.15],[880,.55],[1318.5,.7]];
  var buf=new ArrayBuffer(44+n*2),v=new DataView(buf);
  var str=function(o,s){for(var i=0;i<s.length;i++)v.setUint8(o+i,s.charCodeAt(i));};
  str(0,"RIFF");v.setUint32(4,36+n*2,true);str(8,"WAVE");str(12,"fmt ");v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);
  v.setUint32(24,rate,true);v.setUint32(28,rate*2,true);v.setUint16(32,2,true);v.setUint16(34,16,true);str(36,"data");v.setUint32(40,n*2,true);
  for(var i=0;i<n;i++){
    var t=i/rate,s=0;
    for(var k=0;k<notes.length;k++){var dt=t-notes[k][1];if(dt>=0&&dt<.5)s+=Math.sin(2*Math.PI*notes[k][0]*dt)*Math.exp(-dt*6)*Math.min(1,dt*300);}
    v.setInt16(44+i*2,Math.max(-1,Math.min(1,s*.5))*32767,true);
  }
  audioURL=URL.createObjectURL(new Blob([buf],{type:"audio/wav"}));
  return audioURL;
}

function chime(fromTap){
  if(!IN_APP||(soundState==="off"&&!fromTap))return;
  lastChimeAt=Date.now();
  try{
    if(!audio){audio=new Audio(chimeURL());audio.preload="auto";}
    audio.currentTime=0;
    var p=audio.play();
    if(p&&p.then)p.then(function(){if(soundState!=="off"){soundState="on";renderSound();}},function(){soundState="locked";renderSound();});
  }catch(e){soundState="locked";renderSound();}
}

function urgentOpen(){
  if(!state)return [];
  return state.alerts.filter(function(a){return a.severity==="urgent"&&a.ackedAt==null&&a.resolvedAt==null&&!alertAcked(a);});
}

function soundTick(){
  if(!HAS.alerts||ALERTS!=="front")return;
  var open=urgentOpen();
  var fresh=open.filter(function(a){return !heard[a.id+":"+a.count];});
  open.forEach(function(a){heard[a.id+":"+a.count]=true;});
  if(fresh.length&&Date.now()-lastChimeAt>1500)chime(false);
  else if(open.length&&Date.now()-lastChimeAt>=30000)chime(false);
  document.title=open.length?"("+open.length+") Needs attention - "+BASE_TITLE:BASE_TITLE;
}

function renderSound(){
  var b=$("sound");
  if(!b)return;
  b.hidden=!IN_APP||!HAS.alerts||ALERTS!=="front"||soundState==="on";
  if(soundState==="locked"){b.className="navbtn attn";b.innerHTML=ico("volumeX")+"Enable sound";b.setAttribute("aria-label","Enable alert sound");}
  else if(soundState==="on"){b.className="navbtn";b.innerHTML=ico("volume")+"Sound on";b.setAttribute("aria-label","Alert sound on, tap to mute");}
  else{b.className="navbtn dim";b.innerHTML=ico("volumeX")+"Muted";b.setAttribute("aria-label","Alert sound muted, tap to turn on");}
}

function showToast(text,undo){
  var t=$("toast");
  var host=assistKiosk&&$("assist")?$("assist"):document.body;
  if(t.parentNode!==host)host.appendChild(t);
  clearTimeout(toastTimer);
  t.className="toast"+(undo?"":" plain");
  t.innerHTML='<span>'+esc(text)+'</span>'+(undo?'<button class="undo" type="button" id="undo">'+ico("undo")+"Undo</button>":"");
  t.hidden=false;
  if(undo)$("undo").onclick=function(){t.hidden=true;undo();};
  toastTimer=setTimeout(function(){t.hidden=true;},undo?7000:6000);
}

function renderLink(){
  var link=$("link"),banner=$("banner");
  var queued=outbox.length,live=isLive();
  if(live){link.className="live";link.innerHTML='<span class="dot"></span>Live';}
  else if(offlineSince!=null||(!everLive&&Date.now()-pageStartedAt>8000)||navigator.onLine===false){
    link.className="live off";link.innerHTML='<span class="dot"></span>'+(offlineSince!=null?"Offline since "+clock(offlineSince):"Offline");
  } else {link.className="live connecting";link.innerHTML='<span class="dot"></span>Connecting';}
  var head=null,sub="",cls="warn",glyph="clock";
  if(!live&&offlineSince!=null){
    cls="bad";glyph="wifiOff";
    head="Offline for "+span(Date.now()-offlineSince);
    sub="Showing the last known state. Reconnecting automatically.";
  } else if(!live&&!everLive&&Date.now()-pageStartedAt>8000){
    cls="bad";glyph="wifiOff";head="Can't reach the booth";sub="Retrying automatically.";
  }
  if(queued){
    var q=queued+" change"+(queued===1?"":"s")+" saved on this device, "+(live?"sending now.":"sent when the connection returns.");
    if(head)sub+=" "+q;else{head=q;sub="";}
  }
  if(head){
    banner.hidden=false;banner.className="banner "+cls;
    banner.innerHTML='<span class="glyph">'+ico(glyph)+'</span><span><b>'+esc(head)+"</b>"+(sub?'<span class="sub">'+esc(sub)+"</span>":"")+"</span>";
  } else banner.hidden=true;
}

function plural(n,w){return n+" "+w+(n===1?"":"s");}

function bars(el,entries,labeler){
  if(!entries.length){el.innerHTML='<div class="empty">Nothing yet</div>';return;}
  var max=Math.max.apply(null,entries.map(function(e){return e[1];}));
  el.innerHTML=entries.map(function(e){
    return '<div class="bar"><span class="name">'+esc(labeler(e[0]))+'</span><span class="track"><span class="fill" style="width:'+Math.round(e[1]/max*100)+'%"></span></span><span class="n">'+e[1]+"</span></div>";
  }).join("");
}
function sortedCounts(obj){return Object.keys(obj).map(function(k){return [k,obj[k]];}).sort(function(a,b){return b[1]-a[1];});}

function renderStats(){
  var s=stats;if(!s)return;
  $("tOrders").textContent=s.orders;
  $("tOrdersSub").textContent=plural(s.items,"item")+(s.canceledOrders?", "+s.canceledOrders+" canceled":"")+(s.simulatedOrders?", "+s.simulatedOrders+" test":"");
  $("tRevenue").textContent=money(s.totalCents);
  $("tAvg").textContent=s.orders?"Average "+money(s.averageCents):"No orders yet";
  $("tScoops").textContent=s.scoops;
  $("tVessels").textContent=plural(s.cones,"cone")+", "+plural(s.cups,"cup")+", "+plural(s.toppings,"topping");
  var r=s.last15Min||{orders:0,totalCents:0};
  $("tRecent").textContent=r.orders;
  $("tRecentSub").textContent=money(r.totalCents)+" taken";
  bars($("flavorBars"),sortedCounts(s.flavors),flavorName);
  bars($("toppingBars"),sortedCounts(s.toppingCounts),toppingName);
  bars($("hourBars"),s.byHour.map(function(h){return [h.hour,h.orders];}),clock);
  $("updated").textContent="Since midnight, updated "+clock(s.generatedAt);
}

function refreshTimes(){
  document.querySelectorAll("[data-ago]").forEach(function(el){
    var v=el.getAttribute("data-ago");el.textContent=ago(v===""?null:Number(v));
  });
}

function pendingTag(key){
  var p=pendingFor(key);
  if(!p)return "";
  return '<span class="pending">'+(isLive()?ico("loader","spin")+"Saving":ico("clock")+"Waiting to send")+"</span>";
}

function alertIcon(a){return a.kind==="help"?"bellRing":a.kind==="soldout"?"ban":a.kind==="offline"?"wifiOff":"alert";}

function openAlerts(){
  return state.alerts.filter(function(a){return a.ackedAt==null&&a.resolvedAt==null&&!alertAcked(a);});
}

function alertMeta(a){
  var d=String(a.detail||"").replace(/[.\s]+$/,"");
  return (d?esc(d)+", ":"")+agoSpan(a.updatedAt);
}
function times(a){return a.count>1?' <span class="times">×'+a.count+"</span>":"";}

function alertBar(a){
  return '<section class="alert" role="alert"><div class="glyph">'+ico(alertIcon(a))+'</div><div class="text"><div class="title">'+esc(a.title)+times(a)+'</div><div class="meta">'+alertMeta(a)+"</div></div>"+(READONLY?"":'<button type="button" data-ack="'+esc(a.id)+'">Acknowledge</button>')+"</section>";
}

function alertCell(a){
  var info=a.severity==="info";
  return '<div class="cell acell sev-'+esc(a.severity)+'"><span class="aglyph">'+ico(alertIcon(a))+'</span><div class="grow"><div class="label">'+esc(a.title)+times(a)+'</div><div class="sub">'+alertMeta(a)+"</div></div>"+pendingTag("ack:"+a.id)+(READONLY?"":'<button class="link" type="button" data-ack="'+esc(a.id)+'">'+(info?"Clear":"Acknowledge")+"</button>")+"</div>";
}

function alertList(title,list,ackLabel,max){
  if(!list.length)return "";
  var ids=list.map(function(a){return a.id;}).join(",");
  var right=!READONLY&&list.length>1?'<button class="link" type="button" data-ackids="'+esc(ids)+'">'+ackLabel+"</button>":list.length>1?"<span>"+list.length+"</span>":"";
  return '<div class="section-head"><h2>'+title+"</h2>"+right+'</div><div class="group list">'+list.slice(0,max).map(alertCell).join("")+(list.length>max?'<div class="cell more">And '+(list.length-max)+" more</div>":"")+"</div>";
}

function renderAlerts(){
  var open=openAlerts().sort(function(a,b){return b.updatedAt-a.updatedAt;});
  var urgent=open.filter(function(a){return a.severity==="urgent";});
  var warn=open.filter(function(a){return a.severity==="warning";});
  var info=open.filter(function(a){return a.severity==="info";});
  var bars="",rest="";
  if(ALERTS==="front"){
    bars=urgent.slice(0,2).map(alertBar).join("");
    rest=alertList(urgent.length>2?"More alerts":"Alerts",urgent.slice(2).concat(warn),"Acknowledge all",5);
    $("updates").innerHTML=alertList("Updates",info,"Clear all",3);
  } else if(ALERTS==="display"){
    bars=urgent.slice(0,3).map(alertBar).join("");
    rest=alertList("Alerts",urgent.slice(3).concat(warn),"",6);
  } else rest=alertList("Alerts",urgent.concat(warn),"Acknowledge all",3);
  if($("urgent"))$("urgent").innerHTML=bars;
  $("alerts").innerHTML=rest;
}

function vesselName(v){return v==="cone"?"Waffle cone":titleCase(v);}
function vesselIcon(v){return v==="cone"?"cone":"cup";}
function flavorCounts(ids){
  var order=[],n={};
  ids.forEach(function(id){if(!n[id]){n[id]=0;order.push(id);}n[id]++;});
  return order.map(function(id){return {name:flavorName(id),n:n[id]};});
}
function joinAnd(list){return list.length<2?list.join(""):list.slice(0,-1).join(", ")+" and "+list[list.length-1];}
function flavorText(ids){
  var c=flavorCounts(ids);
  return c.length?joinAnd(c.map(function(x){return x.name+(x.n>1?" ×"+x.n:"");})):"No flavor";
}

function toppingItem(it){
  var t=it.toppings||[];
  return '<div class="item"><div class="base">'+ico(vesselIcon(it.vessel))+esc(vesselName(it.vessel)+", "+flavorText(it.flavors))+"</div>"+
    (t.length?'<ul class="tops">'+t.map(function(x){return '<li><span class="plus">'+ico("plus")+"</span>"+esc(toppingName(x))+"</li>";}).join("")+"</ul>":'<div class="none">No toppings</div>')+"</div>";
}

function scoopItem(it){
  var c=flavorCounts(it.flavors),t=it.toppings||[];
  return '<div class="item"><div class="base">'+ico(vesselIcon(it.vessel))+esc(vesselName(it.vessel))+'</div><ul class="scoops">'+
    (c.length?c.map(function(x){return "<li>"+esc(x.name)+(x.n>1?'<span class="times">×'+x.n+"</span>":"")+"</li>";}).join(""):'<li class="none">No flavor</li>')+"</ul>"+
    (t.length?'<div class="then">'+ico("plus")+esc(t.map(toppingName).join(", "))+"</div>":"")+"</div>";
}

function orderKiosk(o){
  if(!o.kioskId||allKiosks().length<2)return "";
  var k=kioskById(o.kioskId);
  return k?kioskName(k):"";
}
function orderFine(o){
  var parts=[];
  if(o.orderNumber!=null)parts.push("#"+o.orderNumber);
  var k=orderKiosk(o);
  if(k)parts.push(k);
  return parts.join(" · ");
}
function whoHtml(o,bare){
  var fine=bare?"":orderFine(o);
  return '<div class="who"><span class="name">'+esc(o.customerName||"Guest")+"</span>"+(fine?'<span class="num">'+esc(fine)+"</span>":"")+"</div>";
}
function orderLabel(o){return o.customerName||"Guest";}
function tag(text,icon,cls){return '<span class="tag '+(cls||"")+'">'+ico(icon)+text+"</span>";}
function ageTag(o){return '<span class="age">'+agoSpan(o.receivedAt)+"</span>";}
function moveBtn(o,to,label,icon,cls){return '<button class="'+cls+'" type="button" data-order="'+esc(o.id)+'" data-to="'+to+'">'+ico(icon)+label+"</button>";}
function cancelBtn(o,label){return '<button class="plain" type="button" data-cancel="'+esc(o.id)+'">'+label+"</button>";}

function heroCard(o,mode){
  var make=mode==="make";
  var items=o.items.map(make?scoopItem:toppingItem).join("");
  var label=make?tag("Scooping","clock","tint"):tag("Ready for toppings","circleCheck","tint");
  var acts=make?moveBtn(o,"ready","Done","check","primary"):moveBtn(o,"collected","Handed off","check","primary")+cancelBtn(o,"Cancel order");
  return '<article class="group hero"><div class="top">'+whoHtml(o)+'<div class="state">'+label+(make?ageTag(o):"")+pendingTag("order:"+o.id)+'</div></div><div class="foot"><div class="items">'+items+'</div><div class="acts">'+acts+"</div></div></article>";
}

function orderRow(o,status,mode){
  var make=mode==="make";
  var label=status==="preparing"?tag("Scooping","clock"):tag("Waiting","hourglass","dim");
  var act=make?moveBtn(o,"preparing","Start","play","tinted"):cancelBtn(o,"Cancel");
  return '<article class="row">'+whoHtml(o)+'<div class="items">'+o.items.map(make?scoopItem:toppingItem).join("")+'</div><div class="side">'+label+(make?ageTag(o):"")+pendingTag("order:"+o.id)+act+"</div></article>";
}

function head(title,right){return '<div class="section-head"><h2>'+title+"</h2>"+(right?"<span>"+right+"</span>":"")+"</div>";}
function emptyGroup(text){return '<div class="group"><div class="empty">'+text+"</div></div>";}

function realOrders(){
  return state.orders.filter(function(o){return !o.simulated;}).map(function(o){return {o:o,s:orderStatus(o)};});
}
function byPaid(a,b){return a.o.paidAt-b.o.paidAt;}

function renderMake(){
  var all=realOrders();
  var making=all.filter(function(x){return x.s==="preparing";}).sort(byPaid);
  var next=all.filter(function(x){return x.s==="paid";}).sort(byPaid);
  var html="";
  if(making.length)html+=head("Scooping",plural(making.length,"order"))+making.map(function(x){return heroCard(x.o,"make");}).join("");
  if(next.length)html+=head(making.length?"Up next":"To make",plural(next.length,"order"))+'<section class="group list">'+next.map(function(x){return orderRow(x.o,x.s,"make");}).join("")+"</section>";
  $("make").innerHTML=html||head("To make","")+emptyGroup("Nothing to make. New orders appear here the moment a customer pays.");
}

function renderHandoff(){
  var all=realOrders();
  var ready=all.filter(function(x){return x.s==="ready";}).sort(byPaid);
  var coming=all.filter(function(x){return x.s==="paid"||x.s==="preparing";}).sort(byPaid);
  var done=all.filter(function(x){return x.s==="collected"||x.s==="canceled";}).sort(function(a,b){return b.o.statusAt-a.o.statusAt;}).slice(0,12);
  var html=head("Queue",ready.length+coming.length?plural(ready.length+coming.length,"order"):"");
  if(ready.length)html+=ready.map(function(x){return heroCard(x.o,"handoff");}).join("");
  else html+=emptyGroup(coming.length?"Nothing ready for toppings yet. Orders move here when the scooper taps Done.":"No open orders. New orders appear here the moment a customer pays.");
  if(coming.length)html+=head("Coming up","")+'<section class="group list">'+coming.map(function(x){return orderRow(x.o,x.s,"handoff");}).join("")+"</section>";
  $("handoff").innerHTML=html;
  $("doneWrap").hidden=!done.length;
  $("doneTitle").textContent=done.length?plural(done.length,"order"):"";
  $("done").innerHTML=done.map(function(x){
    var back=x.s==="canceled"?"paid":"ready";
    return '<div class="drow">'+whoHtml(x.o)+'<span class="when s-'+x.s+'">'+STATUS_LABEL[x.s]+" "+agoSpan(x.o.statusAt)+"</span>"+pendingTag("order:"+x.o.id)+'<button class="link" type="button" data-order="'+esc(x.o.id)+'" data-to="'+back+'">'+ico("undo")+"Reopen</button></div>";
  }).join("");
}

function renderBoard(){
  var all=realOrders();
  var making=all.filter(function(x){return x.s==="paid"||x.s==="preparing";}).sort(byPaid);
  var ready=all.filter(function(x){return x.s==="ready";}).sort(byPaid);
  var row=function(x){return '<div class="brow">'+whoHtml(x.o,true)+"</div>";};
  $("boardReady").className="group list"+(ready.length>4?" many":"");
  $("boardReady").innerHTML=ready.map(row).join("")||'<div class="empty">Nothing waiting for pickup</div>';
  $("boardMaking").innerHTML=making.map(row).join("")||'<div class="empty">Nothing being made</div>';
  $("readyCount").textContent=ready.length?plural(ready.length,"order"):"";
  $("makingCount").textContent=making.length?plural(making.length,"order"):"";
}

var SUPPLY_NONE={flavor:"No flavors yet",vessel:"No cups or cones listed",topping:"No toppings listed"};
function renderSupplies(){
  document.querySelectorAll("[data-supply]").forEach(function(el){
    var kinds=el.getAttribute("data-supply").split(","),mode=el.getAttribute("data-mode");
    var list=supplies().filter(function(x){return kinds.indexOf(x.kind)>=0;});
    if(mode==="compact"){
      var out=list.filter(supplyOut);
      el.innerHTML=out.map(function(x){return '<div class="cell"><span class="label">'+esc(x.name)+'</span><span class="value bad">Sold out</span></div>';}).join("")||'<div class="cell"><span class="none">'+(list.length?"All available":"Nothing listed yet")+"</span></div>";
      return;
    }
    el.innerHTML=list.map(function(x){
      var o=supplyOut(x),key="supply:"+x.kind+":"+x.id;
      if(mode==="list")return '<div class="cell"><span class="label">'+esc(x.name)+'</span><span class="value'+(o?" bad":"")+'">'+(o?"Sold out":"Available")+"</span></div>";
      return '<div class="cell"><div class="grow"><div class="label">'+esc(x.name)+"</div>"+(o?'<div class="soldout">Sold out</div>':"")+pendingTag(key)+'</div><button class="switch" role="switch" type="button" data-supply-key="'+esc(x.kind+":"+x.id)+'" aria-checked="'+(!o)+'" aria-label="'+esc(x.name)+' available"></button></div>';
    }).join("")||'<div class="empty">'+SUPPLY_NONE[kinds[0]]+"</div>";
  });
}

function allKiosks(){return state&&state.kiosks||[];}
function kioskById(id){return allKiosks().filter(function(k){return k.id===id;})[0]||null;}
function kioskList(){return allKiosks().filter(function(k){return !intended("remove:"+k.id);});}
function cleanName(v){return String(v==null?"":v).replace(/\s+/g," ").trim().slice(0,40);}
function defaultName(k){return k.reportedName||"Kiosk "+k.tag;}
function kioskName(k){var i=intended("name:"+k.id);return i?(cleanName(i.value)||defaultName(k)):k.name;}
function kioskDebug(k){var i=intended("debug:"+k.id);return i?i.value:k.debug;}
function kioskOpenNow(k){
  for(var i=outbox.length-1;i>=0;i--){var a=outbox[i].action;if(a.type==="setKioskOpen"&&(!a.kiosk||a.kiosk===k.id))return a.open;}
  var one=settled["open:"+k.id],all=settled["open:*"],s=one&&all?(one.at>=all.at?one:all):(one||all);
  return s?s.value:k.open;
}
function openPending(k){return pendingTag("open:"+k.id)||pendingTag("open:*");}

function kioskShort(k){
  if(!isLive())return {html:"Status unknown while this page is offline",bad:false};
  if(!k.online)return {html:"Offline, last heard "+agoSpan(k.lastSeenAt),bad:true};
  var h=k.health,parts=["Online"];
  if(h){
    parts.push(h.simulatePayment?"payments simulated":h.readerReady?"card reader ready":"card reader not ready");
    if(h.deviceBattery&&h.deviceBattery.percent>=0)parts.push("battery "+h.deviceBattery.percent+"%"+(h.deviceBattery.charging?", charging":""));
  }
  return {html:esc(parts.join(", ")),bad:!!h&&!h.simulatePayment&&!h.readerReady};
}

function renderKiosks(){
  var list=kioskList();
  $("kioskCount").textContent=list.length>1?plural(list.length,"kiosk"):"";
  if(!list.length){$("kiosks").innerHTML='<div class="empty">No kiosk has connected yet. A kiosk iPad shows up here once it starts.</div>';if(sheetKiosk)closeSheet();return;}
  var empty=noVessels();
  var html=list.map(function(k){
    var open=kioskOpenNow(k),s=kioskShort(k),taking=open&&!empty;
    var text='<div class="label">'+esc(kioskName(k))+'</div><div class="sub'+(s.bad?" bad":"")+'">'+s.html+"</div>"+(open&&empty?'<div class="sub warn">No cups or cones left</div>':"")+(kioskDebug(k)?'<div class="sub warn">Debug tools on</div>':"")+openPending(k)+pendingTag("name:"+k.id)+pendingTag("debug:"+k.id);
    var inner='<span class="kglyph'+(k.online?"":" off")+'">'+ico("tablet")+'</span><div class="grow">'+text+'</div><span class="value'+(taking?"":" bad")+'">'+(taking?"Open":"Closed")+"</span>";
    return READONLY?'<div class="cell kcell">'+inner+"</div>":'<button class="cell kcell" type="button" data-kiosk="'+esc(k.id)+'" aria-label="'+esc(kioskName(k))+', '+(taking?"open":"closed")+'">'+inner+ico("chevron","chev")+"</button>";
  }).join("");
  if(!READONLY){
    var one=list.length===1,anyOpen=list.some(kioskOpenNow),anyClosed=list.some(function(k){return !kioskOpenNow(k);});
    if(anyOpen)html+='<div class="cell"><button class="destructive" type="button" data-allopen="0">'+(one?"Close kiosk":"Close all kiosks")+"</button>"+pendingTag("open:*")+"</div>";
    if(anyClosed)html+='<div class="cell"><button class="action" type="button" data-allopen="1">'+(one?"Reopen kiosk":"Open all kiosks")+"</button></div>";
  }
  $("kiosks").innerHTML=html;
  if(sheetKiosk)renderSheet(false);
}

var sheetKiosk=null;
function openSheet(id){
  if(!kioskById(id))return;
  sheetKiosk=id;
  renderSheet(true);
  var d=$("kioskSheet");
  if(d.showModal){if(!d.open)d.showModal();}else d.setAttribute("open","");
}
function closeSheet(){
  sheetKiosk=null;
  var d=$("kioskSheet");
  if(!d)return;
  if(d.close){if(d.open)d.close();}else d.removeAttribute("open");
}

function healthRows(k){
  var h=k.health;
  var rows=[k.online?["Connection","Online",""]:["Last heard",null,"bad",agoSpan(k.lastSeenAt)],["Screen",k.screen?titleCase(k.screen):"Unknown",""]];
  if(h){
    rows.push(["Payments",h.simulatePayment?"Simulated":h.environment,h.simulatePayment?"warn":""]);
    rows.push(["Square",h.authorized?"Authorized":(h.authorizationState||"Not authorized"),h.authorized?"":"bad"]);
    rows.push(["Card reader",h.readerReady?"Ready":"Not ready",h.readerReady||h.simulatePayment?"":"bad"]);
    h.readers.forEach(function(r){
      if(r.batteryPercent!=null&&r.batteryPercent>=0)rows.push([r.name,r.batteryPercent+"%"+(r.isCharging?", charging":""),r.batteryPercent<=20&&!r.isCharging?"bad":""]);
    });
    if(h.deviceBattery&&h.deviceBattery.percent>=0)rows.push(["iPad battery",h.deviceBattery.percent+"%"+(h.deviceBattery.charging?", charging":""),h.deviceBattery.percent<=20&&!h.deviceBattery.charging?"bad":""]);
    rows.push(["Catalog",h.catalog.ok?"OK":(h.catalog.error||h.catalog.status),h.catalog.ok?"":"warn"]);
    if(h.lastError)rows.push(["Last error",h.lastError,"warn"]);
    rows.push(["App",h.appVersion,""]);
  } else rows.push(["Health","No report yet","warn"]);
  rows.push(["Kiosk ID",k.tag,""]);
  return rows.map(function(r){
    return '<div class="cell"><span class="label">'+esc(r[0])+'</span><span class="value '+r[2]+'">'+(r[3]?r[3]:esc(r[1]))+"</span></div>";
  }).join("");
}

function renderSheet(fresh){
  var k=kioskById(sheetKiosk);
  if(!k||intended("remove:"+k.id)){closeSheet();return;}
  var name=kioskName(k),open=kioskOpenNow(k),debug=kioskDebug(k);
  $("ksTitle").textContent=name;
  if(fresh||!$("ksName")){
    $("ksNameWrap").innerHTML='<div class="section-head"><h2>Name</h2></div><div class="group"><form class="cell" id="ksForm"><input id="ksName" class="field" maxlength="40" autocomplete="off" autocapitalize="words" spellcheck="false" enterkeyhint="done" aria-label="Kiosk name" value="'+esc(name)+'" placeholder="'+esc(defaultName(k))+'"><button class="link" type="submit">Save</button></form></div><p class="footnote">Shown on alerts and staff pages. Leave it empty to use '+esc(defaultName(k))+".</p>";
  }
  var html='<div class="section-head"><h2>Controls</h2></div><div class="group list">';
  html+='<div class="cell"><div class="grow"><div class="label">Taking orders</div><div class="sub">'+(!open?"Begin Order is off. Customers mid-order can still finish.":noVessels()?"Paused while cups and cones are both sold out.":"Customers can start new orders.")+"</div>"+openPending(k)+'</div><button class="switch" role="switch" type="button" data-kopen="'+esc(k.id)+'" aria-checked="'+open+'" aria-label="Taking orders"></button></div>';
  html+='<div class="cell"><div class="grow"><div class="label">Debug tools</div><div class="sub">Shows the debug bar at the top of this kiosk\'s screen.</div>'+pendingTag("debug:"+k.id)+'</div><button class="switch" role="switch" type="button" data-kdebug="'+esc(k.id)+'" aria-checked="'+debug+'" aria-label="Debug tools"></button></div>';
  html+='</div><div class="section-head"><h2>Customer</h2></div><div class="group list"><div class="cell"><div class="grow"><div class="label">Assist</div><div class="sub">'+(assistable(k)?"See the order on this kiosk live and change it for the customer.":"Needs the kiosk to be online.")+'</div></div><button class="tinted" type="button" data-kassist="'+esc(k.id)+'"'+dis(!assistable(k))+">"+ico("handHelping")+"Assist</button></div></div>";
  html+='<div class="section-head"><h2>Status</h2></div><div class="group list health">'+healthRows(k)+"</div>";
  if(!k.online)html+='<div class="section-head"></div><div class="group list"><div class="cell"><button class="destructive" type="button" data-kremove="'+esc(k.id)+'">Remove kiosk</button></div></div><p class="footnote">For an iPad that isn\'t a kiosk any more. Its alerts close; if it connects again it comes back as '+esc(defaultName(k))+".</p>";
  $("ksRest").innerHTML=html;
}

function saveName(){
  var k=kioskById(sheetKiosk),input=$("ksName");
  if(!k||!input)return;
  var name=cleanName(input.value);
  input.blur();
  if(name===defaultName(k)&&!k.customName)name="";
  var i=intended("name:"+k.id),current=i?cleanName(i.value):(k.customName||"");
  if(name===current){input.value=kioskName(k);return;}
  enqueue({type:"renameKiosk",kiosk:k.id,name:name});
  input.value=kioskName(k);
  showToast("Renamed to "+kioskName(k));
}

function askKioskOpen(k,open){
  var name=kioskName(k);
  if(open)ask("Reopen "+name+"?","Customers will be able to start new orders on "+name+" right away.","Reopen kiosk",false,"Cancel",function(){enqueue({type:"setKioskOpen",kiosk:k.id,open:true});});
  else ask("Close "+name+"?","Begin Order turns off on "+name+". A customer already ordering there can still finish and pay.","Close kiosk",true,"Cancel",function(){enqueue({type:"setKioskOpen",kiosk:k.id,open:false});});
}

function askAllOpen(open){
  var list=kioskList();
  if(list.length===1)return askKioskOpen(list[0],open);
  if(open)ask("Open all kiosks?","Customers will be able to start new orders on every kiosk right away.","Open all",false,"Cancel",function(){enqueue({type:"setKioskOpen",open:true});});
  else ask("Close all kiosks?","Begin Order turns off on every kiosk. Customers already ordering can still finish and pay.","Close all",true,"Cancel",function(){enqueue({type:"setKioskOpen",open:false});});
}

function askRemove(k){
  var name=kioskName(k);
  ask("Remove "+name+"?","It leaves the kiosk list and its alerts close. If the iPad connects again it comes back as "+defaultName(k)+".","Remove",true,"Cancel",function(){enqueue({type:"removeKiosk",kiosk:k.id});closeSheet();});
}

function askExit(){
  ask("Exit staff mode?","This iPad goes back to the role picker, where it can start as a kiosk or open a staff page again.","Exit",false,"Cancel",function(){
    var h=window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.boothApp;
    if(h)h.postMessage({type:"exitStaffMode"});
    else showToast("This version of the app can't switch roles from here. Relaunch it to pick a role.");
  });
}

function renderFeed(){
  var list=state.orders.slice().sort(function(a,b){return b.paidAt-a.paidAt;});
  var real=list.filter(function(o){return !o.simulated;}).length;
  $("feedCount").textContent=real?plural(real,"order"):"";
  if(!list.length){$("feed").innerHTML='<div class="empty">No orders yet. They appear here the moment a customer pays.</div>';return;}
  $("feed").innerHTML=list.slice(0,40).map(function(o){
    var st=orderStatus(o);
    var items=o.items.map(function(it){
      var t=it.toppings&&it.toppings.length?" with "+joinAnd(it.toppings.map(toppingName)):"";
      return vesselName(it.vessel)+", "+flavorText(it.flavors)+t;
    }).join("; ");
    return '<div class="frow'+(o.simulated?" sim":"")+'">'+whoHtml(o)+'<div class="fside"><span class="fstatus s-'+st+'">'+(o.simulated?"Test, ":"")+STATUS_LABEL[st]+"</span>"+pendingTag("order:"+o.id)+'<span class="total">'+money(o.totalCents)+", "+clock(o.paidAt)+'</span></div><div class="fitems">'+esc(items)+"</div></div>";
  }).join("");
}

var HAS={alerts:!!$("alerts"),make:!!$("make"),handoff:!!$("handoff"),board:!!$("boardMaking"),feed:!!$("feed"),soldout:!!document.querySelector("[data-supply]"),kiosks:!!$("kiosks"),stats:!!$("tOrders")};

function render(){
  renderLink();renderSound();
  if(!state){
    var waiting='<div class="empty">'+ico("loader","spin")+" Waiting for the booth</div>";
    ["make","handoff","feed","kiosks","boardMaking"].forEach(function(id){if($(id)&&!$(id).innerHTML)$(id).innerHTML=id==="make"||id==="handoff"?'<div class="group" style="margin-top:34px">'+waiting+"</div>":waiting;});
    document.querySelectorAll("[data-supply]").forEach(function(el){if(!el.innerHTML)el.innerHTML=waiting;});
    return;
  }
  if(HAS.alerts)renderAlerts();
  if(HAS.make)renderMake();
  if(HAS.handoff)renderHandoff();
  if(HAS.board)renderBoard();
  if(HAS.feed)renderFeed();
  if(HAS.soldout)renderSupplies();
  if(HAS.kiosks)renderKiosks();
  if(assistKiosk)renderAssist(false);
  if(pickerOpen())renderPicker();
  fitNames();
}

function fitNames(){
  var names=document.querySelectorAll(".who .name");
  for(var i=0;i<names.length;i++){
    var el=names[i];
    el.style.fontSize="";
    var size=parseFloat(getComputedStyle(el).fontSize),min=size*.6;
    while(el.scrollWidth>el.clientWidth+1&&size>min){size-=2;el.style.fontSize=size+"px";}
    el.style.overflowWrap=el.scrollWidth>el.clientWidth+1?"anywhere":"";
  }
}
window.addEventListener("resize",fitNames);

function setStatus(id,to,withUndo){
  var o=state&&state.orders.filter(function(x){return x.id===id;})[0];
  if(!o)return;
  var from=orderStatus(o);
  if(from===to)return;
  enqueue({type:"setOrderStatus",orderId:id,status:to});
  if(withUndo)showToast(orderLabel(o)+": "+STATUS_LABEL[to],function(){enqueue({type:"setOrderStatus",orderId:id,status:from});});
}

var pendingConfirm=null;
function ask(title,text,yesLabel,danger,noLabel,onYes){
  pendingConfirm=onYes;
  $("confirmTitle").textContent=title;
  $("confirmText").textContent=text;
  $("confirmYes").className="confirm"+(danger?" danger":"");
  $("confirmYes").textContent=yesLabel;
  $("confirmNo").textContent=noLabel;
  var d=$("confirm");
  if(d.showModal){if(!d.open)d.showModal();}else d.setAttribute("open","");
}
function closeConfirm(){var d=$("confirm");if(d.close)d.close();else d.removeAttribute("open");pendingConfirm=null;}

function askCancel(id){
  var o=state&&state.orders.filter(function(x){return x.id===id;})[0];
  if(!o)return;
  ask("Cancel the order for "+orderLabel(o)+"?","It leaves the queue and stops counting in totals. Any refund is done separately in Square.","Cancel order",true,"Keep order",function(){setStatus(id,"canceled",true);});
}

function askSupply(x){
  var n=x.name,lower=x.kind==="vessel"?n.toLowerCase():n,go=function(v){enqueue({type:"setSupply",kind:x.kind,item:x.id,soldOut:v});};
  if(supplyOut(x)){
    var back=x.kind==="topping"?"Customers will be able to add "+n+" on the kiosks right away.":"Customers will be able to choose "+lower+" on the kiosks right away.";
    if(x.kind==="vessel"&&noVessels())back+=" Kiosks showing Closed for lack of cups and cones take orders again.";
    ask("Mark "+n+" available again?",back,"Mark available",false,"Cancel",function(){go(false);});
    return;
  }
  var out=x.kind==="flavor"?"Customers won't be able to choose "+n+" on the kiosks. Scoops already in a cart stay."
    :x.kind==="vessel"?"Customers won't be able to choose "+lower+" on the kiosks. Items already in a cart stay."
    :"Customers won't be able to add "+n+" on the kiosks. Toppings already in a cart stay.";
  if(x.kind==="vessel"&&supplies().filter(function(v){return v.kind==="vessel"&&v.id!==x.id;}).every(supplyOut))out+=" With no cups or cones left, every kiosk shows Closed until one is back.";
  ask("Mark "+n+" sold out?",out,"Mark sold out",true,"Cancel",function(){go(true);});
}

document.addEventListener("click",function(e){
  var el=e.target.closest&&e.target.closest("button");
  if(!el)return;
  if(el.id==="confirmYes"){var go=pendingConfirm;closeConfirm();if(go)go();return;}
  if(el.id==="confirmNo"){closeConfirm();return;}
  if(el.id==="ksDone"){closeSheet();return;}
  if(el.id==="exitStaff"){askExit();return;}
  if(el.id==="sound"){
    if(soundState==="on"){soundState="off";store(MUTE_KEY,"1");renderSound();}
    else{store(MUTE_KEY,null);soundState="on";chime(true);renderSound();}
    return;
  }
  if(READONLY)return;
  if(assistClick(el))return;
  if(el.dataset.ack){enqueue({type:"ack",alertId:el.dataset.ack});}
  else if(el.dataset.ackids){el.dataset.ackids.split(",").forEach(function(id){if(id)enqueue({type:"ack",alertId:id});});}
  else if(el.dataset.supplyKey){
    var su=supplyByKey(el.dataset.supplyKey);
    if(su)askSupply(su);
  }
  else if(el.dataset.kiosk){openSheet(el.dataset.kiosk);}
  else if(el.dataset.allopen){askAllOpen(el.dataset.allopen==="1");}
  else if(el.dataset.kopen){var ko=kioskById(el.dataset.kopen);if(ko)askKioskOpen(ko,!kioskOpenNow(ko));}
  else if(el.dataset.kdebug){var kd=kioskById(el.dataset.kdebug);if(kd)enqueue({type:"setKioskDebug",kiosk:kd.id,debug:!kioskDebug(kd)});}
  else if(el.dataset.kremove){var kr=kioskById(el.dataset.kremove);if(kr)askRemove(kr);}
  else if(el.dataset.order&&el.dataset.to){setStatus(el.dataset.order,el.dataset.to,true);}
  else if(el.dataset.cancel){askCancel(el.dataset.cancel);}
});

document.addEventListener("submit",function(e){
  if(e.target&&e.target.id==="ksForm"){e.preventDefault();saveName();}
  if(e.target&&e.target.id==="asNameForm"){e.preventDefault();saveCustomerName();}
});
if($("assist"))$("assist").addEventListener("close",function(){if(assistKiosk)stopAssist();});
if($("kioskSheet"))$("kioskSheet").addEventListener("close",function(){sheetKiosk=null;});

var sessions={}, assistKiosk=null, assistOpenedAt=0, lastPresenceAt=0, cmdPending={}, assistNoteKey="";
var SCREEN_LABEL={attract:"the welcome screen",builder:"building the order",summary:"reviewing the order",name:"entering a name",confirmation:"the receipt",roleSetup:"the role picker",staff:"a staff page"};
var STEP_LABEL={vessel:"a cup or cone",flavors:"scoops",toppings:"toppings"};
var ASSIST_NAV=[["builder","Building the order"],["summary","Reviewing the order"],["name","Entering a name"]];

function dis(b){return b?" disabled":"";}
function setSessions(list){sessions={};(list||[]).forEach(function(x){sessions[x.kiosk]=x;});}
function assistable(k){return !!k&&k.online&&k.connected;}
function showDialog(d){if(d.showModal){if(!d.open)d.showModal();}else d.setAttribute("open","");}
function hideDialog(d){if(!d)return;if(d.close){if(d.open)d.close();}else d.removeAttribute("open");}
function pickerOpen(){var d=$("assistPick");return !!d&&d.open;}

function sessionArrived(kiosk,session){
  if(session)sessions[kiosk]=session;else delete sessions[kiosk];
  if(session)(session.results||[]).forEach(function(r){if(cmdPending[r.id])commandDone(r.id,r.status,r.message);});
  if(assistKiosk===kiosk)renderAssist(false);
  if(pickerOpen())renderPicker();
}

function sessionLine(k){
  var x=sessions[k.id];
  if(!assistable(k))return "Offline";
  if(!x)return "Online";
  if(x.paying)return "Payment in progress";
  var n=x.items.filter(function(i){return i.inOrder;}).length;
  return "On "+SCREEN_LABEL[x.screen]+(n?", "+plural(n,"item")+", "+money(x.totalCents):"");
}

function startAssist(){
  var list=kioskList();
  if(!list.length){showToast("No kiosk has connected yet.");return;}
  var online=list.filter(assistable);
  if(online.length===1)return askAssist(online[0]);
  renderPicker();
  showDialog($("assistPick"));
}

function renderPicker(){
  $("apList").innerHTML=kioskList().map(function(k){
    var ok=assistable(k);
    return '<button class="cell kcell" type="button" data-assistk="'+esc(k.id)+'"'+dis(!ok)+'><span class="kglyph'+(ok?"":" off")+'">'+ico("tablet")+'</span><div class="grow"><div class="label">'+esc(kioskName(k))+'</div><div class="sub">'+esc(sessionLine(k))+"</div></div>"+ico("chevron","chev")+"</button>";
  }).join("")||'<div class="empty">No kiosk has connected yet.</div>';
}

function askAssist(k){
  var name=kioskName(k);
  ask("Assist at "+name+"?","You'll see the order on "+name+" as it happens and can change it for the customer. The kiosk shows \"A staff member is helping you\" until you tap Done.","Start assisting",false,"Cancel",function(){hideDialog($("assistPick"));openAssist(k.id);});
}

function openAssist(id){
  assistKiosk=id;assistOpenedAt=Date.now();cmdPending={};assistNoteKey="";
  sendPresence();
  renderAssist(true);
  showDialog($("assist"));
  $("assist").scrollTop=0;
}

function stopAssist(){
  assistKiosk=null;cmdPending={};
  sendPresence();
  hideDialog($("assist"));
  var t=$("toast");if(t.parentNode!==document.body)document.body.appendChild(t);
}

function sendPresence(){
  if(!isLive())return;
  lastPresenceAt=Date.now();
  send({type:"assist",kiosk:assistKiosk,by:ACTOR});
}

function command(op,fields){
  if(!assistKiosk)return;
  var c={id:uuid(),kiosk:assistKiosk,op:op,by:ACTOR};
  Object.keys(fields||{}).forEach(function(k){c[k]=fields[k];});
  var p={cmd:c,firstAt:Date.now(),sentAt:0};
  cmdPending[c.id]=p;
  transmit(p);
  renderAssistLink();
}
function transmit(p){if(!isLive())return;p.sentAt=Date.now();send({type:"command",command:p.cmd});}
function commandDone(id,status,message){
  if(!cmdPending[id])return;
  delete cmdPending[id];
  if(status==="rejected")showToast(message||"The kiosk didn't make that change.");
  renderAssistLink();
}

function assistTick(){
  if(!assistKiosk)return;
  var t=Date.now();
  if(isLive()&&t-lastPresenceAt>=10000)sendPresence();
  Object.keys(cmdPending).forEach(function(id){
    var p=cmdPending[id];
    if(t-p.firstAt>15000){delete cmdPending[id];showToast("The kiosk didn't answer. Check it and try again.");}
    else if(isLive()&&t-p.sentAt>3000)transmit(p);
  });
  renderAssistLink();
  var v=asState(),n=asNotice(v,"");
  if((n?n[2]:"")!==assistNoteKey)renderAssist(false);
}

function asState(){
  var k=kioskById(assistKiosk),x=sessions[assistKiosk]||null,live=isLive(),connected=assistable(k);
  var ready=live&&connected&&!!x;
  var editable=ready&&!x.paying&&(x.screen==="builder"||x.screen==="summary"||x.screen==="name");
  return {k:k,s:x,live:live,connected:connected,ready:ready,editable:editable};
}

function asNotice(v,name){
  var x=v.s;
  if(!v.live)return ["bad","wifiOff","This iPad is offline","Assist needs a live connection. Showing the last known order; changes are off until it reconnects."];
  if(!v.k)return ["bad","alert","This kiosk was removed","It isn't in the kiosk list any more."];
  if(!v.connected)return ["bad","wifiOff",name+" is offline","Assist needs a live connection to the kiosk. Changes are off until it reconnects."];
  if(!x)return Date.now()-assistOpenedAt<8000?["wait","loader","Connecting to "+name,"Waiting for the kiosk to share its order."]:["warn","alert",name+" isn't sharing its order","Its app may need an update before it can be assisted."];
  if(x.paying)return ["warn","card","Payment in progress","The customer is paying on the kiosk. Changes are paused until they finish."];
  if(x.screen==="attract")return x.orderingOpen?["info","tablet",name+" is on its welcome screen","Start an order for the customer, or let them tap Begin Order."]:["warn","ban",name+" is closed","It isn't taking new orders."];
  if(x.screen==="confirmation")return ["info","circleCheck","Paid","The kiosk is showing the receipt."];
  if(x.screen==="roleSetup"||x.screen==="staff")return ["warn","alert",name+" isn't running as a kiosk","Nothing to assist with right now."];
  return null;
}

function renderAssistLink(){
  var el=$("asLink");if(!el||!assistKiosk)return;
  var v=asState(),busy=Object.keys(cmdPending).length>0;
  if(!v.live){el.className="live off";el.innerHTML='<span class="dot"></span>Offline';}
  else if(!v.connected){el.className="live off";el.innerHTML='<span class="dot"></span>Kiosk offline';}
  else if(busy){el.className="live";el.innerHTML=ico("loader","spin")+"Sending";}
  else{el.className="live";el.innerHTML='<span class="dot"></span>Live';}
}

function renderAssist(fresh){
  if(!assistKiosk||!$("assist"))return;
  var v=asState(),name=v.k?kioskName(v.k):"Kiosk";
  $("asTitle").textContent=name;
  renderAssistLink();
  var urgent=urgentOpen();
  $("asAlerts").innerHTML=urgent.slice(0,2).map(alertBar).join("");
  var n=asNotice(v,name);
  assistNoteKey=n?n[2]:"";
  var start=n&&v.ready&&v.s.screen==="attract"&&v.s.orderingOpen?'<button class="tinted" type="button" data-asnav="builder">'+ico("play")+"Start an order</button>":"";
  $("asNote").innerHTML=n?'<div class="as-note '+n[0]+'"><span class="aglyph">'+ico(n[1],n[0]==="wait"?"spin":"")+'</span><span><b>'+esc(n[2])+"</b>"+(n[3]?'<span class="sub">'+esc(n[3])+"</span>":"")+"</span>"+start+"</div>":"";
  $("asOrder").innerHTML=assistOrder(v);
  $("asSide").innerHTML=assistSide(v);
  assistName(v,fresh);
  var canStart=v.ready&&!v.s.paying&&["builder","summary","name","confirmation"].indexOf(v.s.screen)>=0;
  $("asEnd").innerHTML='<div class="section-head"></div><div class="group"><div class="cell"><button class="destructive" type="button" id="asStartOver"'+dis(!canStart)+">Start over</button></div></div><p class=\"footnote\">Clears the whole order and takes the kiosk back to its welcome screen.</p><p class=\"footnote\">While this is open the kiosk shows \"A staff member is helping you\". Payment always happens on the kiosk, on Square's own screen.</p>";
}

function assistOrder(v){
  var x=v.s;
  var head='<div class="section-head"><h2>Order</h2>'+(x&&x.items.length?'<span class="as-total">Total '+money(x.totalCents)+"</span>":"")+"</div>";
  if(!x||!x.items.length)return head+emptyGroup(x&&x.screen!=="attract"?"Nothing in the order yet.":"No order in progress.");
  var n=0;
  var html=x.items.map(function(it){return assistItem(it,it.inOrder?"Item "+(++n):"New item",v);}).join("");
  if(["builder","summary","name"].indexOf(x.screen)>=0)html+='<button class="as-add" type="button" id="asAdd"'+dis(!v.editable)+">"+ico("plus")+"Add another item</button>";
  return head+html;
}

function assistItem(it,label,v){
  var x=v.s,e=v.editable,max=x.maxScoops||3,full=it.flavors.length>=max,id=esc(it.id);
  var onScreen=x.screen==="builder"&&it.current;
  var tops=it.toppings||[];
  var desc=vesselName(it.vessel)+", "+(it.flavors.length?flavorText(it.flavors):"no scoops yet")+(tops.length?", "+joinAnd(tops.map(toppingName)):"");
  var removable=it.inOrder||it.flavors.length>0||tops.length>0;
  var h='<article class="group as-item'+(onScreen?" cur":"")+'"><div class="as-ihead"><div class="grow"><div class="as-iname">'+esc(label)+(onScreen?'<span class="as-on">On screen</span>':"")+'</div><div class="sub">'+esc(desc)+(it.inOrder?"":". It joins the order with its first scoop.")+"</div></div>"+(it.inOrder?'<span class="as-price">'+money(it.cents)+"</span>":"")+(removable?'<button class="as-trash" type="button" data-asremove="'+id+'" aria-label="Remove '+esc(label)+'"'+dis(!e)+">"+ico("trash")+"</button>":"")+"</div>";
  h+='<div class="as-seg" role="group" aria-label="Cup or cone for '+esc(label)+'">'+["cup","cone"].map(function(vs){
    var su=supplyByKey("vessel:"+vs),out=!!su&&supplyOut(su),sel=it.vessel===vs;
    return '<button type="button" class="'+(sel?"sel":"")+'" aria-pressed="'+sel+'" data-asvessel="'+vs+'" data-asitem="'+id+'"'+dis(!e||(!sel&&out))+">"+ico(vesselIcon(vs))+esc(vesselName(vs))+(out&&!sel?"<small>Sold out</small>":"")+"</button>";
  }).join("")+"</div>";
  h+='<div class="as-label"><span>Scoops</span><span>'+it.flavors.length+" of "+max+'</span></div><div class="list as-flavors">'+supplies().filter(function(f){return f.kind==="flavor";}).map(function(f){
    var c=it.flavors.filter(function(x){return x===f.id;}).length,out=supplyOut(f);
    return '<div class="cell"><div class="grow"><div class="label">'+esc(f.name)+"</div>"+(out?'<div class="soldout">Sold out</div>':"")+'</div><div class="as-step"><button type="button" data-asminus="'+esc(f.id)+'" data-asitem="'+id+'" aria-label="Remove a '+esc(f.name)+' scoop from '+esc(label)+'"'+dis(!e||!c)+">"+ico("minus")+'</button><span class="n">'+c+'</span><button type="button" class="plus" data-asplus="'+esc(f.id)+'" data-asitem="'+id+'" aria-label="Add a '+esc(f.name)+' scoop to '+esc(label)+'"'+dis(!e||full||out)+">"+ico("plus")+"</button></div></div>";
  }).join("")+"</div>";
  h+='<div class="as-label"><span>Toppings</span><span>'+(it.flavors.length?plural(tops.length,"topping"):"Add a scoop first")+'</span></div><div class="as-chips">'+supplies().filter(function(t){return t.kind==="topping";}).map(function(t){
    var on=tops.indexOf(t.id)>=0,out=supplyOut(t);
    return '<button type="button" class="as-chip'+(on?" on":"")+'" aria-pressed="'+on+'" data-astopping="'+esc(t.id)+'" data-asitem="'+id+'"'+dis(!e||(!on&&(out||!it.flavors.length)))+">"+(on?ico("check"):"")+esc(t.name)+(out&&!on?" <small>Sold out</small>":"")+"</button>";
  }).join("")+"</div>";
  return h+"</article>";
}

function assistSide(v){
  var x=v.s,here=x&&!x.paying?x.screen:null;
  var html='<div class="section-head"><h2>Kiosk screen</h2></div><div class="group list">'+ASSIST_NAV.map(function(r){
    var on=here===r[0];
    return '<button class="cell as-nav'+(on?" here":"")+'" type="button" data-asnav="'+r[0]+'" aria-pressed="'+on+'"'+dis(!v.editable||on)+'><span class="label">'+r[1]+"</span>"+(on?ico("check"):"")+"</button>";
  }).join("")+"</div>";
  var now="";
  if(x&&x.paying)now="The customer is paying on Square's screen.";
  else if(x&&x.screen==="builder"&&x.step)now="The customer is choosing "+STEP_LABEL[x.step]+(x.editing?" for an item they're changing.":".");
  else if(x)now="The kiosk is on "+SCREEN_LABEL[x.screen]+".";
  return html+(now?'<p class="footnote">'+esc(now)+"</p>":"");
}

function assistName(v,fresh){
  var wrap=$("asNameWrap"),input=$("asName");
  if(fresh||!input){
    wrap.innerHTML='<div class="section-head"><h2>Name for pickup</h2></div><div class="group"><form class="cell" id="asNameForm"><input id="asName" class="field" maxlength="24" autocomplete="off" autocapitalize="words" spellcheck="false" enterkeyhint="done" aria-label="Name for pickup" placeholder="Customer\'s name"><button class="link" type="submit" id="asNameSave">Save</button></form></div><p class="footnote">Called out when the order is ready.</p>';
    input=$("asName");
  }
  var ok=v.editable;
  if(document.activeElement!==input)input.value=v.s?v.s.customerName:"";
  input.disabled=!ok;$("asNameSave").disabled=!ok;
}

function saveCustomerName(){
  var input=$("asName");if(!input)return;
  var name=cleanName(input.value).slice(0,24);
  input.blur();
  var x=sessions[assistKiosk];
  if(x&&name===x.customerName)return;
  command("setName",{name:name});
}

function assistItemByID(id){var x=sessions[assistKiosk];return x?x.items.filter(function(i){return i.id===id;})[0]||null:null;}

function askRemoveItem(id){
  var x=sessions[assistKiosk],it=assistItemByID(id);if(!x||!it)return;
  var n=0,label="the new item";
  x.items.forEach(function(i){if(i.inOrder)n++;if(i.id===id&&i.inOrder)label="item "+n;});
  var name=kioskName(kioskById(assistKiosk)||{id:assistKiosk,tag:""});
  ask("Remove "+label+"?",(it.inOrder?"It comes out of the order on "+name+".":"The item being built on "+name+" is cleared.")+" The customer sees it go.","Remove",true,"Cancel",function(){command("removeItem",{item:id});});
}

function askStartOver(){
  var k=kioskById(assistKiosk),name=k?kioskName(k):"this kiosk";
  ask("Start over at "+name+"?","This clears the customer's whole order and takes the kiosk back to its welcome screen.","Start over",true,"Cancel",function(){command("startOver",{});});
}

function assistClick(el){
  var d=el.dataset;
  if(el.id==="assistOpen"){startAssist();return true;}
  if(el.id==="apDone"){hideDialog($("assistPick"));return true;}
  if(el.id==="asDone"){stopAssist();return true;}
  if(d.assistk){var ka=kioskById(d.assistk);if(ka)askAssist(ka);return true;}
  if(d.kassist){var kb=kioskById(d.kassist);if(kb){closeSheet();askAssist(kb);}return true;}
  if(!assistKiosk)return false;
  if(d.asplus){command("addScoop",{item:d.asitem,flavor:d.asplus});return true;}
  if(d.asminus){command("removeScoop",{item:d.asitem,flavor:d.asminus});return true;}
  if(d.asvessel){if(el.getAttribute("aria-pressed")!=="true")command("setVessel",{item:d.asitem,vessel:d.asvessel});return true;}
  if(d.astopping){command("setTopping",{item:d.asitem,topping:d.astopping,on:el.getAttribute("aria-pressed")!=="true"});return true;}
  if(d.asremove){askRemoveItem(d.asremove);return true;}
  if(d.asnav){command("navigate",{to:d.asnav});return true;}
  if(el.id==="asAdd"){command("addItem",{});return true;}
  if(el.id==="asStartOver"){askStartOver();return true;}
  return false;
}

function renewSession(){
  fetch("/dashboard/renew",{method:"POST",credentials:"same-origin",cache:"no-store"}).then(function(r){if(r.status===401)location.reload();}).catch(function(){});
}
setInterval(renewSession,30*60000);

restoreOutbox();
render();
connect();
loadStats();
flush();
renewSession();
`;

export function dashboardScript(): string {
  return SCRIPT.replace("__ICONS__", () => JSON.stringify(ICONS)).replace("__TOPPINGS__", () => JSON.stringify(TOPPING_TITLES));
}
