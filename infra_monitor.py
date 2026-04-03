#!/usr/bin/env python3
"""
AMR 인프라 모니터링 에이전트 (서버 실행용)
AP #01~15, PoE 스위치 #01~03, 메인 스위치 생존 여부를 ping으로 모니터링
MQTT 토픽: infra_test/network_infra/{device_type}/{device_id}
"""
import subprocess, time, json, threading, socket
from datetime import datetime
import paho.mqtt.client as mqtt

# ── 설정 ──────────────────────────────────────────────────────
MQTT_BROKER = "192.168.145.5"
MQTT_PORT   = 1883
INTERVAL_SEC = 10   # 모니터링 주기 (초)

# WiFi 기능 비활성 AP (전원은 켜져 있으나 WiFi 미운영)
WIFI_DISABLED = {"AP-05", "AP-10", "AP-13"}

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
    while True:
        for dev in DEVICES:
            up, ping_ms = ping(dev["ip"])
            payload = {
                "device_id":      dev["id"],
                "device_type":    dev["type"],
                "ip":             dev["ip"],
                "status":         "UP" if up else "DOWN",
                "wifi_disabled":  dev["id"] in WIFI_DISABLED,
                "ping_ms":        ping_ms,
                "timestamp":      datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
            }
            topic = f"infra_test/network_infra/{dev['type'].lower()}/{dev['id']}"
            try:
                client.publish(topic, json.dumps(payload), qos=0)
            except Exception as e:
                print(f"[INFRA] 발행 실패 {dev['id']}: {e}")

            status_str = "UP" if up else "DOWN"
            ping_str   = f"{ping_ms}ms" if up else "timeout"
            print(f"[{dev['type']:6}] {dev['id']:12} {dev['ip']:18} {status_str:4} {ping_str}")

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
