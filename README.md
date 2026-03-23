# AMR Network Monitor

AMR(Autonomous Mobile Robot)의 무선 네트워크 상태를 실시간으로 모니터링하는 시스템입니다.
로봇 탑재 Python 에이전트가 MQTT로 상태를 전송하고, Flutter 웹/앱이 이를 시각화합니다.

---

## 시스템 구성

```
[로봇 미니PC]                        [MQTT 브로커]              [관제 단말]
amr_unified_agent.py  →  MQTT 1883  →  EMQX  →  MQTT WS 8083  →  amr_monitor (웹/앱)
     (Python)                    (172.18.100.123)              (브라우저 / Android / Windows)
```

### 구성 요소

| 구성 요소 | 설명 |
|-----------|------|
| `amr_unified_agent.py` | 로봇 미니PC에 상주하는 Python 모니터링 에이전트 |
| `amr-agent.service` | systemd 자동재시작 서비스 파일 |
| `amr_monitor/` | Flutter 관제 앱 (웹 / Android / Windows) |
| `amr_monitor/Dockerfile` | Flutter Web → nginx 멀티스테이지 Docker 빌드 |

### 에이전트 동작 모드

- **NATIVE 모드**: 로봇 내장 USB WiFi(`iw dev link` + `iw station dump`)로 직접 상태 수집
- **MOXA 모드**: 외장 MOXA 산업용 무선 브릿지 SNMP OID로 상태 수집 (`MOXA_IP` 설정 시 자동 전환)

---

## 관제 앱 주요 기능

### 실시간 모니터링
- RSSI / Ping 실시간 그래프 (1초 갱신)
- TX Retry율 / TX Failed / RX·TX 비트레이트 실시간 표시
- WiFi 주파수 대역 (2.4GHz / 5GHz) 및 DFS 채널 경고
- 다중 로봇 동시 관제 (MQTT 토픽 `#` 와일드카드)

### 자동 장애 진단 (OSI 계층별)
| 계층 | 진단 기준 |
|------|-----------|
| RF/AP | RSSI < -75 dBm (WARN) / < -85 dBm 3초 연속 (CRIT) |
| MOXA | MOXA 연결 끊김 감지 |
| GW Ping | 100 ms 초과 (WARN) / 500 ms 초과 (CRIT) |
| 서버 Ping | 서버 응답 없음 |
| 미니PC | 에이전트 30초 이상 무응답 |

### 채널 간섭 / 품질 진단
- **국소 간섭 vs Co-channel 혼잡** 자동 판별
  - 같은 BSSID(AP) 접속 로봇들의 TX Retry율 비교
  - 다른 로봇은 Retry < 10% → 해당 로봇 위치 특화 국소 간섭 (EMI/다중경로)
  - 전체 로봇 Retry 높음 → Co-channel 혼잡 (채널 분리 권장)
- **DFS 채널 감지**: 5GHz 5260~5720 MHz → 레이더 탐지로 인한 채널 변경 위험 경고
- **2.4GHz → 5GHz 마이그레이션 권장** 판단 (RSSI 조건 충족 시)

### UI 뷰 모드
- **테이블 뷰** (기본): 로봇ID / 진단상태 / RSSI / Retry / Ping / 채널 / 마지막수신 — 행 클릭 시 상세 확장
- **카드 뷰**: 로봇별 상세 카드 (RSSI·Ping 그래프, 이벤트 로그, 조치 배너)
- **공용 레이어 헤더**: RF/AP · MOXA · GW Ping · 서버 Ping · 미니PC 레이블 최상단 1개로 통일, 클릭으로 토글 숨김
- **카드 접기/펼치기**: 개별 카드 토글 가능

### 이벤트 로그 & 보고서
- 음영구간 / 로밍 / Ping 지연 이벤트 자동 로그 (debounce 3초, 순간 노이즈 오탐 방지)
- 장애 보고서 자동 생성 및 클립보드 복사

---

## MQTT 페이로드 스펙

에이전트가 `infra_test/network_status/<ROBOT_ID>` 토픽으로 발행하는 JSON:

```json
{
  "robot_id":      "HD-BaseAir-002",
  "timestamp":     "2026-03-23T14:30:00",
  "rssi":          -62,
  "current_bssid": "d4:b4:c0:d5:6b:32",
  "ssid":          "CROMS-5G",
  "channel":       149,
  "freq_mhz":      5745,
  "band":          "5GHz",
  "ping_server_ms": 12,
  "srv_ip":        "172.18.100.123",
  "pc_ip":         "172.16.90.101",
  "tx_retry_rate": 3.2,
  "tx_failed":     0,
  "rx_bitrate":    300.0,
  "tx_bitrate":    270.0,
  "roaming_count": 0,
  "packet_loss":   0.0
}
```

---

## 임계값 기준

| 구분 | 임계값 | 판정 |
|------|--------|------|
| RSSI 약함 | -75 dBm 이하 | WARN |
| RSSI 불량 (음영) | -85 dBm 이하 (3초 연속) | CRIT |
| Ping 지연 | 100 ms 이상 | WARN |
| Ping 심각 | 500 ms 이상 | CRIT |
| TX Retry 주의 | 10% 이상 | WARN |
| TX Retry 불량 | 30% 이상 | CRIT |
| 에이전트 무응답 | 30초 이상 | CRIT |

---

## 1. 로봇 에이전트 배포

### 필수 패키지 설치

```bash
sudo apt update
sudo apt install -y python3-pip iw wireless-tools
pip3 install paho-mqtt
```

### 에이전트 설치

```bash
sudo mkdir -p /home/clobot/wifi_agent/logs
sudo chown -R clobot:clobot /home/clobot/wifi_agent
cp amr_unified_agent.py /home/clobot/wifi_agent/
```

### 로봇별 설정 수정

`amr_unified_agent.py` 상단의 설정값을 로봇에 맞게 수정합니다:

```python
SERVER_IP   = "172.18.100.123"    # MQTT 브로커 서버 IP
ROBOT_ID    = "HD-BaseAir-002"    # ★ 로봇마다 고유하게 변경
WLAN_IFACE  = "wlxb0386cf45145"   # ★ 실제 WiFi 인터페이스명으로 변경 (ip link show | grep wl)
MOXA_IP     = ""                  # MOXA 사용 시 IP 입력, 없으면 빈 문자열
MQTT_BROKER = "172.18.100.123"    # MQTT 브로커 IP
LAN_IFACE   = "eth0"              # LAN 인터페이스명 (pc_ip 수집용)
```

### systemd 서비스 등록

```bash
sudo cp amr-agent.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable amr-agent
sudo systemctl start amr-agent
sudo systemctl status amr-agent
```

### WiFi Power Management 비활성화 (오탐 방지)

```bash
# 즉시 적용
sudo iwconfig <인터페이스명> power off

# 영구 적용
sudo bash -c 'cat > /etc/NetworkManager/conf.d/wifi-powersave.conf << EOF
[connection]
wifi.powersave = 2
EOF'
sudo systemctl restart NetworkManager
```

### 로그 확인

```bash
journalctl -u amr-agent -f
cat ~/wifi_agent/logs/<ROBOT_ID>_events.log
```

---

## 2. 웹 관제 대시보드 Docker 배포 (서버)

Flutter Web 앱을 Docker + nginx로 서버에 배포합니다.

### 사전 준비

`docker-compose.yml`에 서비스 추가:

```yaml
amr-monitor-web:
  build:
    context: ./amr_monitor
    dockerfile: Dockerfile
  ports:
    - "8084:80"
  restart: unless-stopped
```

### 배포

```bash
# 로컬 PC에서 파일 전송
scp -r amr_monitor clobot@172.18.100.20:/data/docker/amr_monitor

# 서버에서 이미지 빌드 및 실행
ssh clobot@172.18.100.20
cd /data/docker
docker-compose build amr-monitor-web
docker-compose up -d amr-monitor-web
```

브라우저에서 `http://172.18.100.20:8084` 접속.

---

## 3. 다중 로봇 배포 (N대 확장)

앱은 MQTT 토픽 `infra_test/network_status/#`를 구독하므로 **설정 변경 없이** 새 로봇이 자동으로 화면에 추가됩니다.

```bash
# 예시: HD-BaseAir-003 추가
ROBOT="HD-BaseAir-003"
ROBOT_IP="172.16.90.xxx"

sed "s/HD-BaseAir-002/$ROBOT/" amr_unified_agent.py > /tmp/agent_new.py
scp /tmp/agent_new.py clobot@$ROBOT_IP:/home/clobot/wifi_agent/amr_unified_agent.py
scp amr-agent.service clobot@$ROBOT_IP:/tmp/

ssh clobot@$ROBOT_IP "sudo cp /tmp/amr-agent.service /etc/systemd/system/ && \
  sudo systemctl daemon-reload && \
  sudo systemctl enable amr-agent && \
  sudo systemctl start amr-agent"
```

---

## 4. Android / Windows 앱 빌드

### Android APK

```bash
cd amr_monitor
flutter pub get
flutter build apk --release
# 결과: build/app/outputs/flutter-apk/app-release.apk
```

### Windows

```powershell
cd amr_monitor
flutter pub get
flutter build windows --release
# 결과: build\windows\x64\runner\Release\amr_monitor.exe
```

---

## 트러블슈팅

### 에이전트 시작 안 됨

```bash
sudo -u clobot python3 /home/clobot/wifi_agent/amr_unified_agent.py
pip3 install paho-mqtt
sudo chown -R clobot:clobot /home/clobot/wifi_agent
```

### 앱에서 데이터 수신 안 됨

1. MQTT 브로커 접근 확인: `telnet 172.18.100.123 8083`
2. 에이전트 실행 확인: `sudo systemctl status amr-agent`
3. MQTT 토픽 확인: 에이전트의 `MQTT_TOPIC`과 앱 구독 토픽(`infra_test/network_status/#`) 일치 여부

### RSSI 오탐 (순간 -100 반복)

```bash
sudo iwconfig <인터페이스명> power off
iwconfig <인터페이스명> | grep -i power    # Power Management:off 확인
```

### TX Retry 수집 안 됨

`iw` 명령어가 설치되어 있는지 확인:
```bash
which iw || sudo apt install -y iw
iw dev <인터페이스명> station dump
```

---

## 변경 이력

| 날짜 | 내용 |
|------|------|
| 2026-03-23 | 테이블/카드 듀얼 뷰 모드 추가 (기본: 테이블) |
| 2026-03-23 | 공용 레이어 헤더 통합 및 토글 숨김 기능 |
| 2026-03-23 | TX Retry 기반 채널 간섭 진단 (국소 간섭 vs Co-channel 혼잡 판별) |
| 2026-03-23 | DFS 채널 경고, 2.4/5GHz 밴드 표시, 채널 품질 바 추가 |
| 2026-03-23 | 레이어 아이콘 하단 IP 주소 표시 |
| 2026-03-23 | 카드 접기/펼치기 토글 기능 |
| 2026-03-23 | Flutter Web Docker 배포 지원 (nginx, 포트 8084) |
| 2026-03-23 | `iw station dump` 기반 TX Retry율 실시간 수집 (delta 방식) |
| 2026-03-23 | MQTT 페이로드에 freq_mhz, band, pc_ip, tx_retry_rate, rx/tx_bitrate 추가 |
