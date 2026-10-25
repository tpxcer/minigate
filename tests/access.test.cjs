const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const { config, geoDir, root } = require('./helpers/access-fixture.cjs');

test('disabled or absent access option preserves unrestricted generated sites', () => {
    for (const enabled of ['', '0']) {
        const result = config('write_geo_access; write_server "$conf" app.example.com 2000 127.0.0.1 80 0 0 1 old 1 0', { enabled });
        assert.equal(result.status, 0, result.stderr);
        assert.equal(result.stdout, '');
        assert.doesNotMatch(result.conf, /minigate_geo_allowed/);
        assert.match(result.conf, /proxy_pass http:\/\/127.0.0.1:80/);
    }
});

test('province policy defaults to deny, uses connection IP and preserves private LAN', () => {
    const result = config('write_geo_access');
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /geo \$minigate_client_addr \$minigate_geo_allowed/);
    assert.match(result.stdout, /default 0;/);
    assert.match(result.stdout, /192\.168\.0\.0\/16 1;/);
    assert.match(result.stdout, /fc00::\/7 1;/);
    assert.match(result.stdout, /fe80::\/10 1;/);
    assert.match(result.stdout, /510000\.conf;/);
    assert.doesNotMatch(result.stdout, /http_x_|100\.64|0\.0\.0\.0\/0/);
});

test('multiple selected provinces are included once and other provinces stay absent', () => {
    const result = config('write_geo_access', { regions: '510000 500000 510000' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal((result.stdout.match(/510000\.conf/g) || []).length, 1);
    assert.match(result.stdout, /500000\.conf/);
    assert.doesNotMatch(result.stdout, /440000\.conf/);
});

test('empty, invalid or missing region data never falls back to public access', () => {
    for (const options of [
        { regions: '' }, { regions: '../510000; return 200;' }, { regions: '990000' },
        { directory: '/missing-minigate-geo-data' }
    ]) {
        const result = config('write_geo_access', options);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.stdout, /default 0;/);
        assert.doesNotMatch(result.stdout, /include .*\.conf|return 200/);
    }
});

test('both ordinary and multiplexed proxy sites reject before proxy_pass and websocket upgrade', () => {
    for (const mux of [0, 1]) {
        const result = config(`write_server "$conf" app.example.com 2000 127.0.0.1 80 0 0 1 old 1 ${mux}`);
        assert.equal(result.status, 0, result.stderr);
        assert.match(result.conf, /if \(\$minigate_geo_allowed = 0\) \{ return 444; \}/);
        assert.ok(result.conf.indexOf('return 444;') < result.conf.indexOf('proxy_pass'));
        assert.match(result.conf, /proxy_set_header Upgrade/);
    }
});

test('HTTP redirect rejects unapproved source before sending a redirect', () => {
    const result = config('write_redirect_server "$conf" app.example.com 2000');
    assert.equal(result.status, 0, result.stderr);
    assert.ok(result.conf.indexOf('return 444;') < result.conf.indexOf('return 308'));
});

test('the legacy scanner cannot add global firewall bans in request access mode', () => {
    const scanner = path.join(root, 'root/usr/lib/minigate/geofence.sh');
    const result = spawnSync('/bin/sh', ['-c', `
        export MINIGATE_GEOFENCE_LIBRARY_ONLY=1
        . '${scanner}'
        uci() { [ "$3" = minigate.global.access_enabled ] && echo 1; }
        init_block_set() { echo unexpected >&2; return 1; }
        scan_and_block
    `], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stderr, '');
});

test('bundled regions all cover IPv4 and IPv6 and data follows every install path', () => {
    const metadata = JSON.parse(fs.readFileSync(path.join(geoDir, 'metadata.json')));
    const regions = fs.readFileSync(path.join(geoDir, 'regions.txt'), 'utf8').trim().split('\n');
    assert.equal(regions.length, 34);
    for (const row of regions) {
        const code = row.split(' ')[0];
        const data = fs.readFileSync(path.join(geoDir, `${code}.conf`), 'utf8');
        assert.match(data, /^\d+\.\d+\.\d+\.\d+\/\d+ 1;$/m, code);
        assert.match(data, /^[a-f0-9:]+\/\d+ 1;$/m, code);
        assert.equal(data.trim().split('\n').length - 1, metadata.networks[code]['4'] + metadata.networks[code]['6']);
    }
    for (const file of ['Makefile', 'install.sh', 'scripts/build-ipk.sh']) {
        assert.match(fs.readFileSync(path.join(root, file), 'utf8'), /root\/usr\/lib\/minigate\/geo/, file);
    }
    assert.match(fs.readFileSync(path.join(geoDir, 'LICENSE.ip2region'), 'utf8'), /Copyright.*Lionsoul/);
});


test('assigned LAN global IPv6 subnet is exempted without allowing a broad remote prefix', () => {
    const run = mask => config(`
        ubus() { echo fixture; }
        jsonfilter() {
            case "$2" in
                *'[0].address') echo 2001:db8:1234:: ;;
                *'[0].mask') echo ${mask} ;;
            esac
        }
        write_geo_access
    `);
    const assigned = run('64');
    assert.equal(assigned.status, 0, assigned.stderr);
    assert.match(assigned.stdout, /2001:db8:1234::\/64 1;/);
    assert.doesNotMatch(run('0').stdout, /2001:db8:1234/);
    assert.doesNotMatch(run('32').stdout, /2001:db8:1234/);
});
