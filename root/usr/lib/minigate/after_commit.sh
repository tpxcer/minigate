#!/bin/sh
# LuCI 的 on_after_commit 在浏览器提交配置之前执行。这里先记录当前配置摘要，
# 后台等配置文件变化（最多 WAIT 秒）后再应用，避免后台脚本读到旧配置。
CONFIG="${MINIGATE_CONFIG_FILE:-/etc/config/minigate}"
WAIT="${MINIGATE_COMMIT_WAIT:-15}"
INIT="${MINIGATE_INIT:-/etc/init.d/minigate}"
LIB_DIR="${MINIGATE_LIB_DIR:-/usr/lib/minigate}"

config_digest() {
    md5sum "$CONFIG" 2>/dev/null | cut -d' ' -f1
}

case "$1" in
    restart|stop|reload|ddns|proxy) ;;
    *)
        echo "用法: $0 {restart|stop|reload|ddns|proxy}" >&2
        exit 2
        ;;
esac

before=$(config_digest)
(
    i=0
    while [ "$i" -lt "$WAIT" ] && [ "$(config_digest)" = "$before" ]; do
        sleep 1
        i=$((i + 1))
    done
    case "$1" in
        restart|stop|reload) exec "$INIT" "$1" ;;
        ddns) exec /bin/sh "$LIB_DIR/ddns.sh" force ;;
        proxy) exec /bin/sh "$LIB_DIR/proxy.sh" reload ;;
    esac
) </dev/null >/dev/null 2>&1 &
