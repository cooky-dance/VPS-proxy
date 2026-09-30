#!/bin/bash
# 在任意一台 Debian / Ubuntu VPS 上以 root 运行：装好 VLESS + Reality，直接从这台机器出网。
#   bash single-vps/setup.sh
# 可用环境变量覆盖：SNI（Reality 伪装站点，默认 www.microsoft.com）、PORT（默认 443）。
set -euo pipefail

SING_BOX_VERSION=1.12.9
SNI=${SNI:-www.microsoft.com}
PORT=${PORT:-443}

render_config() { # $1=端口 $2=UUID $3=Reality 私钥 $4=short id $5=SNI
  cat <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "local", "tag": "local"}]},
  "inbounds": [
    {"type": "vless", "tag": "from-client", "listen": "::", "listen_port": $1,
     "users": [{"uuid": "$2", "flow": "xtls-rprx-vision"}],
     "tls": {"enabled": true, "server_name": "$5",
             "reality": {"enabled": true, "handshake": {"server": "$5", "server_port": 443},
                         "private_key": "$3", "short_id": ["$4"]}}}
  ],
  "outbounds": [{"type": "direct", "tag": "direct"}],
  "route": {
    "default_domain_resolver": "local",
    "rules": [
      {"ip_is_private": true, "action": "reject"},
      {"ip_cidr": ["169.254.0.0/16"], "action": "reject"}
    ],
    "final": "direct"
  }
}
EOF
}

main() {
  [ "$(id -u)" -eq 0 ] || { echo "请用 root 运行（sudo -i 之后再执行）。" >&2; exit 1; }

  export DEBIAN_FRONTEND=noninteractive
  command -v curl >/dev/null || { apt-get update -q && apt-get install -y -q curl; }

  if [ "$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')" != "$SING_BOX_VERSION" ]; then
    local arch
    arch=$(dpkg --print-architecture)
    curl -fsSL -o /tmp/sing-box.deb \
      "https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/sing-box_${SING_BOX_VERSION}_${arch}.deb"
    dpkg -i /tmp/sing-box.deb
  fi

  cat >/etc/sysctl.d/90-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
  sysctl -q --system

  # 已经装过就沿用原来的密钥，客户端链接不变。
  local state=/etc/sing-box/vps-proxy.env uuid priv pub sid
  if [ -f "$state" ]; then
    # shellcheck disable=SC1090
    . "$state"
  else
    uuid=$(sing-box generate uuid)
    local keys
    keys=$(sing-box generate reality-keypair)
    priv=$(awk '/PrivateKey/{print $2}' <<<"$keys")
    pub=$(awk '/PublicKey/{print $2}' <<<"$keys")
    sid=$(sing-box generate rand --hex 8)
    install -d -m 700 /etc/sing-box
    printf 'uuid=%s\npriv=%s\npub=%s\nsid=%s\n' "$uuid" "$priv" "$pub" "$sid" >"$state"
    chmod 600 "$state"
  fi

  install -d /etc/sing-box
  render_config "$PORT" "$uuid" "$priv" "$sid" "$SNI" >/etc/sing-box/config.json
  chmod 600 /etc/sing-box/config.json
  sing-box check -c /etc/sing-box/config.json

  # 系统防火墙开着的话放行端口（ufw 或 Oracle 镜像那种 iptables REJECT 规则）。
  if command -v ufw >/dev/null && ufw status | grep -q 'Status: active'; then
    ufw allow "$PORT/tcp"
  elif iptables -S INPUT 2>/dev/null | grep -q -- '-j REJECT'; then
    iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$PORT" -j ACCEPT
    command -v netfilter-persistent >/dev/null && netfilter-persistent save
  fi

  systemctl enable sing-box
  systemctl restart sing-box

  local ip
  ip=$(curl -fsS4 -m 10 https://api.ipify.org || hostname -I | awk '{print $1}')
  local link="vless://${uuid}@${ip}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${pub}&sid=${sid}&type=tcp&headerType=none#VPS-proxy"
  umask 077
  echo "$link" >/root/vps-proxy-client.txt

  cat <<EOF

已装好。客户端导入链接（也存到了 /root/vps-proxy-client.txt）：

$link

如果服务商控制台有「防火墙 / 安全组」，记得放行 TCP $PORT。
EOF
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
