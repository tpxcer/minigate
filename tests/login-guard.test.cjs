const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/login_guard.sh');

function runRepair({ firewallReady }) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-login-guard-test-'));
    const dataDir = path.join(dir, 'data');
    const bans = path.join(dataDir, 'bans.txt');
    const calls = path.join(dir, 'nft.log');
    fs.mkdirSync(dataDir, { recursive: true });
    fs.writeFileSync(bans, '198.51.100.4 9999999999\n198.51.100.5 1\n');
    const before = fs.statSync(bans).ino;

    const command = `
        set -u
        logger() { :; }
        uci() { return 1; }
        nft() {
            printf '%s\\n' "$*" >> ${JSON.stringify(calls)}
            case "$*" in
                'list set inet fw4 login_banned_v4') [ ${firewallReady ? 1 : 0} = 1 ]; return ;;
                'list chain inet fw4 input') [ ${firewallReady ? 1 : 0} = 1 ] && printf 'ip saddr @login_banned_v4 counter drop\\n'; return 0 ;;
            esac
            return 0
        }
        export MINIGATE_LG_LIBRARY_ONLY=1
        export MINIGATE_LG_DATA_DIR=${JSON.stringify(dataDir)}
        export MINIGATE_LG_RUN_DIR=${JSON.stringify(path.join(dir, 'run'))}
        export MINIGATE_LG_LOG=${JSON.stringify(path.join(dir, 'login-guard.log'))}
        . ${JSON.stringify(script)}
        repair_nft
    `;
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
    return {
        result,
        calls: fs.existsSync(calls) ? fs.readFileSync(calls, 'utf8') : '',
        bans: fs.readFileSync(bans, 'utf8'),
        rewritten: fs.statSync(bans).ino !== before
    };
}

test('periodic nft check does not rewrite the persisted ban list when rules are intact', () => {
    const scenario = runRepair({ firewallReady: true });
    assert.equal(scenario.result.status, 0, scenario.result.stderr);
    assert.doesNotMatch(scenario.calls, /add element/);
    assert.equal(scenario.rewritten, false, 'bans.txt must not be rewritten on every watchdog tick');
});

test('a firewall reload that drops the set restores persisted bans immediately', () => {
    const scenario = runRepair({ firewallReady: false });
    assert.equal(scenario.result.status, 0, scenario.result.stderr);
    assert.match(scenario.calls, /add set inet fw4 login_banned_v4/);
    assert.match(scenario.calls, /insert rule inet fw4 input ip saddr @login_banned_v4/);
    assert.match(scenario.calls, /add element inet fw4 login_banned_v4 \{ 198\.51\.100\.4 timeout \d+s \}/);
    assert.doesNotMatch(scenario.calls, /198\.51\.100\.5/, 'expired bans must not be restored');
    assert.equal(scenario.bans, '198.51.100.4 9999999999\n');
});

test('stopping the login guard also ends its logread/tail children', async () => {
    const init = path.join(root, 'root/etc/init.d/minigate');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-login-guard-stop-'));
    const followed = path.join(dir, 'access.log');
    fs.writeFileSync(followed, '');
    // 与 login_guard.sh run 相同的结构：后台子 shell + tail -f 管道；忽略 SIGPIPE 的 tail 失去读端后不会自行退出
    const guard = spawn('/bin/sh', ['-c', 'trap "" PIPE; ( while :; do sleep 1; done ) & tail -n 0 -f "$LG_FOLLOW" | while read -r line; do :; done', '/usr/lib/minigate/login_guard.sh', 'run'], {
        detached: true, stdio: 'ignore', env: { ...process.env, LG_FOLLOW: followed }
    });
    guard.unref();
    const pgrep = pattern => spawnSync('pgrep', ['-f', pattern], { encoding: 'utf8' }).stdout.trim();
    const started = Date.now();
    while (!pgrep(`tail -n 0 -f ${followed}`) && Date.now() - started < 3000) await new Promise(resolve => setTimeout(resolve, 100));
    const tailPid = pgrep(`tail -n 0 -f ${followed}`);
    assert.ok(tailPid, 'fake login guard did not start');

    const result = spawnSync('/bin/sh', ['-c', `logger() { :; }; nft() { return 1; }; . ${JSON.stringify(init)}; stop_login_guard`], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(pgrep(`tail -n 0 -f ${followed}`), '', 'tail -f must not be left behind');
    assert.equal(pgrep('/usr/lib/minigate/login_guard.sh run'), '');
});
