local m,s,o
local ctl=require"luci.controller.minigate"

local function esc(v)
    v=tostring(v or "")
    v=v:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
    v=v:gsub('"',"&quot;"):gsub("'","&#39;")
    return v
end

-- 域名：可带 *. 前缀，每段 1-63 位字母数字或连字符，不以连字符开头或结尾
local function valid_domain(value)
    local name=tostring(value or ""):gsub("^%*%.","")
    if #name==0 or #name>253 then return false end
    local count=0
    for label in (name.."."):gmatch("([^.]*)%.") do
        if #label<1 or #label>63 or not label:match("^[%w%-]+$") or label:match("^%-") or label:match("%-$") then return false end
        count=count+1
    end
    return count>=2
end

-- 保存并应用后由 procd 的配置触发器只重新同步 DDNS，不重启反向代理和登录防护
m=Map("minigate","MiniGate - 动态DNS","支持多域名、IPv4/IPv6双栈。保存并应用后立即同步。需先在「总览」启用 MiniGate。")

s=m:section(SimpleSection); s.template="minigate/style"

s=m:section(TypedSection,"ddns","DDNS 记录")
s.anonymous=true; s.addremove=true; s.sortable=true

o=s:option(Flag,"enabled","启用"); o.rmempty=false

o=s:option(Value,"domain","域名"); o.rmempty=false; o.placeholder="*.example.com 或 home.example.com"
o.validate=function(self,value)
    if valid_domain(value) then return value end
    return nil,"域名格式不正确，例如 home.example.com 或 *.example.com"
end

o=s:option(Value,"cf_zone_id","Zone ID"); o.rmempty=false; o.placeholder="Cloudflare 区域 ID"
o.description="在 Cloudflare 域名概览页右下角「API」区域可以找到。"
o.validate=function(self,value)
    if tostring(value or ""):match("^%x+$") and #value==32 then return value end
    return nil,"Zone ID 应为 32 位十六进制字符"
end

o=s:option(Value,"cf_api_token","API 令牌"); o.rmempty=false; o.password=true
o.description="在 Cloudflare「我的个人资料 → API 令牌」创建，权限选「区域 → DNS → 编辑」，区域资源选本域名。"
o.validate=function(self,value)
    if tostring(value or ""):match("^[%w%-_]+$") then return value end
    return nil,"API 令牌只包含字母、数字、- 和 _，请检查是否复制了多余的空格"
end

-- ====== 协议版本 ======
o=s:option(ListValue,"ip_version","协议版本")
o:value("ipv4","仅 IPv4（A 记录）")
o:value("ipv6","仅 IPv6（AAAA 记录）")
o:value("dual","双栈（A + AAAA）")
o.default="ipv4"
o.description="选择更新哪种 DNS 记录。双栈模式同时更新 A 和 AAAA 记录。"

o=s:option(ListValue,"ip_source","IP 来源")
o:value("interface","从网卡获取"); o:value("url","从外部URL获取"); o.default="interface"
o.description="软路由在上级路由后面（网卡是 192.168.x.x 等内网地址）时，请选「从外部URL获取」。内网地址不会被推送到 Cloudflare。"

-- IPv4 网卡
o=s:option(ListValue,"interface","IPv4 网络接口"); o.default="wan"
local uci=require"luci.model.uci".cursor()
uci:foreach("network","interface",function(sec) if sec[".name"]~="loopback"then o:value(sec[".name"],sec[".name"])end end)
o:depends("ip_source","interface")

-- IPv4 URL
o=s:option(ListValue,"ip_url","IPv4 获取地址")
o:value("https://ddns.oray.com/checkip","ddns.oray.com（HTTPS，推荐）")
o:value("http://ip.3322.net","ip.3322.net（HTTP）")
o:value("http://members.3322.org/dyndns/getip","members.3322.org（HTTP）")
o:value("http://ns1.dnspod.net:6666","ns1.dnspod.net（HTTP）")
o.default="https://ddns.oray.com/checkip"
o.description="所选地址失败时自动尝试其他地址；旁路由/代理环境会绕过代理直连获取真实公网 IP。"
o:depends("ip_source","url")

-- IPv6 网卡
o=s:option(ListValue,"interface6","IPv6 网络接口"); o.default="wan6"
o.description="用于获取 IPv6 地址的接口（通常为 wan6）；只使用全球单播地址。"
uci:foreach("network","interface",function(sec) if sec[".name"]~="loopback"then o:value(sec[".name"],sec[".name"])end end)
o:depends({ip_source="interface",ip_version="ipv6"})
o:depends({ip_source="interface",ip_version="dual"})

-- IPv6 URL
o=s:option(ListValue,"ip_url6","IPv6 获取地址")
o:value("https://api6.ipify.org","api6.ipify.org")
o:value("https://6.ipw.cn","6.ipw.cn")
o:value("https://v6.ident.me","v6.ident.me")
o:value("https://ifconfig.co","ifconfig.co (v6)")
o:value("http://v6.66666.host:66/ip","v6.66666.host（HTTP）")
o.default="https://api6.ipify.org"
o.description="仅通过 IPv6 连接获取地址"
o:depends({ip_source="url",ip_version="ipv6"})
o:depends({ip_source="url",ip_version="dual"})

o=s:option(Value,"check_interval","检查间隔（秒）"); o.datatype="uinteger"; o.default="300"
o:value("300","5 分钟"); o:value("600","10 分钟"); o:value("1800","30 分钟"); o:value("3600","1 小时")
o.description="最少 300 秒。定时任务每 5 分钟检查一次，实际间隔按 5 分钟向上取整。"
o.validate=function(self,value)
    local n=tonumber(value)
    if n and n>=300 then return value end
    return nil,"检查间隔不能少于 300 秒"
end

-- 状态+手动同步（状态来自 /var/run，不写入配置文件）
local STATE={ok={"&#10003; 正常","mgx-ok"},partial={"&#9888; 部分成功","mgx-warn"},error={"&#10007; 异常","mgx-err"},stopped={"已停止","mgx-muted"}}
o=s:option(DummyValue,"_info","运行状态"); o.rawhtml=true
o.cfgvalue=function(self,section)
    local domain=m.uci:get("minigate",section,"domain")or""
    local st=ctl.ddns_state(domain)
    local label=STATE[st.status or ""] or {"未同步","mgx-muted"}
    local h='<span id="ss-'..section..'"><span class="'..label[2]..'">'..label[1]..'</span>'
    if st.status=="error" and (st.message or "")~="" then h=h..' <span class="mgx-err">'..esc(st.message)..'</span>' end
    if (st.ip or "")~="" then h=h..'<span class="mgx-small mgx-muted">A: '..esc(st.ip)..'</span>' end
    if (st.ip6 or "")~="" then h=h..'<span class="mgx-small mgx-info">AAAA: '..esc(st.ip6)..'</span>' end
    if (st.message or "")~="" and st.status~="error" then h=h..'<span class="mgx-small mgx-muted">'..esc(st.message)..'</span>' end
    if (st.updated or "")~="" then h=h..'<span class="mgx-small mgx-muted">更新: '..esc(st.updated)..'</span>' end
    if (st.next or "")~="" then h=h..'<span class="mgx-small mgx-muted">下次: '..esc(st.next)..'</span>' end
    h=h..'</span><br><button type="button" class="cbi-button cbi-button-action mgx-sync" onclick="doSync(\''..section..'\',this)">手动同步</button>'
    h=h..'<span id="sr-'..section..'" class="mgx-sync-result" role="status"></span>'
    return h
end

-- 最近一天 IP 变化明细
s=m:section(SimpleSection)
s.template="minigate/ddns_history"

-- 注入 JS
s=m:section(NamedSection,"global","global"); s.anonymous=true
o=s:option(DummyValue,"_js"," "); o.rawhtml=true
o.cfgvalue=function()
    local url=luci.dispatcher.build_url("admin/services/minigate/ddns_sync")
    local job=luci.dispatcher.build_url("admin/services/minigate/ddns_job")
    return[[<script type="text/javascript">
var mgFormDirty=false;
document.addEventListener('change',function(e){if(e.target&&e.target.form&&e.target.className.indexOf('mgx-')<0)mgFormDirty=true;},true);
function mgEsc(s){return String(s==null?'':s).replace(/[&<>"']/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c];});}
function mgShowState(s,d){
    var box=document.getElementById("ss-"+s);if(!box||!d)return;
    var labels={ok:['✓ 正常','mgx-ok'],partial:['⚠ 部分成功','mgx-warn'],error:['✗ 异常','mgx-err'],stopped:['已停止','mgx-muted']};
    var l=labels[d.status]||['未同步','mgx-muted'];
    var h='<span class="'+l[1]+'">'+l[0]+'</span>';
    if(d.status=='error'&&d.message)h+=' <span class="mgx-err">'+mgEsc(d.message)+'</span>';
    if(d.ip)h+='<span class="mgx-small mgx-muted">A: '+mgEsc(d.ip)+'</span>';
    if(d.ip6)h+='<span class="mgx-small mgx-info">AAAA: '+mgEsc(d.ip6)+'</span>';
    if(d.message&&d.status!='error')h+='<span class="mgx-small mgx-muted">'+mgEsc(d.message)+'</span>';
    if(d.updated)h+='<span class="mgx-small mgx-muted">更新: '+mgEsc(d.updated)+'</span>';
    if(d.next)h+='<span class="mgx-small mgx-muted">下次: '+mgEsc(d.next)+'</span>';
    box.innerHTML=h;
}
function mgRequest(method,url,args,cb){
    var done=false;
    function finish(x,d){if(done)return;done=true;cb(d);}
    var p=XHR[method](url,args,finish);
    if(p&&typeof p.catch==="function")p.catch(function(){finish(null,null)});
}
// 同步在后台进行，完成后原地更新状态，不刷新页面，表单里未保存的修改不会丢
function doSync(s,b){
    var e=document.getElementById("sr-"+s),tries=0;
    function show(cls,text){e.innerHTML='<span class="'+cls+'">'+mgEsc(text)+'</span>';}
    function done(){b.disabled=false;b.textContent="手动同步";}
    if(mgFormDirty&&!confirm("表单里有尚未保存的修改。手动同步使用已保存的配置，确定继续吗？"))return;
    b.disabled=true;b.textContent="同步中...";e.textContent="";
    function poll(){
        mgRequest('get',"]]..job..[[",{section:s},function(d){
            if(d&&d.running&&tries++<90){setTimeout(poll,2000);return;}
            done();
            if(!d){show('mgx-err',"✗ 无法读取同步结果，请稍后刷新页面");return;}
            if(d.running){show('mgx-warn',"仍在同步，请稍后刷新页面查看");return;}
            mgShowState(s,d);
            if(d.success)show('mgx-ok',"✓ 同步完成 "+[d.ip,d.ip6].filter(Boolean).join(" / "));
            else show('mgx-err',"✗ "+(d.message||"同步失败，查看日志"));
        });
    }
    mgRequest('post',"]]..url..[[",{section:s},function(d){
        if(!d||!d.success){done();show('mgx-err',"✗ "+((d&&d.message)||"请求失败，请检查网络后重试"));return;}
        setTimeout(poll,1500);
    });
}
</script>]]
end

return m
