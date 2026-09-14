local m, s, o
local sys = require "luci.sys"

m = Map("minigate", "MiniGate 轻网关", "轻量级网关管理：动态域名解析（IPv4/IPv6双栈）、SSL 证书签发、反向代理。")

m.on_after_commit = function(self)
    local en = self.uci:get("minigate", "global", "enabled")
    if en == "1" then
        sys.call("/etc/init.d/minigate restart >/dev/null 2>&1 &")
    else
        sys.call("/etc/init.d/minigate stop >/dev/null 2>&1 &")
    end
end

s = m:section(NamedSection, "global", "global", "服务状态")
s.anonymous = true
s:tab("status", "总览")

local su = luci.dispatcher.build_url("admin/services/minigate/status")

o = s:taboption("status", DummyValue, "_status")
o.rawhtml = true
o.cfgvalue = function()
    local su = luci.dispatcher.build_url("admin/services/minigate/status")
    local au = luci.dispatcher.build_url("admin/services/minigate/proxy_access")
    local gu = luci.dispatcher.build_url("admin/services/minigate/geo_lookup")
    local uu = luci.dispatcher.build_url("admin/services/minigate/update_status")
    local cu = luci.dispatcher.build_url("admin/services/minigate/update_check")
    local iu = luci.dispatcher.build_url("admin/services/minigate/update_apply")
    return [[
<style>
.mg-wrap{display:flex;flex-direction:column;gap:16px;--mg-success:#2f9e44;--mg-info:#1971c2;--mg-warning:#f08c00;--mg-danger:#e03131;--mg-muted:#6b7280;--mg-link:#15803d;--mg-accent:#7c3aed;--mg-surface:#fff;--mg-surface-muted:#f6f8fb;--mg-surface-alt:#f8fafc;--mg-surface-hover:#eef4ff;--mg-control:#fff;--mg-text:#1f2937;--mg-text-soft:#2f3a47;--mg-text-muted:#5f6b7a;--mg-border:#d7dce3;--mg-border-soft:#e6eaf0;--mg-code-bg:#e8edf6;--mg-shadow:0 10px 24px rgba(15,23,42,.08)}
.mg-status-grid{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:14px}
.mg-card{position:relative;min-height:154px;border-radius:8px;padding:18px 18px 16px;background:var(--mg-surface);border:1px solid var(--mg-border);box-shadow:var(--mg-shadow);overflow:hidden}
.mg-card:before{content:"";position:absolute;left:0;top:0;bottom:0;width:4px;background:var(--accent,#777)}
.mg-card-title{font-size:12px;color:var(--mg-text-muted);margin-bottom:12px}
.mg-card-state{font-size:18px;font-weight:700;margin-bottom:14px;line-height:1.25}
.mg-card-body{font-size:12px;color:var(--mg-text-soft);line-height:1.9;word-break:break-word}
.mg-card-body a,.mg-link{color:var(--mg-link);text-decoration:none}
.mg-card-body a:hover,.mg-link:hover{text-decoration:underline}
.mg-panel{border-radius:8px;background:var(--mg-surface);border:1px solid var(--mg-border);box-shadow:var(--mg-shadow);overflow:hidden}
.mg-panel-head{display:flex;justify-content:space-between;align-items:center;gap:10px;flex-wrap:wrap;padding:14px 16px;border-bottom:1px solid var(--mg-border)}
.mg-panel-title{font-size:13px;font-weight:700;color:var(--mg-text)}
.mg-count{color:var(--mg-accent);font-weight:600}
.mg-limit-label{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--mg-text-muted);white-space:nowrap}
.mg-select{height:28px;border-radius:6px;border:1px solid var(--mg-border);background:var(--mg-control);color:var(--mg-text);padding:0 8px;font-size:12px}
.mg-table-wrap{overflow-x:auto}
.mg-table{width:100%;border-collapse:collapse;min-width:760px}
.mg-table th{padding:10px 12px;color:var(--mg-text-muted);font-size:11px;font-weight:600;text-align:left;border-bottom:1px solid var(--mg-border);background:var(--mg-surface-muted)}
.mg-table td{padding:11px 12px;color:var(--mg-text);font-size:12px;border-bottom:1px solid var(--mg-border-soft);vertical-align:middle}
.mg-table tr:nth-child(even) td{background:var(--mg-surface-alt)}
.mg-table tr:hover td{background:var(--mg-surface-hover)}
.mg-status{display:inline-flex;align-items:center;gap:6px;white-space:nowrap}
.mg-dot{display:inline-block;width:7px;height:7px;border-radius:50%;background:#777}
.mg-dot.on{background:var(--mg-success);box-shadow:0 0 0 3px rgba(47,158,68,.14)}
.mg-ip{display:inline-block;border-radius:6px;background:var(--mg-code-bg);color:var(--mg-text);padding:2px 7px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12px}
.mg-empty{padding:18px 16px;color:var(--mg-text-muted);font-size:12px}
.mg-update-body{display:flex;align-items:center;justify-content:space-between;gap:18px;padding:15px 16px;flex-wrap:wrap}
.mg-update-copy{display:flex;flex-direction:column;gap:5px;min-width:220px;flex:1}
.mg-update-version{font-size:13px;font-weight:700;color:var(--mg-text)}
.mg-update-message{font-size:12px;color:var(--mg-text-muted);line-height:1.6}
.mg-update-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.mg-update-progress{height:3px;background:var(--mg-border-soft);overflow:hidden}
.mg-update-progress span{display:block;width:0;height:100%;background:var(--mg-info);transition:width .25s ease}
:root[data-darkmode="true"] .mg-wrap{--mg-success:#78c98d;--mg-info:#7db7df;--mg-warning:#d7a64a;--mg-danger:#e58a84;--mg-muted:#9aa7b3;--mg-link:#7bcf91;--mg-accent:#b69af4;--mg-surface:var(--background-color-medium,#171e26);--mg-surface-muted:var(--background-color-high,#131a22);--mg-surface-alt:var(--background-color-low,#19212a);--mg-surface-hover:#202a34;--mg-control:var(--background-color-high,#111820);--mg-text:var(--text-color-high,#d5dbe3);--mg-text-soft:var(--text-color-high,#c8d0d9);--mg-text-muted:var(--text-color-medium,#9aa7b3);--mg-border:var(--border-color-medium,rgba(148,163,184,.18));--mg-border-soft:var(--border-color-low,rgba(148,163,184,.12));--mg-code-bg:var(--background-color-low,#253142);--mg-shadow:none}
@media(prefers-color-scheme:dark){
:root:not([data-darkmode]) .mg-wrap{--mg-success:#78c98d;--mg-info:#7db7df;--mg-warning:#d7a64a;--mg-danger:#e58a84;--mg-muted:#9aa7b3;--mg-link:#7bcf91;--mg-accent:#b69af4;--mg-surface:#171e26;--mg-surface-muted:#131a22;--mg-surface-alt:#19212a;--mg-surface-hover:#202a34;--mg-control:#111820;--mg-text:#d5dbe3;--mg-text-soft:#c8d0d9;--mg-text-muted:#9aa7b3;--mg-border:rgba(148,163,184,.18);--mg-border-soft:rgba(148,163,184,.12);--mg-code-bg:#253142;--mg-shadow:none}
}
@media(max-width:900px){.mg-status-grid{grid-template-columns:1fr}.mg-card{min-height:auto}}
</style>

<div class="mg-wrap">
<div id="mg" class="mg-status-grid">
<div id="mg-ddns-card" class="mg-card" style="--accent:var(--mg-success)">
<div class="mg-card-title">动态 DNS</div>
<div id="mg-d1" class="mg-card-state">--</div>
<div id="mg-d2" class="mg-card-body"></div>
</div>
<div id="mg-cert-card" class="mg-card" style="--accent:var(--mg-info)">
<div class="mg-card-title">SSL/TLS 证书</div>
<div id="mg-a1" class="mg-card-state">--</div>
<div id="mg-a2" class="mg-card-body"></div>
</div>
<div id="mg-proxy-card" class="mg-card" style="--accent:var(--mg-warning)">
<div class="mg-card-title">反向代理</div>
<div id="mg-p1" class="mg-card-state">--</div>
<div id="mg-p2" class="mg-card-body"></div>
</div>
</div>

<div id="mg-update" class="mg-panel">
<div class="mg-panel-head"><div class="mg-panel-title">软件更新</div></div>
<div class="mg-update-body">
<div class="mg-update-copy">
<div id="mg-u-version" class="mg-update-version">当前版本 --</div>
<div id="mg-u-message" class="mg-update-message">正在读取更新状态...</div>
</div>
<div class="mg-update-actions">
<button type="button" id="mg-u-check" class="cbi-button cbi-button-reload" onclick="mgCheckUpdate()">检查更新</button>
<button type="button" id="mg-u-apply" class="cbi-button cbi-button-apply" onclick="mgApplyUpdate()" style="display:none">一键更新</button>
</div>
</div>
<div class="mg-update-progress"><span id="mg-u-progress"></span></div>
</div>

<div id="mg-visitors" class="mg-panel">
<div class="mg-panel-head">
<div class="mg-panel-title">访问记录 <span id="mg-v-count" class="mg-count"></span></div>
<label class="mg-limit-label">显示
<select id="mg-v-limit" class="mg-select">
<option value="5" selected>5</option>
<option value="20">20</option>
<option value="50">50</option>
</select>条</label>
</div>
<div id="mg-v-list" class="mg-table-wrap"><div class="mg-empty">加载中...</div></div>
</div>
</div>

<script type="text/javascript">
var _geoCache={};
var _geoPending={};
var _visitorLimit=localStorage.getItem('mgVisitorLimit')||'5';
if(_visitorLimit!='5'&&_visitorLimit!='20'&&_visitorLimit!='50')_visitorLimit='5';

function escHtml(s){
    return String(s||'').replace(/[&<>"']/g,function(c){
        return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];
    });
}

function mgColor(name){
    var root=document.querySelector('.mg-wrap');
    if(!root)return'#999';
    return getComputedStyle(root).getPropertyValue('--mg-'+name).trim()||'#999';
}

function fmtT(iso){
    if(!iso)return'--';
    var m=iso.match(/(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})/);
    return m?(m[2]+'-'+m[3]+' '+m[4]+':'+m[5]+':'+m[6]):iso;
}

function queryGeo(ip,cb){
    if(_geoCache[ip]){cb(_geoCache[ip]);return;}
    if(_geoPending[ip]){
        _geoPending[ip].push(cb);
        return;
    }
    _geoPending[ip]=[cb];
    XHR.get(']] .. gu .. [[',{ip:ip},function(x,d){
        var loc=(d&&d.geo)?d.geo:'未知';
        var list=_geoPending[ip]||[];
        delete _geoPending[ip];
        _geoCache[ip]=loc;
        for(var i=0;i<list.length;i++)list[i](loc);
    });
}

function loadVisitors(){
    XHR.get(']] .. au .. [[',{limit:_visitorLimit},function(x,d){
        var el=document.getElementById('mg-v-list');
        var ct=document.getElementById('mg-v-count');
        if(!d||!d.visitors||d.visitors.length===0){
            el.innerHTML='<div class="mg-empty">暂无访问记录</div>';
            ct.textContent='';
            return;
        }
        ct.textContent='('+d.visitors.length+' 个IP)';
        var h='<table class="mg-table">';
        h+='<thead><tr><th>状态</th><th>IP 地址</th><th>归属地</th><th>最后访问</th><th>域名</th><th>次数</th></tr></thead><tbody>';
        for(var i=0;i<d.visitors.length;i++){
            var v=d.visitors[i];
            var dot=v.online
                ?'<span class="mg-dot on" title="在线"></span>'
                :'<span class="mg-dot" title="离线"></span>';
            var stxt=v.online?'<span style="color:'+mgColor('success')+'">在线</span>':'<span style="color:'+mgColor('muted')+'">离线</span>';
            h+='<tr>';
            h+='<td><span class="mg-status">'+dot+stxt+'</span></td>';
            h+='<td><code class="mg-ip">'+escHtml(v.ip)+'</code></td>';
            h+='<td id="geo-'+i+'"><span style="color:'+mgColor('muted')+'">查询中...</span></td>';
            h+='<td style="white-space:nowrap">'+escHtml(fmtT(v.last_time))+'</td>';
            h+='<td>'+escHtml(v.domain)+'</td>';
            h+='<td>'+escHtml(v.count)+'</td>';
            h+='</tr>';
        }
        h+='</tbody></table>';
        el.innerHTML=h;
        // 逐个查询归属地（避免并发太多）
        var qi=0;
        function nextGeo(){
            if(qi>=d.visitors.length)return;
            var idx=qi;qi++;
            queryGeo(d.visitors[idx].ip,function(loc){
                var ge=document.getElementById('geo-'+idx);
                if(ge)ge.innerHTML='<span style="font-size:11px">'+escHtml(loc)+'</span>';
                setTimeout(nextGeo,150);
            });
        }
        nextGeo();
    });
}

var _updatePolling=false;
function mgRenderUpdate(d){
    if(!d)return;
    var version=document.getElementById('mg-u-version');
    var message=document.getElementById('mg-u-message');
    var check=document.getElementById('mg-u-check');
    var apply=document.getElementById('mg-u-apply');
    var progress=document.getElementById('mg-u-progress');
    var current=d.current||'--';
    version.textContent='当前版本 '+current+(d.latest?' · 最新版本 '+d.latest:'');
    message.textContent=d.message||'--';
    message.style.color=d.success===false?mgColor('danger'):(d.status=='success'?mgColor('success'):mgColor('muted'));
    progress.style.width=Math.max(0,Math.min(100,Number(d.progress)||0))+'%';
    progress.style.background=d.success===false?mgColor('danger'):(d.status=='success'?mgColor('success'):mgColor('info'));
    check.disabled=!!d.running;
    apply.disabled=!!d.running;
    apply.style.display=d.available?'inline-block':'none';
    if(d.running&&!_updatePolling){
        _updatePolling=true;
        setTimeout(mgLoadUpdate,1200);
    }else if(!d.running){
        _updatePolling=false;
    }
    if(d.status=='success')setTimeout(function(){location.reload()},3500);
}

function mgLoadUpdate(){
    var keepPolling=_updatePolling;
    XHR.get(']] .. uu .. [[',null,function(x,d){
        _updatePolling=false;
        if(d){
            mgRenderUpdate(d);
        }else if(keepPolling){
            _updatePolling=true;
            setTimeout(mgLoadUpdate,2000);
        }
    });
}

function mgCheckUpdate(){
    var check=document.getElementById('mg-u-check');
    check.disabled=true;
    document.getElementById('mg-u-message').textContent='正在连接 GitHub...';
    XHR.get(']] .. cu .. [[',null,function(x,d){
        check.disabled=false;
        mgRenderUpdate(d||{success:false,message:'检查失败，请稍后重试'});
    });
}

function mgApplyUpdate(){
    var apply=document.getElementById('mg-u-apply');
    apply.disabled=true;
    document.getElementById('mg-u-message').textContent='正在启动更新任务...';
    XHR.post(']] .. iu .. [[',{},function(x,d){
        if(!d||!d.success){
            apply.disabled=false;
            mgRenderUpdate({success:false,available:true,message:(d&&d.message)||'无法启动更新任务'});
            return;
        }
        setTimeout(mgLoadUpdate,700);
    });
}

var limitSel=document.getElementById('mg-v-limit');
if(limitSel){
    limitSel.value=_visitorLimit;
    limitSel.onchange=function(){
        _visitorLimit=this.value;
        localStorage.setItem('mgVisitorLimit',_visitorLimit);
        loadVisitors();
    };
}

XHR.poll(6,']] .. su .. [[',null,function(x,d){
if(!d)return;
var d1=document.getElementById('mg-d1'),d2=document.getElementById('mg-d2');
var card=document.getElementById('mg-ddns-card');
if(d.ddns_list&&d.ddns_list.length>0){
var e=d.ddns_list[0];
var c=e.status=='ok'?mgColor('success'):(e.status=='partial'?mgColor('warning'):(e.enabled=='1'?mgColor('danger'):mgColor('muted')));
var l=e.status=='ok'?'\u2713 \u8fd0\u884c\u4e2d':(e.status=='partial'?'\u26a0 \u90e8\u5206\u6210\u529f':(e.enabled=='1'?'\u26a0 \u5f02\u5e38':'\u672a\u542f\u7528'));
card.style.setProperty('--accent',c);
d1.innerHTML='<span style="color:'+c+'">'+l+'</span>';
var info=(e.domain||'')+'\n';
if(e.last_ip)info+='A: '+e.last_ip+'\n';
if(e.last_ip6)info+='AAAA: '+e.last_ip6+'\n';
var sm=e.status_msg||'';
if(sm){
    var dupA=e.last_ip&&sm.indexOf('A:'+e.last_ip)>=0;
    var dupAAAA=e.last_ip6&&sm.indexOf('AAAA:'+e.last_ip6)>=0;
    var onlyIpStatus=sm.replace(/A:[^;]+;?/g,'').replace(/AAAA:[^;]+;?/g,'').replace(/\s+/g,'')=='';
    if(!(onlyIpStatus&&(dupA||dupAAAA)))info+=sm+'\n';
}
if(e.last_update)info+='\u66f4\u65b0: '+e.last_update+'\n';
if(e.next_sync)info+='\u4e0b\u6b21: '+e.next_sync;
if(d.ddns_list.length>1)info+='\n(+'+(d.ddns_list.length-1)+' \u6761\u8bb0\u5f55)';
d2.innerHTML=escHtml(info).replace(/\n/g,'<br>');
}else{d1.innerHTML='<span style="color:'+mgColor('muted')+'">\u672a\u914d\u7f6e</span>';d2.textContent='';card.style.setProperty('--accent',mgColor('muted'));}

var a1=document.getElementById('mg-a1'),a2=document.getElementById('mg-a2');
if(d.acme&&d.acme.enabled=='1'){
a1.innerHTML=d.acme.status=='ok'?'<span style="color:'+mgColor('info')+'">\u2713 \u6709\u6548</span>':'<span style="color:'+mgColor('danger')+'">'+escHtml(d.acme.status)+'</span>';
a2.innerHTML=escHtml(d.acme.last_domain||'')+(d.acme.cert_expiry?'<br>\u8fc7\u671f: '+escHtml(d.acme.cert_expiry):'');
}else{a1.innerHTML='<span style="color:'+mgColor('muted')+'">\u672a\u542f\u7528</span>';a2.textContent='';}

var p1=document.getElementById('mg-p1'),p2=document.getElementById('mg-p2');
p1.innerHTML=d.proxy_running?'<span style="color:'+mgColor('warning')+'">\u2713 \u8fd0\u884c\u4e2d</span>':'<span style="color:'+mgColor('muted')+'">\u5df2\u505c\u6b62</span>';
var pinfo='';
if(d.proxy_rules&&d.proxy_rules.length>0){
for(var i=0;i<d.proxy_rules.length;i++){
var r=d.proxy_rules[i];
var url=r.scheme+'://'+r.domain+(r.listen_port!='443'&&r.listen_port!='80'?':'+r.listen_port:'');
var v6tag=r.ipv6_listen=='1'?' <span style="color:'+mgColor('info')+';font-size:10px">[IPv6]</span>':'';
pinfo+='<div><span class="mg-link">'+escHtml(url)+'</span>'+v6tag+' \u2192 '+escHtml(r.target)+'</div>';
}}else if(d.proxy_running){pinfo='Nginx \u8fd0\u884c\u4e2d';}
p2.innerHTML=pinfo;
});

loadVisitors();
setInterval(loadVisitors,15000);
mgLoadUpdate();
</script>
]] end

s = m:section(NamedSection, "global", "global", "全局设置")
s.anonymous = true
o = s:option(Flag, "enabled", "启用 MiniGate")
o.description = "总开关。关闭后停止 DDNS 定时任务、ACME 续期和反向代理。保存后立即生效。"
o.rmempty = false

o = s:option(Flag, "ipv6_listen", "反向代理监听 IPv6")
o.description = "开启后，Nginx 反向代理将同时监听 IPv4 和 IPv6 地址（listen [::]:port）。"
o.rmempty = false
o.default = "0"

return m
