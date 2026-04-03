#!/usr/bin/env python3
"""
서버사이드 MOXA AWK-1137C SNMP 폴러
서버(192.168.145.5)에서 MOXA WiFi IP로 SNMP GET 후 MQTT 발행
MQTT topic: infra_test/moxa/{robot_id}
"""
import socket, time, json
import paho.mqtt.client as mqtt
from datetime import datetime

MQTT_BROKER  = "192.168.145.5"
MQTT_PORT    = 1883
INTERVAL_SEC = 5
COMMUNITY    = b'public'

# MOXA WiFi IP → 연결된 로봇 ID 매핑
MOXA_DEVICES = [
    {"ip": "192.168.145.51", "robot_id": "sebang001"},
    {"ip": "192.168.145.52", "robot_id": "sebang002"},
    {"ip": "192.168.145.53", "robot_id": "sebang003"},
    {"ip": "192.168.145.54", "robot_id": "sebang004"},
    {"ip": "192.168.145.55", "robot_id": "sebang005"},
    {"ip": "192.168.145.56", "robot_id": "sebang006"},
    {"ip": "192.168.145.57", "robot_id": "sebang007"},
    {"ip": "192.168.145.58", "robot_id": "sebang008"},
    {"ip": "192.168.145.59", "robot_id": "sebang009"},
    {"ip": "192.168.145.60", "robot_id": "sebang010"},
    {"ip": "192.168.145.61", "robot_id": "sebang011"},
    {"ip": "192.168.145.62", "robot_id": "sebang012"},
    {"ip": "192.168.145.63", "robot_id": "sebang013"},
]

# 확인된 OID (1.11.17.1 live status 테이블)
OID_CHANNEL = "1.3.6.1.4.1.8691.15.35.1.11.17.1.2.1.1"
OID_BSSID   = "1.3.6.1.4.1.8691.15.35.1.11.17.1.3.1.1"
OID_RSSI    = "1.3.6.1.4.1.8691.15.35.1.11.17.1.4.1.1"
OID_RATE    = "1.3.6.1.4.1.8691.15.35.1.11.17.1.5.1.1"
OID_SSID    = "1.3.6.1.4.1.8691.15.35.1.11.17.1.6.1.1"
OID_SNR     = "1.3.6.1.4.1.8691.15.35.1.11.17.1.11.1.1"
OID_NOISE   = "1.3.6.1.4.1.8691.15.35.1.11.17.1.12.1.1"

def encode_oid(parts):
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

def tlv(tag, val):
    l = len(val)
    if l < 128:   return bytes([tag, l]) + val
    elif l < 256: return bytes([tag, 0x81, l]) + val
    else:         return bytes([tag, 0x82, l >> 8, l & 0xff]) + val

def snmp_get(host, oid_str, timeout=2):
    try:
        parts = [int(x) for x in oid_str.split('.')]
        oid_b   = tlv(0x06, encode_oid(parts))
        varbind = tlv(0x30, oid_b + b'\x05\x00')
        pdu     = tlv(0xa0, tlv(0x02, b'\x01') + b'\x02\x01\x00\x02\x01\x00' + tlv(0x30, varbind))
        msg     = tlv(0x30, b'\x02\x01\x01' + tlv(0x04, COMMUNITY) + pdu)

        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.settimeout(timeout)
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

def create_mqtt():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="moxa_snmp_poller")
    except AttributeError:
        client = mqtt.Client(client_id="moxa_snmp_poller")
    client.username_pw_set("cloud", "zmfhatm*0")
    return client

def poll_all(client):
    for dev in MOXA_DEVICES:
        ip       = dev["ip"]
        robot_id = dev["robot_id"]

        channel = snmp_get(ip, OID_CHANNEL)
        bssid   = snmp_get(ip, OID_BSSID)
        rssi    = snmp_get(ip, OID_RSSI)
        rate    = snmp_get(ip, OID_RATE)
        ssid    = snmp_get(ip, OID_SSID)
        snr     = snmp_get(ip, OID_SNR)
        noise   = snmp_get(ip, OID_NOISE)

        reachable = channel is not None

        payload = {
            "robot_id":  robot_id,
            "moxa_ip":   ip,
            "channel":   channel if channel else "Error",
            "bssid":     bssid   if bssid   else "Unknown",
            "rssi":      rssi    if rssi    else "N/A",
            "rate_mbps": rate    if rate    else "N/A",
            "ssid":      ssid    if ssid    else "Unknown",
            "snr":       snr     if snr     else "N/A",
            "noise":     noise   if noise   else "N/A",
            "reachable": reachable,
            "timestamp": datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        }

        topic = f"infra_test/moxa/{robot_id}"
        try:
            client.publish(topic, json.dumps(payload), qos=0)
        except Exception as e:
            print(f"[MOXA-POLL] {robot_id} publish 실패: {e}")

        status = f"ch={channel} rssi={rssi}dBm snr={snr}" if reachable else "SNMP timeout"
        print(f"[MOXA-POLL] {robot_id} ({ip}) {status} ssid={ssid} bssid={bssid}")

def main():
    client = create_mqtt()
    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_start()
            print(f"[MOXA-POLL] MQTT 연결: {MQTT_BROKER}:{MQTT_PORT}")
            while True:
                poll_all(client)
                time.sleep(INTERVAL_SEC)
        except Exception as e:
            print(f"[MOXA-POLL] 오류: {e} → 10초 후 재시도")
            time.sleep(10)

if __name__ == "__main__":
    main()
