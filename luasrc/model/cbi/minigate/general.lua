local m, s, o

-- 保存并应用后由 procd 的配置触发器重载服务（见 /etc/init.d/minigate）
m = Map("minigate", "MiniGate", "轻量级网关管理：动态域名解析（IPv4/IPv6双栈）、SSL 证书签发、反向代理和登录防护。")

-- 总开关放在最上方，新安装时不必翻到页面底部寻找
s = m:section(NamedSection, "global", "global", "全局设置")
s.anonymous = true
o = s:option(Flag, "enabled", "启用 MiniGate")
o.description = "总开关。关闭后停止 DDNS 定时任务、证书续期和反向代理；登录防护单独控制。点击「保存并应用」后生效。"
o.rmempty = false

s = m:section(NamedSection, "global", "global", "服务状态")
s.anonymous = true

o = s:option(DummyValue, "_status")
o.rawhtml = true
o.cfgvalue = function()
    local su = luci.dispatcher.build_url("admin/services/minigate/status")
    local au = luci.dispatcher.build_url("admin/services/minigate/proxy_access")
    local gu = luci.dispatcher.build_url("admin/services/minigate/geo_lookup")
    local uu = luci.dispatcher.build_url("admin/services/minigate/update_status")
    local xu = luci.dispatcher.build_url("admin/services/minigate/update_auto")
    local cu = luci.dispatcher.build_url("admin/services/minigate/update_check")
    local iu = luci.dispatcher.build_url("admin/services/minigate/update_apply")
    local du = luci.dispatcher.build_url("admin/services/minigate/uninstall")
    local services_url = luci.dispatcher.build_url("admin/services")
    return [[
<style>
.mg-wrap{display:flex;flex-direction:column;gap:16px;--mg-success:#2f9e44;--mg-info:#1971c2;--mg-warning:#f08c00;--mg-danger:#e03131;--mg-danger-solid:#c92a2a;--mg-muted:#6b7280;--mg-link:#15803d;--mg-accent:#7c3aed;--mg-surface:#fff;--mg-surface-muted:#f6f8fb;--mg-surface-alt:#f8fafc;--mg-surface-hover:#eef4ff;--mg-control:#fff;--mg-text:#1f2937;--mg-text-soft:#2f3a47;--mg-text-muted:#5f6b7a;--mg-border:#d7dce3;--mg-border-soft:#e6eaf0;--mg-code-bg:#e8edf6;--mg-shadow:0 10px 24px rgba(15,23,42,.08)}
.mg-wrap{--mg-danger-hover:#fff5f5;--mg-danger-border:#f1b8b8}
.mg-notice{padding:12px 16px;border-radius:8px;border:1px solid var(--mg-border);border-left:4px solid var(--mg-warning);background:var(--mg-surface);color:var(--mg-text);font-size:13px;line-height:1.6}
.mg-notice[hidden]{display:none}
.mg-row{display:flex;align-items:baseline;gap:8px;flex-wrap:wrap}
.mg-dot{display:inline-block;flex:0 0 auto;width:8px;height:8px;border-radius:50%;transform:translateY(-1px)}
.mg-sub{color:var(--mg-text-muted)}
.mg-warn-text{color:var(--mg-warning)}
.mg-danger-text{color:var(--mg-danger)}
.mg-uninstall-trigger{min-width:112px;min-height:38px;border:1px solid var(--mg-danger-border)!important;border-radius:6px!important;background:transparent!important;color:var(--mg-danger)!important;font-weight:600}
.mg-uninstall-trigger:hover,.mg-uninstall-trigger:focus{background:var(--mg-danger-hover)!important}
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
.mg-request-result{display:flex;flex-direction:column;gap:4px}
.mg-request-detail{font-size:11px;color:var(--mg-text-muted);line-height:1.5;white-space:normal}
.mg-ip{display:inline-block;border-radius:6px;background:var(--mg-code-bg);color:var(--mg-text);padding:2px 7px;font-family:ui-monospace,SFMono-Regular,Menlo,Monaco,Consolas,monospace;font-size:12px}
.mg-empty{padding:18px 16px;color:var(--mg-text-muted);font-size:12px}
.mg-update-body{display:flex;align-items:center;justify-content:space-between;gap:18px;padding:15px 16px;flex-wrap:wrap}
.mg-update-copy{display:flex;flex-direction:column;gap:5px;min-width:220px;flex:1}
.mg-update-version{font-size:13px;font-weight:700;color:var(--mg-text)}
.mg-update-message{font-size:12px;color:var(--mg-text-muted);line-height:1.6}
.mg-update-actions{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.mg-update-progress{height:3px;background:var(--mg-border-soft);overflow:hidden}
.mg-update-progress span{display:block;width:0;height:100%;background:var(--mg-info);transition:width .25s ease}
.mg-modal{position:fixed;inset:0;z-index:10000;display:none;align-items:center;justify-content:center;padding:20px;background:rgba(15,23,42,.58)}
.mg-modal.is-open{display:flex}
.mg-modal-dialog{display:flex;flex-direction:column;width:min(620px,100%);max-height:min(80vh,720px);border:1px solid var(--mg-border);border-radius:8px;background:var(--mg-surface);box-shadow:0 20px 48px rgba(15,23,42,.28);overflow:hidden}
.mg-modal-head{display:flex;flex-shrink:0;align-items:center;justify-content:space-between;gap:16px;padding:15px 16px;border-bottom:1px solid var(--mg-border)}
.mg-modal-title{margin:0;min-width:0;overflow-wrap:anywhere;color:var(--mg-text);font-size:15px;font-weight:700;line-height:1.4}
.mg-modal-close{display:inline-flex;align-items:center;justify-content:center;flex:0 0 44px;width:44px;height:44px;padding:0;border:0;background:transparent;color:var(--mg-text-muted);font-size:28px;line-height:1;cursor:pointer}
.mg-modal-close:hover{color:var(--mg-text);background:var(--mg-surface-hover)}
.mg-modal-notes{min-height:0;padding:16px;overflow:auto;white-space:pre-wrap;overflow-wrap:anywhere;color:var(--mg-text-soft);font-size:13px;line-height:1.7;background:var(--mg-surface-muted)}
.mg-modal-actions{display:flex;flex-shrink:0;flex-wrap:wrap;justify-content:flex-end;gap:8px;padding:14px 16px;border-top:1px solid var(--mg-border);background:var(--mg-surface)}
.mg-modal-actions button{min-height:44px}
.mg-modal button:focus{outline:2px solid var(--mg-info);outline-offset:2px}
.mg-uninstall-body{padding:16px;color:var(--mg-text-soft);font-size:13px;line-height:1.7;background:var(--mg-surface-muted)}
.mg-uninstall-body p{margin:0 0 12px}
.mg-uninstall-warning{margin-bottom:14px;padding:11px 12px;border-left:4px solid var(--mg-danger);background:var(--mg-surface);color:var(--mg-text)}
.mg-uninstall-choice{display:flex;align-items:flex-start;gap:10px;padding:12px;border:1px solid var(--mg-border);border-radius:6px;background:var(--mg-surface);color:var(--mg-text);cursor:pointer}
.mg-uninstall-choice input{flex:0 0 auto;width:18px;height:18px;margin:2px 0 0}
.mg-uninstall-detail{margin:8px 0 0;color:var(--mg-text-muted);font-size:12px}
.mg-uninstall-status{min-height:21px;margin-top:10px;color:var(--mg-danger);font-size:12px}
.mg-danger-button{border-color:var(--mg-danger-solid)!important;background:var(--mg-danger-solid)!important;color:#fff!important}
.mg-danger-button:hover{filter:brightness(.94)}
.mg-danger-button:focus{outline-color:var(--mg-danger)!important}
:root[data-darkmode="true"] .mg-wrap{--mg-success:#78c98d;--mg-info:#7db7df;--mg-warning:#d7a64a;--mg-danger:#e58a84;--mg-danger-solid:#a9504d;--mg-muted:#9aa7b3;--mg-link:#7bcf91;--mg-accent:#b69af4;--mg-surface:var(--background-color-medium,#171e26);--mg-surface-muted:var(--background-color-high,#131a22);--mg-surface-alt:var(--background-color-low,#19212a);--mg-surface-hover:#202a34;--mg-control:var(--background-color-high,#111820);--mg-text:var(--text-color-high,#d5dbe3);--mg-text-soft:var(--text-color-high,#c8d0d9);--mg-text-muted:var(--text-color-medium,#9aa7b3);--mg-border:var(--border-color-medium,rgba(148,163,184,.18));--mg-border-soft:var(--border-color-low,rgba(148,163,184,.12));--mg-code-bg:var(--background-color-low,#253142);--mg-shadow:none}
:root[data-darkmode="true"] .mg-wrap{--mg-danger-hover:rgba(229,138,132,.1);--mg-danger-border:rgba(229,138,132,.45)}
@media(prefers-color-scheme:dark){
:root:not([data-darkmode]) .mg-wrap{--mg-success:#78c98d;--mg-info:#7db7df;--mg-warning:#d7a64a;--mg-danger:#e58a84;--mg-danger-solid:#a9504d;--mg-muted:#9aa7b3;--mg-link:#7bcf91;--mg-accent:#b69af4;--mg-surface:#171e26;--mg-surface-muted:#131a22;--mg-surface-alt:#19212a;--mg-surface-hover:#202a34;--mg-control:#111820;--mg-text:#d5dbe3;--mg-text-soft:#c8d0d9;--mg-text-muted:#9aa7b3;--mg-border:rgba(148,163,184,.18);--mg-border-soft:rgba(148,163,184,.12);--mg-code-bg:#253142;--mg-shadow:none}
:root:not([data-darkmode]) .mg-wrap{--mg-danger-hover:rgba(229,138,132,.1);--mg-danger-border:rgba(229,138,132,.45)}
}
@media(max-width:900px){.mg-status-grid{grid-template-columns:1fr}.mg-card{min-height:auto}}
@media(max-width:640px){.mg-uninstall-trigger{width:100%}.mg-update-actions{width:100%}.mg-modal{padding:12px}.mg-modal-dialog{max-height:88vh}.mg-modal-actions{display:grid;grid-template-columns:1fr 1fr}.mg-modal-actions button{width:100%;min-width:0}
.mg-table{min-width:0}.mg-table thead{display:none}
.mg-table tbody tr{display:grid;grid-template-columns:minmax(0,1fr) auto;gap:4px 12px;padding:12px 14px;border-bottom:1px solid var(--mg-border-soft)}
.mg-table tbody tr:nth-child(even){background:var(--mg-surface-alt)}
.mg-table td{display:flex;align-items:center;justify-content:space-between;gap:12px;min-width:0;padding:2px 0;border:0!important;background:transparent!important;overflow-wrap:anywhere}
.mg-table td:nth-child(2){order:1;justify-content:flex-start}
.mg-table td:nth-child(1){order:2;justify-content:flex-end}
.mg-table td:nth-child(n+3){order:3;grid-column:1/-1}
.mg-table td:nth-child(3):before{content:"归属地"}
.mg-table td:nth-child(4):before{content:"最后请求"}
.mg-table td:nth-child(5):before{content:"域名"}
.mg-table td:nth-child(6):before{content:"请求次数"}
.mg-table td:before{flex:0 0 auto;color:var(--mg-text-muted)}
}
</style>

<div class="mg-wrap">
<div id="mg-disabled" class="mg-notice" role="status" hidden>MiniGate 尚未启用：勾选上方「启用 MiniGate」，再点击页面底部的「保存并应用」。</div>
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

<div id="mg-update-modal" class="mg-modal" role="dialog" aria-modal="true" aria-hidden="true" aria-labelledby="mg-update-modal-title">
<div class="mg-modal-dialog">
<div class="mg-modal-head">
<h3 id="mg-update-modal-title" class="mg-modal-title">本次更新内容</h3>
<button type="button" class="mg-modal-close" aria-label="关闭更新说明" title="关闭更新说明" onclick="mgCloseUpdateDialog()">&times;</button>
</div>
<div id="mg-update-modal-notes" class="mg-modal-notes" tabindex="0" aria-label="本次更新内容"></div>
<div class="mg-modal-actions">
<button type="button" class="cbi-button" onclick="mgCloseUpdateDialog()">取消</button>
<button type="button" id="mg-update-confirm" class="cbi-button cbi-button-apply" onclick="mgStartUpdate()">确认更新</button>
</div>
</div>
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
<div class="mg-request-detail" style="padding:10px 16px">包含被拦截的请求；结果对应最后一次请求，次数为最近日志内按 IP 汇总。已转发不代表已登录。</div>
<div id="mg-v-list" class="mg-table-wrap"><div class="mg-empty">加载中...</div></div>
</div>

<div id="mg-danger" class="mg-panel">
<div class="mg-panel-head"><div class="mg-panel-title">危险操作</div></div>
<div class="mg-update-body">
<div class="mg-update-copy">
<div class="mg-update-version">卸载 MiniGate</div>
<div class="mg-update-message">停止所有服务并移除程序；卸载时可选择是否保留配置、证书和封禁记录。</div>
</div>
<div class="mg-update-actions">
<button type="button" id="mg-uninstall-open" class="cbi-button mg-uninstall-trigger" onclick="mgOpenUninstallDialog()">卸载</button>
</div>
</div>
</div>

<div id="mg-uninstall-modal" class="mg-modal" role="dialog" aria-modal="true" aria-hidden="true" aria-labelledby="mg-uninstall-modal-title">
<div class="mg-modal-dialog">
<div class="mg-modal-head">
<h3 id="mg-uninstall-modal-title" class="mg-modal-title">卸载 MiniGate</h3>
<button type="button" id="mg-uninstall-close" class="mg-modal-close" aria-label="关闭卸载确认" title="关闭卸载确认" onclick="mgCloseUninstallDialog()">&times;</button>
</div>
<div class="mg-uninstall-body">
<p>卸载会停止动态 DNS、证书续期、反向代理和登录防护，并移除 MiniGate 的程序及 LuCI 页面。</p>
<div class="mg-uninstall-warning">由 MiniGate 提供的公网访问会立即中断。</div>
<label class="mg-uninstall-choice" for="mg-uninstall-purge">
<input type="checkbox" id="mg-uninstall-purge" onchange="mgUpdateUninstallChoice()">
<span>同时删除配置、证书、封禁记录和日志</span>
</label>
<p id="mg-uninstall-detail" class="mg-uninstall-detail">默认保留这些数据，方便以后重新安装。</p>
<div id="mg-uninstall-status" class="mg-uninstall-status" role="status" aria-live="polite"></div>
</div>
<div class="mg-modal-actions">
<button type="button" id="mg-uninstall-cancel" class="cbi-button" onclick="mgCloseUninstallDialog()">取消</button>
<button type="button" id="mg-uninstall-confirm" class="cbi-button mg-danger-button" onclick="mgStartUninstall()">确认卸载</button>
</div>
</div>
</div>
</div>

<script type="text/javascript">
var _geoCache={};
var _geoPending={};
var _visitorLimit='5';
var _visitorGen=0;
var _visitorReq=0;
var _visitorsLoading=false;
var _statusLoading=false;
var _statusLoaded=false;
try{_visitorLimit=localStorage.getItem('mgVisitorLimit')||'5';}catch(e){}
if(_visitorLimit!='5'&&_visitorLimit!='20'&&_visitorLimit!='50')_visitorLimit='5';

// LuCI 的 XHR.get 在网络错误时不会调用回调；统一回调一次，避免按钮和轮询卡住。
function mgGet(url,args,cb){
    var done=false;
    function finish(x,d){if(done)return;done=true;cb(x,d);}
    var p=XHR.get(url,args,finish);
    if(p&&typeof p.catch==='function')p.catch(function(){finish(null,null);});
}

// LuCI 把空 Lua 表编码成 {}，按空列表处理；其他非数组值视为读取失败。
function mgList(value){
    if(Array.isArray(value))return value;
    return value&&typeof value==='object'&&Object.keys(value).length===0?[]:null;
}

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
    mgGet(']] .. gu .. [[',{ip:ip},function(x,d){
        var loc=(d&&d.geo)?d.geo:'未知';
        var list=_geoPending[ip]||[];
        delete _geoPending[ip];
        if(d&&d.geo)_geoCache[ip]=loc;
        for(var i=0;i<list.length;i++)list[i](loc);
    });
}

function mgGeoHtml(loc){
    return loc?'<span style="font-size:11px">'+escHtml(loc)+'</span>':'<span style="color:'+mgColor('muted')+'">查询中...</span>';
}

function loadVisitors(force){
    if(_visitorsLoading&&!force)return;
    _visitorsLoading=true;
    var req=++_visitorReq;
    mgGet(']] .. au .. [[',{limit:_visitorLimit},function(x,d){
        if(req!==_visitorReq)return;
        _visitorsLoading=false;
        var el=document.getElementById('mg-v-list');
        var ct=document.getElementById('mg-v-count');
        var visitors=mgList(d&&d.visitors);
        if(!visitors){
            if(!el.querySelector('table'))el.innerHTML='<div class="mg-empty">访问记录读取失败，稍后自动重试</div>';
            return;
        }
        var gen=++_visitorGen;
        if(visitors.length===0){
            el.innerHTML='<div class="mg-empty">暂无访问记录</div>';
            ct.textContent='';
            return;
        }
        ct.textContent='('+visitors.length+' 个IP)';
        var h='<table class="mg-table">';
        h+='<thead><tr><th>最近结果</th><th>IP 地址</th><th>归属地</th><th>最后请求</th><th>域名</th><th>请求次数</th></tr></thead><tbody>';
        for(var i=0;i<visitors.length;i++){
            var v=visitors[i];
            var outcomes={blocked:['已拦截','danger'],forwarded:['已转发','success'],responded:['已响应','info'],error:['请求失败','warning']};
            var outcome=outcomes[v.outcome]||['结果未知','muted'];
            var status=typeof v.status==='number'?('HTTP '+v.status):'无状态码';
            var activity=typeof v.recent==='boolean'?(v.recent?'近5分钟有请求':'5分钟内无新请求'):'请求时间未知';
            h+='<tr>';
            h+='<td><div class="mg-request-result"><span class="mg-status" style="color:'+mgColor(outcome[1])+'">'+outcome[0]+'</span><span class="mg-request-detail">'+escHtml(status)+'</span></div></td>';
            h+='<td><code class="mg-ip">'+escHtml(v.ip)+'</code></td>';
            h+='<td id="geo-'+i+'">'+mgGeoHtml(_geoCache[v.ip])+'</td>';
            h+='<td style="white-space:nowrap"><div class="mg-request-result"><span>'+escHtml(fmtT(v.last_time))+'</span><span class="mg-request-detail">'+activity+'</span></div></td>';
            h+='<td>'+escHtml(v.domain)+'</td>';
            h+='<td><div class="mg-request-result"><span>总计 '+escHtml(String(v.count))+'</span>';
            if(typeof v.blocked_count==='number'&&typeof v.forwarded_count==='number'&&typeof v.other_count==='number'){
                h+='<span class="mg-request-detail">拦截 '+escHtml(String(v.blocked_count))+' · 转发 '+escHtml(String(v.forwarded_count))+' · 其他 '+escHtml(String(v.other_count))+'</span>';
            }
            h+='</div></td>';
            h+='</tr>';
        }
        h+='</tbody></table>';
        el.innerHTML=h;
        // 逐个查询未缓存的归属地（避免并发太多）；表格重绘后旧队列停止写入
        var qi=0;
        function nextGeo(){
            if(gen!==_visitorGen)return;
            while(qi<visitors.length&&_geoCache[visitors[qi].ip])qi++;
            if(qi>=visitors.length)return;
            var idx=qi;qi++;
            queryGeo(visitors[idx].ip,function(loc){
                if(gen!==_visitorGen)return;
                var ge=document.getElementById('geo-'+idx);
                if(ge)ge.innerHTML=mgGeoHtml(loc);
                setTimeout(nextGeo,150);
            });
        }
        nextGeo();
    });
}

var _updatePolling=false;
var _latestUpdate=null;
var _updateDialogOpener=null;
var _confirmedUpdate=null;
var _bodyOverflow='';
var _updateStarting=false;
var _updateStarted=false;
var _updateReloading=false;
var _uninstallDialogOpener=null;
var _uninstallStarting=false;

function mgOpenUninstallDialog(){
    if(_uninstallStarting)return;
    var modal=document.getElementById('mg-uninstall-modal');
    var purge=document.getElementById('mg-uninstall-purge');
    _uninstallDialogOpener=document.getElementById('mg-uninstall-open');
    purge.checked=false;
    document.getElementById('mg-uninstall-status').textContent='';
    mgUpdateUninstallChoice();
    modal.className='mg-modal is-open';
    modal.setAttribute('aria-hidden','false');
    _bodyOverflow=document.body.style.overflow;
    document.body.style.overflow='hidden';
    document.getElementById('mg-uninstall-confirm').focus();
}

function mgCloseUninstallDialog(){
    if(_uninstallStarting)return;
    var modal=document.getElementById('mg-uninstall-modal');
    modal.className='mg-modal';
    modal.setAttribute('aria-hidden','true');
    document.body.style.overflow=_bodyOverflow;
    if(_uninstallDialogOpener)_uninstallDialogOpener.focus();
}

function mgUpdateUninstallChoice(){
    var purge=document.getElementById('mg-uninstall-purge').checked;
    document.getElementById('mg-uninstall-detail').textContent=purge
        ?'配置、证书、封禁记录和日志将一并删除，无法恢复。'
        :'默认保留这些数据，方便以后重新安装。';
    document.getElementById('mg-uninstall-confirm').textContent=purge?'彻底卸载':'确认卸载';
}

function mgStartUninstall(){
    if(_uninstallStarting)return;
    var purge=document.getElementById('mg-uninstall-purge').checked?'1':'0';
    var confirm=document.getElementById('mg-uninstall-confirm');
    var status=document.getElementById('mg-uninstall-status');
    _uninstallStarting=true;
    confirm.disabled=true;
    document.getElementById('mg-uninstall-purge').disabled=true;
    document.getElementById('mg-uninstall-cancel').disabled=true;
    document.getElementById('mg-uninstall-close').disabled=true;
    status.textContent='正在启动卸载任务...';
    XHR.post(']] .. du .. [[',{confirm:'uninstall-minigate',purge:purge},function(x,d){
        if(!d||!d.success){
            _uninstallStarting=false;
            confirm.disabled=false;
            document.getElementById('mg-uninstall-purge').disabled=false;
            document.getElementById('mg-uninstall-cancel').disabled=false;
            document.getElementById('mg-uninstall-close').disabled=false;
            status.textContent=(d&&d.message)||'无法启动卸载任务';
            return;
        }
        confirm.textContent='卸载中...';
        status.textContent='正在移除 MiniGate，完成后将返回服务页面。';
        setTimeout(function(){location.href=']] .. services_url .. [[';},3000);
    });
}

function mgRenderUpdate(d){
    if(!d)return;
    _latestUpdate=d;
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
    document.getElementById('mg-uninstall-open').disabled=!!d.running;
    apply.style.display=d.available?'inline-block':'none';
    if(d.running&&!_updatePolling){
        _updatePolling=true;
        setTimeout(mgLoadUpdate,1200);
    }else if(!d.running){
        _updatePolling=false;
    }
    if(d.status=='success'&&_updateStarted&&!_updateReloading){
        _updateReloading=true;
        setTimeout(function(){location.reload()},3500);
    }
}

function mgLoadUpdate(){
    var keepPolling=_updatePolling;
    mgGet(']] .. uu .. [[',null,function(x,d){
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
    mgGet(']] .. cu .. [[',null,function(x,d){
        check.disabled=false;
        mgRenderUpdate(d||{success:false,message:'检查失败，请稍后重试'});
    });
}

function mgAutoCheckUpdate(){
    var check=document.getElementById('mg-u-check');
    check.disabled=true;
    document.getElementById('mg-u-message').textContent='正在自动检查更新...';
    mgGet(']] .. xu .. [[',null,function(x,d){
        check.disabled=false;
        mgRenderUpdate(d||{success:false,message:'自动检查失败，可稍后手动重试'});
    });
}

function mgApplyUpdate(){
    if(!_latestUpdate||!_latestUpdate.available||!_latestUpdate.latest||_latestUpdate.running||_updateStarting||_confirmedUpdate)return;
    var modal=document.getElementById('mg-update-modal');
    var title=document.getElementById('mg-update-modal-title');
    var notes=document.getElementById('mg-update-modal-notes');
    _updateDialogOpener=document.getElementById('mg-u-apply');
    _confirmedUpdate=_latestUpdate;
    title.textContent=_latestUpdate.release_title||('更新到 v'+(_latestUpdate.latest||''));
    notes.textContent=_latestUpdate.release_notes||'GitHub Release 未提供本次更新说明。';
    modal.className='mg-modal is-open';
    modal.setAttribute('aria-hidden','false');
    _bodyOverflow=document.body.style.overflow;
    document.body.style.overflow='hidden';
    notes.focus();
}

function mgCloseUpdateDialog(){
    var modal=document.getElementById('mg-update-modal');
    modal.className='mg-modal';
    modal.setAttribute('aria-hidden','true');
    document.body.style.overflow=_bodyOverflow;
    _confirmedUpdate=null;
    if(_updateDialogOpener)_updateDialogOpener.focus();
}

function mgStartUpdate(){
    if(!_confirmedUpdate||_updateStarting)return;
    var confirmed=_confirmedUpdate;
    _updateStarting=true;
    mgCloseUpdateDialog();
    var apply=document.getElementById('mg-u-apply');
    apply.disabled=true;
    document.getElementById('mg-u-check').disabled=true;
    document.getElementById('mg-u-message').textContent='正在启动更新任务...';
    XHR.post(']] .. iu .. [[',{version:confirmed.latest},function(x,d){
        _updateStarting=false;
        if(!d||!d.success){
            confirmed.success=false;
            confirmed.message=(d&&d.message)||'无法启动更新任务';
            mgRenderUpdate(confirmed);
            return;
        }
        _updateStarted=true;
        _updatePolling=true;
        setTimeout(mgLoadUpdate,700);
    });
}

var updateModal=document.getElementById('mg-update-modal');
var uninstallModal=document.getElementById('mg-uninstall-modal');
if(updateModal){
    updateModal.onclick=function(e){if(e.target===updateModal)mgCloseUpdateDialog();};
}
if(uninstallModal){
    uninstallModal.onclick=function(e){if(e.target===uninstallModal)mgCloseUninstallDialog();};
}
document.addEventListener('keydown',function(e){
    var modal=null;
    if(updateModal&&updateModal.className.indexOf('is-open')>=0)modal=updateModal;
    else if(uninstallModal&&uninstallModal.className.indexOf('is-open')>=0)modal=uninstallModal;
    if(!modal)return;
    if(e.key==='Escape'){
        e.preventDefault();
        if(modal===updateModal)mgCloseUpdateDialog();else mgCloseUninstallDialog();
    }
    if(e.key==='Tab'){
        var items=modal.querySelectorAll('button:not([disabled]),input:not([disabled]),[tabindex="0"]');
        var first=items[0],last=items[items.length-1];
        if(!first)return;
        if(e.shiftKey&&(document.activeElement===first||!modal.contains(document.activeElement))){
            e.preventDefault();last.focus();
        }else if(!e.shiftKey&&(document.activeElement===last||!modal.contains(document.activeElement))){
            e.preventDefault();first.focus();
        }
    }
});

var limitSel=document.getElementById('mg-v-limit');
if(limitSel){
    limitSel.value=_visitorLimit;
    limitSel.onchange=function(){
        _visitorLimit=this.value;
        try{localStorage.setItem('mgVisitorLimit',_visitorLimit);}catch(e){}
        loadVisitors(true);
    };
}

function mgLoadStatus(){
    if(_statusLoading||document.hidden)return;
    _statusLoading=true;
    mgGet(']] .. su .. [[',null,function(x,d){
        _statusLoading=false;
        if(!d){
            if(!_statusLoaded){
                var failed='<span style="color:'+mgColor('danger')+'">读取失败</span>';
                document.getElementById('mg-d1').innerHTML=failed;
                document.getElementById('mg-a1').innerHTML=failed;
                document.getElementById('mg-p1').innerHTML=failed;
            }
            return;
        }
        _statusLoaded=true;
        mgRenderStatus(d);
    });
}

var MG_DDNS_STATE={ok:['\u2713 正常','success'],partial:['\u26a0 部分成功','warning'],error:['\u26a0 异常','danger'],stopped:['已停止','muted'],unknown:['未同步','muted'],disabled:['未启用','muted']};

function mgStateHtml(label,color){
    return '<span style="color:'+mgColor(color)+'">'+escHtml(label)+'</span>';
}

function mgDot(color){
    return '<span class="mg-dot" style="background:'+mgColor(color)+'"></span>';
}

function mgRenderDdns(d){
    var d1=document.getElementById('mg-d1'),d2=document.getElementById('mg-d2');
    var card=document.getElementById('mg-ddns-card');
    var list=mgList(d.ddns_list)||[];
    if(!list.length){
        d1.innerHTML=mgStateHtml('未配置','muted');d2.textContent='';
        card.style.setProperty('--accent',mgColor('muted'));
        return;
    }
    // 卡片颜色取所有已启用记录中最差的状态，任一记录异常都能看到
    var overall=MG_DDNS_STATE[d.ddns_status||'disabled']||MG_DDNS_STATE.unknown;
    card.style.setProperty('--accent',mgColor(overall[1]));
    d1.innerHTML=mgStateHtml(overall[0],overall[1]);
    var h='';
    for(var i=0;i<list.length;i++){
        var e=list[i],st=MG_DDNS_STATE[e.status]||MG_DDNS_STATE.unknown;
        var ips=[e.last_ip?'A '+e.last_ip:'',e.last_ip6?'AAAA '+e.last_ip6:''].filter(Boolean).join(' · ');
        h+='<div class="mg-row">'+mgDot(st[1])+'<strong>'+escHtml(e.domain||'--')+'</strong>'+(ips?'<span class="mg-sub">'+escHtml(ips)+'</span>':'')+'</div>';
        if(e.status_msg&&(e.status=='error'||e.status=='partial'))h+='<div class="mg-'+(e.status=='error'?'danger':'warn')+'-text">'+escHtml(e.status_msg)+'</div>';
        if(e.last_update||e.next_sync)h+='<div class="mg-sub">'+escHtml((e.last_update?'更新 '+e.last_update:'')+(e.next_sync?' · 下次 '+e.next_sync:''))+'</div>';
    }
    d2.innerHTML=h;
}

function mgCertLine(c){
    var left=typeof c.days_left==='number'?c.days_left:null;
    var color=left===null?'muted':(left<0?'danger':(left<14||c.staging?'warning':'success'));
    var when=c.expires_date?('到期 '+c.expires_date+(left===null?'':(left<0?'（已过期）':'（剩 '+left+' 天）'))):'到期时间未知';
    return '<div class="mg-row">'+mgDot(color)+'<strong>'+escHtml(c.domain)+'</strong><span class="mg-sub">'+escHtml(when)+'</span>'+(c.staging?'<span class="mg-warn-text">测试证书，浏览器不信任</span>':'')+'</div>';
}

function mgRenderCerts(d){
    var a1=document.getElementById('mg-a1'),a2=document.getElementById('mg-a2');
    var card=document.getElementById('mg-cert-card');
    var certs=mgList(d.certs)||[];
    var acme=d.acme||{};
    var label,color;
    if(certs.length){
        var expired=false,soon=false,staging=false;
        for(var i=0;i<certs.length;i++){
            var left=certs[i].days_left;
            if(typeof left==='number'&&left<0)expired=true;
            else if(typeof left==='number'&&left<14)soon=true;
            if(certs[i].staging)staging=true;
        }
        if(expired){label='\u26a0 有证书已过期';color='danger';}
        else if(soon){label='\u26a0 即将到期';color='warning';}
        else if(staging){label='\u26a0 测试证书';color='warning';}
        else{label='\u2713 有效';color='success';}
    }else if(acme.enabled=='1'){label='暂无证书';color='muted';}
    else{label='未启用';color='muted';}
    card.style.setProperty('--accent',mgColor(color));
    a1.innerHTML=mgStateHtml(label,color);
    var h='';
    for(var j=0;j<certs.length;j++)h+=mgCertLine(certs[j]);
    if(acme.result=='error'||acme.result=='partial')h+='<div class="mg-'+(acme.result=='error'?'danger':'warn')+'-text">最近一次签发：'+escHtml(acme.message)+'</div>';
    a2.innerHTML=h;
}

function mgRenderProxy(d){
    var p1=document.getElementById('mg-p1'),p2=document.getElementById('mg-p2');
    var card=document.getElementById('mg-proxy-card');
    var warnings=mgList(d.proxy_warnings)||[];
    var label,color;
    if(!d.proxy_running){label='已停止';color='muted';}
    else if(d.proxy_check=='error'){label='\u26a0 运行中，最近一次配置未生效';color='danger';}
    else if(warnings.length){label='\u26a0 运行中，有规则未生效';color='warning';}
    else{label='\u2713 运行中';color='success';}
    card.style.setProperty('--accent',mgColor(color));
    p1.innerHTML=mgStateHtml(label,color);
    var h='';
    var rules=mgList(d.proxy_rules)||[];
    for(var i=0;i<rules.length;i++){
        var r=rules[i];
        var url=r.scheme+'://'+r.domain+(r.listen_port!='443'&&r.listen_port!='80'?':'+r.listen_port:'');
        var v6tag=r.ipv6_listen=='1'?' <span class="mg-sub" style="font-size:10px">[IPv6]</span>':'';
        h+='<div><a class="mg-link" href="'+escHtml(url)+'" target="_blank" rel="noopener noreferrer">'+escHtml(url)+'</a>'+v6tag+' \u2192 '+escHtml(r.target)+'</div>';
    }
    if(!rules.length&&d.proxy_running)h='Nginx 运行中，暂无代理规则';
    if(d.proxy_check=='error'&&d.proxy_message)h+='<div class="mg-danger-text">'+escHtml(d.proxy_message)+'</div>';
    for(var k=0;k<warnings.length;k++)h+='<div class="mg-warn-text">'+escHtml(warnings[k])+'</div>';
    p2.innerHTML=h;
}

function mgRenderStatus(d){
    var notice=document.getElementById('mg-disabled');
    if(notice)notice.hidden=(d.enabled=='1');
    mgRenderDdns(d);
    mgRenderCerts(d);
    mgRenderProxy(d);
}

// 页面在后台时暂停轮询，切回前台立即刷新
mgLoadStatus();
setInterval(mgLoadStatus,6000);
loadVisitors();
setInterval(function(){if(!document.hidden)loadVisitors();},15000);
document.addEventListener('visibilitychange',function(){
    if(document.hidden)return;
    mgLoadStatus();
    loadVisitors();
});
mgAutoCheckUpdate();
</script>
]] end

return m
