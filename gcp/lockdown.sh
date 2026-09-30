#!/bin/bash
# 在 Google Cloud Shell 里运行：让 GCP 出口机只接受 Oracle 中转机的连接。
#   bash gcp/lockdown.sh <Oracle 公网 IP>
set -euo pipefail

ORACLE_IP=${1:?用法：bash gcp/lockdown.sh <Oracle 公网 IP>}
gcloud compute firewall-rules update vps-proxy-allow-oracle --source-ranges="$ORACLE_IP/32"
echo "已收紧：只有 $ORACLE_IP 能连 GCP 出口机。"
