#!/bin/sh
LOGFILE="${MINIGATE_DDNS_LOG:-/var/log/minigate-ddns.log}"
HISTORY_DIR="${MINIGATE_HISTORY_DIR:-/etc/minigate/ddns-history}"
HISTORY_WINDOW="${MINIGATE_HISTORY_WINDOW:-86400}"
CACHE_DIR="${MINIGATE_CACHE_DIR:-/tmp}"
SINGBOX_CONFIG="${MINIGATE_SINGBOX_CONFIG:-/opt/open-box/etc/config.json}"
CLASH_API_URL="${MINIGATE_CLASH_API_URL:-http://127.0.0.1:9095}"
LOCK_FILE="${MINIGATE_DDNS_LOCK:-/var/lock/minigate-ddns.lock}"
# 运行状态只放内存，不写 /etc/config：避免每次检查都提交配置、备份里混入运行数据
STATE_DIR="${MINIGATE_DDNS_STATE_DIR:-/var/run/minigate/ddns}"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [DDNS] $*" >> "$LOGFILE"; }
trim_log() { [ -f "$LOGFILE" ] && [ "$(wc -l < "$LOGFILE")" -gt 300 ] && { tail -n 150 "$LOGFILE" > "${LOGFILE}.tmp"; mv "${LOGFILE}.tmp" "$LOGFILE"; }; }

# 定时、保存页面和手动同步可能同时运行，串行化避免重复创建 Cloudflare 记录。
# 定时检查遇到正在运行的同步直接跳过，强制同步排队等待。
lock_ddns() {
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null
    touch "$LOCK_FILE" 2>/dev/null || return 0
    exec 7>"$LOCK_FILE"
    if [ "$1" = "wait" ]; then
        flock -x 7
    else
        flock -n 7
    fi
}

# 状态文件与 IP 历史一样按域名命名；LuCI 侧用相同规则读取
state_key() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '_'
}

state_value() {
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# write_state 域名 状态 说明 IPv4 IPv6 更新时间 下次检查；IP 为空时保留上次结果
write_state() {
    local key file tmp ip ip6
    key=$(state_key "$1")
    [ -n "$key" ] || return 0
    mkdir -p "$STATE_DIR" 2>/dev/null || return 0
    file="${STATE_DIR}/${key}.state"
    tmp="${file}.$$"
    ip="$4"; ip6="$5"
    [ -n "$ip" ] || ip=$(state_value "$file" ip)
    [ -n "$ip6" ] || ip6=$(state_value "$file" ip6)
    {
        printf 'status=%s\n' "$2"
        printf 'message=%s\n' "$3"
        printf 'ip=%s\n' "$ip"
        printf 'ip6=%s\n' "$ip6"
        printf 'updated=%s\n' "$6"
        printf 'next=%s\n' "$7"
    } > "$tmp" && mv -f "$tmp" "$file"
}

mark_stopped() {
    local sec domain file
    for sec in $(uci -q -X show minigate | grep '=ddns$' | cut -d. -f2 | cut -d= -f1); do
        domain=$(uci -q get minigate.${sec}.domain)
        [ -n "$domain" ] || continue
        file="${STATE_DIR}/$(state_key "$domain").state"
        write_state "$domain" stopped "已停止" "" "" "$(state_value "$file" updated)" ""
    done
}

# 只接受公网地址：软路由在上级路由 NAT 之后时，网卡上是内网地址，不能推到 Cloudflare
is_public_ipv4() {
    printf '%s\n' "$1" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i + 0 > 255) exit 1
            a = $1 + 0; b = $2 + 0
            if (a == 0 || a == 10 || a == 127 || a >= 224) exit 1
            if (a == 100 && b >= 64 && b <= 127) exit 1
            if (a == 169 && b == 254) exit 1
            if (a == 172 && b >= 16 && b <= 31) exit 1
            if (a == 192 && b == 168) exit 1
            if (a == 198 && (b == 18 || b == 19)) exit 1
        }'
}

# 全球单播 2000::/3；排除 ULA、链路本地等
is_public_ipv6() {
    case "$1" in
        *[!0-9a-fA-F:]*) return 1 ;;
        [23][0-9a-fA-F]*:*) return 0 ;;
    esac
    return 1
}

history_now() {
    if [ -n "${MINIGATE_HISTORY_NOW:-}" ]; then
        printf '%s\n' "$MINIGATE_HISTORY_NOW"
    else
        date +%s
    fi
}

compact_history_file() {
    local file="$1" now="$2" cutoff tmp
    cutoff=$((now - HISTORY_WINDOW))
    tmp="${file}.tmp.$$"

    awk -F '\t' -v cutoff="$cutoff" '
        $1 ~ /^[0-9]+$/ && NF >= 2 {
            if ($1 < cutoff) {
                anchor = $0
                next
            }
            if (!emitted && anchor != "") {
                print anchor
                emitted = 1
            }
            print
            emitted = 1
        }
        END {
            if (!emitted && anchor != "") print anchor
        }
    ' "$file" > "$tmp" && chmod 600 "$tmp" 2>/dev/null && mv "$tmp" "$file"
}

record_ip_history_locked() {
    local file="$1" ip="$2" now="$3" last_ip
    if [ -f "$file" ]; then
        last_ip=$(awk -F '\t' 'NF >= 2 { value=$2 } END { print value }' "$file" 2>/dev/null)
    else
        last_ip=""
    fi
    [ "$last_ip" = "$ip" ] && return 0

    printf '%s\t%s\n' "$now" "$ip" >> "$file" || return 1
    chmod 600 "$file" 2>/dev/null || true
    compact_history_file "$file" "$now"
}

record_ip_history() {
    local section="$1" family="$2" ip="$3" safe_section file now last_ip
    case "$family" in ipv4|ipv6) ;; *) return 1 ;; esac
    [ -n "$ip" ] || return 1

    safe_section=$(printf '%s' "$section" | tr -c 'A-Za-z0-9_-' '_')
    [ -n "$safe_section" ] || return 1
    if [ ! -d "$HISTORY_DIR" ]; then
        mkdir -p "$HISTORY_DIR" || return 1
        chmod 700 "$HISTORY_DIR" 2>/dev/null || true
    fi
    file="${HISTORY_DIR}/${safe_section}.${family}.tsv"
    if [ -f "$file" ]; then
        last_ip=$(awk -F '\t' 'NF >= 2 { value=$2 } END { print value }' "$file" 2>/dev/null)
        [ "$last_ip" = "$ip" ] && return 0
    fi
    now=$(history_now)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac

    if command -v flock >/dev/null 2>&1; then
        (
            umask 077
            exec 8>"${file}.lock"
            flock -x 8 || exit 1
            record_ip_history_locked "$file" "$ip" "$now"
        )
    else
        record_ip_history_locked "$file" "$ip" "$now"
    fi
}

# 只清运行中 DNS 缓存，不重启 sing-box、dnsmasq 或代理链路。
flush_singbox_dns_cache() {
    local secret http_code
    [ -r "$SINGBOX_CONFIG" ] || return 2
    command -v jsonfilter >/dev/null 2>&1 || return 2
    command -v curl >/dev/null 2>&1 || return 2

    secret=$(jsonfilter -i "$SINGBOX_CONFIG" -e '@.experimental.clash_api.secret' 2>/dev/null)
    if [ -n "$secret" ]; then
        http_code=$(printf 'Authorization: Bearer %s\n' "$secret" | \
            curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 \
                -X POST -H @- "${CLASH_API_URL}/cache/dns/flush" 2>/dev/null)
    else
        http_code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 1 --max-time 3 \
            -X POST "${CLASH_API_URL}/cache/dns/flush" 2>/dev/null)
    fi
    case "$http_code" in 2??) return 0 ;; *) return 1 ;; esac
}

send_hup() {
    kill -HUP "$@"
}

flush_dnsmasq_cache() {
    local pids
    command -v pidof >/dev/null 2>&1 || return 2
    pids=$(pidof dnsmasq 2>/dev/null)
    [ -n "$pids" ] || return 2
    send_hup $pids >/dev/null 2>&1
}

refresh_local_dns_caches() {
    local domain="$1" result
    if flush_singbox_dns_cache; then
        log "$domain: sing-box DNS缓存已刷新"
    else
        result=$?
        [ "$result" = "2" ] || log "$domain: sing-box DNS缓存刷新失败（接口不可用）"
    fi

    if flush_dnsmasq_cache; then
        log "$domain: dnsmasq DNS缓存已刷新"
    else
        result=$?
        [ "$result" = "2" ] || log "$domain: dnsmasq DNS缓存刷新失败"
    fi
    return 0
}

# ====== IPv4 获取 ======
get_ip4_iface() {
    local ip=""
    ip=$(ubus call network.interface.${1:-wan} status 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    [ -z "$ip" ] && ip=$(ifstatus "${1:-wan}" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0].address' 2>/dev/null)
    echo "$ip" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# 依次请求查询地址，取第一个公网 IPv4；HTTPS 优先，HTTP 仅作兜底
IP4_FALLBACK_URLS="https://ddns.oray.com/checkip http://ip.3322.net http://members.3322.org/dyndns/getip http://ns1.dnspod.net:6666"

get_ip4_url() {
    local ip="" url
    for url in $1 $IP4_FALLBACK_URLS; do
        ip=$(fetch_ip4 "$url")
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    done
    echo ""
}

fetch_ip4() {
    local url="$1" ip candidate host port scheme resolved
    host=$(echo "$url" | sed -E 's|https?://||;s|/.*||;s|:.*||')
    port=$(echo "$url" | sed -E 's|https?://[^/:]*||' | grep -oE '^:[0-9]+' | tr -d ':')
    scheme="http"
    echo "$url" | grep -q '^https' && scheme="https"
    [ -z "$port" ] && { [ "$scheme" = "https" ] && port="443" || port="80"; }

    # 方法1: 直连
    for candidate in $(curl -4 -s --connect-timeout 3 --max-time 8 "$url" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -3); do
        is_public_ipv4 "$candidate" && { echo "$candidate"; return 0; }
    done

    # 方法2: 用公共 DNS 解析后直连（绕过透明代理的 fake-ip 解析）
    resolved=$(nslookup "$host" 223.5.5.5 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | head -1 | awk '{print $2}')
    is_public_ipv4 "$resolved" || return 0
    for candidate in $(curl -4 -s --connect-timeout 3 --max-time 8 --resolve "${host}:${port}:${resolved}" "$url" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -3); do
        is_public_ipv4 "$candidate" && { echo "$candidate"; return 0; }
    done
    return 0
}

# ====== IPv6 获取 ======
get_ip6_iface() {
    local status ip iface="${1:-wan6}"
    status=$(ubus call network.interface.${iface} status 2>/dev/null)
    [ -n "$status" ] || status=$(ifstatus "${iface}" 2>/dev/null)
    # 取第一个全球单播地址（跳过 ULA、链路本地），没有时再看前缀分配给本机的地址
    for ip in $(printf '%s' "$status" | jsonfilter -e '@["ipv6-address"][*].address' 2>/dev/null) \
              $(printf '%s' "$status" | jsonfilter -e '@["ipv6-prefix-assignment"][*]["local-address"].address' 2>/dev/null); do
        is_public_ipv6 "$ip" && { echo "$ip"; return 0; }
    done
    echo ""
}

get_ip6_url() {
    local url="$1" ip=""
    local host=$(echo "$url" | sed -E 's|https?://||;s|/.*||;s|:.*||')
    local port=$(echo "$url" | sed -E 's|https?://[^/:]*||' | grep -oE '^:[0-9]+' | tr -d ':')

    # 先尝试直连
    ip=$(curl -6 -s --connect-timeout 5 --max-time 10 "$url" 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -1)

    # 如果失败，DNS 解析后直连绕过代理
    if [ -z "$ip" ]; then
        local resolved=$(nslookup "$host" 223.5.5.5 2>/dev/null | grep -A1 'Name:' | grep 'Address:' | head -1 | awk '{print $2}')
        if [ -n "$resolved" ]; then
            local scheme="http"
            echo "$url" | grep -q '^https' && scheme="https"
            [ -z "$port" ] && { [ "$scheme" = "https" ] && port="443" || port="80"; }
            ip=$(curl -6 -s --connect-timeout 5 --max-time 10 --resolve "${host}:${port}:${resolved}" "$url" 2>/dev/null | grep -oE '([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}' | head -1)
        fi
    fi
    is_public_ipv6 "$ip" && echo "$ip"
}

# Token 经标准输入交给 curl，不出现在进程参数中。
cf_api() {
    local token="$1"
    shift
    printf 'Authorization: Bearer %s\n' "$token" | \
        curl -s --connect-timeout 10 --max-time 20 -H @- -H "Content-Type: application/json" "$@" 2>/dev/null
}

# ====== Cloudflare API：支持 A 和 AAAA 记录 ======
cf_update() {
    local zone_id="$1" token="$2" domain="$3" ip="$4" record_type="$5"
    # record_type: A 或 AAAA
    [ -z "$record_type" ] && record_type="A"
    local resp match_resp rids rid keep_id result changed=0
    resp=$(cf_api "$token" "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=${record_type}&name=${domain}")
    result=$(echo "$resp" | jsonfilter -e '$.success' 2>/dev/null)
    [ "$result" = "true" ] || { echo "false"; return 1; }

    rids=$(echo "$resp" | jsonfilter -e '$.result[*].id' 2>/dev/null)
    if [ -n "$rids" ]; then
        match_resp=$(cf_api "$token" "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records?type=${record_type}&name=${domain}&content=${ip}")
        result=$(echo "$match_resp" | jsonfilter -e '$.success' 2>/dev/null)
        [ "$result" = "true" ] || { echo "false"; return 1; }
        keep_id=$(echo "$match_resp" | jsonfilter -e '$.result[0].id' 2>/dev/null)

        if [ -z "$keep_id" ]; then
            for rid in $rids; do keep_id="$rid"; break; done
            resp=$(cf_api "$token" -X PUT \
                -d "{\"type\":\"$record_type\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}" \
                "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${keep_id}")
            result=$(echo "$resp" | jsonfilter -e '$.success' 2>/dev/null)
            [ "$result" = "true" ] || { echo "false"; return 1; }
            changed=1
        fi

        for rid in $rids; do
            [ "$rid" = "$keep_id" ] && continue
            resp=$(cf_api "$token" -X DELETE "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${rid}")
            result=$(echo "$resp" | jsonfilter -e '$.success' 2>/dev/null)
            [ "$result" = "true" ] || { echo "false"; return 1; }
            changed=1
        done
        [ "$changed" = "1" ] && echo "changed" || echo "unchanged"
    else
        resp=$(cf_api "$token" -X POST \
            -d "{\"type\":\"$record_type\",\"name\":\"$domain\",\"content\":\"$ip\",\"ttl\":120,\"proxied\":false}" \
            "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records")
        result=$(echo "$resp" | jsonfilter -e '$.success' 2>/dev/null)
        [ "$result" = "true" ] && echo "changed" || { echo "false"; return 1; }
    fi
}

ddns_interval() {
    local interval
    interval=$(uci -q get minigate.${1}.check_interval)
    case "$interval" in ''|*[!0-9]*) interval=300 ;; esac
    [ "$interval" -ge 300 ] 2>/dev/null || interval=300
    echo "$interval"
}

# 定时任务每 5 分钟触发；未到本记录的检查间隔时跳过，留 30 秒余量吸收启动抖动。
ddns_due() {
    local sec="$1" last now
    last=$(cat "${CACHE_DIR}/minigate_ddns_${sec}.checked" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) return 0 ;; esac
    now=$(date +%s)
    [ "$now" -ge "$last" ] || return 0
    [ $((now - last + 30)) -ge "$(ddns_interval "$sec")" ]
}

# 下一次实际执行的整 5 分钟时刻，与 ddns_due 的判断一致
calc_next() {
    local interval="${1:-300}"
    local now=$(date +%s)
    local next=$(( (now + interval + 269) / 300 * 300 ))
    date -d "@${next}" '+%H:%M:%S' 2>/dev/null || echo "${interval}秒后"
}

update_one() {
    local sec="$1" force="$2"
    local enabled=$(uci -q get minigate.${sec}.enabled)
    [ "$enabled" = "1" ] || return 0
    date +%s > "${CACHE_DIR}/minigate_ddns_${sec}.checked"

    local domain=$(uci -q get minigate.${sec}.domain)
    local zone_id=$(uci -q get minigate.${sec}.cf_zone_id)
    local token=$(uci -q get minigate.${sec}.cf_api_token)
    local ip_source=$(uci -q get minigate.${sec}.ip_source)
    local iface=$(uci -q get minigate.${sec}.interface)
    local ip_url=$(uci -q get minigate.${sec}.ip_url)
    local interval=$(ddns_interval "$sec")
    local ip_version=$(uci -q get minigate.${sec}.ip_version); ip_version=${ip_version:-ipv4}
    local iface6=$(uci -q get minigate.${sec}.interface6); iface6=${iface6:-wan6}
    local ip_url6=$(uci -q get minigate.${sec}.ip_url6); ip_url6=${ip_url6:-https://api6.ipify.org}

    [ -z "$domain" ] || [ -z "$zone_id" ] || [ -z "$token" ] && {
        log "$domain: 配置不完整"
        write_state "$domain" error "配置不完整" "" "" "$(date '+%Y-%m-%d %H:%M:%S')" ""
        return 1
    }

    local cache="${CACHE_DIR}/minigate_ddns_${sec}.cache"
    local cache6="${CACHE_DIR}/minigate_ddns_${sec}_v6.cache"
    local cached=$(cat "$cache" 2>/dev/null)
    local cached6=$(cat "$cache6" 2>/dev/null)
    local next_time=$(calc_next "$interval")
    local any_ok=0 any_fail=0
    local result_ip="" result_ip6=""
    local msgs="" refresh_dns=0

    # ====== IPv4 处理 ======
    if [ "$ip_version" = "ipv4" ] || [ "$ip_version" = "dual" ]; then
        local ip4=""
        case "$ip_source" in url) ip4=$(get_ip4_url "$ip_url");; *) ip4=$(get_ip4_iface "$iface");; esac

        if [ -n "$ip4" ] && ! is_public_ipv4 "$ip4"; then
            log "$domain: 网卡地址 $ip4 不是公网地址（可能在上级路由 NAT 之后），请改用「从外部URL获取」"
            msgs="${msgs}IPv4 ${ip4} 不是公网地址; "
            any_fail=1
            ip4=""
        elif [ -z "$ip4" ]; then
            log "$domain: 获取IPv4失败"
            msgs="${msgs}IPv4获取失败; "
            any_fail=1
        else
            record_ip_history "$domain" "ipv4" "$ip4" || log "$domain: IPv4历史记录写入失败"
        fi

        if [ -n "$ip4" ] && { [ "$force" = "1" ] || [ "$ip4" != "$cached" ]; }; then
            log "$domain: IPv4 ${cached:-无} -> $ip4"
            local result=$(cf_update "$zone_id" "$token" "$domain" "$ip4" "A")
            if [ "$result" = "changed" ] || [ "$result" = "unchanged" ]; then
                log "$domain: A记录同步成功"
                echo "$ip4" > "$cache"
                result_ip="$ip4"
                msgs="${msgs}A:${ip4} ✓; "
                any_ok=1
                if [ "$result" = "changed" ] || { [ -n "$cached" ] && [ "$cached" != "$ip4" ]; }; then
                    refresh_dns=1
                fi
            else
                log "$domain: A记录同步失败"
                msgs="${msgs}A记录失败; "
                any_fail=1
            fi
        elif [ -n "$ip4" ]; then
            log "$domain: IPv4地址一致($ip4)"
            result_ip="$ip4"
            msgs="${msgs}A:${ip4} (未变); "
            any_ok=1
        fi
    fi

    # ====== IPv6 处理 ======
    if [ "$ip_version" = "ipv6" ] || [ "$ip_version" = "dual" ]; then
        local ip6=""
        case "$ip_source" in url) ip6=$(get_ip6_url "$ip_url6");; *) ip6=$(get_ip6_iface "$iface6");; esac

        if [ -z "$ip6" ]; then
            log "$domain: 获取IPv6失败"
            msgs="${msgs}IPv6获取失败; "
            # 双栈模式下 IPv6 获取失败不算整体失败
            [ "$ip_version" = "ipv6" ] && any_fail=1
        else
            record_ip_history "$domain" "ipv6" "$ip6" || log "$domain: IPv6历史记录写入失败"
        fi

        if [ -n "$ip6" ] && { [ "$force" = "1" ] || [ "$ip6" != "$cached6" ]; }; then
            log "$domain: IPv6 ${cached6:-无} -> $ip6"
            local result=$(cf_update "$zone_id" "$token" "$domain" "$ip6" "AAAA")
            if [ "$result" = "changed" ] || [ "$result" = "unchanged" ]; then
                log "$domain: AAAA记录同步成功"
                echo "$ip6" > "$cache6"
                result_ip6="$ip6"
                msgs="${msgs}AAAA:${ip6} ✓; "
                any_ok=1
                if [ "$result" = "changed" ] || { [ -n "$cached6" ] && [ "$cached6" != "$ip6" ]; }; then
                    refresh_dns=1
                fi
            else
                log "$domain: AAAA记录同步失败"
                msgs="${msgs}AAAA记录失败; "
                any_fail=1
            fi
        elif [ -n "$ip6" ]; then
            log "$domain: IPv6地址一致($ip6)"
            result_ip6="$ip6"
            msgs="${msgs}AAAA:${ip6} (未变); "
            any_ok=1
        fi
    fi

    # ====== 更新状态 ======
    local status="error"
    if [ "$any_ok" = "1" ] && [ "$any_fail" = "0" ]; then
        status="ok"
    elif [ "$any_ok" = "1" ] && [ "$any_fail" = "1" ]; then
        status="partial"
    fi
    write_state "$domain" "$status" "$msgs" "$result_ip" "$result_ip6" "$(date '+%Y-%m-%d %H:%M:%S')" "$next_time"
    [ "$refresh_dns" = "1" ] && refresh_local_dns_caches "$domain" || true
}

main() {
    local gen=$(uci -q get minigate.global.enabled)
    if [ "$gen" != "1" ]; then
        log "全局未启用，跳过 DDNS"
        return 0
    fi

    local force=0; [ "$1" = "force" ] && force=1
    if [ "$force" = "1" ]; then
        lock_ddns wait
    elif ! lock_ddns; then
        log "上一轮同步仍在运行，跳过本次定时检查"
        return 0
    fi
    # 与 LuCI 手动同步使用相同的节名，两条路径共享同一份 IP 缓存
    local sections=$(uci -q -X show minigate | grep '=ddns$' | cut -d. -f2 | cut -d= -f1)
    local due="" sec
    for sec in $sections; do
        [ "$(uci -q get minigate.${sec}.enabled)" = "1" ] || continue
        if [ "$force" = "1" ] || ddns_due "$sec"; then due="$due $sec"; fi
    done
    # 定时检查没有到期记录时静默退出，不写日志、不提交配置
    [ -n "$sections" ] && [ -z "$due" ] && return 0
    log "--- 开始同步 ---"
    local c=0
    for sec in $due; do update_one "$sec" "$force"; c=$((c + 1)); done
    [ "$c" = "0" ] && log "无 DDNS 记录"
    log "--- 同步完成 ($c 条) ---"
    trim_log
}

if [ "${MINIGATE_DDNS_LIBRARY_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# 手动单条同步
if [ "$1" = "single" ] && [ -n "$2" ]; then
    lock_ddns wait
    log "手动同步: $2"
    update_one "$2" "1"
    trim_log
    exit 0
fi

if [ "$1" = "mark-stopped" ]; then
    mark_stopped
    exit 0
fi

main "$@"
