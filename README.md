# MiniGate - OpenWrt 轻量网关管理

一个类似 Lucky 的轻量级 OpenWrt 应用，提供四大核心功能：DDNS、SSL 证书、反向代理、登录防护。

当前版本：**v2026.10.28-2**。界面名称为 **MiniGate**，仓库名及 OpenWrt 内部包名均为 **`minigate`**。

> OpenWrt 用户请从 [Releases](https://github.com/tpxcer/minigate/releases/latest) 下载 `minigate_2026.10.28-2_all.ipk`。不要把 GitHub 自动生成的 `Source code (zip)` / `Source code (tar.gz)` 当安装包上传到 LuCI。

## 项目定位

MiniGate 面向需要自托管轻量网关能力的 OpenWrt / ImmortalWrt 用户，目标是在 LuCI 中集中完成域名解析、证书签发、反向代理和登录防护配置，减少在路由器上手动维护多组脚本、Nginx 配置和防火墙规则的成本。

项目重点关注以下场景：

- 家庭或小型办公网络中的自托管服务入口管理
- IPv4 / IPv6 双栈 DDNS 与反向代理配置
- Cloudflare DNS-01 自动签发和续期证书
- 直接 IP 访问、未知 Host、暴力登录尝试等常见暴露面防护
- OpenWrt / ImmortalWrt opkg、apk、源码安装和 SDK 编译兼容

## 维护状态

- 维护者：[@tpxcer](https://github.com/tpxcer)
- 当前维护分支：`main`
- 发布方式：GitHub Releases 提供源码包和 OpenWrt/ImmortalWrt 兼容安装包
- 版本规则：按北京时间（Asia/Shanghai）发布日期使用 `年.月.日`；同日首版无后缀，后续版本依次追加 `-1`、`-2`，例如 `2026.9.14`、`2026.9.14-1`。标签加 `v` 前缀。
- 安全策略：见 [SECURITY.md](SECURITY.md)
- 贡献说明：见 [CONTRIBUTING.md](CONTRIBUTING.md)
- 许可证：MIT License

## 功能特性

### 🌐 DDNS (动态域名解析)
- **Cloudflare** DNS API 支持
- **IPv4 / IPv6 / 双栈** 模式，同时更新 A 和 AAAA 记录
- 自动检测 WAN IP 变化并更新 DNS 记录
- 公网记录变化成功后无重启刷新 sing-box 与 dnsmasq DNS 缓存，减少局域网继续命中旧地址
- 同名同类型记录重复时，保留匹配当前 IP 的记录并清理其余旧记录，避免旧 IP 继续参与解析
- 支持从网络接口或外部 URL 获取 IP；外部查询默认用 HTTPS，失败时依次回退
- 只向 Cloudflare 推送公网地址：软路由在上级路由 NAT 之后时，网卡上的 192.168.x 等内网地址会被拒绝并提示改用外部 URL
- 运行状态保存在 `/var/run/minigate`，定时检查不再改写 `/etc/config/minigate`
- 每条记录可配置检查间隔（最小 5 分钟，按 5 分钟取整）
- 一键手动触发更新，在后台执行并原地刷新状态，不会丢掉表单里未保存的修改
- 最近一天 IP 变化明细，显示 IPv4/IPv6 地址、开始时间、结束时间和持续时长

### 🔒 SSL/TLS 证书 (ACME)
- **Let's Encrypt** 自动证书签发
- 使用 **DNS-01** 挑战方式（Cloudflare）
- 支持 ECC / RSA 多种密钥类型
- 自动续期（通过 cron 每天检查）；剩余超过 30 天时手动签发不会重复申请，避免触发频率限制
- 证书列表显示到期日期、剩余天数，并区分测试证书和正式证书
- acme.sh 固定为 3.1.6 版本，下载后校验 SHA-256 再安装
- 签发在后台执行，页面轮询结果，不受网页请求超时影响
- Staging 模式用于测试

### 🔄 反向代理
- 基于 **Nginx** 的轻量反向代理
- **IPv6 监听**支持（listen [::]:port 双栈）
- HTTP/2；所有站点自动支持 WebSocket，无需逐条开启
- 自动 SSL 证书关联
- 已启用 HTTPS 的任意监听端口可自动识别明文 HTTP，并以 308 跳转到同域名、同端口的 HTTPS
- 安全 Headers（HSTS 等）
- 多站点管理；子域名可单独停用，通配符主域名停用时其子域名一并停用
- 同一端口只能用于一种协议（HTTP 或 HTTPS），冲突的规则会被跳过，并在总览页提示原因
- 配置检查失败时自动恢复上一份可用配置，正在运行的站点不受影响；缺少证书的站点会在总览页提示
- Nginx 由 procd 管理，异常退出后自动拉起
- **直接 IP 访问拒绝**：只允许域名访问，扫描器直接断开
- **未知 Host 拒绝**：同一监听端口下，未配置的域名/前缀不会落到第一个反代站点
- **局域网直连解析**（可选）：内网设备把代理域名直接解析到本机 LAN 地址，公网 IP 变化、上游 DNS 缓存过期或主路由不支持回流时，内网访问不受影响，流量也不进入代理
- **公网访问范围**（可选）：选择允许访问的省级地区，IPv4/IPv6 在首次转发前检查，未命中白名单直接断开；局域网私有地址继续可用

### 🛡 登录防护 (Login Guard)
- 监控 **SSH（dropbear）** 和 **LuCI 网页** 登录失败，支持 **IPv4 和 IPv6** 来源
- 在「失败窗口」内累积达到阈值（默认 3 次/10 分钟）→ 自动用 nftables 封禁源 IP
- 可配置封禁时长（1 小时 / 6 小时 / **12 小时（默认）** / 24 小时 / 1 周 / 30 天）
- **LAN 私有段自动豁免**（192.168.x / 10.x / 127.x / 172.16-31.x、IPv6 ULA / 链路本地，以及 LAN 分配的 IPv6 子网），可加额外白名单（IPv4/IPv6，任意前缀长度）
- **滑动时间窗口**：超过窗口未再失败则计数自动清零
- 持久化存储 `/etc/minigate/login-guard/bans.txt`，重启/固件升级后已生效封禁自动恢复
- LuCI 页面实时显示封禁列表、剩余时间、归属地（结合归属地查询 API）
- 失败计数列表默认显示 5 条，支持切换 5 / 20 / 30 条，并复用访客追踪归属地查询；显示最近访问时间并按最新时间排序
- 支持网页**一键解封**、**手动封禁**、**清空全部**（清空按钮在列表底部，避免误点）
- 封禁集合与拦截规则随包放在 `/usr/share/nftables.d`，防火墙每次重载自动加载；重载清空的封禁 30 秒内从持久化文件恢复
- 由 procd 管理，异常退出后自动拉起；停止时结束所有子进程

### 👁 访客追踪
- 总览页面显示来源 IP、归属地、最近请求结果、HTTP 状态及转发/拦截次数；被拒绝的扫描也保留在记录中
- 「近5分钟有请求」仅表示近期出现请求，不代表访客在线；已转发也不代表已登录。旧日志缺少上游响应信息时，只能标记为已响应、请求失败或结果未知，不推断为准入放行
- IP 归属地优先查随包的离线省级地址库，命中时不把访客 IP 发给外部服务；境外地址再用 HTTPS 接口（ip9.com.cn → pconline）查询，缓存最多保留 500 条

### 软件更新
- 登录 LuCI 后打开 **服务 → MiniGate → 总览**，自动检查 GitHub 最新正式版；不会自动下载或安装
- 10 分钟内复用成功检查结果；「检查更新」可随时手动重新检查
- 点击「一键更新」先显示本次 Release 更新内容，确认后才开始安装
- 安装前校验 SHA-256 并备份程序和配置，安装或服务验证失败时尝试回滚
- 总览页底部「危险操作」区提供「卸载」入口；二次确认默认保留配置、证书、封禁记录和日志，也可主动选择彻底清理

---

## 安装方法

### 方法 1：IPK 安装（推荐，OpenWrt / ImmortalWrt opkg 版本）

从 [Releases](https://github.com/tpxcer/minigate/releases/latest) 下载：

`minigate_2026.10.28-2_all.ipk`

**通过 LuCI 界面安装：**
1. 打开 LuCI → **系统** → **软件包**
2. 点击 **上传软件包**
3. 选择 `minigate_2026.10.28-2_all.ipk`，点击安装

**通过命令行安装：**

```bash
cd /tmp
wget -O minigate_2026.10.28-2_all.ipk https://github.com/tpxcer/minigate/releases/download/v2026.10.28-2/minigate_2026.10.28-2_all.ipk
opkg update
opkg install /tmp/minigate_2026.10.28-2_all.ipk
rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
/etc/init.d/uhttpd restart
/etc/init.d/minigate restart
```

> 如果 LuCI 上传时报 `Malformed package file`，请确认下载的是 Release 里的 `.ipk` 资产，并确认该 `.ipk` 是 OpenWrt 原生 tar.gz 外层格式。ImmortalWrt 24.10.5 的新版 opkg 对格式更严格，Debian 风格 ar 外层 `.ipk` 会被判定为 malformed。

### 维护者打包

Release 用的 `.ipk` 请用仓库脚本生成，避免生成 Debian 风格 ar 外层包：

```bash
./scripts/build-ipk.sh
```

脚本会输出：

```text
dist/minigate_2026.10.28-2_all.ipk
```

该文件外层是 OpenWrt/ImmortalWrt 24.10 兼容的 `tar.gz`，内部成员顺序为 `debian-binary`、`control.tar.gz`、`data.tar.gz`。

### 方法 2：SSH 一键安装（推荐，opkg / apk）

适用于使用 **apk** 或 **opkg** 的 OpenWrt / ImmortalWrt。请先确认 LuCI、Nginx SSL 等下列依赖可用，且软件源与当前固件和架构匹配；不要为了安装混用其他固件的软件源。

**已经通过 SSH 登录软路由后，执行：**

```sh
curl -fsSL https://raw.githubusercontent.com/tpxcer/minigate/main/scripts/install.sh | sh
```

这条短命令会自动获取 GitHub 最新正式版。远程脚本内部仍会创建随机临时目录，在写入系统前检查 OpenWrt 环境、下载前后核对 Release、校验源码包 SHA-256、检查压缩包路径和版本信息，然后调用正式安装器并刷新 LuCI。

如果系统只有 `wget`，可以执行：

```sh
wget -qO- https://raw.githubusercontent.com/tpxcer/minigate/main/scripts/install.sh | sh
```

### 方法 3：固定版本命令安装

需要指定并核对具体版本时，执行：

```bash
d="$(mktemp -d /tmp/minigate.XXXXXX)" && cd "$d" && wget -q https://github.com/tpxcer/minigate/releases/download/v2026.10.28-2/minigate-v2026.10.28-2-src.tar.gz && wget -q https://github.com/tpxcer/minigate/releases/download/v2026.10.28-2/SHA256SUMS && grep 'minigate-v2026.10.28-2-src.tar.gz$' SHA256SUMS | sha256sum -c - && tar xzf minigate-v2026.10.28-2-src.tar.gz && sh install.sh && /etc/init.d/uhttpd restart && /etc/init.d/minigate restart
```

其中 `minigate.XXXXXX` 是临时目录模板，系统会自动把六个 `X` 替换为随机字符，避免与已有目录重名。该命令会校验源码包的 SHA-256、保留现有 minigate 配置并重启 LuCI 与 minigate 服务。

源码安装直接写入程序文件，不向 opkg/apk 注册软件包；希望软件包列表中显示 `minigate`，请使用 IPK 或匹配 SDK 编译的 APK。旧名包用户先阅读下方「旧包名迁移」。

**分步安装：**

```bash
# 1. SSH 到路由器
ssh root@192.168.1.1

# 2. 在路由器上直接下载 Release 源码包
cd /tmp
wget -O minigate-src.tar.gz https://github.com/tpxcer/minigate/releases/download/v2026.10.28-2/minigate-v2026.10.28-2-src.tar.gz
wget -O minigate-SHA256SUMS https://github.com/tpxcer/minigate/releases/download/v2026.10.28-2/SHA256SUMS
awk '$2 == "minigate-v2026.10.28-2-src.tar.gz" {print $1 "  minigate-src.tar.gz"}' minigate-SHA256SUMS | sha256sum -c - || exit 1

# 3. 解压到独立目录并安装
mkdir -p /tmp/minigate-v2026.10.28-2
tar xzf minigate-src.tar.gz -C /tmp/minigate-v2026.10.28-2
cd /tmp/minigate-v2026.10.28-2
sh install.sh

# 4. 启动服务
/etc/init.d/minigate restart

# 5. 访问 LuCI → 服务 → MiniGate
```

### 方法 4：OpenWrt SDK 编译（适用所有版本，含 APK）

如果需要正规的 `.apk` 安装包，需使用 OpenWrt SDK 编译：

```bash
# 将源码放入 SDK 的 package 目录
cp -r minigate ~/openwrt/package/

# 编译
cd ~/openwrt
make package/minigate/compile V=s

# 生成的 ipk 或 apk 在 bin/packages/ 目录下
```

APK 的内部版本格式要求将同日序号 `-N` 写为 `-rN`，SDK 会自动转换；例如发布版 `2026.9.14-1` 对应 APK 版本 `2026.9.14-r1`。网页、Release 标签和 IPK 仍使用 `2026.9.14-1`，包名均为 `minigate`。

---

## 升级方法

### LuCI 一键更新

进入 **服务 → MiniGate → 总览 → 软件更新**：

1. 打开总览时自动检查，也可以点击「检查更新」立即重新检查
2. 有新版本时点击「一键更新」，弹出该版本的更新内容
3. 阅读后点击「确认更新」才开始；取消或关闭弹窗不会安装
4. 页面显示下载、SHA-256 校验、备份、安装和服务验证进度，成功后刷新

更新器只接受 `tpxcer/minigate` 的固定 Release 资产，不接受自定义下载地址。自动检查只在打开 minigate 总览时触发，不会修改全局 LuCI 登录流程。确认后若最新版本已经变化，会停止并要求重新查看更新内容。更新前会备份程序和 `/etc/config/minigate`；安装或服务验证失败时尝试恢复原版本，失败详情见 `/var/log/minigate-update.log`。

`v1.3.11` 已有一键更新，但需先升级本版才具备自动检查和说明弹窗。本版保留旧名源码附件用于兼容它；旧版不能识别 `2026.9.14-1` 这样的后缀版本，应先升级 `v2026.9.14` 或使用本文命令手动安装。更早版本需手动安装。

### 源码升级（通用）

SSH 登录后执行上方「方法 2」的一条命令，保留原有配置并校验下载内容。网页一键更新也采用源码覆盖方式，不会同步修改 opkg/apk 数据库中的包名或版本；包管理器安装的用户建议继续使用对应软件包升级。

### IPK 升级

```bash
opkg install --force-reinstall /tmp/minigate_2026.10.28-2_all.ipk
rm -f /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
/etc/init.d/minigate restart
```

配置文件 `/etc/config/minigate` 会自动保留。

### 旧包名迁移

如果 `opkg list-installed` 或 `apk info` 中仍有 `luci-app-minigate`，它是旧版内部包名，不等于新包 `minigate`。先备份 `/etc/config/minigate` 和 `/etc/minigate/`，并提前下载新安装包和旧版本回退包，再移除旧名包并安装新包。请在 LAN 或 SSH 连接下操作，迁移会短暂中断由 minigate 提供的反向代理。

新 IPK 声明旧包的兼容/替换关系，但不同固件的自动替换行为仍需实机验证；不要使用 `--force-overwrite` 混装，不要在新文件写入后再卸载旧名包，以免旧包把同路径的新文件一并删除。源码安装的用户若没有旧包数据库记录，无需迁移。

---

## 卸载方法

### 方式 1：LuCI 一键卸载（推荐）

进入 **服务 → MiniGate → 总览**，点击页面底部「危险操作」区的「卸载」：

1. 阅读中断提示并确认卸载范围
2. 默认不勾选数据清理，保留 `/etc/config/minigate`、证书、封禁记录和日志
3. 只有确认不再使用时，才勾选「同时删除配置、证书、封禁记录和日志」
4. 点击「确认卸载」后，页面会返回 LuCI 服务列表

卸载会立即停止 minigate 的 DDNS、证书续期、反向代理和登录防护。请从 LAN 或 SSH 登录 LuCI 后操作，避免通过 minigate 自身的公网反向代理入口执行。

### 方式 2：命令行保留配置卸载

适合以后还可能重装 minigate 的情况。此方式会删除 LuCI 页面、脚本和服务文件，但保留 `/etc/config/minigate` 以及 `/etc/minigate/` 下的证书、封禁记录等数据。

```sh
/bin/sh /usr/lib/minigate/uninstall.sh 0
```

脚本会自动识别源码安装、`opkg` 和 `apk`，清理程序、LuCI 页面、cron、运行进程及临时状态，并刷新 LuCI。

如果你是早期版本，尚未包含 `uninstall.sh`，可以使用包管理器卸载：

```sh
/etc/init.d/minigate stop 2>/dev/null
/etc/init.d/minigate disable 2>/dev/null
opkg remove minigate 2>/dev/null || apk del minigate 2>/dev/null
/etc/init.d/uhttpd restart
```

源码安装且没有包管理器记录的旧版本，建议先覆盖安装最新版，再使用 LuCI 或上面的统一卸载脚本，不要手工复制不完整的删除清单。

### 方式 3：命令行彻底卸载

确认不再使用 minigate 时再执行。此方式会删除配置、证书记录、登录防护封禁记录和日志。

```sh
/bin/sh /usr/lib/minigate/uninstall.sh 1
```

---

## 使用指南

### 第一步：基础配置
1. 进入 **LuCI → 服务 → MiniGate**
2. 在「总览」页面顶部勾选「启用 MiniGate」，点击「保存并应用」
3. 如需 IPv6 反代监听，在「反向代理 → 高级设置」开启「监听 IPv6」

### 第二步：配置 DDNS
1. 切换到 **DDNS** 标签页
2. 启用 DDNS，填入 Cloudflare Zone ID 和 API Token
3. 设置域名，选择协议版本（IPv4 / IPv6 / 双栈）
4. 软路由在上级路由后面时，「IP 来源」选「从外部URL获取」
5. 保存并应用

### 第三步：签发 SSL 证书
1. 切换到 **SSL 证书** 标签页，启用 ACME
2. 先用测试模式（Staging）验证
3. 点击「立即签发」，签发在后台进行，可以离开页面
4. 成功后关闭测试模式并保存，再签发正式证书；证书列表会标出「测试证书」和「正式证书」

### 第四步：配置反向代理
1. 切换到 **反向代理** 标签页
2. 添加规则，填写域名、目标地址和端口
3. 启用 SSL（自动关联 ACME 证书）
4. 如需输入 `http://域名:监听端口` 后自动进入 HTTPS，在页面下方「高级设置」开启「HTTP 跳转」
5. 保存并应用；MiniGate 会自动跟随每条 HTTPS 规则的监听端口，无需额外指定固定跳转端口
6. 如需内网访问不绕公网，开启「局域网直连解析」（见下方说明）

### 局域网直连解析
宽带重新拨号后，DDNS 会很快更新公网记录，但主路由或运营商 DNS 可能在一段时间内继续返回旧 IP（部分运营商 DNS 不遵守 TTL），内网访问因此时好时坏；主路由不支持 NAT 回流时也无法从内网访问。

开启后，minigate 在每次启动和重载时把已生成站点的具体域名写入 `/tmp/hosts/minigate`，并通知 dnsmasq 重新加载（不重启任何服务，内容未变时不重载）：

```
192.168.1.1 app.example.com
```

- 解析地址默认取 LAN 口 IPv4，也可以手动指定
- 只覆盖使用本机 dnsmasq 的设备；浏览器自行开启的安全 DNS（DoH）不受影响
- 内网访问使用与公网相同的端口，因此要求公网端口映射没有改端口号（例如外网 443 映射到内网 2000 时不适用）
- 关闭开关或停止 minigate 时会移除该文件；也可以手动执行 `/usr/lib/minigate/proxy.sh lan-dns` 重新同步

### 设置公网访问范围
在 **反向代理 → 高级设置：公网访问范围** 中启用「限制公网访问地区」，再勾选允许的省级地区（支持多个）。例如仅保留「四川省」，保存应用后，只允许地址库判定为四川的公网 IP 访问。默认关闭，升级不会自动收紧现有访问范围。

- 所有普通域名、子域名、HTTP 跳转及 WebSocket 均在转发前检查；其他地区、境外及归属地未知来源返回 Nginx `444`（直接断开，无响应正文）
- IPv4、IPv6 使用同一策略；RFC1918 私有 IPv4、回环、IPv6 ULA 和链路本地地址继续放行；LAN 接口已分配的全球 IPv6 子网也自动豁免。使用「局域网直连解析」可通过 LAN IPv4 访问
- 不修改防火墙，不限制 SSH、RustDesk 等其他服务；旧版的地区日志扫描封禁已移除，升级时会把旧配置迁移到这里；登录防护独立生效
- 使用实际连接来源（同端口分流时为本机 stream 提供的 PROXY protocol），不信任访客提交的 `X-Forwarded-For` / `X-Real-IP`；若前面还有 CDN 或隐藏来源的代理，看到的是该代理的出口 IP
- 数据来自 [ip2region](https://github.com/lionsoul2014/ip2region)，随安装包附带 34 个省级地区的离线 CIDR，不需要在线归属地接口或额外 Nginx 模块。版本、源文件 SHA-256 和网段数见 `root/usr/lib/minigate/geo/metadata.json`，原许可证随包保留
- 地址归属可能误判或随运营商调整变化；外出、漫游或使用外省代理出口时可能被拦截。数据缺失或配置为空时仍拒绝公网，不自动退回全部放行。可从局域网关闭开关恢复访问

维护数据时，从 `scripts/build-geo-data.py` 中的固定 `REVISION` 下载对应 `data/ipv4_source.txt`、`data/ipv6_source.txt`，然后运行：

```bash
python3 scripts/build-geo-data.py /path/to/ip2region/data
```

脚本核验源文件 SHA-256 后生成省级 CIDR。更新快照时需同时审查来源提交、更新固定摘要和许可证，并随项目新版本发布；运行时不自动下载或替换白名单。

### Cloudflare API Token 创建方法
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)
2. 头像 → **My Profile** → **API Tokens** → **Create Token**
3. 使用 **Edit zone DNS** 模板
4. Zone Resources 选择你的域名
5. 创建并复制 Token

---

## 安全特性

### 域名访问限制
安装后，反向代理自动拒绝直接使用 IP 地址访问的请求（返回 444 断开连接）。同时，每个监听端口都会生成 `default_server` 兜底规则，未配置的 Host / 子域名前缀不会落到同端口第一个反代站点。只有通过正确域名访问才能到达后端服务，这可以有效防止网络扫描器探测和域名串站。

### 访客追踪
总览页面实时显示所有通过反向代理访问的 IP 地址、归属地和最近请求结果，帮助你发现异常访问。

---

## 文件结构

```
minigate/
├── CONTRIBUTING.md                    # 贡献说明
├── LICENSE                            # MIT 许可证
├── Makefile                           # OpenWrt 编译配置
├── README.md
├── SECURITY.md                        # 安全报告策略
├── install.sh                         # 一键安装脚本（兼容 opkg/apk）
├── luasrc/
│   ├── controller/minigate.lua        # LuCI 路由控制器
│   ├── model/cbi/minigate/
│   │   ├── general.lua                # 总览（含访客追踪）
│   │   ├── ddns.lua                   # DDNS（IPv4/IPv6）
│   │   ├── acme.lua                   # ACME 证书
│   │   ├── proxy.lua                  # 反向代理
│   │   └── login_guard.lua            # 登录防护
│   └── view/minigate/
│       ├── log.htm                    # 日志页面（按时间合并各来源）
│       ├── style.htm                  # 各配置页共用的深浅色样式
│       ├── proxy_empty.htm            # 反代页无域名时的提示
│       └── ddns_history.htm           # 最近一天 IP 变化明细
└── root/
    ├── etc/config/minigate            # UCI 配置（含 login_guard 段）
    ├── etc/init.d/minigate            # procd 服务脚本（Nginx、登录防护、配置变更自动重载）
    ├── usr/share/nftables.d/          # 登录防护封禁集合与规则（随 fw4 加载）
    └── usr/lib/minigate/
        ├── ddns.sh                    # DDNS（双栈）
        ├── acme.sh                    # 证书管理
        ├── proxy.sh                   # 反代（协议分流+IPv6+访问日志）
        ├── login_guard.sh             # 登录防护 watcher + CLI（IPv4/IPv6）
        ├── job.sh                     # 签发证书、手动同步等后台任务
        ├── geo_lookup.sh              # 离线省级归属地查询
        ├── uninstall.sh               # 卸载
        └── update.sh                  # GitHub Release 安全更新器
```

## 依赖

- `luci-base` - LuCI Web 界面
- `luci-compat` - LuCI 的 CBI 页面支持（新版 LuCI 不再默认附带）
- `nginx-ssl` - Nginx（带 SSL 支持）
- `nginx-mod-stream` - 在同一入口端口识别 HTTP 与 TLS
- `openssl-util` - 证书工具
- `wget` - 下载安装包和源码包
- `curl` - HTTP 客户端
- `jsonfilter` - JSON 解析
- `coreutils-stat` - 登录防护读取计数文件更新时间
- `nftables` - 登录防护用（OpenWrt 22.03+ / ImmortalWrt 默认已装）

## 更新日志

### v2026.10.28-2
- 修复 v2026.10.28 引入的登录防护回归：达到失败阈值时，封禁地址被修复防火墙的读取过程清空，日志显示「封禁  失败」，新的攻击来源不会被封禁（已有封禁不受影响）。升级后会立即恢复正常封禁

### v2026.10.28-1
- 「公网访问范围」的地区选择改为收起式：收起时只显示已选地区标签和数量，展开后按华北、东北、华东、华中、华南、西南、西北、港澳台分组对齐排列，支持按地区名或大区名搜索、一键清空、点标签上的 × 移除
- 修复 v2026.10.28 中关闭「限制公网访问地区」后保存反向代理页会提示未选择地区、导致整页无法保存的问题

### v2026.10.28
- 修复：通配符主域名停用或删除后，其子域名会退回成 443 端口的明文 HTTP 站点，并可能让 Nginx 因两个默认站点无法加载；现在子域名随主域名一起停用，并可单独停用
- 修复：同一端口同时有 HTTP 和 HTTPS 规则时生成无法加载的配置；冲突规则会被跳过并在总览提示
- 配置检查失败时恢复上一份可用配置；生成过程加锁，避免保存、续期和更新同时触发时互相覆盖
- 服务改由 procd 管理：Nginx 与登录防护异常退出后自动拉起，LuCI「保存并应用」后只重载受影响的部分，不再轮询等待配置写入
- 登录防护支持 IPv6 来源、任意前缀长度的白名单；封禁规则随防火墙重载自动加载，重载后的封禁 30 秒内恢复；封禁失败不再误记为已封禁
- DDNS 只推送公网地址，外部查询默认用 HTTPS；运行状态移出 `/etc/config/minigate`，定时检查不再改写配置
- 证书：固定 acme.sh 3.1.6 并校验 SHA-256；剩余超过 30 天不重复签发；签发和手动同步改为后台任务，不受网页超时影响
- 所有站点自动支持 WebSocket；归属地优先查离线地址库，境外地址才用 HTTPS 接口
- 移除旧版地区日志扫描（升级时迁移到请求前准入）；定时任务只管理本插件脚本，不再误删用户任务
- 界面：名称统一为 MiniGate；总开关移到总览顶部，未启用时有提示；DDNS 卡片列出全部记录并按最差状态着色；证书卡片显示到期日期、剩余天数和测试证书；反代地址可直接点击，并显示配置问题；卸载移到底部「危险操作」区
- 界面：日志「全部」按时间合并各来源，新增登录防护、软件更新来源，向上翻看时不再被拉回底部；DDNS 手动同步不再刷新整页；反代页规则在前、高级设置在后，地区改为复选框，启用开关统一为勾选框；配置页跟随深色主题；表单增加域名、Zone ID、检查间隔、阈值和白名单校验
- CI 对每次推送和 PR 运行测试，发布任务只在测试通过后执行

### v2026.10.26
- 访问记录区分「已拦截、已转发、已响应、请求失败、结果未知」，显示最近请求的 HTTP 状态与拦截/转发/其他次数
- 「在线/离线」改为近期请求说明，避免把被拒绝的外地扫描误认为访问成功；保留拦截记录便于核查
- 新日志记录上游响应，后端 401/403 不误判为地区拦截；兼容旧日志，缺少信息时不推断转发或登录成功

### v2026.10.25
- 新增可配置的「公网访问范围」：选择一个或多个省级地区，仅允许匹配的公网 IP 访问所有反代站点，其他及未知来源在首次转发前直接断开
- 同时检查 IPv4、IPv6，覆盖 HTTP 跳转与 WebSocket；保留局域网访问，不修改防火墙或限制 SSH、RustDesk
- 随包附带离线省级地址库及来源、摘要和许可证，不依赖在线查询；限制默认关闭，启用时预选四川
- 新增真实 Nginx 请求和 LuCI 参数校验测试，地区数据缺失不自动退回全部放行


### v2026.10.17
- 新增「局域网直连解析」（默认关闭）：把已配置的代理域名直接解析到本机 LAN 地址，宽带重新拨号后主路由或运营商 DNS 继续返回旧 IP 时，内网访问不再时好时坏，流量也不进入代理
- 地区访问控制改用 BusyBox 兼容的访客提取方式（原 `grep -P` 在 BusyBox 上无法运行，扫描实际取不到任何 IP），并跳过局域网、回环、链路本地和运营商 NAT 地址

### v2026.10.14-3
- 修复 v2026.10.14-2 的登录防护进程匹配过宽：命令行中恰好含有登录防护命令文本的调用方会被当成登录防护一并结束，可能导致更新中断并自动回滚；现在只匹配登录防护的实际启动命令
- 包含 v2026.10.14-2 的全部修复：停止或重启登录防护时不再遗留 `logread -f`、`tail -f` 子进程

### v2026.10.14-2
- 修复停止或重启登录防护时遗留 `logread -f`、`tail -f` 子进程的问题；每次重启、更新或保存登录防护设置不再累积孤儿进程
- 从旧版本升级时，安装脚本先完整结束旧的登录防护进程树，升级本身也不会留下残留进程

### v2026.10.14-1
- 修复 LuCI 一键卸载和命令行卸载在停止服务后中断、程序和页面未被删除的问题
- 证书自动续期后重载 Nginx，避免继续使用旧证书直至过期
- 修复登录防护定时检查逻辑写反：不再每 5 分钟改写封禁文件，防火墙重载后立即恢复封禁
- DDNS 网络请求增加超时并串行执行；Cloudflare 令牌不再出现在进程参数中；「间隔(秒)」设置现在生效
- 保存设置后等配置提交再应用；保存动态 DNS 页不再重启反向代理
- 访问日志等内存日志设置大小上限；封禁、同步、签发等操作改为 POST 并校验 CSRF 令牌
- 界面：空列表与读取失败分开提示、归属地不再闪烁、后台标签暂停轮询、手机端卡片布局、证书页适配深色主题

### v2026.10.14
- 公网 IP 更新并经 Cloudflare 确认成功后，无重启刷新 sing-box 与 dnsmasq 的本地 DNS 缓存，减少局域网继续命中旧地址
- 只有 DNS 记录实际新增、改写、清理重复项，或 MiniGate 本地仍保存旧 IP 时才刷新；普通定时检查不会反复清缓存
- sing-box 接口或 dnsmasq 不可用时仅记录诊断，不回滚已成功的 DDNS 更新，也不重启 Open-Box、sing-box 或整套代理

### v2026.9.18-2
- 修复 DDNS 历史写入与 LuCI 查询使用不同 UCI 节名称，导致“最近一天 IP 变化明细”无法找到记录的问题
- 历史文件改用域名作为稳定标识；接口成功但暂无记录时，页面现在显示正常空状态，不再误报读取失败

### v2026.9.18-1
- 修复已有可用 OpenSSL CLI、但包管理器没有 `openssl-util` 安装记录时，一键更新仍尝试联网安装依赖并触发回滚的问题
- 源码安装现在先执行 `openssl version` 验证能力；已可用则跳过包安装，缺失时仍正常安装 `openssl-util`

### v2026.9.18
- 动态 DNS 页面新增最近 24 小时 IP 变化明细，显示 IPv4/IPv6、开始时间、结束时间和持续时长
- 历史只在 IP 实际变化时写入，稳定轮询不触碰历史文件，并保留跨越 24 小时边界的持续区间
- 桌面端使用紧凑表格，手机端优先纵向展示 IP 和持续时间，适配深浅色主题
- 修复源码安装未安装 `openssl-util`，导致 ACME 签发和续期缺少 OpenSSL CLI 的问题

### v2026.9.14-4
- 总览标题区新增「卸载」按钮，适配桌面、手机和深浅色主题
- 卸载前必须二次确认，默认保留配置、证书、封禁记录和日志
- 可主动选择彻底清理；统一兼容源码安装、opkg 和 apk 包安装

### v2026.9.14-3
- 新增 `curl -fsSL https://raw.githubusercontent.com/tpxcer/minigate/main/scripts/install.sh | sh` 短命令安装
- 自动获取 latest Release，并在写入系统前校验 SHA-256、压缩包路径和版本信息
- 下载前后核对 `SHA256SUMS`，避免发布切换期间混用不同版本文件
- 保留固定版本长命令，方便指定版本和手工复核

### v2026.9.14-2
- 修复一键更新启动 Nginx、登录防护和 LuCI 服务后更新锁被长驻进程继承，导致后续「检查更新」只显示旧状态的问题
- 更新流程在所有正常返回路径显式释放锁，启动长驻服务时同时关闭更新锁文件描述符

### v2026.9.14-1
- 修复子域名反向代理规则的 WebSocket 开关未生效问题
- 子域规则现在会正确生成 `Upgrade` / `Connection` 头，支持 Open-Box 等 WebSocket 动态页面通过外网穿透显示连接和日志

### v2026.9.14
- 项目、GitHub 仓库和 OpenWrt 内部包名统一为 `minigate`
- 改用北京时间发布日期版号，同一天后续版本依次追加 `-1`、`-2`
- 打开总览自动检查更新，点击一键更新先显示本次内容并要求确认
- 确认绑定具体版本，避免安装未看过说明的后续版本；修复成功状态重复刷新
- 保留 `v1.3.11` 识别的旧名源码包副本，方便迁移到首个日期版

### v1.3.11
- HTTP 自动跳转改为跟随任意 HTTPS 监听端口，同一端口同时接受 HTTP 和 TLS；非 443 端口会保留端口号
- 协议分流通过 PROXY protocol 保留真实访客 IP，未知 Host 仍直接拒绝
- 总览新增「检查更新 / 一键更新」，固定 GitHub Release 来源并执行 SHA-256 校验、备份、服务验证和失败回滚

### v1.3.10
- 新增独立 HTTP 自动跳转入口，为已配置 HTTPS 的代理域名返回 308 跳转
- 未配置 Host 继续返回 444，且禁止 HTTP 跳转端口与反向代理监听端口冲突
- 公网部署时可将 TCP 80 映射到内部跳转端口（默认 2001），无需暴露 LuCI 的 80 端口

### v1.3.9
- 修复 FanchmWrt 等 LuCI 主题使用自身深色开关时，minigate 仍显示白色卡片和表格的问题
- 页面背景、文字、边框和控件改为跟随 LuCI 主题变量，同时保留系统深色模式兼容

### v1.3.8
- 调整 LuCI 深色模式配色，降低高饱和强调色和卡片边框的突兀感
- 统一总览与登录防护页面的深色背景、文字和状态颜色

### v1.3.7
- DDNS 同步会保留一条匹配当前 IP 的 A / AAAA 记录，并删除其余同名同类型重复记录，避免旧 IP 继续参与解析
- Cloudflare 记录查询失败时不再误判为记录不存在，避免异常新建重复 DNS 记录

### v1.3.6
- 修复 ACME 重复签发/续期失败时，即使本地已有有效证书仍把 SSL/TLS 状态误标为 `error` 的问题
- ACME 现在会在失败但已有证书未过期时保留 `ok` 状态，并记录最近错误，避免总览页误报证书失效
- 修复 LuCI 手动签发证书、手动同步 DDNS 时命令参数未做安全引用的问题
- 对总览页、证书页、登录防护页中的域名、证书、访问记录、归属地等动态文本做 HTML 转义

### v1.3.5
- 修复同一监听端口下未知 Host / 任意子域名前缀会落到第一个反代站点的问题；现在会生成 `default_server` 兜底规则并直接断开
- HTTPS 反代端口自动生成 minigate 默认证书用于兜底拒绝站点，避免未知 SNI 复用真实站点
- 修复通过 minigate 反向代理访问 LuCI 时，登录防护页面保存设置导致当前反代连接被断开的问题
- 登录防护页面保存设置时改为轻量重载 minigate，不再完整重启反代 nginx
- 登录防护「失败计数中」新增最近访问时间，并按最新访问时间排在最前
- 修复 OpenWrt/ImmortalWrt 编译菜单中 `luci-app-minigate` 出现两条重复选项的问题
- Release 自动构建流程改为中文更新说明，并自动刷新安装包附件

### v1.3.4
- 🎨 修复 LuCI 白天模式下总览和登录防护页面仍显示深色卡片/表格的问题
- 🎨 保留黑夜模式原有深色显示效果，页面会跟随系统/浏览器配色切换

### v1.3.3
- 🐛 重新生成 OpenWrt opkg 更兼容的 `.ipk` ar 归档格式，修复部分系统仍提示 `Malformed package file`

### v1.3.2
- ✨ 登录防护「失败计数中」默认显示 5 条，支持 5 / 20 / 30 条下拉切换
- ✨ 失败计数归属地查询复用总览「访问记录」的查询方式
- 🐛 修复失败计数文件异常时 `lg_status` 刷新卡住的问题

### v1.3.1
- 🐛 修复手工安装脚本在 OpenWrt `/bin/sh` 下目录创建失败的问题
- 🐛 重新生成标准 `.ipk` 安装包，避免 LuCI 提示 `Malformed package file`

### v1.3.0
- ⚡ 归属地查询增加 24 小时本地缓存
- ⚡ 缩短外部归属地接口超时时间，减少页面等待

### v1.2.0
- ✨ 新增 **登录防护 (Login Guard)** —— SSH/LuCI 失败登录达到阈值自动封禁源 IP
- ✨ LuCI 网页：实时封禁列表 + 归属地 + 一键解封/封禁/清空
- ✨ 持久化封禁，重启/固件升级后自动恢复
- ✨ Watchdog 自检 nftables 资源，防 fw4 reload 后失效
- 🔧 install.sh 自动清理旧的独立 login-guard 部署（如有）+ 迁移 bans.txt

### v1.1.0
- ✨ DDNS 支持 IPv6 / 双栈模式（A + AAAA 记录）
- ✨ 反向代理支持 IPv6 监听
- ✨ 总览页面新增访客追踪（IP、归属地、在线状态）
- ✨ 归属地后端查询（解决浏览器跨域问题）
- ✨ 直接 IP 访问拒绝（防扫描器）
- ✨ 同时兼容 opkg（IPK）和 apk（源码安装）
- ✨ install.sh 自动适配 opkg/apk 环境
- 🐛 目标地址支持 IPv6 格式

### v1.0.0
- 🎉 初始版本：Cloudflare DDNS、Let's Encrypt ACME、Nginx 反向代理

## 许可证

MIT License


