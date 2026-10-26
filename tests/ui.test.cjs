const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');

function pageScript(file) {
    const source = fs.readFileSync(path.join(root, file), 'utf8');
    const start = source.indexOf('<script type="text/javascript">');
    const end = source.indexOf('</script>', start);
    return source.slice(start + '<script type="text/javascript">'.length, end).replace(/\]\] \.\. (\w+) \.\. \[\[/g, '$1');
}

function fakePage(script, { storageBlocked = false } = {}) {
    const elements = new Map();
    const element = id => {
        if (!elements.has(id)) {
            elements.set(id, {
                id, style: { setProperty() {} }, className: '', textContent: '', innerHTML: '', value: '',
                disabled: false, checked: false, hidden: false, children: [],
                setAttribute() {}, getAttribute() { return ''; }, focus() {}, appendChild() {}, insertBefore() {},
                querySelector(selector) { return selector === 'table' && this.innerHTML.includes('<table') ? {} : null; },
                querySelectorAll() { return []; }, contains() { return false; }
            });
        }
        return elements.get(id);
    };
    const listeners = {};
    const requests = [];
    const intervals = [];
    const document = {
        hidden: false, body: { style: {} }, activeElement: null,
        getElementById: element, querySelector: () => null, querySelectorAll: () => [],
        addEventListener: (name, handler) => { listeners[name] = handler; }
    };
    const request = method => (url, data, callback) => { requests.push({ method, url, data, callback }); };
    const context = vm.createContext({
        document, location: { reload() {} }, getComputedStyle: () => ({ getPropertyValue: () => '' }),
        localStorage: storageBlocked
            ? { getItem() { throw new Error('storage blocked'); }, setItem() { throw new Error('storage blocked'); } }
            : { getItem() { return null; }, setItem() {} },
        setTimeout: callback => { callback(); return 0; }, setInterval: callback => { intervals.push(callback); return intervals.length; },
        clearInterval() {}, confirm: () => true, alert() {},
        XHR: { get: request('GET'), post: request('POST') }
    });
    vm.runInContext(script, context);
    return { context, document, element, listeners, requests, intervals };
}

const overviewScript = pageScript('luasrc/model/cbi/minigate/general.lua');
const loginGuardScript = pageScript('luasrc/model/cbi/minigate/login_guard.lua');
const take = (page, url) => {
    const index = page.requests.findIndex(item => item.url === url);
    assert.ok(index >= 0, `missing request ${url}`);
    return page.requests.splice(index, 1)[0];
};

test('overview loads even when browser storage is blocked', () => {
    const page = fakePage(overviewScript, { storageBlocked: true });
    assert.deepEqual(page.requests.map(item => item.url).sort(), ['au', 'su', 'xu']);
});

test('overview treats an empty visitor object as no records and keeps errors distinct', () => {
    const page = fakePage(overviewScript);
    take(page, 'au').callback(null, { visitors: {} });
    assert.match(page.element('mg-v-list').innerHTML, /暂无访问记录/);
    assert.equal(page.element('mg-v-count').textContent, '');

    const failed = fakePage(overviewScript);
    take(failed, 'au').callback(null, null);
    assert.match(failed.element('mg-v-list').innerHTML, /读取失败/);
    take(failed, 'su').callback(null, null);
    assert.match(failed.element('mg-d1').innerHTML, /读取失败/);
});

test('overview shows cached locations immediately instead of flashing a lookup state', () => {
    const page = fakePage(overviewScript);
    const visitors = { visitors: [{ ip: '198.51.100.7', last_time: '2026-10-14T08:00:00+08:00', domain: 'a.example.com', count: 2, online: true }] };
    take(page, 'au').callback(null, visitors);
    take(page, 'gu').callback(null, { geo: '四川成都 电信' });
    assert.match(page.element('geo-0').innerHTML, /四川成都 电信/);

    page.context.loadVisitors();
    take(page, 'au').callback(null, visitors);
    assert.match(page.element('mg-v-list').innerHTML, /四川成都 电信/);
    assert.doesNotMatch(page.element('mg-v-list').innerHTML, /查询中/);
    assert.equal(page.requests.some(item => item.url === 'gu'), false);
});

test('overview polling pauses in a hidden tab and refreshes when visible again', () => {
    const page = fakePage(overviewScript);
    take(page, 'su').callback(null, { ddns_list: {}, proxy_rules: {}, acme: {} });
    take(page, 'au').callback(null, { visitors: [] });
    page.requests.length = 0;
    page.document.hidden = true;
    page.intervals.forEach(callback => callback());
    assert.equal(page.requests.length, 0);
    page.document.hidden = false;
    page.listeners.visibilitychange();
    assert.deepEqual(page.requests.map(item => item.url).sort(), ['au', 'su']);
});

test('overview distinguishes request results and never labels blocked requests as online', () => {
    const page = fakePage(overviewScript);
    const visitors = ['blocked', 'forwarded', 'responded', 'error', 'unknown'].map((outcome, i) => ({
        ip: '198.51.100.' + (i + 1), last_time: '2026-10-26T11:59:00+08:00', domain: 'app.example.com',
        outcome, status: [444, 403, 308, 502, null][i], recent: i === 0,
        count: 6, blocked_count: i === 0 ? 0 : 1, forwarded_count: 2, other_count: 3
    }));
    take(page, 'au').callback(null, { visitors });
    const html = page.element('mg-v-list').innerHTML;
    for (const label of ['已拦截', '已转发', '已响应', '请求失败', '结果未知', 'HTTP 444', 'HTTP 403',
        '无状态码', '近5分钟有请求', '5分钟内无新请求', '总计 6', '拦截 1 · 转发 2 · 其他 3', '拦截 0 · 转发 2 · 其他 3']) {
        assert.ok(html.includes(label), label);
    }
    assert.doesNotMatch(html, /在线|离线|mg-dot/);
});

test('overview renders legacy visitor responses as unknown and escapes log content', () => {
    const page = fakePage(overviewScript);
    take(page, 'au').callback(null, { visitors: [{
        ip: '198.51.100.1', domain: '<img src=x onerror=alert(1)>', count: 1,
        last_time: '2026-10-26T11:59:00+08:00', online: true
    }] });
    const html = page.element('mg-v-list').innerHTML;
    assert.match(html, /结果未知/);
    assert.match(html, /请求时间未知/);
    assert.match(html, /&lt;img/);
    assert.doesNotMatch(html, /<img|已转发|在线|离线|拦截 undefined/);
});

test('login guard renders empty JSON objects as empty lists and uses POST for changes', () => {
    const page = fakePage(loginGuardScript);
    take(page, 'lu').callback(null, { enabled: '1', running: true, banned: {}, banned_total: 0, watching: {}, watching_total: 0, threshold: 3 });
    assert.match(page.element('lg-banned-list').innerHTML, /暂无封禁/);
    assert.match(page.element('lg-watching-list').innerHTML, /无/);
    assert.doesNotMatch(page.element('lg-banned-list').innerHTML, /<table/);

    page.element('lg-ban-input').value = '198.51.100.9';
    page.context.lgManualBan();
    page.context.lgFlushAll();
    assert.deepEqual(page.requests.filter(item => item.url !== 'lu').map(item => `${item.method} ${item.url}`), ['POST bu', 'POST fu']);
});

test('state-changing LuCI endpoints require POST with the CSRF token', () => {
    const controller = fs.readFileSync(path.join(root, 'luasrc/controller/minigate.lua'), 'utf8');
    for (const name of ['acme_install', 'acme_issue', 'ddns_sync', 'lg_ban', 'lg_unban', 'lg_flush', 'update_apply', 'uninstall']) {
        assert.match(controller, new RegExp(`"${name}"\\}, post\\("action_${name}"\\)\\)`), name);
    }
    const ddns = fs.readFileSync(path.join(root, 'luasrc/model/cbi/minigate/ddns.lua'), 'utf8');
    const acme = fs.readFileSync(path.join(root, 'luasrc/model/cbi/minigate/acme.lua'), 'utf8');
    assert.match(ddns, /XHR\.post\("\]\]\.\.url\.\.\[\[",\{section:s\}/);
    assert.doesNotMatch(acme, /XHR\.get\(/);
    assert.match(controller, /sec:match\("\^\[%w_\]\+\$"\)/);
});
