#!/bin/bash
# 在 Google Cloud Shell 里运行：创建美国出口机（免费 e2-micro + Standard Tier 公网 IP）。
#   bash gcp/setup.sh
# 可用环境变量覆盖：ZONE（默认 us-west1-b）、NAME、SS_PORT、TRAFFIC_LIMIT_GIB、BUDGET。
set -euo pipefail

ZONE=${ZONE:-us-west1-b}
REGION=${ZONE%-*}
NAME=${NAME:-vps-proxy-exit}
SS_PORT=${SS_PORT:-8388}
TRAFFIC_LIMIT_GIB=${TRAFFIC_LIMIT_GIB:-180}
BUDGET=${BUDGET:-1USD}
FW_RULE=vps-proxy-allow-oracle
HERE=$(cd "$(dirname "$0")" && pwd)

case "$REGION" in
  us-west1|us-central1|us-east1) ;;
  *) echo "免费 e2-micro 只在 us-west1 / us-central1 / us-east1，当前 ZONE=$ZONE" >&2; exit 1 ;;
esac

PROJECT=$(gcloud config get-value project 2>/dev/null)
if [ -z "$PROJECT" ]; then
  echo "先选项目：gcloud config set project <项目ID>" >&2
  exit 1
fi
BILLING=$(gcloud billing projects describe "$PROJECT" --format='value(billingAccountName)')
if [ -z "$BILLING" ]; then
  echo "项目 $PROJECT 还没关联结算账号，先在控制台「结算」里关联。" >&2
  exit 1
fi
echo "项目：$PROJECT  区域：$ZONE"

gcloud services enable compute.googleapis.com billingbudgets.googleapis.com

# 以后新建的公网 IP 默认也走 Standard Tier（Premium 的免费额度只有 1 GB，且不含中国和澳大利亚）。
gcloud compute project-info update --default-network-tier=STANDARD

if ! gcloud compute firewall-rules describe "$FW_RULE" >/dev/null 2>&1; then
  # 先对所有来源开放（Shadowsocks 2022 有密钥认证），Oracle 建好后用 gcp/lockdown.sh 收紧到 Oracle 的 IP。
  gcloud compute firewall-rules create "$FW_RULE" --network=default --direction=INGRESS \
    --action=allow --rules="tcp:$SS_PORT,udp:$SS_PORT" --source-ranges=0.0.0.0/0 \
    --target-tags=vps-proxy-exit
fi

if gcloud compute instances describe "$NAME" --zone="$ZONE" >/dev/null 2>&1; then
  echo "实例 $NAME 已存在，沿用它的密码。"
  SS_PASSWORD=$(gcloud compute instances describe "$NAME" --zone="$ZONE" \
    --format='value(metadata.items.ss-password)')
else
  SS_PASSWORD=$(openssl rand -base64 16)
  gcloud compute instances create "$NAME" --zone="$ZONE" \
    --machine-type=e2-micro \
    --network-tier=STANDARD \
    --image-family=debian-12 --image-project=debian-cloud \
    --boot-disk-size=30GB --boot-disk-type=pd-standard \
    --tags=vps-proxy-exit \
    --metadata="ss-password=$SS_PASSWORD,ss-port=$SS_PORT,traffic-limit-gib=$TRAFFIC_LIMIT_GIB" \
    --metadata-from-file=startup-script="$HERE/startup.sh"
fi

TIER=$(gcloud compute instances describe "$NAME" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].networkTier)')
GCP_IP=$(gcloud compute instances describe "$NAME" --zone="$ZONE" \
  --format='value(networkInterfaces[0].accessConfigs[0].natIP)')
if [ "$TIER" != "STANDARD" ]; then
  echo "警告：$NAME 的公网 IP 是 $TIER，不是 STANDARD，出站会按 Premium 计费！" >&2
fi

# 预算提醒：只发邮件，不会自动停机（停机靠机器上的 traffic-guard）。
if ! gcloud billing budgets list --billing-account="${BILLING#billingAccounts/}" \
    --format='value(displayName)' 2>/dev/null | grep -qx 'vps-proxy'; then
  gcloud billing budgets create --billing-account="${BILLING#billingAccounts/}" \
    --display-name=vps-proxy --budget-amount="$BUDGET" \
    --filter-projects="projects/$PROJECT" \
    --threshold-rule=percent=0.01 --threshold-rule=percent=0.5 --threshold-rule=percent=1.0 \
    || echo "预算提醒没建成（结算币种不是 USD 时用 BUDGET=7CNY 这类写法重跑），可以在控制台「结算 → 预算和提醒」里手动建。" >&2
fi

cat <<EOF

GCP 出口机已创建（开机脚本需要 1～3 分钟装好 sing-box）。
下一步在 Oracle Cloud Shell 里运行：

  bash oracle/setup.sh $GCP_IP '$SS_PASSWORD' $SS_PORT

EOF
