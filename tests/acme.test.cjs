const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const script = path.join(root, 'root/usr/lib/minigate/acme.sh');

function runRenew({ renewChangesCert }) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'minigate-acme-test-'));
    const acmeHome = path.join(dir, 'acme');
    const certDir = path.join(dir, 'certs');
    const reloadLog = path.join(dir, 'reload.log');
    const cert = path.join(certDir, '_wildcard_.example.com/fullchain.pem');
    fs.mkdirSync(path.join(acmeHome, 'dnsapi'), { recursive: true });
    fs.mkdirSync(path.dirname(cert), { recursive: true });
    fs.writeFileSync(cert, 'old-certificate\n');
    fs.writeFileSync(path.join(acmeHome, 'acme.sh'), renewChangesCert
        ? `#!/bin/sh\nprintf 'renewed-certificate\\n' > ${JSON.stringify(cert)}\n`
        : '#!/bin/sh\necho "Skip, Next renewal time is in the future"\n');
    fs.chmodSync(path.join(acmeHome, 'acme.sh'), 0o755);
    fs.writeFileSync(path.join(dir, 'proxy.sh'), `printf '%s\\n' "$1" >> ${JSON.stringify(reloadLog)}\n`);

    const result = spawnSync('/bin/sh', [script, 'renew'], {
        encoding: 'utf8',
        env: {
            ...process.env,
            MINIGATE_ACME_HOME: acmeHome,
            MINIGATE_CERT_DIR: certDir,
            MINIGATE_ACME_LOG: path.join(dir, 'acme.log'),
            MINIGATE_PROXY_SCRIPT: path.join(dir, 'proxy.sh')
        }
    });
    const reloads = fs.existsSync(reloadLog) ? fs.readFileSync(reloadLog, 'utf8').trim().split('\n') : [];
    return { result, reloads };
}

test('renewal reloads the reverse proxy when a certificate file changes', () => {
    const { result, reloads } = runRenew({ renewChangesCert: true });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.deepEqual(reloads, ['reload']);
});

test('renewal without certificate changes leaves the running proxy alone', () => {
    const { result, reloads } = runRenew({ renewChangesCert: false });
    assert.equal(result.status, 0, result.stderr || result.stdout);
    assert.deepEqual(reloads, []);
});
