# VPS-proxy：Oracle 亚洲 + GCP 美国，拼一个免费美国出口

```
你的设备 ──VLESS+Reality──▶ Oracle 新加坡/日本（中转）──Shadowsocks 2022──▶ GCP us-west1（出口）──▶ 美国网站
```

- **Oracle 管中国这一侧**：Always Free 每月 10 TB 出站，你收到的所有数据都从这里发出。
- **GCP 管美国这一侧**：免费 e2-micro，公网 IP 用 **Standard Tier**，每月前 200 GiB 出站免费。网站看到的是 GCP 的美国 IP。

思路来自 [@404jsh 的推文](https://x.com/404jsh/status/2105317843617378492)。本仓库把它做成了脚本，两边都只要在各自的网页版 Cloud Shell 里跑一条命令，不用在本机装任何云工具，也不用把云账号密钥交给别人。

> 仅供个人自用。请遵守所在地法律和两家云厂商的服务条款。

---

## 先纠正推文里的三处细节（按 2026-09 官方价格页）

| 推文说法 | 实际情况 | 影响 |
|---|---|---|
| Standard Tier「每个区域每月 200GiB 免费」 | [VPC 价格页](https://cloud.google.com/vpc/network-pricing)现在写的是 **每个结算账号每月共 200 GiB，所有区域合计** | 一个账号就是 200 GiB，多开区域不会叠加 |
| GCP 主要的出站是「GCP → 美国网站」 | 真正的大头是 **回程 GCP → Oracle 新加坡**（你下载的每个字节都要走这段）。去美国网站的只是请求，量很小 | 仍然在 200 GiB 内，结论不变 |
| 「中国方向不在免费额度内」 | 这是 **Premium Tier** 那 1 GB 免费额度的限制（不含中国、澳大利亚）。Standard Tier [按来源区域计价](https://cloud.google.com/network-tiers/pricing)，不分目的地 | **必须把 IP 设成 Standard Tier**，否则走 Premium，只有 1 GB 免费 |

所以这个方案里 Oracle 的主要价值是 **线路和隐蔽性**：国内直连 GCP 美国的 Standard Tier 线路一般很差，Oracle 亚洲区到国内好得多。它不只是用来省钱的。

还要注意：

- **GCP 外网 IPv4**：普通实例每小时 $0.005，但 [Google 的公告](https://cloud.google.com/vpc/pricing-announce-external-ips)写明免费层实例不收外网 IP 费。建议跑一两天后到「结算 → 报告」里确认，项目费用应该是 0。
- **200 GiB 是整个 GCP 账号共用的**，其他项目的出站也算在里面。
- 脚本在 GCP 机器上装了 `traffic-guard`：本月出站到 **180 GiB**（按太平洋时间，与 Google 账单月对齐）就自动停掉代理，下个月自动恢复。另外建了一个 1 美元的预算邮件提醒。

---

## 第 0 步：准备

- 一张能在海外扣款的 **Visa / MasterCard 信用卡**。两家可以绑**同一张卡**，各自预授权约 1 美元，几天到一两周内自动撤销，不会真扣。
  - Oracle 基本只收信用卡，借记卡、预付卡、虚拟卡大多会被拒；纯银联卡两家都不行。
  - 绑卡前在银行 App 里开通「境外线上交易 / 无卡支付」，可以顺手把境外单笔限额调低（如 50～100 元），给意外扣费加个上限。
  - 地址、姓名（拼音）、国家都填真实信息，并和卡的账单地址一致。
  - **没有这样的卡，这个方案就做不了。** 可以先去银行办一张双币信用卡。
- 一个 Google 账号。
- 注册和打开两家控制台时，你本身得能访问它们的网站。
- 手机客户端：iOS 用 Shadowrocket；Android 用 v2rayNG 或 Hiddify；Windows 用 v2rayN 或 Hiddify；macOS 用 Hiddify 或 sing-box。

---

## 第 1 步：注册 Oracle Cloud（手动）

1. 打开 <https://www.oracle.com/cloud/free/> → **Start for free**。
2. 填邮箱和国家/地区（要和信用卡账单地址一致），然后去邮箱点验证链接。
3. 设置密码和 **Cloud Account Name**（租户名，以后登录要用，记下来）。
4. **Home Region** 选一个亚洲区域。⚠️ 主区域以后不能改，免费实例只能建在主区域。
   - **日本 大阪 / 东京**（推荐）：离国内近，到 GCP 美国西部也比新加坡近，整条链路延迟更低。
   - **新加坡**（推文原版）：国内线路普遍还行，但到美国西部绕得远。
   - 韩国 春川 / 首尔：离国内近，春川人相对少。
   - 不要选欧洲区（法兰克福、阿姆斯特丹）：免费资源虽然多，但离国内太远，不适合做中转。
   - 以上延迟比较是按地理位置估的，没有实测；线路好坏也和运营商有关。脚本在任何区域都能用。
5. 填地址和手机号，接收短信验证码。
6. 绑卡验证。如果报 “Error processing transaction”，常见原因是卡不支持或地址不一致，换卡或核对地址后重试。
7. 等开通邮件（几分钟到几小时），然后登录 <https://cloud.oracle.com>。

注意：
- 免费实例如果 7 天内 CPU、网络、内存利用率都很低，Oracle 可能会回收（idle reclaim）。有流量在跑一般不会触发。想彻底避免，可以升级成「按量付费」账号：Always Free 资源仍然免费，但**超出免费范围的资源会开始计费**，升级前想清楚。
- 亚洲各区的 ARM 机器（A1）都经常提示容量不足（Out of host capacity）。脚本会自动退回到 AMD 小机器（E2.1.Micro），它性能弱一些，但做中转够用。

## 第 2 步：注册 Google Cloud（手动）

1. 打开 <https://console.cloud.google.com/>，用 Google 账号登录，点 **免费试用 / Start free**。
2. 选国家，账号类型选 **个人**，绑信用卡（也是预授权验证）。开通后有 90 天 $300 试用金，**免费层（e2-micro、200 GiB Standard 出站）在试用结束后仍然有效**。
3. 顶部项目下拉框 → **新建项目**，名字随便起，比如 `vps-proxy`。
4. ⚠️ 90 天试用期结束前，控制台会提示「激活完整账号」。**不激活的话，机器会被停掉**；激活后超出免费范围的部分会从卡里扣钱，所以本仓库加了流量上限和预算提醒。

## 第 3 步：建 GCP 出口机（在 Google Cloud Shell 里跑命令）

1. 在 GCP 控制台右上角点 **`>_`（激活 Cloud Shell）**。
2. 运行：

```bash
gcloud config set project <你的项目ID>
git clone https://github.com/cooky-dance/VPS-proxy.git && cd VPS-proxy
bash gcp/setup.sh
```

脚本会：开启 Compute API → 把项目默认网络层级设成 Standard → 建防火墙规则 → 在 `us-west1-b` 建 e2-micro（Debian 12、30 GB 标准永久磁盘、**Standard Tier IP**）→ 建预算提醒。机器开机后会自动装 sing-box 和 traffic-guard。

最后会打印出下一步要运行的命令，形如：

```
bash oracle/setup.sh 34.x.x.x 'xxxxxxxxxxxxxxxxxxxxxx==' 8388
```

**把这一行复制下来。** 里面有密码，不要发到公开的地方。

> 可选参数：`ZONE=us-central1-a`（换区域）、`TRAFFIC_LIMIT_GIB=150`（换流量上限）、`BUDGET=7CNY`（结算币种不是美元时用）。例如 `TRAFFIC_LIMIT_GIB=150 bash gcp/setup.sh`。

## 第 4 步：建 Oracle 中转机（在 Oracle Cloud Shell 里跑命令）

1. 在 Oracle 控制台右上角点 **开发者工具图标 → Cloud Shell**（确认页面右上角显示的是你的主区域）。
2. 运行（最后一行换成上一步打印出来的那行）：

```bash
git clone https://github.com/cooky-dance/VPS-proxy.git && cd VPS-proxy
bash oracle/setup.sh 34.x.x.x 'xxxxxxxxxxxxxxxxxxxxxx==' 8388
```

脚本会：建 VCN、互联网网关、路由和安全列表（放行 22 和 443 端口）→ 先尝试 A1（1 核 6 GB），失败就改用 E2.1.Micro → 用 cloud-init 装 sing-box、放行系统防火墙、开启 BBR。

最后会打印 Oracle 的 IP 和一条 `vless://...` 客户端链接，同时保存到 Cloud Shell 的 `~/vps-proxy-client.txt`。

## 第 5 步：收紧 GCP 防火墙（回到 Google Cloud Shell）

```bash
bash gcp/lockdown.sh <Oracle 的 IP>
```

之后 GCP 出口机只接受 Oracle 中转机的连接。

## 第 6 步：导入客户端

等 2～3 分钟，让两台机器的开机脚本跑完。然后把 `vless://...` 链接复制到客户端（一般是「从剪贴板导入」），选中这个节点并开启代理。

验证：浏览器打开 <https://ipinfo.io>，应该显示美国俄勒冈的 Google IP。

---

## 手动步骤一览

| # | 在哪 | 做什么 |
|---|---|---|
| 1 | Oracle 官网 | 注册、Home Region 选亚洲区（推荐日本）、绑卡 |
| 2 | Google Cloud 官网 | 注册、绑卡、新建项目 |
| 3 | GCP Cloud Shell | `bash gcp/setup.sh` |
| 4 | Oracle Cloud Shell | `bash oracle/setup.sh ...` |
| 5 | GCP Cloud Shell | `bash gcp/lockdown.sh <Oracle IP>` |
| 6 | 手机 / 电脑 | 导入 `vless://` 链接 |
| 7 | GCP 控制台（试用期结束前） | 激活完整账号 |

## 日常查看

在 GCP 出口机上（控制台 → Compute Engine → 实例 → SSH）：

```bash
vnstat -m                            # 本月流量（tx 就是计费的出站）
systemctl status sing-box            # 代理是否在运行
journalctl -t traffic-guard          # 有没有因为超额被停过
echo 150 | sudo tee /etc/traffic-limit-gib   # 改流量上限（重启后会恢复成元数据里的值）
```

Oracle 中转机上的配置在 `/etc/sing-box/config.json`。

## 常见问题

- **客户端连不上**：先确认 Oracle 实例是 RUNNING 状态，而且已经等了 3 分钟。在 Oracle 机器上跑 `systemctl status sing-box`。国内部分运营商到 Oracle 的线路可能不稳，可以换个网络试试。
- **能连上但打不开网页**：通常是 GCP 那边的问题。在 GCP 机器上看 `systemctl status sing-box`，确认 `gcp/lockdown.sh` 里填的 IP 就是 Oracle 的 IP。
- **想换 Reality 伪装站点**：`SNI=www.apple.com bash oracle/setup.sh ...`（需要先在 Oracle 控制台终止旧实例）。
- **GCP 出现了费用**：在「结算 → 报告」里按 SKU 分组查看。最常见的原因是 IP 不是 Standard Tier，或者磁盘选成了 balanced/SSD。脚本已经指定 Standard Tier 和 pd-standard。

## 文件

| 文件 | 在哪里运行 | 作用 |
|---|---|---|
| `gcp/setup.sh` | Google Cloud Shell | 建出口机、防火墙、预算提醒 |
| `gcp/startup.sh` | GCP 出口机（开机自动） | 装 sing-box（Shadowsocks 2022 入站，拒绝访问内网和元数据地址）、BBR、traffic-guard |
| `gcp/lockdown.sh` | Google Cloud Shell | 防火墙只放行 Oracle IP |
| `oracle/setup.sh` | Oracle Cloud Shell | 建网络和中转机，生成 Reality 密钥和客户端链接 |

sing-box 固定用 1.12.9 版本。整条链路（客户端 → Reality 中转 → SS 出口）已经在本地用这个版本实际跑通；UUID 错误的连接会被拒绝；出口端访问 `127.0.0.1`、`169.254.169.254` 会被拒绝。

## 许可证

[MIT](LICENSE)。本仓库的脚本不包含 sing-box 本体，只在服务器上从官方 GitHub Releases 下载（sing-box 自身使用 GPL-3.0）。
