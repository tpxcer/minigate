const { test } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const lua = process.env.MINIGATE_TEST_LUA;
const controller = path.resolve(__dirname, '../luasrc/controller/minigate.lua');

test('visitor aggregation distinguishes blocked, upstream, legacy and failed requests', { skip: !lua }, () => {
    const input = [
        "local raw, response, limit = '', nil, '50'",
        "package.preload['luci.sys'] = function() return {exec=function() return raw end} end",
        "luci = {http={formvalue=function() return limit end, prepare_content=function() end, write_json=function(v) response=v end}}",
        'dofile(' + JSON.stringify(controller) + ')',
        "local real_time = os.time",
        "os.time = function(v) return v and real_time(v) or real_time({year=2026,month=10,day=26,hour=12,min=0,sec=0}) end",
        "local function row(ip, status, upstream, domain, time)",
        "raw = raw .. '{\"time\":\"' .. (time or '2026-10-26T11:59:00+08:00') .. '\",\"client\":\"' .. ip .. '\",\"domain\":\"' .. (domain or 'app.example.com') .. '\"' ..",
        "(status and ',\"status\":' .. status or '') .. (upstream and ',\"upstream_status\":\"' .. upstream .. '\"' or '') .. '}\\n'",
        "end",
        "row('mixed', 200, '200')",
        "row('mixed', 444, '-')",
        "row('mixed', 308, '-')",
        "row('blocked', 444, '-')",
        "row('default', 400, '-', '_')",
        "row('upstream403', 403, '403')",
        "row('upstream401', 401, '401')",
        "row('legacy200', 200)",
        "row('legacy403', 403)",
        "row('failure', 502, '502')",
        "row('closed', 499, '-')",
        "row('missing', 200, '200')",
        "row('missing', nil, '200', '')",
        "row('old', 200, '200', nil, '2026-10-26T11:54:59+08:00')",
        "row('future', 200, '200', nil, '2026-10-26T12:01:00+08:00')",
        "raw = raw .. 'invalid line\\n'",
        "luci.controller.minigate.action_proxy_access()",
        "local by_ip = {}",
        "for _, v in ipairs(response.visitors) do",
        "by_ip[v.ip] = v",
        "assert(v.count == v.blocked_count + v.forwarded_count + v.other_count)",
        "assert(v.online == nil)",
        "end",
        "local v = by_ip.mixed",
        "assert(v.count == 3 and v.blocked_count == 1 and v.forwarded_count == 1 and v.other_count == 1)",
        "assert(v.outcome == 'responded' and v.status == 308)",
        "assert(by_ip.blocked.outcome == 'blocked' and by_ip.blocked.recent)",
        "assert(by_ip.default.outcome == 'blocked')",
        "assert(by_ip.upstream403.outcome == 'forwarded' and by_ip.upstream403.status == 403)",
        "assert(by_ip.upstream401.outcome == 'forwarded')",
        "assert(by_ip.legacy200.outcome == 'responded')",
        "assert(by_ip.legacy403.outcome == 'error')",
        "assert(by_ip.failure.outcome == 'error' and by_ip.closed.outcome == 'error')",
        "assert(by_ip.missing.outcome == 'unknown' and by_ip.missing.status == nil and by_ip.missing.domain == '')",
        "assert(not by_ip.old.recent and not by_ip.future.recent)",
        "limit = 'invalid'",
        "luci.controller.minigate.action_proxy_access()",
        "assert(#response.visitors == 5)",
        "print('visitor aggregation passed')"
    ].join('\n');
    const result = spawnSync(lua, ['-'], { encoding: 'utf8', input });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.match(result.stdout, /aggregation passed/);
});
