#!/bin/sh
NGINX_CONF="${MINIGATE_NGINX_CONF:-/etc/minigate/nginx/minigate.conf}"
SITES_DIR="${MINIGATE_SITES_DIR:-/etc/minigate/nginx/sites}"
STREAMS_DIR="${MINIGATE_STREAMS_DIR:-/etc/minigate/nginx/streams}"
CERT_DIR="${MINIGATE_CERT_DIR:-/etc/minigate/certs}"
DEFAULT_CERT_DIR="${MINIGATE_DEFAULT_CERT_DIR:-${CERT_DIR}/_default}"
LOGFILE="${MINIGATE_LOGFILE:-/var/log/minigate-proxy.log}"
PID_FILE="${MINIGATE_PID_FILE:-/var/run/minigate-nginx.pid}"
NGINX_ERROR_LOG="${MINIGATE_NGINX_ERROR_LOG:-/var/log/minigate-nginx-error.log}"
ACCESS_LOG="${MINIGATE_ACCESS_LOG:-/var/log/minigate-access.log}"
SOCKET_DIR="${MINIGATE_SOCKET_DIR:-/var/run/minigate}"
STREAM_MODULE="${MINIGATE_STREAM_MODULE:-/usr/lib/nginx/modules/ngx_stream_module.so}"
ACCESS_LOG_MAX="${MINIGATE_ACCESS_LOG_MAX:-1048576}"
# OpenWrt 的 dnsmasq 以 addn-hosts=/tmp/hosts 读取整个目录，收到 SIGHUP 时重新加载
LAN_HOSTS_FILE="${MINIGATE_LAN_HOSTS_FILE:-/tmp/hosts/minigate}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [PROXY] $*" >> "$LOGFILE"; }

generate_main_conf() {
    local http_redirect=$(get_http_redirect)
    local use_stream=0
    mkdir -p "$(dirname "$NGINX_CONF")" "$SITES_DIR" "$STREAMS_DIR" "$SOCKET_DIR"

    if [ "$http_redirect" = "1" ] && ls "$STREAMS_DIR"/*.conf >/dev/null 2>&1; then
        use_stream=1
    fi
    if [ "$use_stream" = "1" ] && [ ! -f "$STREAM_MODULE" ]; then
        log "同端口HTTP跳转需要 nginx-mod-stream"
        return 1
    fi

    : > "$NGINX_CONF"
    [ "$use_stream" = "1" ] && echo "load_module ${STREAM_MODULE};" >> "$NGINX_CONF"
    cat >> "$NGINX_CONF" <<EOF
worker_processes auto;
pid ${PID_FILE};
error_log ${NGINX_ERROR_LOG} warn;
events { worker_connections 512; }
EOF
    if [ "$use_stream" = "1" ]; then
        cat >> "$NGINX_CONF" <<EOF
stream {
    include ${STREAMS_DIR}/*.conf;
}
EOF
    fi
    cat >> "$NGINX_CONF" <<'EOF'
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_names_hash_bucket_size 64;
    sendfile on; keepalive_timeout 65; client_max_body_size 100m;
    gzip on; gzip_types text/plain text/css application/json application/javascript text/xml;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    map $proxy_protocol_addr $minigate_client_addr {
        default $proxy_protocol_addr;
        "" $remote_addr;
    }
    log_format minigate_json escape=json
        '{"time":"$time_iso8601",'
        '"domain":"$server_name",'
        '"client":"$minigate_client_addr",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"size":$body_bytes_sent,'
        '"referer":"$http_referer",'
        '"ua":"$http_user_agent"}';
EOF
    echo "    access_log ${ACCESS_LOG} minigate_json;" >> "$NGINX_CONF"
    echo "    include ${SITES_DIR}/*.conf;" >> "$NGINX_CONF"
    cat >> "$NGINX_CONF" <<'EOF'
}
EOF
}

find_cert() {
    local domain="$1"
    local parent=$(echo "$domain" | sed 's/^[^.]*\.//')
    for try in "$domain" "_wildcard_.${parent}" "$parent"; do
        [ -f "${CERT_DIR}/${try}/fullchain.pem" ] && { echo "${CERT_DIR}/${try}"; return 0; }
    done
    for try in "$parent" "$domain"; do
        [ -L "${CERT_DIR}/${try}" ] && {
            local t=$(readlink -f "${CERT_DIR}/${try}")
            [ -f "${t}/fullchain.pem" ] && { echo "$t"; return 0; }
        }
    done
    return 1
}

check_h2() {
    local m=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1 | cut -d. -f2)
    [ "${m:-0}" -ge 25 ] && echo "new" || echo "old"
}

# 读取全局 IPv6 监听设置
get_ipv6_listen() {
    local v6=$(uci -q get minigate.global.ipv6_listen)
    echo "${v6:-0}"
}

get_http_redirect() {
    local enabled=$(uci -q get minigate.global.http_redirect)
    echo "${enabled:-0}"
}

ensure_default_cert() {
    mkdir -p "$DEFAULT_CERT_DIR"
    [ -f "${DEFAULT_CERT_DIR}/fullchain.pem" ] && [ -f "${DEFAULT_CERT_DIR}/key.pem" ] && return 0
    openssl req -x509 -nodes -newkey rsa:2048 -days 3650 \
        -subj "/CN=minigate.invalid" \
        -keyout "${DEFAULT_CERT_DIR}/key.pem" \
        -out "${DEFAULT_CERT_DIR}/fullchain.pem" >/dev/null 2>&1
}

write_default_server() {
    local conf="$1" lport="$2" ssl="$3" h2s="$4" ipv6_listen="$5" mux="$6"
    local ll="listen ${lport} default_server"
    local ll6=""
    local ex=""

    if [ "$mux" = "1" ]; then
        if [ "$ssl" = "1" ]; then
            ll="listen unix:${SOCKET_DIR}/https_${lport}.sock default_server ssl proxy_protocol"
        else
            ll="listen unix:${SOCKET_DIR}/http_${lport}.sock default_server proxy_protocol"
        fi
    elif [ "$ssl" = "1" ]; then
        ll="${ll} ssl"
    fi
    if [ "$mux" != "1" ] && [ "$ipv6_listen" = "1" ]; then
        ll6="listen [::]:${lport} default_server"
        [ "$ssl" = "1" ] && ll6="${ll6} ssl"
    fi

    if [ "$ssl" = "1" ]; then
        if [ "$h2s" = "new" ]; then
            ex="    http2 on;"
        else
            ll="${ll} http2"
            [ -n "$ll6" ] && ll6="${ll6} http2"
        fi
        ensure_default_cert
    fi

    cat > "$conf" <<SEOF
server {
    ${ll};
SEOF
    [ -n "$ll6" ] && echo "    ${ll6};" >> "$conf"
    cat >> "$conf" <<SEOF
    server_name _;
${ex}
SEOF
    if [ "$ssl" = "1" ]; then
        cat >> "$conf" <<SEOF
    ssl_certificate ${DEFAULT_CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${DEFAULT_CERT_DIR}/key.pem;
SEOF
    fi
    cat >> "$conf" <<'SEOF'
    return 444;
}
SEOF
}

ensure_default_server() {
    local lport="$1" ssl="$2" h2s="$3" ipv6_listen="$4" mux="$5"
    local key=$(echo "${lport}_${ssl}_${mux}" | tr -c 'A-Za-z0-9_' '_')
    local mark="/tmp/minigate_default_${key}.tmp"
    [ -f "$mark" ] && return 0
    : > "$mark"
    write_default_server "${SITES_DIR}/000_default_${key}.conf" "$lport" "$ssl" "$h2s" "$ipv6_listen" "$mux"
}

write_redirect_server() {
    local conf="$1" domain="$2" lport="$3"
    local authority="$domain"
    [ "$lport" = "443" ] || authority="${domain}:${lport}"

    cat >> "$conf" <<SEOF
server {
    listen unix:${SOCKET_DIR}/http_${lport}.sock proxy_protocol;
    server_name ${domain};
    return 308 https://${authority}\$request_uri;
}
SEOF
}

ensure_stream_server() {
    local lport="$1" ipv6_listen="$2"
    local mark="/tmp/minigate_stream_${lport}.tmp"
    local conf="${STREAMS_DIR}/stream_${lport}.conf"
    [ -f "$mark" ] && return 0
    : > "$mark"

    cat > "$conf" <<SEOF
map \$ssl_preread_protocol \$minigate_backend_${lport} {
    "" unix:${SOCKET_DIR}/http_${lport}.sock;
    default unix:${SOCKET_DIR}/https_${lport}.sock;
}
server {
    listen ${lport};
SEOF
    [ "$ipv6_listen" = "1" ] && echo "    listen [::]:${lport};" >> "$conf"
    cat >> "$conf" <<SEOF
    ssl_preread on;
    proxy_protocol on;
    proxy_pass \$minigate_backend_${lport};
}
SEOF
}

# 写一个完整的 server block（带 proxy_pass），同时支持 IPv6
write_server() {
    local conf="$1" domain="$2" lport="$3" taddr="$4" tport="$5" ssl="$6" h2="$7" ws="$8" h2s="$9"
    shift 9
    local ipv6_listen="${1:-0}"
    local mux="${2:-0}"

    log "生成: $domain:${lport} -> ${taddr}:${tport} (ipv6=$ipv6_listen)"

    local ll="listen ${lport}"; local ll6=""; local ex=""
    if [ "$mux" = "1" ]; then
        ll="listen unix:${SOCKET_DIR}/https_${lport}.sock ssl proxy_protocol"
    elif [ "$ssl" = "1" ]; then
        ll="${ll} ssl"
    fi

    # IPv6 listen
    if [ "$mux" != "1" ] && [ "$ipv6_listen" = "1" ]; then
        ll6="listen [::]:${lport}"
        [ "$ssl" = "1" ] && ll6="${ll6} ssl"
    fi

    # HTTPS 模式自动启用 HTTP/2
    if [ "$ssl" = "1" ]; then
        if [ "$h2s" = "new" ]; then
            ex="    http2 on;"
        else
            ll="${ll} http2"
            [ -n "$ll6" ] && ll6="${ll6} http2"
        fi
    fi

    cat >> "$conf" <<SEOF
server {
    ${ll};
SEOF
    [ -n "$ll6" ] && echo "    ${ll6};" >> "$conf"
    cat >> "$conf" <<SEOF
    server_name ${domain};
${ex}
SEOF
    if [ "$ssl" = "1" ]; then
        local cp=$(find_cert "$domain")
        [ -n "$cp" ] && cat >> "$conf" <<SEOF
    ssl_certificate ${cp}/fullchain.pem;
    ssl_certificate_key ${cp}/key.pem;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
SEOF
    fi

    # 判断目标地址是否为 IPv6
    local target_host="$taddr"
    echo "$taddr" | grep -q ':' && target_host="[${taddr}]"

    cat >> "$conf" <<SEOF
    location / {
        # 拒绝直接 IP 访问（非域名）
        if (\$host ~* "^\d+\.\d+\.\d+\.\d+") {
            return 444;
        }
        proxy_pass http://${target_host}:${tport};
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$minigate_client_addr;
        proxy_set_header X-Forwarded-For \$minigate_client_addr;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_read_timeout 300s;
        proxy_buffering off;
SEOF
    [ "$ws" = "1" ] && cat >> "$conf" <<SEOF
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
SEOF
    echo "    }" >> "$conf"; echo "}" >> "$conf"
}

generate_sites() {
    mkdir -p "$SITES_DIR" "$STREAMS_DIR" "$SOCKET_DIR"
    rm -f "$SITES_DIR"/*.conf
    rm -f "$STREAMS_DIR"/*.conf
    local h2s=$(check_h2)
    local idx=0
    local ipv6_listen=$(get_ipv6_listen)
    local http_redirect=$(get_http_redirect)

    # === 通配符域名设置 (proxy_wildcard sections) ===
    local wc_sections=$(uci -q show minigate | grep '=proxy_wildcard$' | cut -d. -f2 | cut -d= -f1)
    for sec in $wc_sections; do
        local enabled=$(uci -q get minigate.${sec}.enabled)
        [ "$enabled" = "1" ] || continue
        local domain=$(uci -q get minigate.${sec}.domain)
        [ -z "$domain" ] && continue
        local lport=$(uci -q get minigate.${sec}.listen_port); lport=${lport:-443}
        local ssl=$(uci -q get minigate.${sec}.ssl); ssl=${ssl:-0}
        local base=$(echo "$domain" | sed 's/^\*\.//')
        echo "${lport}|${ssl}" > "/tmp/minigate_proxy_${base}.tmp"
        log "通配符: $domain (端口:$lport https:$ssl ipv6:$ipv6_listen)"
    done

    # === 非通配符代理规则 (proxy sections) ===
    local sections=$(uci -q show minigate | grep '=proxy$' | cut -d. -f2 | cut -d= -f1)
    for sec in $sections; do
        local enabled=$(uci -q get minigate.${sec}.enabled)
        [ "$enabled" = "1" ] || continue
        local domain=$(uci -q get minigate.${sec}.domain)
        local lport=$(uci -q get minigate.${sec}.listen_port); lport=${lport:-443}
        local taddr=$(uci -q get minigate.${sec}.target_addr)
        local tport=$(uci -q get minigate.${sec}.target_port); tport=${tport:-80}
        local ssl=$(uci -q get minigate.${sec}.ssl); ssl=${ssl:-1}
        local h2=$(uci -q get minigate.${sec}.http2); h2=${h2:-1}
        local ws=$(uci -q get minigate.${sec}.websocket); ws=${ws:-0}
        [ -z "$domain" ] || [ -z "$taddr" ] && continue
        local mux=0
        if [ "$http_redirect" = "1" ] && [ "$ssl" = "1" ]; then
            mux=1
            ensure_stream_server "$lport" "$ipv6_listen"
            ensure_default_server "$lport" "0" "$h2s" "$ipv6_listen" "1"
        fi
        ensure_default_server "$lport" "$ssl" "$h2s" "$ipv6_listen" "$mux"
        idx=$((idx + 1))
        local conf="${SITES_DIR}/site_${idx}.conf"; > "$conf"
        write_server "$conf" "$domain" "$lport" "$taddr" "$tport" "$ssl" "$h2" "$ws" "$h2s" "$ipv6_listen" "$mux"
        [ "$mux" = "1" ] && write_redirect_server "$conf" "$domain" "$lport"
    done

    # === 子域名规则：继承通配符主域名设置 ===
    local subs=$(uci -q show minigate | grep '=subproxy$' | cut -d. -f2 | cut -d= -f1)
    for sec in $subs; do
        local parent=$(uci -q get minigate.${sec}.parent_domain)
        local prefix=$(uci -q get minigate.${sec}.prefix)
        local taddr=$(uci -q get minigate.${sec}.target_addr)
        local tport=$(uci -q get minigate.${sec}.target_port); tport=${tport:-80}
        local ws=$(uci -q get minigate.${sec}.websocket); ws=${ws:-0}
        [ -z "$parent" ] || [ -z "$prefix" ] || [ -z "$taddr" ] && continue

        local domain="${prefix}.${parent}"

        local parent_conf="/tmp/minigate_proxy_${parent}.tmp"
        local lport="443" ssl="0"
        if [ -f "$parent_conf" ]; then
            local settings=$(cat "$parent_conf")
            lport=$(echo "$settings" | cut -d'|' -f1)
            ssl=$(echo "$settings" | cut -d'|' -f2)
        fi

        idx=$((idx + 1))
        local mux=0
        if [ "$http_redirect" = "1" ] && [ "$ssl" = "1" ]; then
            mux=1
            ensure_stream_server "$lport" "$ipv6_listen"
            ensure_default_server "$lport" "0" "$h2s" "$ipv6_listen" "1"
        fi
        ensure_default_server "$lport" "$ssl" "$h2s" "$ipv6_listen" "$mux"
        local conf="${SITES_DIR}/site_${idx}.conf"; > "$conf"
        write_server "$conf" "$domain" "$lport" "$taddr" "$tport" "$ssl" "1" "$ws" "$h2s" "$ipv6_listen" "$mux"
        [ "$mux" = "1" ] && write_redirect_server "$conf" "$domain" "$lport"
    done

    rm -f /tmp/minigate_proxy_*.tmp
    rm -f /tmp/minigate_default_*.tmp
    rm -f /tmp/minigate_stream_*.tmp
}

# === 局域网直连解析 ===
# 内网设备把本机反代的域名直接解析到 LAN 地址：不依赖公网 IP、回流 NAT 和上游 DNS 缓存，
# 流量留在局域网内，也不会进入代理。公网解析仍由 DDNS 维护。

is_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }
    '
}

# 手动指定优先；留空时取 LAN 接口 IPv4，再退回 network.lan.ipaddr（可能是列表或带 /前缀）
get_lan_ip() {
    local ip
    ip=$(uci -q get minigate.global.lan_ip)
    [ -n "$ip" ] || ip=$(ubus call network.interface.lan status 2>/dev/null | \
        jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    [ -n "$ip" ] || ip=$(uci -q get network.lan.ipaddr)
    ip=${ip%% *}
    ip=${ip%%/*}
    is_ipv4 "$ip" && echo "$ip"
}

# 以生成的站点配置为准，只取实际由 nginx 提供的具体域名（跳过默认站点 _ 和通配符）
list_site_domains() {
    cat "$SITES_DIR"/*.conf 2>/dev/null | \
        sed -n 's/^[[:space:]]*server_name[[:space:]]\{1,\}\([^;]*\);.*/\1/p' | \
        tr ' ' '\n' | grep -E '^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$' | sort -u
}

send_hup() {
    kill -HUP "$@"
}

reload_dnsmasq_hosts() {
    local pids
    pids=$(pidof dnsmasq 2>/dev/null)
    [ -n "$pids" ] && send_hup $pids >/dev/null 2>&1
    return 0
}

remove_lan_hosts() {
    [ -f "$LAN_HOSTS_FILE" ] || return 0
    rm -f "$LAN_HOSTS_FILE"
    reload_dnsmasq_hosts
    log "局域网直连解析已移除"
}

# 内容未变时不重载 dnsmasq，避免每次保存都清空整个 DNS 缓存
sync_lan_hosts() {
    local ip domains domain content
    if [ "$(uci -q get minigate.global.lan_dns)" != "1" ]; then
        remove_lan_hosts
        return 0
    fi

    ip=$(get_lan_ip)
    if [ -z "$ip" ]; then
        log "局域网直连解析：未取得有效的 LAN IPv4 地址，已跳过"
        remove_lan_hosts
        return 0
    fi
    domains=$(list_site_domains)
    if [ -z "$domains" ]; then
        remove_lan_hosts
        return 0
    fi

    content="# MiniGate 局域网直连解析，由 proxy.sh 自动生成"
    for domain in $domains; do
        content="${content}
${ip} ${domain}"
    done
    [ -f "$LAN_HOSTS_FILE" ] && [ "$(cat "$LAN_HOSTS_FILE")" = "$content" ] && return 0

    mkdir -p "$(dirname "$LAN_HOSTS_FILE")" && printf '%s\n' "$content" > "$LAN_HOSTS_FILE" || {
        log "局域网直连解析：写入 ${LAN_HOSTS_FILE} 失败"
        return 1
    }
    reload_dnsmasq_hosts
    log "局域网直连解析 -> ${ip}: $(echo $domains)"
}

do_stop() {
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE" 2>/dev/null)
        if [ -n "$pid" ]; then
            kill "$pid" 2>/dev/null
            local i=0
            while [ $i -lt 10 ] && kill -0 "$pid" 2>/dev/null; do
                sleep 1; i=$((i + 1))
            done
            kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
        rm -f "$SOCKET_DIR"/*.sock
        log "已停止"
    fi
}

prepare_config() {
    generate_sites || return 1
    generate_main_conf || return 1
    nginx -t -c "$NGINX_CONF" >> "$LOGFILE" 2>&1 || { log "配置错误"; return 1; }
}

start_prepared() {
    do_stop 2>/dev/null
    sleep 1
    mkdir -p "$SOCKET_DIR"
    rm -f "$SOCKET_DIR"/*.sock
    nginx -c "$NGINX_CONF" >> "$LOGFILE" 2>&1 && log "已启动" || { log "启动失败"; return 1; }
}

do_start() {
    [ -z "$(which nginx 2>/dev/null)" ] && { log "nginx未安装"; return 1; }
    prepare_config || return 1
    start_prepared || return 1
    sync_lan_hosts
}

do_reload() {
    local old_mux=0 new_mux=0
    grep -q '^stream {' "$NGINX_CONF" 2>/dev/null && old_mux=1
    prepare_config || return 1
    grep -q '^stream {' "$NGINX_CONF" 2>/dev/null && new_mux=1
    if [ -f "$PID_FILE" ] && kill -0 $(cat "$PID_FILE" 2>/dev/null) 2>/dev/null; then
        if [ "$old_mux" != "$new_mux" ]; then
            start_prepared || return 1
        else
            kill -HUP $(cat "$PID_FILE") || return 1
            log "已重载"
        fi
    else
        start_prepared || return 1
    fi
    sync_lan_hosts
}

# /var/log 在内存中且 nginx 不会自行轮转。访问日志保留最近记录到 .1 后原地清空：
# nginx 以追加方式继续写入，登录防护的 tail -f 从头读取新内容，不会重放旧记录。
trim_logs() {
    local log_file
    if [ -f "$ACCESS_LOG" ] && [ "$(wc -c < "$ACCESS_LOG")" -gt "$ACCESS_LOG_MAX" ]; then
        tail -n 1000 "$ACCESS_LOG" > "${ACCESS_LOG}.1.tmp" && mv -f "${ACCESS_LOG}.1.tmp" "${ACCESS_LOG}.1"
        : > "$ACCESS_LOG"
    fi
    for log_file in "$NGINX_ERROR_LOG" "$LOGFILE"; do
        [ -f "$log_file" ] && [ "$(wc -c < "$log_file")" -gt 262144 ] || continue
        tail -n 300 "$log_file" > "${log_file}.tmp" && cat "${log_file}.tmp" > "$log_file"
        rm -f "${log_file}.tmp"
    done
}

if [ "${MINIGATE_PROXY_LIBRARY_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

case "$1" in
    start) do_start ;;
    stop) do_stop; remove_lan_hosts ;;
    reload) do_reload ;;
    test) prepare_config ;;
    trim-logs) trim_logs ;;
    lan-dns) sync_lan_hosts ;;
    *) echo "用法: $0 {start|stop|reload|test|trim-logs|lan-dns}" ;;
esac
