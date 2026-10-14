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
