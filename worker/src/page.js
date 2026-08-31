// 儀表板頁面。刻意做成單一字串常數：不需要打包工具，也不載入任何外部資源
// （Worker 的 CSP 是 default-src 'none'，連 CDN 都連不出去，這是故意的）。
//
// 注意：底下的頁面腳本一律用字串串接，不使用樣板字面值 —— 這整份是包在
// JS 樣板字面值裡的，頁面自己再用 ${...} 會被外層搶先解析。

export const PAGE = `<!doctype html>
<html lang="zh-Hant">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>擋廣告觀測儀表板</title>
<style>
:root{
  color-scheme:dark;
  --bg:#0f1115; --panel:#171a21; --panel2:#1c2029; --line:#262b36;
  --fg:#e6e8eb; --dim:#9aa4b2; --faint:#6b7480;
  --ok:#34d399; --block:#f87171; --other:#fbbf24; --accent:#3b82f6;
}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--fg);
  font:14px/1.6 ui-sans-serif,system-ui,-apple-system,"Noto Sans TC","Microsoft JhengHei",sans-serif}
.wrap{max-width:1180px;margin:0 auto;padding:20px 16px 56px}

header{display:flex;flex-wrap:wrap;gap:12px;align-items:baseline;justify-content:space-between;margin-bottom:18px}
h1{font-size:19px;margin:0;letter-spacing:.01em}
.sub{color:var(--faint);font-size:12px;margin-top:2px}
.hdr-actions{display:flex;gap:8px;align-items:center}

button,select,input{font:inherit;color:var(--fg)}
.btn{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:7px 13px;cursor:pointer}
.btn:hover{border-color:#39414f}
.btn.primary{background:var(--accent);border-color:var(--accent);color:#fff;font-weight:600}
.btn.primary:disabled{opacity:.55;cursor:default}
.btn.sm{padding:4px 9px;font-size:12px;border-radius:6px}

.panel{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:16px;margin-bottom:16px}
.panel h2{font-size:13px;margin:0 0 12px;color:var(--dim);font-weight:600;letter-spacing:.03em}

.controls{display:flex;flex-wrap:wrap;gap:14px;align-items:flex-end}
.field{display:flex;flex-direction:column;gap:5px}
.field label{font-size:11px;color:var(--faint);letter-spacing:.03em}
.seg{display:flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.seg button{background:var(--panel2);border:0;border-right:1px solid var(--line);padding:7px 12px;cursor:pointer;font-size:13px}
.seg button:last-child{border-right:0}
.seg button[aria-pressed="true"]{background:var(--accent);color:#fff;font-weight:600}
select,input[type=search]{background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:7px 11px}
input[type=search]{min-width:230px}
.grow{flex:1 1 230px}

/* 即時顯示目前的分析條件 */
.chips{display:flex;flex-wrap:wrap;gap:7px;align-items:center;margin-top:14px;
  padding-top:13px;border-top:1px dashed var(--line);min-height:32px}
.chips .lead{color:var(--faint);font-size:12px;margin-right:2px}
.chip{display:inline-flex;align-items:center;gap:6px;background:var(--panel2);
  border:1px solid var(--line);border-radius:999px;padding:3px 11px;font-size:12px}
.chip b{font-weight:600}
.chip.on-allow{border-color:#2a5f4a;color:var(--ok)}
.chip.on-block{border-color:#6b2b2b;color:var(--block)}
.chip.on-bucket{border-color:#2f4a75;color:#93c5fd}
.chip button{background:none;border:0;color:inherit;cursor:pointer;padding:0 0 0 2px;font-size:14px;line-height:1;opacity:.7}
.chip button:hover{opacity:1}
.chip.pending{border-style:dashed;color:var(--faint)}

.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px}
.stat{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:13px 15px}
.stat .k{font-size:11px;color:var(--faint);letter-spacing:.03em}
.stat .v{font-size:24px;font-weight:650;margin-top:3px;font-variant-numeric:tabular-nums}
.stat.ok .v{color:var(--ok)} .stat.block .v{color:var(--block)} .stat.rate .v{color:#93c5fd}

.chart-hint{font-size:11px;color:var(--faint);margin-bottom:8px}
.chart{width:100%;height:230px;display:block;touch-action:manipulation}
.chart .bar-hit{cursor:pointer;fill:transparent}
.chart .bar-hit:hover + .bar-grp rect,.chart g.sel .bar-grp rect{filter:brightness(1.35)}
.chart g.sel .bg{fill:#ffffff12}
.axis{fill:var(--faint);font-size:10px}
.legend{display:flex;gap:15px;font-size:12px;color:var(--dim);margin-top:9px;flex-wrap:wrap}
.legend i{display:inline-block;width:10px;height:10px;border-radius:2px;margin-right:5px;vertical-align:-1px}

table{width:100%;border-collapse:collapse;font-size:13px}
th{text-align:left;color:var(--faint);font-weight:600;font-size:11px;letter-spacing:.03em;
  padding:0 10px 8px;border-bottom:1px solid var(--line)}
td{padding:8px 10px;border-bottom:1px solid #1e222b;vertical-align:top}
tr:last-child td{border-bottom:0}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.dom{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:12.5px;word-break:break-all}
.dom button{background:none;border:0;color:inherit;cursor:pointer;padding:0;font:inherit;text-align:left}
.dom button:hover{color:#93c5fd;text-decoration:underline}
.tag{display:inline-block;font-size:10.5px;padding:1px 7px;border-radius:999px;border:1px solid;margin-right:4px}
.tag.a{color:var(--ok);border-color:#2a5f4a} .tag.b{color:var(--block);border-color:#6b2b2b}
.tag.o{color:var(--other);border-color:#6b5524}
.pol{color:var(--faint);font-size:11px;margin-top:2px}
.scroll{overflow-x:auto}

.msg{padding:26px 10px;text-align:center;color:var(--faint);font-size:13px}
.msg.err{color:var(--block)}
.spin{opacity:.5;pointer-events:none}
.warn{background:#2a2113;border:1px solid #6b5524;color:#fcd34d;border-radius:8px;
  padding:9px 12px;font-size:12px;margin-bottom:14px}
code{background:var(--panel2);padding:1px 5px;border-radius:4px;font-size:12px}
</style>
</head>
<body>
<div class="wrap">

<header>
  <div>
    <h1>擋廣告觀測儀表板</h1>
    <div class="sub" id="sub">載入中…</div>
  </div>
  <div class="hdr-actions">
    <label class="chip" style="cursor:pointer">
      <input type="checkbox" id="auto" style="margin:0"> 每 60 秒自動更新
    </label>
    <button class="btn primary" id="refresh">重新整理</button>
  </div>
</header>

<div class="panel">
  <h2>分析條件</h2>
  <div class="controls">
    <div class="field">
      <label>時間範圍</label>
      <div class="seg" id="range">
        <button data-v="1h">1 小時</button>
        <button data-v="6h">6 小時</button>
        <button data-v="24h" aria-pressed="true">24 小時</button>
        <button data-v="7d">7 天</button>
      </div>
    </div>
    <div class="field">
      <label>放行結果</label>
      <div class="seg" id="decision">
        <button data-v="all" aria-pressed="true">全部</button>
        <button data-v="allowed">僅允許通過</button>
        <button data-v="blocked">僅拒絕通過</button>
      </div>
    </div>
    <div class="field grow">
      <label>搜尋網域（子字串比對）</label>
      <input type="search" id="q" placeholder="例如 doubleclick、googleads、.tw" autocomplete="off">
    </div>
  </div>
  <div class="chips" id="chips"></div>
</div>

<div id="warn"></div>

<div class="panel">
  <h2>統計</h2>
  <div class="stats" id="stats"></div>
</div>

<div class="panel">
  <h2>查詢量趨勢</h2>
  <div class="chart-hint">點一下任何一根柱子，可以把下方明細縮到那個時間區間；再點一次取消。</div>
  <svg class="chart" id="chart" role="img" aria-label="DNS 查詢量時間分佈"></svg>
  <div class="legend">
    <span><i style="background:#34d399"></i>允許通過</span>
    <span><i style="background:#f87171"></i>拒絕通過</span>
    <span><i style="background:#fbbf24"></i>其他／未歸類</span>
  </div>
</div>

<div class="panel">
  <h2>網域明細 <span id="detail-scope" style="color:var(--faint);font-weight:400"></span></h2>
  <div class="scroll"><table>
    <thead><tr>
      <th style="width:52%">網域</th><th class="num">總計</th>
      <th class="num">允許</th><th class="num">拒絕</th><th>判定</th>
    </tr></thead>
    <tbody id="rows"></tbody>
  </table></div>
</div>

<div class="panel">
  <h2>同步狀態</h2>
  <div id="status" class="msg">載入中…</div>
</div>

</div>
<script>
(function(){
  "use strict";

  var state = { range:"24h", decision:"all", q:"", bucket:"", data:null, busy:false };
  var timer = null, debounce = null;

  var $ = function(id){ return document.getElementById(id); };
  var fmt = function(n){ return (n||0).toLocaleString("zh-Hant"); };

  function esc(s){
    return String(s == null ? "" : s).replace(/[&<>"']/g, function(c){
      return {"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c];
    });
  }

  // 依目前的分組粒度決定時間怎麼顯示
  function tlabel(ts, step){
    var d = new Date(ts);
    if (isNaN(d)) return ts;
    if (step >= 86400000) return (d.getMonth()+1) + "/" + d.getDate();
    var hh = String(d.getHours()).padStart(2,"0");
    var mm = String(d.getMinutes()).padStart(2,"0");
    return hh + ":" + mm;
  }
  function tfull(ts){
    var d = new Date(ts);
    return isNaN(d) ? ts : d.toLocaleString("zh-Hant");
  }

  // ── 即時顯示目前的分析條件 ───────────────────────────
  // pending=true 代表輸入框已經改了但還沒送出查詢，用虛線框表示「尚未套用」。
  function renderChips(){
    var rl = { "1h":"近 1 小時", "6h":"近 6 小時", "24h":"近 24 小時", "7d":"近 7 天" }[state.range];
    var typed = $("q").value.trim();
    var pending = typed !== state.q;
    var h = '<span class="lead">目前分析：</span>';
    h += '<span class="chip"><b>' + esc(rl) + '</b></span>';

    if (state.decision === "allowed")      h += '<span class="chip on-allow">僅<b>允許通過</b><button data-clear="decision" title="改回全部">×</button></span>';
    else if (state.decision === "blocked") h += '<span class="chip on-block">僅<b>拒絕通過</b><button data-clear="decision" title="改回全部">×</button></span>';
    else h += '<span class="chip">允許與拒絕<b>全部</b></span>';

    if (state.q) h += '<span class="chip">網域含 <b>' + esc(state.q) + '</b><button data-clear="q" title="清除搜尋">×</button></span>';
    if (pending) h += '<span class="chip pending">待套用：' + (typed ? '網域含 ' + esc(typed) : '清除搜尋') + '</span>';

    if (state.bucket && state.data){
      h += '<span class="chip on-bucket">明細限於 <b>' + esc(tfull(state.bucket)) + '</b><button data-clear="bucket" title="取消時間區間">×</button></span>';
    }
    if (state.busy) h += '<span class="chip pending">查詢中…</span>';
    $("chips").innerHTML = h;
  }

  // ── 柱狀圖（手繪 SVG，所以可以點）────────────────────
  function renderChart(){
    var svg = $("chart");
    var d = state.data;
    svg.innerHTML = "";
    if (!d || !d.series.length){
      svg.innerHTML = '<text x="50%" y="50%" text-anchor="middle" class="axis">這個範圍內沒有查詢記錄</text>';
      return;
    }
    var W = svg.clientWidth || 900, H = 230, padB = 24, padT = 10, padL = 44;
    svg.setAttribute("viewBox", "0 0 " + W + " " + H);

    var s = d.series;
    var max = 0;
    for (var i=0;i<s.length;i++) max = Math.max(max, s[i].allowed + s[i].blocked + s[i].other);
    if (max <= 0) max = 1;

    var plotW = W - padL - 8, plotH = H - padB - padT;
    var bw = plotW / s.length;
    var barW = Math.max(1, Math.min(bw - 2, 46));
    var ns = "http://www.w3.org/2000/svg";
    var frag = document.createDocumentFragment();

    // Y 軸格線
    [0, 0.5, 1].forEach(function(f){
      var y = padT + plotH - plotH*f;
      var ln = document.createElementNS(ns,"line");
      ln.setAttribute("x1",padL); ln.setAttribute("x2",W-8);
      ln.setAttribute("y1",y); ln.setAttribute("y2",y);
      ln.setAttribute("stroke","#262b36"); frag.appendChild(ln);
      var tx = document.createElementNS(ns,"text");
      tx.setAttribute("x",padL-7); tx.setAttribute("y",y+3);
      tx.setAttribute("text-anchor","end"); tx.setAttribute("class","axis");
      tx.textContent = fmt(Math.round(max*f)); frag.appendChild(tx);
    });

    var labelEvery = Math.ceil(s.length / Math.max(4, Math.floor(W/90)));

    s.forEach(function(b, i){
      var x = padL + i*bw + (bw-barW)/2;
      var g = document.createElementNS(ns,"g");
      if (state.bucket === b.ts) g.setAttribute("class","sel");

      var bg = document.createElementNS(ns,"rect");
      bg.setAttribute("class","bg");
      bg.setAttribute("x", padL + i*bw); bg.setAttribute("y", padT);
      bg.setAttribute("width", bw); bg.setAttribute("height", plotH);
      bg.setAttribute("fill","transparent");
      g.appendChild(bg);

      var grp = document.createElementNS(ns,"g");
      grp.setAttribute("class","bar-grp");
      var y = padT + plotH;
      [["other", b.other, "#fbbf24"], ["blocked", b.blocked, "#f87171"], ["allowed", b.allowed, "#34d399"]].forEach(function(p){
        if (!p[1]) return;
        var h = (p[1]/max)*plotH;
        y -= h;
        var r = document.createElementNS(ns,"rect");
        r.setAttribute("x",x); r.setAttribute("y",y);
        r.setAttribute("width",barW); r.setAttribute("height",Math.max(1,h));
        r.setAttribute("fill",p[2]);
        grp.appendChild(r);
      });

      // 透明的點擊區蓋滿整欄，柱子很矮時也點得到
      var hit = document.createElementNS(ns,"rect");
      hit.setAttribute("class","bar-hit");
      hit.setAttribute("x", padL + i*bw); hit.setAttribute("y", padT);
      hit.setAttribute("width", bw); hit.setAttribute("height", plotH);
      hit.addEventListener("click", function(){
        state.bucket = (state.bucket === b.ts) ? "" : b.ts;
        load();
      });
      var ti = document.createElementNS(ns,"title");
      ti.textContent = tfull(b.ts) + "\\n允許 " + fmt(b.allowed) + "　拒絕 " + fmt(b.blocked)
        + (b.other ? "　其他 " + fmt(b.other) : "") + "\\n（點擊可鎖定這個時間區間）";
      hit.appendChild(ti);

      g.appendChild(hit);
      g.appendChild(grp);

      if (i % labelEvery === 0){
        var lb = document.createElementNS(ns,"text");
        lb.setAttribute("x", padL + i*bw + bw/2); lb.setAttribute("y", H-8);
        lb.setAttribute("text-anchor","middle"); lb.setAttribute("class","axis");
        lb.textContent = tlabel(b.ts, d.window.stepMs);
        g.appendChild(lb);
      }
      frag.appendChild(g);
    });
    svg.appendChild(frag);
  }

  function renderStats(){
    var t = state.data ? state.data.totals : {allowed:0,blocked:0,other:0};
    var total = t.allowed + t.blocked + t.other;
    var rate = total ? (t.blocked/total*100) : 0;
    var cards = [
      ["總查詢數", fmt(total), ""],
      ["允許通過", fmt(t.allowed), "ok"],
      ["拒絕通過", fmt(t.blocked), "block"],
      ["封鎖率", rate.toFixed(1) + "%", "rate"]
    ];
    if (t.other) cards.push(["其他／未歸類", fmt(t.other), ""]);
    $("stats").innerHTML = cards.map(function(c){
      return '<div class="stat ' + c[2] + '"><div class="k">' + c[0] + '</div><div class="v">' + c[1] + '</div></div>';
    }).join("");
  }

  function renderRows(){
    var d = state.data;
    var tb = $("rows");
    $("detail-scope").textContent = state.bucket ? "（限於 " + tfull(state.bucket) + "）" : "（整個時間範圍）";
    if (!d || !d.topDomains.length){
      tb.innerHTML = '<tr><td colspan="5" class="msg">沒有符合條件的網域</td></tr>';
      return;
    }
    tb.innerHTML = d.topDomains.map(function(r){
      var tags = "";
      if (r.allowed) tags += '<span class="tag a">允許</span>';
      if (r.blocked) tags += '<span class="tag b">拒絕</span>';
      if (r.other)   tags += '<span class="tag o">其他 ' + esc(r.codes.join("/")) + '</span>';
      var pol = r.policies.length ? '<div class="pol">' + esc(r.policies.join("、")) + '</div>' : "";
      return '<tr><td class="dom"><button data-dom="' + esc(r.domain) + '" title="以這個網域搜尋">'
        + esc(r.domain) + '</button>' + pol + '</td>'
        + '<td class="num">' + fmt(r.total) + '</td>'
        + '<td class="num" style="color:var(--ok)">' + (r.allowed ? fmt(r.allowed) : "—") + '</td>'
        + '<td class="num" style="color:var(--block)">' + (r.blocked ? fmt(r.blocked) : "—") + '</td>'
        + '<td>' + tags + '</td></tr>';
    }).join("");
  }

  function renderWarn(){
    var d = state.data, h = "";
    if (d && d.totals.other > 0){
      h = '<div class="warn">有 ' + fmt(d.totals.other) + ' 筆查詢的判定代碼還沒有被歸類成允許或拒絕，'
        + '在圖表與統計中以「其他」單獨呈現，<b>沒有</b>被算進允許或拒絕。'
        + '在下方明細的「判定」欄可以看到實際的代碼，對照它的政策名稱就能確定該歸哪一邊。</div>';
    }
    $("warn").innerHTML = h;
  }

  function render(){
    renderChips(); renderWarn(); renderStats(); renderChart(); renderRows();
    if (state.data){
      $("sub").textContent = "資料時間 " + tfull(state.data.generatedAt)
        + "　·　" + state.data.filters.rangeLabel + "　·　共 " + fmt(state.data.topDomains.length) + " 個網域";
    }
  }

  function load(){
    if (state.busy) return;
    state.busy = true;
    $("refresh").disabled = true;
    renderChips();
    document.querySelectorAll(".panel").forEach(function(p){ p.classList.add("spin"); });

    var u = "/api/data?range=" + encodeURIComponent(state.range)
      + "&decision=" + encodeURIComponent(state.decision)
      + "&q=" + encodeURIComponent(state.q)
      + "&bucket=" + encodeURIComponent(state.bucket);

    fetch(u, { headers:{ "Accept":"application/json" } })
      .then(function(r){ return r.json().then(function(j){ return { ok:r.ok, j:j }; }); })
      .then(function(res){
        if (!res.ok) throw new Error(res.j && res.j.error ? res.j.error : "查詢失敗");
        state.data = res.j;
        render();
      })
      .catch(function(e){
        $("stats").innerHTML = "";
        $("rows").innerHTML = '<tr><td colspan="5" class="msg err">' + esc(e.message) + '</td></tr>';
        $("warn").innerHTML = '<div class="warn">查詢失敗：' + esc(e.message)
          + '<br>如果訊息提到權限，多半是 API Token 缺少 <code>Account Analytics: Read</code>。</div>';
      })
      .finally(function(){
        state.busy = false;
        $("refresh").disabled = false;
        document.querySelectorAll(".panel").forEach(function(p){ p.classList.remove("spin"); });
        renderChips();
      });
  }

  function loadStatus(){
    fetch("/api/status").then(function(r){ return r.json(); }).then(function(s){
      var h = "";
      if (s.sync && s.sync.length){
        h += '<div class="scroll"><table><thead><tr><th>時間</th><th>結果</th>'
          + '<th class="num">合併</th><th class="num">上傳</th><th class="num">原生分類扣除</th></tr></thead><tbody>';
        h += s.sync.map(function(r){
          return '<tr><td>' + esc(new Date(r.run_at*1000).toLocaleString("zh-Hant")) + '</td>'
            + '<td>' + (r.status === "success" ? '<span class="tag a">成功</span>' : '<span class="tag b">' + esc(r.status) + '</span>') + '</td>'
            + '<td class="num">' + fmt(r.total_merged) + '</td>'
            + '<td class="num">' + fmt(r.total_uploaded) + '</td>'
            + '<td class="num">' + fmt(r.total_excluded_by_native_category) + '</td></tr>';
        }).join("") + "</tbody></table></div>";
      }
      if (s.kv){
        h += '<div class="pol" style="margin-top:10px">KV 分類快取快照：'
          + (s.kv.present ? fmt(Math.round(s.kv.bytes/1024)) + " KiB" : "不存在") + '</div>';
      }
      if (s.errors && s.errors.length){
        h += '<div class="pol" style="margin-top:6px">' + esc(s.errors.join("　")) + '</div>';
      }
      $("status").innerHTML = h || '<div class="msg">沒有同步記錄</div>';
      $("status").className = "";
    }).catch(function(e){
      $("status").className = "msg err";
      $("status").textContent = "讀取同步狀態失敗：" + e.message;
    });
  }

  // ── 事件 ─────────────────────────────────────────────
  function seg(id, key){
    $(id).addEventListener("click", function(e){
      var b = e.target.closest("button[data-v]");
      if (!b) return;
      state[key] = b.dataset.v;
      // 換時間範圍會讓原本選定的時間桶失去意義，一併清掉
      if (key === "range") state.bucket = "";
      Array.prototype.forEach.call(this.querySelectorAll("button"), function(x){
        x.setAttribute("aria-pressed", x === b ? "true" : "false");
      });
      load();
    });
  }
  seg("range","range");
  seg("decision","decision");

  // 邊打字邊更新「目前分析」的顯示，但查詢本身要等停手 400ms 才送出
  $("q").addEventListener("input", function(){
    renderChips();
    clearTimeout(debounce);
    debounce = setTimeout(function(){
      var v = $("q").value.trim();
      if (v === state.q) { renderChips(); return; }
      state.q = v; state.bucket = "";
      load();
    }, 400);
  });
  $("q").addEventListener("keydown", function(e){
    if (e.key === "Enter"){ clearTimeout(debounce); state.q = this.value.trim(); state.bucket=""; load(); }
  });

  $("chips").addEventListener("click", function(e){
    var b = e.target.closest("button[data-clear]");
    if (!b) return;
    var k = b.dataset.clear;
    if (k === "decision"){
      state.decision = "all";
      Array.prototype.forEach.call($("decision").querySelectorAll("button"), function(x){
        x.setAttribute("aria-pressed", x.dataset.v === "all" ? "true" : "false");
      });
    } else if (k === "q"){ state.q = ""; $("q").value = ""; }
    else if (k === "bucket"){ state.bucket = ""; }
    load();
  });

  $("rows").addEventListener("click", function(e){
    var b = e.target.closest("button[data-dom]");
    if (!b) return;
    state.q = b.dataset.dom; $("q").value = state.q; state.bucket = "";
    load();
  });

  $("refresh").addEventListener("click", function(){ load(); loadStatus(); });

  $("auto").addEventListener("change", function(){
    clearInterval(timer);
    if (this.checked) timer = setInterval(function(){ load(); loadStatus(); }, 60000);
  });

  var rt;
  window.addEventListener("resize", function(){ clearTimeout(rt); rt = setTimeout(renderChart, 150); });

  load();
  loadStatus();
})();
</script>
</body>
</html>`;
