#!/bin/bash
# 在 Oracle Cloud Shell 里运行：创建新加坡中转机（VLESS + Reality 入口，所有流量转发给 GCP 出口机）。
#   bash oracle/setup.sh <GCP 公网 IP> '<SS 密码>' [SS 端口，默认 8388]
# 可用环境变量覆盖：SNI（Reality 伪装站点，默认 www.microsoft.com）、SHAPE（A1 或 MICRO，默认先试 A1）、
# COMPARTMENT_ID（默认根区间）。
set -euo pipefail

SING_BOX_VERSION=1.12.9
NAME=vps-proxy-relay
SNI=${SNI:-www.microsoft.com}
OUT_FILE=${OUT_FILE:-$HOME/vps-proxy-client.txt}

b64url() { base64 -w0 | tr '+/' '-_' | tr -d '='; }

render_config() { # $1=GCP IP $2=SS 端口 $3=SS 密码 $4=UUID $5=Reality 私钥 $6=short id $7=SNI
  cat <<EOF
{
  "log": {"level": "warn"},
  "inbounds": [
    {"type": "vless", "tag": "from-client", "listen": "::", "listen_port": 443,
     "users": [{"uuid": "$4", "flow": "xtls-rprx-vision"}],
     "tls": {"enabled": true, "server_name": "$7",
             "reality": {"enabled": true, "handshake": {"server": "$7", "server_port": 443},
                         "private_key": "$5", "short_id": ["$6"]}}}
  ],
  "outbounds": [
    {"type": "shadowsocks", "tag": "to-gcp", "server": "$1", "server_port": $2,
     "method": "2022-blake3-aes-128-gcm", "password": "$3"}
  ],
  "route": {"final": "to-gcp"}
}
EOF
}

render_cloud_init() { # $1=sing-box 配置
  cat <<EOF
#!/bin/bash
set -euo pipefail
# Oracle 的 Ubuntu 镜像自带 iptables 规则，只放行 22 端口，要手动放行 443。
iptables -I INPUT -p tcp --dport 443 -j ACCEPT
iptables -I INPUT -p udp --dport 443 -j ACCEPT
netfilter-persistent save || true
cat >/etc/sysctl.d/90-bbr.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
SYSCTL
sysctl -q --system
arch=\$(dpkg --print-architecture)
curl -fsSL -o /tmp/sing-box.deb \
  "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box_${SING_BOX_VERSION}_\${arch}.deb"
dpkg -i /tmp/sing-box.deb
install -d /etc/sing-box
cat >/etc/sing-box/config.json <<'CONFIG'
$1
CONFIG
chmod 600 /etc/sing-box/config.json
sing-box check -c /etc/sing-box/config.json
systemctl enable sing-box
systemctl restart sing-box
EOF
}

find_or_create() { # $1=列表命令 $2=创建命令（都返回 id）
  local id
  id=$(eval "$1" 2>/dev/null || true)
  if [ -z "$id" ] || [ "$id" = "null" ]; then
    id=$(eval "$2")
  fi
  echo "$id"
}

latest_ubuntu_image() { # $1=shape
  oci compute image list --compartment-id "$COMP" --operating-system "Canonical Ubuntu" \
    --operating-system-version "24.04" --shape "$1" --sort-by TIMECREATED --sort-order DESC \
    --query 'data[0].id' --raw-output
}

launch() { # $1=shape $2=shape-config(JSON 或空)
  local image args
  image=$(latest_ubuntu_image "$1")
  args=(--availability-domain "$AD" --compartment-id "$COMP" --shape "$1" --image-id "$image"
        --subnet-id "$SUBNET" --assign-public-ip true --display-name "$NAME"
        --ssh-authorized-keys-file "$HOME/.ssh/id_ed25519.pub" --user-data-file "$USER_DATA"
        --wait-for-state RUNNING --query 'data.id' --raw-output)
  [ -n "$2" ] && args+=(--shape-config "$2")
  oci compute instance launch "${args[@]}"
}

main() {
  local gcp_ip=${1:?用法：bash oracle/setup.sh <GCP 公网 IP> '<SS 密码>' [SS 端口]}
  local ss_password=${2:?缺少 SS 密码}
  local ss_port=${3:-8388}

  COMP=${COMPARTMENT_ID:-${OCI_TENANCY:?请在 Oracle Cloud Shell 里运行，或设置 COMPARTMENT_ID}}
  echo "区域：${OCI_REGION:-未知}"
  if [ "${OCI_REGION:-}" != "ap-singapore-1" ]; then
    echo "提示：当前 Cloud Shell 区域不是新加坡（ap-singapore-1）。免费实例只能建在主区域，继续使用当前区域。"
  fi

  if oci compute instance list --compartment-id "$COMP" --display-name "$NAME" \
      --lifecycle-state RUNNING --query 'data[0].id' --raw-output 2>/dev/null | grep -q ocid; then
    echo "已有运行中的 $NAME，不重复创建。要重建请先在控制台终止它。" >&2
    exit 1
  fi

  mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"
  [ -f "$HOME/.ssh/id_ed25519" ] || ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519"

  # Reality 密钥、UUID、short id 在这里生成，客户端链接不用再登录服务器去取。
  local tmp priv pub uuid sid
  tmp=$(mktemp -d)
  openssl genpkey -algorithm X25519 -outform DER -out "$tmp/k.der"
  priv=$(tail -c 32 "$tmp/k.der" | b64url)
  pub=$(openssl pkey -inform DER -in "$tmp/k.der" -pubout -outform DER | tail -c 32 | b64url)
  uuid=$(cat /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 8)
  USER_DATA="$tmp/cloud-init.sh"
  render_cloud_init "$(render_config "$gcp_ip" "$ss_port" "$ss_password" "$uuid" "$priv" "$sid" "$SNI")" >"$USER_DATA"

  echo "== 网络"
  local vcn rt sl igw
  vcn=$(find_or_create \
    "oci network vcn list --compartment-id '$COMP' --display-name vps-proxy-vcn --query 'data[0].id' --raw-output" \
    "oci network vcn create --compartment-id '$COMP' --display-name vps-proxy-vcn --cidr-blocks '[\"10.0.0.0/16\"]' --wait-for-state AVAILABLE --query 'data.id' --raw-output")
  igw=$(find_or_create \
    "oci network internet-gateway list --compartment-id '$COMP' --vcn-id '$vcn' --query 'data[0].id' --raw-output" \
    "oci network internet-gateway create --compartment-id '$COMP' --vcn-id '$vcn' --is-enabled true --display-name vps-proxy-igw --wait-for-state AVAILABLE --query 'data.id' --raw-output")
  rt=$(oci network vcn get --vcn-id "$vcn" --query 'data."default-route-table-id"' --raw-output)
  sl=$(oci network vcn get --vcn-id "$vcn" --query 'data."default-security-list-id"' --raw-output)
  oci network route-table update --rt-id "$rt" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" >/dev/null
  oci network security-list update --security-list-id "$sl" --force \
    --egress-security-rules '[{"destination":"0.0.0.0/0","protocol":"all"}]' \
    --ingress-security-rules '[
      {"source":"0.0.0.0/0","protocol":"1","icmpOptions":{"type":3,"code":4}},
      {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":22,"max":22}}},
      {"source":"0.0.0.0/0","protocol":"6","tcpOptions":{"destinationPortRange":{"min":443,"max":443}}},
      {"source":"0.0.0.0/0","protocol":"17","udpOptions":{"destinationPortRange":{"min":443,"max":443}}}]' >/dev/null
  SUBNET=$(find_or_create \
    "oci network subnet list --compartment-id '$COMP' --vcn-id '$vcn' --query 'data[0].id' --raw-output" \
    "oci network subnet create --compartment-id '$COMP' --vcn-id '$vcn' --cidr-block 10.0.0.0/24 --display-name vps-proxy-subnet --wait-for-state AVAILABLE --query 'data.id' --raw-output")

  AD=$(oci iam availability-domain list --compartment-id "$COMP" --query 'data[0].name' --raw-output)

  echo "== 实例（可能要几分钟）"
  local instance="" shape=${SHAPE:-A1}
  if [ "$shape" = "A1" ]; then
    # Ampere A1 免费额度 4 核 24G；这里只用 1 核 6G，剩下的留给你别的用途。新加坡经常「容量不足」。
    instance=$(launch VM.Standard.A1.Flex '{"ocpus":1,"memoryInGBs":6}') || {
      echo "A1 创建失败（多半是 Out of host capacity），改用 AMD 免费小鸡 VM.Standard.E2.1.Micro。"
      instance=""
    }
  fi
  [ -n "$instance" ] || instance=$(launch VM.Standard.E2.1.Micro "")

  local oracle_ip
  oracle_ip=$(oci compute instance list-vnics --instance-id "$instance" --query 'data[0]."public-ip"' --raw-output)
  rm -rf "$tmp"

  local link="vless://${uuid}@${oracle_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#VPS-proxy"
  umask 077
  cat >"$OUT_FILE" <<EOF
Oracle 公网 IP：$oracle_ip
客户端导入链接（v2rayN / v2rayNG / Shadowrocket / Hiddify / sing-box 均可）：
$link
EOF

  cat <<EOF

Oracle 中转机已创建：$oracle_ip（开机脚本还需要 1～3 分钟装好 sing-box）
客户端链接也存到了 $OUT_FILE：

$link

最后一步，回到 Google Cloud Shell 运行：

  bash gcp/lockdown.sh $oracle_ip

EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
