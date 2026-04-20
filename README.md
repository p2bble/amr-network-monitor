# AMR Network Monitor

AMR(Autonomous Mobile Robot)의 무선 네트워크 상태를 실시간으로 모니터링하는 시스템입니다.
로봇 탑재 Python 에이전트가 MQTT로 상태를 전송하고, Flutter 웹/앱이 이를 시각화합니다.

---

## 시스템 구성

```
[로봇 미니PC]                     [메인 서버]                          [관제 단말]
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
| `deploy_agents.sh` | 로컬 | 13대 일괄 배포 스크립트 |

### 에이전트 동작 모드

- **NATIVE 모드**: 로봇 내장 USB WiFi(`iw dev link`)로 직접 상태 수집 (`MOXA_IP = ""`)
- **MOXA 모드**: 서버사이드 SNMP 폴러(`moxa_snmp_poller.py`)가 MOXA에서 데이터 수집 후 MQTT 발행
  → 로봇 에이전트는 `infra_test/moxa/{ROBOT_ID}` 토픽을 구독해 수신

---

## MOXA 서버사이드 SNMP 폴러

### 아키텍처

```
서버
  └─ moxa_snmp_poller.py
       ├─ SNMP GET → MOXA-01 (sebang001)
       ├─ SNMP GET → MOXA-02 (sebang002)
       │   ...
       └─ SNMP GET → MOXA-13 (sebang013)
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

1. MOXA 웹 UI 접속: 각 MOXA 관리 페이지 접속
2. Advanced Setup → SNMP Agent → **Enable**
3. Submit → **Save Configuration** (재부팅 후에도 유지)

---

## 관제 앱 주요 기능

### 실시간 모니터링
- RSSI / Ping 실시간 표시 (SNMP 실측값, 1초 갱신)
- BSSID / SSID / 채널 / SNR / Noise floor / 전송속도
- **전체 현황 그리드** (상단 Wrap 배치 — 13대 동시 표시, 로봇 번호 + RSSI + 상태색상)
- AP 상태 배지 (AP-01~15, WiFi-OFF 표시)

### Ping 3단계 경로 진단 (2026-04-20 추가)

에이전트가 MOXA LAN / AP 게이트웨이 / 서버를 동시 병렬 ping하여 지연 구간을 특정합니다.

```
로봇PC → [MOXA LAN ping] → [AP GW ping] → [서버 ping]
           ↑ LAN 케이블       ↑ WiFi 구간     ↑ 네트워크
```

| latency_src 값 | 의미 |
|---|---|
| `NORMAL` | 전 구간 정상 |
| `MOXA_LAN_DOWN` | LAN 케이블 또는 MOXA 장치 문제 |
| `WIFI_DOWN` | WiFi 연결 끊김 / AP 불응 |
| `WIFI_POOR` | WiFi 구간 지연 100ms 초과 (RF 불량 / AP 과부하) |
| `SERVER_DOWN` | AP까지 정상 / 서버 경로 단절 |
| `NETWORK_ISSUE` | AP→서버 구간 지연 100ms 초과 |

### Sticky Client 감지 (2026-04-20 추가)

RSSI < -75 dBm 상태에서 30초 이상 로밍 없을 경우 `WARN` 이벤트 기록.
→ 더 나은 AP가 있음에도 현재 AP에 고착된 상태 감지.

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

### UI 뷰 모드
- **테이블 뷰** (기본): 로봇ID / 진단상태 / RSSI / 경로(latency_src) / Ping / 채널 / 마지막수신
- **카드 뷰**: 로봇별 상세 카드
- 상세 패널 클릭 시: Ping 3단계 분석 / RSSI+Ping 그래프 / 이벤트 로그

---

## 임계값 기준

| 구분 | 임계값 | 판정 |
|------|--------|------|
| RSSI 약함 | -75 dBm 이하 | WARN |
| RSSI 불량 (음영) | -85 dBm 이하 3회 연속 | CRIT |
| Ping 지연 | 100 ms 이상 | WARN |
| Ping 심각 | 500 ms 이상 | CRIT |
| WiFi 구간 지연 | 100 ms 이상 | WIFI_POOR |
| Sticky Client | RSSI < -75 + 30초 로밍 없음 | WARN |
| 에이전트 무응답 | 30초 이상 | CRIT |

---

## 세방 현장 배포 가이드

### 인프라 정보

| 구분 | 내용 |
|------|------|
| 메인 서버 | 192.168.145.5 (내부) |
| VPN 게이트웨이 | 172.16.***.*** (담당자 노트북) |
| 서버 SSH | `ssh -p 10022 clobot@172.16.***.***` |
| 웹 대시보드 | http://172.16.***.***:9090 (원격) / http://192.168.145.5:9090 (현장) |
| EMQX 관리콘솔 | http://192.168.145.5:18083 |
| MQTT 인증 | cloud / `********` |

### AMR 로봇 정보

| 구분 | 내용 |
|------|------|
| 로봇 수 | 13대 (sebang001~013) |
| 내부 IP | 192.168.145.51~63 |
| SSH 유저 | `thira` |
| SSH(원격) | `ssh -p 9101~9113 thira@172.16.***.***` |
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
| MOXA 웹(원격) | http://172.16.***.***:9201~9213 |
| SNMP 설정 | community: public / V1, V2c / Enable + Save Configuration |

### 네트워크 인프라 (2층)

| 구분 | IP / 채널 |
|------|-----------|
| 메인 스위치 | 192.168.145.254 |
| PoE 스위치 #1~3 | 192.168.145.251~253 |
| AP #01~15 | 192.168.145.31~45 |
| 미운영 AP | #05, #10 |

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
tail -f /home/clobot/amr_deploy/logs/diagnostics.log
```

### 파일 위치 (서버)

```
/home/clobot/amr_deploy/
  ├── amr_unified_agent.py      # 로봇 에이전트 (배포용 원본)
  ├── moxa_snmp_poller.py       # MOXA SNMP 폴러
  ├── infra_monitor.py          # AP/스위치 인프라 모니터
  ├── amr_diagnostics.py        # 자동 장애 진단 서비스
  ├── moxa-poller.service
  ├── infra-monitor.service
  └── amr-diagnostics.service
```

---

## 2. 로봇 에이전트 배포 (서버에서 실행)

```bash
for i in $(seq 1 13); do ROBOT_ID=$(printf "sebang%03d" $i); IP="192.168.145.$((50+i))"; echo "=== $ROBOT_ID ($IP) ==="; scp ~/amr_deploy/amr_unified_agent.py thira@$IP:~/wifi_agent/amr_unified_agent.py && ssh thira@$IP "sed -i 's/^ROBOT_ID.*/ROBOT_ID    = \"$ROBOT_ID\"/' ~/wifi_agent/amr_unified_agent.py && sudo systemctl restart amr-agent && sudo systemctl is-active amr-agent"; done
```

### 주요 설정값 (`amr_unified_agent.py`)

```python
SERVER_IP   = "192.168.145.5"
MOXA_IP     = "192.167.140.1"   # 설정 시 MOXA 모드 자동 전환
AP_GW       = "192.168.145.254" # AP 측 게이트웨이 (WiFi 구간 진단용)
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
flutter build web --release
scp -P 10022 -r build\web\* clobot@172.16.***.***:/home/clobot/amr_deploy/web/
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

## 4. AP 설정 가이드 (H3C WA6320, 펌웨어 7.1.064)

### AP별 채널 / 전력 현황 (2026-04-20 기준 실측)

| AP | IP | 채널 | max-power | 비고 |
|----|----|------|-----------|------|
| AP-01 | 192.168.145.31 | Ch 36 | — | 미확인 |
| AP-02 | 192.168.145.32 | Ch 157 | — | 미확인 |
| AP-03 | 192.168.145.33 | Ch 36 | — | 미확인 |
| AP-04 | 192.168.145.34 | Ch 157 | — | 미확인 |
| AP-05 | 192.168.145.35 | — | — | 미운영 |
| AP-06 | 192.168.145.36 | Ch 161 | — | 미확인 |
| AP-07 | 192.168.145.37 | **Ch 44** | — | 미확인 |
| AP-08 | 192.168.145.38 | Ch 161 | — | 미확인 |
| AP-09 | 192.168.145.39 | **Ch 48** | — | 미확인 |
| AP-10 | 192.168.145.40 | — | — | 미운영 |
| AP-11 | 192.168.145.41 | Ch 36 | **5dBm** | 밀집 구간 저전력 |
| AP-12 | 192.168.145.42 | Ch 149 | **7dBm** | 밀집 구간 저전력 |
| AP-13 | 192.168.145.43 | **Ch 161** | **6dBm** | 2026-04-20 활성화 |
| AP-14 | 192.168.145.44 | Ch 153 | **7dBm** | 2026-04-20 20→7 감소 |
| AP-15 | 192.168.145.45 | Ch 40 | **7dBm** | 밀집 구간 저전력 |

> AP-11~15 구간은 물리적 간격이 좁아 (약 5~8m) 전력을 5~7dBm으로 제한.
> AP-13은 2026-04-20 이전 미운영 상태였으며 Ch161/6dBm으로 활성화.

### AP SSH 접속 (서버 경유)

```bash
ssh admin@192.168.145.31   # AP-01 (현장 서버에서 직접)
```

### AP 채널/전력 변경 명령어

```
system-view
interface WLAN-Radio 1/0/1
channel [채널번호]
max-power [dBm]
quit
save force
quit
quit
```

### AP 신규 활성화 (shutdown 상태에서)

```
system-view
interface WLAN-Radio 1/0/1
undo shutdown
channel [채널번호]
max-power [dBm]
channel band-width 20
quit
save force
quit
quit
```

### max-power 허용 범위

| 채널 대역 | 최대값 |
|---|---|
| Ch 36 (UNII-1) | 14dBm |
| Ch 149 / 153 / 157 / 161 (UNII-3) | 24dBm |

### 펌웨어 7.1.064 미지원 기능

- `dot11r` (802.11r Fast BSS Transition) — 미지원
- `dot11k` (802.11k Neighbor Report) — 미지원
- `wlan rrm` / `station-kick rssi` — 미지원
- `quick-association enable` 이미 설정됨 (OKC/PMK 캐싱으로 부분 대체)

> **주의**: 서비스 템플릿 변경 시 `undo service-template enable` 먼저 실행 필수.

### MOXA 로밍 설정 권장값 (AWK-1137C 웹UI)

| 항목 | 권장값 | 이유 |
|------|--------|------|
| roamingDifference5G | **8** | 핑퐁 로밍 방지 |
| roamingThreshold5G_Signal | **-75** | 불필요한 로밍 감소 |
| rmtConnCheckRebootDevice | **DISABLE** | 서버 ping 실패 시 재부팅 방지 |
| rmtConnCheckCheckTimeout | **2000ms** | 안정적 판정 |
| rmtConnCheckRetryInterval | **3** | timeout보다 커야 함 |

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
mosquitto_sub -h 192.168.145.5 -p 1883 -u cloud -P '********' \
-t 'infra_test/network_status/#' -v -C 5
```

### AP 전체 채널/전력 일괄 확인 (서버에서)
```bash
for i in $(seq 31 45); do echo "=== AP $(( i - 30 )) (192.168.145.$i) ==="; ssh -o ConnectTimeout=3 admin@192.168.145.$i "display current-configuration interface WLAN-Radio 1/0/1" 2>/dev/null | grep -E "channel|max-power|shutdown"; done
```

---

## 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-04-20 | `amr_unified_agent.py`: MOXA LAN / AP GW / 서버 3단계 병렬 ping 추가 (`ping_multi`) |
| 2026-04-20 | `amr_unified_agent.py`: `diagnose_latency()` — 지연 구간 자동 추론 (`latency_src` 필드) |
| 2026-04-20 | `amr_unified_agent.py`: Sticky Client 감지 (RSSI < -75 + 30초 로밍 없음 → WARN) |
| 2026-04-20 | `amr_unified_agent.py`: 로밍 이벤트 로그에 RSSI / ping_gw 컨텍스트 추가 |
| 2026-04-20 | Flutter 대시보드: Summary Bar → Wrap 그리드 (13대 전체 동시 표시) |
| 2026-04-20 | Flutter 대시보드: 테이블 Retry 컬럼 → 경로(latency_src) 배지로 교체 |
| 2026-04-20 | Flutter 대시보드: 상세 패널 Ping 3단계 분석 패널 추가 (MOXA LAN → AP GW → 서버) |
| 2026-04-20 | AP-13 활성화: Ch161 / 6dBm (밀집 구간 커버리지 보완) |
| 2026-04-20 | AP-14 전력 감소: 14dBm → 7dBm (밀집 구간 커버리지 축소, 로밍 개선) |
| 2026-04-20 | `deploy_agents.sh` 추가 — MOXA jump host 경유 13대 일괄 배포 스크립트 |
| 2026-04-06 | H3C WA6320 AP 설정 적용: undo cipher-suite tkip, max-power 14/20 (채널별) |
| 2026-04-06 | MOXA 환경 감지 수정: ping 체크 제거 → MOXA_IP 설정 시 항상 MOXA 모드 |
| 2026-04-06 | RSSI N/A 오탐 수정: rssiAvailable 필드 추가, MOXA SNMP 미수신 진단 구분 |
| 2026-04-06 | ROBOT_ID 템플릿 통일 |
| 2026-04-05 | `amr_diagnostics.py` 추가 — 서버 24/7 자동 진단 서비스 (크로스 로봇 패턴 분석) |
| 2026-04-05 | 대시보드 상단 글로벌 진단 배너 추가 (cross_faults, 오프라인 목록 실시간 표시) |
| 2026-04-03 | MOXA 로밍 임계값 / Device Reboot 설정 적용 |
| 2026-04-03 | MOXA 1.11.17.1 OID 발견 — RSSI/채널/SNR/Noise 실측값 수집 확인 |
| 2026-04-03 | 서버사이드 MOXA 폴러 아키텍처 도입 (moxa-poller.service 배포) |
| 2026-04-02 | 세방 현장 배포 완료 (sebang001~013, 13대) |
| 2026-04-02 | nginx /mqtt WebSocket 프록시 방식 적용 (포트 9090 단일화) |
| 2026-04-02 | Flutter broker URL 동적화 (Uri.base.host/port) |
| 2026-04-02 | paho-mqtt 1.x/2.x 호환 처리 (CallbackAPIVersion 분기) |
