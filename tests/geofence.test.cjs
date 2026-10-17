const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/geofence.sh');

function runLibrary(body, accessLog = '') {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-geofence-test-'));
    const log = path.join(dir, 'access.log');
    fs.writeFileSync(log, accessLog);
    const command = `
        set -u
        export MINIGATE_GEOFENCE_LIBRARY_ONLY=1
        export MINIGATE_ACCESS_LOG=${JSON.stringify(log)}
        export MINIGATE_GEOFENCE_LOG=${JSON.stringify(path.join(dir, 'geofence.log'))}
        export MINIGATE_GEO_CACHE_DIR=${JSON.stringify(path.join(dir, 'cache'))}
        . ${JSON.stringify(script)}
        ${body}
    `;
    return spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
}

const entry = client => JSON.stringify({ time: '2026-10-17T07:22:40+08:00', domain: 'box.example.com', client, status: 200 });
const ACCESS_LOG = [
    entry('192.168.2.1'),
    entry('198.51.100.7'),
    entry('172.20.0.5'),
    entry('203.0.113.9'),
    entry('198.51.100.7'),
    entry('2001:db8::1'),
    entry('100.100.1.1'),
    entry('192.168.2.15')
].join('\n') + '\n';

test('private, loopback, link-local and carrier NAT addresses are recognised', () => {
    const privateIps = ['0.0.0.0', '10.1.2.3', '127.0.0.1', '169.254.1.1', '172.16.0.1', '172.31.255.255',
        '192.168.2.15', '100.64.0.1', '100.99.1.1', '100.127.255.255'];
    const publicIps = ['172.15.0.1', '172.32.0.1', '100.63.255.255', '100.128.0.1', '198.51.100.7', '1.10.0.1', '192.169.0.1'];
    const check = ips => ips.map(ip => `is_private_ip ${ip} && echo "${ip} private" || echo "${ip} public"`).join('\n');
    const result = runLibrary(check([...privateIps, ...publicIps]));
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stdout.trim().split('\n'), [
        ...privateIps.map(ip => `${ip} private`),
        ...publicIps.map(ip => `${ip} public`)
    ]);
});

test('client extraction works without grep -P and keeps only unique public IPv4 visitors', () => {
    const result = runLibrary(`
        grep() { [ "\${1:-}" = "-oP" ] && { echo "grep: unrecognized option: P" >&2; return 2; }; command grep "$@"; }
        extract_public_ips
    `, ACCESS_LOG);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stdout.trim().split('\n'), ['198.51.100.7', '203.0.113.9']);
});

test('scan never looks up or blocks LAN visitors', () => {
    const result = runLibrary(`
        uci() {
            [ "\${1:-}" = "-q" ] && shift
            case "\${2:-}" in
                minigate.global.geo_enabled) echo 1 ;;
                minigate.global.geo_allowed) echo 四川 ;;
            esac
        }
        init_block_set() { :; }
        nft() { :; }
        sleep() { :; }
        lookup_geo() { echo "lookup $1" >&2; echo 广东; }
        block_ip() { echo "block $1"; }
        mkdir -p "$CACHE_DIR"
        scan_and_block
    `, ACCESS_LOG);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(result.stderr.trim().split('\n'), ['lookup 198.51.100.7', 'lookup 203.0.113.9']);
    assert.deepEqual(result.stdout.trim().split('\n'), ['block 198.51.100.7', 'block 203.0.113.9']);
});
