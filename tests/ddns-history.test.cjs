const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const ddnsScript = path.join(root, 'root/usr/lib/minigate/ddns.sh');
const controller = fs.readFileSync(path.join(root, 'luasrc/controller/minigate.lua'), 'utf8');
const model = fs.readFileSync(path.join(root, 'luasrc/model/cbi/minigate/ddns.lua'), 'utf8');
const view = fs.readFileSync(path.join(root, 'luasrc/view/minigate/ddns_history.htm'), 'utf8');

function runHistory(script, options = {}) {
    const historyDir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-ddns-history-'));
    const command = [
        'set -eu',
        'export MINIGATE_DDNS_LIBRARY_ONLY=1',
        `export MINIGATE_HISTORY_DIR=${JSON.stringify(historyDir)}`,
        `export MINIGATE_HISTORY_WINDOW=${options.window || 86400}`,
        `. ${JSON.stringify(ddnsScript)}`,
        script
    ].join('\n');
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    return { historyDir, output: result.stdout.trim() };
}

function readRows(file) {
    return fs.readFileSync(file, 'utf8').trim().split('\n').filter(Boolean);
}

function runUpdateScenario({ cfResult, cachedIp = '', refreshResult = 0 }) {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-ddns-update-'));
    const cacheFile = path.join(tempDir, 'minigate_ddns_cfg01.cache');
    const refreshLog = path.join(tempDir, 'refresh.log');
    const uciLog = path.join(tempDir, 'uci.log');
    if (cachedIp) fs.writeFileSync(cacheFile, `${cachedIp}\n`);

    const command = `
        set -u
        export MINIGATE_DDNS_LIBRARY_ONLY=1
        export MINIGATE_CACHE_DIR=${JSON.stringify(tempDir)}
        export MINIGATE_HISTORY_DIR=${JSON.stringify(path.join(tempDir, 'history'))}
        export MINIGATE_DDNS_LOG=${JSON.stringify(path.join(tempDir, 'ddns.log'))}
        . ${JSON.stringify(ddnsScript)}
        uci() {
            [ "\${1:-}" = "-q" ] && shift
            case "\${1:-}:\${2:-}" in
                get:minigate.cfg01.enabled) printf '1\\n' ;;
                get:minigate.cfg01.domain) printf '*.example.com\\n' ;;
                get:minigate.cfg01.cf_zone_id) printf 'zone\\n' ;;
                get:minigate.cfg01.cf_api_token) printf 'token\\n' ;;
                get:minigate.cfg01.ip_source) printf 'url\\n' ;;
                get:minigate.cfg01.interface) printf 'wan\\n' ;;
                get:minigate.cfg01.ip_url) printf 'http://ip.example/\\n' ;;
                get:minigate.cfg01.check_interval) printf '300\\n' ;;
                get:minigate.cfg01.ip_version) printf 'ipv4\\n' ;;
                set:*) printf '%s\\n' "\$2" >> ${JSON.stringify(uciLog)} ;;
            esac
            return 0
        }
        get_ip4_url() { printf '198.51.100.20\\n'; }
        record_ip_history() { return 0; }
        calc_next() { printf '12:00:00\\n'; }
        cf_update() {
            printf '%s\\n' ${JSON.stringify(cfResult)}
            [ ${JSON.stringify(cfResult)} != false ]
        }
        refresh_local_dns_caches() {
            printf '%s\\n' "\$1" >> ${JSON.stringify(refreshLog)}
            return ${Number(refreshResult)}
        }
        update_one cfg01 1
    `;
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
    const refreshes = fs.existsSync(refreshLog) ? readRows(refreshLog) : [];
    const uciWrites = fs.existsSync(uciLog) ? readRows(uciLog) : [];
    const cache = fs.existsSync(cacheFile) ? fs.readFileSync(cacheFile, 'utf8').trim() : '';
    return { result, refreshes, uciWrites, cache };
}

function runCloudflareScenario(mode) {
    const command = `
        set -u
        export MINIGATE_DDNS_LIBRARY_ONLY=1
        . ${JSON.stringify(ddnsScript)}
        CF_MODE=${JSON.stringify(mode)}
        curl() {
            case "\$*" in
                *'-X PUT'*|*'-X DELETE'*|*'-X POST'*) printf 'WRITE\\n' ;;
                *'&content='*) printf 'MATCH\\n' ;;
                *) printf 'LIST\\n' ;;
            esac
        }
        jsonfilter() {
            input=; IFS= read -r input || true
            expression="\${2:-}"
            case "\$expression:\$input:\$CF_MODE" in
                '$.success:'*) [ "\$CF_MODE" = failure ] && printf 'false\\n' || printf 'true\\n' ;;
                '$.result[*].id:LIST:create') ;;
                '$.result[*].id:LIST:duplicates') printf 'r1\\nr2\\n' ;;
                '$.result[*].id:LIST:'*) printf 'r1\\n' ;;
                '$.result[0].id:MATCH:unchanged'|'$.result[0].id:MATCH:duplicates') printf 'r1\\n' ;;
            esac
        }
        cf_update zone token example.com 198.51.100.20 A
    `;
    return spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
}

test('DDNS history records only actual IPv4 changes', () => {
    const { historyDir, output } = runHistory(`
        export MINIGATE_HISTORY_NOW=100000
        record_ip_history cfg01 ipv4 198.51.100.10
        printf sentinel > "$MINIGATE_HISTORY_DIR/cfg01.ipv4.tsv.lock"
        export MINIGATE_HISTORY_NOW=100060
        record_ip_history cfg01 ipv4 198.51.100.10
        cat "$MINIGATE_HISTORY_DIR/cfg01.ipv4.tsv.lock"
        export MINIGATE_HISTORY_NOW=100120
        record_ip_history cfg01 ipv4 198.51.100.11
    `);
    assert.equal(output, 'sentinel', 'unchanged IP must not reopen the history lock file');
    assert.deepEqual(readRows(path.join(historyDir, 'cfg01.ipv4.tsv')), [
        '100000\t198.51.100.10',
        '100120\t198.51.100.11'
    ]);
    assert.equal(fs.statSync(path.join(historyDir, 'cfg01.ipv4.tsv')).mode & 0o777, 0o600);
});

test('DDNS history keeps one anchor before the rolling window', () => {
    const { historyDir } = runHistory(`
        export MINIGATE_HISTORY_NOW=100
        record_ip_history cfg02 ipv4 192.0.2.1
        export MINIGATE_HISTORY_NOW=150
        record_ip_history cfg02 ipv4 192.0.2.2
        export MINIGATE_HISTORY_NOW=250
        record_ip_history cfg02 ipv4 192.0.2.3
        export MINIGATE_HISTORY_NOW=400
        record_ip_history cfg02 ipv4 192.0.2.4
    `, { window: 100 });
    assert.deepEqual(readRows(path.join(historyDir, 'cfg02.ipv4.tsv')), [
        '250\t192.0.2.3',
        '400\t192.0.2.4'
    ]);
});

test('IPv4 and IPv6 histories stay separate and domain names are safe', () => {
    const { historyDir } = runHistory(`
        export MINIGATE_HISTORY_NOW=200000
        record_ip_history '*.example.com' ipv4 203.0.113.7
        record_ip_history '*.example.com' ipv6 2001:db8::7
    `);
    assert.deepEqual(readRows(path.join(historyDir, '__example_com.ipv4.tsv')), ['200000\t203.0.113.7']);
    assert.deepEqual(readRows(path.join(historyDir, '__example_com.ipv6.tsv')), ['200000\t2001:db8::7']);
});

test('DDNS writer and controller both use the domain history key', () => {
    const shellKey = fs.readFileSync(ddnsScript, 'utf8');
    assert.match(shellKey, /record_ip_history "\$domain" "ipv4" "\$ip4"/);
    assert.match(shellKey, /record_ip_history "\$domain" "ipv6" "\$ip6"/);
    assert.match(controller, /history_section_name\(section\.domain\) \.\. "\." \.\. family \.\. "\.tsv"/);
    assert.doesNotMatch(controller, /history_section_name\(section\.name\)/);
});

test('Cloudflare updater distinguishes unchanged records from authoritative changes', () => {
    for (const mode of ['create', 'replace', 'duplicates']) {
        const result = runCloudflareScenario(mode);
        assert.equal(result.status, 0, `${mode}: ${result.stderr || result.stdout}`);
        assert.equal(result.stdout.trim(), 'changed', mode);
    }
    const unchanged = runCloudflareScenario('unchanged');
    assert.equal(unchanged.status, 0, unchanged.stderr || unchanged.stdout);
    assert.equal(unchanged.stdout.trim(), 'unchanged');

    const failure = runCloudflareScenario('failure');
    assert.notEqual(failure.status, 0);
    assert.equal(failure.stdout.trim(), 'false');
});

test('successful Cloudflare changes refresh local DNS caches once', () => {
    const scenario = runUpdateScenario({ cfResult: 'changed' });
    assert.equal(scenario.result.status, 0, scenario.result.stderr || scenario.result.stdout);
    assert.deepEqual(scenario.refreshes, ['*.example.com']);
    assert.equal(scenario.cache, '198.51.100.20');
    assert.ok(scenario.uciWrites.includes('minigate.cfg01.status=ok'));
});

test('unchanged forced sync does not flush caches, but a stale local IP does', () => {
    const current = runUpdateScenario({ cfResult: 'unchanged', cachedIp: '198.51.100.20' });
    assert.equal(current.result.status, 0, current.result.stderr || current.result.stdout);
    assert.deepEqual(current.refreshes, []);

    const stale = runUpdateScenario({ cfResult: 'unchanged', cachedIp: '198.51.100.19' });
    assert.equal(stale.result.status, 0, stale.result.stderr || stale.result.stdout);
    assert.deepEqual(stale.refreshes, ['*.example.com']);
    assert.equal(stale.cache, '198.51.100.20');
});

test('Cloudflare failure never flushes local caches', () => {
    const scenario = runUpdateScenario({ cfResult: 'false', cachedIp: '198.51.100.19' });
    assert.equal(scenario.result.status, 0, scenario.result.stderr || scenario.result.stdout);
    assert.deepEqual(scenario.refreshes, []);
    assert.equal(scenario.cache, '198.51.100.19');
    assert.ok(scenario.uciWrites.includes('minigate.cfg01.status=error'));
});

test('cache refresh failure does not turn a successful DDNS update into an error', () => {
    const scenario = runUpdateScenario({ cfResult: 'changed', refreshResult: 1 });
    assert.equal(scenario.result.status, 0, scenario.result.stderr || scenario.result.stdout);
    assert.deepEqual(scenario.refreshes, ['*.example.com']);
    assert.ok(scenario.uciWrites.includes('minigate.cfg01.status=ok'));
});

test('local cache refresh uses sing-box API and dnsmasq SIGHUP without service restart', () => {
    const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-dns-flush-'));
    const config = path.join(tempDir, 'config.json');
    const calls = path.join(tempDir, 'calls.log');
    fs.writeFileSync(config, '{}\n');
    const command = `
        set -eu
        export MINIGATE_DDNS_LIBRARY_ONLY=1
        export MINIGATE_SINGBOX_CONFIG=${JSON.stringify(config)}
        export MINIGATE_CLASH_API_URL=http://127.0.0.1:19095
        export MINIGATE_DDNS_LOG=${JSON.stringify(path.join(tempDir, 'ddns.log'))}
        . ${JSON.stringify(ddnsScript)}
        jsonfilter() { printf 'local-secret\\n'; }
        curl() { printf 'curl %s\\n' "\$*" >> ${JSON.stringify(calls)}; sed 's/^/header /' >> ${JSON.stringify(calls)}; printf '204'; }
        pidof() { [ "\$1" = dnsmasq ] && printf '101 202\\n'; }
        send_hup() { printf 'hup %s\\n' "\$*" >> ${JSON.stringify(calls)}; }
        refresh_local_dns_caches '*.example.com'
    `;
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    const callLog = fs.readFileSync(calls, 'utf8');
    const curlLine = callLog.split('\n').find(line => line.startsWith('curl ')) || '';
    assert.match(callLog, /curl .* -X POST -H @- http:\/\/127\.0\.0\.1:19095\/cache\/dns\/flush/);
    assert.match(callLog, /header Authorization: Bearer local-secret/);
    assert.doesNotMatch(curlLine, /local-secret/, 'secret must not appear in the curl process arguments');
    assert.match(callLog, /hup 101 202/);
    assert.doesNotMatch(callLog, /restart|reload|stop|start/);
});

test('controller exposes a read-only rolling 24-hour history endpoint', () => {
    assert.match(controller, /entry\(\{"admin","services","minigate","ddns_history"\}, call\("action_ddns_history"\)\)/);
    assert.match(controller, /local cutoff = now - 86400/);
    assert.match(controller, /if end_time > cutoff and event\.timestamp <= now then/);
    assert.match(controller, /duration=math\.max\(0, end_time - event\.timestamp\)/);
    assert.match(controller, /active=\(next_event == nil\)/);
    assert.doesNotMatch(controller, /ddns_history"\}, post\(/);
});

test('DDNS page includes responsive history controls and required columns', () => {
    assert.match(model, /s\.template="minigate\/ddns_history"/);
    for (const text of ['最近一天 IP 变化明细', 'IP 地址', '开始时间', '结束时间', '持续时间', '使用中']) {
        assert.match(view, new RegExp(text));
    }
    assert.match(view, /@media\(max-width:640px\)/);
    assert.match(view, /data-darkmode="true"/);
    assert.match(view, /refresh\.disabled=true/);
    assert.match(view, /textContent/);
});

test('DDNS page treats an empty JSON object as an empty array', () => {
    const match = view.match(/function asArray\(value\)\{([\s\S]*?)\n    \}/);
    assert.ok(match, 'asArray helper must exist');
    const asArray = Function('value', match[1]);
    assert.deepEqual(asArray([]), []);
    assert.deepEqual(asArray({}), []);
    assert.equal(asArray({ unexpected: true }), null);
    assert.equal(asArray(null), null);
    assert.match(view, /nextRecords===null/);
    assert.match(view, /records=nextRecords/);
});
