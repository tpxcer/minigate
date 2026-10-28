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

test('the installer removes the legacy scanner and its global firewall set', () => {
    const installer = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
    const init = fs.readFileSync(path.join(root, 'root/etc/init.d/minigate'), 'utf8');
    assert.equal(fs.existsSync(path.join(root, 'root/usr/lib/minigate/geofence.sh')), false);
    assert.doesNotMatch(init, /geofence/);
    assert.match(installer, /rm -f \/usr\/lib\/minigate\/after_commit\.sh \/usr\/lib\/minigate\/geofence\.sh/);
    assert.match(installer, /nft delete set inet fw4 minigate_blocked/);
    assert.match(installer, /uci -q delete minigate\.global\.blocked_ips/);
});

test('legacy province names migrate to request access region codes', () => {
    const installer = fs.readFileSync(path.join(root, 'install.sh'), 'utf8');
    const body = installer.slice(installer.indexOf('migrate_legacy_geofence() {'), installer.indexOf('\nmigrate_legacy_geofence\n'));
    const result = spawnSync('/bin/sh', ['-c', `
        D=${JSON.stringify(root)}
        uci() {
            case "$*" in
                '-q get minigate.global.geo_enabled') echo 1 ;;
                '-q get minigate.global.access_enabled') echo 0 ;;
                '-q get minigate.global.geo_allowed') echo '四川,重庆' ;;
                *) echo "uci $*" ;;
            esac
        }
        ${body}
        migrate_legacy_geofence
    `], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /add_list minigate\.global\.access_regions=510000/);
    assert.match(result.stdout, /add_list minigate\.global\.access_regions=500000/);
    assert.match(result.stdout, /set minigate\.global\.access_enabled=1/);
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
