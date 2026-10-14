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

// BusyBox pgrep 只排除自身，不像 macOS 那样默认排除祖先进程。
function busyboxPgrep(dir) {
    const shim = path.join(dir, 'bin/pgrep');
    fs.mkdirSync(path.dirname(shim), { recursive: true });
    fs.writeFileSync(shim, `#!/bin/sh
self=$$
case "$1" in
    -f) ps -A -o pid= -o ppid= -o args= | awk -v self="$self" -v re="$2" '
            { pid=$1; ppid=$2; if (pid == self || ppid == self) next; $1=""; $2=""; sub(/^ +/, ""); if ($0 ~ re) print pid }' ;;
    -P) ps -A -o pid= -o ppid= | awk -v self="$self" -v parent="$2" '$2 == parent && $1 != self { print $1 }' ;;
esac
`);
    fs.chmodSync(shim, 0o755);
    return path.dirname(shim);
}

test('stopping the login guard ends its children but not a caller that mentions it', async () => {
    const init = path.join(root, 'root/etc/init.d/minigate');
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-login-guard-stop-'));
    const followed = path.join(dir, 'access.log');
    const guardScript = path.join(dir, 'login_guard.sh');
    const marker = path.join(dir, 'caller-survived');
    fs.writeFileSync(followed, '');
    // 与 login_guard.sh run 相同的结构：后台子 shell + tail -f 管道；忽略 SIGPIPE 的 tail 失去读端后不会自行退出
    fs.writeFileSync(guardScript, `trap "" PIPE\n( while :; do sleep 1; done ) &\ntail -n 0 -f ${JSON.stringify(followed)} | while read -r line; do :; done\n`);
    const guard = spawn('/bin/sh', [guardScript, 'run'], { detached: true, stdio: 'ignore' });
    guard.unref();
    const pgrep = pattern => spawnSync('pgrep', ['-f', pattern], { encoding: 'utf8' }).stdout.trim();
    const started = Date.now();
    while (!pgrep(`tail -n 0 -f ${followed}`) && Date.now() - started < 3000) await new Promise(resolve => setTimeout(resolve, 100));
    assert.ok(pgrep(`tail -n 0 -f ${followed}`), 'fake login guard did not start');

    // 调用方的命令行里含有登录防护的命令文本（例如 SSH 一次性执行的脚本），不能被当成登录防护结束
    const caller = `logger() { :; }; nft() { return 1; }; . ${JSON.stringify(init)}; LOGIN_GUARD=${JSON.stringify(guardScript)}; echo "checking ${guardScript} run" >/dev/null; stop_login_guard; echo ok > ${JSON.stringify(marker)}`;
    const result = spawnSync('/bin/sh', ['-c', caller], { encoding: 'utf8', env: { ...process.env, PATH: `${busyboxPgrep(dir)}:${process.env.PATH}` } });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(fs.existsSync(marker), true, 'stop_login_guard killed its own caller');
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(pgrep(`tail -n 0 -f ${followed}`), '', 'tail -f must not be left behind');
    assert.equal(pgrep(`${guardScript} run`), '');
});

test('upgrades stop the old login guard tree before running the previous init script', () => {
    const installer = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
    const treeStop = installer.indexOf("pgrep -f '^/bin/sh /usr/lib/minigate/login_guard.sh run'");
    const initStop = installer.indexOf('/etc/init.d/minigate stop');
    assert.ok(treeStop > 0 && treeStop < initStop, 'installer must stop the login guard tree before the old init script');
    assert.match(installer, /stop_process_tree\(\) \{[\s\S]*pgrep -P "\$1"/);
});
