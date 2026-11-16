/// Web scoreboard operator at http://<ipad-ip>:8080/scoreboard — pick the sport, score by the rules,
/// rename teams, put the board on air, undo/redo. Buttons come from the rules engine (/api/scoreboard),
/// so every sport works without page changes. Works on any phone / laptop in the same LAN.
enum ScoreboardRemotePage {
    static let html = #"""
<!doctype html><html lang="vi"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">
<title>DTDStudio · Bảng tỉ số</title>
<style>
:root{color-scheme:dark;--acc:#FFC700}
*{box-sizing:border-box}body{font:15px -apple-system,system-ui,sans-serif;margin:0;background:#0f1013;color:#eee;-webkit-user-select:none;user-select:none}
header{padding:10px 12px;background:#1b1b1f;display:flex;gap:8px;align-items:center;position:sticky;top:0;z-index:2;flex-wrap:wrap}
a{color:#aaa}select,input{font:inherit;padding:8px;border-radius:8px;border:1px solid #333;background:#1b1b1f;color:#eee;min-width:0}
button{font:inherit;padding:10px 12px;border-radius:10px;border:1px solid #333;background:#26262b;color:#eee;touch-action:manipulation}
button:disabled{opacity:.35}button.primary{background:#1f5fbf;border-color:#2f72d6;font-weight:600;min-height:64px;font-size:17px}
button.destructive{background:#5a1a1d;border-color:#8a2a2e}button.air{background:#b3141c;border-color:#e3343c;font-weight:700}
.sb{margin:12px;background:#14161c;border-radius:10px;overflow:hidden}
.sbh{display:flex;gap:8px;align-items:center;background:#000a;padding:6px 10px;font-size:12px}
.sbh .t{color:var(--acc);font-weight:700}.sbh .ck{margin-left:auto;background:var(--acc);color:#000;font-weight:700;padding:1px 8px;border-radius:4px;font-variant-numeric:tabular-nums}
.r{display:flex;align-items:center;gap:8px;height:46px}.r .bar{width:6px;align-self:stretch}
.r .n{flex:1;font-weight:700;font-size:16px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;display:flex;gap:6px;align-items:center}
.dot{width:9px;height:9px;border-radius:50%;background:var(--acc);flex:none}
.bd{font-size:11px;padding:1px 5px;border-radius:4px;background:#ffffff26}.bd.warning{background:#ff9500cc}.bd.danger{background:#ff3b30}
.bd.highlight{background:var(--acc);color:#000}.bd.yellowCard{background:#ffd60a;color:#000}.bd.redCard{background:#ff3b30}
.c{width:30px;text-align:center;color:#fffb;font-variant-numeric:tabular-nums}.m{width:58px;height:46px;display:flex;align-items:center;justify-content:center;background:#fff;color:#000;font-size:24px;font-weight:800}
.m.win{background:var(--acc)}.co{background:var(--acc);color:#000;font-weight:800;padding:5px 10px;font-size:13px}.de{color:#fffb;padding:4px 10px;font-size:13px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(120px,1fr));gap:8px;padding:0 12px 10px}
.sides{display:grid;grid-template-columns:1fr 1fr;gap:10px;padding:0 12px}.side{display:grid;gap:8px;align-content:start}
.side h3{margin:4px 0;font-size:14px;display:flex;gap:6px;align-items:center}.sw{width:12px;height:12px;border-radius:3px}
.teams{display:grid;grid-template-columns:1fr 1fr;gap:8px;padding:10px 12px}
.foot{display:flex;gap:8px;padding:14px 12px 30px;flex-wrap:wrap}
.free{display:flex;gap:10px;align-items:center;justify-content:center;padding:12px}.free b{font-size:28px;min-width:40px;text-align:center}
#msg{color:#ff9500;font-size:13px;padding:0 12px}
.dlg{position:fixed;inset:0;background:#000b;display:flex;align-items:flex-end;justify-content:center;z-index:9}
.dlg[hidden]{display:none}.box{background:#1d1e24;width:100%;max-width:520px;border-radius:16px 16px 0 0;padding:16px;display:grid;gap:10px}
.box b{font-size:16px}.chips{display:flex;flex-wrap:wrap;gap:8px}.chips button{background:#2d3140}
.btns{display:grid;grid-template-columns:1fr 1fr;gap:8px}
</style></head><body>
<header><b>Bảng tỉ số</b>
 <select id="tpl" onchange="setTpl(this.value)"></select>
 <button id="airBtn" onclick="air()">Lên sóng</button>
 <a href="/" style="margin-left:auto">← Remote</a></header>
<div id="board"></div>
<div id="msg"></div>
<div class="teams"><input id="home" placeholder="Đội nhà" onchange="teams()"><input id="away" placeholder="Đội khách" onchange="teams()"></div>
<div class="grid" id="shared"></div>
<div class="sides" id="sides"></div>
<div class="foot">
 <button onclick="act('/api/scoreboard/undo')" id="undo">↶ Hoàn tác</button>
 <button onclick="act('/api/scoreboard/redo')" id="redo">↷ Làm lại</button>
 <button class="destructive" onclick="restart()">Trận mới</button>
</div>
<!-- in-page dialog: window.prompt/confirm are blocked in Zalo / Facebook / Messenger browsers -->
<div class="dlg" id="dlg" hidden onclick="if(event.target===this)dlgDone(null)"><div class="box">
 <b id="dlgT"></b><div class="chips" id="dlgC"></div>
 <input id="dlgI" placeholder="Tên / số áo" autocomplete="off" onkeydown="if(event.key==='Enter')dlgDone(dlgI.value)">
 <div class="btns"><button onclick="dlgDone(null)">Huỷ</button><button class="primary" style="min-height:44px" id="dlgOK" onclick="dlgDone(dlgI.value)">OK</button></div>
</div></div>
<script>
// access key from the link (…/?key=…): added to every request and link on this page
const KEY=new URLSearchParams(location.search).get('key')||'';
const _fetch=window.fetch.bind(window);
window.fetch=(u,o)=>_fetch(u+(String(u).includes('?')?'&':'?')+'key='+encodeURIComponent(KEY),o);
document.querySelectorAll('a[href^="/"]').forEach(a=>a.href=a.getAttribute('href')+'?key='+encodeURIComponent(KEY));
let S={},busy=false,CTL=[],dlgCB=null;
function ask(title,choices,input){ return new Promise(res=>{ dlgCB=res; dlgT.textContent=title;
 dlgC.innerHTML=''; (choices||[]).forEach(c=>{ const b=document.createElement('button'); b.textContent=c; b.onclick=()=>dlgDone(c); dlgC.appendChild(b); });
 dlgI.style.display=input?'':'none'; dlgI.value=''; dlg.hidden=false; if(input)setTimeout(()=>dlgI.focus(),50); }); }
function dlgDone(v){ dlg.hidden=true; const cb=dlgCB; dlgCB=null; if(cb)cb(v); }
async function restart(){ if(await ask('Bắt đầu lại trận với cùng luật?',[],false)!==null)act('/api/scoreboard/restart'); }
const E=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
async function load(){ if(busy)return; try{ S=await (await fetch('/api/scoreboard')).json(); draw(); msg.textContent=''; }catch(e){ msg.textContent='Mất kết nối tới DTDStudio…'; } }
async function act(u){ busy=true; try{ S=await (await fetch(u,{method:'POST'})).json(); draw(); }catch(e){ msg.textContent='Không gửi được lệnh'; } busy=false; }
function q(o){return Object.entries(o).map(([k,v])=>k+'='+encodeURIComponent(v)).join('&')}
function setTpl(v){act('/api/scoreboard/template?'+q({t:v}))}
function teams(){act('/api/scoreboard/teams?'+q({home:home.value,away:away.value}))}
function air(){act('/api/scoreboard/show?on='+(S.visible?0:1))}
async function ctl(i){ const c=CTL[i]; if(!c||!c.enabled)return; let p='';
 if(c.prompt){ p=await ask(c.title+' — '+c.prompt,c.choices||[],true); if(p===null)return; }
 if(navigator.vibrate)navigator.vibrate(15); act('/api/scoreboard/action?'+q({id:c.id,input:p})); }
function draw(){
 if(!tpl.options.length){ const g={}; (S.templates||[]).forEach(t=>(g[t.group]=g[t.group]||[]).push(t));
  tpl.innerHTML='<option value="">Tự do (+/−)</option>'+Object.entries(g).map(([k,a])=>`<optgroup label="${E(k)}">`+a.map(t=>`<option value="${t.id}">${E(t.title)}</option>`).join('')+'</optgroup>').join(''); }
 tpl.value=S.template||'';
 airBtn.textContent=S.visible?'● Trên sóng':'Lên sóng'; airBtn.className=S.visible?'air':'';
 if(document.activeElement!==home)home.value=S.home||''; if(document.activeElement!==away)away.value=S.away||'';
 undo.disabled=!S.canUndo; redo.disabled=!S.canRedo;
 const d=S.display;
 if(!d){ // free scoring
  board.innerHTML=`<div class="sb"><div class="sbh"><span class="t">TỰ DO</span><span>${E(S.period)}</span>${S.clock?`<span class="ck">${E(S.clock)}</span>`:''}</div>
   <div class="free"><button onclick="score('a',-1)">−</button><b>${S.scoreA??0}</b><button onclick="score('a',1)" class="primary">+ ${E(S.home)}</button></div>
   <div class="free"><button onclick="score('b',-1)">−</button><b>${S.scoreB??0}</b><button onclick="score('b',1)" class="primary">+ ${E(S.away)}</button></div></div>`;
  shared.innerHTML='';sides.innerHTML='';return; }
 board.innerHTML=`<div class="sb"><div class="sbh"><span class="t">${E(d.title)}</span><span>${E(d.period)}</span>${(d.headers||[]).map(h=>`<span class="c">${E(h)}</span>`).join('')}${d.clock?`<span class="ck">${E(d.clock)}</span>`:''}</div>`+
  d.rows.map(r=>`<div class="r"><span class="bar" style="background:${E(r.color)}"></span><span class="n">${E(r.name)}${r.serving?'<span class="dot"></span>':''}${r.badges.map(b=>`<span class="bd ${b.style}">${E(b.text)}</span>`).join('')}</span>${r.columns.map(c=>`<span class="c">${E(c)}</span>`).join('')}<span class="m ${r.winner?'win':''}">${E(r.main)}</span></div>`).join('')+
  (d.callout?`<div class="co">${E(d.callout)}</div>`:(d.detail?`<div class="de">${E(d.detail)}</div>`:''))+'</div>';
 const C=S.controls||[]; CTL=C; const b=c=>`<button class="${c.role}" ${c.enabled?'':'disabled'} onclick="ctl(${C.indexOf(c)})">${E(c.title)}</button>`;
 shared.innerHTML=C.filter(c=>!c.side).map(b).join('');
 sides.innerHTML=['home','away'].map((s,i)=>`<div class="side"><h3><span class="sw" style="background:${E(d.rows[i].color)}"></span>${E(d.rows[i].name)}</h3>${C.filter(c=>c.side==s).map(b).join('')}</div>`).join('');
}
function score(k,d){const v=Math.max(0,(k=='a'?S.scoreA:S.scoreB)+d);fetch('/api/score?'+k+'='+v,{method:'POST'}).then(load)}
load();setInterval(load,1000);
</script></body></html>
"""#
}
