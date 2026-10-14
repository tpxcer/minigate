local m,s,o
local sys=require"luci.sys"
local fs=require"nixio.fs"
local uc=require"luci.model.uci".cursor()

local function esc(v)
    v=tostring(v or "")
    v=v:gsub("&","&amp;"):gsub("<","&lt;"):gsub(">","&gt;")
    v=v:gsub('"',"&quot;"):gsub("'","&#39;")
    return v
end

local function shellquote(v)
    v=tostring(v or "")
    return "'"..v:gsub("'","'\"'\"'").."'"
end

local dd={}
uc:foreach("minigate","ddns",function(sec) if sec.domain and sec.domain~=""then dd[#dd+1]=sec.domain end end)

m=Map("minigate","MiniGate - SSL 证书","ACME（Let's Encrypt）自动签发。域名和令牌自动关联「动态DNS」。")

s=m:section(NamedSection,"acme","acme","ACME 设置"); s.anonymous=true

o=s:option(Flag,"enabled","启用 ACME"); o.rmempty=false

o=s:option(Value,"email","账户邮箱"); o.placeholder="admin@example.com"; o.rmempty=true
o.description="可选。"

o=s:option(ListValue,"key_type","密钥类型")
o:value("ec-256","ECC P-256（推荐）"); o:value("ec-384","ECC P-384"); o:value("rsa-2048","RSA 2048"); o:value("rsa-4096","RSA 4096")
o.default="ec-256"

o=s:option(Flag,"staging","测试模式"); o.rmempty=false; o.default="1"
o.description="正式使用请关闭。"

-- 证书列表
o=s:option(DummyValue,"_certs","已签发证书"); o.rawhtml=true
o.cfgvalue=function()
    local cd="/etc/minigate/certs"
    local h='<table class="table"><tr class="tr table-titles"><th class="th">域名</th><th class="th">过期时间</th><th class="th">路径</th></tr>'
    local found=false
    if fs.dir(cd)then
        for entry in fs.dir(cd)do
            local fp=cd.."/"..entry
            -- lstat 返回 table，检查 type 字段
            local st=fs.lstat(fp)
            if entry~="_default" and st and st.type=="dir"then
                local cert=fp.."/fullchain.pem"
                if fs.access(cert)then
                    found=true
                    local exp=""
                    local f=io.popen("openssl x509 -in "..shellquote(cert).." -noout -enddate 2>/dev/null")
                    if f then local l=f:read("*l"); if l then exp=l:gsub("notAfter=","") end; f:close() end
                    local dn=entry:gsub("_wildcard_%.", "*.")
                    h=h..'<tr class="tr"><td class="td"><strong>'..esc(dn)..'</strong></td><td class="td">'..esc(exp)..'</td><td class="td"><code>'..esc(fp)..'/</code></td></tr>'
                end
            end
        end
    end
    if not found then h=h..'<tr class="tr"><td class="td" colspan="3" style="text-align:center;color:#999;padding:15px">暂无证书</td></tr>' end
    return h..'</table>'
end

o=s:option(DummyValue,"_ast","acme.sh 状态"); o.rawhtml=true
o.cfgvalue=function()
    if fs.access("/etc/minigate/acme/data/acme.sh")and fs.access("/etc/minigate/acme/data/dnsapi/dns_cf.sh")then return'<span style="color:#4caf50">&#10003; 已安装</span>'
    elseif fs.access("/etc/minigate/acme/data/acme.sh")then return'<span style="color:#ff9800">&#9888; 缺DNS插件</span>'
    else return'<span style="color:#f44336">&#10007; 未安装</span>'end
end

-- 操作
s=m:section(NamedSection,"acme","acme","操作"); s.anonymous=true
o=s:option(DummyValue,"_act"," "); o.rawhtml=true
o.cfgvalue=function()
    local iu=luci.dispatcher.build_url("admin/services/minigate/acme_install")
    local su=luci.dispatcher.build_url("admin/services/minigate/acme_issue")
    local opts=""
    for _,d in ipairs(dd)do opts=opts..'<option value="'..esc(d)..'">'..esc(d)..'</option>' end
    return[[
<div style="margin-bottom:15px"><button class="cbi-button cbi-button-reload" id="bi" onclick="doI()" style="min-width:220px">下载并安装 acme.sh</button></div>
<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:10px">
<label>签发域名：</label>
<select id="sd" style="padding:5px 10px;border-radius:4px;border:1px solid #ccc;min-width:250px">]]..
(opts~=""and opts or'<option value="">请先配置动态DNS</option>')..[[</select>
<button class="cbi-button cbi-button-apply" id="bs" onclick="doS()">立即签发 / 续期</button></div>
<div id="ap" class="mg-acme-note" style="display:none"><span style="display:inline-block;animation:sp 1s linear infinite;margin-right:8px">&#9203;</span><span id="am">处理中...</span></div>
<div id="ar" style="display:none"><div id="ai" class="mg-acme-note" role="status"></div></div>
<style>@keyframes sp{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}
.mg-acme-note{margin-top:12px;border-radius:4px;padding:10px 15px;font-size:13px;line-height:1.6;background:rgba(127,127,127,.12);border:1px solid rgba(127,127,127,.2)}
.mg-acme-note.ok{background:rgba(47,158,68,.12);border-color:rgba(47,158,68,.32);color:#2e7d32}
.mg-acme-note.fail{background:rgba(224,49,49,.1);border-color:rgba(224,49,49,.3);color:#c62828}
:root[data-darkmode="true"] .mg-acme-note.ok{color:#78c98d}
:root[data-darkmode="true"] .mg-acme-note.fail{color:#e58a84}
@media(prefers-color-scheme:dark){:root:not([data-darkmode]) .mg-acme-note.ok{color:#78c98d}:root:not([data-darkmode]) .mg-acme-note.fail{color:#e58a84}}
</style>
<script type="text/javascript">
function sP(m){document.getElementById('ap').style.display='block';document.getElementById('ar').style.display='none';document.getElementById('am').textContent=m}
function sR(ok,m){document.getElementById('ap').style.display='none';document.getElementById('ar').style.display='block';var e=document.getElementById('ai');e.className='mg-acme-note '+(ok?'ok':'fail');e.textContent=m}
function acmePost(url,args,cb){var done=false;function finish(x,d){if(done)return;done=true;cb(d)}var p=XHR.post(url,args,finish);if(p&&typeof p.catch==='function')p.catch(function(){finish(null,null)})}
function doI(){document.getElementById('bi').disabled=true;sP('下载安装中（约30秒）...');acmePost(']]..iu..[[',null,function(d){document.getElementById('bi').disabled=false;d?sR(d.success,d.message):sR(false,'请求未完成：安装可能仍在后台进行，请稍后刷新页面查看 acme.sh 状态');if(d&&d.success)setTimeout(function(){location.reload()},2000)})}
function doS(){var d=document.getElementById('sd').value;if(!d){sR(false,'请选择域名');return}document.getElementById('bs').disabled=true;sP('签发 '+d+'（约1-2分钟）...');acmePost(']]..su..[[',{domain:d},function(r){document.getElementById('bs').disabled=false;r?sR(r.success,r.message):sR(false,'请求超时：签发可能仍在后台进行，请稍后刷新页面查看证书状态');if(r&&r.success)setTimeout(function(){location.reload()},2000)})}
</script>]]
end

return m
