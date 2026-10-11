import { escapeHtml } from "./http";
import { STAFF_ROLES, type StaffRole, type StaffSection } from "./staff-roles";

const STYLE = `
:root{color-scheme:light dark;
--bg:#f5f2ec;--panel:#fff;--panel2:#f0ebe2;--line:#e2dacb;--text:#1f1b16;--dim:#675f54;
--accent:#a8235a;--accent-soft:#fbe4ee;--ok:#17703f;--ok-soft:#dcf2e4;--warn:#7d5300;--warn-soft:#fbefcf;--bad:#b42318;--bad-soft:#fde3df;
--primary:#1f1b16;--on-primary:#fff;--shadow:0 1px 2px rgba(40,30,20,.06),0 2px 8px rgba(40,30,20,.05)}
@media(prefers-color-scheme:dark){:root{
--bg:#131519;--panel:#1c1f26;--panel2:#262a33;--line:#323745;--text:#f3efe6;--dim:#a9afbd;
--accent:#f4a6c3;--accent-soft:#3b2530;--ok:#7fd6a2;--ok-soft:#1d3327;--warn:#f2c46b;--warn-soft:#3a3020;--bad:#ff8f84;--bad-soft:#40211f;
--primary:#f3efe6;--on-primary:#16181d;--shadow:none}}
*{box-sizing:border-box}
html{font-size:18px;-webkit-text-size-adjust:100%;touch-action:manipulation}
@media(max-width:480px){html{font-size:17px}}
body{margin:0;background:var(--bg);color:var(--text);font-family:system-ui,-apple-system,"SF Pro Text","Segoe UI",Roboto,sans-serif;line-height:1.35;overscroll-behavior:none;-webkit-tap-highlight-color:transparent;
padding:env(safe-area-inset-top) env(safe-area-inset-right) env(safe-area-inset-bottom) env(safe-area-inset-left)}
svg.i{width:1.2em;height:1.2em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;flex:none}
button{font:inherit;color:inherit;cursor:pointer;-webkit-user-select:none;user-select:none}
button:disabled{cursor:default}
:focus-visible{outline:3px solid var(--accent);outline-offset:2px}
[hidden]{display:none!important}
.btn{display:inline-flex;align-items:center;justify-content:center;gap:.5rem;min-height:3.1rem;padding:.6rem 1.15rem;border-radius:.9rem;border:2px solid transparent;font-weight:700;font-size:1.05rem;line-height:1.1;white-space:nowrap}
.btn.primary{background:var(--primary);color:var(--on-primary)}
.btn.go{background:var(--ok);color:#fff}
.btn.urgent{background:var(--bad);color:#fff;min-height:3.6rem;font-size:1.15rem;padding:.7rem 1.5rem}
.btn.quiet{background:var(--panel);border-color:var(--line);color:var(--text)}
.btn.danger{background:var(--panel);border-color:var(--line);color:var(--bad)}
.btn.big{min-height:3.6rem;font-size:1.15rem}
.btn:active:not(:disabled){transform:scale(.97)}
@media(prefers-color-scheme:dark){.btn.go{color:#10251a}.btn.urgent{color:#2a0f0c}}
.login{min-height:100vh;display:grid;place-items:center;padding:1.5rem}
.login form{background:var(--panel);border:1px solid var(--line);border-radius:1.4rem;padding:2rem;width:min(28rem,100%);display:grid;gap:1.1rem;box-shadow:var(--shadow)}
.login h1{margin:0;font-size:1.7rem;display:flex;gap:.6rem;align-items:center}
.login label{color:var(--dim);font-weight:600}
.login input{font:inherit;font-size:2rem;letter-spacing:.3em;text-align:center;min-height:4rem;padding:.6rem 1rem;border-radius:1rem;border:2px solid var(--line);background:var(--bg);color:var(--text);width:100%}
.login input:focus{border-color:var(--accent);outline:none}
.login .err{color:var(--bad);margin:0;font-weight:600;display:flex;gap:.5rem;align-items:center}
.sticky{position:sticky;top:0;z-index:5}
.top{background:var(--bg);display:flex;flex-wrap:wrap;align-items:center;gap:.6rem 1rem;padding:.75rem 1.25rem;border-bottom:1px solid var(--line)}
.top h1{margin:0;font-size:1.35rem;display:flex;gap:.55rem;align-items:center;flex:1 1 auto;min-width:9rem}
.status{display:flex;gap:.5rem;flex-wrap:wrap;align-items:center}
.pill{display:inline-flex;gap:.45rem;align-items:center;min-height:2.75rem;padding:.4rem .95rem;border-radius:99rem;background:var(--panel);border:1px solid var(--line);font-size:.95rem;font-weight:600;white-space:nowrap}
.pill.ok{color:var(--ok);background:var(--ok-soft);border-color:transparent}
.pill.warn{color:var(--warn);background:var(--warn-soft);border-color:transparent}
.pill.bad{color:var(--bad);background:var(--bad-soft);border-color:transparent}
.pill.muted{color:var(--dim)}
button.pill.attn{background:var(--accent);color:#fff;border-color:transparent}
@media(prefers-color-scheme:dark){button.pill.attn{color:#2a1620}}
.dot{width:.65rem;height:.65rem;border-radius:50%;background:currentColor;flex:none}
.pill.ok .dot{animation:breathe 2.4s ease-in-out infinite}
@keyframes breathe{50%{opacity:.35}}
.banner{display:flex;gap:.7rem;align-items:center;padding:.8rem 1.25rem;font-weight:600;border-bottom:1px solid var(--line)}
.banner.bad{background:var(--bad-soft);color:var(--bad)}
.banner.warn{background:var(--warn-soft);color:var(--warn)}
.banner .sub{font-weight:400;color:var(--text);opacity:.85}
.wrap{padding:1rem 1.25rem 3rem;max-width:120rem;margin:0 auto;display:grid;gap:1rem}
.alerts{display:grid;gap:.75rem}
.alert{display:flex;flex-wrap:wrap;gap:.75rem 1rem;align-items:center;padding:1rem 1.1rem;border-radius:1.1rem;background:var(--panel);border:1px solid var(--line);border-left:.5rem solid var(--warn);box-shadow:var(--shadow)}
.alert .ic{display:grid;place-items:center;width:2.8rem;height:2.8rem;border-radius:50%;background:var(--warn-soft);color:var(--warn);font-size:1.15rem;flex:none}
.alert .body{flex:1 1 14rem;min-width:0}
.alert .title{font-weight:800;font-size:1.2rem}
.alert .detail{color:var(--dim);margin-top:.15rem}
.alert .when{font-weight:600;font-size:.95rem;color:var(--dim);margin-left:.5rem;white-space:nowrap}
.alert.urgent{background:var(--bad-soft);border-color:var(--bad);border-width:2px 2px 2px .6rem;padding:1.2rem 1.25rem}
.alert.urgent .ic{background:var(--bad);color:#fff;width:3.4rem;height:3.4rem;font-size:1.5rem}
@media(prefers-color-scheme:dark){.alert.urgent .ic{color:#2a0f0c}}
.alert.urgent .title{font-size:1.5rem;color:var(--bad)}
.alert.urgent .detail{color:var(--text)}
.alert.info{border-left-color:var(--accent);padding:.7rem 1rem}
.alert.info .ic{background:var(--accent-soft);color:var(--accent);width:2.4rem;height:2.4rem}
.alert.info .title{font-size:1.05rem}
@media(prefers-reduced-motion:no-preference){.alert.urgent .ic{animation:ring 1.6s ease-in-out infinite}}
@keyframes ring{0%,100%{box-shadow:0 0 0 0 rgba(180,35,24,.45)}60%{box-shadow:0 0 0 .7rem rgba(180,35,24,0)}}
.updates{background:var(--panel);border:1px solid var(--line);border-left:.5rem solid var(--accent);border-radius:1.1rem;padding:.4rem 1rem .5rem;box-shadow:var(--shadow)}
.uhead{display:flex;align-items:center;justify-content:space-between;gap:1rem;font-weight:700;color:var(--dim);min-height:3rem}
.uhead span{display:inline-flex;gap:.45rem;align-items:center}
.urow{display:flex;align-items:center;gap:.75rem;padding:.35rem 0;border-top:1px solid var(--line);color:var(--accent)}
.urow .ut{flex:1;color:var(--text);min-width:0}
.urow .when{color:var(--dim);font-size:.9rem;margin-left:.3rem;white-space:nowrap}
.urow .btn,.uhead .btn{min-height:2.75rem;padding:.4rem .9rem;font-size:.95rem}
.urow.more-n{color:var(--dim);justify-content:center;min-height:2.5rem}
.updates.more{border-left-color:var(--bad)}.updates.more .urow{color:var(--bad)}
.grid{display:grid;gap:1rem;grid-template-columns:minmax(0,1fr);align-items:start}
.col{display:grid;gap:1rem;min-width:0}
@media(min-width:700px){.grid.cols-2,.grid.cols-3{grid-template-columns:minmax(0,3fr) minmax(0,2fr)}.grid.cols-3>.col:first-child{grid-column:1/-1}}
@media(min-width:1180px){.grid.cols-3{grid-template-columns:minmax(0,1fr) minmax(0,1.25fr) minmax(0,1fr)}.grid.cols-3>.col:first-child{grid-column:auto}}
.picker{max-width:44rem}
.picker h2{margin:.5rem 0 0;font-size:1.4rem}
.roles{display:grid;gap:.9rem}
.role{display:flex;align-items:center;gap:1.1rem;padding:1.2rem 1.3rem;min-height:5.5rem;border-radius:1.2rem;background:var(--panel);border:1px solid var(--line);box-shadow:var(--shadow);color:var(--text);text-decoration:none}
.role:active{transform:scale(.99)}
.role>span:nth-child(2){flex:1;display:grid;gap:.2rem}
.role b{font-size:1.3rem}
.role span span{color:var(--dim)}
.role .ric{display:grid;place-items:center;width:3.2rem;height:3.2rem;border-radius:1rem;background:var(--accent-soft);color:var(--accent);font-size:1.3rem;flex:none}
a.pill{color:var(--dim);text-decoration:none}
.err{color:var(--bad);font-weight:600;display:flex;gap:.5rem;align-items:center}
.frow{display:grid;grid-template-columns:auto minmax(0,1fr) auto;gap:.15rem .9rem;padding:.7rem 0;border-top:1px solid var(--line);align-items:baseline}
.frow:first-child{border-top:0}
.frow .num{font-size:1.25rem;font-weight:800;font-variant-numeric:tabular-nums;min-width:2.8rem}
.frow .who{font-weight:700;font-size:1.1rem;display:flex;gap:.5rem;align-items:center;flex-wrap:wrap}
.frow .total{font-weight:800;font-variant-numeric:tabular-nums;text-align:right}
.frow .items{grid-column:2;color:var(--dim)}
.frow .when{grid-column:3;color:var(--dim);font-size:.9rem;text-align:right;white-space:nowrap}
.frow.sim{opacity:.6}
.card{background:var(--panel);border:1px solid var(--line);border-radius:1.2rem;padding:1rem 1.1rem;box-shadow:var(--shadow);min-width:0}
.card h2{margin:0 0 .75rem;font-size:.95rem;color:var(--dim);font-weight:700;letter-spacing:.05em;text-transform:uppercase;display:flex;gap:.5rem;align-items:center}
.card h2 .count{margin-left:auto;background:var(--panel2);color:var(--text);border-radius:99rem;padding:.1rem .7rem;font-size:.95rem;letter-spacing:0}
.empty{color:var(--dim);padding:.5rem 0 .3rem}
.orders{display:grid;gap:.75rem}
.order{border:1px solid var(--line);border-radius:1rem;padding:.85rem .95rem;display:grid;gap:.6rem;background:var(--panel);border-left:.45rem solid var(--warn)}
.order.s-preparing{border-left-color:var(--accent)}
.order.s-ready{border-left-color:var(--ok);background:var(--ok-soft)}
.order .head{display:flex;align-items:baseline;gap:.7rem;flex-wrap:wrap}
.order .num{font-size:1.9rem;font-weight:800;font-variant-numeric:tabular-nums;line-height:1}
.order .who{font-size:1.35rem;font-weight:700;flex:1 1 auto;min-width:0;overflow-wrap:anywhere}
.order .age{color:var(--dim);font-variant-numeric:tabular-nums;white-space:nowrap}
.order ul{margin:0;padding:0;list-style:none;display:grid;gap:.3rem}
.order li{font-size:1.1rem;padding:.4rem .6rem;border-radius:.6rem;background:var(--panel2)}
.order li .v{font-weight:700}
.order li .t{display:inline-block;color:var(--accent);font-weight:700}
.order li .nt{color:var(--dim)}
.order .acts{display:flex;gap:.6rem;align-items:center;flex-wrap:wrap}
.order .acts .grow{flex:1}
.chip{display:inline-flex;align-items:center;gap:.35rem;font-size:.85rem;font-weight:800;text-transform:uppercase;letter-spacing:.05em;padding:.3rem .7rem;border-radius:99rem;background:var(--warn-soft);color:var(--warn)}
.chip.preparing{background:var(--accent-soft);color:var(--accent)}
.chip.ready{background:var(--ok);color:#fff}
@media(prefers-color-scheme:dark){.chip.ready{color:#10251a}}
.chip.collected{background:var(--panel2);color:var(--dim)}.chip.canceled{background:var(--bad-soft);color:var(--bad)}
.pending{display:inline-flex;align-items:center;gap:.35rem;font-size:.85rem;color:var(--dim);font-weight:600}
.sub-h{font-size:.9rem;font-weight:700;color:var(--dim);margin:.4rem 0 .5rem;display:flex;gap:.4rem;align-items:center}
details.done{margin-top:.9rem;border-top:1px solid var(--line);padding-top:.5rem}
details.done summary{min-height:2.9rem;display:flex;align-items:center;gap:.5rem;font-weight:700;color:var(--dim);cursor:pointer;list-style:none}
details.done summary::-webkit-details-marker{display:none}
.drow{display:flex;align-items:center;gap:.7rem;padding:.45rem 0;border-top:1px solid var(--line);flex-wrap:wrap}
.drow .num{font-weight:800;font-variant-numeric:tabular-nums;min-width:2.6rem}
.drow .who{flex:1;min-width:6rem}
.flavors{display:grid;grid-template-columns:repeat(auto-fill,minmax(8rem,1fr));gap:.6rem}
.flavor{display:flex;flex-direction:column;align-items:flex-start;justify-content:center;gap:.2rem;min-height:4.4rem;padding:.65rem .9rem;border-radius:1rem;background:var(--panel2);border:2px solid transparent;text-align:left}
.flavor .name{font-size:1.15rem;font-weight:700}
.flavor .state{font-size:.85rem;font-weight:700;color:var(--ok);display:inline-flex;gap:.3rem;align-items:center}
.flavor.out{background:var(--bad-soft);border-color:var(--bad)}
.flavor.out .state{color:var(--bad)}
.flavor .pending{font-size:.8rem}
.health{display:grid;gap:0}
.health div{display:flex;justify-content:space-between;gap:1rem;padding:.5rem 0;border-top:1px solid var(--line)}
.health div:first-child{border-top:0}
.health span:first-child{color:var(--dim)}
.health span:last-child{text-align:right;font-weight:600;overflow-wrap:anywhere}
.ok-t{color:var(--ok)}.warn-t{color:var(--warn)}.bad-t{color:var(--bad)}
.tiles{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:.75rem}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:1.1rem;padding:.85rem 1rem;box-shadow:var(--shadow)}
.tile .label{color:var(--dim);font-size:.9rem;display:flex;gap:.4rem;align-items:center;font-weight:600}
.tile .value{font-size:2.3rem;font-weight:800;line-height:1.1;font-variant-numeric:tabular-nums;margin-top:.15rem}
.tile .sub{color:var(--dim);font-size:.85rem;font-variant-numeric:tabular-nums}
.bar{display:grid;grid-template-columns:7rem 1fr 2.4rem;gap:.6rem;align-items:center;margin:.4rem 0}
.bar .name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar .track{height:.85rem;background:var(--panel2);border-radius:99rem;overflow:hidden}
.bar .fill{display:block;height:100%;background:var(--accent);border-radius:99rem;min-width:.25rem}
.bar .n{text-align:right;font-variant-numeric:tabular-nums;font-weight:700}
.hours .fill{background:var(--warn)}
.foot{color:var(--dim);font-size:.9rem;display:flex;gap:1rem;flex-wrap:wrap;align-items:center}
.foot a{color:var(--dim);min-height:2.75rem;display:inline-flex;align-items:center}
.toast{position:fixed;left:50%;bottom:calc(1.2rem + env(safe-area-inset-bottom));transform:translateX(-50%);z-index:20;display:flex;gap:1rem;align-items:center;background:var(--primary);color:var(--on-primary);padding:.55rem .6rem .55rem 1.2rem;border-radius:1rem;box-shadow:0 8px 30px rgba(0,0,0,.25);font-weight:600;max-width:calc(100vw - 2rem)}
.toast .btn{min-height:2.9rem;background:transparent;color:var(--on-primary);border-color:currentColor}
.toast.plain{padding:.9rem 1.2rem}
dialog{border:0;border-radius:1.3rem;padding:1.5rem;width:min(30rem,calc(100vw - 2rem));background:var(--panel);color:var(--text);box-shadow:0 20px 60px rgba(0,0,0,.35)}
dialog::backdrop{background:rgba(20,15,10,.45)}
dialog h3{margin:0 0 .5rem;font-size:1.4rem}
dialog p{margin:0 0 1.3rem;color:var(--dim)}
dialog .row{display:flex;gap:.75rem;justify-content:flex-end;flex-wrap:wrap}
dialog .row .btn{flex:1 1 10rem}
body.app .web-only{display:none!important}
@media(max-width:560px){.top{padding:.6rem .9rem}.top h1{display:none}.status{flex:1}.status form{margin-left:auto}.pill{padding:.35rem .75rem;font-size:.9rem}.alert.info .btn{flex:0 0 auto}.wrap{padding:.8rem .9rem 3rem}.top h1 .lbl,.status .lbl{display:none}.order .num{font-size:1.6rem}.alert.urgent .title{font-size:1.3rem}.alert .btn{flex:1 1 100%}.alert .body{flex-basis:9rem}.alert.urgent .ic{width:2.8rem;height:2.8rem;font-size:1.2rem}.alert.urgent{padding:1rem}.alert .when{display:block;margin:0}}
`;

const ICONS: Record<string, string> = {
  cone: '<path d="m7 11 4.08 10.35a1 1 0 0 0 1.84 0L17 11"/><path d="M17 7A5 5 0 0 0 7 7"/><path d="M17 7a2 2 0 0 1 0 4H7a2 2 0 0 1 0-4"/>',
  bell: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/>',
  bellRing: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M22 8c0-2.3-.8-4.3-2-6"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/><path d="M4 2C2.8 3.7 2 5.7 2 8"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
  checkCheck: '<path d="M18 6 7 17l-5-5"/><path d="m22 10-7.5 7.5L13 16"/>',
  wifi: '<path d="M12 20h.01"/><path d="M2 8.82a15 15 0 0 1 20 0"/><path d="M5 12.859a10 10 0 0 1 14 0"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/>',
  wifiOff: '<path d="M12 20h.01"/><path d="M8.5 16.429a5 5 0 0 1 7 0"/><path d="M5 12.859a10 10 0 0 1 5.17-2.69"/><path d="M19 12.859a10 10 0 0 0-2.007-1.523"/><path d="M2 8.82a15 15 0 0 1 4.177-2.643"/><path d="M22 8.82a15 15 0 0 0-11.288-3.764"/><path d="m2 2 20 20"/>',
  tablet: '<rect width="16" height="20" x="4" y="2" rx="2" ry="2"/><line x1="12" x2="12.01" y1="18" y2="18"/>',
  dollar: '<line x1="12" x2="12" y1="2" y2="22"/><path d="M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6"/>',
  clock: '<circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/>',
  logOut: '<path d="m16 17 5-5-5-5"/><path d="M21 12H9"/><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/>',
  alert: '<path d="m21.73 18-8-14a2 2 0 0 0-3.48 0l-8 14A2 2 0 0 0 4 21h16a2 2 0 0 0 1.73-3"/><path d="M12 9v4"/><path d="M12 17h.01"/>',
  ban: '<circle cx="12" cy="12" r="10"/><path d="m4.9 4.9 14.2 14.2"/>',
  chart: '<path d="M3 3v16a2 2 0 0 0 2 2h16"/><path d="M18 17V9"/><path d="M13 17V5"/><path d="M8 17v-3"/>',
  receipt: '<path d="M4 2v20l2-1 2 1 2-1 2 1 2-1 2 1 2-1 2 1V2l-2 1-2-1-2 1-2-1-2 1-2-1-2 1Z"/><path d="M16 8h-6a2 2 0 1 0 0 4h4a2 2 0 1 1 0 4H8"/><path d="M12 17.5v-11"/>',
  sparkles: '<path d="M9.937 15.5A2 2 0 0 0 8.5 14.063l-6.135-1.582a.5.5 0 0 1 0-.962L8.5 9.936A2 2 0 0 0 9.937 8.5l1.582-6.135a.5.5 0 0 1 .963 0L14.063 8.5A2 2 0 0 0 15.5 9.937l6.135 1.581a.5.5 0 0 1 0 .964L15.5 14.063a2 2 0 0 0-1.437 1.437l-1.582 6.135a.5.5 0 0 1-.963 0z"/>',
  help: '<circle cx="12" cy="12" r="10"/><path d="M9.09 9a3 3 0 0 1 5.83 1c0 2-3 3-3 3"/><path d="M12 17h.01"/>',
  lock: '<rect width="18" height="11" x="3" y="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
  volume: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><path d="M16 9a5 5 0 0 1 0 6"/><path d="M19.364 18.364a9 9 0 0 0 0-12.728"/>',
  volumeX: '<path d="M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z"/><line x1="22" x2="16" y1="9" y2="15"/><line x1="16" x2="22" y1="9" y2="15"/>',
  play: '<polygon points="6 3 20 12 6 21 6 3"/>',
  x: '<path d="M18 6 6 18"/><path d="m6 6 12 12"/>',
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 5.5 5.5a5.5 5.5 0 0 1-5.5 5.5H11"/>',
  loader: '<path d="M21 12a9 9 0 1 1-6.219-8.56"/>',
  list: '<path d="M3 12h.01"/><path d="M3 18h.01"/><path d="M3 6h.01"/><path d="M8 12h13"/><path d="M8 18h13"/><path d="M8 6h13"/>',
  chevron: '<path d="m9 18 6-6-6-6"/>',
  layout: '<rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/>',
};

export function icon(name: string): string {
  return `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

export function shell(title: string, body: string, nonce: string, script = ""): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="robots" content="noindex"><meta name="apple-mobile-web-app-capable" content="yes"><meta name="mobile-web-app-capable" content="yes"><meta name="format-detection" content="telephone=no">
<meta name="theme-color" content="#f5f2ec" media="(prefers-color-scheme: light)"><meta name="theme-color" content="#131519" media="(prefers-color-scheme: dark)">
<title>${escapeHtml(title)}</title><style nonce="${nonce}">${STYLE}</style></head><body>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ""}</body></html>`;
}

export function loginBody(message: string | null, next = "/staff"): string {
  const error = message ? `<p class="err" role="alert">${icon("alert")} ${escapeHtml(message)}</p>` : "";
  return `<div class="login"><form method="post" action="/dashboard/login"><h1>${icon("cone")} Booth staff</h1>${error}<input type="hidden" name="next" value="${escapeHtml(next)}"><label for="pin">Staff PIN</label><input id="pin" name="pin" type="password" inputmode="numeric" autocomplete="current-password" required autofocus><button class="btn primary big">${icon("lock")} Sign in</button></form></div>`;
}

function signOut(): string {
  return `<form method="post" action="/dashboard/logout" class="web-only"><button class="pill muted" aria-label="Sign out">${icon("logOut")}<span class="lbl">Sign out</span></button></form>`;
}

export function pickerBody(message: string | null = null): string {
  const cards = Object.entries(STAFF_ROLES).map(([id, role]: [string, StaffRole]) =>
    `<a class="role" href="/staff/${id}"><span class="ric">${icon(role.icon)}</span><span><b>${escapeHtml(role.title)}</b><span>${escapeHtml(role.summary)}</span></span>${icon("chevron")}</a>`).join("");
  const error = message ? `<p class="err" role="alert">${icon("alert")} ${escapeHtml(message)}</p>` : "";
  return `<div class="sticky"><header class="top"><h1>${icon("cone")}<span>Booth staff</span></h1><div class="status">${signOut()}</div></header></div>
<div class="wrap picker"><h2>Which page do you need?</h2>${error}<nav class="roles">${cards}</nav></div>`;
}

const SECTIONS: Record<StaffSection, () => string> = {
  queue: () => `<section class="card"><h2>${icon("receipt")} Orders <span class="count" id="openCount">0</span></h2><div id="orders"></div><details class="done" id="doneWrap"><summary>${icon("chevron")} <span id="doneTitle">Finished</span></summary><div id="done"></div></details></section>`,
  feed: () => `<section class="card"><h2>${icon("list")} All orders <span class="count" id="feedCount">0</span></h2><div id="feed"></div></section>`,
  soldout: () => `<section class="card"><h2>${icon("ban")} Sold out</h2><div class="flavors" id="soldout"></div></section>`,
  kiosk: () => `<section class="card"><h2>${icon("tablet")} Kiosk</h2><div class="health" id="health"></div></section>`,
  stats: () => `<div class="tiles">
<div class="tile"><div class="label">${icon("receipt")} Orders</div><div class="value" id="tOrders">0</div><div class="sub" id="tOrdersSub"></div></div>
<div class="tile"><div class="label">${icon("dollar")} Revenue</div><div class="value" id="tRevenue">$0</div><div class="sub" id="tAvg"></div></div>
<div class="tile"><div class="label">${icon("cone")} Scoops</div><div class="value" id="tScoops">0</div><div class="sub" id="tVessels"></div></div>
<div class="tile"><div class="label">${icon("clock")} Last 15 min</div><div class="value" id="tRecent">0</div><div class="sub" id="tRecentSub"></div></div>
</div>
<section class="card"><h2>${icon("cone")} Scoops by flavor</h2><div id="flavorBars"></div></section>
<section class="card"><h2>${icon("sparkles")} Toppings</h2><div id="toppingBars"></div></section>
<section class="card"><h2>${icon("chart")} Orders per hour</h2><div class="hours" id="hourBars"></div></section>
<div class="foot"><span id="updated"></span><a href="/v1/square/oauth/start" class="web-only">Connect Square</a></div>`,
};

export function dashboardBody(roleId: string, role: StaffRole): string {
  const columns = role.columns.map((sections) => `<div class="col">${sections.map((s) => SECTIONS[s]()).join("")}</div>`).join("");
  return `<div class="sticky"><header class="top"><h1>${icon(role.icon)}<span class="lbl">${escapeHtml(role.title)}</span></h1>
<div class="status"><span class="pill" id="link" role="status"></span><span class="pill" id="kioskPill"></span>
<button class="pill" id="sound" type="button" hidden></button>
<a class="pill muted web-only" href="/staff" aria-label="Switch page">${icon("layout")}<span class="lbl">Pages</span></a>${signOut()}</div></header>
<div id="banner" class="banner" hidden role="status"></div></div>
<div class="wrap" data-role="${escapeHtml(roleId)}">
${role.alerts ? `<section class="alerts" id="alerts" aria-live="assertive"></section>` : ""}
<main class="grid cols-${role.columns.length}">${columns}</main></div>
<div id="toast" class="toast" hidden role="status"></div>
<dialog id="confirm"><h3 id="confirmTitle"></h3><p id="confirmText"></p><div class="row"><button class="btn quiet big" id="confirmNo" type="button">Keep order</button><button class="btn urgent" id="confirmYes" type="button">${icon("x")} Cancel order</button></div></dialog>`;
}

const SCRIPT = String.raw`
"use strict";
var ICONS = __ICONS__;
var BASE_TITLE = document.title;
var IN_APP = /BoothStaffApp\//.test(navigator.userAgent);
var ACTOR = IN_APP ? "Counter iPad" : "Dashboard";
var OUTBOX_KEY = "booth.outbox.v1", DEVICE_KEY = "booth.device", MUTE_KEY = "booth.muted";
var MAX_QUEUE_AGE = 60 * 60000, SETTLE_GRACE = 5000;
var NEXT = { paid: "preparing", preparing: "ready", ready: "collected" };
var STATUS_LABEL = { paid: "New", preparing: "Making", ready: "Ready", collected: "Collected", canceled: "Canceled" };

function ico(n){return '<svg class="i" viewBox="0 0 24 24" aria-hidden="true">'+ICONS[n]+'</svg>';}
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
var toastTimer=null, confirmOrder=null;

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
function agoSpan(ms){return '<span data-ago="'+(ms==null?"":ms)+'">'+ago(ms)+"</span>";}

function keyOf(a){
  return a.type==="ack"?"ack:"+a.alertId:a.type==="setSoldOut"?"flavor:"+a.flavor:"order:"+a.orderId;
}
function valueOf(a){return a.type==="ack"?true:a.type==="setSoldOut"?a.soldOut:a.status;}

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
  outbox=outbox.filter(function(e){return e.inFlight||keyOf(e.action)!==key;});
  delete settled[key];
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
    var s=settled[key],actual;
    if(key.indexOf("flavor:")===0){var f=state.flavors.filter(function(x){return "flavor:"+x.id===key;})[0];actual=f?f.soldOut:undefined;}
    else if(key.indexOf("order:")===0){var o=state.orders.filter(function(x){return "order:"+x.id===key;})[0];actual=o?o.status:undefined;}
    else{var a=state.alerts.filter(function(x){return "ack:"+x.id===key;})[0];actual=!a||a.ackedAt!=null||a.resolvedAt!=null;}
    if(actual===s.value||(live&&t-s.at>SETTLE_GRACE)){delete settled[key];changed=true;}
  });
  return changed;
}

function flavorOut(f){var i=intended("flavor:"+f.id);return i?i.value:f.soldOut;}
function orderStatus(o){var i=intended("order:"+o.id);return i?i.value:o.status;}
function alertAcked(a){return !!intended("ack:"+a.id);}

function applyPatch(msg){
  if(!state)return send({type:"sync"});
  if(msg.rev<=state.rev)return;
  if(msg.rev!==state.rev+1)return send({type:"sync"});
  var c=msg.change;
  if(c.kind==="flavors")state.flavors=c.flavors;
  else if(c.kind==="kiosk")state.kiosk=c.kiosk;
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
    if(state.serverTime)serverOffset=state.serverTime-Date.now();
    everLive=true;offlineSince=null;
    reconcile();render();scheduleStats(0);flush();
  }
  else if(msg.type==="patch")applyPatch(msg);
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

var audio=null, audioURL=null, soundState=IN_APP?"on":"locked", heard={}, lastChimeAt=0;
if(load(MUTE_KEY)==="1")soundState="off";

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
  if(soundState==="off"&&!fromTap)return;
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
  if(!HAS.alerts)return;
  var open=urgentOpen();
  var fresh=open.filter(function(a){return !heard[a.id+":"+a.count];});
  open.forEach(function(a){heard[a.id+":"+a.count]=true;});
  if(fresh.length&&Date.now()-lastChimeAt>1500)chime(false);
  else if(open.length&&Date.now()-lastChimeAt>=30000)chime(false);
  document.title=open.length?"("+open.length+") Needs attention - "+BASE_TITLE:BASE_TITLE;
}

function renderSound(){
  var b=$("sound");
  b.hidden=!HAS.alerts||(IN_APP&&soundState==="on");
  if(soundState==="locked"){b.className="pill attn";b.innerHTML=ico("volumeX")+'<span>Enable sound</span>';b.setAttribute("aria-label","Enable alert sound");}
  else if(soundState==="on"){b.className="pill";b.innerHTML=ico("volume")+'<span class="lbl">Sound on</span>';b.setAttribute("aria-label","Alert sound on, tap to mute");}
  else{b.className="pill muted";b.innerHTML=ico("volumeX")+'<span class="lbl">Muted</span>';b.setAttribute("aria-label","Alert sound muted, tap to turn on");}
}

function showToast(text,undo){
  var t=$("toast");
  clearTimeout(toastTimer);
  t.className="toast"+(undo?"":" plain");
  t.innerHTML='<span>'+esc(text)+'</span>'+(undo?'<button class="btn" type="button" id="undo">'+ico("undo")+' Undo</button>':"");
  t.hidden=false;
  if(undo)$("undo").onclick=function(){t.hidden=true;undo();};
  toastTimer=setTimeout(function(){t.hidden=true;},undo?7000:6000);
}

function renderLink(){
  var pill=$("link"),banner=$("banner");
  var queued=outbox.length,live=isLive();
  if(live){
    pill.className="pill ok";pill.innerHTML='<span class="dot"></span>Live';
  } else if(offlineSince!=null||(!everLive&&Date.now()-pageStartedAt>8000)||navigator.onLine===false){
    pill.className="pill bad";pill.innerHTML=ico("wifiOff")+'<span>Offline</span>';
  } else {
    pill.className="pill warn";pill.innerHTML=ico("loader")+'<span>Connecting</span>';
  }
  var parts=null,cls="warn";
  if(!live&&offlineSince!=null){
    cls="bad";
    parts=["Offline since "+clock(offlineSince)+" ("+span(Date.now()-offlineSince)+").","Showing the last known state. Reconnecting automatically."];
  } else if(!live&&!everLive&&Date.now()-pageStartedAt>8000){
    cls="bad";parts=["Can't reach the booth.","Retrying automatically."];
  }
  if(queued){
    var q=queued+" change"+(queued===1?"":"s")+" saved on this device, "+(live?"sending now.":"sent when the connection returns.");
    parts=parts?[parts[0],parts[1]+" "+q]:[q,""];
  }
  if(parts){
    banner.hidden=false;banner.className="banner "+cls;
    banner.innerHTML=(cls==="bad"?ico("wifiOff"):ico("clock"))+'<span>'+esc(parts[0])+' <span class="sub">'+esc(parts[1])+'</span></span>';
  } else banner.hidden=true;
}

function bars(el,entries,labeler){
  if(!entries.length){el.innerHTML='<div class="empty">Nothing yet</div>';return;}
  var max=Math.max.apply(null,entries.map(function(e){return e[1];}));
  el.innerHTML=entries.map(function(e){
    return '<div class="bar"><span class="name">'+esc(labeler(e[0]))+'</span><span class="track"><span class="fill" style="width:'+Math.round(e[1]/max*100)+'%"></span></span><span class="n">'+e[1]+'</span></div>';
  }).join("");
}
function sortedCounts(obj){return Object.keys(obj).map(function(k){return [k,obj[k]];}).sort(function(a,b){return b[1]-a[1];});}

function renderStats(){
  var s=stats;if(!s)return;
  $("tOrders").textContent=s.orders;
  $("tOrdersSub").textContent=s.items+" items"+(s.canceledOrders?", "+s.canceledOrders+" canceled":"")+(s.simulatedOrders?", "+s.simulatedOrders+" test":"");
  $("tRevenue").textContent=money(s.totalCents);
  $("tAvg").textContent=s.orders?"Average "+money(s.averageCents):"No orders yet";
  $("tScoops").textContent=s.scoops;
  $("tVessels").textContent=s.cones+" cones, "+s.cups+" cups, "+s.toppings+" toppings";
  var r=s.last15Min||{orders:0,totalCents:0};
  $("tRecent").textContent=r.orders;
  $("tRecentSub").textContent=money(r.totalCents)+" taken";
  bars($("flavorBars"),sortedCounts(s.flavors),flavorName);
  bars($("toppingBars"),sortedCounts(s.toppingCounts),titleCase);
  bars($("hourBars"),s.byHour.map(function(h){return [h.hour,h.orders];}),clock);
  $("updated").textContent="Stats since midnight, updated "+clock(s.generatedAt);
}

function refreshTimes(){
  document.querySelectorAll("[data-ago]").forEach(function(el){
    var v=el.getAttribute("data-ago");el.textContent=ago(v===""?null:Number(v));
  });
}

function pendingTag(key){
  var p=pendingFor(key);
  if(!p)return "";
  return '<span class="pending">'+ico(isLive()?"loader":"clock")+(isLive()?"Saving":"Waiting to send")+"</span>";
}

function alertIcon(a){return a.kind==="help"?"bellRing":a.kind==="soldout"?"ban":a.kind==="offline"?"wifiOff":"alert";}

function compactList(cls,title,list,ackLabel,max){
  var ids=list.map(function(a){return a.id;}).join(",");
  return '<div class="updates '+cls+'"><div class="uhead"><span>'+ico(cls==="more"?"alert":"bell")+" "+title+" ("+list.length+')</span>'+(list.length>1?'<button class="btn quiet" type="button" data-ackids="'+esc(ids)+'">'+ico("checkCheck")+" "+ackLabel+"</button>":"")+"</div>"+list.slice(0,max).map(function(a){
    return '<div class="urow">'+ico(alertIcon(a))+'<span class="ut"><b>'+esc(a.title)+(a.count>1?" (x"+a.count+")":"")+'</b> <span class="when">'+agoSpan(a.updatedAt)+'</span></span><button class="btn quiet" type="button" data-ack="'+esc(a.id)+'">'+ico("check")+" OK</button></div>";
  }).join("")+(list.length>max?'<div class="urow more-n">and '+(list.length-max)+" more</div>":"")+"</div>";
}

function renderAlerts(){
  var open=state.alerts.filter(function(a){return a.ackedAt==null&&a.resolvedAt==null&&!alertAcked(a);});
  var rank={urgent:0,warning:1};
  var main=open.filter(function(a){return a.severity!=="info";}).sort(function(a,b){return rank[a.severity]-rank[b.severity]||b.updatedAt-a.updatedAt;});
  var info=open.filter(function(a){return a.severity==="info";}).sort(function(a,b){return b.updatedAt-a.updatedAt;});
  var shown=main.slice(0,2),rest=main.slice(2);
  var html=shown.map(function(a){
    var urgent=a.severity==="urgent";
    return '<div class="alert '+esc(a.severity)+'" role="alert"><span class="ic">'+ico(alertIcon(a))+'</span><div class="body"><div class="title">'+esc(a.title)+(a.count>1?" (x"+a.count+")":"")+'<span class="when">'+agoSpan(a.updatedAt)+'</span></div>'+(a.detail?'<div class="detail">'+esc(a.detail)+'</div>':"")+'</div><button class="btn '+(urgent?"urgent":"quiet")+'" type="button" data-ack="'+esc(a.id)+'">'+ico("check")+(urgent?" Acknowledge":" OK")+"</button></div>";
  }).join("");
  if(rest.length)html+=compactList("more","More alerts",rest,"Acknowledge all",5);
  if(info.length)html+=compactList("info","Updates",info,"Clear all",3);
  $("alerts").innerHTML=html;
}

function itemsHtml(o){
  return o.items.map(function(it){
    var f=it.flavors.map(flavorName).join(", ")||"No flavor";
    var vessel=it.vessel==="cone"?"Waffle cone":titleCase(it.vessel);
    var t=it.toppings&&it.toppings.length?' <span class="t">+ '+esc(it.toppings.map(titleCase).join(", "))+"</span>":' <span class="nt">no toppings</span>';
    return '<li><span class="v">'+esc(vessel)+":</span> "+esc(f)+t+"</li>";
  }).join("");
}

function orderLabel(o){return (o.orderNumber!=null?"#"+o.orderNumber+" ":"")+(o.customerName||"Guest");}

function orderCard(o,status){
  var next=NEXT[status],key="order:"+o.id;
  var primary=status==="paid"?'<button class="btn primary big" type="button" data-order="'+esc(o.id)+'" data-to="preparing">'+ico("play")+" Start</button>"
    :status==="preparing"?'<button class="btn go big" type="button" data-order="'+esc(o.id)+'" data-to="ready">'+ico("check")+" Ready</button>"
    :'<button class="btn primary big" type="button" data-order="'+esc(o.id)+'" data-to="collected">'+ico("checkCheck")+" Collected</button>";
  return '<article class="order s-'+status+'"><div class="head"><span class="num">'+(o.orderNumber!=null?"#"+o.orderNumber:"")+'</span><span class="who">'+esc(o.customerName||"Guest")+'</span>'+pendingTag(key)+'<span class="age">'+agoSpan(o.receivedAt)+'</span></div><ul>'+itemsHtml(o)+'</ul><div class="acts"><span class="chip '+status+'">'+STATUS_LABEL[status]+'</span><span class="grow"></span><button class="btn danger" type="button" data-cancel="'+esc(o.id)+'">'+ico("x")+" Cancel</button>"+(next?primary:"")+"</div></article>";
}

function renderOrders(){
  var real=state.orders.filter(function(o){return !o.simulated;});
  var withStatus=real.map(function(o){return {o:o,s:orderStatus(o)};});
  var making=withStatus.filter(function(x){return x.s==="paid"||x.s==="preparing";}).sort(function(a,b){return a.o.paidAt-b.o.paidAt;});
  var ready=withStatus.filter(function(x){return x.s==="ready";}).sort(function(a,b){return a.o.paidAt-b.o.paidAt;});
  var done=withStatus.filter(function(x){return x.s==="collected"||x.s==="canceled";}).sort(function(a,b){return b.o.statusAt-a.o.statusAt;}).slice(0,12);
  $("openCount").textContent=making.length+ready.length;
  var html="";
  if(!making.length&&!ready.length)html='<div class="empty">No open orders. New ones appear here the moment a customer pays.</div>';
  if(making.length)html+='<div class="sub-h">'+ico("cone")+" To make ("+making.length+')</div><div class="orders">'+making.map(function(x){return orderCard(x.o,x.s);}).join("")+"</div>";
  if(ready.length)html+='<div class="sub-h" style="margin-top:1rem">'+ico("bell")+" Ready for pickup ("+ready.length+')</div><div class="orders">'+ready.map(function(x){return orderCard(x.o,x.s);}).join("")+"</div>";
  $("orders").innerHTML=html;
  $("doneWrap").hidden=!done.length;
  $("doneTitle").textContent="Finished ("+done.length+")";
  $("done").innerHTML=done.map(function(x){
    var back=x.s==="canceled"?"paid":"ready";
    return '<div class="drow"><span class="num">'+(x.o.orderNumber!=null?"#"+x.o.orderNumber:"")+'</span><span class="who">'+esc(x.o.customerName||"Guest")+'</span><span class="chip '+x.s+'">'+STATUS_LABEL[x.s]+"</span>"+pendingTag("order:"+x.o.id)+'<button class="btn quiet" type="button" data-order="'+esc(x.o.id)+'" data-to="'+back+'">'+ico("undo")+" Reopen</button></div>";
  }).join("");
}

function renderSoldOut(){
  $("soldout").innerHTML=state.flavors.map(function(f){
    var out=flavorOut(f);
    return '<button class="flavor'+(out?" out":"")+'" type="button" data-flavor="'+esc(f.id)+'" aria-pressed="'+out+'"><span class="name">'+esc(f.name)+'</span><span class="state">'+(out?ico("ban")+"Sold out":ico("check")+"Available")+"</span>"+pendingTag("flavor:"+f.id)+"</button>";
  }).join("")||'<div class="empty">The kiosk hasn\'t reported its flavors yet.</div>';
}

function renderKiosk(){
  var k=state.kiosk,h=k.health,pill=$("kioskPill"),live=isLive();
  if(!live){pill.className="pill muted";pill.innerHTML=ico("tablet")+'Kiosk unknown';}
  else{pill.className="pill "+(k.online?"ok":"bad");pill.innerHTML=ico("tablet")+'Kiosk '+(k.online?"online":"offline");}
  var rows=[["Last heard",null,k.online?"ok-t":"bad-t",agoSpan(k.lastSeenAt)],["Screen",k.screen?titleCase(k.screen):"Unknown",""]];
  if(h){
    rows.push(["Payments",h.simulatePayment?"Simulated":h.environment,h.simulatePayment?"warn-t":""]);
    rows.push(["Square",h.authorized?"Authorized":(h.authorizationState||"Not authorized"),h.authorized?"ok-t":"bad-t"]);
    rows.push(["Card reader",h.readerReady?"Ready":"Not ready",h.readerReady?"ok-t":(h.simulatePayment?"":"bad-t")]);
    h.readers.forEach(function(r){
      if(r.batteryPercent!=null&&r.batteryPercent>=0)rows.push([r.name,r.batteryPercent+"%"+(r.isCharging?", charging":""),r.batteryPercent<=20&&!r.isCharging?"bad-t":""]);
    });
    if(h.deviceBattery&&h.deviceBattery.percent>=0)rows.push(["iPad battery",h.deviceBattery.percent+"%"+(h.deviceBattery.charging?", charging":""),h.deviceBattery.percent<=20&&!h.deviceBattery.charging?"bad-t":""]);
    rows.push(["Catalog",h.catalog.ok?"OK":(h.catalog.error||h.catalog.status),h.catalog.ok?"ok-t":"warn-t"]);
    if(h.lastError)rows.push(["Last error",h.lastError,"warn-t"]);
    rows.push(["App",h.appVersion,""]);
  } else rows.push(["Health","No report yet","warn-t"]);
  if(HAS.health)$("health").innerHTML=rows.map(function(r){
    return '<div><span>'+esc(r[0])+'</span><span class="'+r[2]+'">'+(r[3]?r[3]:esc(r[1]))+"</span></div>";
  }).join("");
}

var HAS={alerts:!!$("alerts"),orders:!!$("orders"),feed:!!$("feed"),soldout:!!$("soldout"),health:!!$("health"),stats:!!$("tOrders")};

function render(){
  renderLink();renderSound();
  if(!state){
    var waiting='<div class="empty">'+ico("loader")+" Waiting for the booth</div>";
    ["orders","feed","soldout","health"].forEach(function(id){if(HAS[id]&&!$(id).innerHTML)$(id).innerHTML=waiting;});
    return;
  }
  if(HAS.alerts)renderAlerts();
  if(HAS.orders)renderOrders();
  if(HAS.feed)renderFeed();
  if(HAS.soldout)renderSoldOut();
  renderKiosk();
}

function renderFeed(){
  var list=state.orders.slice().sort(function(a,b){return b.paidAt-a.paidAt;});
  $("feedCount").textContent=list.filter(function(o){return !o.simulated;}).length;
  if(!list.length){$("feed").innerHTML='<div class="empty">No orders yet. They appear here the moment a customer pays.</div>';return;}
  $("feed").innerHTML=list.map(function(o){
    var st=orderStatus(o);
    var items=o.items.map(function(it){
      var t=it.toppings&&it.toppings.length?" + "+it.toppings.map(titleCase).join(", "):"";
      return (it.vessel==="cone"?"Waffle cone":titleCase(it.vessel))+": "+(it.flavors.map(flavorName).join(", ")||"no flavor")+t;
    }).join("; ");
    return '<div class="frow'+(o.simulated?" sim":"")+'"><span class="num">'+(o.orderNumber!=null?"#"+o.orderNumber:"")+'</span><span class="who">'+esc(o.customerName||"Guest")+' <span class="chip '+st+'">'+(o.simulated?"Test, ":"")+STATUS_LABEL[st]+"</span>"+pendingTag("order:"+o.id)+'</span><span class="total">'+money(o.totalCents)+'</span><span class="items">'+esc(items)+'</span><span class="when">'+clock(o.paidAt)+"</span></div>";
  }).join("");
}

function setStatus(id,to,withUndo){
  var o=state&&state.orders.filter(function(x){return x.id===id;})[0];
  if(!o)return;
  var from=orderStatus(o);
  if(from===to)return;
  enqueue({type:"setOrderStatus",orderId:id,status:to});
  if(withUndo)showToast(orderLabel(o)+": "+STATUS_LABEL[to],function(){enqueue({type:"setOrderStatus",orderId:id,status:from});});
}

function askCancel(id){
  var o=state&&state.orders.filter(function(x){return x.id===id;})[0];
  if(!o)return;
  confirmOrder=id;
  $("confirmTitle").textContent="Cancel order "+orderLabel(o)+"?";
  $("confirmText").textContent="It leaves the queue and stops counting in totals. Any refund is done separately in Square.";
  var d=$("confirm");
  if(d.showModal)d.showModal();else if(confirm($("confirmTitle").textContent))finishCancel();
}
function finishCancel(){
  var d=$("confirm");if(d.open)d.close();
  if(confirmOrder)setStatus(confirmOrder,"canceled",true);
  confirmOrder=null;
}

document.addEventListener("click",function(e){
  var el=e.target.closest&&e.target.closest("button");
  if(!el)return;
  if(el.dataset.ack){enqueue({type:"ack",alertId:el.dataset.ack});}
  else if(el.dataset.ackids){el.dataset.ackids.split(",").forEach(function(id){if(id)enqueue({type:"ack",alertId:id});});}
  else if(el.dataset.flavor){
    var f=state&&state.flavors.filter(function(x){return x.id===el.dataset.flavor;})[0];
    if(f)enqueue({type:"setSoldOut",flavor:f.id,soldOut:!flavorOut(f)});
  }
  else if(el.dataset.order&&el.dataset.to){setStatus(el.dataset.order,el.dataset.to,true);}
  else if(el.dataset.cancel){askCancel(el.dataset.cancel);}
  else if(el.id==="sound"){
    if(soundState==="on"){soundState="off";store(MUTE_KEY,"1");renderSound();}
    else{store(MUTE_KEY,null);soundState="on";chime(true);renderSound();}
  }
  else if(el.id==="confirmYes")finishCancel();
  else if(el.id==="confirmNo"){$("confirm").close();confirmOrder=null;}
});

restoreOutbox();
render();
connect();
loadStats();
flush();
`;

export function dashboardScript(): string {
  return SCRIPT.replace("__ICONS__", () => JSON.stringify(ICONS));
}
