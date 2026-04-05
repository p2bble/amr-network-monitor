#!/usr/bin/env python3
"""
AMR 자동 진단 서비스 (amr_diagnostics.py)
서버에서 전체 로봇 데이터를 수집·분석해 장애 원인을 자동 분류합니다.

구독: infra_test/network_status/+
발행: infra_test/diagnosis/summary
     infra_test/diagnosis/{robot_id}
로그: /home/clobot/amr_deploy/logs/diagnostics.log

실행: python3 amr_diagnostics.py
서비스: amr-diagnostics.service
"""
import json
import time
import os
import threading
from datetime import datetime
from collections import deque, Counter
import paho.mqtt.client as mqtt

# ── 설정 ──────────────────────────────────────────────────────
MQTT_BROKER    = "192.168.145.5"
MQTT_PORT      = 1883
INTERVAL_SEC   = 10       # 진단 주기 (초)

LOG_DIR  = "/home/clobot/amr_deploy/logs"
LOG_FILE = os.path.join(LOG_DIR, "diagnostics.log")
LOG_MAX_MB = 50           # 로그 파일 최대 크기 (MB)

# 임계값
RSSI_WEAK      = -75      # dBm — 약함
RSSI_CRITICAL  = -85      # dBm — 불량
PING_WARN      = 100      # ms  — 경고
PING_CRIT      = 500      # ms  — 심각
AGENT_TIMEOUT  = 60       # 초  — 에이전트 무응답 판정
ROAM_STUCK_MIN = 10       # 분  — RSSI 약함인데 로밍 없음 → MOXA 고착
MULTI_AP_MIN   = 2        # 대  — 동일 BSSID N대 이상 동시 이상 → AP 문제
MULTI_CH_MIN   = 3        # 대  — 동일 채널 N대 이상 동시 이상 → 채널 간섭
BACKBONE_RATIO = 0.5      # 비율 — 전체의 N% 이상 동시 이상 → 백본 문제

ROBOT_IDS = [f"sebang{i:03d}" for i in range(1, 14)]

# ── 전역 상태 ──────────────────────────────────────────────────
_robots: dict = {}         # robot_id → {"latest": dict, "history": deque}
_lock = threading.Lock()
_prev_alerts: dict = {}    # robot_id → last summary (중복 로그 방지)
_prev_cross: list  = []    # 이전 크로스 진단 (중복 방지)

os.makedirs(LOG_DIR, exist_ok=True)


# ── 로깅 ──────────────────────────────────────────────────────
def log(msg: str):
    ts   = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = f"[{ts}] {msg}"
    print(line, flush=True)
    try:
        # 로그 파일 크기 초과 시 롤오버
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > LOG_MAX_MB * 1024 * 1024:
            os.rename(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except Exception:
        pass


# ── 단일 로봇 진단 ─────────────────────────────────────────────
def diagnose_single(robot_id: str, latest: dict, history: list) -> tuple:
    """
    단일 로봇 진단.
    반환: (layer, summary, detail, action)
    layer: "normal" | "agent" | "moxa" | "ap" | "network" | "backbone"
    """
    now = datetime.now()

    # ── 에이전트 무응답 ──────────────────────────────────────────
    last_seen = latest.get("_received_at")
    if last_seen and (now - last_seen).total_seconds() > AGENT_TIMEOUT:
        secs = int((now - last_seen).total_seconds())
        return (
            "agent",
            f"에이전트 무응답 ({secs}초)",
            f"{secs}초째 데이터 미수신",
            "systemctl status amr-agent / 전원·케이블 확인"
        )

    rssi_str = latest.get("rssi", "N/A")
    ping_ms  = float(latest.get("ping_ms", 0) or 0)
    status   = latest.get("status", "NORMAL")
    bssid    = latest.get("bssid", "")
    channel  = latest.get("channel", "Unknown")
    snr      = latest.get("snr", "N/A")

    rssi = None
    try:
        rssi = int(str(rssi_str).replace("dBm", "").strip())
    except (ValueError, TypeError):
        pass

    # ── 연결 단절 ────────────────────────────────────────────────
    if status in ("DISCONNECTED", "NETWORK_UNREACHABLE"):
        return (
            "network",
            f"연결 단절 ({status})",
            f"ping={ping_ms:.0f}ms  bssid={bssid}",
            "MOXA 상태 / AP 연결 / 케이블 확인"
        )

    if rssi is not None:
        # ── 음영구간 ──────────────────────────────────────────────
        if rssi < RSSI_CRITICAL:
            return (
                "ap",
                f"음영구간 ({rssi}dBm)",
                f"AP 신호 불량 (기준 {RSSI_CRITICAL}dBm)  ch={channel}",
                "해당 구역 AP 추가 설치 / AP Tx Power 상향"
            )

        # ── MOXA 로밍 고착 ───────────────────────────────────────
        if rssi < RSSI_WEAK:
            cutoff = ROAM_STUCK_MIN * 60
            window = [h for h in history
                      if (now - h["_received_at"]).total_seconds() < cutoff]
            if len(window) >= 3:
                bssids = set(h.get("bssid", "") for h in window
                             if h.get("bssid") not in ("", "Unknown", "Disconnected", "Error"))
                if len(bssids) == 1:
                    return (
                        "moxa",
                        f"MOXA 로밍 고착 ({rssi}dBm)",
                        f"RSSI 약함이지만 {ROAM_STUCK_MIN}분간 로밍 없음  "
                        f"BSSID={bssid}  ch={channel}  SNR={snr}",
                        "MOXA 로밍 임계값 확인 (-70dBm 권장) / MOXA 재부팅 검토"
                    )
            return (
                "ap",
                f"AP 신호 약함 ({rssi}dBm)",
                f"기준 {RSSI_WEAK}dBm  ch={channel}",
                "AP Tx Power 상향 / AP 추가 검토"
            )

    # ── Ping 지연 ────────────────────────────────────────────────
    if ping_ms > PING_CRIT:
        return (
            "network",
            f"Ping 심각 지연 ({ping_ms:.0f}ms)",
            f"RSSI={rssi_str}  ch={channel}",
            "스위치 STP 루프 점검 / 서버 부하 확인"
        )
    if ping_ms > PING_WARN:
        return (
            "network",
            f"Ping 지연 ({ping_ms:.0f}ms)",
            f"RSSI={rssi_str}  ch={channel}",
            "채널 간섭 / 서버 부하 점검"
        )

    return ("normal", "정상", "", "")


# ── 크로스-로봇 진단 ───────────────────────────────────────────
def diagnose_cross(all_robots: dict) -> list:
    """
    여러 로봇의 동시 패턴으로 공통 원인 감지.
    반환: [{"ids": [...], "layer": str, "summary": str, "detail": str, "action": str}, ...]
    """
    now = datetime.now()
    results = []

    # 온라인 + 이상 로봇 분류
    online_robots = []
    bad_robots    = []

    for rid, d in all_robots.items():
        latest = d.get("latest", {})
        if not latest:
            continue
        last_seen = latest.get("_received_at")
        if not last_seen or (now - last_seen).total_seconds() > AGENT_TIMEOUT:
            continue  # 오프라인은 단일 진단에서 처리

        online_robots.append(rid)

        rssi_str = latest.get("rssi", "N/A")
        ping_ms  = float(latest.get("ping_ms", 0) or 0)
        status   = latest.get("status", "NORMAL")
        bssid    = latest.get("bssid", "")
        channel  = latest.get("channel", "Unknown")

        rssi = None
        try:
            rssi = int(str(rssi_str).replace("dBm", "").strip())
        except (ValueError, TypeError):
            pass

        is_bad = (
            status in ("DISCONNECTED", "NETWORK_UNREACHABLE")
            or (rssi is not None and rssi < RSSI_WEAK)
            or ping_ms > PING_WARN
        )
        if is_bad:
            bad_robots.append({
                "id": rid, "rssi": rssi, "bssid": bssid,
                "channel": channel, "ping_ms": ping_ms, "status": status
            })

    if not bad_robots or not online_robots:
        return results

    total_online = len(online_robots)

    # ── 전체 백본 장애 (온라인 로봇의 절반 이상) ──────────────
    if len(bad_robots) >= max(MULTI_AP_MIN, int(total_online * BACKBONE_RATIO)):
        ids = [r["id"] for r in bad_robots]
        results.append({
            "ids":     ids,
            "layer":   "backbone",
            "summary": f"광범위 장애 ({len(bad_robots)}/{total_online}대)",
            "detail":  "온라인 로봇 절반 이상 동시 이상",
            "action":  "서버·메인 스위치·백본 AP 우선 점검",
        })
        return results  # 백본 장애면 하위 진단 생략

    # ── 동일 BSSID(AP) 여러 대 이상 ──────────────────────────
    bssid_groups = Counter(
        r["bssid"] for r in bad_robots
        if r["bssid"] not in ("", "Unknown", "Disconnected", "Error")
    )
    for bssid, cnt in bssid_groups.items():
        if cnt >= MULTI_AP_MIN:
            affected = [r["id"] for r in bad_robots if r["bssid"] == bssid]
            results.append({
                "ids":     affected,
                "layer":   "ap",
                "summary": f"AP 장애 의심 ({cnt}대 동시 이상)",
                "detail":  f"BSSID {bssid} 연결 로봇 {cnt}대 동시 이상",
                "action":  f"AP(BSSID:{bssid}) 전원·연결 상태 확인",
            })

    # ── 동일 채널 여러 대 이상 ────────────────────────────────
    ch_groups = Counter(
        r["channel"] for r in bad_robots
        if r["channel"] not in ("Unknown", "Error", "")
    )
    for ch, cnt in ch_groups.items():
        if cnt >= MULTI_CH_MIN:
            # 이미 AP 장애로 잡힌 그룹과 겹치면 스킵
            affected = [r["id"] for r in bad_robots if r["channel"] == ch]
            results.append({
                "ids":     affected,
                "layer":   "channel",
                "summary": f"채널 {ch} 간섭 의심 ({cnt}대)",
                "detail":  f"채널 {ch}에서 {cnt}대 동시 RSSI 저하 / 지연",
                "action":  f"채널 {ch} AP 부하 / 인접 채널 점검",
            })

    return results


# ── 진단 실행 및 MQTT 발행 ────────────────────────────────────
def run_diagnosis(client):
    with _lock:
        snapshot = {
            rid: {
                "latest":  dict(d.get("latest", {})),
                "history": list(d.get("history", [])),
            }
            for rid in ROBOT_IDS
            for d in [_robots.get(rid, {})]
        }

    now = datetime.now()
    now_str = now.strftime("%Y-%m-%dT%H:%M:%S")

    robot_results = {}
    normal_count  = 0
    alert_count   = 0
    offline_list  = []

    for rid in ROBOT_IDS:
        d       = snapshot.get(rid, {})
        latest  = d.get("latest", {})
        history = d.get("history", [])

        if not latest:
            offline_list.append(rid)
            robot_results[rid] = {
                "layer": "offline", "summary": "데이터 없음",
                "detail": "에이전트 미배포 또는 오프라인", "action": ""
            }
            continue

        layer, summary, detail, action = diagnose_single(rid, latest, history)
        robot_results[rid] = {
            "layer": layer, "summary": summary,
            "detail": detail, "action": action
        }

        if layer == "normal":
            normal_count += 1
        else:
            alert_count += 1
            # 변화된 경우에만 로그 기록 (중복 방지)
            if _prev_alerts.get(rid) != summary:
                log(f"[{rid}] [{layer.upper()}] {summary}  |  {detail}")
            _prev_alerts[rid] = summary

        # 개별 진단 발행
        payload = {
            "robot_id":  rid,
            "layer":     layer,
            "summary":   summary,
            "detail":    detail,
            "action":    action,
            "timestamp": now_str,
        }
        try:
            client.publish(
                f"infra_test/diagnosis/{rid}",
                json.dumps(payload, ensure_ascii=False),
                qos=0
            )
        except Exception as e:
            log(f"[DIAG] {rid} publish 실패: {e}")

    # 정상 복구된 로봇 알림 클리어
    for rid in list(_prev_alerts.keys()):
        if robot_results.get(rid, {}).get("layer") == "normal":
            if _prev_alerts.get(rid) and _prev_alerts[rid] != "정상":
                log(f"[{rid}] [RECOVER] 정상 복구")
            _prev_alerts[rid] = "정상"

    # 크로스 진단
    cross_faults = diagnose_cross(snapshot)
    for cf in cross_faults:
        key = cf["summary"]
        if key not in [c["summary"] for c in _prev_cross]:
            log(f"[CROSS][{cf['layer'].upper()}] {cf['summary']}  |  {cf['detail']}  |  로봇: {', '.join(cf['ids'])}")
    _prev_cross.clear()
    _prev_cross.extend(cross_faults)

    # 전체 요약 발행
    issues = [
        {"robot_id": rid, **v}
        for rid, v in robot_results.items()
        if v["layer"] not in ("normal", "offline")
    ]
    summary_payload = {
        "timestamp":    now_str,
        "total_robots": len(ROBOT_IDS),
        "online":       len(ROBOT_IDS) - len(offline_list),
        "normal_count": normal_count,
        "alert_count":  alert_count,
        "offline":      offline_list,
        "issues":       issues,
        "cross_faults": cross_faults,
    }
    try:
        client.publish(
            "infra_test/diagnosis/summary",
            json.dumps(summary_payload, ensure_ascii=False),
            qos=0
        )
    except Exception as e:
        log(f"[DIAG] summary publish 실패: {e}")

    # 콘솔 요약 출력
    status_str = f"정상 {normal_count}대 / 이상 {alert_count}대 / 오프라인 {len(offline_list)}대"
    if cross_faults:
        status_str += f" / 크로스 알림 {len(cross_faults)}건"
    log(f"[DIAG] {status_str}")


# ── MQTT 핸들러 ───────────────────────────────────────────────
def on_connect(client, userdata, flags, rc):
    if rc == 0:
        client.subscribe("infra_test/network_status/+", qos=0)
        log("[DIAG] MQTT 연결 완료, 구독 시작: infra_test/network_status/+")
    else:
        log(f"[DIAG] MQTT 연결 실패: rc={rc}")


def on_message(client, userdata, msg):
    try:
        data = json.loads(msg.payload.decode())
        robot_id = data.get("robot_id")
        if not robot_id:
            return
        data["_received_at"] = datetime.now()
        with _lock:
            if robot_id not in _robots:
                _robots[robot_id] = {
                    "latest":  {},
                    "history": deque(maxlen=360),  # 최대 1시간 (10초 × 360)
                }
            _robots[robot_id]["latest"] = data
            _robots[robot_id]["history"].append(data)
    except Exception as e:
        log(f"[DIAG] 메시지 파싱 오류: {e}")


# ── MQTT 클라이언트 생성 ──────────────────────────────────────
def create_client():
    try:
        client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION1, client_id="amr_diagnostics")
    except AttributeError:
        client = mqtt.Client(client_id="amr_diagnostics")
    client.username_pw_set("cloud", "zmfhatm*0")
    client.on_connect = on_connect
    client.on_message = on_message
    return client


# ── 메인 ──────────────────────────────────────────────────────
def main():
    log("[DIAG] AMR 자동 진단 서비스 시작")
    log(f"[DIAG] 진단 주기: {INTERVAL_SEC}초 / 로그: {LOG_FILE}")
    client = create_client()

    while True:
        try:
            client.connect(MQTT_BROKER, MQTT_PORT, keepalive=60)
            client.loop_start()
            log(f"[DIAG] MQTT 연결: {MQTT_BROKER}:{MQTT_PORT}")
            # 첫 데이터 수집 대기
            time.sleep(15)
            while True:
                run_diagnosis(client)
                time.sleep(INTERVAL_SEC)
        except Exception as e:
            log(f"[DIAG] 오류: {e} → 10초 후 재시도")
            try:
                client.loop_stop()
            except Exception:
                pass
            time.sleep(10)


if __name__ == "__main__":
    main()
