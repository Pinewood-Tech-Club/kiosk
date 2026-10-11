import { escapeHtml } from "./http";

const STYLE = `
:root{color-scheme:dark;--bg:#14161c;--panel:#1d2029;--panel2:#252936;--line:#2f3443;--text:#f3efe6;--dim:#a2a8b8;--accent:#f4b6c8;--ok:#7fd1a0;--warn:#f2c36b;--bad:#ef8a80;--vanilla:#f3e3b5}
*{box-sizing:border-box}
html{font-size:18px}
body{margin:0;background:var(--bg);color:var(--text);font-family:ui-rounded,"SF Pro Rounded",system-ui,-apple-system,"Segoe UI",sans-serif;line-height:1.35}
svg.i{width:1.15em;height:1.15em;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round;vertical-align:-.2em;flex:none}
button{font:inherit;color:inherit;cursor:pointer}
.login{min-height:100vh;display:grid;place-items:center;padding:2rem}
.login form{background:var(--panel);border:1px solid var(--line);border-radius:1.2rem;padding:2.2rem;width:min(26rem,100%);display:grid;gap:1rem}
.login h1{margin:0;font-size:1.6rem;display:flex;gap:.6rem;align-items:center}
.login input{font:inherit;font-size:1.6rem;letter-spacing:.25em;padding:.7rem 1rem;border-radius:.8rem;border:1px solid var(--line);background:var(--bg);color:var(--text)}
.login button{padding:.8rem 1rem;border-radius:.8rem;border:0;background:var(--accent);color:#2a1620;font-weight:700;font-size:1.1rem}
.login .err{color:var(--bad);margin:0}
header{display:flex;align-items:center;gap:1rem;padding:1rem 1.6rem;border-bottom:1px solid var(--line);position:sticky;top:0;background:var(--bg);z-index:2}
header h1{margin:0;font-size:1.3rem;display:flex;gap:.6rem;align-items:center;flex:1}
.pill{display:inline-flex;gap:.45rem;align-items:center;padding:.35rem .85rem;border-radius:99rem;background:var(--panel);border:1px solid var(--line);font-size:.9rem;white-space:nowrap}
.pill.ok{color:var(--ok)}.pill.warn{color:var(--warn)}.pill.bad{color:var(--bad)}
.ghost{background:none;border:1px solid var(--line);border-radius:.7rem;padding:.4rem .8rem;display:inline-flex;gap:.4rem;align-items:center;color:var(--dim)}
#banner{display:none;background:#3a2a1f;color:var(--warn);padding:.6rem 1.6rem;border-bottom:1px solid var(--line)}
#banner.on{display:flex;gap:.6rem;align-items:center}
main{padding:1.4rem 1.6rem 3rem;display:grid;gap:1.4rem;max-width:110rem;margin:0 auto}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(13rem,1fr));gap:1rem}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:1.1rem;padding:1.1rem 1.3rem}
.tile .label{color:var(--dim);font-size:.9rem;display:flex;gap:.45rem;align-items:center}
.tile .value{font-size:3rem;font-weight:700;line-height:1.1;font-variant-numeric:tabular-nums;margin-top:.2rem}
.tile .sub{color:var(--dim);font-size:.9rem;font-variant-numeric:tabular-nums}
.cols{display:grid;grid-template-columns:minmax(0,3fr) minmax(0,2fr);gap:1.4rem;align-items:start}
@media(max-width:62rem){.cols{grid-template-columns:1fr}}
.stack{display:grid;gap:1.4rem}
section.card{background:var(--panel);border:1px solid var(--line);border-radius:1.1rem;padding:1.1rem 1.3rem}
section.card h2{margin:0 0 .8rem;font-size:1rem;color:var(--dim);font-weight:600;letter-spacing:.04em;text-transform:uppercase;display:flex;gap:.5rem;align-items:center}
.empty{color:var(--dim);padding:.6rem 0}
.alert{display:flex;gap:.9rem;align-items:center;padding:.8rem 1rem;border-radius:.9rem;background:var(--panel2);border-left:.4rem solid var(--warn);margin-bottom:.6rem}
.alert.urgent{border-color:var(--bad);background:#35252a}.alert.info{border-color:var(--accent)}
.alert .body{flex:1;min-width:0}.alert .title{font-weight:700;font-size:1.1rem}.alert .detail{color:var(--dim);font-size:.9rem}
.alert button{background:var(--text);color:var(--bg);border:0;border-radius:.7rem;padding:.55rem 1rem;font-weight:700;display:inline-flex;gap:.4rem;align-items:center}
.order{display:grid;grid-template-columns:auto 1fr auto;gap:.2rem 1rem;padding:.85rem 0;border-top:1px solid var(--line);align-items:baseline}
.order:first-child{border-top:0}
.order .num{font-size:1.5rem;font-weight:700;font-variant-numeric:tabular-nums;color:var(--accent);min-width:3.2rem}
.order .who{font-size:1.2rem;font-weight:600}
.order .total{font-size:1.3rem;font-weight:700;font-variant-numeric:tabular-nums;text-align:right}
.order .items{grid-column:2;color:var(--dim);font-size:.95rem}
.order .when{grid-column:3;color:var(--dim);font-size:.85rem;text-align:right}
.badge{font-size:.72rem;padding:.12rem .55rem;border-radius:99rem;margin-left:.5rem;background:var(--panel2);color:var(--dim);text-transform:uppercase;letter-spacing:.05em;vertical-align:.15rem}
.badge.paid{color:var(--warn)}.badge.preparing{color:var(--accent)}.badge.ready{color:var(--ok)}.badge.canceled{color:var(--bad)}
.bar{display:grid;grid-template-columns:7.5rem 1fr 2.6rem;gap:.7rem;align-items:center;margin:.35rem 0;font-size:1rem}
.bar .name{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.bar .track{height:.9rem;background:var(--panel2);border-radius:99rem;overflow:hidden}
.bar .fill{display:block;height:100%;background:var(--accent);border-radius:99rem;min-width:.2rem;transition:width .4s}
.bar .n{text-align:right;font-variant-numeric:tabular-nums;font-weight:700}
.hours .fill{background:var(--vanilla)}
.flavors{display:grid;grid-template-columns:repeat(auto-fill,minmax(10rem,1fr));gap:.6rem}
.flavor{display:flex;gap:.5rem;align-items:center;justify-content:space-between;padding:.65rem .9rem;border-radius:.8rem;background:var(--panel2);border:1px solid var(--line);text-align:left}
.flavor.out{background:#35252a;border-color:var(--bad);color:var(--bad)}
.flavor .state{font-size:.75rem;text-transform:uppercase;letter-spacing:.05em}
.health{display:grid;gap:.45rem}
.health div{display:flex;justify-content:space-between;gap:1rem}
.health span:first-child{color:var(--dim)}
.health .ok{color:var(--ok)}.health .warn{color:var(--warn)}.health .bad{color:var(--bad)}
footer{color:var(--dim);font-size:.85rem;display:flex;gap:1.2rem;justify-content:center;flex-wrap:wrap}
footer a{color:var(--dim)}
`;

const ICONS: Record<string, string> = {
  cone: '<path d="m7 11 4.08 10.35a1 1 0 0 0 1.84 0L17 11"/><path d="M17 7A5 5 0 0 0 7 7"/><path d="M17 7a2 2 0 0 1 0 4H7a2 2 0 0 1 0-4"/>',
  bell: '<path d="M10.268 21a2 2 0 0 0 3.464 0"/><path d="M3.262 15.326A1 1 0 0 0 4 17h16a1 1 0 0 0 .74-1.673C19.41 13.956 18 12.499 18 8A6 6 0 0 0 6 8c0 4.499-1.411 5.956-2.738 7.326"/>',
  check: '<path d="M20 6 9 17l-5-5"/>',
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
};

export function icon(name: string): string {
  return `<svg class="i" viewBox="0 0 24 24" aria-hidden="true">${ICONS[name]}</svg>`;
}

export function shell(title: string, body: string, nonce: string, script = ""): string {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex"><title>${escapeHtml(title)}</title><style nonce="${nonce}">${STYLE}</style></head><body>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ""}</body></html>`;
}

export function loginBody(message: string | null): string {
  const error = message ? `<p class="err" role="alert">${escapeHtml(message)}</p>` : "";
  return `<div class="login"><form method="post" action="/dashboard/login"><h1>${icon("cone")} Booth dashboard</h1>${error}<label for="pin" style="color:var(--dim)">Staff PIN</label><input id="pin" name="pin" type="password" autocomplete="current-password" required autofocus><button>${icon("lock")} Sign in</button></form></div>`;
}

export function dashboardBody(): string {
  return `<header><h1>${icon("cone")} Booth dashboard</h1><span class="pill" id="link"></span><span class="pill" id="kioskPill"></span>
<form method="post" action="/dashboard/logout"><button class="ghost">${icon("logOut")} Sign out</button></form></header>
<div id="banner">${icon("wifiOff")}<span id="bannerText"></span></div>
<main>
<div class="tiles">
<div class="tile"><div class="label">${icon("receipt")} Orders</div><div class="value" id="tOrders">0</div><div class="sub" id="tOrdersSub"></div></div>
<div class="tile"><div class="label">${icon("dollar")} Revenue</div><div class="value" id="tRevenue">$0</div><div class="sub" id="tAvg"></div></div>
<div class="tile"><div class="label">${icon("cone")} Scoops</div><div class="value" id="tScoops">0</div><div class="sub" id="tVessels"></div></div>
<div class="tile"><div class="label">${icon("clock")} Last 15 minutes</div><div class="value" id="tRecent">0</div><div class="sub" id="tRecentSub"></div></div>
</div>
<div id="alertsCard" style="display:none"><section class="card"><h2>${icon("bell")} Needs attention</h2><div id="alerts"></div></section></div>
<div class="cols">
<div class="stack"><section class="card"><h2>${icon("receipt")} Orders, newest first</h2><div id="orders"></div></section></div>
<div class="stack">
<section class="card"><h2>${icon("ban")} Sold out</h2><div class="flavors" id="soldout"></div></section>
<section class="card"><h2>${icon("tablet")} Kiosk</h2><div class="health" id="health"></div></section>
<section class="card"><h2>${icon("cone")} Scoops by flavor</h2><div id="flavorBars"></div></section>
<section class="card"><h2>${icon("sparkles")} Toppings</h2><div id="toppingBars"></div></section>
<section class="card"><h2>${icon("chart")} Orders per hour</h2><div class="hours" id="hourBars"></div></section>
</div></div>
<footer><span id="updated"></span><a href="/v1/square/oauth/start">Connect Square</a></footer>
</main>`;
}

const SCRIPT = String.raw`
"use strict";
var ICONS = __ICONS__;
function ico(n){return '<svg class="i" viewBox="0 0 24 24" aria-hidden="true">'+ICONS[n]+'</svg>';}
var $ = function(id){return document.getElementById(id);};
var state = null, stats = null, ws = null, everOpen = false, attempt = 0, retryTimer = null;
var lastMessageAt = 0, connectStartedAt = 0, lastPingAt = 0, statsTimer = null, serverOffset = 0, pendingAcks = {};

function esc(s){return String(s).replace(/[&<>"']/g,function(c){return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];});}
function money(c){var d=c/100;return "$"+(c%100===0?d.toFixed(0):d.toFixed(2));}
function now(){return Date.now()+serverOffset;}
function ago(ms){
  if(ms==null)return "never";
  var s=Math.max(0,Math.round((now()-ms)/1000));
  if(s<10)return "just now";if(s<60)return s+" s ago";
  var m=Math.floor(s/60);if(m<60)return m+" min ago";
  var h=Math.floor(m/60);return h+" h "+(m%60)+" min ago";
}
function clock(ms){return new Date(ms).toLocaleTimeString([],{hour:"numeric",minute:"2-digit"});}
function titleCase(s){return String(s).replace(/[-_]/g," ").replace(/\b\w/g,function(c){return c.toUpperCase();});}
function flavorName(id){
  var f=state&&state.flavors.filter(function(x){return x.id===id;})[0];
  return f?f.name:titleCase(id);
}
function uuid(){
  if(crypto.randomUUID)return crypto.randomUUID();
  return "d-"+Math.random().toString(36).slice(2)+Date.now().toString(36);
}

function applyState(next){
  state=next;
  if(next.serverTime)serverOffset=next.serverTime-Date.now();
  render();
}

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
  render();
}

function send(m){if(ws&&ws.readyState===1)ws.send(JSON.stringify(m));}

function onMessage(event){
  lastMessageAt=Date.now();
  var msg;try{msg=JSON.parse(event.data);}catch(e){return;}
  if(msg.type==="snapshot"){applyState(msg.state);scheduleStats(0);}
  else if(msg.type==="patch")applyPatch(msg);
  else if(msg.type==="pong"){
    if(msg.serverTime)serverOffset=msg.serverTime-Date.now();
    if(state&&msg.rev>state.rev)send({type:"sync"});
  }
}

function connect(){
  clearTimeout(retryTimer);
  if(ws){try{ws.close();}catch(e){}}
  var url=(location.protocol==="https:"?"wss://":"ws://")+location.host+"/v1/ws";
  var socket=new WebSocket(url);
  ws=socket;
  connectStartedAt=Date.now();
  var opened=false;
  socket.onopen=function(){opened=true;everOpen=true;attempt=0;lastMessageAt=Date.now();renderLink();};
  socket.onmessage=function(e){if(ws===socket)onMessage(e);};
  socket.onclose=function(){
    if(ws!==socket)return;
    renderLink();
    if(!opened){
      fetch("/v1/state",{credentials:"same-origin"}).then(function(r){if(r.status===401||r.status===403)location.reload();}).catch(function(){});
    }
    retryTimer=setTimeout(connect,backoffDelay());
  };
  socket.onerror=function(){};
  renderLink();
}

function backoffDelay(){return Math.min(30000,1000*Math.pow(2,attempt++))*(0.5+Math.random());}

function abandonSocket(){
  var dead=ws;ws=null;
  try{dead.close();}catch(e){}
  renderLink();
  clearTimeout(retryTimer);
  retryTimer=setTimeout(connect,backoffDelay());
}

setInterval(function(){
  if(!ws)return;
  if(ws.readyState===0&&Date.now()-connectStartedAt>10000)return abandonSocket();
  if(ws.readyState!==1)return;
  if(Date.now()-lastMessageAt>25000)return abandonSocket();
  if(Date.now()-lastPingAt>=10000){lastPingAt=Date.now();send({type:"ping",t:lastPingAt});}
},5000);
setInterval(function(){if(state)render(true);},5000);
window.addEventListener("online",function(){attempt=0;connect();});
document.addEventListener("visibilitychange",function(){
  if(document.visibilityState==="visible"&&(!ws||ws.readyState!==1)){attempt=0;connect();}
});

function dayStart(){var d=new Date();d.setHours(0,0,0,0);return d.getTime();}

function scheduleStats(delay){
  clearTimeout(statsTimer);
  statsTimer=setTimeout(loadStats,delay);
}
function loadStats(){
  clearTimeout(statsTimer);
  statsTimer=setTimeout(loadStats,30000);
  fetch("/v1/stats?since="+dayStart(),{credentials:"same-origin",cache:"no-store"}).then(function(r){
    if(r.status===401||r.status===403){location.reload();return null;}
    return r.ok?r.json():null;
  }).then(function(s){if(s){stats=s;renderStats();}}).catch(function(){});
}

function act(action){
  action.id=uuid();action.by="Dashboard";
  return fetch("/v1/actions",{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/json"},body:JSON.stringify({actions:[action]})})
    .then(function(r){if(r.status===401||r.status===403)location.reload();return r.ok?r.json():null;})
    .then(function(j){
      var ok=j&&j.results&&j.results[0]&&j.results[0].status!=="rejected";
      if(!ok&&action.type==="ack"){delete pendingAcks[action.alertId];if(state)renderAlerts();}
      if(j&&state&&j.rev>state.rev)send({type:"sync"});
    })
    .catch(function(){if(action.type==="ack"){delete pendingAcks[action.alertId];if(state)renderAlerts();}});
}

function renderLink(){
  var pill=$("link"),banner=$("banner");
  var live=ws&&ws.readyState===1&&state;
  if(live){
    pill.className="pill ok";pill.innerHTML=ico("wifi")+" Live";banner.className="";
  } else {
    pill.className="pill bad";pill.innerHTML=ico("wifiOff")+(everOpen?" Reconnecting":" Connecting");
    banner.className="on";
    $("bannerText").textContent=state?"Connection lost. Showing the last known state; reconnecting automatically.":"Connecting to the booth.";
  }
}

function bars(el,entries,labeler){
  if(!entries.length){el.innerHTML='<div class="empty">Nothing yet</div>';return;}
  var max=Math.max.apply(null,entries.map(function(e){return e[1];}));
  el.innerHTML=entries.map(function(e){
    return '<div class="bar"><span class="name">'+esc(labeler(e[0]))+'</span><span class="track"><span class="fill" style="width:'+Math.round(e[1]/max*100)+'%"></span></span><span class="n">'+e[1]+'</span></div>';
  }).join("");
}

function sortedCounts(obj){
  return Object.keys(obj).map(function(k){return [k,obj[k]];}).sort(function(a,b){return b[1]-a[1];});
}

function renderStats(){
  var s=stats;if(!s)return;
  $("tOrders").textContent=s.orders;
  $("tOrdersSub").textContent=s.items+" items"+(s.canceledOrders?", "+s.canceledOrders+" canceled not counted":"")+(s.simulatedOrders?", "+s.simulatedOrders+" test orders not counted":"");
  $("tRevenue").textContent=money(s.totalCents);
  $("tAvg").textContent=s.orders?"Average "+money(s.averageCents)+" per order":"No orders yet";
  $("tScoops").textContent=s.scoops;
  $("tVessels").textContent=s.cones+" cones, "+s.cups+" cups, "+s.toppings+" toppings";
  var r=s.last15Min||{orders:0,totalCents:0};
  $("tRecent").textContent=r.orders;
  $("tRecentSub").textContent=money(r.totalCents)+" taken";
  bars($("flavorBars"),sortedCounts(s.flavors),flavorName);
  bars($("toppingBars"),sortedCounts(s.toppingCounts),titleCase);
  bars($("hourBars"),s.byHour.map(function(h){return [h.hour,h.orders];}),clock);
  $("updated").textContent="Stats updated "+clock(s.generatedAt)+", counting since midnight";
}

function agoSpan(ms){return '<span data-ago="'+(ms==null?"":ms)+'">'+ago(ms)+"</span>";}

function refreshTimes(){
  document.querySelectorAll("[data-ago]").forEach(function(el){
    var v=el.getAttribute("data-ago");el.textContent=ago(v===""?null:Number(v));
  });
}

function renderAlerts(){
  var open=state.alerts.filter(function(a){return a.ackedAt==null&&a.resolvedAt==null;});
  Object.keys(pendingAcks).forEach(function(id){if(!open.some(function(a){return a.id===id;}))delete pendingAcks[id];});
  $("alertsCard").style.display=open.length?"":"none";
  var rank={urgent:0,warning:1,info:2};
  open.sort(function(a,b){return rank[a.severity]-rank[b.severity]||b.updatedAt-a.updatedAt;});
  $("alerts").innerHTML=open.map(function(a){
    var name=a.kind==="help"?"help":a.kind==="soldout"?"ban":"alert";
    return '<div class="alert '+esc(a.severity)+'">'+ico(name)+'<div class="body"><div class="title">'+esc(a.title)+(a.count>1?" (x"+a.count+")":"")+'</div><div class="detail">'+esc(a.detail)+" - "+agoSpan(a.updatedAt)+'</div></div><button data-ack="'+esc(a.id)+'"'+(pendingAcks[a.id]?" disabled":"")+'>'+ico("check")+" Acknowledge</button></div>";
  }).join("");
}

function itemsText(o){
  return o.items.map(function(it){
    var f=it.flavors.map(flavorName).join(", ");
    var t=it.toppings&&it.toppings.length?" + "+it.toppings.map(titleCase).join(", "):"";
    return titleCase(it.vessel)+": "+(f||"no flavor")+t;
  }).join("  |  ");
}

function renderOrders(){
  var list=state.orders.filter(function(o){return !o.simulated;});
  if(!list.length){$("orders").innerHTML='<div class="empty">No orders yet. They appear here the moment a customer pays.</div>';return;}
  $("orders").innerHTML=list.map(function(o){
    var badge=o.status==="collected"?"":'<span class="badge '+esc(o.status)+'">'+esc(o.status)+"</span>";
    return '<div class="order"><span class="num">'+(o.orderNumber!=null?"#"+o.orderNumber:"")+'</span><span class="who">'+esc(o.customerName||"Guest")+badge+'</span><span class="total">'+money(o.totalCents)+'</span><span class="items">'+esc(itemsText(o))+'</span><span class="when">'+clock(o.paidAt)+"</span></div>";
  }).join("");
}

function renderSoldOut(){
  $("soldout").innerHTML=state.flavors.map(function(f){
    return '<button class="flavor'+(f.soldOut?" out":"")+'" data-flavor="'+esc(f.id)+'" data-out="'+(f.soldOut?"1":"0")+'" aria-pressed="'+f.soldOut+'"><span>'+esc(f.name)+'</span><span class="state">'+(f.soldOut?"Sold out":"Available")+"</span></button>";
  }).join("")||'<div class="empty">The kiosk has not reported its flavors yet.</div>';
}

function renderKiosk(){
  var k=state.kiosk,h=k.health;
  var pill=$("kioskPill");
  pill.className="pill "+(k.online?"ok":"bad");
  pill.innerHTML=ico("tablet")+(k.online?" Kiosk online":" Kiosk offline");
  var rows=[["Last heard",ago(k.lastSeenAt),k.online?"ok":"bad",agoSpan(k.lastSeenAt)],["Screen",k.screen?titleCase(k.screen):"unknown",""]];
  if(h){
    rows.push(["Mode",h.simulatePayment?"Simulated payments":h.environment,h.simulatePayment?"warn":""]);
    rows.push(["Square",h.authorized?"Authorized":(h.authorizationState||"Not authorized"),h.authorized?"ok":"bad"]);
    rows.push(["Card reader",h.readerReady?"Ready":"Not ready",h.readerReady?"ok":(h.simulatePayment?"":"bad")]);
    h.readers.forEach(function(r){
      if(r.batteryPercent!=null&&r.batteryPercent>=0)rows.push([r.name,r.batteryPercent+"%"+(r.isCharging?" charging":""),r.batteryPercent<=20&&!r.isCharging?"bad":""]);
    });
    if(h.deviceBattery&&h.deviceBattery.percent>=0)rows.push(["iPad battery",h.deviceBattery.percent+"%"+(h.deviceBattery.charging?" charging":""),h.deviceBattery.percent<=20&&!h.deviceBattery.charging?"bad":""]);
    rows.push(["Catalog",h.catalog.ok?"OK":(h.catalog.error||h.catalog.status),h.catalog.ok?"ok":"warn"]);
    if(h.lastError)rows.push(["Last error",h.lastError,"warn"]);
    rows.push(["App",h.appVersion,""]);
  } else rows.push(["Health","No report yet","warn"]);
  $("health").innerHTML=rows.map(function(r){
    var value=r[3]?r[3]:esc(r[1]);
    return '<div><span>'+esc(r[0])+'</span><span class="'+r[2]+'">'+value+"</span></div>";
  }).join("");
}

function render(timeOnly){
  renderLink();
  if(!state)return;
  if(timeOnly)return refreshTimes();
  renderAlerts();renderOrders();renderKiosk();renderSoldOut();
}

document.addEventListener("click",function(e){
  var el=e.target.closest&&e.target.closest("button");
  if(!el)return;
  if(el.dataset.ack){el.disabled=true;pendingAcks[el.dataset.ack]=true;act({type:"ack",alertId:el.dataset.ack});}
  else if(el.dataset.flavor){act({type:"setSoldOut",flavor:el.dataset.flavor,soldOut:el.dataset.out!=="1"});}
});

connect();
loadStats();
`;

export function dashboardScript(): string {
  return SCRIPT.replace("__ICONS__", () => JSON.stringify(ICONS));
}
