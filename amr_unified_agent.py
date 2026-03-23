#!/usr/bin/env python3
import subprocess
import time
import json
import socket
import threading
import re
import os
import paho.mqtt.client as mqtt
from datetime import datetime

# ================= [1] 인프라 및 통신 설정 =================
SERVER_IP   = "172.18.100.123"
MOXA_IP     = ""
ROBOT_ID    = "HD-BaseAir-002"

WLAN_IFACE  = "wlxb0386cf45145"
LAN_IFACE   = "eth0"

MQTT_BROKER = "172.18.100.123"
MQTT_TOPIC  = f"infra_test/network_status/{ROBOT_ID}"

OID_BSSID   = ".1.3.6.1.4.1.8691.16.1.1.1.2.1.0"
OID_RSSI    = ".1.3.6.1.4.1.8691.16.1.1.1.3.1.0"

# 이벤트 로그 파일 경로 (앱이 꺼져 있어도 이력 영구 보존)
LOG_DIR     = os.path.expanduser("~/wifi_agent/logs")
LOG_FILE    = os.path.join(LOG_DIR, f"{ROBOT_ID}_events.log")

# 임계값 기준
RSSI_WEAK_THRESHOLD  = -75   # dBm 이하 → 약함
RSSI_BAD_THRESHOLD   = -85   # dBm 이하 → 불량
PING_WARN_THRESHOLD  = 100   # ms 이상 → 지연 경고
PING_CRIT_THRESHOLD  = 500   # ms 이상 → 심각 지연
# ============================================================

latest_log_msg   = "None"
active_mode      = "UNKNOWN"
_prev_tx_packets = 0
_prev_tx_retries = 0

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
    if not MOXA_IP:
        return "NATIVE"
    try:
        subprocess.check_output(['ping', '-c', '1', '-W', '1', MOXA_IP], stderr=subprocess.STDOUT)
        return "MOXA"
    except subprocess.CalledProcessError:
        return "NATIVE"

def ping_server():
    try:
        out = subprocess.check_output(
            ['ping', '-c', '1', '-W', '2', SERVER_IP],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        m = re.search(r'time=([\d\.]+)\s*ms', out)
        if m:
            return float(m.group(1))
    except subprocess.CalledProcessError:
        pass
    return -1.0

# ── IP 주소 조회 ─────────────────────────────────────────────
def get_lan_ip():
    """LAN 인터페이스의 IPv4 주소를 반환합니다."""
    try:
        out = subprocess.check_output(
            ['ip', 'addr', 'show', LAN_IFACE],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        m = re.search(r'inet (\d+\.\d+\.\d+\.\d+)', out)
        return m.group(1) if m else ""
    except Exception:
        return ""

# ── MOXA 모드 ────────────────────────────────────────────────
def get_moxa_snmp(oid):
    try:
        out = subprocess.check_output(
            ['snmpget', '-v2c', '-c', 'public', MOXA_IP, oid],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        value = out.split("=")[1].strip()
        return value.split(":")[1].strip().strip('"') if ":" in value else value
    except Exception:
        return "Error"

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
def connect_mqtt():
    client = mqtt.Client(client_id=f"agent_{ROBOT_ID}")
    client.username_pw_set("cloud", "zmfhatm*0")
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
    global active_mode, latest_log_msg

    active_mode = detect_environment()
    log_event("START", f"에이전트 시작 — 모드: {active_mode}")

    client = connect_mqtt()

    if active_mode == "MOXA":
        threading.Thread(target=moxa_syslog_listener,   daemon=True).start()
    else:
        threading.Thread(target=native_wifi_log_listener, daemon=True).start()

    # 이전 상태 추적 (임계값 교차 이벤트 감지용)
    prev_status   = "NORMAL"
    prev_bssid    = ""
    prev_rssi_int = 0
    prev_ping     = 0.0
    reconnect_count = 0

    # RSSI debounce 카운터 (3회 연속 시에만 이벤트 발생, 순간 노이즈 오탐 방지)
    RSSI_DEBOUNCE = 3
    rssi_bad_count  = 0  # RSSI_BAD_THRESHOLD 이하 연속 횟수
    rssi_weak_count = 0  # RSSI_WEAK_THRESHOLD 이하 연속 횟수

    while True:
        ping_latency = ping_server()

        if active_mode == "MOXA":
            iface_name    = LAN_IFACE
            iface_type    = "External (Moxa)"
            bssid         = get_moxa_snmp(OID_BSSID)
            rssi          = get_moxa_snmp(OID_RSSI)
            ssid, channel = "MOXA_AP", "Unknown"
            freq_mhz      = 0
            band          = "Unknown"
            stats         = {'tx_retry_rate': -1.0, 'tx_failed': -1,
                             'rx_bitrate': -1.0, 'tx_bitrate': -1.0}
        else:
            iface_name                            = WLAN_IFACE
            iface_type                            = "Internal (Native)"
            bssid, rssi, ssid, channel, freq_mhz = get_native_wifi_status()
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
            log_event("ROAM", f"로밍 발생: {prev_bssid} → {bssid} (Ch: {channel})")
        prev_bssid = bssid

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

        # ── 이벤트 감지: Ping 임계값 교차 ─────────────────
        if ping_latency >= 0 and prev_ping >= 0:
            if prev_ping < PING_WARN_THRESHOLD and ping_latency >= PING_WARN_THRESHOLD:
                log_event("WARN", f"Ping 지연 발생: {prev_ping:.0f}ms → {ping_latency:.0f}ms")
            elif prev_ping >= PING_WARN_THRESHOLD and ping_latency < PING_WARN_THRESHOLD:
                log_event("INFO", f"Ping 정상화: {prev_ping:.0f}ms → {ping_latency:.0f}ms")
            if prev_ping < PING_CRIT_THRESHOLD and ping_latency >= PING_CRIT_THRESHOLD:
                log_event("CRIT", f"Ping 심각 지연: {ping_latency:.0f}ms")
        if ping_latency >= 0:
            prev_ping = ping_latency

        # ── Payload 구성 ────────────────────────────────────
        payload = {
            "robot_id":        ROBOT_ID,
            "timestamp":       ts,
            "active_mode":     active_mode,
            "interface_name":  iface_name,
            "interface_type":  iface_type,
            "ping_ms":         ping_latency,
            "bssid":           bssid,
            "ssid":            ssid,
            "channel":         channel,
            "rssi":            rssi,
            "status":          status,
            "latest_log":      latest_log_msg,
            "reconnect_count": reconnect_count,
            "srv_ip":          SERVER_IP,
            "pc_ip":           get_lan_ip(),
            "freq_mhz":        freq_mhz,
            "band":            band,
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
        time.sleep(1)

if __name__ == "__main__":
    main()
