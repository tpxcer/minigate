const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawn, spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/login_guard.sh');

// firewallReady: 集合和规则都在；setsEmpty: 防火墙重载后随包集合存在但内容为空
function runRepair({ firewallReady, setsEmpty = false }) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-login-guard-test-'));
    const dataDir = path.join(dir, 'data');
    const bans = path.join(dataDir, 'bans.txt');
    const calls = path.join(dir, 'nft.log');
    fs.mkdirSync(dataDir, { recursive: true });
    fs.writeFileSync(bans, '198.51.100.4 9999999999\n198.51.100.5 1\n2001:db8::9 9999999999\n');
    const before = fs.statSync(bans).ino;

    const command = `
        set -u
        logger() { :; }
        uci() { return 1; }
        ubus() { return 1; }
        nft() {
            printf '%s\\n' "$*" >> ${JSON.stringify(calls)}
            case "$*" in
                'list set inet fw4 login_banned_v4'|'list set inet fw4 login_banned_v6')
                    [ ${firewallReady ? 1 : 0} = 1 ] || return 1
                    [ ${setsEmpty ? 1 : 0} = 1 ] || printf 'elements = { 198.51.100.4 }\\n'
                    return 0 ;;
                'list chain inet fw4 input') [ ${firewallReady ? 1 : 0} = 1 ] && printf 'ip saddr @login_banned_v4 counter drop\\nip6 saddr @login_banned_v6 counter drop\\n'; return 0 ;;
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

test('a firewall reload that drops the set restores persisted IPv4 and IPv6 bans immediately', () => {
    const scenario = runRepair({ firewallReady: false });
    assert.equal(scenario.result.status, 0, scenario.result.stderr);
    assert.match(scenario.calls, /add set inet fw4 login_banned_v4 \{ type ipv4_addr; flags timeout; \}/);
    assert.match(scenario.calls, /add set inet fw4 login_banned_v6 \{ type ipv6_addr; flags timeout; \}/);
    assert.match(scenario.calls, /insert rule inet fw4 input ip saddr @login_banned_v4/);
    assert.match(scenario.calls, /insert rule inet fw4 input ip6 saddr @login_banned_v6/);
    assert.match(scenario.calls, /add element inet fw4 login_banned_v4 \{ 198\.51\.100\.4 timeout \d+s \}/);
    assert.match(scenario.calls, /add element inet fw4 login_banned_v6 \{ 2001:db8::9 timeout \d+s \}/);
    assert.doesNotMatch(scenario.calls, /198\.51\.100\.5/, 'expired bans must not be restored');
    assert.equal(scenario.bans, '198.51.100.4 9999999999\n2001:db8::9 9999999999\n');
});

test('packaged firewall sets that come back empty after a reload are refilled', () => {
    const scenario = runRepair({ firewallReady: true, setsEmpty: true });
    assert.equal(scenario.result.status, 0, scenario.result.stderr);
    assert.doesNotMatch(scenario.calls, /add set|insert rule/);
    assert.match(scenario.calls, /add element inet fw4 login_banned_v4 \{ 198\.51\.100\.4 timeout \d+s \}/);
});

test('fw4 includes declare both ban sets before the input rules that use them', () => {
    const tablePre = fs.readFileSync(path.join(root, 'root/usr/share/nftables.d/table-pre/20-minigate-login-guard.nft'), 'utf8');
    const chainPre = fs.readFileSync(path.join(root, 'root/usr/share/nftables.d/chain-pre/input/20-minigate-login-guard.nft'), 'utf8');
    assert.match(tablePre, /set login_banned_v4 \{\n\ttype ipv4_addr\n\tflags timeout\n\}/);
    assert.match(tablePre, /set login_banned_v6 \{\n\ttype ipv6_addr\n\tflags timeout\n\}/);
    assert.match(chainPre, /^ip saddr @login_banned_v4 counter drop comment "minigate-login-guard"$/m);
    assert.match(chainPre, /^ip6 saddr @login_banned_v6 counter drop comment "minigate-login-guard"$/m);
    for (const file of ['Makefile', 'install.sh', 'scripts/build-ipk.sh', 'root/usr/lib/minigate/uninstall.sh']) {
        assert.match(fs.readFileSync(path.join(root, file), 'utf8'), /nftables\.d\/chain-pre\/input\/20-minigate-login-guard\.nft/, file);
    }
});

function library(body) {
    return spawnSync('/bin/sh', ['-c', `
        export MINIGATE_LG_LIBRARY_ONLY=1
        export MINIGATE_LG_DATA_DIR=${JSON.stringify(fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lg-lib-')))}
        export MINIGATE_LG_RUN_DIR=${JSON.stringify(fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lg-run-')))}
        export MINIGATE_LG_LOG=/dev/null
        logger() { :; }
        uci() { [ "$3" = minigate.login_guard.whitelist ] && echo "203.0.113.0/20 2001:db8:abcd::/48"; return 0; }
        . ${JSON.stringify(script)}
        ${body}
    `], { encoding: 'utf8' });
}

test('addresses from dropbear and LuCI logs are parsed for both IP families and spoofed usernames', () => {
    const result = library(`
        extract_ip "authpriv.warn dropbear[1]: Bad password attempt for 'root' from 198.51.100.7:52144" 1
        extract_ip "dropbear[1]: Login attempt for nonexistent user 'x from 9.9.9.9:1' from 2001:db8::7:52144" 1
        extract_ip "luci: failed login on / for root from 2001:db8::8" 0
        extract_ip "luci: failed login on / for root from bad;rm" 0 || echo rejected
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), '198.51.100.7\n2001:db8::7\n2001:db8::8\nrejected');
});

test('whitelist matches any IPv4 prefix length and IPv6 subnets, private ranges stay exempt', () => {
    const result = library(`
        for ip in 203.0.120.9 203.0.128.1 2001:db8:abcd:1::5 2001:db8:abce::5 192.168.2.5 fd00::5 fe80::1 198.51.100.7 2400:da00::1; do
            is_whitelisted "$ip" && printf 'white:%s ' "$ip" || printf 'watch:%s ' "$ip"
        done
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'white:203.0.120.9 watch:203.0.128.1 white:2001:db8:abcd:1::5 watch:2001:db8:abce::5 white:192.168.2.5 white:fd00::5 white:fe80::1 watch:198.51.100.7 watch:2400:da00::1');
});

test('a ban the firewall rejects is reported instead of being logged as banned', () => {
    const result = library(`
        nft() { return 1; }
        ban_ip 198.51.100.9 && echo banned || echo failed
        cat "$BANS_FILE"
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout.trim(), 'failed');
});

test('procd stopping the login guard ends logread and tail children and lifts enforcement', async () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-login-guard-stop-'));
    const bin = path.join(dir, 'bin');
    const followed = path.join(dir, 'access.log');
    const nftLog = path.join(dir, 'nft.log');
    fs.mkdirSync(bin);
    fs.writeFileSync(followed, '');
    const shim = (name, body) => fs.writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
    shim('uci', 'case "$3" in minigate.login_guard.enabled) echo 1 ;; *) exit 1 ;; esac');
    shim('nft', `printf '%s\\n' "$*" >> ${JSON.stringify(nftLog)}; case "$*" in 'list chain'*) echo '@login_banned_v4 @login_banned_v6' ;; 'list set'*) echo elements ;; esac; exit 0`);
    shim('logger', 'exit 0');
    shim('ubus', 'exit 1');
    // logread -f 与 tail -f 一样会一直阻塞，用 tail 模拟
    shim('logread', `exec tail -n 0 -f ${JSON.stringify(followed)}`);
    const guard = spawn('/bin/sh', [script, 'run'], {
        stdio: 'ignore',
        env: {
            ...process.env,
            PATH: `${bin}:${process.env.PATH}`,
            MINIGATE_LG_DATA_DIR: path.join(dir, 'data'),
            MINIGATE_LG_RUN_DIR: path.join(dir, 'run'),
            MINIGATE_LG_LOG: path.join(dir, 'lg.log'),
            MINIGATE_ACCESS_LOG: followed
        }
    });
    const pgrep = pattern => spawnSync('pgrep', ['-f', pattern], { encoding: 'utf8' }).stdout.trim();
    const started = Date.now();
    while (pgrep(`tail -n 0 -f ${followed}`).split('\n').filter(Boolean).length < 2 && Date.now() - started < 4000) {
        await new Promise(resolve => setTimeout(resolve, 100));
    }
    assert.equal(pgrep(`tail -n 0 -f ${followed}`).split('\n').filter(Boolean).length, 2, 'both followers should run');
    guard.kill('SIGTERM');
    await new Promise(resolve => guard.once('exit', resolve));
    await new Promise(resolve => setTimeout(resolve, 300));
    assert.equal(pgrep(`tail -n 0 -f ${followed}`), '', 'tail -f / logread -f must not be left behind');
    assert.match(fs.readFileSync(nftLog, 'utf8'), /flush set inet fw4 login_banned_v4[\s\S]*flush set inet fw4 login_banned_v6/);
});

test('upgrades stop the old login guard tree before running the previous init script', () => {
    const installer = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
    const treeStop = installer.indexOf("pgrep -f '^/bin/sh /usr/lib/minigate/login_guard.sh run'");
    const initStop = installer.indexOf('/etc/init.d/minigate stop');
    assert.ok(treeStop > 0 && treeStop < initStop, 'installer must stop the login guard tree before the old init script');
    assert.match(installer, /stop_process_tree\(\) \{[\s\S]*pgrep -P "\$1"/);
});

// 回归：v2026.10.28 中修复防火墙时读取 bans.txt 的循环变量覆盖了调用方的 ip，
// 达到阈值后用空地址封禁，日志出现「封禁  失败」，攻击者再也不会被封。
test('reaching the threshold bans the attacking address even when other bans are persisted', () => {
    for (const setsEmpty of [false, true]) {
        const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lg-threshold-'));
        const dataDir = path.join(dir, 'data');
        const calls = path.join(dir, 'nft.log');
        fs.mkdirSync(dataDir);
        fs.writeFileSync(path.join(dataDir, 'bans.txt'), '111.170.34.182 9999999999\n185.246.128.170 9999999999\n');
        const result = spawnSync('/bin/sh', ['-c', `
            logger() { :; }
            uci() { case "$3" in minigate.login_guard.threshold) echo 3 ;; *) return 1 ;; esac; }
            nft() {
                printf '%s\\n' "$*" >> ${JSON.stringify(calls)}
                case "$*" in
                    'list set inet fw4 login_banned_v4'|'list set inet fw4 login_banned_v6') [ ${setsEmpty ? 1 : 0} = 1 ] || echo 'elements = { 111.170.34.182 }' ;;
                    'list chain inet fw4 input') echo '@login_banned_v4 @login_banned_v6' ;;
                esac
                return 0
            }
            export MINIGATE_LG_LIBRARY_ONLY=1 MINIGATE_LG_DATA_DIR=${JSON.stringify(dataDir)}
            export MINIGATE_LG_RUN_DIR=${JSON.stringify(path.join(dir, 'run'))} MINIGATE_LG_LOG=${JSON.stringify(path.join(dir, 'lg.log'))}
            . ${JSON.stringify(script)}
            for i in 1 2 3; do handle_failure 139.162.161.162; done
        `], { encoding: 'utf8' });
        assert.equal(result.status, 0, result.stderr);
        const log = fs.readFileSync(path.join(dir, 'lg.log'), 'utf8');
        assert.match(fs.readFileSync(calls, 'utf8'), /add element inet fw4 login_banned_v4 \{ 139\.162\.161\.162 timeout 43200s \}/, `setsEmpty=${setsEmpty}`);
        assert.match(log, /BAN 139\.162\.161\.162 12小时（达到 3 次失败）/);
        assert.doesNotMatch(log, /封禁 +失败/);
        assert.match(fs.readFileSync(path.join(dataDir, 'bans.txt'), 'utf8'), /^139\.162\.161\.162 \d+$/m);
        assert.equal(fs.existsSync(path.join(dir, 'run/counters/139.162.161.162')), false, 'counter is cleared after a ban');
    }
});

function guardLibrary(dir, body) {
    return spawnSync('/bin/sh', ['-c', `
        logger() { :; }
        uci() { case "$3" in minigate.login_guard.threshold) echo 3 ;; *) return 1 ;; esac; }
        nft() {
            printf '%s\\n' "$*" >> ${JSON.stringify(path.join(dir, 'nft.log'))}
            case "$*" in
                'list set inet fw4 login_banned_v4'|'list set inet fw4 login_banned_v6') [ -f ${JSON.stringify(path.join(dir, 'sets-empty'))} ] || echo 'elements = { 1.1.1.1 }' ;;
                'list chain inet fw4 input') echo '@login_banned_v4 @login_banned_v6' ;;
            esac
            return 0
        }
        export MINIGATE_LG_LIBRARY_ONLY=1 MINIGATE_LG_DATA_DIR=${JSON.stringify(path.join(dir, 'data'))}
        export MINIGATE_LG_RUN_DIR=${JSON.stringify(path.join(dir, 'run'))} MINIGATE_LG_LOG=${JSON.stringify(path.join(dir, 'lg.log'))}
        . ${JSON.stringify(script)}
        ${body}
    `], { encoding: 'utf8' });
}

test('bans and failure counters record whether the attempt came over SSH or LuCI', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lg-kind-'));
    fs.mkdirSync(path.join(dir, 'data'));
    fs.writeFileSync(path.join(dir, 'data/bans.txt'), '111.170.34.182 9999999999\n');
    const result = guardLibrary(dir, `
        handle_failure 198.51.100.30 luci
        cat "$COUNTER_DIR/198.51.100.30"
        for i in 1 2 3; do handle_failure 139.162.161.162 ssh; done
        cmd_ban 198.51.100.40 >/dev/null
    `);
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^\d+ 1 luci$/m);
    const bans = fs.readFileSync(path.join(dir, 'data/bans.txt'), 'utf8');
    assert.match(bans, /^111\.170\.34\.182 9999999999$/m, 'old records without a type are kept as they are');
    assert.match(bans, /^139\.162\.161\.162 \d+ ssh$/m);
    assert.match(bans, /^198\.51\.100\.40 \d+ manual$/m);
    const log = fs.readFileSync(path.join(dir, 'lg.log'), 'utf8');
    assert.match(log, /FAIL 198\.51\.100\.30 LuCI \(1\/3\)/);
    assert.match(log, /BAN 139\.162\.161\.162 12小时（SSH，达到 3 次失败）/);
});

test('typed ban records survive a firewall reload and are restored with their type', () => {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-lg-kind-restore-'));
    fs.mkdirSync(path.join(dir, 'data'));
    fs.writeFileSync(path.join(dir, 'sets-empty'), '');
    fs.writeFileSync(path.join(dir, 'data/bans.txt'), '139.162.161.162 9999999999 ssh\n2001:db8::9 9999999999 luci\n5.231.242.181 9999999999\n');
    const result = guardLibrary(dir, 'repair_nft');
    assert.equal(result.status, 0, result.stderr);
    const calls = fs.readFileSync(path.join(dir, 'nft.log'), 'utf8');
    assert.match(calls, /add element inet fw4 login_banned_v4 \{ 139\.162\.161\.162 timeout \d+s \}/);
    assert.match(calls, /add element inet fw4 login_banned_v6 \{ 2001:db8::9 timeout \d+s \}/);
    assert.equal(fs.readFileSync(path.join(dir, 'data/bans.txt'), 'utf8'), '139.162.161.162 9999999999 ssh\n2001:db8::9 9999999999 luci\n5.231.242.181 9999999999\n');
});

test('each log source reports its own access type', () => {
    const source = fs.readFileSync(script, 'utf8');
    assert.match(source, /handle_failure "\$\(extract_ip "\$line" 1\)" ssh/);
    assert.match(source, /handle_failure "\$\(extract_ip "\$line" 0\)" luci/);
    assert.match(source, /handle_failure "\$ip" luci/);
});
