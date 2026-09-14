local m, s, o
local sys = require "luci.sys"
local uc = require "luci.model.uci".cursor()

m = Map("minigate", "MiniGate - 反向代理", "保存后自动生效。")

m.on_after_commit = function(self)
    sys.call("sleep 1 && /bin/sh /usr/lib/minigate/proxy.sh reload >/dev/null 2>&1 &")
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
    "为已启用 HTTPS 的代理域名单独监听 HTTP，并跳转到标准 HTTPS 地址。公网使用时还需在上级路由设置 TCP 80 转发到这里配置的端口。")
s.anonymous = true

o = s:option(Flag, "http_redirect", "启用 HTTP 跳转")
o.default = "0"
o.rmempty = false

o = s:option(Value, "http_redirect_port", "内部监听端口")
o.datatype = "port"
o.default = "2001"
o.rmempty = false
o:depends("http_redirect", "1")
o.validate = function(self, value, section)
    local conflict = false
    uc:foreach("minigate", "proxy_wildcard", function(sec)
        if sec.enabled == "1" and tostring(sec.listen_port or "443") == value then conflict = true end
    end)
    uc:foreach("minigate", "proxy", function(sec)
        if sec.enabled == "1" and tostring(sec.listen_port or "443") == value then conflict = true end
    end)
    if conflict then return nil, "HTTP 跳转端口不能与反向代理监听端口相同" end
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
