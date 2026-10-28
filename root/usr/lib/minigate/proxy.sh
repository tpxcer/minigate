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
GEO_DIR="${MINIGATE_GEO_DIR:-/usr/lib/minigate/geo}"
MIME_TYPES="${MINIGATE_MIME_TYPES:-/etc/nginx/mime.types}"
LOCK_FILE="${MINIGATE_PROXY_LOCK:-/var/lock/minigate-proxy.lock}"
STATUS_FILE="${MINIGATE_PROXY_STATUS:-/var/run/minigate/proxy.status}"
INIT_SCRIPT="${MINIGATE_INIT:-/etc/init.d/minigate}"
# 每次生成使用独立临时目录记录端口、默认站点和通配符设置，结束后删除
GEN_TMP=""

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [PROXY] $*" >> "$LOGFILE"; }

# 生成配置时的提示同时写日志，并在总览页显示
warn() {
    log "$*"
    [ -n "$GEN_TMP" ] && printf '%s\n' "$*" >> "$GEN_TMP/warnings"
}

# LuCI 保存、证书续期和更新可能同时触发生成；串行化，避免互相删除刚生成的文件。
lock_proxy() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    exec 6>"$LOCK_FILE" || return 0
    flock -x 6
}

write_status() {
    local result="$1" message="$2" tmp
    mkdir -p "$(dirname "$STATUS_FILE")" 2>/dev/null || return 0
    tmp="${STATUS_FILE}.$$"
    {
        printf 'result=%s\n' "$result"
        printf 'time=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'message=%s\n' "$message"
        [ -n "$GEN_TMP" ] && [ -f "$GEN_TMP/warnings" ] && sed 's/^/warning=/' "$GEN_TMP/warnings"
    } > "$tmp" && mv -f "$tmp" "$STATUS_FILE"
}

generate_main_conf() {
    local http_redirect=$(get_http_redirect)
    local use_stream=0
    mkdir -p "$(dirname "$NGINX_CONF")" "$SITES_DIR" "$STREAMS_DIR" "$SOCKET_DIR"

    if [ "$http_redirect" = "1" ] && ls "$STREAMS_DIR"/*.conf >/dev/null 2>&1; then
        use_stream=1
    fi
    if [ "$use_stream" = "1" ] && [ ! -f "$STREAM_MODULE" ]; then
        warn "同端口HTTP跳转需要 nginx-mod-stream，请先安装"
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
EOF
    echo "    include ${MIME_TYPES};" >> "$NGINX_CONF"
    cat >> "$NGINX_CONF" <<'EOF'
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
    # 所有站点都支持 WebSocket；普通请求仍按 nginx 默认关闭上游连接
    map $http_upgrade $minigate_connection_upgrade {
        default upgrade;
        "" close;
    }
    log_format minigate_json escape=json
        '{"time":"$time_iso8601",'
        '"domain":"$server_name",'
        '"client":"$minigate_client_addr",'
        '"method":"$request_method",'
        '"uri":"$request_uri",'
        '"status":$status,'
        '"upstream_status":"$upstream_status",'
        '"size":$body_bytes_sent,'
        '"referer":"$http_referer",'
        '"ua":"$http_user_agent"}';
EOF
    write_geo_access >> "$NGINX_CONF"
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

# nginx 1.25 起用独立的 http2 指令；同时兼容以后的主版本号
check_h2() {
    local v major minor
    v=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    major=${v%%.*}
    minor=${v#*.}
    case "$major" in ''|*[!0-9]*) major=0 ;; esac
    case "$minor" in ''|*[!0-9]*) minor=0 ;; esac
    if [ "$major" -gt 1 ] || { [ "$major" = "1" ] && [ "$minor" -ge 25 ]; }; then
        echo "new"
    else
        echo "old"
    fi
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

# 同端口分流已由本机 stream 写入 PROXY protocol；不读取访客传来的转发头。
write_geo_access() {
    [ "$(uci -q get minigate.global.access_enabled)" = "1" ] || return 0
    cat <<'EOF'
    geo $minigate_client_addr $minigate_geo_allowed {
        default 0;
        127.0.0.1/32 1;
        10.0.0.0/8 1;
        172.16.0.0/12 1;
        192.168.0.0/16 1;
        ::1/128 1;
        fc00::/7 1;
        fe80::/10 1;
EOF
    write_lan_ipv6_access
    local region
    for region in $(uci -q get minigate.global.access_regions | tr ' ' '\n' | sort -u); do
        # 仅接受随包提供的省级代码，防止 UCI 值进入路径或 Nginx 指令。
        case "$region" in
            [0-9][0-9]0000) ;;
            *) log "访问范围：忽略无效地区代码"; continue ;;
        esac
        if [ -f "$GEO_DIR/$region.conf" ] && grep -q "^${region} " "$GEO_DIR/regions.txt"; then
            echo "        include ${GEO_DIR}/${region}.conf;"
        else
            log "访问范围：地区 ${region} 数据缺失，该地区公网请求将被拒绝"
        fi
    done
    echo "    }"
}

write_lan_ipv6_access() {
    local status address mask i=0
    status=$(ubus call network.interface.lan status 2>/dev/null)
    [ -n "$status" ] || return 0
    # LAN 获得的全球 IPv6 前缀也属于内网；只接受 LAN 接口实际分配的子网。
    while [ "$i" -lt 32 ]; do
        address=$(printf '%s' "$status" | jsonfilter -e "@[\"ipv6-prefix-assignment\"][${i}].address" 2>/dev/null)
        mask=$(printf '%s' "$status" | jsonfilter -e "@[\"ipv6-prefix-assignment\"][${i}].mask" 2>/dev/null)
        [ -n "$address" ] || break
        i=$((i + 1))
        case "$address" in *[!0-9a-fA-F:]*|[!23]*) continue ;; esac
        case "$mask" in ''|*[!0-9]*) continue ;; esac
        [ "$mask" -ge 48 ] && [ "$mask" -le 128 ] || continue
        echo "        ${address}/${mask} 1;"
    done
}

write_geo_guard() {
    [ "$(uci -q get minigate.global.access_enabled)" = "1" ] || return 0
    echo '    if ($minigate_geo_allowed = 0) { return 444; }' >> "$1"
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
    local mark="${GEN_TMP}/default_${key}"
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
SEOF
    write_geo_guard "$conf"
    cat >> "$conf" <<SEOF
    return 308 https://${authority}\$request_uri;
}
SEOF
}

ensure_stream_server() {
    local lport="$1" ipv6_listen="$2"
    local mark="${GEN_TMP}/stream_${lport}"
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
    write_geo_guard "$conf"
    if [ "$ssl" = "1" ]; then
        local cp=$(find_cert "$domain")
        if [ -n "$cp" ]; then
            cat >> "$conf" <<SEOF
    ssl_certificate ${cp}/fullchain.pem;
    ssl_certificate_key ${cp}/key.pem;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
SEOF
        else
            warn "${domain} 没有可用证书，HTTPS 访问会失败；请先在「SSL 证书」页签发"
        fi
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
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$minigate_connection_upgrade;
    }
}
SEOF
}

# 同一端口只能用于一种协议：明文 HTTP、HTTPS，或 HTTPS + HTTP 跳转（stream 分流）。
# 先占用的规则生效，冲突的规则跳过并提示，避免生成 nginx 无法加载的配置。
claim_port() {
    local lport="$1" mode="$2" domain="$3" file used
    file="${GEN_TMP}/port_${lport}"
    if [ -f "$file" ]; then
        used=$(cat "$file")
        [ "$used" = "$mode" ] && return 0
        warn "跳过 ${domain}：端口 ${lport} 已用于$(port_mode_label "$used")，不能同时用于$(port_mode_label "$mode")"
        return 1
    fi
    echo "$mode" > "$file"
}

port_mode_label() {
    case "$1" in
        http) echo "HTTP" ;;
        https) echo "HTTPS" ;;
        *) echo "HTTPS（含 HTTP 跳转）" ;;
    esac
}

# 生成一条站点规则；返回非 0 表示因端口冲突被跳过
add_site() {
    local domain="$1" lport="$2" taddr="$3" tport="$4" ssl="$5" h2s="$6" ipv6_listen="$7" http_redirect="$8"
    local mux=0 mode=http conf
    if [ "$ssl" = "1" ]; then
        mode=https
        if [ "$http_redirect" = "1" ]; then
            mux=1
            mode=mux
        fi
    fi
    claim_port "$lport" "$mode" "$domain" || return 1
    if [ "$mux" = "1" ]; then
        ensure_stream_server "$lport" "$ipv6_listen"
        ensure_default_server "$lport" "0" "$h2s" "$ipv6_listen" "1"
    fi
    ensure_default_server "$lport" "$ssl" "$h2s" "$ipv6_listen" "$mux"
    SITE_INDEX=$((SITE_INDEX + 1))
    conf="${SITES_DIR}/site_${SITE_INDEX}.conf"
    : > "$conf"
    write_server "$conf" "$domain" "$lport" "$taddr" "$tport" "$ssl" "1" "1" "$h2s" "$ipv6_listen" "$mux"
    [ "$mux" = "1" ] && write_redirect_server "$conf" "$domain" "$lport"
    return 0
}

wildcard_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9.-' '_'
}

generate_sites() {
    local own_tmp=0
    if [ -z "$GEN_TMP" ]; then
        GEN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/minigate-gen.XXXXXX") || return 1
        own_tmp=1
    fi
    mkdir -p "$SITES_DIR" "$STREAMS_DIR" "$SOCKET_DIR"
    rm -f "$SITES_DIR"/*.conf
    rm -f "$STREAMS_DIR"/*.conf
    local h2s=$(check_h2)
    local ipv6_listen=$(get_ipv6_listen)
    local http_redirect=$(get_http_redirect)
    SITE_INDEX=0

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
        echo "${lport}|${ssl}" > "${GEN_TMP}/wildcard_$(wildcard_key "$base")"
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
        [ -z "$domain" ] || [ -z "$taddr" ] && continue
        add_site "$domain" "$lport" "$taddr" "$tport" "$ssl" "$h2s" "$ipv6_listen" "$http_redirect"
    done

    # === 子域名规则：继承通配符主域名设置；主域名未启用时整组不生效 ===
    local subs=$(uci -q show minigate | grep '=subproxy$' | cut -d. -f2 | cut -d= -f1)
    for sec in $subs; do
        local enabled=$(uci -q get minigate.${sec}.enabled)
        [ "${enabled:-1}" = "1" ] || continue
        local parent=$(uci -q get minigate.${sec}.parent_domain)
        local prefix=$(uci -q get minigate.${sec}.prefix)
        local taddr=$(uci -q get minigate.${sec}.target_addr)
        local tport=$(uci -q get minigate.${sec}.target_port); tport=${tport:-80}
        [ -z "$parent" ] || [ -z "$prefix" ] || [ -z "$taddr" ] && continue

        local domain="${prefix}.${parent}"
        local parent_conf="${GEN_TMP}/wildcard_$(wildcard_key "$parent")"
        if [ ! -f "$parent_conf" ]; then
            warn "跳过 ${domain}：通配符主域名 *.${parent} 未启用或不存在"
            continue
        fi
        local settings=$(cat "$parent_conf")
        local lport=${settings%%|*}
        local ssl=${settings#*|}
        add_site "$domain" "$lport" "$taddr" "$tport" "$ssl" "$h2s" "$ipv6_listen" "$http_redirect"
    done

    if [ "$own_tmp" = "1" ]; then
        rm -rf "$GEN_TMP"
        GEN_TMP=""
    fi
    return 0
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

# 保存当前配置，生成或检查失败时恢复，磁盘上始终保留最后一份可用配置
snapshot_config() {
    local dir="$1"
    mkdir -p "$dir/sites" "$dir/streams" || return 1
    cp -p "$SITES_DIR"/*.conf "$dir/sites/" 2>/dev/null
    cp -p "$STREAMS_DIR"/*.conf "$dir/streams/" 2>/dev/null
    [ -f "$NGINX_CONF" ] && cp -p "$NGINX_CONF" "$dir/main.conf"
    return 0
}

restore_config() {
    local dir="$1"
    rm -f "$SITES_DIR"/*.conf "$STREAMS_DIR"/*.conf
    cp -p "$dir/sites/"*.conf "$SITES_DIR/" 2>/dev/null
    cp -p "$dir/streams/"*.conf "$STREAMS_DIR/" 2>/dev/null
    if [ -f "$dir/main.conf" ]; then
        cp -p "$dir/main.conf" "$NGINX_CONF"
    else
        rm -f "$NGINX_CONF"
    fi
}

# 生成并检查配置；失败时恢复上一份配置，不影响正在运行的 nginx
prepare_config() {
    local backup output rc=0 message=""
    GEN_TMP=$(mktemp -d "${TMPDIR:-/tmp}/minigate-gen.XXXXXX") || { log "无法创建临时目录"; return 1; }
    backup="${GEN_TMP}/backup"
    output="${GEN_TMP}/nginx-test.log"
    snapshot_config "$backup"

    if ! generate_sites || ! generate_main_conf; then
        rc=1
        message="生成配置失败，已保留上一份配置"
    elif ! nginx -t -c "$NGINX_CONF" > "$output" 2>&1; then
        rc=1
        cat "$output" >> "$LOGFILE"
        message="配置检查失败，已保留上一份配置：$(grep -m1 -E 'emerg|error' "$output" | sed 's/^nginx: //')"
        log "配置错误，已恢复上一份配置"
    fi

    if [ "$rc" = "0" ]; then
        write_status ok "配置检查通过"
    else
        restore_config "$backup"
        write_status error "$message"
    fi
    rm -rf "$GEN_TMP"
    GEN_TMP=""
    return "$rc"
}

nginx_pid() {
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pid" 2>/dev/null || return 1
    echo "$pid"
}

# 由 procd 启动（前台运行，崩溃后自动拉起）。启动前清掉上次异常退出留下的 socket。
do_run() {
    mkdir -p "$SOCKET_DIR"
    rm -f "$SOCKET_DIR"/*.sock
    exec nginx -c "$NGINX_CONF" -g 'daemon off;'
}

# 让运行中的 nginx 加载新配置。stream 模块增减需要重启进程，交给 procd 处理。
apply_config() {
    local pid old_stream="$1" new_stream=0
    grep -q '^stream {' "$NGINX_CONF" 2>/dev/null && new_stream=1
    pid=$(nginx_pid)
    if [ -n "$pid" ] && [ "$old_stream" = "$new_stream" ]; then
        kill -HUP "$pid" || return 1
        log "已重载"
    else
        MINIGATE_SKIP_PREPARE=1 "$INIT_SCRIPT" start 6>&- >/dev/null 2>&1 || return 1
        log "已交由 procd 启动"
    fi
}

do_reload() {
    local old_stream=0
    [ "$(uci -q get minigate.global.enabled)" = "1" ] || return 0
    lock_proxy
    grep -q '^stream {' "$NGINX_CONF" 2>/dev/null && old_stream=1
    prepare_config || return 1
    apply_config "$old_stream" || return 1
    sync_lan_hosts
}

# 仅向已加载新配置的 nginx 发送重载信号（init 已完成生成和检查）
do_hup() {
    local pid
    pid=$(nginx_pid) || return 0
    kill -HUP "$pid" && log "已重载"
}

do_stop() {
    remove_lan_hosts
    rm -f "$SOCKET_DIR"/*.sock 2>/dev/null
    write_status stopped "反向代理已停止"
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
    prepare|test) lock_proxy; prepare_config ;;
    run) do_run ;;
    reload) do_reload ;;
    hup) do_hup ;;
    stop) do_stop ;;
    trim-logs) trim_logs ;;
    lan-dns) sync_lan_hosts ;;
    *) echo "用法: $0 {prepare|run|reload|hup|stop|trim-logs|lan-dns}" ;;
esac
