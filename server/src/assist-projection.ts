/**
 * The staff assist view's model of a kiosk's cart: the kiosk's last session with the staff page's own unacknowledged
 * commands applied by the same rules the kiosk uses (AppModel and AppModel+Assist on the iPad). Shipped verbatim inside
 * the staff page's script and evaluated by the tests, so it stays plain ES5 with no imports.
 */
export const ASSIST_PROJECTION_JS = String.raw`
var PJ_SCOOPS=[0,400,700,900];
function pjPrice(it){var n=it.flavors.length;return (n<PJ_SCOOPS.length?PJ_SCOOPS[n]:900+200*(n-3))+(it.vessel==="cone"?150:0)+50*it.toppings.length;}
function pjCopy(it){return {id:it.id,vessel:it.vessel,flavors:it.flavors.slice(),toppings:(it.toppings||[]).slice()};}
function pjDefaultVessel(ctx){return ctx.soldOut("vessel","cup")&&!ctx.soldOut("vessel","cone")?"cone":"cup";}
function pjFresh(m,ref){var v=pjDefaultVessel(m.ctx);m.start=v;return {id:ref||"local-"+(++m.fresh),vessel:v,flavors:[],toppings:[]};}
function pjModel(x,ctx){
  var m={ctx:ctx,fresh:0,screen:"attract",mode:"customize",step:"vessel",items:[],current:null,editing:null,start:null,customerName:"",paying:false,orderingOpen:true,maxScoops:3};
  if(!x)return m;
  m.paying=!!x.paying;m.orderingOpen=x.orderingOpen!==false;m.maxScoops=x.maxScoops||3;m.customerName=x.customerName||"";m.donationCents=x.donationCents||0;
  m.screen=x.screen==="summary"?"builder":x.screen;
  if(x.screen==="summary")m.mode="summary";
  if(x.screen==="builder")m.step=x.step||"vessel";
  var listed=["builder","summary","name","confirmation"].indexOf(x.screen)>=0;
  (x.items||[]).forEach(function(it){
    var c=pjCopy(it);
    if(x.screen==="builder"&&it.current){
      m.current=c;
      if(x.editing){m.editing=c.id;m.items.push(c);}
      else if(!it.inOrder)m.start=c.vessel;
    }else if(listed)m.items.push(c);
  });
  if(m.screen==="builder"&&m.mode==="customize"&&!m.current)m.current=pjFresh(m);
  return m;
}
function pjFind(m,id){
  for(var i=0;i<m.items.length;i++)if(m.items[i].id===id)return m.items[i];
  return m.current&&m.current.id===id?m.current:null;
}
function pjIndex(m,id){for(var i=0;i<m.items.length;i++)if(m.items[i].id===id)return i;return -1;}
function pjChoices(m){var c=m.current;return !!c&&(c.flavors.length>0||c.toppings.length>0||c.vessel!==(m.start||pjDefaultVessel(m.ctx)));}
function pjCustomizing(m){return m.screen==="builder"&&m.mode==="customize";}
function pjCanViewOrder(m){return m.items.length>0||(!!m.current&&m.current.flavors.length>0);}
function pjEmptyEdit(m){return !!m.editing&&m.current.flavors.length===0;}
function pjBackToSummary(m){m.mode="summary";m.screen="builder";}
function pjBackToBuilder(m){if(m.mode!=="summary")return;m.mode="customize";m.current=pjFresh(m);m.step="vessel";}
function pjStartOrder(m){m.screen="builder";m.mode="customize";m.items=[];m.editing=null;m.customerName="";m.current=pjFresh(m);m.step="vessel";}
function pjViewOrder(m){
  if(!m.editing&&m.current.flavors.length>0)m.items.push(m.current);
  m.editing=null;m.current=null;m.mode="summary";
}
function pjStartNewItem(m){
  if(!m.editing)m.items.push(m.current);
  m.editing=null;m.current=pjFresh(m);m.step="vessel";
}
function pjEdit(m,id){
  if(m.mode==="summary")m.mode="customize";
  var item=pjFind(m,id);
  m.editing=id;m.current=item;m.step="toppings";
}
function pjTapTrayItem(m,id){
  if(m.editing){m.editing=null;}
  else if(pjCustomizing(m)&&m.current.flavors.length>0){m.items.push(m.current);}
  pjEdit(m,id);
}
function pjDelete(m,id){
  var i=pjIndex(m,id);if(i<0)return;
  m.items.splice(i,1);
  if(id===m.editing){m.editing=null;m.current=pjFresh(m);m.step="vessel";}
  if(m.mode==="summary"&&!m.items.length)pjBackToBuilder(m);
}
function pjFocus(m,id,target){
  if(m.screen==="name")pjBackToSummary(m);
  if(m.screen!=="builder")return "No order in progress";
  if(m.mode!=="customize"||m.current.id!==id){
    if(pjIndex(m,id)<0)return "That item is no longer in the order";
    if(pjEmptyEdit(m))return "The item being edited has no scoops left";
    pjTapTrayItem(m,id);
  }
  if(m.step!==target){
    if(target==="toppings"&&!m.current.flavors.length)return "Add a scoop first";
    m.step=target;
  }
  return null;
}
function pjNavigate(m,to){
  if(m.screen==="confirmation")return "This order is paid. Start over for a new one.";
  if(m.screen==="roleSetup"||m.screen==="staff")return "The kiosk isn't taking orders";
  if(to==="builder"){
    if(m.screen==="attract"){
      if(!m.orderingOpen)return "This kiosk is closed";
      pjStartOrder(m);return null;
    }
    if(m.screen==="name")pjBackToSummary(m);
    pjBackToBuilder(m);
    return null;
  }
  if(m.screen==="attract")return "No order in progress";
  if(to==="summary"){
    if(m.screen==="name"){pjBackToSummary(m);return null;}
    if(m.mode==="summary")return null;
    if(pjEmptyEdit(m))return "The item being edited has no scoops left";
    if(!pjCanViewOrder(m))return "The order is empty";
    pjViewOrder(m);return null;
  }
  if(m.screen==="name")return null;
  if(m.mode==="customize"){
    if(pjEmptyEdit(m))return "The item being edited has no scoops left";
    if(!pjCanViewOrder(m))return "The order is empty";
    pjViewOrder(m);
  }
  if(!m.items.length)return "The order is empty";
  m.screen="name";
  return null;
}
function pjOp(m,c){
  var ctx=m.ctx,why;
  switch(c.op){
    case "startOver":
      if(m.screen==="builder"||m.screen==="name"||m.screen==="confirmation"){m.screen="attract";m.mode="customize";m.items=[];m.current=null;m.editing=null;m.customerName="";return null;}
      return m.screen==="attract"?null:"The kiosk isn't taking orders";
    case "navigate":return pjNavigate(m,c.to);
    case "setName":
      if(m.screen!=="builder"&&m.screen!=="name")return "No order in progress";
      m.customerName=String(c.name||"").trim().slice(0,24);return null;
    case "addItem":
      if(m.screen==="attract")return pjNavigate(m,"builder");
      if(m.screen==="confirmation")return "This order is paid. Start over for a new one.";
      if(m.screen!=="builder"&&m.screen!=="name")return "The kiosk isn't taking orders";
      if(m.screen==="name")pjBackToSummary(m);
      if(m.mode==="summary"){pjBackToBuilder(m);return null;}
      if(pjEmptyEdit(m))return "The item being edited has no scoops left";
      if(m.editing||m.current.flavors.length>0)pjStartNewItem(m);
      else m.step="vessel";
      return null;
    case "removeItem":
      if(m.screen!=="builder"&&m.screen!=="name")return "No order in progress";
      if(pjCustomizing(m)&&m.current.id===c.item&&!m.editing){
        if(pjChoices(m)){m.current=pjFresh(m);m.step="vessel";}
        return null;
      }
      if(pjIndex(m,c.item)<0)return "That item is no longer in the order";
      if(m.screen==="name")pjBackToSummary(m);
      pjDelete(m,c.item);return null;
    case "addScoop":
      if(ctx.soldOut("flavor",c.flavor))return ctx.title("flavor",c.flavor)+" is sold out";
      if((why=pjFocus(m,c.item,"flavors")))return why;
      if(m.current.flavors.length>=m.maxScoops)return m.maxScoops+" scoops max";
      m.current.flavors.push(c.flavor);return null;
    case "removeScoop":
      if((why=pjFocus(m,c.item,"flavors")))return why;
      var at=m.current.flavors.lastIndexOf(c.flavor);
      if(at<0)return "No "+ctx.title("flavor",c.flavor)+" scoop on that item";
      m.current.flavors.splice(at,1);return null;
    case "setVessel":
      if(ctx.soldOut("vessel",c.vessel))return c.vessel==="cup"?"Cups are sold out":"Waffle cones are sold out";
      if((why=pjFocus(m,c.item,"vessel")))return why;
      m.current.vessel=c.vessel;return null;
    case "setTopping":
      if(c.on&&ctx.soldOut("topping",c.topping))return ctx.title("topping",c.topping)+" is sold out";
      if((why=pjFocus(m,c.item,"toppings")))return why;
      var has=m.current.toppings.indexOf(c.topping)>=0;
      if(c.on&&!has){if(!m.current.flavors.length)return "Couldn't change "+ctx.title("topping",c.topping);m.current.toppings.push(c.topping);}
      if(!c.on&&has)m.current.toppings=m.current.toppings.filter(function(t){return t!==c.topping;});
      return null;
  }
  return "This kiosk's app doesn't know "+c.op;
}
function pjApply(m,c){
  if(m.paying)return "Payment is in progress on the kiosk";
  var why=pjOp(m,c);
  if(!why&&c.ref&&pjCustomizing(m)&&!m.editing&&m.current&&!m.current.flavors.length&&!m.current.toppings.length&&!pjFind(m,c.ref))m.current.id=c.ref;
  return why;
}
function pjLine(it,current,inOrder){return {id:it.id,vessel:it.vessel,flavors:it.flavors.slice(),toppings:it.toppings.slice(),cents:inOrder?pjPrice(it):0,current:current,inOrder:inOrder};}
function pjView(m){
  var lines=[],screen=m.screen,step=null,editing=false;
  if(pjCustomizing(m)){
    step=m.step;editing=!!m.editing;
    m.items.forEach(function(it){lines.push(pjLine(it,it===m.current,true));});
    if(!m.editing&&pjChoices(m))lines.push(pjLine(m.current,true,true));
    if(!lines.some(function(l){return l.current;}))lines.push(pjLine(m.current,true,false));
  }else if(m.screen==="builder"||m.screen==="name"||m.screen==="confirmation"){
    if(m.screen==="builder")screen="summary";
    m.items.forEach(function(it){lines.push(pjLine(it,false,true));});
  }
  var total=0,donation=lines.some(function(l){return l.inOrder;})?m.donationCents||0:0;lines.forEach(function(l){total+=l.cents;});
  return {screen:screen,step:step,editing:editing,items:lines,customerName:m.customerName,totalCents:total+donation,donationCents:donation,paying:m.paying,orderingOpen:m.orderingOpen,maxScoops:m.maxScoops};
}
function pjProject(session,commands,ctx){
  var m=pjModel(session,ctx),failed=[];
  commands.forEach(function(c){var why=pjApply(m,c);if(why)failed.push({id:c.id,why:why});});
  return {view:pjView(m),failed:failed};
}
function pjTarget(c){return c.item||null;}
function pjAfter(pending,c){
  var item=pjTarget(c);if(!item)return [];
  for(var i=pending.length-1;i>=0;i--){var p=pending[i];if(pjTarget(p)===item||p.ref===item)return [p.id];}
  return [];
}
function pjBase(pending,seq){return pending.length?pending[0].seq-1:seq;}
function pjReconcile(pending,session,stream){
  var results={},st=null,dropped={},keep=[],rejected=null,skipped=0;
  ((session&&session.results)||[]).forEach(function(r){results[r.id]=r;});
  ((session&&session.streams)||[]).forEach(function(s){if(s.id===stream)st=s;});
  pending.forEach(function(c){
    if((c.after||[]).some(function(id){return dropped[id];})){dropped[c.id]=true;if(rejected)skipped++;return;}
    var r=results[c.id];
    if(r){if(r.status==="rejected"){dropped[c.id]=true;if(!rejected)rejected={command:c,why:r.message||""};else skipped++;}return;}
    if(st&&c.seq<=st.done)return;
    keep.push(c);
  });
  return {pending:keep,rejected:rejected,skipped:skipped,received:st?st.received:null};
}
`;

export const ASSIST_PROJECTION_EXPORTS = [
  "pjPrice",
  "pjModel",
  "pjApply",
  "pjView",
  "pjProject",
  "pjAfter",
  "pjBase",
  "pjReconcile",
] as const;
