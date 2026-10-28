#!/bin/sh
# 用随包的离线地址库查询省级归属地，命中时输出地区名；未命中输出空。
GEO_DIR="${MINIGATE_GEO_DIR:-/usr/lib/minigate/geo}"
ip="$1"

case "$ip" in
    ''|*[!0-9a-fA-F:.]*) exit 1 ;;
esac

code=$(awk -v ip="$ip" '
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
    function v6(a,   halves, left, right, l, r, i, out, missing) {
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
        family = index(ip, ":") ? 6 : 4
        if (family == 4) { want4 = v4(ip); if (want4 < 0) exit }
        else { want6 = v6(ip); if (want6 == "") exit }
    }
    /^[0-9a-fA-F.:]+\/[0-9]+ 1;$/ {
        net = $1; sub(/ .*/, "", net)
        addr = net; sub(/\/.*/, "", addr)
        bits = net; sub(/^[^\/]*\//, "", bits); bits = bits + 0
        if (family == 4) {
            if (index(addr, ":")) next
            d = 2 ^ (32 - bits)
            if (int(want4 / d) == int(v4(addr) / d)) { found = FILENAME; exit }
        } else {
            if (!index(addr, ":")) next
            b = v6(addr)
            full = int(bits / 4)
            if (substr(want6, 1, full) != substr(b, 1, full)) next
            rest = bits - full * 4
            if (rest == 0) { found = FILENAME; exit }
            d = 2 ^ (4 - rest)
            if (int(hexval(substr(want6, full + 1, 1)) / d) == int(hexval(substr(b, full + 1, 1)) / d)) { found = FILENAME; exit }
        }
    }
    END {
        if (found != "") { sub(/^.*\//, "", found); sub(/\.conf$/, "", found); print found }
    }
' "$GEO_DIR"/[0-9]*.conf 2>/dev/null)

[ -n "$code" ] || exit 0
awk -v code="$code" '$1 == code { $1 = ""; sub(/^ /, ""); print; exit }' "$GEO_DIR/regions.txt"
