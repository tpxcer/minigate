local m, s, o
local sys = require "luci.sys"
local uc = require "luci.model.uci".cursor()

m = Map("minigate", "MiniGate - 反向代理", "保存后自动生效。")

m.on_after_commit = function(self)
    sys.call("/bin/sh /usr/lib/minigate/after_commit.sh proxy >/dev/null 2>&1")
end

local ddns_domains = {}
local ddns_ok = {}
local wildcard_domains = {}
local normal_domains = {}
uc:foreach("minigate", "ddns", function(sec)
    local d = sec.domain or ""
    local st = sec.status or ""
    if d ~= "" then
        ddns_domains[#ddns_domains + 1] = d
        if st == "ok" then ddns_ok[d] = true end
        if d:match("^%*%.") then
            wildcard_domains[#wildcard_domains + 1] = d
        else
            normal_domains[#normal_domains + 1] = d
        end
    end
end)

s = m:section(NamedSection, "global", "global", "HTTP 自动跳转",
    "让每个已启用 HTTPS 的监听端口同时接受 HTTP；明文请求会以 308 跳转到同域名、同端口的 HTTPS。")
s.anonymous = true

o = s:option(Flag, "http_redirect", "启用 HTTP 跳转")
o.default = "0"
o.rmempty = false

local lan_ip_auto = uc:get("network", "lan", "ipaddr")
if type(lan_ip_auto) == "table" then lan_ip_auto = lan_ip_auto[1] end
lan_ip_auto = lan_ip_auto and lan_ip_auto:match("^(%d+%.%d+%.%d+%.%d+)")

s = m:section(NamedSection, "global", "global", "局域网直连解析",
    "让局域网设备把本页的代理域名直接解析到本机 LAN 地址：访问不经过公网 IP、主路由回流和上游 DNS 缓存，也不进入代理；公网解析不变。" ..
    "仅对使用本机 DNS（dnsmasq）的设备生效，且要求公网端口映射没有改端口号。")
s.anonymous = true

o = s:option(Flag, "lan_dns", "启用局域网直连解析")
o.default = "0"
o.rmempty = false

o = s:option(Value, "lan_ip", "解析到的 LAN 地址", "留空自动使用 LAN 口 IPv4 地址。")
o.datatype = "ip4addr"
o.placeholder = lan_ip_auto and ("自动（" .. lan_ip_auto .. "）") or "自动"
o:depends("lan_dns", "1")

s = m:section(NamedSection, "global", "global", "公网访问范围",
    "启用后，仅允许所选地区的公网 IP 访问本插件的所有反代站点（含 HTTP 跳转和 WebSocket）；其他地区及归属地未知的 IP 直接断开。" ..
    "局域网私有地址和回环地址继续可用，不影响 SSH、RustDesk 等其他服务。IPv4/IPv6 均检查，按实际连接来源判断。" ..
    "使用随版本附带的离线地址库，归属地可能存在误差；外出或使用外省代理出口也会被拒绝。")
s.anonymous = true

o = s:option(Flag, "access_enabled", "限制公网访问地区")
o.default = "0"
o.rmempty = false

local access_regions = {}
local regions_file = io.open("/usr/lib/minigate/geo/regions.txt", "r")
if regions_file then
    for line in regions_file:lines() do
        local code, name = line:match("^(%d+) (.+)$")
        if code then access_regions[#access_regions + 1] = {code, name} end
    end
    regions_file:close()
end

o = s:option(DynamicList, "access_regions", "允许的省级地区", "可选择多个地区；只允许四川时，仅保留“四川省”。关闭地区限制即恢复所有地区访问。")
o.default = "510000"
o.rmempty = false
o:depends("access_enabled", "1")
local valid_regions = {}
for _, region in ipairs(access_regions) do
    o:value(region[1], region[2])
    valid_regions[region[1]] = true
end
o.validate = function(self, value, section)
    local values = type(value) == "table" and value or {value}
    if #values == 0 then return nil, "请选择至少一个允许的地区" end
    for _, code in ipairs(values) do
        if not valid_regions[code] then return nil, "请从列表中选择有效的省级地区" end
    end
    return value
end

-- ================================
-- 通配符域名
-- ================================
if #wildcard_domains > 0 then

s = m:section(TypedSection, "proxy_wildcard", "通配符域名",
    "配置监听端口和HTTPS，具体转发由「子域名」控制。")
s.anonymous = false
s.addremove = true
s.template = "cbi/tblsection"
s.sectionhead = "名称"

o = s:option(ListValue, "enabled", "启用")
o:value("1", "✓ 启用")
o:value("0", "✗ 禁用")
o.default = "1"
o.rmempty = false

o = s:option(ListValue, "domain", "域名")
o:value("", "-- 请选择 --")
for _, d in ipairs(wildcard_domains) do
    local label = d
    if ddns_ok[d] then label = d .. " ✓" end
    o:value(d, label)
end
o.rmempty = false

o = s:option(Value, "listen_port", "监听端口")
o.datatype = "port"
o.default = "2000"
o.rmempty = false

o = s:option(ListValue, "ssl", "HTTPS")
o:value("1", "✓ 开启")
o:value("0", "✗ 关闭")
o.default = "1"
o.rmempty = false

-- ================================
-- 子域名规则
-- ================================
s = m:section(TypedSection, "subproxy", "子域名规则")
s.anonymous = true
s.addremove = true
s.sortable = true
s.template = "cbi/tblsection"

o = s:option(ListValue, "parent_domain", "主域名")
o:value("", "--")
for _, d in ipairs(wildcard_domains) do
    local base = d:gsub("^%*%.", "")
    o:value(base, d)
end
o.rmempty = false

o = s:option(Value, "prefix", "前缀")
o.rmempty = false
o.placeholder = "app"

o = s:option(Value, "target_addr", "目标地址")
o.rmempty = false
o.placeholder = "192.168.1.100"

o = s:option(Value, "target_port", "端口")
o.datatype = "port"
o.default = "80"
o.rmempty = false

o = s:option(DummyValue, "_final", "实际域名")
o.rawhtml = true
o.cfgvalue = function(self, section)
    local base = m.uci:get("minigate", section, "parent_domain") or ""
    local prefix = m.uci:get("minigate", section, "prefix") or ""
    if prefix ~= "" and base ~= "" then
        return '<strong style="color:#4caf50">' .. prefix .. '.' .. base .. '</strong>'
    end
    return '<span style="color:#999">--</span>'
end

end -- wildcard_domains

-- ================================
-- 普通域名代理
-- ================================
if #normal_domains > 0 or #wildcard_domains == 0 then

s = m:section(TypedSection, "proxy", "代理规则",
    "非通配符域名的反向代理。")
s.anonymous = false
s.addremove = true
s.template = "cbi/tblsection"
s.sortable = true
s.sectionhead = "名称"

o = s:option(ListValue, "enabled", "启用")
o:value("1", "✓ 启用")
o:value("0", "✗ 禁用")
o.default = "1"
o.rmempty = false

o = s:option(ListValue, "domain", "域名")
o:value("", "-- 请选择 --")
for _, d in ipairs(normal_domains) do
    local label = d
    if ddns_ok[d] then label = d .. " ✓" end
    o:value(d, label)
end
o.rmempty = false

o = s:option(Value, "listen_port", "端口")
o.datatype = "port"
o.default = "443"
o.rmempty = false

o = s:option(Value, "target_addr", "目标地址")
o.rmempty = false
o.placeholder = "192.168.1.100"

o = s:option(Value, "target_port", "目标端口")
o.datatype = "port"
o.default = "80"
o.rmempty = false

o = s:option(ListValue, "ssl", "HTTPS")
o:value("1", "✓ 开启")
o:value("0", "✗ 关闭")
o.default = "1"
o.rmempty = false

o = s:option(ListValue, "websocket", "WS")
o:value("0", "✗ 关闭")
o:value("1", "✓ 开启")
o.default = "0"
o.rmempty = false

end -- normal_domains

return m
