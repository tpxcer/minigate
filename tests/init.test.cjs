const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const init = path.join(root, 'root/etc/init.d/minigate');

function runInit(body, env = {}) {
    return spawnSync('/bin/sh', ['-c', `. ${JSON.stringify(init)}\n${body}`], { encoding: 'utf8', env: { ...process.env, ...env } });
}

test('cron entries are managed by script path and user jobs mentioning minigate survive', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-cron-'));
    const cron = path.join(dir, 'root');
    fs.writeFileSync(cron, '0 1 * * * /root/backup-minigate-certs.sh\n*/2 * * * * /bin/sh /usr/lib/minigate/geofence.sh scan\n');
    let result = runInit('update_cron 1', { MINIGATE_CRON_FILE: cron });
    assert.equal(result.status, 0, result.stderr);
    const enabled = fs.readFileSync(cron, 'utf8');
    assert.match(enabled, /^0 1 \* \* \* \/root\/backup-minigate-certs\.sh$/m);
    assert.doesNotMatch(enabled, /geofence/);
    assert.match(enabled, /\/usr\/lib\/minigate\/ddns\.sh$/m);
    assert.match(enabled, /\/usr\/lib\/minigate\/acme\.sh renew$/m);

    result = runInit('update_cron 0', { MINIGATE_CRON_FILE: cron });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.readFileSync(cron, 'utf8'), '0 1 * * * /root/backup-minigate-certs.sh\n');
});

test('reload digests only include the settings of the page that changed', () => {
    const result = runInit(`
        md5sum() { cat; }
        uci() {
            cat <<'UCI'
minigate.global=global
minigate.global.enabled='1'
minigate.@ddns[0]=ddns
minigate.@ddns[0].domain='a.example.com'
minigate.web=proxy
minigate.web.domain='b.example.com'
minigate.login_guard=login_guard
minigate.login_guard.threshold='3'
UCI
        }
        echo "== ddns"; config_digest ddns
        echo "== proxy"; config_digest "global proxy proxy_wildcard subproxy"
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, [
        '== ddns',
        'minigate.@ddns[0]=ddns',
        "minigate.@ddns[0].domain='a.example.com'",
        '== proxy',
        'minigate.global=global',
        "minigate.global.enabled='1'",
        'minigate.web=proxy',
        "minigate.web.domain='b.example.com'",
        ''
    ].join('\n'));
});

test('services run under procd, background work drops the procd lock and LuCI pages no longer poll for commits', () => {
    const source = fs.readFileSync(init, 'utf8');
    assert.match(source, /procd_open_instance login_guard/);
    assert.match(source, /procd_set_param env MINIGATE_LG_DIGEST=/);
    assert.match(source, /run_background\(\) \{\n    \( close_procd_lock; "\$@" \) <\/dev\/null >\/dev\/null 2>&1 &/);
    assert.match(source, /\( close_procd_lock; \/etc\/init\.d\/cron restart \)/);
    // 只有 eval 字符串里出现多位数描述符，dash 等 shell 才能解析本文件
    assert.deepEqual(source.split('\n').filter(line => /\d{2,}>&/.test(line)), ["    [ -e /proc/self/fd/1000 ] && eval 'exec 1000>&-'"]);
    for (const page of ['general', 'ddns', 'proxy', 'login_guard']) {
        const lua = fs.readFileSync(path.join(root, `luasrc/model/cbi/minigate/${page}.lua`), 'utf8');
        assert.doesNotMatch(lua, /on_after_commit|after_commit\.sh/, page);
    }
    assert.equal(fs.existsSync(path.join(root, 'root/usr/lib/minigate/after_commit.sh')), false);
});
