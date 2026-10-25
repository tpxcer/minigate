const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const script = path.join(root, 'root/usr/lib/minigate/proxy.sh');
const geoDir = path.join(root, 'root/usr/lib/minigate/geo');

function config(body, { enabled = '1', regions = '510000', directory = geoDir } = {}) {
    const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'mg-access-'));
    const file = path.join(dir, 'site.conf');
    fs.writeFileSync(file, '');
    fs.mkdirSync(path.join(dir, 'sites'));
    fs.mkdirSync(path.join(dir, 'streams'));
    fs.writeFileSync(path.join(dir, 'mime.types'), '');
    const quote = s => `'${s.replaceAll("'", "'\\''")}'`;
    const command = `
        export MINIGATE_PROXY_LIBRARY_ONLY=1
        export MINIGATE_NGINX_CONF=${quote(path.join(dir, 'main.conf'))}
        export MINIGATE_SITES_DIR=${quote(path.join(dir, 'sites'))}
        export MINIGATE_STREAMS_DIR=${quote(path.join(dir, 'streams'))}
        export MINIGATE_MIME_TYPES=${quote(path.join(dir, 'mime.types'))}
        export MINIGATE_PID_FILE=${quote(path.join(dir, 'nginx.pid'))}
        export MINIGATE_NGINX_ERROR_LOG=${quote(path.join(dir, 'error.log'))}
        export MINIGATE_ACCESS_LOG=${quote(path.join(dir, 'access.log'))}
        export MINIGATE_GEO_DIR=${quote(directory)}
        export MINIGATE_LOGFILE=${quote(path.join(dir, 'proxy.log'))}
        export MINIGATE_SOCKET_DIR=${quote(dir)}
        . ${quote(script)}
        uci() {
            case "$3" in
                minigate.global.access_enabled) printf '%s\\n' ${quote(enabled)} ;;
                minigate.global.access_regions) printf '%s\\n' ${quote(regions)} ;;
            esac
        }
        conf=${quote(file)}
        ${body}
    `;
    const result = spawnSync('/bin/sh', ['-c', command], { encoding: 'utf8' });
    return { ...result, conf: fs.readFileSync(file, 'utf8'), dir };
}

module.exports = { config, geoDir, root };
