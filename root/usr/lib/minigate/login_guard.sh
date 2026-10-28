#!/bin/sh
# MiniGate · 登录防护（Login Guard）
# 监控 SSH (dropbear) 和 LuCI 网页登录失败，达到阈值自动封禁源 IP（IPv4 / IPv6）
#
# 用法：
#   login_guard.sh run                后台监控（由 procd 启动）
#   login_guard.sh list               列出当前已封禁的 IP
#   login_guard.sh status             状态总览
#   login_guard.sh ban <IP>           手动封禁
#   login_guard.sh unban <IP>         解封
#   login_guard.sh flush              清空所有封禁
#   login_guard.sh log                最近日志

# === 从 uci 读配置 ===
ENABLED=$(uci -q get minigate.login_guard.enabled || echo "0")
THRESHOLD=$(uci -q get minigate.login_guard.threshold || echo "3")
BANTIME=$(uci -q get minigate.login_guard.bantime || echo "43200")
WINDOW=$(uci -q get minigate.login_guard.window || echo "600")
case "$THRESHOLD" in ''|*[!0-9]*|0) THRESHOLD=3 ;; esac
case "$BANTIME" in ''|*[!0-9]*|0) BANTIME=43200 ;; esac
case "$WINDOW" in ''|*[!0-9]*|0) WINDOW=600 ;; esac

DATA_DIR="${MINIGATE_LG_DATA_DIR:-/etc/minigate/login-guard}"
RUN_DIR="${MINIGATE_LG_RUN_DIR:-/var/run/minigate/login-guard}"
BANS_FILE="$DATA_DIR/bans.txt"
COUNTER_DIR="$RUN_DIR/counters"
LOG_FILE="${MINIGATE_LG_LOG:-/var/log/minigate-login-guard.log}"
ACCESS_LOG="${MINIGATE_ACCESS_LOG:-/var/log/minigate-access.log}"
SET4="login_banned_v4"
SET6="login_banned_v6"
TABLE="inet fw4"
WATCHDOG_INTERVAL="${MINIGATE_LG_WATCHDOG:-30}"
LAN6_NETS=""

mkdir -p "$DATA_DIR" "$COUNTER_DIR"
touch "$BANS_FILE"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG_FILE"
    logger -t minigate-lg "$*"
}

fmt_duration() {
    local s=$1
    if [ "$s" -ge 86400 ] && [ $((s % 86400)) -eq 0 ]; then
        printf "%d天" $((s / 86400))
    elif [ "$s" -ge 3600 ]; then
        if [ $((s % 3600)) -eq 0 ]; then
            printf "%d小时" $((s / 3600))
        else
            printf "%d小时%d分" $((s / 3600)) $(((s % 3600) / 60))
        fi
    elif [ "$s" -ge 60 ]; then
        printf "%d分%d秒" $((s / 60)) $((s % 60))
    else
        printf "%d秒" "$s"
    fi
}

# 输出 4 / 6，无效地址输出空。IPv6 只接受纯十六进制写法，地址会原样进入 nft 命令。
ip_family() {
    case "$1" in
        *[!0-9.]*) ;;
        *.*.*.*)
            printf '%s\n' "$1" | awk -F. 'NF == 4 { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1; ok = 1 } END { exit !ok }' && echo 4
            return 0
            ;;
    esac
    case "$1" in
        *:*:*)
            case "$1" in *[!0-9a-fA-F:]*) return 0 ;; esac
            [ "${#1}" -le 39 ] && echo 6
            ;;
    esac
    return 0
}

set_for_ip() {
    case "$(ip_family "$1")" in
        4) echo "$SET4" ;;
        6) echo "$SET6" ;;
    esac
}

# 判断 IP 是否属于 CIDR（IPv4 任意前缀；IPv6 展开后逐位比较）
cidr_match() {
    awk -v ip="$1" -v net="$2" '
        function v4(a,   p, n, i, v) {
            n = split(a, p, ".")
            if (n != 4) return -1
            v = 0
            for (i = 1; i <= 4; i++) {
                if (p[i] !~ /^[0-9]+$/ || p[i] + 0 > 255) return -1
                v = v * 256 + p[i]
            }
            return v
        }
        function pad(g) { while (length(g) < 4) g = "0" g; return g }
        function v6(a,   halves, left, right, l, r, i, out, missing, g) {
            a = tolower(a)
            if (a !~ /^[0-9a-f:]+$/) return ""
            if (split(a, halves, "::") > 2) return ""
            l = (halves[1] == "") ? 0 : split(halves[1], left, ":")
            r = (index(a, "::") && halves[2] != "") ? split(halves[2], right, ":") : 0
            if (!index(a, "::") && l != 8) return ""
            missing = 8 - l - r
            if (missing < 0) return ""
            out = ""
            for (i = 1; i <= l; i++) { if (length(left[i]) > 4 || left[i] == "") return ""; out = out pad(left[i]) }
            for (i = 0; i < missing; i++) out = out "0000"
            for (i = 1; i <= r; i++) { if (length(right[i]) > 4 || right[i] == "") return ""; out = out pad(right[i]) }
            return out
        }
        function hexval(c) { return index("0123456789abcdef", c) - 1 }
        BEGIN {
            addr = net; bits = -1
            if (index(net, "/")) { addr = substr(net, 1, index(net, "/") - 1); bits = substr(net, index(net, "/") + 1) }
            if (bits != -1 && bits !~ /^[0-9]+$/) exit 1
            bits = bits + 0
            if (index(ip, ":")) {
                a = v6(ip); b = v6(addr)
                if (a == "" || b == "") exit 1
                if (bits == -1) bits = 128
                if (bits > 128) exit 1
                full = int(bits / 4)
                if (substr(a, 1, full) != substr(b, 1, full)) exit 1
                rest = bits - full * 4
                if (rest == 0) exit 0
                d = 2 ^ (4 - rest)
                exit !(int(hexval(substr(a, full + 1, 1)) / d) == int(hexval(substr(b, full + 1, 1)) / d))
            }
            a = v4(ip); b = v4(addr)
            if (a < 0 || b < 0) exit 1
            if (bits == -1) bits = 32
            if (bits > 32) exit 1
            d = 2 ^ (32 - bits)
            exit !(int(a / d) == int(b / d))
        }'
}

# LAN 接口实际分配到的全球 IPv6 子网也属于内网
load_lan6_nets() {
    local status address mask i=0 nets=""
    status=$(ubus call network.interface.lan status 2>/dev/null)
    if [ -n "$status" ]; then
        while [ "$i" -lt 32 ]; do
            address=$(printf '%s' "$status" | jsonfilter -e "@[\"ipv6-prefix-assignment\"][${i}].address" 2>/dev/null)
            mask=$(printf '%s' "$status" | jsonfilter -e "@[\"ipv6-prefix-assignment\"][${i}].mask" 2>/dev/null)
            [ -n "$address" ] || break
            i=$((i + 1))
            case "$mask" in ''|*[!0-9]*) continue ;; esac
            [ "$mask" -ge 48 ] && [ "$mask" -le 128 ] || continue
            nets="$nets ${address}/${mask}"
        done
    fi
    LAN6_NETS="$nets"
}

# === 白名单：默认私有段 + LAN 的 IPv6 子网 + uci list whitelist ===
is_whitelisted() {
    local ip="$1" net
    case "$ip" in
        192.168.*|10.*|127.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;;
        ::1|[fF][cCdD]*:*|[fF][eE][89aAbB]*:*) return 0 ;;
    esac
    for net in $LAN6_NETS $(uci -q get minigate.login_guard.whitelist 2>/dev/null); do
        cidr_match "$ip" "$net" && return 0
    done
    return 1
}

nft_set_spec() {
    case "$1" in
        "$SET6") echo '{ type ipv6_addr; flags timeout; }' ;;
        *) echo '{ type ipv4_addr; flags timeout; }' ;;
    esac
}

nft_rule_match() {
    case "$1" in
        "$SET6") echo "ip6 saddr" ;;
        *) echo "ip saddr" ;;
    esac
}

# === 确保 nft set + drop rule 存在 ===
# 规则和集合随包放在 /usr/share/nftables.d，防火墙每次重载都会带上；这里兜底处理
# 安装后防火墙尚未重载的情况。返回 0 表示刚重建过，调用方需要从持久化文件恢复封禁。
ensure_nft() {
    local recreated=0 set chain
    for set in "$SET4" "$SET6"; do
        if ! nft list set $TABLE $set >/dev/null 2>&1; then
            nft "add set $TABLE $set $(nft_set_spec "$set")" 2>/dev/null
            recreated=1
        fi
    done
    chain=$(nft list chain $TABLE input 2>/dev/null)
    for set in "$SET4" "$SET6"; do
        if ! printf '%s\n' "$chain" | grep -q "@$set"; then
            nft "insert rule $TABLE input $(nft_rule_match "$set") @$set counter drop comment \"minigate-login-guard\"" 2>/dev/null
            recreated=1
        fi
    done
    [ $recreated -eq 1 ] || return 1
    log "已创建 nft set + drop 规则"
    return 0
}

# 防火墙重载后，随包的集合会重新出现但内容为空；持久化文件里仍有未过期封禁时恢复
sets_lost_bans() {
    local now set
    now=$(date +%s)
    for set in "$SET4" "$SET6"; do
        nft list set $TABLE $set 2>/dev/null | grep -q 'elements' && continue
        while read -r ip exp; do
            [ -n "$ip" ] || continue
            case "$exp" in ''|*[!0-9]*) continue ;; esac
            [ "$exp" -gt "$now" ] || continue
            [ "$(set_for_ip "$ip")" = "$set" ] && return 0
        done < "$BANS_FILE"
    done
    return 1
}

add_ban_element() {
    local ip="$1" seconds="$2" set
    set=$(set_for_ip "$ip")
    [ -n "$set" ] || return 1
    nft add element $TABLE $set "{ $ip timeout ${seconds}s }" 2>/dev/null
}

persist_ban() {
    local ip="$1" exp="$2"
    grep -v "^$ip " "$BANS_FILE" > "${BANS_FILE}.tmp" 2>/dev/null || true
    echo "$ip $exp" >> "${BANS_FILE}.tmp"
    mv "${BANS_FILE}.tmp" "$BANS_FILE"
}

# === 把 IP 加入封禁集合 + 持久化 ===
ban_ip() {
    local ip="$1"
    local exp=$(($(date +%s) + BANTIME))
    if ! add_ban_element "$ip" "$BANTIME"; then
        log "封禁 $ip 失败：防火墙未接受该地址"
        return 1
    fi
    persist_ban "$ip" "$exp"
    log "BAN $ip $(fmt_duration "$BANTIME")（达到 $THRESHOLD 次失败）"
    rm -f "$COUNTER_DIR/$ip"
}

# === 启动时从持久化文件恢复封禁 ===
restore_bans() {
    [ -f "$BANS_FILE" ] || return 0
    local now=$(date +%s)
    local tmp="${BANS_FILE}.tmp"
    > "$tmp"
    local count=0
    while read -r ip exp; do
        [ -z "$ip" ] && continue
        case "$exp" in ''|*[!0-9]*) continue ;; esac
        if [ "$exp" -gt "$now" ] && [ -n "$(set_for_ip "$ip")" ]; then
            add_ban_element "$ip" $((exp - now))
            echo "$ip $exp" >> "$tmp"
            count=$((count + 1))
        fi
    done < "$BANS_FILE"
    mv "$tmp" "$BANS_FILE"
    [ $count -gt 0 ] && log "从持久化文件恢复 $count 条封禁"
}

# === 处理一条登录失败 ===
handle_failure() {
    local ip="$1"
    [ -z "$ip" ] && return
    [ -n "$(ip_family "$ip")" ] || return
    is_whitelisted "$ip" && return

    # 滑动窗口：超过 window 秒的旧失败丢弃
    local f="$COUNTER_DIR/$ip"
    local now=$(date +%s)
    local first=0
    local count=0
    if [ -f "$f" ]; then
        read -r first count < "$f"
        if [ -n "$first" ] && [ $((now - first)) -gt "$WINDOW" ]; then
            first=$now
            count=0
        fi
    else
        first=$now
    fi
    count=$((count + 1))
    echo "$first $count" > "$f"
    log "FAIL $ip ($count/$THRESHOLD)"

    if [ "$count" -ge "$THRESHOLD" ]; then
        # 加 ban 前再确认 nft 还在（fw4 可能重载）
        repair_nft
        ban_ip "$ip"
    fi
}

# 取日志行里最后一个 " from " 后的地址：用户名由访客提供，可能伪造前面的 from。
# dropbear 以 "地址:端口" 记录（IPv6 不加方括号），LuCI 只记录地址。
extract_ip() {
    local line="$1" with_port="$2" addr
    addr=${line##* from }
    addr=${addr%% *}
    case "$addr" in
        \[*\]:*) addr=${addr#\[}; addr=${addr%%\]*} ;;
        *)
            [ "$with_port" = "1" ] && case "$addr" in *:[0-9]*) addr=${addr%:*} ;; esac
            ;;
    esac
    [ -n "$(ip_family "$addr")" ] && echo "$addr"
}

extract_json_field() {
    local key="$1"
    sed -n "s/.*\"${key}\":\"\([^\"]*\)\".*/\1/p" | head -1
}

is_luci_failed_post() {
    local line="$1"
    echo "$line" | grep -q '"method":"POST"' || return 1
    echo "$line" | grep -q '"status":403' || return 1
    echo "$line" | grep -Eq '"uri":"/cgi-bin/luci(/|")' || return 1
    return 0
}

access_log_loop() {
    touch "$ACCESS_LOG" 2>/dev/null
    tail -n 0 -f "$ACCESS_LOG" 2>/dev/null | while read -r line; do
        is_luci_failed_post "$line" || continue
        ip=$(echo "$line" | extract_json_field client)
        handle_failure "$ip"
    done
}

syslog_loop() {
    logread -f 2>/dev/null | while read -r line; do
        case "$line" in
            *"Bad password attempt"*"from"*|\
            *"Login attempt for nonexistent user"*"from"*)
                handle_failure "$(extract_ip "$line" 1)"
                ;;
            *"luci: failed login"*"from"*)
                handle_failure "$(extract_ip "$line" 0)"
                ;;
        esac
    done
}

repair_nft() {
    if ensure_nft || sets_lost_bans; then
        restore_bans
    fi
    return 0
}

# 日志在内存 /var/log 中，长期遭遇爆破时需要限制大小
trim_log() {
    [ -f "$LOG_FILE" ] || return 0
    [ "$(wc -c < "$LOG_FILE")" -gt 262144 ] || return 0
    tail -n 500 "$LOG_FILE" > "${LOG_FILE}.tmp" && mv -f "${LOG_FILE}.tmp" "$LOG_FILE"
}

# === 后台 watchdog：防火墙重载后尽快恢复封禁 ===
watchdog_loop() {
    local tick=0
    while true; do
        sleep "$WATCHDOG_INTERVAL"
        repair_nft
        tick=$((tick + 1))
        if [ $((tick % 10)) -eq 0 ]; then
            load_lan6_nets
            trim_log
        fi
    done
}

stop_process_tree() {
    local child
    for child in $(pgrep -P "$1" 2>/dev/null); do
        stop_process_tree "$child"
    done
    kill "$1" 2>/dev/null
}

# procd 停止时只向本进程发 TERM；logread -f / tail -f 忽略 SIGPIPE 不会自行退出，需逐个结束。
# 停止后不再拦截（与旧版移除规则一致），持久化文件保留，下次启动恢复。
stop_watcher() {
    local child
    trap - TERM INT
    for child in $(pgrep -P $$ 2>/dev/null); do
        stop_process_tree "$child"
    done
    nft flush set $TABLE $SET4 2>/dev/null
    nft flush set $TABLE $SET6 2>/dev/null
    log "登录防护已停止"
    exit 0
}

# === 主监控循环 ===
run_watcher() {
    [ "$ENABLED" = "1" ] || {
        log "未启用（minigate.login_guard.enabled=0），退出"
        exit 0
    }

    load_lan6_nets
    ensure_nft
    restore_bans
    log "登录防护启动 阈值=$THRESHOLD 窗口=${WINDOW}s 封禁=$(fmt_duration "$BANTIME")"

    trap stop_watcher TERM INT
    watchdog_loop &
    # MiniGate 反代访问 LuCI 时，LuCI 日志只会看到反代内网 IP。
    # 这里补充监听 nginx access log，用 JSON client 字段记录真实公网 IP。
    access_log_loop &
    syslog_loop &
    # 在 wait 中才能及时响应 TERM；任一循环全部退出后进程结束，由 procd 重新拉起
    wait
}

# === CLI 命令 ===

# 用 nft -j 拿封禁列表，输出每行: <IP> <剩余秒数>
# 注意 nft -j 输出可能有空格、字段顺序也不固定（有的 elem 多个 timeout 字段）
parse_set_json() {
    local set
    for set in "$SET4" "$SET6"; do
        nft -j list set $TABLE $set 2>/dev/null | awk '
        {
            # 在每条 elem 块（{...}）内匹配 val + expires；[^{}]* 限制不跨越 brace 边界
            while (match($0, /"val":[ ]*"[0-9a-fA-F:.]+"[^{}]*"expires":[ ]*[0-9]+/)) {
                block = substr($0, RSTART, RLENGTH)
                $0 = substr($0, RSTART + RLENGTH)
                if (match(block, /"val":[ ]*"[0-9a-fA-F:.]+"/)) {
                    ip = substr(block, RSTART, RLENGTH)
                    sub(/^"val":[ ]*"/, "", ip); sub(/"$/, "", ip)
                }
                if (match(block, /"expires":[ ]*[0-9]+/)) {
                    exp_str = substr(block, RSTART, RLENGTH)
                    gsub(/[^0-9]/, "", exp_str)
                    print ip, exp_str
                }
            }
        }'
    done
}

cmd_list() {
    echo "=== 当前已封禁 IP ==="
    local out
    out=$(parse_set_json)
    if [ -z "$out" ]; then
        echo "（暂无）"
        return
    fi
    echo "$out" | while read -r ip secs; do
        printf "  %-40s 剩余 %s\n" "$ip" "$(fmt_duration "$secs")"
    done
}

cmd_status() {
    local banned watching
    banned=$(parse_set_json | wc -l)
    watching=$(ls "$COUNTER_DIR" 2>/dev/null | wc -l)
    echo "已封禁 IP 数: $banned"
    echo "失败计数中的 IP: $watching"
    if [ "$banned" -gt 0 ]; then
        echo "--- 已封禁 ---"
        cmd_list | tail -n +2
    fi
    if [ "$watching" -gt 0 ]; then
        echo "--- 失败计数详情 ---"
        for f in "$COUNTER_DIR"/*; do
            [ -f "$f" ] || continue
            local ip count first now age
            ip=$(basename "$f")
            read -r first count < "$f"
            now=$(date +%s)
            age=$((now - first))
            printf "  %-40s %d/%d (距首次失败 %ds)\n" "$ip" "$count" "$THRESHOLD" "$age"
        done
    fi
}

cmd_unban() {
    local ip="$1" set
    set=$(set_for_ip "$ip")
    [ -n "$set" ] || { echo "用法: $0 unban <IP>"; exit 1; }
    nft delete element $TABLE $set "{ $ip }" 2>&1
    grep -v "^$ip " "$BANS_FILE" > "${BANS_FILE}.tmp" 2>/dev/null || true
    mv "${BANS_FILE}.tmp" "$BANS_FILE"
    rm -f "$COUNTER_DIR/$ip"
    echo "✓ 已解封 $ip"
    log "MANUAL unban $ip"
}

cmd_ban() {
    local ip="$1"
    [ -n "$(ip_family "$ip")" ] || { echo "用法: $0 ban <IP>"; exit 1; }
    ensure_nft
    if ! add_ban_element "$ip" "$BANTIME"; then
        echo "✗ 封禁 $ip 失败"
        exit 1
    fi
    persist_ban "$ip" $(($(date +%s) + BANTIME))
    echo "✓ 已封禁 $ip"
    log "MANUAL ban $ip"
}

cmd_flush() {
    nft flush set $TABLE $SET4 2>&1 || true
    nft flush set $TABLE $SET6 2>&1 || true
    > "$BANS_FILE"
    rm -rf "$COUNTER_DIR"/*
    echo "✓ 已清空所有封禁"
    log "MANUAL flush all bans"
}

cmd_log() {
    local n="${1:-30}"
    if [ -f "$LOG_FILE" ]; then
        tail -n "$n" "$LOG_FILE"
    else
        logread -e minigate-lg | tail -n "$n"
    fi
}

if [ "${MINIGATE_LG_LIBRARY_ONLY:-0}" = "1" ]; then
    return 0 2>/dev/null || exit 0
fi

# === 入口 ===
case "${1:-help}" in
    run)        run_watcher ;;
    list|ls)    cmd_list ;;
    status)     cmd_status ;;
    ban)        cmd_ban "$2" ;;
    unban)      cmd_unban "$2" ;;
    flush)      cmd_flush ;;
    log|logs)   cmd_log "$2" ;;
    *)
        cat <<EOH
MiniGate 登录防护

  $0 run               后台监控（procd 启动）
  $0 list              列出已封禁 IP
  $0 status            状态总览
  $0 ban <IP>          手动封禁
  $0 unban <IP>        解封
  $0 flush             清空所有封禁
  $0 log [N]           最近 N 条日志（默认 30）
EOH
        ;;
esac
