const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/after_commit.sh');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));

function fixture() {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-after-commit-test-'));
    const config = path.join(dir, 'minigate');
    const marker = path.join(dir, 'applied.log');
    fs.writeFileSync(config, "option enabled '0'\n");
    fs.mkdirSync(path.join(dir, 'lib'));
    fs.writeFileSync(path.join(dir, 'lib/ddns.sh'), `printf 'ddns %s %s\\n' "$1" "$(cat ${JSON.stringify(config)})" >> ${JSON.stringify(marker)}\n`);
    fs.writeFileSync(path.join(dir, 'lib/proxy.sh'), `printf 'proxy %s\\n' "$1" >> ${JSON.stringify(marker)}\n`);
    fs.writeFileSync(path.join(dir, 'init'), `#!/bin/sh\nprintf 'init %s\\n' "$1" >> ${JSON.stringify(marker)}\n`);
    fs.chmodSync(path.join(dir, 'init'), 0o755);
    return { dir, config, marker };
}

function run(fx, action, wait) {
    return spawnSync('/bin/sh', [script, action], {
        encoding: 'utf8',
        timeout: 5000,
        env: {
            ...process.env,
            MINIGATE_CONFIG_FILE: fx.config,
            MINIGATE_COMMIT_WAIT: String(wait),
            MINIGATE_INIT: path.join(fx.dir, 'init'),
            MINIGATE_LIB_DIR: path.join(fx.dir, 'lib')
        }
    });
}

const applied = fx => (fs.existsSync(fx.marker) ? fs.readFileSync(fx.marker, 'utf8').trim() : '');

async function waitFor(check, timeout = 4000) {
    const started = Date.now();
    while (Date.now() - started < timeout) {
        if (check()) return true;
        await sleep(100);
    }
    return check();
}

test('saved settings are applied only after LuCI commits the new configuration', async () => {
    const fx = fixture();
    const started = Date.now();
    const result = run(fx, 'ddns', 10);
    assert.equal(result.status, 0, result.stderr);
    assert.ok(Date.now() - started < 1000, 'the LuCI hook must return immediately');

    await sleep(1300);
    assert.equal(applied(fx), '', 'must not run against the old configuration');
    fs.writeFileSync(fx.config, "option enabled '1'\n");
    assert.ok(await waitFor(() => applied(fx) !== ''));
    assert.equal(applied(fx), "ddns force option enabled '1'");
});

test('an unchanged save still applies after the wait limit', async () => {
    const fx = fixture();
    assert.equal(run(fx, 'proxy', 1).status, 0);
    assert.ok(await waitFor(() => applied(fx) !== ''));
    assert.equal(applied(fx), 'proxy reload');
});

test('service actions go through the init script and unknown actions are rejected', async () => {
    const fx = fixture();
    assert.equal(run(fx, 'restart', 1).status, 0);
    assert.ok(await waitFor(() => applied(fx) !== ''));
    assert.equal(applied(fx), 'init restart');

    const bad = fixture();
    assert.equal(run(bad, 'reboot', 1).status, 2);
    await sleep(1500);
    assert.equal(applied(bad), '');
});

test('LuCI pages defer their actions and saving DDNS no longer restarts the proxy', () => {
    const page = name => fs.readFileSync(path.join(root, 'luasrc/model/cbi/minigate', name), 'utf8');
    assert.match(page('general.lua'), /after_commit\.sh " \.\. \(en == "1" and "restart" or "stop"\)/);
    assert.match(page('ddns.lua'), /after_commit\.sh ddns/);
    assert.match(page('proxy.lua'), /after_commit\.sh proxy/);
    assert.match(page('login_guard.lua'), /after_commit\.sh reload/);
    assert.doesNotMatch(page('ddns.lua'), /minigate restart/);
    const makefile = fs.readFileSync(path.join(root, 'Makefile'), 'utf8');
    assert.match(makefile, /root\/usr\/lib\/minigate\/after_commit\.sh/);
});
