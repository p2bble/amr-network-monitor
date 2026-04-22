#!/usr/bin/env python3
import subprocess
import time
import json
import socket
import threading
import re
import os
import collections
import paho.mqtt.client as mqtt
from datetime import datetime

# ================= [1] 인프라 및 통신 설정 =================
SERVER_IP   = "192.168.145.5"
MOXA_IP     = "192.167.140.1"
ROBOT_ID    = "sebang001"            # 로봇별 배포 시 변경

WLAN_IFACE  = "wlxb0386cf45145"     # 로봇별 배포 시 변경
LAN_IFACE   = "eth0"

MQTT_BROKER = "192.168.145.5"
MQTT_TOPIC  = f"infra_test/network_status/{ROBOT_ID}"
MOXA_TOPIC  = f"infra_test/moxa/{ROBOT_ID}"

# 이벤트 로그 파일 경로 (앱이 꺼져 있어도 이력 영구 보존)
LOG_DIR     = os.path.expanduser("~/wifi_agent/logs")
LOG_FILE    = os.path.join(LOG_DIR, f"{ROBOT_ID}_events.log")

# 임계값 (이벤트 로그 기록용만 유지, 경보 기준은 서버 진단 서비스에서 판단)
RSSI_WEAK_THRESHOLD  = -75   # dBm: 파일 로그 기록 기준
RSSI_BAD_THRESHOLD   = -80   # dBm: 파일 로그 기록 기준
STICKY_CLIENT_SEC    = 60    # 초: RSSI 약한데 로밍 없으면 파일 로그 기록

# ── 슬라이딩 윈도우 (60초 rolling 배경 지표용) ────────────────
LOOP_INTERVAL_SEC = 5
WINDOW_SIZE       = 12   # 5초 × 12 = 60초
# ============================================================

latest_log_msg     = "None"
active_mode        = "UNKNOWN"
_prev_tx_packets   = 0
_prev_tx_retries   = 0
_moxa_data         = {}   # 서버 MOXA 폴러에서 수신한 최신 MOXA 데이터
_bssid_stuck_since = None # Sticky client 판단용 타임스탬프
_sticky_alerted    = False

# ── 슬라이딩 윈도우 (60초 rolling — 배경 지표, 서버 진단용) ──
_ping_srv_window = collections.deque(maxlen=WINDOW_SIZE)
# (timestamp, from_bssid, to_bssid) — 최근 20회 로밍 이력
_roam_history = collections.deque(maxlen=20)

# ── 연속 ping 실패 카운터 (로밍 순단 vs 실질 단절 구분) ────────
# 1~2회 실패: 로밍 순단 (Transient, 통계 노이즈 — 무시)
# 3회 이상  : 실질 단절 (Sustained — CROMS 30초 알람 전 조기 경고)
_ping_fail_streak = 0

def _window_stats(window):
    """슬라이딩 윈도우 → (avg_ms, loss_pct). -1은 loss 처리."""
    if not window:
        return -1.0, 0.0
    valid    = [p for p in window if p >= 0]
    n_total  = len(window)
    loss_pct = round((n_total - len(valid)) / n_total * 100, 1)
    avg      = round(sum(valid) / len(valid), 1) if valid else -1.0
    return avg, loss_pct

def _roam_count_10min():
    now = time.time()
    return sum(1 for t, _, _ in _roam_history if now - t <= 600)

def _detect_pingpong(window_sec=300, min_bounces=3):
    """
    ping-pong 로밍 감지: window_sec 내에 동일한 두 AP 사이에서
    min_bounces회 이상 교대로 왔다갔다하는 패턴.

    이동 중 자연스러운 로밍(다른 AP로 순차 전환)은 해당 안 됨.
    반환: (is_pingpong: bool, pair_str: str)
    """
    now = time.time()
    recent = [(t, f, to) for t, f, to in _roam_history if now - t <= window_sec]
    if len(recent) < min_bounces:
        return False, ""

    # 최근 min_bounces+1개의 목적지 BSSID 추출
    dest_bssids = [to for _, _, to in recent[-(min_bounces + 1):]]
    if len(dest_bssids) < min_bounces:
        return False, ""

    # 정확히 2개의 BSSID만 사용되는지 확인
    unique = set(dest_bssids)
    if len(unique) != 2:
        return False, ""

    # 교대 패턴 확인: ABAB... 또는 BABA...
    for i in range(1, len(dest_bssids)):
        if dest_bssids[i] == dest_bssids[i - 1]:
            return False, ""

    bssids = sorted(unique)
    pair_str = f"{bssids[0][:11]} ↔ {bssids[1][:11]}"
    return True, pair_str

# ── 파일 로깅 ───────────────────────────────────────────────
os.makedirs(LOG_DIR, exist_ok=True)

def log_event(event_type: str, message: str):
    """이벤트를 파일에 영구 기록합니다 (앱 종료 중에도 보존)."""
    global latest_log_msg
    ts  = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}][{event_type}] {message}\n"
    try:
        with open(LOG_FILE, "a") as f:
            f.write(line)
    except Exception:
        pass
    latest_log_msg = f"[{event_type}] {message}"
    print(f"[{ROBOT_ID}] {line.strip()}")

# ── 환경 감지 ────────────────────────────────────────────────
def detect_environment():
    # MOXA_IP가 설정돼 있으면 무조건 MOXA 모드.
    # 과거에는 MOXA ping 성공 여부로 판단했으나, MOXA 데이터는 서버 MQTT에서 수신하므로
    # 부팅 시 MOXA ping 실패가 NATIVE 폴백을 유발하는 문제 수정.
    return "MOXA" if MOXA_IP else "NATIVE"

def ping_target(ip, timeout=1):
    """단일 IP에 ping, 응답 시간(ms) 반환. 실패 시 -1.0"""
    try:
        out = subprocess.check_output(
            ['ping', '-c', '1', '-W', str(timeout), ip],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        m = re.search(r'time=([\d\.]+)\s*ms', out)
        if m:
            return float(m.group(1))
    except subprocess.CalledProcessError:
        pass
    return -1.0

def ping_server():
    return ping_target(SERVER_IP)


# ── IP 주소 조회 (5분 캐시) ─────────────────────────────────
_lan_ip_cache = ("", 0.0)

def get_lan_ip():
    """LAN 인터페이스의 IPv4 주소를 반환합니다 (5분 캐시)."""
    global _lan_ip_cache
    ip, ts = _lan_ip_cache
    if ip and time.time() - ts < 300:
        return ip
    try:
        out = subprocess.check_output(
            ['ip', 'addr', 'show', LAN_IFACE],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', out)
        ip = m.group(1) if m else ""
    except Exception:
        ip = ""
    _lan_ip_cache = (ip, time.time())
    return ip

# ── MOXA 모드 ────────────────────────────────────────────────
def get_moxa_data():
    """서버 MOXA 폴러가 MQTT로 발행한 최신 데이터 반환"""
    d = _moxa_data
    return (
        d.get("bssid",    "Unknown"),
        d.get("rssi",     "N/A"),
        d.get("ssid",     "Unknown"),
        d.get("channel",  "Unknown"),
        d.get("snr",      "N/A"),
        d.get("noise",    "N/A"),
        d.get("rate_mbps","N/A"),
    )

def moxa_syslog_listener():
    global latest_log_msg
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        sock.bind(("0.0.0.0", 514))
        while active_mode == "MOXA":
            data, _ = sock.recvfrom(1024)
            msg = data.decode('utf-8', errors='ignore')
            if any(k in msg.lower() for k in ["fail", "disconnect", "roam", "auth"]):
                log_event("MOXA", msg.strip())
    except Exception:
        pass

# ── NATIVE 모드 ──────────────────────────────────────────────
def get_native_wifi_status():
    try:
        out = subprocess.check_output(
            ['iw', 'dev', WLAN_IFACE, 'link'],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        if "Not connected" in out:
            return "Disconnected", "Error", "None", "None", 0

        bssid_m  = re.search(r'Connected to ([0-9a-fA-F:]+)', out)
        signal_m = re.search(r'signal:\s+(-\d+)\s+dBm', out)
        ssid_m   = re.search(r'SSID:\s+(.*)', out)
        freq_m   = re.search(r'freq:\s+(\d+)', out)

        bssid   = bssid_m.group(1)  if bssid_m  else "Unknown"
        rssi    = signal_m.group(1) if signal_m else "Unknown"
        ssid    = ssid_m.group(1).strip() if ssid_m else "Unknown"
        freq    = freq_m.group(1)   if freq_m   else "Unknown"

        channel  = "Unknown"
        freq_mhz = 0
        if freq != "Unknown":
            f        = int(freq)
            freq_mhz = f
            if 2412 <= f <= 2484: channel = str((f - 2412) // 5 + 1)
            elif f >= 5180:       channel = str((f - 5180) // 5 + 36)

        return bssid, rssi, ssid, channel, freq_mhz
    except Exception:
        return "Error", "Error", "Error", "Error", 0

def native_wifi_log_listener():
    global latest_log_msg
    try:
        proc = subprocess.Popen(
            ['journalctl', '-u', 'wpa_supplicant', '-f', '-n', '0'],
            stdout=subprocess.PIPE, universal_newlines=True
        )
        for line in proc.stdout:
            if active_mode != "NATIVE":
                break
            if any(k in line for k in ["CTRL-EVENT-DISCONNECTED", "reason=", "FAIL", "CTRL-EVENT-BSS-ADDED"]):
                try:    clean = line.split(f'{WLAN_IFACE}: ')[1].strip()
                except IndexError: clean = line.strip()
                log_event("SYS", clean)
    except Exception:
        pass

# ── 채널 품질 측정 (iw station dump) ─────────────────────────
def get_station_stats():
    """
    iw station dump 에서 TX Retry율, TX Failed, Bitrate를 수집합니다.
    delta 방식으로 1초 간격의 실시간 Retry율을 계산합니다.
    연결 중단 없이 수집 가능하며, NATIVE 모드에서만 유효합니다.
    """
    global _prev_tx_packets, _prev_tx_retries
    try:
        out = subprocess.check_output(
            ['iw', 'dev', WLAN_IFACE, 'station', 'dump'],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        tx_packets = 0
        tx_retries = 0
        tx_failed  = 0
        rx_bitrate = -1.0
        tx_bitrate = -1.0

        for line in out.splitlines():
            s = line.strip()
            if   s.startswith('tx packets:'):
                tx_packets = int(s.split(':')[1].strip())
            elif s.startswith('tx retries:'):
                tx_retries = int(s.split(':')[1].strip())
            elif s.startswith('tx failed:'):
                tx_failed  = int(s.split(':')[1].strip())
            elif s.startswith('rx bitrate:'):
                m = re.search(r'([\d.]+)\s+MBit', s)
                if m: rx_bitrate = float(m.group(1))
            elif s.startswith('tx bitrate:'):
                m = re.search(r'([\d.]+)\s+MBit', s)
                if m: tx_bitrate = float(m.group(1))

        # 1초 간격 delta 기반 실시간 Retry율 계산
        d_packets = tx_packets - _prev_tx_packets
        d_retries = tx_retries - _prev_tx_retries

        if d_packets < 0 or d_retries < 0:
            # 로밍 후 카운터 리셋 감지 → 당 사이클 0 처리
            retry_rate = 0.0
        elif d_packets + d_retries > 0:
            retry_rate = round(d_retries / (d_packets + d_retries) * 100, 1)
        else:
            retry_rate = 0.0

        _prev_tx_packets = tx_packets
        _prev_tx_retries = tx_retries

        return {
            'tx_retry_rate': retry_rate,
            'tx_failed':     tx_failed,
            'rx_bitrate':    rx_bitrate,
            'tx_bitrate':    tx_bitrate,
        }
    except Exception:
        return {
            'tx_retry_rate': -1.0,
            'tx_failed':     -1,
            'rx_bitrate':    -1.0,
            'tx_bitrate':    -1.0,
        }

# ── MQTT 연결 (재시도 포함) ──────────────────────────────────
def _on_connect(client, userdata, flags, rc):
    if rc == 0 and active_mode == "MOXA":
        client.subscribe(MOXA_TOPIC, qos=0)

def _on_message(client, userdata, msg):
    global _moxa_data
    try:
        _moxa_data = json.loads(msg.payload.decode())
    except Exception:
        pass

def connect_mqtt():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id=f"agent_{ROBOT_ID}")
    except AttributeError:
        client = mqtt.Client(client_id=f"agent_{ROBOT_ID}")
    client.username_pw_set("cloud", "zmfhatm*0")
    client.on_connect = _on_connect
    client.on_message = _on_message
    while True:
        try:
            client.connect(MQTT_BROKER, 1883, keepalive=60)
            client.loop_start()
            print(f"[{ROBOT_ID}] MQTT 연결 성공: {MQTT_BROKER}:1883")
            return client
        except Exception as e:
            print(f"[{ROBOT_ID}] MQTT 연결 실패: {e} → 5초 후 재시도...")
            time.sleep(5)

# ── 메인 실행 루프 ───────────────────────────────────────────
def main():
    global active_mode, latest_log_msg, _bssid_stuck_since, _sticky_alerted, _ping_fail_streak

    active_mode = detect_environment()
    log_event("START", f"에이전트 시작 — 모드: {active_mode}")

    client = connect_mqtt()

    if active_mode == "MOXA":
        threading.Thread(target=moxa_syslog_listener,   daemon=True).start()
    else:
        threading.Thread(target=native_wifi_log_listener, daemon=True).start()

    # 이전 상태 추적 (임계값 교차 이벤트 감지용)
    prev_status     = "NORMAL"
    prev_bssid      = ""
    prev_rssi_int   = 0
    prev_ping       = 0.0
    reconnect_count = 0

    # RSSI debounce 카운터 (3회 연속 시에만 이벤트 발생, 순간 노이즈 오탐 방지)
    RSSI_DEBOUNCE = 3
    rssi_bad_count  = 0  # RSSI_BAD_THRESHOLD 이하 연속 횟수
    rssi_weak_count = 0  # RSSI_WEAK_THRESHOLD 이하 연속 횟수

    while True:
        # ── 서버 ping (단일 타겟) ────────────────────────────────
        ping_latency = ping_server()

        # ── 슬라이딩 윈도우 업데이트 ───────────────────────────
        _ping_srv_window.append(ping_latency)
        ping_avg_60s, ping_loss_pct = _window_stats(_ping_srv_window)
        roam_count_10min            = _roam_count_10min()

        # ── 연속 실패 카운터 업데이트 ──────────────────────────
        # 로밍 순단(1~2회)은 Transient로 분류 — 통계 노이즈 제외
        # 3회 이상 연속 실패(≥15초)만 실질 단절(Sustained)로 판정
        if ping_latency < 0:
            _ping_fail_streak += 1
            if _ping_fail_streak == 3:
                log_event("WARN", f"연속 3회 ping 실패 (15초) — 실질 단절 의심 (로밍 아님)")
        else:
            if _ping_fail_streak >= 3:
                log_event("INFO", f"ping 복구 — {_ping_fail_streak}회 연속 실패에서 정상화")
            _ping_fail_streak = 0
        sustained_loss = _ping_fail_streak >= 3

        if active_mode == "MOXA":
            iface_name  = LAN_IFACE
            iface_type  = "External (Moxa)"
            bssid, rssi, ssid, channel, snr, noise, rate_mbps = get_moxa_data()
            freq_mhz    = 0
            band        = "Unknown"
            stats       = {'tx_retry_rate': -1.0, 'tx_failed': -1,
                           'rx_bitrate':    -1.0, 'tx_bitrate': -1.0}
        else:
            iface_name                            = WLAN_IFACE
            iface_type                            = "Internal (Native)"
            bssid, rssi, ssid, channel, freq_mhz = get_native_wifi_status()
            snr = noise = rate_mbps = "N/A"
            band  = ("2.4GHz" if 2400 <= freq_mhz < 3000 else
                     "5GHz"   if freq_mhz >= 5000          else "Unknown")
            stats = get_station_stats()

        # RSSI 정수 파싱
        rssi_int = None
        if rssi not in ("Error", "Unknown"):
            try:
                rssi_int = int(rssi.replace('dBm', '').strip())
            except ValueError:
                pass

        # ── 상태 판별 ──────────────────────────────────────
        status = "NORMAL"
        if ping_latency == -1.0:
            status = "DISCONNECTED" if bssid in ("Disconnected", "Error") else "NETWORK_UNREACHABLE"
        elif rssi_int is not None and rssi_int <= RSSI_WEAK_THRESHOLD:
            status = "WEAK_SIGNAL"

        ts = datetime.now().strftime("%H:%M:%S")

        # ── 이벤트 감지: 상태 변화 ─────────────────────────
        if status != prev_status:
            log_event("STATUS", f"상태 변화: {prev_status} → {status}")
        prev_status = status

        # ── 이벤트 감지: 로밍 (BSSID 변경) ────────────────
        if prev_bssid and prev_bssid != bssid and bssid not in ("Disconnected", "Error", "Unknown"):
            _roam_history.append((time.time(), prev_bssid, bssid))
            pp, pp_pair = _detect_pingpong()
            if pp:
                log_event("WARN", f"PING-PONG 로밍: {pp_pair} (5분 내 반복)")
            else:
                log_event("ROAM", f"로밍 발생: {prev_bssid} → {bssid} (Ch: {channel}, RSSI: {rssi})")
            _bssid_stuck_since = None
            _sticky_alerted    = False
        prev_bssid = bssid

        # ── 이벤트 감지: Sticky Client (MOXA 모드) ─────────
        if active_mode == "MOXA" and rssi_int is not None and rssi_int < RSSI_WEAK_THRESHOLD:
            if bssid not in ("Unknown", "Error", "Disconnected"):
                if _bssid_stuck_since is None:
                    _bssid_stuck_since = time.time()
                stuck_sec = time.time() - _bssid_stuck_since
                if stuck_sec >= STICKY_CLIENT_SEC and not _sticky_alerted:
                    log_event("WARN", f"STICKY CLIENT: RSSI={rssi_int}dBm, {int(stuck_sec)}초간 로밍 없음 (AP: {bssid})")
                    _sticky_alerted = True
        else:
            _bssid_stuck_since = None
            _sticky_alerted    = False

        # ── 이벤트 감지: RSSI 임계값 교차 (debounce: 3회 연속) ────
        if rssi_int is not None:
            # Bad threshold (-85 dBm)
            if rssi_int < RSSI_BAD_THRESHOLD:
                rssi_bad_count += 1
                rssi_weak_count = 0
                if rssi_bad_count == RSSI_DEBOUNCE:
                    log_event("CRIT", f"RSSI 불량 구간 진입 (음영): {rssi_int}dBm")
            else:
                if rssi_bad_count >= RSSI_DEBOUNCE:
                    log_event("INFO", f"음영구간 탈출 (RSSI {rssi_int}dBm)")
                rssi_bad_count = 0
                # Weak threshold (-75 dBm)
                if rssi_int < RSSI_WEAK_THRESHOLD:
                    rssi_weak_count += 1
                    if rssi_weak_count == RSSI_DEBOUNCE:
                        log_event("WARN", f"RSSI 약함 구간 진입: {rssi_int}dBm")
                else:
                    if rssi_weak_count >= RSSI_DEBOUNCE:
                        log_event("INFO", f"RSSI 회복: {rssi_int}dBm")
                    rssi_weak_count = 0
            prev_rssi_int = rssi_int

        if ping_latency >= 0:
            prev_ping = ping_latency

        # ── Payload 구성 ────────────────────────────────────
        payload = {
            "robot_id":         ROBOT_ID,
            "timestamp":        ts,
            "active_mode":      active_mode,
            "interface_name":   iface_name,
            "interface_type":   iface_type,
            "ping_ms":          ping_latency,       # 서버 ping 순간값 (진단 참고용)
            "ping_avg_60s":     ping_avg_60s,       # 60초 평균 ping
            "ping_loss_pct":    ping_loss_pct,      # 60초 패킷 손실률 (raw, 로밍 순단 포함)
            "ping_fail_streak": _ping_fail_streak,  # 연속 실패 횟수 (1~2=순단, 3+=실질단절)
            "sustained_loss":   sustained_loss,     # 3회 이상 연속 실패 = 실질 단절
            "bssid":            bssid,
            "ssid":             ssid,
            "channel":          channel,
            "rssi":             rssi,
            "status":           status,
            "latest_log":       latest_log_msg,
            "reconnect_count":  reconnect_count,    # MQTT 재연결 누적 (핵심 지표)
            "roam_count_10min": roam_count_10min,   # 10분 내 로밍 횟수 (정보용)
            "pingpong":         _detect_pingpong()[0],   # ping-pong 감지 여부
            "pingpong_pair":    _detect_pingpong()[1],   # ping-pong 대상 AP 쌍
            "srv_ip":           SERVER_IP,
            "pc_ip":            get_lan_ip(),
            "freq_mhz":         freq_mhz,
            "band":             band,
            **({"snr": snr, "noise": noise, "rate_mbps": rate_mbps}
               if active_mode == "MOXA" else {}),
            **stats,
        }

        # ── Publish (실패 시 재연결) ─────────────────────────
        result = client.publish(MQTT_TOPIC, json.dumps(payload))
        if result.rc != mqtt.MQTT_ERR_SUCCESS:
            log_event("SYS", f"MQTT publish 실패(rc={result.rc}) — 재연결 시도")
            client.loop_stop()
            client = connect_mqtt()
            reconnect_count += 1

        latest_log_msg = "None"  # 한 번 전송 후 초기화
        time.sleep(LOOP_INTERVAL_SEC)  # 5초 (기존 1초 → 순간값 노이즈 제거)

if __name__ == "__main__":
    main()
