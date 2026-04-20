#!/usr/bin/env python3
"""
AMR 장애 상관관계 진단 서비스 v2

핵심: MQTT heartbeat gap 감지 → 로밍/AP장애/백본/디바이스 원인 자동 분류

진단 트리:
  DISCONNECT 감지
  ├── 전체 50%+ 동시 단절? → backbone (서버/백본 장애)
  ├── ±30초 내 AP DOWN?    → ap_failure
  ├── ±30초 내 로밍 이벤트? → roaming (RSSI < -75이면 sticky_client)
  └── 해당 없음            → device (MOXA/로봇PC 자체 문제)

구독:
  infra_test/network_status/+   로봇 heartbeat
  infra_test/network_infra/ap/+ AP 상태 (infra_monitor.py)
발행:
  infra_test/diagnosis/{robot_id}
  infra_test/diagnosis/summary
로그:
  /home/clobot/amr_deploy/logs/diagnostics.log
"""
import json, time, os, threading
from datetime import datetime, timedelta
from collections import deque
import paho.mqtt.client as mqtt

# ── 설정 ──────────────────────────────────────────────────────
MQTT_BROKER  = "192.168.145.5"
MQTT_PORT    = 1883
LOG_DIR      = "/home/clobot/amr_deploy/logs"
LOG_FILE     = os.path.join(LOG_DIR, "diagnostics.log")
LOG_MAX_MB   = 50

ROBOT_IDS    = [f"sebang{i:03d}" for i in range(1, 14)]

DISCONNECT_SEC   = 30    # heartbeat gap 이 이상이면 오프라인 판정
CORRELATION_SEC  = 30    # 끊김 시점 전 N초를 상관관계 윈도우로 사용
BACKBONE_RATIO   = 0.5   # 전체 N% 이상 동시 단절 → 백본/서버 장애
STICKY_RSSI      = -75   # dBm: 로밍 전 RSSI가 이보다 낮으면 Sticky Client
PUBLISH_SEC      = 10    # 진단 결과 발행 주기

# ── 전역 상태 ──────────────────────────────────────────────────
_lock   = threading.Lock()
_robots = {}   # robot_id → RobotState (아래 클래스)

# 글로벌 이벤트 타임라인
_roaming_events = deque(maxlen=500)   # {robot_id, time, bssid_from, bssid_to, rssi_before}
_ap_events      = deque(maxlen=300)   # {ap_id, time, event: "DOWN"|"UP"}

os.makedirs(LOG_DIR, exist_ok=True)


# ── 로봇 상태 모델 ─────────────────────────────────────────────
class RobotState:
    def __init__(self, robot_id):
        self.id              = robot_id
        self.last_seen       = None      # datetime: 마지막 heartbeat 수신
        self.last_bssid      = ""
        self.last_rssi       = 0
        self.is_connected    = False
        self.disconnect_start = None     # datetime: 단절 시작 시각
        self.disconnects     = deque(maxlen=20)  # 최근 단절 이력

    @property
    def disconnect_count_1h(self):
        cutoff = datetime.now() - timedelta(hours=1)
        return sum(1 for d in self.disconnects
                   if datetime.fromisoformat(d["time"]) > cutoff)

    def to_dict(self):
        now = datetime.now()
        gap = (now - self.last_seen).total_seconds() if self.last_seen else -1
        return {
            "robot_id":            self.id,
            "connected":           self.is_connected,
            "last_seen_sec_ago":   round(gap, 1) if gap >= 0 else -1,
            "last_bssid":          self.last_bssid,
            "last_rssi":           self.last_rssi,
            "disconnect_count_1h": self.disconnect_count_1h,
            "last_disconnect":     self.disconnects[0] if self.disconnects else None,
            "disconnect_history":  list(self.disconnects)[:5],  # 최근 5건
        }


# ── 로깅 ──────────────────────────────────────────────────────
def log(msg: str):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_MB * 1024 * 1024:
            os.rename(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


def get_robot(robot_id) -> RobotState:
    if robot_id not in _robots:
        _robots[robot_id] = RobotState(robot_id)
    return _robots[robot_id]


def _parse_rssi(raw) -> int:
    try:
        return int(str(raw).replace("dBm", "").strip())
    except (ValueError, TypeError):
        return 0


# ── 상관관계 분석 ──────────────────────────────────────────────
def classify_root_cause(robot_id: str, disconnect_time: datetime, duration_sec: float) -> dict:
    """
    단절 시점 기준으로 원인 분류. 반환: {cause, detail, action}
    cause: backbone | ap_failure | sticky_client | roaming | device
    """
    w_start = disconnect_time - timedelta(seconds=CORRELATION_SEC)
    w_end   = disconnect_time + timedelta(seconds=15)

    # ── 1. 백본/서버: 동시 다발 단절 ────────────────────────────
    simultaneous = sum(
        1 for rid, rs in _robots.items()
        if rid != robot_id
        and rs.disconnect_start is not None
        and abs((rs.disconnect_start - disconnect_time).total_seconds()) < 20
    )
    total = max(len(_robots), 1)
    if (simultaneous + 1) / total >= BACKBONE_RATIO:
        return {
            "cause":  "backbone",
            "detail": f"동시 단절 {simultaneous + 1}/{total}대 — 서버/백본 장애 의심",
            "action": "서버 상태 확인 (docker ps, EMQX 브로커)\n백본 스위치 포트 에러 확인",
        }

    # ── 2. AP 장애: 해당 시간대 AP DOWN 이벤트 ─────────────────
    for ev in _ap_events:
        if ev["event"] == "DOWN" and w_start <= ev["time"] <= w_end:
            ap_id = ev["ap_id"]
            rs    = _robots.get(robot_id)
            bssid_hint = f", 로봇 BSSID: {rs.last_bssid[:11]}" if rs and rs.last_bssid else ""
            return {
                "cause":  "ap_failure",
                "detail": f"{ap_id} 다운 감지 (단절 {int(disconnect_time.timestamp()-ev['time'].timestamp())}초 전{bssid_hint})",
                "action": f"{ap_id} 전원/케이블/PoE 스위치 포트 확인",
            }

    # ── 3. 로밍: BSSID 변경 이벤트 ─────────────────────────────
    for ev in _roaming_events:
        if ev["robot_id"] == robot_id and w_start <= ev["time"] <= w_end:
            rssi_b    = ev.get("rssi_before", 0)
            bssid_f   = ev.get("bssid_from", "?")
            bssid_t   = ev.get("bssid_to",   "?")
            dur_ms    = int(duration_sec * 1000)
            if rssi_b and rssi_b < STICKY_RSSI:
                return {
                    "cause":  "sticky_client",
                    "detail": f"로밍 전 RSSI {rssi_b}dBm (Sticky Client) → {bssid_f[:11]}→{bssid_t[:11]}, {dur_ms}ms 단절",
                    "action": "MOXA roamingThreshold5G -75dBm, roamingDifference5G 8 이상 설정",
                }
            return {
                "cause":  "roaming",
                "detail": f"정상 로밍 중 단절: {bssid_f[:11]}→{bssid_t[:11]}, {dur_ms}ms",
                "action": "단순 로밍 지연 (802.11r 미지원 환경 정상 범위)\n반복 발생 시 AP 커버리지 재검토",
            }

    # ── 4. 원인 불명 ─────────────────────────────────────────────
    dur = int(duration_sec)
    return {
        "cause":  "device",
        "detail": f"{dur}초 단절, 연관 이벤트 없음 — MOXA/로봇PC 자체 문제 의심",
        "action": "MOXA 상태 확인 (웹UI 또는 LED)\nsystemctl status amr-agent on robot PC",
    }


# ── MQTT 메시지 처리 ──────────────────────────────────────────
def on_robot_heartbeat(robot_id: str, data: dict):
    """로봇 heartbeat 수신 — 로밍 감지 + 복구 감지"""
    with _lock:
        rs  = get_robot(robot_id)
        now = datetime.now()

        new_bssid = data.get("bssid", "")
        new_rssi  = _parse_rssi(data.get("rssi", "0"))

        # ── 로밍 감지: BSSID 변경 ─────────────────────────────
        valid_bssid = new_bssid not in ("", "Unknown", "Error", "Disconnected")
        if rs.last_bssid and rs.last_bssid != new_bssid and valid_bssid:
            _roaming_events.appendleft({
                "robot_id":   robot_id,
                "time":       now,
                "bssid_from": rs.last_bssid,
                "bssid_to":   new_bssid,
                "rssi_before": rs.last_rssi,
            })
            log(f"[ROAM] {robot_id}: {rs.last_bssid[:11]}→{new_bssid[:11]} "
                f"RSSI_before={rs.last_rssi}dBm")

        # ── 복구 감지: 이전에 단절 상태였으면 원인 분류 ────────
        if not rs.is_connected and rs.disconnect_start is not None:
            duration = (now - rs.disconnect_start).total_seconds()
            if duration >= 5:   # 5초 이상만 기록 (짧은 순간 노이즈 제외)
                cause_info = classify_root_cause(robot_id, rs.disconnect_start, duration)
                event = {
                    "time":         rs.disconnect_start.strftime("%Y-%m-%dT%H:%M:%S"),
                    "duration_sec": round(duration, 1),
                    "cause":        cause_info["cause"],
                    "detail":       cause_info["detail"],
                    "action":       cause_info["action"],
                }
                rs.disconnects.appendleft(event)
                log(f"[RECOVER] {robot_id}: {duration:.0f}초 단절 복구 "
                    f"→ {cause_info['cause']}: {cause_info['detail']}")

        rs.last_seen       = now
        rs.last_bssid      = new_bssid if valid_bssid else rs.last_bssid
        rs.last_rssi       = new_rssi
        rs.is_connected    = True
        rs.disconnect_start = None


def on_ap_status(ap_id: str, data: dict):
    """AP UP/DOWN 이벤트 기록"""
    status = data.get("status", "")
    if status not in ("UP", "DOWN"):
        return
    with _lock:
        # 중복 이벤트 스킵 (직전과 같은 상태면 기록 안 함)
        for ev in list(_ap_events)[:3]:
            if ev["ap_id"] == ap_id and ev["event"] == status:
                delta = (datetime.now() - ev["time"]).total_seconds()
                if delta < 30:
                    return
        _ap_events.appendleft({
            "ap_id": ap_id,
            "time":  datetime.now(),
            "event": status,
        })
        if status == "DOWN":
            log(f"[AP-DOWN] {ap_id}")
        else:
            log(f"[AP-UP]   {ap_id}")


def on_message(client, userdata, msg):
    try:
        data  = json.loads(msg.payload.decode())
        topic = msg.topic
        if topic.startswith("infra_test/network_status/"):
            on_robot_heartbeat(topic.split("/")[-1], data)
        elif topic.startswith("infra_test/network_infra/ap/"):
            on_ap_status(topic.split("/")[-1], data)
    except Exception as e:
        log(f"[MSG] 처리 오류: {e}")


# ── 오프라인 감지 루프 ────────────────────────────────────────
def offline_detector():
    """5초마다 heartbeat gap 확인 → 오프라인 판정"""
    while True:
        time.sleep(5)
        now = datetime.now()
        with _lock:
            for robot_id in ROBOT_IDS:
                rs = get_robot(robot_id)
                if rs.last_seen is None:
                    continue
                gap = (now - rs.last_seen).total_seconds()
                # 연결 상태인데 gap 초과 → 단절 시작
                if rs.is_connected and gap > DISCONNECT_SEC:
                    rs.is_connected     = False
                    rs.disconnect_start = rs.last_seen
                    log(f"[OFFLINE] {robot_id}: {int(gap)}초 무응답")


# ── 진단 결과 발행 ────────────────────────────────────────────
def publisher(client):
    while True:
        time.sleep(PUBLISH_SEC)
        with _lock:
            # 개별 로봇
            for robot_id, rs in _robots.items():
                try:
                    client.publish(
                        f"infra_test/diagnosis/{robot_id}",
                        json.dumps(rs.to_dict()), qos=0)
                except Exception as e:
                    log(f"[PUB] {robot_id}: {e}")

            # 전체 요약
            total     = len(_robots)
            connected = sum(1 for rs in _robots.values() if rs.is_connected)
            alerts    = [
                {"id": rid, "cause": rs.disconnects[0]["cause"] if rs.disconnects else "unknown"}
                for rid, rs in _robots.items() if not rs.is_connected
            ]
            # 최근 1시간 끊김 빈도 상위 로봇
            freq_list = sorted(
                [{"id": rid, "count": rs.disconnect_count_1h}
                 for rid, rs in _robots.items() if rs.disconnect_count_1h > 0],
                key=lambda x: -x["count"]
            )[:5]
            summary = {
                "timestamp":     datetime.now().strftime("%Y-%m-%dT%H:%M:%S"),
                "total":         total,
                "connected":     connected,
                "offline":       total - connected,
                "offline_robots": alerts,
                "freq_1h":       freq_list,  # 자주 끊기는 로봇 순위
            }
            try:
                client.publish("infra_test/diagnosis/summary",
                               json.dumps(summary), qos=0)
            except Exception as e:
                log(f"[PUB] summary: {e}")


# ── MQTT 설정 ─────────────────────────────────────────────────
def on_connect(client, userdata, flags, rc):
    if rc == 0:
        client.subscribe("infra_test/network_status/+", qos=0)
        client.subscribe("infra_test/network_infra/ap/+", qos=0)
        log("[MQTT] 연결 완료")
    else:
        log(f"[MQTT] 연결 실패 rc={rc}")


def create_client():
    try:
        c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="amr_diagnostics_v2")
    except AttributeError:
        c = mqtt.Client(client_id="amr_diagnostics_v2")
    c.username_pw_set("cloud", "zmfhatm*0")
    c.on_connect = on_connect
    c.on_message = on_message
    return c


def main():
    log("[DIAG] AMR 진단 서비스 v2 시작")
    client = create_client()
    threading.Thread(target=offline_detector, daemon=True).start()

    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_start()
            publisher(client)
        except Exception as e:
            log(f"[MQTT] 오류: {e} → 10초 후 재시도")
            time.sleep(10)


if __name__ == "__main__":
    main()
