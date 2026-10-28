local m,s,o
local fs=require"nixio.fs"
local uc=require"luci.model.uci".cursor()
local ctl=require"luci.controller.minigate"

local function esc(v)
    v=tostring(v or "")
    v=v:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
    v=v:gsub('"',"&quot;"):gsub("'","&#39;")
    return v
end

local function acme_installed()
    return fs.access("/etc/minigate/acme/data/acme.sh") and fs.access("/etc/minigate/acme/data/dnsapi/dns_cf.sh")
end

local dd={}
uc:foreach("minigate","ddns",function(sec) if sec.domain and sec.domain~=""then dd[#dd+1]=sec.domain end end)

m=Map("minigate","MiniGate - SSL 证书","ACME（Let's Encrypt）自动签发，每天自动续期。域名和令牌自动关联「动态DNS」。")

s=m:section(SimpleSection); s.template="minigate/style"

s=m:section(NamedSection,"acme","acme","ACME 设置"); s.anonymous=true

o=s:option(Flag,"enabled","启用 ACME"); o.rmempty=false

o=s:option(Value,"email","账户邮箱"); o.placeholder="admin@example.com"; o.rmempty=true
o.datatype="string"
o.description="可选，用于接收 Let's Encrypt 到期提醒。"

o=s:option(ListValue,"key_type","密钥类型")
o:value("ec-256","ECC P-256（推荐）"); o:value("ec-384","ECC P-384"); o:value("rsa-2048","RSA 2048"); o:value("rsa-4096","RSA 4096")
o.default="ec-256"

o=s:option(Flag,"staging","测试模式"); o.rmempty=false; o.default="1"
o.description="测试模式签发的证书浏览器不信任，只用于验证配置。确认能签发成功后，请关闭测试模式再签发正式证书。"

-- 证书列表：到期日期、剩余天数和证书类型直接从证书文件读取
o=s:option(DummyValue,"_certs","已签发证书"); o.rawhtml=true
o.cfgvalue=function()
    local certs=ctl.cert_list()
    local h=''
    if uc:get("minigate","acme","staging")=="1" then
        h=h..'<div class="mgx-note">测试模式已开启：签发的证书浏览器不信任。正式使用请关闭测试模式并保存，再点击下方「立即签发」。</div>'
    end
    h=h..'<table class="table"><tr class="tr table-titles"><th class="th">域名</th><th class="th">到期</th><th class="th">类型</th></tr>'
    for _,c in ipairs(certs) do
        local left=c.days_left
        local cls=(left==nil and "mgx-muted") or (left<0 and "mgx-err") or ((left<14 or c.staging) and "mgx-warn") or "mgx-ok"
        local when=c.expires_date and (c.expires_date..(left<0 and "（已过期）" or "（剩 "..left.." 天）")) or "未知"
        h=h..'<tr class="tr"><td class="td"><strong>'..esc(c.domain)..'</strong></td><td class="td"><span class="'..cls..'">'..esc(when)..'</span></td>'
        h=h..'<td class="td">'..(c.staging and '<span class="mgx-warn">测试证书（不受信任）</span>' or '<span class="mgx-ok">正式证书</span>')..'</td></tr>'
    end
    if #certs==0 then h=h..'<tr class="tr"><td class="td mgx-muted" colspan="3" style="text-align:center;padding:15px">暂无证书</td></tr>' end
    return h..'</table>'
end

o=s:option(DummyValue,"_ast","acme.sh 状态"); o.rawhtml=true
o.cfgvalue=function()
    if acme_installed() then return'<span class="mgx-ok">&#10003; 已安装</span>'
    elseif fs.access("/etc/minigate/acme/data/acme.sh")then return'<span class="mgx-warn">&#9888; 缺 DNS 插件，请重新安装</span>'
    else return'<span class="mgx-err">&#10007; 未安装（首次签发时会自动安装）</span>'end
end

-- 操作：签发在后台进行，页面轮询结果，不受网页请求超时影响
s=m:section(NamedSection,"acme","acme","操作"); s.anonymous=true
o=s:option(DummyValue,"_act"," "); o.rawhtml=true
o.cfgvalue=function()
    local iu=luci.dispatcher.build_url("admin/services/minigate/acme_install")
    local su=luci.dispatcher.build_url("admin/services/minigate/acme_issue")
    local ju=luci.dispatcher.build_url("admin/services/minigate/acme_job")
    local opts=""
    for _,d in ipairs(dd)do opts=opts..'<option value="'..esc(d)..'">'..esc(d)..'</option>' end
    local install_button=acme_installed() and "" or
        '<div class="mgx-actions"><button type="button" class="cbi-button cbi-button-reload" id="bi" onclick="doI()" style="min-width:220px">下载并安装 acme.sh</button></div>'
    return install_button..[[
<div class="mgx-actions">
<label for="sd">签发域名：</label>
<select id="sd" class="mgx-select">]]..
(opts~=""and opts or'<option value="">请先配置动态DNS</option>')..[[</select>
<button type="button" class="cbi-button cbi-button-apply" id="bs" onclick="doS()">立即签发</button></div>
<div class="mgx-small mgx-muted">证书剩余超过 30 天时不会重复签发，避免触发 Let's Encrypt 频率限制；到期前 30 天内会自动续期。</div>
<div id="ap" class="mgx-note is-info" style="display:none"><span class="mgx-spin">&#9203;</span><span id="am">处理中...</span></div>
<div id="ar" style="display:none"><div id="ai" class="mgx-note" role="status"></div></div>
<script type="text/javascript">
function sP(m){document.getElementById('ap').style.display='block';document.getElementById('ar').style.display='none';document.getElementById('am').textContent=m}
function sR(ok,m){document.getElementById('ap').style.display='none';document.getElementById('ar').style.display='block';var e=document.getElementById('ai');e.className='mgx-note '+(ok?'is-ok':'is-err');e.textContent=m}
function acmePost(url,args,cb){var done=false;function finish(x,d){if(done)return;done=true;cb(d)}var p=XHR.post(url,args,finish);if(p&&typeof p.catch==='function')p.catch(function(){finish(null,null)})}
function acmeGet(url,cb){var done=false;function finish(x,d){if(done)return;done=true;cb(d)}var p=XHR.get(url,null,finish);if(p&&typeof p.catch==='function')p.catch(function(){finish(null,null)})}
function acmeWait(button,kind,tries){
    acmeGet(']]..ju..[[',function(d){
        if(d&&d.running&&tries<150){setTimeout(function(){acmeWait(button,kind,tries+1)},2000);return}
        if(button)button.disabled=false;
        if(!d){sR(false,'无法读取任务结果，请稍后刷新页面查看');return}
        if(d.running){sR(false,'任务仍在进行，请稍后刷新页面查看');return}
        var ok,msg;
        if(kind==='install'){ok=d.code===0&&d.installed;msg=ok?'安装成功':'安装失败，请查看 ACME 日志';}
        else{ok=d.code===0&&d.result==='ok';msg=d.message||(ok?'签发成功':'签发失败，请查看 ACME 日志');}
        sR(ok,msg);
        if(ok)setTimeout(function(){location.reload()},2500);
    });
}
function doI(){var b=document.getElementById('bi');b.disabled=true;sP('正在下载并校验 acme.sh（约30秒）...');acmePost(']]..iu..[[',null,function(d){if(!d||!d.success){b.disabled=false;sR(false,(d&&d.message)||'无法启动安装任务');return}setTimeout(function(){acmeWait(b,'install',0)},2000)})}
function doS(){var d=document.getElementById('sd').value;if(!d){sR(false,'请选择域名');return}var b=document.getElementById('bs');b.disabled=true;sP('正在签发 '+d+'（约1-2分钟，可离开本页）...');acmePost(']]..su..[[',{domain:d},function(r){if(!r||!r.success){b.disabled=false;sR(false,(r&&r.message)||'无法启动签发任务');return}setTimeout(function(){acmeWait(b,'issue',0)},3000)})}
</script>]]
end

return m
