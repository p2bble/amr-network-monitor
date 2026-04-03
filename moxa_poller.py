#!/usr/bin/env python3
"""
MOXA AWK-1137C RSSI Poller (server-side)
HTTP scraping via wireless_status.asp
MQTT topic: infra_test/moxa/{moxa_id}
"""
import hashlib, time, re, json, threading
import urllib.request, urllib.parse, urllib.error
import paho.mqtt.client as mqtt
from datetime import datetime

# ── 설정 ──────────────────────────────────────────────────────
MQTT_BROKER  = "192.168.145.5"
MQTT_PORT    = 1883
INTERVAL_SEC = 30

MOXA_USER = "admin"
MOXA_PASS = "moxa"

MOXA_LIST = [
    {"id": "MOXA-01", "ip": "192.168.145.51"},
    {"id": "MOXA-02", "ip": "192.168.145.52"},
    {"id": "MOXA-03", "ip": "192.168.145.53"},
    {"id": "MOXA-04", "ip": "192.168.145.54"},
    {"id": "MOXA-05", "ip": "192.168.145.55"},
    {"id": "MOXA-06", "ip": "192.168.145.56"},
    {"id": "MOXA-07", "ip": "192.168.145.57"},
    {"id": "MOXA-08", "ip": "192.168.145.58"},
    {"id": "MOXA-09", "ip": "192.168.145.59"},
    {"id": "MOXA-10", "ip": "192.168.145.60"},
    {"id": "MOXA-11", "ip": "192.168.145.61"},
    {"id": "MOXA-12", "ip": "192.168.145.62"},
    {"id": "MOXA-13", "ip": "192.168.145.63"},
]

# ── MOXA HTTP 인증 ─────────────────────────────────────────────
class MoxaSession:
    def __init__(self, ip, user, password, timeout=5):
        self.ip = ip
        self.user = user
        self.password = password
        self.timeout = timeout
        self.cookies = {}

    def _get(self, path):
        url = f"http://{self.ip}{path}"
        req = urllib.request.Request(url)
        if self.cookies:
            cookie_str = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
            req.add_header("Cookie", cookie_str)
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            # Extract Set-Cookie headers
            for h in r.headers.get_all("Set-Cookie") or []:
                m = re.match(r'(\w+)=([^;]*)', h)
                if m:
                    self.cookies[m.group(1)] = m.group(2)
            return r.read().decode(errors='replace')

    def login(self):
        try:
            # Step 1: Get nonce
            ts = int(time.time() * 1000)
            nonce = self._get(f"/webNonce?user={self.user}&time={ts}").strip()
            if not nonce or len(nonce) < 4:
                return False

            # Step 2: MD5(password + nonce) = ssionID1
            token = hashlib.md5((self.password + nonce).encode()).hexdigest()

            # Step 3: checkCookie - server registers session, returns sToken
            encoded = urllib.parse.quote(token)
            stoken = self._get(f"/checkCookie?user={self.user}&ssionID1={encoded}").strip()

            # Step 4: Set cookies
            self.cookies['ssionID1'] = token
            if stoken:
                self.cookies['sToken'] = stoken

            # Step 5: POST to home.asp to finalize session
            url = f"http://{self.ip}/home.asp"
            data = urllib.parse.urlencode({
                "Username": self.user,
                "Password": "",
                "iw_interface": "web"
            }).encode()
            req = urllib.request.Request(url, data=data, method="POST")
            cookie_str = "; ".join(f"{k}={v}" for k, v in self.cookies.items())
            req.add_header("Cookie", cookie_str)
            req.add_header("Content-Type", "application/x-www-form-urlencoded")
            try:
                with urllib.request.urlopen(req, timeout=self.timeout) as r:
                    for h in r.headers.get_all("Set-Cookie") or []:
                        m = re.match(r'(\w+)=([^;]*)', h)
                        if m:
                            self.cookies[m.group(1)] = m.group(2)
            except Exception:
                pass  # 302 redirect to Login.asp is expected on failed auth

            return True
        except Exception as e:
            print(f"[MOXA] {self.ip} 로그인 실패: {e}")
            return False

    def get_wireless_status(self):
        try:
            html = self._get("/wireless_status.asp")
            if "Login.asp" in html or len(html) < 100:
                # Session expired, re-login
                self.cookies = {}
                if not self.login():
                    return None
                html = self._get("/wireless_status.asp")
            return self._parse_status(html)
        except Exception as e:
            print(f"[MOXA] {self.ip} 상태 조회 실패: {e}")
            return None

    def _parse_status(self, html):
        """Parse wireless_status.asp HTML for signal info"""
        result = {}
        patterns = {
            "signal_dbm":  r"Signal strength.*?(-?\d+)\s*dBm",
            "noise_dbm":   r"Noise floor.*?(-?\d+)\s*dBm",
            "snr":         r"SNR.*?(\d+)",
            "ssid":        r"SSID.*?<td[^>]*>([^<]+)</td>",
            "bssid":       r"Current BSSID.*?<td[^>]*>([^<]+)</td>",
            "channel":     r"Channel.*?(\d+)\s*\(",
            "rate_mbps":   r"Rate.*?(\d+(?:\.\d+)?)\s*Mb/s",
        }
        for key, pat in patterns.items():
            m = re.search(pat, html, re.IGNORECASE | re.DOTALL)
            if m:
                val = m.group(1).strip()
                try:
                    result[key] = int(val) if '.' not in val else float(val)
                except ValueError:
                    result[key] = val
        return result if result else None


# ── MQTT ──────────────────────────────────────────────────────
def create_mqtt():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="moxa_poller")
    except AttributeError:
        client = mqtt.Client(client_id="moxa_poller")
    client.username_pw_set("cloud", "zmfhatm*0")
    return client


# ── 메인 루프 ─────────────────────────────────────────────────
sessions = {m["id"]: MoxaSession(m["ip"], MOXA_USER, MOXA_PASS) for m in MOXA_LIST}

def poll_moxa(client, moxa):
    mid = moxa["id"]
    sess = sessions[mid]
    status = sess.get_wireless_status()

    if status:
        payload = {
            "moxa_id":    mid,
            "ip":         moxa["ip"],
            "signal_dbm": status.get("signal_dbm", -100),
            "noise_dbm":  status.get("noise_dbm", -100),
            "snr":        status.get("snr", 0),
            "ssid":       status.get("ssid", ""),
            "bssid":      status.get("bssid", ""),
            "channel":    status.get("channel", 0),
            "rate_mbps":  status.get("rate_mbps", 0),
            "timestamp":  datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
        }
        topic = f"infra_test/moxa/{mid}"
        client.publish(topic, json.dumps(payload), qos=0)
        print(f"[MOXA] {mid} {moxa['ip']} signal={status.get('signal_dbm','?')}dBm "
              f"snr={status.get('snr','?')} rate={status.get('rate_mbps','?')}Mb/s")
    else:
        print(f"[MOXA] {mid} {moxa['ip']} 데이터 없음 (웹서버 미응답)")

def monitor_loop(client):
    # Pre-login all MOXAs
    for moxa in MOXA_LIST:
        mid = moxa["id"]
        print(f"[MOXA] {mid} 로그인 중...")
        sessions[mid].login()
        time.sleep(0.5)

    while True:
        for moxa in MOXA_LIST:
            try:
                poll_moxa(client, moxa)
            except Exception as e:
                print(f"[MOXA] {moxa['id']} 오류: {e}")
            time.sleep(1)
        print(f"--- {datetime.now().strftime('%H:%M:%S')} MOXA 폴링 완료, {INTERVAL_SEC}초 대기 ---")
        time.sleep(INTERVAL_SEC)

def main():
    client = create_mqtt()
    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_start()
            print(f"[MOXA] MQTT 연결: {MQTT_BROKER}:{MQTT_PORT}")
            monitor_loop(client)
        except Exception as e:
            print(f"[MOXA] 오류: {e} → 10초 후 재시도")
            time.sleep(10)

if __name__ == "__main__":
    main()
