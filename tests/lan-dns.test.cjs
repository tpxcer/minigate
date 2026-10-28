const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/proxy.sh');
const HEADER = '# MiniGate 局域网直连解析，由 proxy.sh 自动生成';

const SITES = {
    '000_default_2000_1_1_.conf': 'server {\n    listen unix:/var/run/minigate/https_2000.sock default_server ssl proxy_protocol;\n    server_name _;\n    return 444;\n}\n',
    'site_1.conf': 'server {\n    listen unix:/var/run/minigate/https_2000.sock ssl proxy_protocol;\n    server_name ly.example.com;\n}\nserver {\n    listen unix:/var/run/minigate/http_2000.sock proxy_protocol;\n    server_name ly.example.com;\n    return 308 https://ly.example.com:2000$request_uri;\n}\n',
    'site_2.conf': 'server {\n    listen 2000 ssl;\n    server_name box.example.com;\n}\n',
    'site_3.conf': 'server {\n    listen 443 ssl;\n    server_name *.wild.example.com;\n}\n'
};

function sandbox({ sites = SITES, hosts } = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lan-dns-test-'));
    const sitesDir = path.join(dir, 'sites');
    fs.mkdirSync(sitesDir);
    for (const [name, content] of Object.entries(sites)) fs.writeFileSync(path.join(sitesDir, name), content);
    const hostsFile = path.join(dir, 'hosts', 'minigate');
    if (hosts !== undefined) {
        fs.mkdirSync(path.dirname(hostsFile));
        fs.writeFileSync(hostsFile, hosts);
    }
    return { dir, sitesDir, hostsFile, hupLog: path.join(dir, 'hup.log'), logFile: path.join(dir, 'proxy.log') };
}

// 以库模式加载 proxy.sh，替换 uci/ubus/pidof/send_hup 后执行一段命令
function runLibrary(box, body, { lanDns = '1', lanIp = '', ifaceIp = '192.168.2.2', networkIp = '' } = {}) {
    const command = `
        set -u
        export MINIGATE_PROXY_LIBRARY_ONLY=1
        export MINIGATE_SITES_DIR=${JSON.stringify(box.sitesDir)}
        export MINIGATE_LAN_HOSTS_FILE=${JSON.stringify(box.hostsFile)}
        export MINIGATE_LOGFILE=${JSON.stringify(box.logFile)}
        . ${JSON.stringify(script)}
        uci() {
            [ "\${1:-}" = "-q" ] && shift
            case "\${1:-}:\${2:-}" in
                get:minigate.global.lan_dns) printf '%s\\n' ${JSON.stringify(lanDns)} ;;
                get:minigate.global.lan_ip) [ -n ${JSON.stringify(lanIp)} ] && printf '%s\\n' ${JSON.stringify(lanIp)} ;;
                get:network.lan.ipaddr) [ -n ${JSON.stringify(networkIp)} ] && printf '%s\\n' ${JSON.stringify(networkIp)} ;;
            esac
            return 0
        }
        ubus() { [ -n ${JSON.stringify(ifaceIp)} ] && printf '%s\\n' ${JSON.stringify(ifaceIp)}; }
        jsonfilter() { cat; }
        pidof() { printf '101 102\\n'; }
        send_hup() { printf '%s\\n' "$*" >> ${JSON.stringify(box.hupLog)}; }
        ${body}
    `;
    return spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
}

const read = file => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : null);
const hups = box => (read(box.hupLog) || '').split('\n').filter(Boolean);

test('enabled sync maps every concrete site domain to the LAN address and reloads dnsmasq once', () => {
    const box = sandbox();
    let result = runLibrary(box, 'sync_lan_hosts');
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), `${HEADER}\n192.168.2.2 box.example.com\n192.168.2.2 ly.example.com\n`);
    assert.deepEqual(hups(box), ['101 102']);
    assert.match(read(box.logFile), /局域网直连解析 -> 192\.168\.2\.2: box\.example\.com ly\.example\.com/);

    // 内容不变时不再重载，避免每次保存都清空 dnsmasq 缓存
    result = runLibrary(box, 'sync_lan_hosts');
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(hups(box), ['101 102']);
});

test('a changed address rewrites the file and reloads again', () => {
    const box = sandbox({ hosts: `${HEADER}\n192.168.2.9 box.example.com\n192.168.2.9 ly.example.com\n` });
    const result = runLibrary(box, 'sync_lan_hosts');
    assert.equal(result.status, 0, result.stderr);
    assert.match(read(box.hostsFile), /^192\.168\.2\.2 box\.example\.com$/m);
    assert.deepEqual(hups(box), ['101 102']);
});

test('a manual LAN address takes priority over the interface address', () => {
    const box = sandbox();
    const result = runLibrary(box, 'sync_lan_hosts', { lanIp: '10.0.0.5' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), `${HEADER}\n10.0.0.5 box.example.com\n10.0.0.5 ly.example.com\n`);
});

test('without interface status the first network.lan.ipaddr entry is used without its prefix', () => {
    const box = sandbox();
    const result = runLibrary(box, 'get_lan_ip', { ifaceIp: '', networkIp: '192.168.9.1/24 192.168.10.1/24' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), '192.168.9.1');
});

test('an invalid LAN address writes nothing and removes a stale file', () => {
    const box = sandbox({ hosts: `${HEADER}\n192.168.2.2 box.example.com\n` });
    const result = runLibrary(box, 'sync_lan_hosts', { lanIp: '192.168.1.300' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), null);
    assert.deepEqual(hups(box), ['101 102']);
    assert.match(read(box.logFile), /未取得有效的 LAN IPv4 地址/);
});

test('disabling removes the file once and does not reload when nothing was written', () => {
    const box = sandbox({ hosts: `${HEADER}\n192.168.2.2 box.example.com\n` });
    let result = runLibrary(box, 'sync_lan_hosts', { lanDns: '0' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), null);
    assert.deepEqual(hups(box), ['101 102']);

    result = runLibrary(box, 'sync_lan_hosts', { lanDns: '0' });
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(hups(box), ['101 102']);
});

test('no generated sites means no hosts file', () => {
    const box = sandbox({ sites: { '000_default_443_1_0_.conf': 'server {\n    server_name _;\n}\n' } });
    const result = runLibrary(box, 'sync_lan_hosts');
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), null);
    assert.deepEqual(hups(box), []);
});

test('reload syncs LAN hosts only after nginx accepted the new configuration', () => {
    const box = sandbox();
    const body = ok => `
        uci() { echo 1; }
        lock_proxy() { :; }
        prepare_config() { return ${ok ? 0 : 1}; }
        apply_config() { return 0; }
        sync_lan_hosts() { echo synced; }
        do_reload
    `;
    let result = runLibrary(box, body(true));
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'synced');

    result = runLibrary(box, body(false));
    assert.equal(result.status, 1);
    assert.equal(result.stdout.trim(), '');
});

test('proxy.sh stop removes the LAN hosts file', () => {
    const box = sandbox({ hosts: `${HEADER}\n192.168.2.2 box.example.com\n` });
    const bin = path.join(box.dir, 'bin');
    fs.mkdirSync(bin);
    fs.writeFileSync(path.join(bin, 'pidof'), '#!/bin/sh\nexit 1\n', { mode: 0o755 });
    const result = spawnSync('/bin/sh', [script, 'stop'], {
        encoding: 'utf8',
        env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            MINIGATE_PID_FILE: path.join(box.dir, 'missing.pid'),
            MINIGATE_LAN_HOSTS_FILE: box.hostsFile,
            MINIGATE_LOGFILE: box.logFile
        }
    });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(read(box.hostsFile), null);
    assert.match(read(box.logFile), /局域网直连解析已移除/);
});

test('LuCI exposes the toggle and an optional IPv4 address, disabled by default', () => {
    const page = fs.readFileSync(path.join(root, 'luasrc/model/cbi/minigate/proxy.lua'), 'utf8');
    const config = fs.readFileSync(path.join(root, 'root/etc/config/minigate'), 'utf8');
    assert.match(page, /s:option\(Flag, "lan_dns", "启用局域网直连解析"\)\no\.default = "0"/);
    assert.match(page, /s:option\(Value, "lan_ip",[^\n]*\)\no\.datatype = "ip4addr"/);
    assert.match(page, /o:depends\("lan_dns", "1"\)/);
    assert.match(config, /option lan_dns '0'/);
});
