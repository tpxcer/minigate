const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const lua = process.env.MINIGATE_TEST_LUA;
const root = path.resolve(__dirname, '..');
const controller = path.join(root, 'luasrc/controller/minigate.lua');

function runLua(source) {
    const result = spawnSync(lua, ['-'], { encoding: 'utf8', input: source });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return result.stdout.trim();
}

function luaFiles(dir) {
    return fs.readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const full = path.join(dir, entry.name);
        return entry.isDirectory() ? luaFiles(full) : (entry.name.endsWith('.lua') ? [full] : []);
    });
}

test('every LuCI Lua file compiles', { skip: !lua }, () => {
    const files = luaFiles(path.join(root, 'luasrc'));
    assert.ok(files.length >= 6);
    const checks = files.map(file => `assert(loadfile(${JSON.stringify(file)}))`).join('\n');
    runLua(checks + '\nprint("ok")');
});

// 加载控制器时只需要 luci.http；其他模块在函数内部按需 require
const controllerPrelude = `
    local response, status_code, calls, form = nil, nil, {}, {}
    luci = {http={
        formvalue=function(name) return form[name] end,
        prepare_content=function() end,
        write_json=function(v) response=v end,
        status=function(code) status_code=code end
    }}
    package.preload['luci.sys'] = function() return {
        call=function(cmd) calls[#calls + 1] = cmd; return 0 end,
        exec=function() return '' end
    } end
    package.preload['luci.model.uci'] = function() return {cursor=function() return {
        get=function(_, _, sec) if sec == 'cfg01' then return 'ddns' end end,
        foreach=function() end
    } end} end
    dofile(${JSON.stringify(controller)})
    local c = luci.controller.minigate
`;

test('certificate expiry parsing is timezone independent', { skip: !lua }, () => {
    const expected = Date.UTC(2026, 11, 16, 12, 0, 0) / 1000;
    const out = runLua(controllerPrelude + `
        print(c.parse_cert_time('Dec 16 12:00:00 2026 GMT'))
        print(c.parse_cert_time('Feb  1 00:00:00 2028 GMT'))
        print(tostring(c.parse_cert_time('garbage')))
    `);
    assert.deepEqual(out.split('\n'), [String(expected), String(Date.UTC(2028, 1, 1) / 1000), 'nil']);
});

test('log view merges sources by time and keeps untimed lines with their entry', { skip: !lua }, () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-logs-'));
    fs.writeFileSync(path.join(dir, 'ddns.log'), '2026-10-28 10:00:01 [DDNS] a\n2026-10-28 10:00:05 [DDNS] c\n');
    fs.writeFileSync(path.join(dir, 'nginx.log'), '2026/10/28 10:00:03 [emerg] b\n');
    fs.writeFileSync(path.join(dir, 'update.log'), '2026-10-28 10:00:04 start\ncurl output without time\n');
    const out = runLua(controllerPrelude + `
        print(c.merge_logs({{'DDNS', ${JSON.stringify(path.join(dir, 'ddns.log'))}}, {'Nginx', ${JSON.stringify(path.join(dir, 'nginx.log'))}},
            {'更新', ${JSON.stringify(path.join(dir, 'update.log'))}}, {'缺失', '/missing.log'}}, 300))
        print('--')
        print(c.merge_logs({{'DDNS', ${JSON.stringify(path.join(dir, 'ddns.log'))}}}, 1))
    `);
    assert.equal(out, [
        '[DDNS] 2026-10-28 10:00:01 [DDNS] a',
        '[Nginx] 2026/10/28 10:00:03 [emerg] b',
        '[更新] 2026-10-28 10:00:04 start',
        '[更新] curl output without time',
        '[DDNS] 2026-10-28 10:00:05 [DDNS] c',
        '--',
        '[DDNS] 2026-10-28 10:00:05 [DDNS] c'
    ].join('\n'));
});

test('state files are read by the same domain key the shell scripts write', { skip: !lua }, () => {
    const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-state-')), 'proxy.status');
    fs.writeFileSync(file, 'result=ok\nmessage=配置检查通过\nwarning=one\nwarning=two=2\n');
    const out = runLua(controllerPrelude + `
        local st = c.read_state(${JSON.stringify(file)})
        print(st.result, st.message, #st.warnings, st.warnings[2])
        print(c.state_key('*.example.com'), c.state_key('home.example.com'))
        print(tostring(c.read_state('/missing/state')))
    `);
    assert.equal(out, 'ok\t配置检查通过\t2\ttwo=2\n__example_com\thome_example_com\nnil');
});

test('login guard endpoints accept IPv6, quote the address and reject shell text', { skip: !lua }, () => {
    const out = runLua(controllerPrelude + `
        for _, ip in ipairs({'2001:db8::1', '198.51.100.7', "1.2.3.4'; reboot; '", 'abc'}) do
            form.ip = ip; calls = {}; response = nil
            c.action_lg_ban()
            print(response.success and calls[1] or 'rejected')
        end
    `);
    assert.equal(out, [
        "/bin/sh /usr/lib/minigate/login_guard.sh ban '2001:db8::1' >/dev/null 2>&1",
        "/bin/sh /usr/lib/minigate/login_guard.sh ban '198.51.100.7' >/dev/null 2>&1",
        'rejected',
        'rejected'
    ].join('\n'));
});

test('manual DDNS sync starts a background job only for a real DDNS section', { skip: !lua }, () => {
    const out = runLua(controllerPrelude + `
        form.section = 'cfg01'; c.action_ddns_sync()
        print(response.success, calls[1])
        form.section = 'cfg01;reboot'; calls = {}; c.action_ddns_sync()
        print(response.success, status_code, #calls)
    `);
    const [started, rejected] = out.split('\n');
    assert.match(started, /^true\t\( \/bin\/sh \/usr\/lib\/minigate\/job\.sh ddns-cfg01 \/bin\/sh \/usr\/lib\/minigate\/ddns\.sh single 'cfg01' \) <\/dev\/null >\/dev\/null 2>&1 &$/);
    assert.equal(rejected, 'false\t400\t0');
});

// 用最小 CBI 桩加载每个页面，并执行表单渲染时会调用的 cfgvalue
const cbiPrelude = `
    local options = {}
    local function node()
        local n = {}
        function n:option(kind, name, title)
            local o = {kind=kind, name=name, choices={}}
            function o:value(k, v) self.choices[k] = v or k end
            function o:depends() end
            options[name] = o
            return o
        end
        function n:tab() end
        function n:taboption(_, ...) return n:option(...) end
        return n
    end
    function Map(config, title)
        local m = node()
        m.title = title
        m.uci = {get=function(_, _, sec, opt) local v; if opt == 'domain' then v = 'home.example.com' end; return v end}
        function m:section() return node() end
        return m
    end
    for _, name in ipairs({'Flag','Value','DynamicList','ListValue','DummyValue','MultiValue','NamedSection','TypedSection','SimpleSection'}) do _G[name] = name end
    luci = {dispatcher={build_url=function(...) return '/cgi-bin/luci/' .. table.concat({...}, '/') end}}
    package.preload['luci.sys'] = function() return {exec=function() return '' end, call=function() return 0 end} end
    package.preload['nixio.fs'] = function() return {access=function() return false end, dir=function() return nil end, stat=function() return nil end} end
    package.preload['luci.model.uci'] = function() return {cursor=function() return {
        foreach=function(_, config, kind, fn) if kind == 'ddns' then fn({domain='home.example.com'}); fn({domain='*.example.com'}) end end,
        get=function(_, _, _, opt) local v; if opt == 'staging' then v = '1' end; return v end
    } end} end
    package.preload['luci.controller.minigate'] = function() return {
        ddns_state=function() return {status='error', message='IPv4 192.168.2.2 不是公网地址', ip='198.51.100.1'} end,
        cert_list=function() return {{domain='*.example.com', expires_date='2026-11-02', days_left=5, staging=true}} end
    } end
    package.preload['luci.cbi.datatypes'] = function() return {
        ip4addr=function(v) return v:match('^%d+%.%d+%.%d+%.%d+$') ~= nil end,
        ip6addr=function(v) return v:match('^[%x:]+$') ~= nil and v:find(':') ~= nil end
    } end
    local function page(name) return assert(dofile(${JSON.stringify(path.join(root, 'luasrc/model/cbi/minigate'))} .. '/' .. name .. '.lua')) end
`;

test('every LuCI page loads and renders its status blocks', { skip: !lua }, () => {
    const out = runLua(cbiPrelude + `
        for _, name in ipairs({'general', 'ddns', 'acme', 'proxy', 'login_guard'}) do
            options = {}
            local m = page(name)
            assert(m.title:match('^MiniGate'), name .. ' title')
            for key, o in pairs(options) do
                if o.kind == 'DummyValue' and type(o.cfgvalue) == 'function' then
                    assert(type(o.cfgvalue(o, 'cfg01')) == 'string', name .. '.' .. key)
                end
            end
        end
        options = {}; page('ddns')
        print(options._info.cfgvalue(options._info, 'cfg01'):match('不是公网地址') ~= nil)
        options = {}; page('acme')
        local certs = options._certs.cfgvalue(options._certs)
        print(certs:match('剩 5 天') ~= nil, certs:match('测试证书') ~= nil, certs:match('测试模式已开启') ~= nil)
        options = {}; page('general')
        print(options.enabled ~= nil, options.ipv6_listen == nil)
    `);
    assert.equal(out, 'true\ntrue\ttrue\ttrue\ntrue\ttrue');
});

test('LuCI forms validate domains, Cloudflare IDs, intervals, thresholds and whitelists', { skip: !lua }, () => {
    const out = runLua(cbiPrelude + `
        local function ok(o, v) return (o.validate(o, v, 'cfg01')) ~= nil end
        options = {}; page('ddns')
        print(ok(options.domain, 'home.example.com'), ok(options.domain, '*.example.com'), ok(options.domain, 'bad domain.com'),
            ok(options.domain, '-a.example.com'), ok(options.domain, 'localhost'))
        print(ok(options.cf_zone_id, string.rep('a1', 16)), ok(options.cf_zone_id, 'zone'), ok(options.cf_api_token, 'abc_DEF-123'), ok(options.cf_api_token, 'abc def'))
        print(ok(options.check_interval, '300'), ok(options.check_interval, '60'))
        options = {}; page('proxy')
        print(ok(options.prefix, 'app'), ok(options.prefix, 'a.b'), ok(options.prefix, '-x'), options.target_addr.datatype)
        options = {}; page('login_guard')
        print(options.threshold.datatype, ok(options.whitelist, {'203.0.113.0/20', '2001:db8::/48', '8.8.8.8'}), ok(options.whitelist, {'1.2.3.0/255.255.255.0'}), ok(options.whitelist, '10.0.0.0/33'))
    `);
    assert.equal(out, [
        'true\ttrue\tfalse\tfalse\tfalse',
        'true\tfalse\ttrue\tfalse',
        'true\tfalse',
        'true\tfalse\tfalse\thost',
        'range(1,100)\ttrue\tfalse\tfalse'
    ].join('\n'));
});
