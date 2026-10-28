module("luci.controller.minigate", package.seeall)

local RUN_DIR = "/var/run/minigate"
local JOB_DIR = RUN_DIR .. "/jobs"
local DDNS_STATE_DIR = RUN_DIR .. "/ddns"
local ACME_STATE_FILE = RUN_DIR .. "/acme.state"
local PROXY_STATUS_FILE = RUN_DIR .. "/proxy.status"
local CERT_DIR = "/etc/minigate/certs"

local function shellquote(value)
    value = tostring(value or "")
    return "'" .. value:gsub("'", "'\"'\"'") .. "'"
end

local function write_json(data)
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end

local function bad_request(message, extra)
    luci.http.status(400, "Bad Request")
    local data = extra or {}
    data.success = false
    data.message = message
    write_json(data)
end

-- 读取 key=value 状态文件；warning 等可重复的键收集为数组
function read_state(path)
    local data = {}
    local file = io.open(path, "r")
    if not file then return nil end
    for line in file:lines() do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key == "warning" then
            data.warnings = data.warnings or {}
            data.warnings[#data.warnings + 1] = value
        elseif key then
            data[key] = value
        end
    end
    file:close()
    return data
end

-- 与 ddns.sh 的 state_key 和 IP 历史文件使用相同的域名清洗规则
function state_key(domain)
    return (tostring(domain or ""):gsub("[^%w_%-]", "_"))
end

function ddns_state(domain)
    if not domain or domain == "" then return {} end
    return read_state(DDNS_STATE_DIR .. "/" .. state_key(domain) .. ".state") or {}
end

local MONTHS = {Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6, Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12}

-- 公历日期转 UTC 秒数，不依赖路由器时区
local function utc_epoch(y, m, d, hh, mm, ss)
    y = (m <= 2) and (y - 1) or y
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = (m + 9) % 12
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    local days = era * 146097 + doe - 719468
    return days * 86400 + hh * 3600 + mm * 60 + ss
end

-- openssl 的 notAfter 形如 "Dec 16 12:00:00 2026 GMT"
function parse_cert_time(value)
    local mon, d, hh, mm, ss, y = tostring(value or ""):match("^(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+(%d+)")
    if not mon or not MONTHS[mon] then return nil end
    return utc_epoch(tonumber(y), MONTHS[mon], tonumber(d), tonumber(hh), tonumber(mm), tonumber(ss))
end

-- 读取已签发证书：域名、到期日期、剩余天数、是否为测试证书
function cert_list()
    local fs = require "nixio.fs"
    local certs = {}
    if not fs.dir(CERT_DIR) then return certs end
    local now = os.time()
    for entry in fs.dir(CERT_DIR) do
        local path = CERT_DIR .. "/" .. entry
        local st = fs.lstat(path)
        if entry ~= "_default" and st and st.type == "dir" and fs.access(path .. "/fullchain.pem") then
            local handle = io.popen("openssl x509 -in " .. shellquote(path .. "/fullchain.pem") .. " -noout -enddate -issuer 2>/dev/null")
            local output = handle and handle:read("*a") or ""
            if handle then handle:close() end
            local not_after = output:match("notAfter=([^\n]+)")
            local issuer = output:match("issuer=([^\n]+)") or ""
            local expires = parse_cert_time(not_after)
            local item = {
                domain = entry:gsub("^_wildcard_%.", "*."),
                path = path,
                staging = (issuer:lower():find("staging", 1, true) or issuer:lower():find("fake", 1, true)) and true or false
            }
            if expires then
                item.expires = expires
                item.expires_date = os.date("%Y-%m-%d", expires)
                item.days_left = math.floor((expires - now) / 86400)
            end
            certs[#certs + 1] = item
        end
    end
    table.sort(certs, function(a, b) return (a.expires or 0) < (b.expires or 0) end)
    return certs
end

function index()
    entry({"admin","services","minigate"}, alias("admin","services","minigate","general"), "MiniGate", 60).dependent=false
    entry({"admin","services","minigate","general"}, cbi("minigate/general"), "总览", 10)
    entry({"admin","services","minigate","ddns"}, cbi("minigate/ddns"), "动态DNS", 20)
    entry({"admin","services","minigate","acme"}, cbi("minigate/acme"), "SSL 证书", 30)
    entry({"admin","services","minigate","proxy"}, cbi("minigate/proxy"), "反向代理", 40)
    entry({"admin","services","minigate","login_guard"}, cbi("minigate/login_guard"), "登录防护", 45)
    entry({"admin","services","minigate","log"}, template("minigate/log"), "日志", 50)
    entry({"admin","services","minigate","status"}, call("action_status")).leaf=true
    entry({"admin","services","minigate","get_log"}, call("action_get_log")).leaf=true
    entry({"admin","services","minigate","acme_install"}, post("action_acme_install")).leaf=true
    entry({"admin","services","minigate","acme_issue"}, post("action_acme_issue")).leaf=true
    entry({"admin","services","minigate","acme_job"}, call("action_acme_job")).leaf=true
    entry({"admin","services","minigate","ddns_sync"}, post("action_ddns_sync")).leaf=true
    entry({"admin","services","minigate","ddns_job"}, call("action_ddns_job")).leaf=true
    entry({"admin","services","minigate","ddns_history"}, call("action_ddns_history")).leaf=true
    entry({"admin","services","minigate","proxy_access"}, call("action_proxy_access")).leaf=true
    entry({"admin","services","minigate","geo_lookup"}, call("action_geo_lookup")).leaf=true
    entry({"admin","services","minigate","lg_status"}, call("action_lg_status")).leaf=true
    entry({"admin","services","minigate","lg_ban"}, post("action_lg_ban")).leaf=true
    entry({"admin","services","minigate","lg_unban"}, post("action_lg_unban")).leaf=true
    entry({"admin","services","minigate","lg_flush"}, post("action_lg_flush")).leaf=true
    entry({"admin","services","minigate","update_status"}, call("action_update_status")).leaf=true
    entry({"admin","services","minigate","update_auto"}, call("action_update_auto")).leaf=true
    entry({"admin","services","minigate","update_check"}, call("action_update_check")).leaf=true
    entry({"admin","services","minigate","update_apply"}, post("action_update_apply")).leaf=true
    entry({"admin","services","minigate","uninstall"}, post("action_uninstall")).leaf=true
end

-- ============== 后台任务 ==============

local function job_state(name)
    return read_state(JOB_DIR .. "/" .. name .. ".state") or {}
end

-- 同名任务正在运行时不重复启动；超过 15 分钟仍为 running 视为异常退出
local function job_running(name)
    local state = job_state(name)
    local started = tonumber(state.started or "")
    return state.status == "running" and started ~= nil and os.time() - started < 900
end

local function start_job(name, command)
    local sys = require "luci.sys"
    if job_running(name) then return true end
    return sys.call("( /bin/sh /usr/lib/minigate/job.sh " .. name .. " " .. command ..
        " ) </dev/null >/dev/null 2>&1 &") == 0
end

local function job_response(name)
    local state = job_state(name)
    return {
        running = job_running(name),
        done = state.status == "done",
        code = tonumber(state.code or ""),
        finished = tonumber(state.finished or "")
    }
end

-- ============== 软件更新与卸载 ==============

local function update_response(command)
    local sys = require "luci.sys"
    local jsonc = require "luci.jsonc"
    local fs = require "nixio.fs"
    local raw = sys.exec("/bin/sh /usr/lib/minigate/update.sh " .. command .. " 2>/dev/null") or ""
    local ok, data = pcall(jsonc.parse, raw)
    if not ok or type(data) ~= "table" then
        data = {
            status = "error",
            progress = 0,
            current = "",
            latest = "",
            available = false,
            running = false,
            success = false,
            message = "更新服务返回了无效结果"
        }
    end

    local release_raw = fs.readfile("/tmp/minigate-update-release.json")
    if release_raw and data.latest and data.latest ~= "" then
        local release_ok, release = pcall(jsonc.parse, release_raw)
        if release_ok and type(release) == "table" then
            local tag = tostring(release.tag_name or ""):gsub("^v", "")
            if tag == tostring(data.latest) then
                local title = type(release.name) == "string" and release.name or ("MiniGate v" .. tag)
                local notes = type(release.body) == "string" and release.body or ""
                data.release_title = title
                data.release_notes = notes
            end
        end
    end
    write_json(data)
end

function action_update_status()
    update_response("status")
end

function action_update_auto()
    update_response("auto")
end

function action_update_check()
    update_response("check")
end

function action_update_apply()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local version = luci.http.formvalue("version")
    local ok = false

    if type(version) ~= "string" or #version > 32 or not (
        version:match("^%d+%.%d+%.%d+$") or version:match("^%d+%.%d+%.%d+%-%d+$")) then
        bad_request("请先查看更新内容并确认版本")
        return
    end

    if fs.access("/usr/lib/minigate/update.sh") then
        ok = sys.call("runner=$(mktemp /tmp/minigate-update-run.XXXXXX)" ..
            " && cp /usr/lib/minigate/update.sh \"$runner\" && chmod 700 \"$runner\"" ..
            " && ( ( /bin/sh \"$runner\" apply " .. shellquote(version) ..
            "; rm -f \"$runner\" ) >/dev/null 2>&1 & )") == 0
    end

    write_json({
        success = ok,
        message = ok and "更新任务已启动" or "无法启动更新任务"
    })
end

function action_uninstall()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local confirm = luci.http.formvalue("confirm")
    local purge = luci.http.formvalue("purge")
    local ok = false

    if confirm ~= "uninstall-minigate" or (purge ~= "0" and purge ~= "1") then
        bad_request("卸载确认无效，请重新操作")
        return
    end

    if fs.access("/usr/lib/minigate/uninstall.sh") then
        ok = sys.call("runner=$(mktemp /tmp/minigate-uninstall.XXXXXX)" ..
            " && cp /usr/lib/minigate/uninstall.sh \"$runner\" && chmod 700 \"$runner\"" ..
            " && ( ( sleep 1; /bin/sh \"$runner\" " .. shellquote(purge) ..
            "; rm -f \"$runner\" ) >/dev/null 2>&1 & )") == 0
    end

    write_json({
        success = ok,
        message = ok and "卸载任务已启动" or "无法启动卸载任务"
    })
end

-- ============== 总览状态 ==============

local STATUS_RANK = {error=4, partial=3, unknown=2, stopped=1, ok=0}

function action_status()
    local uci = require "luci.model.uci".cursor()
    local pr = false
    local f = io.open("/var/run/minigate-nginx.pid", "r")
    if f then
        local p = f:read("*l"); f:close()
        if p and tonumber(p) then pr = (os.execute("kill -0 " .. p .. " 2>/dev/null") == 0) end
    end
    local enabled = uci:get("minigate", "global", "enabled") or "0"

    -- DDNS：列出所有记录，并给出最差状态用于卡片颜色
    local dl = {}
    local worst = nil
    uci:foreach("minigate", "ddns", function(s)
        local st = ddns_state(s.domain)
        local status = st.status or "unknown"
        local on = s.enabled == "1"
        if not on then status = "disabled" end
        dl[#dl + 1] = {
            name = s[".name"],
            enabled = on and "1" or "0",
            domain = s.domain or "",
            ip_version = s.ip_version or "ipv4",
            status = status,
            status_msg = st.message or "",
            last_ip = st.ip or "",
            last_ip6 = st.ip6 or "",
            last_update = st.updated or "",
            next_sync = st.next or ""
        }
        if on and (worst == nil or (STATUS_RANK[status] or 2) > (STATUS_RANK[worst] or 2)) then worst = status end
    end)

    local ipv6_listen = uci:get("minigate", "global", "ipv6_listen") or "0"

    -- 反代规则：与 proxy.sh 一致，主域名未启用的子域名不显示
    local proxy_rules = {}
    local wc_ports = {}
    uci:foreach("minigate", "proxy_wildcard", function(s)
        if s.enabled == "1" and s.domain then
            local base = (s.domain or ""):gsub("^%*%.", "")
            wc_ports[base] = {port = s.listen_port or "443", ssl = tostring(s.ssl or "0")}
        end
    end)
    uci:foreach("minigate", "subproxy", function(s)
        local parent = s.parent_domain or ""
        local prefix = s.prefix or ""
        local wc = wc_ports[parent]
        if prefix ~= "" and wc and (s.enabled or "1") == "1" then
            proxy_rules[#proxy_rules + 1] = {
                domain = prefix .. "." .. parent,
                target = (s.target_addr or "") .. ":" .. (s.target_port or "80"),
                listen_port = wc.port,
                scheme = wc.ssl == "1" and "https" or "http",
                ipv6_listen = ipv6_listen
            }
        end
    end)
    uci:foreach("minigate", "proxy", function(s)
        if s.enabled == "1" and s.domain and s.target_addr then
            proxy_rules[#proxy_rules + 1] = {
                domain = s.domain,
                target = (s.target_addr or "") .. ":" .. (s.target_port or "80"),
                listen_port = s.listen_port or "443",
                scheme = tostring(s.ssl or "1") == "1" and "https" or "http",
                ipv6_listen = ipv6_listen
            }
        end
    end)

    local proxy_state = read_state(PROXY_STATUS_FILE) or {}
    local acme_state = read_state(ACME_STATE_FILE) or {}

    write_json({
        enabled = enabled,
        ipv6_listen = ipv6_listen,
        proxy_running = pr,
        proxy_check = proxy_state.result or "",
        proxy_message = proxy_state.message or "",
        proxy_time = proxy_state.time or "",
        proxy_warnings = proxy_state.warnings or {},
        ddns_status = worst or "",
        ddns_list = dl,
        proxy_rules = proxy_rules,
        certs = cert_list(),
        acme = {
            enabled = uci:get("minigate", "acme", "enabled") or "0",
            staging = uci:get("minigate", "acme", "staging") or "0",
            result = acme_state.result or "",
            domain = acme_state.domain or "",
            message = acme_state.message or "",
            time = acme_state.time or ""
        }
    })
end

-- ============== 日志 ==============

local LOG_SOURCES = {
    ddns = {{"DDNS", "/var/log/minigate-ddns.log"}},
    acme = {{"证书", "/var/log/minigate-acme.log"}},
    proxy = {{"反代", "/var/log/minigate-proxy.log"}, {"Nginx", "/var/log/minigate-nginx-error.log"}},
    login_guard = {{"登录防护", "/var/log/minigate-login-guard.log"}},
    update = {{"更新", "/var/log/minigate-update.log"}}
}
local LOG_ORDER = {"ddns", "acme", "proxy", "login_guard", "update"}

local function tail_lines(path, count)
    local lines = {}
    local file = io.open(path, "r")
    if not file then return lines end
    for line in file:lines() do
        lines[#lines + 1] = line
        if #lines > count then table.remove(lines, 1) end
    end
    file:close()
    return lines
end

-- 统一时间戳便于合并：nginx 用 2026/10/28，其余脚本用 2026-10-28
local function line_time(line)
    local stamp = line:match("^(%d%d%d%d[-/]%d%d[-/]%d%d %d%d:%d%d:%d%d)")
    return stamp and stamp:gsub("/", "-") or nil
end

-- 「全部」按时间合并各来源，每行标出来源；没有时间戳的行（如 curl 输出）跟随上一行
function merge_logs(sources, limit)
    local rows = {}
    for source_index, source in ipairs(sources) do
        local last = ""
        for line_index, line in ipairs(tail_lines(source[2], limit)) do
            last = line_time(line) or last
            rows[#rows + 1] = {time = last, source = source_index, index = line_index, text = "[" .. source[1] .. "] " .. line}
        end
    end
    table.sort(rows, function(a, b)
        if a.time ~= b.time then return a.time < b.time end
        if a.source ~= b.source then return a.source < b.source end
        return a.index < b.index
    end)
    local out = {}
    for i = math.max(1, #rows - limit + 1), #rows do out[#out + 1] = rows[i].text end
    return table.concat(out, "\n")
end

function action_get_log()
    local source = luci.http.formvalue("source") or "all"
    local sources = {}
    if LOG_SOURCES[source] then
        sources = LOG_SOURCES[source]
    else
        for _, name in ipairs(LOG_ORDER) do
            for _, item in ipairs(LOG_SOURCES[name]) do sources[#sources + 1] = item end
        end
    end
    write_json({log = merge_logs(sources, 300)})
end

-- ============== 证书 ==============

function action_acme_install()
    local ok = start_job("acme", "/bin/sh /usr/lib/minigate/acme.sh install")
    write_json({success = ok, message = ok and "已开始安装" or "无法启动安装任务"})
end

function action_acme_issue()
    local d = luci.http.formvalue("domain") or ""
    if d ~= "" and (#d > 253 or not d:match("^[%*%w][%w%.%-]*$")) then
        bad_request("域名无效")
        return
    end
    local ok = start_job("acme", "/bin/sh /usr/lib/minigate/acme.sh issue " .. shellquote(d))
    write_json({success = ok, message = ok and "已开始签发" or "无法启动签发任务"})
end

function action_acme_job()
    local fs = require "nixio.fs"
    local data = job_response("acme")
    local state = read_state(ACME_STATE_FILE) or {}
    data.result = state.result or ""
    data.message = state.message or ""
    data.domain = state.domain or ""
    data.installed = fs.access("/etc/minigate/acme/data/acme.sh") and fs.access("/etc/minigate/acme/data/dnsapi/dns_cf.sh") and true or false
    write_json(data)
end

-- ============== DDNS ==============

local function valid_ddns_section(sec)
    return sec ~= "" and #sec <= 64 and sec:match("^[%w_]+$") and
        require"luci.model.uci".cursor():get("minigate", sec) == "ddns"
end

function action_ddns_sync()
    local sec = luci.http.formvalue("section") or ""
    if not valid_ddns_section(sec) then
        bad_request("DDNS 记录参数无效", {status = "invalid"})
        return
    end
    local ok = start_job("ddns-" .. sec, "/bin/sh /usr/lib/minigate/ddns.sh single " .. shellquote(sec))
    write_json({success = ok, message = ok and "已开始同步" or "无法启动同步任务"})
end

function action_ddns_job()
    local sec = luci.http.formvalue("section") or ""
    if not valid_ddns_section(sec) then
        bad_request("DDNS 记录参数无效", {status = "invalid"})
        return
    end
    local uci = require "luci.model.uci".cursor()
    local data = job_response("ddns-" .. sec)
    local st = ddns_state(uci:get("minigate", sec, "domain"))
    data.status = st.status or "unknown"
    data.message = st.message or ""
    data.ip = st.ip or ""
    data.ip6 = st.ip6 or ""
    data.updated = st.updated or ""
    data.next = st.next or ""
    data.success = data.status == "ok" or data.status == "partial"
    write_json(data)
end

local function history_section_name(value)
    return tostring(value or ""):gsub("[^%w_%-]", "_")
end

local function history_ip_valid(family, ip)
    if family == "ipv4" then
        return ip:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
    end
    return ip:match("^[%x:]+$") ~= nil and ip:find(":", 1, true) ~= nil
end

local function read_history_events(path, family, now)
    local events = {}
    local file = io.open(path, "r")
    if not file then return events end

    for line in file:lines() do
        local raw_ts, ip = line:match("^(%d+)\t([^\t\r\n]+)$")
        local ts = tonumber(raw_ts)
        if ts and ts > 0 and ts <= now + 300 and history_ip_valid(family, ip or "") then
            local previous = events[#events]
            if not previous or previous.ip ~= ip then
                events[#events + 1] = {timestamp=ts, ip=ip}
            end
        end
    end
    file:close()
    table.sort(events, function(a, b) return a.timestamp < b.timestamp end)
    return events
end

function action_ddns_history()
    local uci = require "luci.model.uci".cursor()
    local history_dir = os.getenv("MINIGATE_HISTORY_DIR") or "/etc/minigate/ddns-history"
    local requested = luci.http.formvalue("section") or ""
    local now = os.time()
    local cutoff = now - 86400
    local rows = {}
    local sections = {}

    if #requested > 64 or (requested ~= "" and not requested:match("^[%w_%-]+$")) then
        bad_request("DDNS 记录参数无效")
        return
    end

    uci:foreach("minigate", "ddns", function(section)
        local name = section[".name"] or ""
        if name ~= "" and (requested == "" or requested == name) then
            sections[#sections + 1] = {
                name=name,
                domain=section.domain or name,
                enabled=(section.enabled == "1" or section.enabled == true),
                ip_version=section.ip_version or "ipv4"
            }
        end
    end)

    for _, section in ipairs(sections) do
        if section.enabled then
            local families = {}
            if section.ip_version == "ipv4" or section.ip_version == "dual" then families[#families + 1] = "ipv4" end
            if section.ip_version == "ipv6" or section.ip_version == "dual" then families[#families + 1] = "ipv6" end

            for _, family in ipairs(families) do
                local path = history_dir .. "/" .. history_section_name(section.domain) .. "." .. family .. ".tsv"
                local events = read_history_events(path, family, now)
                for index, event in ipairs(events) do
                    local next_event = events[index + 1]
                    local end_time = next_event and next_event.timestamp or now
                    if end_time > cutoff and event.timestamp <= now then
                        rows[#rows + 1] = {
                            section=section.name,
                            domain=section.domain,
                            family=family,
                            ip=event.ip,
                            start_time=event.timestamp,
                            end_time=end_time,
                            duration=math.max(0, end_time - event.timestamp),
                            active=(next_event == nil)
                        }
                    end
                end
            end
        end
    end

    table.sort(rows, function(a, b)
        if a.start_time == b.start_time then return a.domain < b.domain end
        return a.start_time > b.start_time
    end)

    write_json({
        success=true,
        generated_at=now,
        window_start=cutoff,
        window_seconds=86400,
        sections=sections,
        records=rows
    })
end

-- ============== 访问记录 ==============

function action_proxy_access()
    local sys = require "luci.sys"
    local limit = tonumber(luci.http.formvalue("limit") or "5") or 5
    if limit ~= 20 and limit ~= 50 then
        limit = 5
    end
    -- 读取最近 500 条日志，按 IP 聚合
    local raw = sys.exec("cat /var/log/minigate-access.log.1 /var/log/minigate-access.log 2>/dev/null | tail -n 500") or ""
    local visitors = {}
    local order = {}     -- 保持顺序

    for line in raw:gmatch("[^\n]+") do
        local time   = line:match('"time":"([^"]*)"')
        local domain = line:match('"domain":"([^"]*)"')
        local client = line:match('"client":"([^"]*)"')
        local status = tonumber(line:match('"status"%s*:%s*(%d+)'))
        local upstream = line:match('"upstream_status":"([^"]*)"')
        if time and client and client ~= "" then
            local outcome = "unknown"
            if status == 444 or (status == 400 and domain == "_") then
                outcome = "blocked"
            elseif status and (status >= 500 or status == 499) then
                outcome = "error"
            elseif status and upstream and upstream ~= "" and upstream ~= "-" then
                outcome = "forwarded"
            elseif status and status >= 100 and status < 400 then
                outcome = "responded"
            elseif status and status >= 400 then
                outcome = "error"
            end
            if not visitors[client] then
                visitors[client] = { count = 0, forwarded_count = 0, blocked_count = 0, other_count = 0 }
                order[#order + 1] = client
            end
            local v = visitors[client]
            v.last_time, v.domain, v.status, v.outcome = time, domain or "", status, outcome
            v.count = v.count + 1
            local counter = outcome == "forwarded" and "forwarded_count" or
                (outcome == "blocked" and "blocked_count" or "other_count")
            v[counter] = v[counter] + 1
        end
    end

    -- 按最后访问时间倒序
    table.sort(order, function(a, b)
        return visitors[a].last_time > visitors[b].last_time
    end)

    -- 按前端选择取前 N 个，默认 5 个
    local result = {}
    local now = os.time()
    for i = 1, math.min(#order, limit) do
        local ip = order[i]
        local v = visitors[ip]
        -- 仅表示最近有请求，不能据此推断访客在线或已通过准入。
        local recent = false
        local y,mo,da,h,mi,se = v.last_time:match("(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
        if y then
            local ts = os.time({year=tonumber(y),month=tonumber(mo),day=tonumber(da),hour=tonumber(h),min=tonumber(mi),sec=tonumber(se)})
            recent = now >= ts and (now - ts) < 300
        end
        result[#result + 1] = {
            ip = ip,
            last_time = v.last_time,
            domain = v.domain,
            count = v.count,
            recent = recent,
            outcome = v.outcome,
            status = v.status,
            forwarded_count = v.forwarded_count,
            blocked_count = v.blocked_count,
            other_count = v.other_count
        }
    end

    write_json({ visitors = result })
end

-- ============== 归属地 ==============

local GEO_CACHE_DIR = "/tmp/minigate-geo-cache"
local GEO_CACHE_MAX = 500

-- 缓存超过上限时删除最旧的一批，避免长期遭遇扫描时占满内存
local function prune_geo_cache()
    local sys = require "luci.sys"
    local count = tonumber((sys.exec("ls " .. GEO_CACHE_DIR .. " 2>/dev/null | wc -l") or ""):match("%d+") or "0") or 0
    if count > GEO_CACHE_MAX then
        sys.call("cd " .. GEO_CACHE_DIR .. " && ls -tr | head -n 100 | xargs rm -f -- 2>/dev/null")
    end
end

local function json_field(raw, key)
    return raw:match('"' .. key .. '"%s*:%s*"([^"]*)"') or ""
end

function action_geo_lookup()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local ip = luci.http.formvalue("ip") or ""
    -- 安全校验：只允许 IP 地址字符
    if #ip > 39 or not ip:match("^[%d%.%:a-fA-F]+$") then
        write_json({ ip = ip, geo = "无效IP" })
        return
    end

    local cache_file = GEO_CACHE_DIR .. "/" .. ip:gsub("[^%w%.%-_:]", "_")
    fs.mkdirr(GEO_CACHE_DIR)
    local cached = fs.readfile(cache_file)
    if cached and cached ~= "" then
        write_json({ ip = ip, geo = cached:gsub("%s+$", "") })
        return
    end

    -- 先查随包的离线省级地址库，命中时不把访客 IP 发给任何外部服务
    local geo = (sys.exec("/bin/sh /usr/lib/minigate/geo_lookup.sh " .. shellquote(ip) .. " 2>/dev/null") or ""):gsub("%s+$", "")
    if geo == "" then geo = nil end

    -- 境外或离线库未覆盖的地址，再用 HTTPS 接口查询
    if not geo then
        local raw = sys.exec("curl -s --proto '=https' --connect-timeout 1 --max-time 2 " .. shellquote("https://ip9.com.cn/get?ip=" .. ip) .. " 2>/dev/null") or ""
        local loc = (json_field(raw, "country") .. json_field(raw, "prov") .. json_field(raw, "city")):gsub("中国", "")
        local isp = json_field(raw, "isp")
        if isp ~= "" then loc = loc .. " " .. isp end
        loc = loc:gsub("^%s+", ""):gsub("%s+$", "")
        if loc ~= "" then geo = loc end
    end

    if not geo then
        local raw = sys.exec("curl -s --proto '=https' --connect-timeout 1 --max-time 2 " .. shellquote("https://whois.pconline.com.cn/ipJson.jsp?ip=" .. ip .. "&json=true") .. " 2>/dev/null | iconv -f gbk -t utf-8 2>/dev/null") or ""
        local addr = json_field(raw, "addr")
        if addr ~= "" then geo = addr:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "") end
    end

    fs.writefile(cache_file, geo or "未知")
    prune_geo_cache()
    write_json({ ip = ip, geo = geo or "未知" })
end

-- ============== 登录防护 API ==============

local function valid_ban_ip(ip)
    if ip:match("^%d+%.%d+%.%d+%.%d+$") then return true end
    return #ip <= 39 and ip:match("^[%x:]+$") ~= nil and select(2, ip:gsub(":", "")) >= 2
end

local function parse_ban_set(raw, banned)
    -- nft -j 在 key 和 value 之间有空格，要用 %s* 匹配；按 elem 块配对 val 与 expires
    for block in raw:gmatch('{[^{}]-"val"%s*:%s*"[^"]+"[^{}]-}') do
        local ip = block:match('"val"%s*:%s*"([%x:%.]+)"')
        local expires = tonumber(block:match('"expires"%s*:%s*(%d+)') or "")
        if ip and expires then banned[#banned + 1] = { ip = ip, remaining = expires } end
    end
end

function action_lg_status()
    local sys = require "luci.sys"
    local fs = require "nixio.fs"
    local uci = require "luci.model.uci".cursor()

    local watch_limit = tonumber(luci.http.formvalue("watch_limit") or "5") or 5
    if watch_limit ~= 20 and watch_limit ~= 30 then
        watch_limit = 5
    end
    local ban_limit = tonumber(luci.http.formvalue("ban_limit") or "5") or 5
    if ban_limit ~= 20 and ban_limit ~= 30 then
        ban_limit = 5
    end

    local enabled = uci:get("minigate","login_guard","enabled") or "0"
    local threshold = tonumber(uci:get("minigate","login_guard","threshold")) or 3
    local bantime = tonumber(uci:get("minigate","login_guard","bantime")) or 43200
    local window_s = tonumber(uci:get("minigate","login_guard","window")) or 600

    -- 服务是否在跑（procd 以 /bin/sh login_guard.sh run 启动）
    local pid_out = sys.exec("pgrep -f '^/bin/sh /usr/lib/minigate/login_guard.sh run' 2>/dev/null")
    local running = (pid_out ~= nil and pid_out:match("%d") ~= nil)

    local banned = {}
    parse_ban_set(sys.exec("nft -j list set inet fw4 login_banned_v4 2>/dev/null") or "", banned)
    parse_ban_set(sys.exec("nft -j list set inet fw4 login_banned_v6 2>/dev/null") or "", banned)
    -- 按剩余时间倒序
    table.sort(banned, function(a,b) return a.remaining > b.remaining end)
    local banned_total = #banned
    local banned_limited = {}
    for i = 1, math.min(banned_total, ban_limit) do
        banned_limited[#banned_limited + 1] = banned[i]
    end

    -- 失败计数中（读 /var/run/minigate/login-guard/counters/）
    local watching = {}
    local counter_dir = "/var/run/minigate/login-guard/counters"
    local now = os.time()
    if fs.dir(counter_dir) then
        for ip in fs.dir(counter_dir) do
            local path = counter_dir .. "/" .. ip
            local fh = io.open(path, "r")
            if fh then
                local line = fh:read("*l") or ""
                fh:close()
                local first, count = line:match("(%d+)%s+(%d+)")
                if first and count then
                    local first_time = tonumber(first)
                    local stat = fs.stat(path)
                    local last_time = (stat and stat.mtime) or first_time
                    local age = now - first_time
                    if age <= window_s then
                        watching[#watching+1] = {
                            ip = ip,
                            count = tonumber(count),
                            age = age,
                            first_time = first_time,
                            last_time = last_time,
                            last_seen = os.date("%Y-%m-%d %H:%M:%S", last_time)
                        }
                    end
                end
            end
        end
    end
    table.sort(watching, function(a,b)
        return (a.last_time or 0) > (b.last_time or 0)
    end)
    local watching_total = #watching
    local watching_limited = {}
    for i = 1, math.min(watching_total, watch_limit) do
        watching_limited[#watching_limited + 1] = watching[i]
    end

    write_json({
        enabled = enabled,
        running = running,
        threshold = threshold,
        bantime = bantime,
        window = window_s,
        banned = banned_limited,
        banned_total = banned_total,
        ban_limit = ban_limit,
        watching = watching_limited,
        watching_total = watching_total,
        watch_limit = watch_limit
    })
end

function action_lg_ban()
    local sys = require "luci.sys"
    local ip = luci.http.formvalue("ip") or ""
    if not valid_ban_ip(ip) then
        write_json({success=false, error="无效 IP"})
        return
    end
    local rc = sys.call("/bin/sh /usr/lib/minigate/login_guard.sh ban " .. shellquote(ip) .. " >/dev/null 2>&1")
    write_json({success = (rc == 0), ip = ip})
end

function action_lg_unban()
    local sys = require "luci.sys"
    local ip = luci.http.formvalue("ip") or ""
    if not valid_ban_ip(ip) then
        write_json({success=false, error="无效 IP"})
        return
    end
    local rc = sys.call("/bin/sh /usr/lib/minigate/login_guard.sh unban " .. shellquote(ip) .. " >/dev/null 2>&1")
    write_json({success = (rc == 0), ip = ip})
end

function action_lg_flush()
    local sys = require "luci.sys"
    local rc = sys.call("/bin/sh /usr/lib/minigate/login_guard.sh flush >/dev/null 2>&1")
    write_json({success = (rc == 0)})
end
