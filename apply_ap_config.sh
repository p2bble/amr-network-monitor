#!/bin/bash
# H3C WA6320 AP 일괄 설정 적용 스크립트
# 적용 내용:
#   - 802.11r (Fast BSS Transition) 활성화
#   - 802.11k (Neighbor Report) 활성화
#   - TKIP 제거
#   - Tx Power: Ch36~48 → 17dBm / Ch149~165 → 20dBm
#   - 약신호 클라이언트 kick (RSSI -80 이하)
#
# 실행: bash apply_ap_config.sh
# 사전 조건: sshpass 설치 (sudo apt install sshpass -y)

AP_USER="admin"
AP_PASS="sebang1234"
AP_BASE_IP="192.168.145"
AP_START=31   # AP-01: 192.168.145.31
AP_COUNT=15   # AP-15: 192.168.145.45

# 미운영 AP (스킵)
SKIP_APS="5 10 13"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=no"

# sshpass 설치 확인
if ! command -v sshpass &> /dev/null; then
echo "[ERROR] sshpass 미설치. 먼저 실행: sudo apt install sshpass -y"
exit 1
fi

echo "============================================"
echo " H3C WA6320 AP 설정 일괄 적용"
echo " 대상: AP-01 ~ AP-${AP_COUNT} (미운영 스킵: ${SKIP_APS})"
echo "============================================"
echo ""

SUCCESS=0
FAILED=0
SKIPPED=0

for i in $(seq 1 $AP_COUNT); do
AP_NUM=$(printf '%02d' $i)
AP_IP="${AP_BASE_IP}.$((AP_START + i - 1))"

# 미운영 AP 스킵
if echo "$SKIP_APS" | grep -qw "$i"; then
echo "[AP-${AP_NUM}] (${AP_IP}) SKIP — 미운영"
SKIPPED=$((SKIPPED + 1))
continue
fi

echo -n "[AP-${AP_NUM}] (${AP_IP}) 접속 중... "

# 연결 테스트
if ! sshpass -p "$AP_PASS" ssh $SSH_OPTS ${AP_USER}@${AP_IP} "display version" &>/dev/null; then
echo "FAIL — 접속 불가"
FAILED=$((FAILED + 1))
continue
fi
echo "OK"

# 채널 조회
CHANNEL=$(sshpass -p "$AP_PASS" ssh $SSH_OPTS ${AP_USER}@${AP_IP} \
"display interface WLAN-Radio1/0/1" 2>/dev/null \
| grep -i "Current channel\|channel " | grep -oE '\b(36|40|44|48|52|56|60|64|100|149|153|157|161|165)\b' | head -1)

if [ -z "$CHANNEL" ]; then
CHANNEL="unknown"
MAX_POWER=17
else
if [ "$CHANNEL" -le 48 ] 2>/dev/null; then
MAX_POWER=17
else
MAX_POWER=20
fi
fi

echo "    채널: Ch${CHANNEL} → max-power ${MAX_POWER}dBm 적용"

# 설정 적용
RESULT=$(sshpass -p "$AP_PASS" ssh $SSH_OPTS ${AP_USER}@${AP_IP} << EOF
system-view
wlan service-template 1
dot11r enable
dot11r over-ds enable
dot11k enable
undo cipher-suite tkip
quit
interface WLAN-Radio1/0/1
max-power ${MAX_POWER}
quit
wlan rrm
station-kick rssi -80
quit
save force
quit
EOF
)

if echo "$RESULT" | grep -qi "error\|invalid\|failed"; then
echo "    [WARN] 일부 명령 오류 발생:"
echo "$RESULT" | grep -i "error\|invalid\|failed" | sed 's/^/      /'
FAILED=$((FAILED + 1))
else
echo "    [OK] 설정 적용 완료"
SUCCESS=$((SUCCESS + 1))
fi

echo ""
done

echo "============================================"
echo " 결과: 성공 ${SUCCESS}대 / 실패 ${FAILED}대 / 스킵 ${SKIPPED}대"
echo "============================================"
