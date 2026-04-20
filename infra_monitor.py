#!/usr/bin/env python3
"""
AMR 인프라 모니터링 에이전트 (서버 실행용)
AP #01~15, PoE 스위치 #01~03, 메인 스위치 생존 여부를 ping으로 모니터링
MQTT 토픽: infra_test/network_infra/{device_type}/{device_id}

wifi_status 판별 우선순위:
  1. H3C AP SNMP ifOperStatus 자동 감지 (AP에 SNMP 설정된 경우)
  2. ap_admin_config.json (SNMP 실패 시 fallback)

wifi_status 값:
  ACTIVE   - WiFi 정상 운영 중 (radio up, 자동 감지 또는 config)
  SHUTDOWN - radio interface shutdown (ping OK, WiFi OFF)
  DISABLED - 해당 구역 WiFi 미운영 구역 (영구)
  DOWN     - ping 실패 (전원/케이블/PoE 장애 의심)
"""
import subprocess, time, json, threading, socket, os
from datetime import datetime
import paho.mqtt.client as mqtt

# ── 설정 ──────────────────────────────────────────────────────
MQTT_BROKER  = "192.168.145.5"
MQTT_PORT    = 1883
INTERVAL_SEC = 10    # 모니터링 주기 (초)
CONFIG_PATH  = os.path.join(os.path.dirname(__file__), "ap_admin_config.json")
CONFIG_RELOAD_SEC = 60  # config 파일 자동 리로드 주기

# ── H3C AP SNMP 설정 ──────────────────────────────────────────
AP_SNMP_COMMUNITY = b'public'
AP_SNMP_TIMEOUT   = 0.5           # 초 (빠른 응답 요구)
AP_SNMP_RESCAN_SEC = 1800         # 30분마다 인터페이스 인덱스 재스캔
# H3C WA6320 5GHz radio 인터페이스 이름 패턴 (대소문자 무관)
AP_RADIO5G_PATTERNS = ('wlan-radio 1/0/1', 'wlan1/0/1', 'wifi1', 'radio1')
# 표준 IF-MIB OID
OID_IF_DESCR = "1.3.6.1.2.1.2.2.1.2"   # ifDescr
OID_IF_OPER  = "1.3.6.1.2.1.2.2.1.8"   # ifOperStatus (1=up, 2=down)

DEVICES = [
    # AP 15대 (2층)
    {"id": "AP-01",  "type": "AP",  "ip": "192.168.145.31"},
    {"id": "AP-02",  "type": "AP",  "ip": "192.168.145.32"},
    {"id": "AP-03",  "type": "AP",  "ip": "192.168.145.33"},
    {"id": "AP-04",  "type": "AP",  "ip": "192.168.145.34"},
    {"id": "AP-05",  "type": "AP",  "ip": "192.168.145.35"},
    {"id": "AP-06",  "type": "AP",  "ip": "192.168.145.36"},
    {"id": "AP-07",  "type": "AP",  "ip": "192.168.145.37"},
    {"id": "AP-08",  "type": "AP",  "ip": "192.168.145.38"},
    {"id": "AP-09",  "type": "AP",  "ip": "192.168.145.39"},
    {"id": "AP-10",  "type": "AP",  "ip": "192.168.145.40"},
    {"id": "AP-11",  "type": "AP",  "ip": "192.168.145.41"},
    {"id": "AP-12",  "type": "AP",  "ip": "192.168.145.42"},
    {"id": "AP-13",  "type": "AP",  "ip": "192.168.145.43"},
    {"id": "AP-14",  "type": "AP",  "ip": "192.168.145.44"},
    {"id": "AP-15",  "type": "AP",  "ip": "192.168.145.45"},
    # PoE 스위치 3대
    {"id": "SW-PoE-01", "type": "SWITCH", "ip": "192.168.145.253"},
    {"id": "SW-PoE-02", "type": "SWITCH", "ip": "192.168.145.252"},
    {"id": "SW-PoE-03", "type": "SWITCH", "ip": "192.168.145.251"},
    # 메인 스위치
    {"id": "SW-Main-01", "type": "SWITCH", "ip": "192.168.145.254"},
]

# ── H3C AP SNMP 유틸 ─────────────────────────────────────────
def _encode_oid(parts):
    b = bytes([40 * parts[0] + parts[1]])
    for v in parts[2:]:
        if v < 128:
            b += bytes([v])
        else:
            chunks = []
            while v:
                chunks.insert(0, v & 0x7f)
                v >>= 7
            b += bytes([(c | 0x80 if i < len(chunks)-1 else c) for i, c in enumerate(chunks)])
    return b

def _tlv(tag, val):
    l = len(val)
    if l < 128:   return bytes([tag, l]) + val
    elif l < 256: return bytes([tag, 0x81, l]) + val
    else:         return bytes([tag, 0x82, l >> 8, l & 0xff]) + val

def _ap_snmp_get(host, oid_str):
    """H3C AP 대상 SNMP GET. 문자열 반환, 실패 시 None."""
    try:
        parts = [int(x) for x in oid_str.split('.')]
        oid_b   = _tlv(0x06, _encode_oid(parts))
        varbind = _tlv(0x30, oid_b + b'\x05\x00')
        pdu     = _tlv(0xa0, _tlv(0x02, b'\x01') + b'\x02\x01\x00\x02\x01\x00' + _tlv(0x30, varbind))
        msg     = _tlv(0x30, b'\x02\x01\x01' + _tlv(0x04, AP_SNMP_COMMUNITY) + pdu)
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(AP_SNMP_TIMEOUT)
        s.sendto(msg, (host, 161))
        data, _ = s.recvfrom(4096)
        s.close()
        idx = data.find(oid_b)
        if idx == -1:
            return None
        idx += len(oid_b)
        vtype, vlen = data[idx], data[idx+1]
        raw = data[idx+2: idx+2+vlen]
        if vtype == 0x04:
            return raw.decode('utf-8', errors='replace').strip()
        elif vtype in (0x02, 0x41, 0x42, 0x43):
            n = int.from_bytes(raw, 'big')
            if vtype == 0x02 and raw and (raw[0] & 0x80):
                n -= (1 << (8 * len(raw)))
            return str(n)
        return raw.hex()
    except Exception:
        return None

# AP 인터페이스 인덱스 캐시: {ip: (ifIndex, last_scan_time)}
# ifIndex = -1 → SNMP 미응답 또는 5GHz radio 인터페이스 없음
_ap_if_idx_cache = {}

def _find_ap_radio5g_idx(ap_ip):
    """H3C AP에서 5GHz radio 인터페이스의 ifIndex를 찾아 반환. 없으면 -1."""
    for idx in range(1, 21):   # ifDescr.1 ~ .20 스캔
        descr = _ap_snmp_get(ap_ip, f"{OID_IF_DESCR}.{idx}")
        if descr and any(p in descr.lower() for p in AP_RADIO5G_PATTERNS):
            print(f"[AP-SNMP] {ap_ip}: 5GHz radio = ifIndex {idx} ({descr})")
            return idx
    return -1

def ap_radio5g_status(ap_ip):
    """
    H3C AP의 5GHz radio 운영 상태를 SNMP로 조회.
    Returns: "ACTIVE" | "SHUTDOWN" | None (SNMP 불가 → config fallback 필요)
    """
    now = time.time()
    cached = _ap_if_idx_cache.get(ap_ip)

    # 캐시 없거나 30분 경과 → 인터페이스 인덱스 재스캔
    if cached is None or (now - cached[1]) > AP_SNMP_RESCAN_SEC:
        idx = _find_ap_radio5g_idx(ap_ip)
        _ap_if_idx_cache[ap_ip] = (idx, now)
    else:
        idx = cached[0]

    if idx <= 0:
        return None   # SNMP 미응답 또는 radio 인터페이스 못 찾음

    oper = _ap_snmp_get(ap_ip, f"{OID_IF_OPER}.{idx}")
    if oper == '1':
        return "ACTIVE"
    if oper == '2':
        return "SHUTDOWN"
    return None   # 예상치 못한 응답

# ── AP config 관리 ────────────────────────────────────────────
_ap_wifi_status = {}   # {"AP-01": "ACTIVE", "AP-12": "SHUTDOWN", ...}
_config_last_loaded = 0

def load_ap_config():
    """ap_admin_config.json 로드. 파일 없으면 기본값(모두 ACTIVE) 사용."""
    global _ap_wifi_status, _config_last_loaded
    try:
        with open(CONFIG_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        _ap_wifi_status = data.get("ap_wifi_status", {})
        _config_last_loaded = time.time()
        print(f"[CONFIG] ap_admin_config.json 로드 완료: {len(_ap_wifi_status)}개 AP 설정")
    except FileNotFoundError:
        print(f"[CONFIG] 설정 파일 없음 ({CONFIG_PATH}) → 모든 AP ACTIVE 처리")
        _ap_wifi_status = {}
        _config_last_loaded = time.time()
    except Exception as e:
        print(f"[CONFIG] 설정 파일 읽기 오류: {e} → 기존 설정 유지")

def get_wifi_status(device_id, ping_up, ap_ip=None):
    """
    wifi_status 결정 우선순위:
      1. ping DOWN → 즉시 "DOWN" (전원/케이블 장애)
      2. H3C SNMP ifOperStatus 자동 감지 (AP SNMP 설정된 경우)
      3. ap_admin_config.json fallback (SNMP 실패 시)
    """
    if not ping_up:
        return "DOWN"

    # SNMP 자동 감지 시도 (AP 타입이고 IP가 있는 경우만)
    if ap_ip:
        snmp_status = ap_radio5g_status(ap_ip)
        if snmp_status is not None:
            return snmp_status   # "ACTIVE" or "SHUTDOWN" — 자동 감지 성공

    # SNMP 미응답 → config 파일 fallback
    return _ap_wifi_status.get(device_id, "ACTIVE")

# ── MQTT ──────────────────────────────────────────────────────
def create_client():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="infra_monitor")
    except AttributeError:
        client = mqtt.Client(client_id="infra_monitor")
    client.username_pw_set("cloud", "zmfhatm*0")
    return client

# ── Ping ──────────────────────────────────────────────────────
def ping(ip, count=2, timeout=1):
    try:
        out = subprocess.check_output(
            ['ping', '-c', str(count), '-W', str(timeout), ip],
            stderr=subprocess.STDOUT, universal_newlines=True
        )
        for line in out.splitlines():
            if 'avg' in line or 'rtt' in line:
                avg = float(line.split('/')[4])
                return True, round(avg, 1)
        return True, 0.0
    except subprocess.CalledProcessError:
        return False, -1

# ── 메인 루프 ─────────────────────────────────────────────────
def monitor_loop(client):
    global _config_last_loaded
    load_ap_config()

    while True:
        # config 파일 주기적 리로드
        if time.time() - _config_last_loaded > CONFIG_RELOAD_SEC:
            load_ap_config()

        for dev in DEVICES:
            up, ping_ms = ping(dev["ip"])
            wifi_status = get_wifi_status(dev["id"], up, ap_ip=dev["ip"]) if dev["type"] == "AP" else None

            payload = {
                "device_id":   dev["id"],
                "device_type": dev["type"],
                "ip":          dev["ip"],
                "status":      "UP" if up else "DOWN",
                "ping_ms":     ping_ms,
                "timestamp":   datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            }
            if wifi_status is not None:
                payload["wifi_status"] = wifi_status

            topic = f"infra_test/network_infra/{dev['type'].lower()}/{dev['id']}"
            try:
                client.publish(topic, json.dumps(payload), qos=0)
            except Exception as e:
                print(f"[INFRA] 발행 실패 {dev['id']}: {e}")

            status_str = "UP" if up else "DOWN"
            ping_str   = f"{ping_ms}ms" if up else "timeout"
            wifi_str   = f" [{wifi_status}]" if wifi_status else ""
            # SNMP 자동감지 여부 표시 (캐시에 유효한 인덱스가 있으면 SNMP)
            src_str = ""
            if wifi_status and dev["type"] == "AP":
                cached = _ap_if_idx_cache.get(dev["ip"])
                src_str = " (snmp)" if cached and cached[0] > 0 else " (cfg)"
            print(f"[{dev['type']:6}] {dev['id']:12} {dev['ip']:18} {status_str:4} {ping_str}{wifi_str}{src_str}")

        print(f"--- {datetime.now().strftime('%H:%M:%S')} 완료, {INTERVAL_SEC}초 대기 ---\n")
        time.sleep(INTERVAL_SEC)

def main():
    client = create_client()
    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_start()
            print(f"[INFRA] MQTT 연결: {MQTT_BROKER}:{MQTT_PORT}")
            monitor_loop(client)
        except Exception as e:
            print(f"[INFRA] 연결 실패: {e} → 10초 후 재시도")
            time.sleep(10)

if __name__ == "__main__":
    main()
