const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const http = require('node:http');
const net = require('node:net');
const { spawn, spawnSync } = require('node:child_process');
const { config, geoDir } = require('./helpers/access-fixture.cjs');

const nginx = process.env.MINIGATE_TEST_NGINX;
const pause = ms => new Promise(resolve => setTimeout(resolve, ms));

function request(socketPath, source, { spoof = false, websocket = false } = {}) {
    return new Promise((resolve, reject) => {
        let response = '';
        const socket = net.connect(socketPath, () => {
            const v6 = source.includes(':');
            socket.write(`PROXY ${v6 ? 'TCP6' : 'TCP4'} ${source} ${v6 ? '::1' : '127.0.0.1'} 12345 2000\r\n` +
                'GET / HTTP/1.1\r\nHost: app.example.com\r\n' +
                (spoof ? 'X-Forwarded-For: 14.196.0.1\r\nX-Real-IP: 14.196.0.1\r\n' : '') +
                (websocket ? 'Connection: Upgrade\r\nUpgrade: websocket\r\n' : 'Connection: close\r\n') + '\r\n');
        });
        socket.setTimeout(3000, () => socket.destroy(new Error('请求超时')));
        socket.on('data', chunk => { response += chunk; });
        socket.on('error', error => error.code === 'ECONNRESET' ? resolve(response) : reject(error));
        socket.on('close', () => resolve(response));
    });
}

async function running(t, options = {}) {
    let reached = 0;
    const backend = http.createServer((req, res) => { reached++; res.end('backend-reached'); });
    backend.on('upgrade', (req, socket) => { reached++; socket.end('HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n'); });
    await new Promise(resolve => backend.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => backend.close(resolve)));
    const port = backend.address().port;
    const fixture = config(`
        write_server "$SITES_DIR/site.conf" app.example.com 2000 127.0.0.1 ${port} 0 0 1 old 0 0
        write_redirect_server "$SITES_DIR/redirect.conf" app.example.com 2000
        generate_main_conf
    `, options);
    assert.equal(fixture.status, 0, fixture.stderr);
    const site = path.join(fixture.dir, 'sites/site.conf');
    const socketPath = path.join(fixture.dir, 'proxy.sock');
    fs.writeFileSync(site, fs.readFileSync(site, 'utf8').replace('listen 2000;', `listen unix:${socketPath} proxy_protocol;`));
    const main = path.join(fixture.dir, 'main.conf');
    fs.mkdirSync(path.join(fixture.dir, 'logs'));
    const tempPaths = ['client_body', 'proxy', 'fastcgi', 'uwsgi', 'scgi']
        .map(name => `    ${name}_temp_path ${fixture.dir}/${name}-temp;`).join('\n');
    fs.writeFileSync(main, fs.readFileSync(main, 'utf8').replace('http {', `http {\n${tempPaths}`));
    const check = spawnSync(nginx, ['-t', '-c', main, '-p', fixture.dir], { encoding: 'utf8' });
    assert.equal(check.status, 0, check.stderr);
    const child = spawn(nginx, ['-c', main, '-p', fixture.dir, '-g', 'daemon off;'], { stdio: 'ignore' });
    t.after(async () => {
        if (child.exitCode === null) {
            child.kill('SIGQUIT');
            await new Promise(resolve => child.once('exit', resolve));
        }
    });
    for (let i = 0; i < 50 && !fs.existsSync(socketPath); i++) await pause(50);
    assert.ok(fs.existsSync(socketPath), fs.existsSync(path.join(fixture.dir, 'error.log')) ? fs.readFileSync(path.join(fixture.dir, 'error.log'), 'utf8') : 'Nginx 未启动');
    return { ...fixture, socketPath, redirectPath: path.join(fixture.dir, 'http_2000.sock'), reached: () => reached };
}

test('real nginx enforces source policy before upstream, redirect and websocket', { skip: !nginx }, async t => {
    const fixture = await running(t);
    for (const ip of ['14.196.0.1', '::ffff:14.196.0.1', '2001:250:2000::1', '192.168.2.15', '10.0.0.2', 'fd00::15', 'fe80::15']) {
        const response = await request(fixture.socketPath, ip);
        assert.match(response, /200 OK/, ip);
        assert.match(response, /backend-reached/, ip);
    }
    const reached = fixture.reached();
    for (const ip of ['8.8.8.8', '::ffff:8.8.8.8', '1.0.1.1', '203.0.113.10', '2001:4860:4860::8888', '2001:db8::1']) {
        assert.equal(await request(fixture.socketPath, ip, { spoof: true }), '', ip);
        assert.equal(await request(fixture.redirectPath, ip), '', `redirect ${ip}`);
        assert.equal(await request(fixture.socketPath, ip, { websocket: true }), '', `websocket ${ip}`);
    }
    assert.equal(fixture.reached(), reached, '拒绝的请求不得到达后端');
    assert.match(await request(fixture.redirectPath, '14.196.0.1'), /308 Permanent Redirect/);
    assert.match(await request(fixture.socketPath, '14.196.0.1', { websocket: true }), /101 Switching Protocols/);
});

test('real nginx permits all sources when disabled and fails closed if selected data is missing', { skip: !nginx }, async t => {
    const open = await running(t, { enabled: '0' });
    assert.match(await request(open.socketPath, '8.8.8.8'), /200 OK/);
    const missing = await running(t, { directory: '/missing-minigate-geo-data' });
    assert.equal(await request(missing.socketPath, '14.196.0.1'), '');
    assert.match(await request(missing.socketPath, '192.168.2.15'), /200 OK/);
});


test('real nginx accepts all bundled province includes together', { skip: !nginx }, async t => {
    const regions = fs.readFileSync(path.join(geoDir, 'regions.txt'), 'utf8').trim().split('\n').map(row => row.split(' ')[0]).join(' ');
    const fixture = await running(t, { regions });
    assert.match(await request(fixture.socketPath, '1.0.1.1'), /200 OK/);
    assert.equal(await request(fixture.socketPath, '8.8.8.8'), '');
});
