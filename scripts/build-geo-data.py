#!/usr/bin/env python3
"""从固定 ip2region 快照生成 Nginx 省级白名单（仅开发/维护时运行）。"""
import argparse
import hashlib
import ipaddress
import json
from pathlib import Path

REVISION = "f8b0792b0cd729f5b2593f690aeed225e49c1967"
SOURCE_SHA256 = {'ipv4_source.txt': 'b845e5682b4d27a6733e811639f2db7f79912c30a351abd4e646fbfedaf58d1a', 'ipv6_source.txt': '4d9df9b89141f069845ae8ce3f375534323a7c068e0d88138eae06244d7192d2'}
REGIONS = {
    "110000": "北京市", "120000": "天津市", "130000": "河北省", "140000": "山西省",
    "150000": "内蒙古", "210000": "辽宁省", "220000": "吉林省", "230000": "黑龙江省",
    "310000": "上海市", "320000": "江苏省", "330000": "浙江省", "340000": "安徽省",
    "350000": "福建省", "360000": "江西省", "370000": "山东省", "410000": "河南省",
    "420000": "湖北省", "430000": "湖南省", "440000": "广东省", "450000": "广西",
    "460000": "海南省", "500000": "重庆市", "510000": "四川省", "520000": "贵州省",
    "530000": "云南省", "540000": "西藏", "610000": "陕西省", "620000": "甘肃省",
    "630000": "青海省", "640000": "宁夏", "650000": "新疆", "710000": "台湾省",
    "810000": "香港特别行政区", "820000": "澳门特别行政区",
}


def generate(source_dir, output_dir):
    by_name = {name: code for code, name in REGIONS.items()}
    ranges = {code: {4: [], 6: []} for code in REGIONS}
    hashes = {}
    for version in (4, 6):
        source = source_dir / f"ipv{version}_source.txt"
        hashes[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
        if hashes[source.name] != SOURCE_SHA256[source.name]:
            raise ValueError(f"{source.name} 与固定来源版本不一致")
        with source.open(encoding="utf-8") as stream:
            for line in stream:
                fields = line.rstrip("\n").split("|")
                if len(fields) != 7 or fields[2] != "中国" or fields[6] != "CN":
                    continue
                code = by_name.get(fields[3])
                if code is None:
                    continue  # 未识别的省级字段不得推断或扩大放行
                first, last = map(ipaddress.ip_address, fields[:2])
                if first.version != version or last.version != version:
                    raise ValueError("地址族与源文件不一致")
                ranges[code][version].extend(ipaddress.summarize_address_range(first, last))
    output_dir.mkdir(parents=True, exist_ok=True)
    counts = {}
    for code, families in ranges.items():
        lines = [f"# ip2region {REVISION}: {REGIONS[code]}"]
        counts[code] = {}
        for version, networks in families.items():
            networks = list(ipaddress.collapse_addresses(networks))
            if not networks:
                raise ValueError(f"{code} 缺失 IPv{version} 数据")
            counts[code][str(version)] = len(networks)
            lines.extend(f"{network} 1;" for network in networks)
        (output_dir / f"{code}.conf").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (output_dir / "regions.txt").write_text("".join(f"{code} {name}\n" for code, name in REGIONS.items()), encoding="utf-8")
    (output_dir / "metadata.json").write_text(json.dumps({
        "source": "https://github.com/lionsoul2014/ip2region", "revision": REVISION,
        "source_sha256": hashes, "networks": counts,
    }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"regions": len(counts), "networks": sum(sum(v.values()) for v in counts.values()),
                      "sichuan": counts["510000"]}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source_dir", type=Path)
    parser.add_argument("--output", type=Path, default=Path(__file__).resolve().parents[1] / "root/usr/lib/minigate/geo")
    args = parser.parse_args()
    generate(args.source_dir, args.output)
