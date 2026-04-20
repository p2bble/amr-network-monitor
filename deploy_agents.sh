#!/bin/bash
# deploy_agents.sh
# 로봇 PC 13대에 amr_unified_agent.py 배포 (MOXA SSH jump host 경유)
#
# 전제:
#   - MOXA SSH 접근: ssh MOXA_USER@192.168.145.5x
#   - 로봇 PC IP: 192.167.140.2 (MOXA LAN 측 고정)
#   - 로봇 PC SSH: ssh clobot@192.167.140.2 (MOXA 경유)
#   - 로봇 PC 배포 경로: /home/clobot/wifi_agent/amr_unified_agent.py
#
# 사용법:
#   chmod +x deploy_agents.sh
#   ./deploy_agents.sh
#
# 특정 로봇만 배포:
#   ./deploy_agents.sh 51 52 53

# ────────── 설정 ──────────────────────────────────────────────
MOXA_USER="admin"                    # MOXA SSH 사용자 (변경 필요시 수정)
MOXA_BASE="192.168.145"
ROBOT_USER="clobot"                  # 로봇 PC SSH 사용자
ROBOT_LAN_IP="192.167.140.2"         # 로봇 PC LAN IP (MOXA 뒤편)
REMOTE_DIR="/home/clobot/wifi_agent"
LOCAL_FILE="$(dirname "$0")/amr_unified_agent.py"
SERVICE_NAME="amr-agent"
# ─────────────────────────────────────────────────────────────

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes"
PASS_FAIL=()

# 인자 없으면 전체 51~63, 인자 있으면 지정 번호만
if [ $# -gt 0 ]; then
    TARGETS=("$@")
else
    TARGETS=(51 52 53 54 55 56 57 58 59 60 61 62 63)
fi

echo "========================================"
echo " AMR Agent 배포 시작 ($(date '+%Y-%m-%d %H:%M:%S'))"
echo " 대상: ${#TARGETS[@]}대"
echo "========================================"

for LAST in "${TARGETS[@]}"; do
    MOXA_IP="${MOXA_BASE}.${LAST}"
    IDX=$((LAST - 50))
    ROBOT_ID=$(printf "sebang%03d" $IDX)

    echo ""
    echo "──────────────────────────────────────"
    echo "[$ROBOT_ID] MOXA: $MOXA_IP  →  Robot: $ROBOT_LAN_IP"
    echo "──────────────────────────────────────"

    # 1. 파일 복사 (MOXA jump host 경유)
    echo "  [1/3] 파일 복사 중..."
    scp $SSH_OPTS \
        -o "ProxyJump ${MOXA_USER}@${MOXA_IP}" \
        "$LOCAL_FILE" \
        "${ROBOT_USER}@${ROBOT_LAN_IP}:${REMOTE_DIR}/amr_unified_agent.py" 2>&1
    if [ $? -ne 0 ]; then
        echo "  [ERROR] SCP 실패 → 스킵"
        PASS_FAIL+=("FAIL: $ROBOT_ID ($MOXA_IP)")
        continue
    fi

    # 2. ROBOT_ID 교체 및 서비스 재시작
    echo "  [2/3] ROBOT_ID 교체 및 서비스 재시작..."
    ssh $SSH_OPTS \
        -J "${MOXA_USER}@${MOXA_IP}" \
        "${ROBOT_USER}@${ROBOT_LAN_IP}" \
        bash -s << ENDSSH
set -e
# ROBOT_ID 교체
sed -i 's/^ROBOT_ID.*/ROBOT_ID    = "${ROBOT_ID}"            # 로봇별 배포 시 변경/' ${REMOTE_DIR}/amr_unified_agent.py
echo "  ROBOT_ID → $(grep '^ROBOT_ID' ${REMOTE_DIR}/amr_unified_agent.py)"

# 서비스 재시작
sudo systemctl restart ${SERVICE_NAME}
sleep 2
sudo systemctl is-active ${SERVICE_NAME} && echo "  서비스: 정상 실행 중" || echo "  서비스: 시작 실패"
ENDSSH

    if [ $? -eq 0 ]; then
        echo "  [3/3] 완료"
        PASS_FAIL+=("OK:   $ROBOT_ID ($MOXA_IP)")
    else
        echo "  [ERROR] 원격 실행 실패"
        PASS_FAIL+=("FAIL: $ROBOT_ID ($MOXA_IP)")
    fi
done

# ── 결과 요약 ─────────────────────────────────────────────────
echo ""
echo "========================================"
echo " 배포 결과 요약"
echo "========================================"
for r in "${PASS_FAIL[@]}"; do echo "  $r"; done
echo "========================================"
