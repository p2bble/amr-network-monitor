#!/bin/bash
# ============================================================
# 서버 측 AP / 스위치 웹 TCP 프록시 설정
# 서버에서 실행: ssh -p 10022 clobot@10.10.150.119
# ============================================================
# 포트 매핑:
#   외부 9301~9315 → AP-01~15 (192.168.145.31~45) 포트 80
#   외부 9401      → SW-Main-01 (192.168.145.254)  포트 80
#   외부 9402~9404 → SW-PoE-01~03 (192.168.145.253~251) 포트 80
# ============================================================

set -e

echo "======================================================"
echo "  서버 AP / 스위치 웹 프록시 설정"
echo "======================================================"

# ── nginx stream 설정 파일 생성 ────────────────────────────
sudo tee /home/clobot/amr_deploy/nginx_infra_stream.conf > /dev/null << 'NGINX_EOF'
stream {
    # ── AP 웹 UI (AP-01~15: 192.168.145.31~45 :80) ──────────
    server { listen 9301; proxy_pass 192.168.145.31:80; }
    server { listen 9302; proxy_pass 192.168.145.32:80; }
    server { listen 9303; proxy_pass 192.168.145.33:80; }
    server { listen 9304; proxy_pass 192.168.145.34:80; }
    server { listen 9305; proxy_pass 192.168.145.35:80; }
    server { listen 9306; proxy_pass 192.168.145.36:80; }
    server { listen 9307; proxy_pass 192.168.145.37:80; }
    server { listen 9308; proxy_pass 192.168.145.38:80; }
    server { listen 9309; proxy_pass 192.168.145.39:80; }
    server { listen 9310; proxy_pass 192.168.145.40:80; }
    server { listen 9311; proxy_pass 192.168.145.41:80; }
    server { listen 9312; proxy_pass 192.168.145.42:80; }
    server { listen 9313; proxy_pass 192.168.145.43:80; }
    server { listen 9314; proxy_pass 192.168.145.44:80; }
    server { listen 9315; proxy_pass 192.168.145.45:80; }

    # ── 스위치 웹 UI ─────────────────────────────────────────
    server { listen 9401; proxy_pass 192.168.145.254:80; }  # SW-Main-01
    server { listen 9402; proxy_pass 192.168.145.253:80; }  # SW-PoE-01
    server { listen 9403; proxy_pass 192.168.145.252:80; }  # SW-PoE-02
    server { listen 9404; proxy_pass 192.168.145.251:80; }  # SW-PoE-03
}
NGINX_EOF

echo "[1] nginx stream 설정 파일 생성 완료"

# ── 기존 nginx-shell 컨테이너 확인 / 신규 컨테이너 실행 ───
if docker ps -a --format '{{.Names}}' | grep -q "^amr-infra-proxy$"; then
    echo "[2] 기존 amr-infra-proxy 컨테이너 제거..."
    docker rm -f amr-infra-proxy
fi

echo "[2] amr-infra-proxy 컨테이너 시작..."
docker run -d \
    --name amr-infra-proxy \
    --restart unless-stopped \
    --network host \
    -v /home/clobot/amr_deploy/nginx_infra_stream.conf:/etc/nginx/nginx.conf:ro \
    nginx:alpine

echo "[2] 컨테이너 시작 완료"

# ── 포트 수신 확인 ──────────────────────────────────────────
sleep 2
echo ""
echo "[3] 포트 수신 확인 (9301 / 9401)..."
if ss -tlnp 2>/dev/null | grep -E "9301|9401" | head -4; then
    echo "    포트 수신 정상"
else
    echo "    ※ ss 명령 없음 - docker logs 확인:"
    docker logs amr-infra-proxy --tail 10
fi

echo ""
echo "======================================================"
echo "  완료! 접속 가능 포트:"
echo "  AP-01~15  : 서버IP:9301~9315"
echo "  SW-Main   : 서버IP:9401"
echo "  SW-PoE-01 : 서버IP:9402"
echo "  SW-PoE-02 : 서버IP:9403"
echo "  SW-PoE-03 : 서버IP:9404"
echo "======================================================"
