const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/proxy.sh');

function trim(files, maxAccess = 4096) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-proxy-log-test-'));
    const paths = {};
    for (const [name, content] of Object.entries(files)) {
        paths[name] = path.join(dir, name);
        fs.writeFileSync(paths[name], content);
    }
    const result = spawnSync('/bin/sh', [script, 'trim-logs'], {
        encoding: 'utf8',
        env: {
            ...process.env,
            MINIGATE_ACCESS_LOG: path.join(dir, 'access.log'),
            MINIGATE_NGINX_ERROR_LOG: path.join(dir, 'error.log'),
            MINIGATE_LOGFILE: path.join(dir, 'proxy.log'),
            MINIGATE_ACCESS_LOG_MAX: String(maxAccess)
        }
    });
    return { result, dir };
}

function lines(count, prefix) {
    return Array.from({ length: count }, (_, i) => `${prefix}-${i + 1} ${'x'.repeat(60)}`).join('\n') + '\n';
}

test('oversized access log keeps recent records in .1 and is truncated in place', () => {
    const { result, dir } = trim({ 'access.log': lines(1500, 'req') });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(dir, 'access.log'), 'utf8'), '');
    const rotated = fs.readFileSync(path.join(dir, 'access.log.1'), 'utf8').trim().split('\n');
    assert.equal(rotated.length, 1000);
    assert.match(rotated[0], /^req-501 /);
    assert.match(rotated[999], /^req-1500 /);
});

test('small logs are left untouched', () => {
    const content = lines(10, 'req');
    const { result, dir } = trim({ 'access.log': content, 'error.log': 'warn\n' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(path.join(dir, 'access.log'), 'utf8'), content);
    assert.equal(fs.existsSync(path.join(dir, 'access.log.1')), false);
    assert.equal(fs.readFileSync(path.join(dir, 'error.log'), 'utf8'), 'warn\n');
});

test('oversized nginx error log keeps its newest lines in the same file', () => {
    const { result, dir } = trim({ 'error.log': lines(5000, 'err') });
    assert.equal(result.status, 0, result.stderr);
    const kept = fs.readFileSync(path.join(dir, 'error.log'), 'utf8').trim().split('\n');
    assert.equal(kept.length, 300);
    assert.match(kept[299], /^err-5000 /);
});

test('log trimming is scheduled and the visitor list reads the rotated access log', () => {
    const init = fs.readFileSync(path.join(root, 'root/etc/init.d/minigate'), 'utf8');
    const controller = fs.readFileSync(path.join(root, 'luasrc/controller/minigate.lua'), 'utf8');
    assert.match(init, /\/bin\/sh \/usr\/lib\/minigate\/proxy\.sh trim-logs/);
    assert.match(controller, /cat \/var\/log\/minigate-access\.log\.1 \/var\/log\/minigate-access\.log 2>\/dev\/null \| tail -n 500/);
});

// 用假的 uci / nginx 生成完整配置，检查跳过规则、回滚和状态文件
function generate(db, { nginxFails = false } = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-proxy-gen-'));
    const bin = path.join(dir, 'bin');
    fs.mkdirSync(bin);
    fs.mkdirSync(path.join(dir, 'sites'));
    fs.writeFileSync(path.join(dir, 'uci.db'), db.trim() + '\n');
    fs.writeFileSync(path.join(bin, 'uci'), `#!/bin/sh
DB=${JSON.stringify(path.join(dir, 'uci.db'))}
[ "$1" = "-q" ] && shift
case "$1" in
    show) grep "^$2" "$DB" ;;
    get) v=$(grep "^$2=" "$DB" | head -1 | cut -d= -f2-); [ -n "$v" ] && echo "$v" || exit 1 ;;
esac
`, { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'nginx'), `#!/bin/sh
[ "$1" = "-v" ] && { echo "nginx version: nginx/1.26.3" >&2; exit 0; }
${nginxFails ? 'echo "nginx: [emerg] unknown directive in site_1.conf:3" >&2; exit 1' : 'exit 0'}
`, { mode: 0o755 });
    fs.writeFileSync(path.join(bin, 'openssl'), '#!/bin/sh\nexit 0\n', { mode: 0o755 });
    fs.writeFileSync(path.join(dir, 'sites/site_1.conf'), '# previous good site\n');
    fs.writeFileSync(path.join(dir, 'main.conf'), '# previous good main\n');
    const result = spawnSync('/bin/sh', [script, 'prepare'], {
        encoding: 'utf8',
        env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            TMPDIR: dir,
            MINIGATE_PROXY_LOCK: path.join(dir, 'proxy.lock'),
            MINIGATE_PROXY_STATUS: path.join(dir, 'proxy.status'),
            MINIGATE_NGINX_CONF: path.join(dir, 'main.conf'),
            MINIGATE_MIME_TYPES: '/dev/null',
            MINIGATE_SITES_DIR: path.join(dir, 'sites'),
            MINIGATE_STREAMS_DIR: path.join(dir, 'streams'),
            MINIGATE_CERT_DIR: path.join(dir, 'certs'),
            MINIGATE_LOGFILE: path.join(dir, 'proxy.log'),
            MINIGATE_SOCKET_DIR: path.join(dir, 'sock')
        }
    });
    const sites = fs.readdirSync(path.join(dir, 'sites')).sort();
    const conf = sites.map(name => fs.readFileSync(path.join(dir, 'sites', name), 'utf8')).join('\n');
    const status = fs.existsSync(path.join(dir, 'proxy.status')) ? fs.readFileSync(path.join(dir, 'proxy.status'), 'utf8') : '';
    const leftovers = fs.readdirSync(dir).filter(name => name.startsWith('minigate-gen.'));
    return { result, dir, sites, conf, status, leftovers, main: fs.readFileSync(path.join(dir, 'main.conf'), 'utf8') };
}

const BASE = `
minigate.global=global
minigate.global.enabled=1
minigate.global.http_redirect=0
minigate.wc=proxy_wildcard
minigate.wc.enabled=WC_ENABLED
minigate.wc.domain=*.example.com
minigate.wc.listen_port=443
minigate.wc.ssl=1
minigate.sub1=subproxy
minigate.sub1.parent_domain=example.com
minigate.sub1.prefix=nas
minigate.sub1.target_addr=192.168.2.10
minigate.sub1.target_port=5000
`;

test('subdomains are skipped when their wildcard parent is disabled instead of falling back to plain HTTP', () => {
    const disabled = generate(BASE.replace('WC_ENABLED', '0'));
    assert.equal(disabled.result.status, 0, disabled.result.stderr);
    assert.doesNotMatch(disabled.conf, /nas\.example\.com/);
    assert.match(disabled.status, /warning=跳过 nas\.example\.com：通配符主域名 \*\.example\.com 未启用或不存在/);

    const enabled = generate(BASE.replace('WC_ENABLED', '1'));
    assert.equal(enabled.result.status, 0, enabled.result.stderr);
    assert.match(enabled.conf, /listen 443 ssl;\n    server_name nas\.example\.com;/);
    assert.doesNotMatch(enabled.conf, /listen 443;\n    server_name nas/);
});

test('a disabled subdomain rule is not generated', () => {
    const result = generate(BASE.replace('WC_ENABLED', '1') + 'minigate.sub1.enabled=0\n');
    assert.equal(result.result.status, 0, result.result.stderr);
    assert.doesNotMatch(result.conf, /nas\.example\.com/);
});

test('HTTP and HTTPS rules on one port never produce two default servers', () => {
    const result = generate(BASE.replace('WC_ENABLED', '1') + `
minigate.plain=proxy
minigate.plain.enabled=1
minigate.plain.domain=plain.example.org
minigate.plain.listen_port=443
minigate.plain.target_addr=192.168.2.30
minigate.plain.ssl=0
`);
    assert.equal(result.result.status, 0, result.result.stderr);
    // 普通规则先生成并占用端口，之后的子域名 HTTPS 规则被跳过
    assert.equal((result.conf.match(/default_server/g) || []).length, 1);
    assert.match(result.conf, /server_name plain\.example\.org;/);
    assert.doesNotMatch(result.conf, /nas\.example\.com/);
    assert.match(result.status, /warning=跳过 nas\.example\.com：端口 443 已用于HTTP，不能同时用于HTTPS/);
});

test('missing certificates and every site get WebSocket support and a visible warning', () => {
    const result = generate(BASE.replace('WC_ENABLED', '1'));
    assert.match(result.status, /warning=nas\.example\.com 没有可用证书/);
    assert.match(result.conf, /proxy_set_header Connection \$minigate_connection_upgrade;/);
    assert.match(result.main, /map \$http_upgrade \$minigate_connection_upgrade/);
    assert.match(result.status, /^result=ok$/m);
    assert.deepEqual(result.leftovers, [], 'temporary generation directory is removed');
});

test('a configuration nginx rejects is rolled back so the last working files stay on disk', () => {
    const result = generate(BASE.replace('WC_ENABLED', '1'), { nginxFails: true });
    assert.equal(result.result.status, 1);
    assert.deepEqual(result.sites, ['site_1.conf']);
    assert.equal(fs.readFileSync(path.join(result.dir, 'sites/site_1.conf'), 'utf8'), '# previous good site\n');
    assert.equal(result.main, '# previous good main\n');
    assert.match(result.status, /^result=error$/m);
    assert.match(result.status, /配置检查失败，已保留上一份配置：\[emerg\] unknown directive/);
    assert.deepEqual(result.leftovers, []);
});

test('nginx runs in the foreground under procd and clears stale sockets first', () => {
    const source = fs.readFileSync(script, 'utf8');
    assert.match(source, /do_run\(\) \{\n    mkdir -p "\$SOCKET_DIR"\n    rm -f "\$SOCKET_DIR"\/\*\.sock\n    exec nginx -c "\$NGINX_CONF" -g 'daemon off;'/);
    const init = fs.readFileSync(path.join(root, 'root/etc/init.d/minigate'), 'utf8');
    assert.match(init, /USE_PROCD=1/);
    assert.match(init, /procd_set_param command \/bin\/sh "\$PROXY" run/);
    assert.match(init, /procd_add_reload_trigger "minigate"/);
    assert.match(source, /MINIGATE_SKIP_PREPARE=1 "\$INIT_SCRIPT" start 6>&-/);
});
