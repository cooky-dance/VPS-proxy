#!/bin/bash
# GCP 出口机的启动脚本（通过实例元数据 startup-script 注入，每次开机以 root 运行，可重复执行）。
# 读取元数据：ss-password、ss-port、traffic-limit-gib。
set -euo pipefail

SING_BOX_VERSION=1.12.9

md() {
  curl -fsS -H 'Metadata-Flavor: Google' \
    "http://metadata.google.internal/computeMetadata/v1/instance/attributes/$1"
}

render_config() { # $1=端口 $2=密码
  cat <<EOF
{
  "log": {"level": "warn"},
  "dns": {"servers": [{"type": "local", "tag": "local"}]},
  "inbounds": [
    {"type": "shadowsocks", "tag": "from-oracle", "listen": "::", "listen_port": $1,
     "method": "2022-blake3-aes-128-gcm", "password": "$2"}
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

install_guard() { # $1=上限 GiB
  cat >/usr/local/sbin/traffic-guard <<'EOF'
#!/bin/bash
# 本月（太平洋时间，与 Google 账单月一致）出站超过上限就停掉 sing-box；下个月自动恢复。
set -euo pipefail
LIMIT_GIB=$(cat /etc/traffic-limit-gib)
IFACE=$(ip route show default | awk '{print $5; exit}')
TX=$(vnstat -i "$IFACE" --json m 2>/dev/null | jq --argjson y "$(date +%Y)" --argjson m "$(date +%-m)" \
  '[.interfaces[0].traffic.month[]? | select(.date.year == $y and .date.month == $m) | .tx] | add // 0' || true)
TX=${TX:-0}
LIMIT=$((LIMIT_GIB * 1024 * 1024 * 1024))
if [ "$TX" -ge "$LIMIT" ]; then
  if systemctl is-active --quiet sing-box; then
    logger -t traffic-guard "本月出站 $((TX / 1073741824)) GiB，已达上限 ${LIMIT_GIB} GiB，停止 sing-box"
    systemctl stop sing-box
  fi
else
  systemctl is-active --quiet sing-box || systemctl start sing-box
fi
EOF
  chmod 755 /usr/local/sbin/traffic-guard
  echo "$1" >/etc/traffic-limit-gib

  cat >/etc/systemd/system/traffic-guard.service <<'EOF'
[Unit]
Description=Stop sing-box when monthly egress reaches the limit
After=vnstat.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/traffic-guard
EOF
  cat >/etc/systemd/system/traffic-guard.timer <<'EOF'
[Unit]
Description=Check monthly egress every 5 minutes

[Timer]
OnBootSec=1min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
}

main() {
  local port pass limit arch
  port=$(md ss-port)
  pass=$(md ss-password)
  limit=$(md traffic-limit-gib || echo 180)

  # Google 账单按太平洋时间划分月份，vnstat 的月份跟着系统时区走。
  timedatectl set-timezone America/Los_Angeles

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v vnstat >/dev/null || ! command -v jq >/dev/null; then
    apt-get update -q
    apt-get install -y -q vnstat jq
  fi
  systemctl enable --now vnstat

  if [ "$(sing-box version 2>/dev/null | awk 'NR==1{print $3}')" != "$SING_BOX_VERSION" ]; then
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

  install -d /etc/sing-box
  render_config "$port" "$pass" >/etc/sing-box/config.json
  chmod 600 /etc/sing-box/config.json
  sing-box check -c /etc/sing-box/config.json

  install_guard "$limit"
  systemctl daemon-reload
  systemctl enable sing-box traffic-guard.timer
  systemctl restart sing-box
  systemctl start traffic-guard.timer
  /usr/local/sbin/traffic-guard
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
