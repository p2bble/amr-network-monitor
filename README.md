# AMR Network Monitor

AMR(Autonomous Mobile Robot)의 무선 네트워크 상태를 실시간으로 모니터링하는 시스템입니다.
로봇 탑재 Python 에이전트가 MQTT로 상태를 전송하고, Flutter 웹/앱이 이를 시각화합니다.

---

## 시스템 구성

```
[로봇 미니PC]                     [메인 서버 192.168.145.5]                [관제 단말]
amr_unified_agent.py              EMQX :1883 (TCP)
     (Python)         →  MQTT  →  EMQX :8083 (WebSocket)     →  amr_monitor (웹 브라우저)
  MOXA_IP=192.167.140.1           nginx :9090 (/mqtt 프록시)
  eth0 → MOXA → WiFi → AP        moxa_snmp_poller.py (서버사이드)
                                  infra_monitor.py   (AP/SW 상태)
```

### 구성 요소

| 구성 요소 | 위치 | 설명 |
|-----------|------|------|
| `amr_unified_agent.py` | 로봇 | Python 모니터링 에이전트 |
| `amr-agent.service` | 로봇 | systemd 자동재시작 서비스 |
| `moxa_snmp_poller.py` | 서버 | MOXA SNMP 서버사이드 폴러 |
| `moxa-poller.service` | 서버 | moxa_snmp_poller systemd 서비스 |
| `infra_monitor.py` | 서버 | AP/스위치 인프라 상태 모니터 |
| `infra-monitor.service` | 서버 | infra_monitor systemd 서비스 |
| `amr_diagnostics.py` | 서버 | 자동 장애 진단 서비스 (크로스 로봇 분석) |
| `amr-diagnostics.service` | 서버 | amr_diagnostics systemd 서비스 |
| `amr_monitor/` | 서버 | Flutter 관제 웹 앱 |

### 에이전트 동작 모드

- **NATIVE 모드**: 로봇 내장 USB WiFi(`iw dev link`)로 직접 상태 수집 (`MOXA_IP = ""`)
- **MOXA 모드**: 서버사이드 SNMP 폴러(`moxa_snmp_poller.py`)가 MOXA에서 데이터 수집 후 MQTT 발행
  → 로봇 에이전트는 `infra_test/moxa/{ROBOT_ID}` 토픽을 구독해 수신

---

## MOXA 서버사이드 SNMP 폴러

### 아키텍처

```
서버(192.168.145.5)
  └─ moxa_snmp_poller.py
       ├─ SNMP GET → 192.168.145.51 (MOXA-01)
       ├─ SNMP GET → 192.168.145.52 (MOXA-02)
       │   ...
       └─ SNMP GET → 192.168.145.63 (MOXA-13)
            ↓ MQTT publish
       infra_test/moxa/sebang001~013

로봇 에이전트
  └─ MQTT subscribe infra_test/moxa/{ROBOT_ID}
       ↓ 수신 데이터 사용
  └─ MQTT publish infra_test/network_status/{ROBOT_ID}
```

### 수집 OID (1.11.17.1 live status 테이블 — AWK-1137C 확인)

| 데이터 | OID |
|--------|-----|
| 채널 (현재 연결) | `1.3.6.1.4.1.8691.15.35.1.11.17.1.2.1.1` |
| BSSID | `1.3.6.1.4.1.8691.15.35.1.11.17.1.3.1.1` |
| RSSI (dBm) | `1.3.6.1.4.1.8691.15.35.1.11.17.1.4.1.1` |
| 전송속도 (Mbps) | `1.3.6.1.4.1.8691.15.35.1.11.17.1.5.1.1` |
| SSID | `1.3.6.1.4.1.8691.15.35.1.11.17.1.6.1.1` |
| SNR (dB) | `1.3.6.1.4.1.8691.15.35.1.11.17.1.11.1.1` |
| Noise floor (dBm) | `1.3.6.1.4.1.8691.15.35.1.11.17.1.12.1.1` |

> **주의**: 과거 사용하던 OID (1.5.1.1.2.1 채널, 1.5.3.1.2.1 SSID)는 설정값 기반으로
> 현재 연결 상태를 반영하지 않음. 반드시 1.11.17.1 테이블 사용.

### MOXA SNMP 활성화

1. MOXA 웹 UI 접속: `http://172.16.200.99:9201` (AMR-01 기준)
2. Advanced Setup → SNMP Agent → **Enable**
3. Submit → **Save Configuration** (재부팅 후에도 유지)

| AMR | MOXA 웹 UI | SNMP 상태 |
|-----|-----------|---------|
| 01~09 | http://172.16.200.99:9201~9209 | ✅ 활성화 완료 |
| 10~13 | http://172.16.200.99:9210~9213 | ⚠️ 재부팅 후 활성화 예정 |

---

## 관제 앱 주요 기능

### 실시간 모니터링
- RSSI / Ping 실시간 표시 (SNMP 실측값, 1초 갱신)
- BSSID / SSID / 채널 / SNR / Noise floor / 전송속도
- 전체 현황 배너 (상단 스크롤 — 음영구간 로봇 강조)
- AP 상태 배지 (AP-01~15, WiFi-OFF 표시)

### 자동 장애 진단

**클라이언트 진단** (대시보드 열람 중에만 동작)

| 계층 | 진단 기준 |
|------|-----------|
| RF/AP | RSSI < -75 dBm (WARN) / < -85 dBm 3회 연속 (CRIT) |
| MOXA | SNMP 무응답 → Ch Error / RSSI N/A |
| GW Ping | 100 ms 초과 (WARN) / 500 ms 초과 (CRIT) |
| 에이전트 | 30초 이상 무응답 (CRIT) |
| TX Retry | 20% 이상 (간섭 의심) / 30% 이상 (심각) — 동일 AP 타 로봇 비교로 국소/공통 분류 |

**서버 자동 진단** (`amr_diagnostics.py` — 24/7 상시 동작, 10초 주기)

| 패턴 | 진단 | 설명 |
|------|------|------|
| 에이전트 60초 무응답 | `agent` | 에이전트 크래시 / 전원 이상 |
| RSSI < -75 + 10분간 로밍 없음 | `moxa` | MOXA 로밍 고착 |
| RSSI < -85 | `ap` | AP 음영구간 |
| 동일 BSSID 2대 이상 동시 이상 | `ap` | AP 장애 의심 |
| 동일 채널 3대 이상 동시 이상 | `channel` | 채널 간섭 의심 |
| 온라인 로봇 50% 이상 동시 이상 | `backbone` | 서버·백본 스위치 장애 |
| Ping > 500 ms | `network` | 네트워크 심각 지연 |

- 결과는 `infra_test/diagnosis/summary` 및 `infra_test/diagnosis/{robot_id}` MQTT 토픽으로 발행
- 대시보드 상단에 빨간 배너로 실시간 표시 (크로스 진단 + 오프라인 목록)
- 로그 영구 보존: `/home/clobot/amr_deploy/logs/diagnostics.log` (50MB 롤오버)

### UI 뷰 모드
- **테이블 뷰** (기본): 로봇ID / 진단상태 / RSSI / Retry / Ping / 채널 / 마지막수신
- **카드 뷰**: 로봇별 상세 카드

---

## 임계값 기준

| 구분 | 임계값 | 판정 |
|------|--------|------|
| RSSI 약함 | -75 dBm 이하 | WARN |
| RSSI 불량 (음영) | -85 dBm 이하 3회 연속 | CRIT |
| Ping 지연 | 100 ms 이상 | WARN |
| Ping 심각 | 500 ms 이상 | CRIT |
| 에이전트 무응답 | 30초 이상 | CRIT |

---

## 세방 현장 배포 가이드

### 인프라 정보

| 구분 | 내용 |
|------|------|
| 메인 서버 | 192.168.145.5 (내부) / 10.10.150.119 (외부노출) |
| VPN 게이트웨이 | 172.16.200.99 (담당자 노트북) |
| 서버 SSH | `ssh -p 10022 clobot@172.16.200.99` |
| 웹 대시보드 | http://172.16.200.99:9090 (원격) / http://192.168.145.5:9090 (현장) |
| EMQX 관리콘솔 | http://192.168.145.5:18083 (admin/public) |
| MQTT 인증 | cloud / zmfhatm*0 |

### AMR 로봇 정보

| 구분 | 내용 |
|------|------|
| 로봇 수 | 13대 (sebang001~013) |
| 내부 IP | 192.168.145.51~63 |
| SSH 유저 | `thira` |
| SSH(원격) | `ssh -p 9101~9113 thira@172.16.200.99` |
| SSH(현장) | `ssh thira@192.168.145.51~63` |
| 에이전트 경로 | `/home/thira/wifi_agent/amr_unified_agent.py` |
| 서비스 | `sudo systemctl status amr-agent` |
| MQTT 토픽(송신) | `infra_test/network_status/sebang001~013` |
| MQTT 토픽(수신) | `infra_test/moxa/sebang001~013` |

### MOXA 정보

| 구분 | 내용 |
|------|------|
| 모델 | AWK-1137C |
| 로봇↔MOXA | eth0(192.167.140.2) → MOXA LAN(192.167.140.1) |
| MOXA WiFi IP | 192.168.145.51~63 (로봇과 1:1) |
| MOXA 웹(원격) | http://172.16.200.99:9201~9213 |
| SNMP 설정 | community: public / V1, V2c / Enable + Save Configuration |

### 네트워크 인프라 (2층)

| 구분 | IP / 채널 |
|------|-----------|
| 메인 스위치 | 192.168.145.254 |
| PoE 스위치 #1~3 | 192.168.145.251~253 |
| AP #01~15 | 192.168.145.31~45 |
| AP 채널 | Ch 36(AP1,3,15) / Ch 149(AP7,9) / Ch 157(AP2,4,11,14) / Ch 161(AP6,8,12) |
| 미운영 AP | #05, #10, #13 |

---

## 1. 서버 서비스 배포/관리

### 서비스 상태 확인

```bash
sudo systemctl status infra-monitor moxa-poller amr-diagnostics
```

### 서비스 재시작

```bash
sudo systemctl restart moxa-poller
sudo systemctl restart infra-monitor
sudo systemctl restart amr-diagnostics
```

### 로그 확인

```bash
sudo journalctl -u moxa-poller -n 30 --no-pager
sudo journalctl -u infra-monitor -n 30 --no-pager
sudo journalctl -u amr-diagnostics -n 30 --no-pager
# 진단 이력 파일
tail -f /home/clobot/amr_deploy/logs/diagnostics.log
```

### 파일 위치 (서버)

```
/home/clobot/amr_deploy/
  ├── amr_unified_agent.py      # 로봇 에이전트 (배포용 원본)
  ├── moxa_snmp_poller.py       # MOXA SNMP 폴러
  ├── infra_monitor.py          # AP/스위치 인프라 모니터
  ├── amr_diagnostics.py        # 자동 장애 진단 서비스
  ├── moxa-poller.service       # (참고용)
  ├── infra-monitor.service     # (참고용)
  └── amr-diagnostics.service   # (참고용)
```

### `amr-diagnostics.service` 신규 배포

```bash
scp -P 10022 amr_diagnostics.py clobot@10.10.150.119:/home/clobot/amr_deploy/
scp -P 10022 amr-diagnostics.service clobot@10.10.150.119:/tmp/
sudo cp /tmp/amr-diagnostics.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable amr-diagnostics
sudo systemctl start amr-diagnostics
```

---

## 2. 로봇 에이전트 배포 (서버에서 실행)

```bash
for i in $(seq 1 13); do
ROBOT_IP="192.168.145.$((50+i))"
ROBOT_ID=$(printf "sebang%03d" $i)
sed "s/ROBOT_ID    = \"HD-BaseAir-002\"/ROBOT_ID    = \"${ROBOT_ID}\"/" \
/home/clobot/amr_deploy/amr_unified_agent.py > /tmp/agent_deploy.py
scp -o StrictHostKeyChecking=no /tmp/agent_deploy.py \
thira@${ROBOT_IP}:/home/thira/wifi_agent/amr_unified_agent.py
ssh -o StrictHostKeyChecking=no thira@${ROBOT_IP} "sudo systemctl restart amr-agent"
echo "$ROBOT_ID 완료"
done
```

### 주요 설정값 (`amr_unified_agent.py`)

```python
SERVER_IP   = "192.168.145.5"
MOXA_IP     = "192.167.140.1"   # 설정 시 MOXA 모드 자동 전환
ROBOT_ID    = "sebang001"        # 로봇마다 변경
MQTT_BROKER = "192.168.145.5"
LAN_IFACE   = "eth0"
```

### paho-mqtt 버전 이슈 (중요)

로봇마다 paho-mqtt 버전이 다름 (1.5.1 / 2.x 혼재). 에이전트 코드에 이미 호환 처리됨:

```python
try:
    client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=f"agent_{ROBOT_ID}")
except AttributeError:
    client = mqtt.Client(client_id=f"agent_{ROBOT_ID}")
```

paho 미설치 시 — 다른 로봇에서 복사:

```bash
ssh thira@192.168.145.51 "tar czf /tmp/paho.tar.gz -C /usr/lib/python3/dist-packages paho"
scp thira@192.168.145.51:/tmp/paho.tar.gz /tmp/
scp /tmp/paho.tar.gz thira@192.168.145.62:/tmp/
ssh thira@192.168.145.62 "sudo tar xzf /tmp/paho.tar.gz -C /usr/lib/python3/dist-packages/"
```

---

## 3. 웹 대시보드 배포 (서버)

### Flutter 웹 빌드 (로컬 PC)

```powershell
cd amr_monitor
flutter clean
flutter pub get
flutter build web --release
scp -P 10022 -r build\web clobot@172.16.200.99:/home/clobot/amr_deploy/
```

### nginx 컨테이너 실행 (서버)

```bash
docker run -d \
  --name amr-monitor \
  --restart unless-stopped \
  -p 9090:80 \
  -v /home/clobot/amr_deploy/web:/usr/share/nginx/html:ro \
  -v /home/clobot/amr_deploy/nginx.conf:/etc/nginx/conf.d/default.conf:ro \
  nginx:alpine
```

> **MQTT WebSocket**: 브라우저 → `ws://host:9090/mqtt` → nginx → `172.17.0.1:8083` (EMQX)
> 8083 포트 별도 포워딩 불필요

---

## 트러블슈팅

### RSSI N/A 또는 Ch Error 표시
→ MOXA SNMP 미활성화. MOXA 웹 UI에서 Enable 후 Save Configuration, 재부팅 필요.

### 에이전트 실패 (status=FAILURE)
```bash
ssh thira@192.168.145.51 "sudo journalctl -u amr-agent -n 20 --no-pager"
```
- `TypeError: callback_api_version` → paho 2.x, 코드 이미 호환 처리됨 → 최신 에이전트 재배포
- `ModuleNotFoundError: paho` → paho 미설치 → 다른 로봇에서 tar 복사

### moxa-poller 확인
```bash
sudo journalctl -u moxa-poller -n 30 --no-pager
# 정상: ch=36 rssi=-55dBm snr=43
# 이상: SNMP timeout → 해당 MOXA SNMP 미활성
```

### MQTT 실시간 확인
```bash
mosquitto_sub -h 192.168.145.5 -p 1883 -u cloud -P 'zmfhatm*0' \
  -t 'infra_test/moxa/#' -v -C 5
```

### EMQX 연결 클라이언트 확인
```bash
curl -s -u admin:public "http://localhost:8081/api/v4/clients?page_size=50" | \
  python3 -c "import json,sys; d=json.load(sys.stdin); ids=[c['clientid'] for c in d.get('data',[])]; print(str(len(ids))+'개:'); [print(' ',c) for c in sorted(ids)]"
```

---

## 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-04-05 | `amr_diagnostics.py` 추가 — 서버 24/7 자동 진단 서비스 (크로스 로봇 패턴 분석) |
| 2026-04-05 | 대시보드 상단 글로벌 진단 배너 추가 (cross_faults, 오프라인 목록 실시간 표시) |
| 2026-04-05 | `amr-diagnostics.service` systemd 서비스 파일 추가 |
| 2026-04-03 | MOXA Device Reboot 비활성화, 로밍 임계값 -70dBm, 로밍 차이 8dBm 설정 |
| 2026-04-03 | MOXA 1.11.17.1 OID 발견 — RSSI/채널/SNR/Noise 실측값 수집 가능 확인 |
| 2026-04-03 | moxa_snmp_poller.py OID 전면 교체 (1.5.x 설정값 → 1.11.17.1 live 테이블) |
| 2026-04-03 | 서버사이드 MOXA 폴러 아키텍처 도입 (moxa-poller.service 배포) |
| 2026-04-03 | 로봇 에이전트 MOXA 데이터 수신 구조 변경 (로컬 SNMP → MQTT 구독) |
| 2026-04-02 | 세방 현장 배포 완료 (sebang001~013, 13대) |
| 2026-04-02 | nginx /mqtt WebSocket 프록시 방식 적용 (포트 9090 단일화) |
| 2026-04-02 | Flutter broker URL 동적화 (Uri.base.host/port) |
| 2026-04-02 | MOXA 환경 대응 — 순수 Python SNMPv2c socket 구현 (snmpget 바이너리 불필요) |
| 2026-04-02 | paho-mqtt 1.x/2.x 호환 처리 (CallbackAPIVersion 분기) |
