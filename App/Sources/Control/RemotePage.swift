/// Web remote served at http://<ipad-ip>:8080/ — titles operator, switching, score.
/// Works on any phone/laptop browser in the same LAN (replaces a separate "title app").
enum RemotePage {
    static let html = #"""
<!doctype html><html lang="__LANG__"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DTDStudio Remote</title>
<style>
:root{color-scheme:dark}body{font:15px -apple-system,system-ui,sans-serif;margin:0;background:#111;color:#eee}
header{padding:10px 14px;background:#1b1b1f;display:flex;gap:8px;align-items:center;position:sticky;top:0}
h2{font-size:13px;text-transform:uppercase;color:#999;margin:18px 14px 6px}
.row{display:flex;flex-wrap:wrap;gap:8px;padding:0 14px}
button{font:inherit;padding:10px 14px;border-radius:8px;border:1px solid #333;background:#26262b;color:#eee}
button.pgm{background:#b3141c;border-color:#e3343c}button.pvw{background:#13702c;border-color:#2a9b48}
button.go{background:#d46a00}input,select{font:inherit;padding:8px;border-radius:6px;border:1px solid #333;background:#1b1b1f;color:#eee}
.card{background:#1b1b1f;margin:8px 14px;padding:10px;border-radius:10px;display:grid;gap:6px}
.on{outline:2px solid #e3343c}
</style></head><body>
<header><b>DTDStudio</b><span id="st" style="color:#888"></span><a id="lng" href="#" style="margin-left:auto;color:#aaa"></a></header>
<h2>Chuyển cảnh</h2>
<div class="row" id="inputs"></div>
<div class="row" style="margin-top:8px">
 <button onclick="post('/api/cut')">CUT</button><button class="go" onclick="post('/api/auto')">AUTO</button>
 <button onclick="post('/api/ftb?on='+(ftb?0:1))" id="ftb">FTB</button>
 <button onclick="post('/api/replay')">REPLAY (PVW → PLAY)</button>
</div>
<h2>Tỉ số <a href="/scoreboard" style="color:#d46a00;text-transform:none;margin-left:8px">Bảng tỉ số theo luật →</a></h2>
<div class="row">
 <button onclick="score('a',-1)">A −</button><b id="sa">0</b><button onclick="score('a',1)">A +</button>
 <button onclick="score('b',-1)">B −</button><b id="sb">0</b><button onclick="score('b',1)">B +</button>
</div>
<h2>Title</h2>
<div id="titles"></div>
<div class="card">
 <select id="nstyle"><option value="lowerThird">Lower third</option><option value="nameStrap">Tên + chức danh</option>
 <option value="fullScreen">Toàn màn hình</option><option value="ticker">Chữ chạy</option><option value="scoreBug">Tỉ số</option><option value="clock">Đồng hồ</option></select>
 <input id="n1" placeholder="Dòng 1"><input id="n2" placeholder="Dòng 2"><button onclick="addTitle()">+ Thêm title</button>
</div>
<script>
// language: ?lang= in the link, else the app's language (filled in by the server)
const LANG=((new URLSearchParams(location.search).get('lang'))||'__LANG__')==='en'?'en':'vi';
const EN={"Chuyển cảnh": "Switching", "Tỉ số": "Score", "Bảng tỉ số theo luật →": "Rules scoreboard →", "Tên + chức danh": "Name + title", "Toàn màn hình": "Full screen", "Chữ chạy": "Ticker", "Tỉ số ": "Score", "Đồng hồ": "Clock", "+ Thêm title": "+ Add title", "Dòng 1": "Line 1", "Dòng 2": "Line 2", "Ẩn": "Hide", "Hiện": "Show", "DTDStudio · Bảng tỉ số": "DTDStudio · Scoreboard", "Bảng tỉ số": "Scoreboard", "Lên sóng": "Go on air", "● Trên sóng": "● On air", "↶ Hoàn tác": "↶ Undo", "↷ Làm lại": "↷ Redo", "Trận mới": "New match", "Huỷ": "Cancel", "OK": "OK", "Tự do (+/−)": "Free (+/−)", "TỰ DO": "FREE", "Đội nhà": "Home", "Đội khách": "Away", "Tên / số áo": "Name / number", "Bắt đầu lại trận với cùng luật?": "Restart the match with the same rules?", "Mất kết nối tới DTDStudio…": "Lost connection to DTDStudio…", "Không gửi được lệnh": "Couldn't send the command", "← Remote": "← Remote"};
const T=s=>(LANG==='en'&&EN[s]!==undefined)?EN[s]:s;
document.documentElement.lang=LANG;
(function i18n(){ if(LANG!=='en')return;
 const w=document.createTreeWalker(document.body,NodeFilter.SHOW_TEXT); const ns=[]; while(w.nextNode())ns.push(w.currentNode);
 ns.forEach(n=>{ const t=n.nodeValue.trim(); if(t&&EN[t]!==undefined)n.nodeValue=n.nodeValue.replace(t,EN[t]); });
 document.querySelectorAll('[placeholder],[title]').forEach(e=>{ ['placeholder','title'].forEach(a=>{ const v=e.getAttribute(a); if(v&&EN[v]!==undefined)e.setAttribute(a,EN[v]); }); });
 if(EN[document.title]!==undefined)document.title=EN[document.title];
})();
// access key from the link (…/?key=…): added to every request and link on this page
const KEY=new URLSearchParams(location.search).get('key')||'';
const _fetch=window.fetch.bind(window);
window.fetch=(u,o)=>_fetch(u+(String(u).includes('?')?'&':'?')+'key='+encodeURIComponent(KEY)+'&lang='+LANG,o);
document.querySelectorAll('a[href^="/"]').forEach(a=>a.href=a.getAttribute('href')+'?key='+encodeURIComponent(KEY)+'&lang='+LANG);
lng.textContent=LANG==='en'?'Tiếng Việt':'English';
lng.href=location.pathname+'?key='+encodeURIComponent(KEY)+'&lang='+(LANG==='en'?'vi':'en');
let S={},ftb=false;
const STY={lowerThird:'Lower third',nameStrap:'Tên + chức danh',fullScreen:'Toàn màn hình',ticker:'Chữ chạy',scoreBug:'Tỉ số',clock:'Đồng hồ'};
async function post(u,b){await fetch(u,{method:'POST',body:b?JSON.stringify(b):undefined});refresh()}
function esc(s){return (s||'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]))}
async function refresh(){
 S=await (await fetch('/api/state')).json();ftb=S.ftb;
 st.textContent=(S.live?'● LIVE ':'')+(S.recording?'● REC':'');
 inputs.innerHTML=S.sources.map((s,i)=>`<button class="${s.program?'pgm':s.preview?'pvw':''}" onclick="post('/api/preview?input=${i+1}')" ondblclick="post('/api/take?input=${i+1}')">${i+1}. ${esc(s.name)}</button>`).join('');
 sa.textContent=S.scoreA;sb.textContent=S.scoreB;
 titles.innerHTML=S.titles.map(t=>`<div class="card ${t.visible?'on':''}"><b>${esc(T(STY[t.style]||t.style))}</b>
  <input value="${esc(t.line1)}" onchange="upd('${t.id}','line1',this.value)"><input value="${esc(t.line2)}" onchange="upd('${t.id}','line2',this.value)">
  <button onclick="post('/api/title/show?id=${t.id}&on=${t.visible?0:1}')">${T(t.visible?'Ẩn':'Hiện')}</button></div>`).join('');
}
function upd(id,k,v){const t=S.titles.find(x=>x.id==id);t[k]=v;post('/api/title',t)}
function score(k,d){const v=Math.max(0,(k=='a'?S.scoreA:S.scoreB)+d);post('/api/score?'+k+'='+v)}
function addTitle(){post('/api/title',{id:crypto.randomUUID().toUpperCase(),style:nstyle.value,line1:n1.value,line2:n2.value,
 scoreA:0,scoreB:0,period:'',accentHex:'#E30613',position:[0.05,0.75],scale:1,visible:false,tickerSpeed:120})}
refresh();setInterval(refresh,1000);
</script></body></html>
"""#
}
