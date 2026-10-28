#!/bin/sh
# 后台执行耗时操作（签发证书、手动同步 DDNS），LuCI 轮询状态文件，不再卡住网页请求。
# 用法: job.sh <任务名> <命令...>
JOB_DIR="${MINIGATE_JOB_DIR:-/var/run/minigate/jobs}"

name="$1"
shift
case "$name" in ''|*[!A-Za-z0-9_-]*) echo "无效任务名" >&2; exit 2 ;; esac
[ "$#" -gt 0 ] || { echo "用法: $0 <任务名> <命令...>" >&2; exit 2; }

mkdir -p "$JOB_DIR" || exit 1
file="${JOB_DIR}/${name}.state"

write_job() {
    printf 'status=%s\nstarted=%s\nfinished=%s\ncode=%s\n' "$1" "$2" "$3" "$4" > "${file}.$$" &&
        mv -f "${file}.$$" "$file"
}

started=$(date +%s)
write_job running "$started" "" ""
"$@" </dev/null >/dev/null 2>&1
code=$?
write_job done "$started" "$(date +%s)" "$code"
exit "$code"
