import 'dart:async';
import 'dart:convert';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:fl_chart/fl_chart.dart';
// 플랫폼별 MQTT 클라이언트 팩토리 (웹: MqttBrowserClient / 네이티브: MqttServerClient)
import 'mqtt_factory.dart'
    if (dart.library.html) 'mqtt_factory_web.dart'
    if (dart.library.io) 'mqtt_factory_native.dart';

void main() => runApp(const AmrMonitorApp());

class AmrMonitorApp extends StatelessWidget {
  const AmrMonitorApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '세방전지 AMR 통신 관제',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo),
        useMaterial3: true,
        fontFamily: 'Roboto',
      ),
      home: const MonitorDashboard(),
    );
  }
}

// ============================================================
// [A] 장애 계층 + 심각도 + 자동 진단 결과 모델
// ============================================================
enum FaultLayer { normal, ap, moxa, network, server, agent }

/// AMR 운영 영향 기반 4단계 심각도
/// 일반 IT 기준이 아닌 MOXA + 물류 창고 환경 기준
enum AlertLevel {
  offline,  // 🔴 끊김  — AMR 실제 통신 단절 또는 즉시 단절 상태
  danger,   // 🟠 위험  — 수초~수십초 내 단절 위험, 즉시 확인 필요
  warning,  // 🟡 경고  — 품질 저하, 운영은 가능하나 주시 필요
  caution,  // 🔵 주의  — 환경 불량이나 AMR 운영 영향 없음
  normal,   // 🟢 정상  — 모든 지표 정상
}

class DiagnosisResult {
  final FaultLayer layer;
  final AlertLevel alertLevel;
  final String summary;
  final String detail;
  final String action;
  final Color badgeColor;
  const DiagnosisResult({
    required this.layer,
    required this.alertLevel,
    required this.summary,
    required this.detail,
    required this.action,
    required this.badgeColor,
  });
}

// ============================================================
// [B] 자동 장애 원인 분류 엔진 — AMR/MOXA 물류 창고 전용
// ============================================================
class DiagnosisEngine {
  // ── AMR 운영 영향 기반 임계값 (일반 IT 기준 아님) ─────────────
  // MOXA AWK-1137C + H3C WA6320 + 폐쇄망 물류 창고 환경 기준
  static const int    _rssiWarn      = -75;   // dBm: 로밍 필요 구간 → [경고]
  static const int    _rssiDanger    = -80;   // dBm: 실질 음영 근접 → [위험]
  static const int    _pingCaution   = 100;   // ms: AMR 운영엔 이상 없음 → [주의]
  static const int    _pingWarn      = 300;   // ms: 제어 응답 지연 시작 → [경고]
  static const int    _pingDanger    = 500;   // ms: 제어 불안정 구간 → [위험]
  static const int    _agentTimeout  = 30;    // 초: 에이전트 무응답
  // 로밍 1회 ≈ ping 1회 누락 ≈ 8.3% (60s 12회 윈도우)
  // → sustainedLoss/pingFailStreak 이 실질 단절 감지 담당
  // → raw 손실률은 높은 임계값으로 오탐 방지
  static const double _packetLossWarn   = 15.0; // %: 로밍 2회 이상 → [경고]
  static const double _packetLossDanger = 25.0; // %: 지속적 손실 → [위험]
  static const double _cpuHigh          = 85.0;
  static const double _retryWarn        = 20.0; // TX Retry % → [경고]
  static const double _retryDanger      = 30.0; // TX Retry % → [위험]

  // 같은 AP(BSSID)의 타 로봇 Retry와 비교: 국소 간섭 vs Co-channel 혼잡
  static bool? _isLocalizedInterference(RobotData d, Map<String, RobotData>? allRobots) {
    if (allRobots == null) return null;
    final peers = allRobots.values.where((r) =>
        r.id != d.id &&
        r.currentBssid == d.currentBssid &&
        r.currentBssid.isNotEmpty &&
        r.currentBssid != 'Disconnected' &&
        r.currentBssid != 'Error' &&
        r.txRetryRate >= 0).toList();
    if (peers.isEmpty) return null;
    final avg = peers.map((r) => r.txRetryRate).reduce((a, b) => a + b) / peers.length;
    return avg < 10.0;
  }

  static DiagnosisResult analyze(RobotData d, {Map<String, RobotData>? allRobots}) {
    final agentSilent = d.lastReceived != null &&
        DateTime.now().difference(d.lastReceived!).inSeconds > _agentTimeout;

    // ════════════════════════════════════════════════════════
    // 🔴 끊김 — AMR 실제 통신 단절 상태
    // ════════════════════════════════════════════════════════
    if (agentSilent) {
      if (d.cpuPct >= 0 && d.cpuPct > _cpuHigh) {
        return DiagnosisResult(
          layer: FaultLayer.agent,
          alertLevel: AlertLevel.offline,
          summary: '[끊김] 미니PC 과부하',
          detail: 'CPU ${d.cpuPct.toInt()}% — 에이전트 정지 상태\n'
              'CROMS "Server Not Connect" 알람 발생 중',
          action: '미니PC 재시작 필요\n'
              '→ systemctl status amr-agent\n'
              '→ top / htop 으로 CPU 점유 프로세스 확인\n'
              '→ 이상 프로세스 종료 또는 미니PC 재부팅',
          badgeColor: Colors.red,
        );
      }
      final sec = DateTime.now().difference(d.lastReceived!).inSeconds;
      return DiagnosisResult(
        layer: FaultLayer.agent,
        alertLevel: AlertLevel.offline,
        summary: '[끊김] 에이전트 무응답',
        detail: '미니PC 에이전트 ${sec}초째 미전송\n'
            'CROMS "Server Not Connect" 알람 발생 중',
        action: '에이전트 프로세스 확인\n'
            '→ ps aux | grep amr_agent\n'
            '→ systemctl restart amr-agent\n'
            '→ 미니PC 전원 및 네트워크 케이블 확인',
        badgeColor: Colors.red,
      );
    }
    if (d.moxaConnected == false) {
      return DiagnosisResult(
        layer: FaultLayer.moxa,
        alertLevel: AlertLevel.offline,
        summary: '[끊김] MOXA 단절',
        detail: 'MOXA와 미니PC 간 링크 단절\n'
            'AMR 무선 통신 완전 중단 상태',
        action: 'MOXA 전원/LED 확인\n'
            '→ MOXA 관리 페이지 접속 (192.168.145.5x)\n'
            '→ LAN 케이블 체결 상태 점검\n'
            '→ MOXA 재부팅 후 링크 재확인',
        badgeColor: Colors.red,
      );
    }
    if (d.pingGwMs >= 0 && d.pingGwMs == 0) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        alertLevel: AlertLevel.offline,
        summary: '[끊김] AP 도달 불가',
        detail: 'AP 게이트웨이 Ping 실패\n'
            'AP 전원 꺼짐 또는 유선 단절',
        action: 'AP 전원 및 PoE 스위치 포트 확인\n'
            '→ AP LED 상태 확인\n'
            '→ 스위치 → AP 케이블 체결 점검',
        badgeColor: Colors.red,
      );
    }
    if (d.pingGwMs > 0 && d.pingSrvMs >= 0 && d.pingSrvMs == 0) {
      return DiagnosisResult(
        layer: FaultLayer.server,
        alertLevel: AlertLevel.offline,
        summary: '[끊김] 관제서버 불가',
        detail: 'AP 구간 정상 / MQTT 서버 Ping 실패\n'
            'CROMS 알람 발생 중',
        action: '관제서버 상태 확인\n'
            '→ docker ps | grep emqx\n'
            '→ 방화벽 1883 / 8083 포트 허용 확인',
        badgeColor: Colors.red,
      );
    }

    // ════════════════════════════════════════════════════════
    // 🟠 위험 — 수초~수십초 내 끊김 위험, 즉시 확인
    // ════════════════════════════════════════════════════════
    if (d.sustainedLoss || d.pingFailStreak >= 3) {
      final streakSec = d.pingFailStreak * 5;
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.danger,
        summary: '[위험] 연속 단절 ${d.pingFailStreak}회 (${streakSec}초)',
        detail: 'ping ${d.pingFailStreak}회 연속 실패 → ${streakSec}초 이상 서버 미도달\n'
            'CROMS 알람(30초) 전 단계 — 즉시 확인 필요\n'
            '※ 로밍 순단(1~2회)은 정상, 이 경우는 실질 단절',
        action: 'MOXA LED 및 웹UI 상태 확인\n'
            '→ 로봇 동선 상 음영구간 진입 여부 점검\n'
            '→ AP ping 정상 여부 확인\n'
            '→ 증상 지속 시 MOXA 재부팅',
        badgeColor: Colors.deepOrange,
      );
    }
    final effectiveLoss = d.pingLossPct > 0 ? d.pingLossPct
        : (d.packetLoss >= 0 ? d.packetLoss : 0.0);
    if (effectiveLoss > _packetLossDanger) {
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.danger,
        summary: '[위험] 패킷 손실 ${effectiveLoss.toInt()}%',
        detail: '60초 평균 패킷 손실 ${effectiveLoss.toStringAsFixed(1)}%\n'
            '로밍 순단 외 지속적 손실 — 채널/AP 문제',
        action: '무선 채널 점검\n'
            '→ 인접 AP 채널 분리 확인 (Ch 149 단독 사용 권장)\n'
            '→ MOXA 안테나 체결 상태 확인',
        badgeColor: Colors.deepOrange,
      );
    }
    if (d.rssiAvailable && d.currentRssi < _rssiDanger) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        alertLevel: AlertLevel.danger,
        summary: '[위험] 음영구간 (${d.currentRssi}dBm)',
        detail: 'RSSI ${d.currentRssi} dBm — AMR 통신 불안정 구간\n'
            '로밍이 발생해야 하는데 안 되고 있을 가능성',
        action: 'AP 커버리지 재검토\n'
            '→ MOXA roamingThreshold5G -75dBm 확인\n'
            '→ 해당 구역 AP Tx Power 상향 또는 AP 추가',
        badgeColor: Colors.deepOrange,
      );
    }
    if (d.txRetryRate >= 0 && d.txRetryRate > _retryDanger) {
      final localized = _isLocalizedInterference(d, allRobots);
      final isLocal = localized == true;
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.danger,
        summary: '[위험] ${isLocal ? "국소 간섭" : "채널 혼잡"} (Retry ${d.txRetryRate.toInt()}%)',
        detail: isLocal
            ? '이 로봇만 TX Retry 높음 — 로봇 주변 RF 간섭\n'
              '(같은 AP 다른 로봇은 정상)'
            : '같은 AP 다수 로봇 TX Retry 높음 — Co-channel 혼잡\n'
              '${d.band.isNotEmpty ? "대역: ${d.band}" : ""}',
        action: isLocal
            ? '로봇 주변 금속/모터/인버터 EMI 점검\n'
              '→ MOXA 안테나 위치 조정 (로봇 상단 권장)'
            : 'AP 채널 분리 점검\n'
              '→ 5GHz Ch 149 단독 사용 유지\n'
              '→ 주변 기기 간섭 여부 확인',
        badgeColor: Colors.deepOrange,
      );
    }
    final effectivePing = d.pingAvg60s > 0 ? d.pingAvg60s : d.currentPing;
    if (effectivePing > _pingDanger) {
      final label = d.pingAvg60s > 0 ? '${effectivePing.toInt()}ms(60s평균)' : '${effectivePing.toInt()}ms';
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.danger,
        summary: '[위험] Ping $label',
        detail: '60초 평균 Ping ${effectivePing.toInt()}ms — AMR 제어 응답 불안정 구간\n'
            '로밍 중 순간 스파이크와 달리 지속적 지연',
        action: '백본 스위치 포트 에러 확인\n'
            '→ STP 루프 여부 점검\n'
            '→ EMQX 브로커 부하 확인 (docker stats emqx)',
        badgeColor: Colors.deepOrange,
      );
    }

    // ════════════════════════════════════════════════════════
    // 🟡 경고 — 품질 저하, 운영 가능하나 주시 필요
    // ════════════════════════════════════════════════════════
    final isPingpong = d.pingpong || d.dashboardPingpong;
    final ppPair     = d.pingpong ? d.pingpongPair : d.dashboardPingpongPair;
    final roamCount  = d.roamCount10min > 0 ? d.roamCount10min : d.recentRoamingCount;
    if (isPingpong) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        alertLevel: AlertLevel.warning,
        summary: '[경고] Ping-pong 로밍${ppPair.isNotEmpty ? " ($ppPair)" : ""}',
        detail: '동일 AP 쌍 반복 전환 (5분 내 3회 이상)\n'
            '${ppPair.isNotEmpty ? "대상: $ppPair\n" : ""}'
            '현재 운영은 유지되나 불안정 로밍 반복 중\n'
            '로밍 횟수: ${roamCount}회',
        action: 'MOXA roamingDifference5G 8 이상 상향\n'
            '→ roamingThreshold5G -75dBm 확인\n'
            '→ 해당 구역 AP 출력 균형 점검',
        badgeColor: Colors.amber,
      );
    }
    if (effectiveLoss > _packetLossWarn) {
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.warning,
        summary: '[경고] 패킷 손실 ${effectiveLoss.toInt()}%',
        detail: '60초 평균 패킷 손실 ${effectiveLoss.toStringAsFixed(1)}%\n'
            'AP 경계 구간 체류 또는 채널 간섭 의심',
        action: 'AP 경계 구간 커버리지 재검토\n'
            '→ MOXA Tx Power 조정\n'
            '→ 로봇 동선 상 AP 경계 위치 확인',
        badgeColor: Colors.amber,
      );
    }
    if (d.rssiAvailable && d.currentRssi < _rssiWarn) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        alertLevel: AlertLevel.warning,
        summary: '[경고] 신호 약함 (${d.currentRssi}dBm)',
        detail: 'RSSI ${d.currentRssi} dBm — 로밍 발생 필요 구간\n'
            '현재 운영은 정상이나 AP 경계 근처 위치',
        action: 'MOXA roamingThreshold5G -75dBm 확인\n'
            '→ 로밍이 안 된다면 roamingDifference 조정',
        badgeColor: Colors.amber,
      );
    }
    if (d.txRetryRate >= 0 && d.txRetryRate > _retryWarn) {
      final localized = _isLocalizedInterference(d, allRobots);
      final isLocal = localized == true;
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.warning,
        summary: '[경고] ${isLocal ? "국소 간섭" : "채널 간섭"} (Retry ${d.txRetryRate.toInt()}%)',
        detail: isLocal
            ? '이 로봇 위치 특화 간섭 의심 (Retry ${d.txRetryRate.toStringAsFixed(1)}%)\n'
              '같은 AP 다른 로봇은 정상'
            : 'TX Retry ${d.txRetryRate.toStringAsFixed(1)}% — 채널 경쟁 발생\n'
              '${d.band.isNotEmpty ? "대역: ${d.band}" : ""}',
        action: isLocal
            ? '로봇 주변 금속 / EMI 발생 장비 점검\n'
              '→ MOXA 안테나 위치 확인'
            : 'AP 채널 분리 확인\n→ 비중복 채널 사용 확인',
        badgeColor: Colors.amber,
      );
    }
    if (effectivePing > _pingWarn) {
      final label = d.pingAvg60s > 0 ? '${effectivePing.toInt()}ms(60s평균)' : '${effectivePing.toInt()}ms';
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.warning,
        summary: '[경고] Ping $label',
        detail: '60초 평균 Ping ${effectivePing.toInt()}ms — 제어 응답 다소 지연\n'
            '로밍 직후 순간 스파이크는 정상, 지속 시 확인 필요',
        action: 'AP 채널 간섭 또는 백본 부하 확인\n'
            '→ 네트워크 대역폭 및 채널 점검',
        badgeColor: Colors.amber,
      );
    }

    // ════════════════════════════════════════════════════════
    // 🔵 주의 — 환경 불량, AMR 운영 영향 없음
    // ════════════════════════════════════════════════════════
    if (!d.rssiAvailable) {
      return DiagnosisResult(
        layer: FaultLayer.moxa,
        alertLevel: AlertLevel.caution,
        summary: '[주의] SNMP 미수신',
        detail: 'MOXA RSSI/채널 데이터 없음\n'
            '운영엔 영향 없으나 신호 품질 측정 불가',
        action: 'sudo systemctl status moxa-poller\n'
            '→ MOXA 웹UI: SNMP Enable + Save + 재부팅',
        badgeColor: Colors.indigo,
      );
    }
    if (effectivePing > _pingCaution) {
      final label = d.pingAvg60s > 0 ? '${effectivePing.toInt()}ms(60s평균)' : '${effectivePing.toInt()}ms';
      return DiagnosisResult(
        layer: FaultLayer.network,
        alertLevel: AlertLevel.caution,
        summary: '[주의] Ping $label — 운영 정상',
        detail: '60초 평균 Ping ${effectivePing.toInt()}ms\n'
            'AMR 물류 운영에 실질 영향 없는 수준\n'
            '로밍 직후 순간 스파이크 포함 시 더 높게 측정될 수 있음',
        action: '지속 상승 시 채널 간섭 또는 부하 확인\n'
            '→ 당장 조치 불필요',
        badgeColor: Colors.indigo,
      );
    }

    // ════════════════════════════════════════════════════════
    // 🟢 정상
    // ════════════════════════════════════════════════════════
    return const DiagnosisResult(
      layer: FaultLayer.normal,
      alertLevel: AlertLevel.normal,
      summary: '정상',
      detail: '모든 계층 정상 동작 중\n'
          '※ 로밍(AP 전환)은 이동 중 정상 현상',
      action: '-',
      badgeColor: Colors.green,
    );
  }
}

// ============================================================
// [C] 로봇 데이터 모델
// ============================================================
class RobotData {
  String id = "";
  String mode = "";
  String status = "NORMAL";
  String interfaceName = "";
  String interfaceType = "";
  String lastTime = "";
  DateTime? lastReceived;

  double currentPing = 0;
  String currentBssid = "";
  String currentSsid = "";
  String currentChannel = "";
  int currentRssi = 0;
  bool rssiAvailable = false;   // false = "N/A" / "Error" (MOXA SNMP 미수신)

  // 확장 필드 (에이전트가 보낼 때 자동 활성화, -1 = 미지원)
  double pingGwMs    = -1;
  double pingMoxaMs  = -1;
  double pingSrvMs   = -1;
  String latencySrc  = "";
  double packetLoss  = -1;
  double cpuPct      = -1;
  double memPct      = -1;
  bool?  moxaConnected;
  int    moxaRssi    = 0;
  String vlanId      = "";
  int    ifErrors    = 0;
  int    reconnectCount = 0;
  int    _prevReconnectCount = 0;

  // 채널 품질 필드 (iw station dump 기반, -1 = 미지원)
  double txRetryRate = -1;
  int    txFailed    = -1;
  double rxBitrate   = -1;
  double txBitrate   = -1;
  int    freqMhz     = 0;
  String band        = "";

  // ── 60초 슬라이딩 윈도우 지표 ──────────────────────────────
  double pingAvg60s     = -1;
  double pingLossPct    = 0;
  int    roamCount10min = 0;
  String latencySrc60s  = "";

  // ── 연속 실패 / 실질 단절 감지 ────────────────────────────
  int  pingFailStreak = 0;     // 연속 ping 실패 횟수 (1~2=순단/로밍, 3+=실질단절)
  bool sustainedLoss  = false; // 3회 이상 연속 실패 = 실질 단절

  // ── Ping-pong 로밍 감지 (에이전트 → 대시보드) ──────────────
  bool   pingpong     = false;   // 에이전트가 감지한 ping-pong 여부
  String pingpongPair = "";      // ping-pong 대상 AP 쌍 문자열
  // 대시보드 자체 로밍 이력 (에이전트 미지원 시 fallback)
  final List<Map<String, dynamic>> _roamingHistory = [];  // {from, to, time}

  // ── 서버 진단 결과 (amr_diagnostics v2) ─────────────────────
  bool   diagConnected      = true;
  int    diagDisconnect1h   = 0;    // 1시간 내 끊김 횟수
  Map<String, dynamic>? diagLastDisconnect;       // 마지막 단절 이벤트
  List<Map<String, dynamic>> diagHistory = [];    // 최근 5건 단절 이력

  // IP 정보 (계층 패널 하단에 표시)
  String gwIp   = "";  // AP 게이트웨이 IP
  String srvIp  = "";  // MQTT 서버 IP
  String pcIp   = "";  // 미니PC IP
  String moxaIp = "";  // MOXA 관리 IP

  List<FlSpot> pingHistory = [];
  List<FlSpot> rssiHistory = [];
  double timeIndex = 0;

  List<Map<String, String>> structuredLogs = [];
  List<String> eventLogs = [];
  final List<DateTime> _roamingTimestamps = [];

  // 임계값 교차 감지용 이전 상태 추적
  double _prevPing   = -1;
  int    _prevRssi   = 0;
  String _prevStatus = "";

  // RSSI 오탐 방지 debounce 카운터 (3초 연속 시에만 이벤트 발생)
  int _rssiCritCount = 0;
  int _rssiWarnCount = 0;
  static const int _rssiDebounceCount = 3;

  static const int _rssiWarnThreshold = -75;
  static const int _rssiCritThreshold = -85;
  static const int _pingWarnThreshold = 100;
  static const int _pingCritThreshold = 500;

  int get recentRoamingCount {
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    return _roamingTimestamps.where((t) => t.isAfter(cutoff)).length;
  }

  /// 대시보드 자체 ping-pong 감지 (에이전트 미지원 구형 agent fallback)
  /// 최근 5분 이력에서 동일 AP 쌍이 3회 이상 교대 전환되면 true
  bool get dashboardPingpong {
    const minBounces = 3;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final recent = _roamingHistory
        .where((e) => (e['time'] as DateTime).isAfter(cutoff))
        .map((e) => e['to'] as String)
        .toList();
    if (recent.length < minBounces) return false;
    final last = recent.length > minBounces + 1
        ? recent.sublist(recent.length - (minBounces + 1))
        : recent;
    if (last.toSet().length != 2) return false;
    for (int i = 1; i < last.length; i++) {
      if (last[i] == last[i - 1]) return false;
    }
    return true;
  }

  String get dashboardPingpongPair {
    if (!dashboardPingpong) return "";
    const minBounces = 3;
    final cutoff = DateTime.now().subtract(const Duration(minutes: 5));
    final recent = _roamingHistory
        .where((e) => (e['time'] as DateTime).isAfter(cutoff))
        .map((e) => e['to'] as String)
        .toList();
    final last = recent.length > minBounces + 1
        ? recent.sublist(recent.length - (minBounces + 1))
        : recent;
    final bssids = last.toSet().toList()..sort();
    String trimBssid(String s) => s.length > 11 ? s.substring(0, 11) : s;
    return "${trimBssid(bssids[0])} ↔ ${trimBssid(bssids[1])}";
  }

  void update(Map<String, dynamic> json) {
    lastReceived = DateTime.now();
    id     = json['robot_id'];
    mode   = json['active_mode'];
    status = json['status'];
    interfaceName = json['interface_name'] ?? "Unknown_IF";
    interfaceType = json['interface_type'] ?? "Unknown_Type";
    currentPing    = (json['ping_ms'] as num) < 0 ? 0 : (json['ping_ms'] as num).toDouble();
    currentSsid    = json['ssid']    ?? "Unknown";
    currentChannel = json['channel'] ?? "Unknown";
    lastTime       = json['timestamp'];

    if (json['ping_gw_ms']      != null) pingGwMs      = (json['ping_gw_ms']      as num).toDouble();
    if (json['ping_moxa_ms']    != null) pingMoxaMs    = (json['ping_moxa_ms']    as num).toDouble();
    if (json['ping_srv_ms']     != null) pingSrvMs     = (json['ping_srv_ms']     as num).toDouble();
    if (json['latency_src']     != null) latencySrc    = json['latency_src'].toString();
    if (json['packet_loss']     != null) packetLoss    = (json['packet_loss']     as num).toDouble();
    if (json['cpu_pct']         != null) cpuPct        = (json['cpu_pct']         as num).toDouble();
    if (json['mem_pct']         != null) memPct        = (json['mem_pct']         as num).toDouble();
    if (json['moxa_connected']  != null) moxaConnected = json['moxa_connected']   as bool;
    if (json['moxa_rssi']       != null) moxaRssi      = (json['moxa_rssi']       as num).toInt();
    if (json['vlan_id']         != null) vlanId        = json['vlan_id'].toString();
    if (json['if_errors']       != null) ifErrors      = (json['if_errors']       as num).toInt();
    if (json['reconnect_count'] != null) reconnectCount = (json['reconnect_count'] as num).toInt();
    // IP 정보
    if (json['gw_ip']   != null) gwIp   = json['gw_ip'];
    if (json['srv_ip']  != null) srvIp  = json['srv_ip'];
    if (json['pc_ip']   != null) pcIp   = json['pc_ip'];
    if (json['moxa_ip'] != null) moxaIp = json['moxa_ip'];
    // 채널 품질
    if (json['tx_retry_rate'] != null) txRetryRate = (json['tx_retry_rate'] as num).toDouble();
    if (json['tx_failed']     != null) txFailed    = (json['tx_failed']     as num).toInt();
    if (json['rx_bitrate']    != null) rxBitrate   = (json['rx_bitrate']    as num).toDouble();
    if (json['tx_bitrate']    != null) txBitrate   = (json['tx_bitrate']    as num).toDouble();
    if (json['freq_mhz']      != null) freqMhz     = (json['freq_mhz']      as num).toInt();
    if (json['band']          != null) band        = json['band'];
    // 60초 윈도우 지표
    if (json['ping_avg_60s']     != null) pingAvg60s    = (json['ping_avg_60s']     as num).toDouble();
    if (json['ping_loss_pct']    != null) pingLossPct   = (json['ping_loss_pct']    as num).toDouble();
    if (json['roam_count_10min'] != null) roamCount10min = (json['roam_count_10min'] as num).toInt();
    if (json['latency_src_60s']  != null) latencySrc60s = json['latency_src_60s'].toString();
    // 연속 실패 / 실질 단절 (에이전트 v2+)
    if (json['ping_fail_streak'] != null) pingFailStreak = (json['ping_fail_streak'] as num).toInt();
    if (json['sustained_loss']   != null) sustainedLoss  = json['sustained_loss'] as bool;
    // Ping-pong 로밍 (에이전트 v2+)
    if (json['pingpong']      != null) pingpong     = json['pingpong']      as bool;
    if (json['pingpong_pair'] != null) pingpongPair = json['pingpong_pair'].toString();

    final rssiRaw = json['rssi']?.toString().replaceAll('dBm', '').trim() ?? '';
    final rssiParsed = int.tryParse(rssiRaw);
    rssiAvailable = rssiParsed != null;
    int newRssi = rssiParsed ?? 0;   // N/A → 0 (임계값 오탐 방지)

    // ── 로밍 감지 ──────────────────────────────────────────
    final newBssid = json['bssid'] as String? ?? "";
    if (currentBssid.isNotEmpty &&
        currentBssid != newBssid &&
        newBssid != "Disconnected" && newBssid != "Error" && newBssid != "Unknown") {
      _addLog("ROAM", "로밍: $currentBssid ➔ $newBssid (Ch: $currentChannel)");
      final now = DateTime.now();
      _roamingTimestamps.add(now);
      _roamingTimestamps.removeWhere((t) => now.difference(t).inMinutes > 30);
      // 대시보드 자체 ping-pong 감지용 이력 (최근 30건)
      _roamingHistory.add({'from': currentBssid, 'to': newBssid, 'time': now});
      if (_roamingHistory.length > 30) _roamingHistory.removeAt(0);
    }
    currentBssid = newBssid;
    currentRssi  = newRssi;

    // ── 상태 변화 감지 ─────────────────────────────────────
    if (_prevStatus.isNotEmpty && _prevStatus != status) {
      _addLog("STATUS", "상태 변화: $_prevStatus → $status");
    }
    _prevStatus = status;

    // ── RSSI 임계값 교차 감지 (debounce: 3초 연속 시에만 이벤트, SNMP 미수신 시 스킵) ──
    if (!rssiAvailable) { _rssiCritCount = 0; _rssiWarnCount = 0; }
    // Critical (-85 dBm): 3회 연속 진입/탈출 시에만 로그 (순간 노이즈 오탐 방지)
    if (currentRssi < _rssiCritThreshold) {
      _rssiCritCount++;
      if (_rssiCritCount == _rssiDebounceCount) {
        _addLog("CRIT", "음영구간 진입 (RSSI ${currentRssi}dBm, 기준 ${_rssiCritThreshold}dBm)");
      }
    } else {
      if (_rssiCritCount >= _rssiDebounceCount) {
        _addLog("INFO", "음영구간 탈출 (RSSI ${currentRssi}dBm)");
      }
      _rssiCritCount = 0;
    }
    // Warn (-75 dBm): crit 구간이 아닌 경우에만
    if (currentRssi < _rssiWarnThreshold && currentRssi >= _rssiCritThreshold) {
      _rssiWarnCount++;
      if (_rssiWarnCount == _rssiDebounceCount) {
        _addLog("WARN", "RSSI 약함 구간 진입: ${currentRssi}dBm");
      }
    } else if (currentRssi >= _rssiWarnThreshold) {
      if (_rssiWarnCount >= _rssiDebounceCount) {
        _addLog("INFO", "RSSI 회복: ${currentRssi}dBm");
      }
      _rssiWarnCount = 0;
    }
    _prevRssi = currentRssi;

    // ── Ping 임계값 교차 감지 ──────────────────────────────
    if (_prevPing >= 0 && currentPing >= 0) {
      if (_prevPing < _pingCritThreshold && currentPing >= _pingCritThreshold) {
        _addLog("CRIT", "Ping 심각 지연: ${_prevPing.toInt()}ms → ${currentPing.toInt()}ms");
      } else if (_prevPing >= _pingCritThreshold && currentPing < _pingWarnThreshold) {
        _addLog("INFO", "Ping 정상화: ${_prevPing.toInt()}ms → ${currentPing.toInt()}ms");
      } else if (_prevPing < _pingWarnThreshold && currentPing >= _pingWarnThreshold) {
        _addLog("WARN", "Ping 지연 발생: ${_prevPing.toInt()}ms → ${currentPing.toInt()}ms");
      } else if (_prevPing >= _pingWarnThreshold && currentPing < _pingWarnThreshold) {
        _addLog("INFO", "Ping 정상화: ${_prevPing.toInt()}ms → ${currentPing.toInt()}ms");
      }
    }
    if (currentPing >= 0) _prevPing = currentPing;

    // ── 에이전트 이벤트 수신 (에이전트가 감지한 이벤트 반영) ──
    if (json['latest_log'] != null && json['latest_log'] != "None") {
      _addLog("AGT", "${json['latest_log']}");
    }
    if (packetLoss > 15)       _addLog("WARN", "패킷 손실: ${packetLoss.toInt()}% (로밍 순단 제외 기준)");
    if (reconnectCount > _prevReconnectCount) _addLog("SYS",  "에이전트 재연결 누적: $reconnectCount 회");
    _prevReconnectCount = reconnectCount;

    pingHistory.add(FlSpot(timeIndex, currentPing));
    rssiHistory.add(FlSpot(timeIndex, currentRssi.toDouble()));
    if (pingHistory.length > 60) { pingHistory.removeAt(0); rssiHistory.removeAt(0); }
    timeIndex++;
  }

  /// 서버 진단 서비스(amr_diagnostics v2)에서 받은 결과 업데이트
  void updateDiagnosis(Map<String, dynamic> json) {
    diagConnected    = json['connected']           as bool?  ?? true;
    diagDisconnect1h = (json['disconnect_count_1h'] as num?  ?? 0).toInt();
    diagLastDisconnect = json['last_disconnect'] as Map<String, dynamic>?;
    final history = json['disconnect_history'] as List?;
    if (history != null) {
      diagHistory = history.cast<Map<String, dynamic>>();
    }
  }

  void _addLog(String type, String message) {
    final nowIso = DateTime.now().toIso8601String().substring(0, 19).replaceFirst('T', ' ');
    structuredLogs.insert(0, {"time": lastTime, "datetime": nowIso, "type": type, "message": message});
    eventLogs.insert(0, "[$lastTime][$type] $message");
    if (structuredLogs.length > 50) { structuredLogs.removeLast(); eventLogs.removeLast(); }
  }

  String generateReport({Map<String, RobotData>? allRobots}) {
    final now  = DateTime.now();
    final diag = DiagnosisEngine.analyze(this, allRobots: allRobots);
    final buf  = StringBuffer();
    final sep  = '─' * 56;
    buf.writeln('=' * 56);
    buf.writeln('  AMR 네트워크 장애 진단 보고서');
    buf.writeln('=' * 56);
    buf.writeln('생성 일시    : ${now.toString().substring(0, 19)}');
    buf.writeln('로봇 ID      : $id');
    buf.writeln('에이전트 모드: $mode');
    buf.writeln();
    buf.writeln('$sep');
    buf.writeln('[자동 진단 결과]');
    buf.writeln('원인 계층  : ${_layerName(diag.layer)}');
    buf.writeln('진단 요약  : ${diag.summary}');
    buf.writeln('상세 내용  : ${diag.detail}');
    buf.writeln('권장 조치  :');
    for (final line in diag.action.split('\n')) buf.writeln('   $line');
    buf.writeln();
    buf.writeln('$sep');
    buf.writeln('[무선 네트워크 상태]');
    buf.writeln('SSID         : $currentSsid');
    buf.writeln('BSSID (AP)   : $currentBssid');
    buf.writeln('채널         : Ch $currentChannel');
    buf.writeln('RSSI         : $currentRssi dBm  ${_rssiGrade(currentRssi)}');
    buf.writeln('Ping (서버)  : ${currentPing.toInt()} ms  ${_pingGrade(currentPing)}');
    if (pingGwMs  >= 0) buf.writeln('Ping (GW)    : ${pingGwMs.toInt()} ms${gwIp.isNotEmpty ? "  [$gwIp]" : ""}');
    if (pingSrvMs >= 0) buf.writeln('Ping (MQTT)  : ${pingSrvMs.toInt()} ms${srvIp.isNotEmpty ? "  [$srvIp]" : ""}');
    if (packetLoss >= 0) buf.writeln('패킷 손실    : ${packetLoss.toStringAsFixed(1)} %');
    buf.writeln('인터페이스   : $interfaceName ($interfaceType)');
    if (band.isNotEmpty) buf.writeln('주파수 대역  : $band${freqMhz > 0 ? "  (${freqMhz}MHz)" : ""}');
    if (txRetryRate >= 0) buf.writeln(
        'TX Retry율   : ${txRetryRate.toStringAsFixed(1)} %'
        '${txRetryRate > 30 ? "  ⚠ 채널 혼잡 심각" : txRetryRate > 20 ? "  ⚠ 채널 간섭 의심" : ""}');
    if (txBitrate  > 0)  buf.writeln('TX Bitrate   : ${txBitrate.toInt()} Mbps');
    if (rxBitrate  > 0)  buf.writeln('RX Bitrate   : ${rxBitrate.toInt()} Mbps');
    if (pcIp.isNotEmpty)   buf.writeln('미니PC IP    : $pcIp');
    if (vlanId.isNotEmpty) buf.writeln('VLAN ID      : $vlanId');
    buf.writeln();
    if (moxaConnected != null || moxaRssi != 0 || moxaIp.isNotEmpty) {
      buf.writeln('$sep');
      buf.writeln('[MOXA 상태]');
      if (moxaConnected != null) buf.writeln('연결 상태  : ${moxaConnected! ? "연결됨" : "단절 ⚠"}');
      if (moxaRssi != 0)         buf.writeln('MOXA RSSI  : $moxaRssi dBm');
      if (moxaIp.isNotEmpty)     buf.writeln('MOXA IP    : $moxaIp');
      buf.writeln();
    }
    if (cpuPct >= 0 || memPct >= 0 || ifErrors > 0) {
      buf.writeln('$sep');
      buf.writeln('[미니PC 리소스]');
      if (cpuPct    >= 0)  buf.writeln('CPU 사용률   : ${cpuPct.toInt()} %');
      if (memPct    >= 0)  buf.writeln('메모리       : ${memPct.toInt()} %');
      if (ifErrors   > 0)  buf.writeln('NIC 에러     : $ifErrors 건');
      if (reconnectCount > 0) buf.writeln('재연결       : $reconnectCount 회');
      buf.writeln();
    }
    buf.writeln('$sep');
    buf.writeln('[로밍 통계]');
    buf.writeln('최근 로밍 횟수: ${roamCount10min > 0 ? "$roamCount10min 회 (10분)" : "$recentRoamingCount 회 (5분)"}');
    if (pingpong || dashboardPingpong) {
      final pair = pingpong ? pingpongPair : dashboardPingpongPair;
      buf.writeln('Ping-pong     : 감지됨${pair.isNotEmpty ? " ($pair)" : ""}');
    }
    buf.writeln();
    if (structuredLogs.isNotEmpty) {
      buf.writeln('$sep');
      buf.writeln('[이벤트 기록 (최근 ${structuredLogs.length}건)]');
      for (final log in structuredLogs) {
        buf.writeln('[${log["time"]}][${log["type"]}] ${log["message"]}');
      }
    }
    buf.writeln('=' * 56);
    return buf.toString();
  }

  String _layerName(FaultLayer l) {
    switch (l) {
      case FaultLayer.normal:  return '정상';
      case FaultLayer.ap:      return 'AP / 무선';
      case FaultLayer.moxa:    return 'MOXA';
      case FaultLayer.network: return '네트워크';
      case FaultLayer.server:  return '관제서버';
      case FaultLayer.agent:   return '미니PC';
    }
  }

  String _rssiGrade(int r) {
    if (r >= -65) return '(우수)';
    if (r >= -72) return '(양호)';
    if (r >= -78) return '(경고)';
    if (r >= -83) return '(위험 ⚠)';
    return '(음영 ✗)';
  }

  String _pingGrade(double ms) {
    if (ms == 0)   return '(측정불가)';
    if (ms < 20)   return '(매우좋음)';
    if (ms < 50)   return '(좋음)';
    if (ms < 100)  return '(보통)';
    if (ms < 200)  return '(나쁨 ⚠)';
    return '(매우나쁨 ✗)';
  }
}

// ============================================================
// [C2] 인프라 장비 (AP / 스위치) 데이터 모델
// ============================================================
class InfraDevice {
  String id = '';
  String type = '';
  String ip = '';
  bool isUp = false;
  // wifiStatus: ACTIVE | SHUTDOWN | DISABLED | DOWN
  // ACTIVE   = WiFi 정상 운영
  // SHUTDOWN = 관리자 radio shutdown (ping OK, WiFi OFF)
  // DISABLED = 해당 구역 WiFi 미운영 (영구 비활성)
  // DOWN     = ping 실패 (전원/케이블/PoE 장애)
  String wifiStatus = 'ACTIVE';
  double pingMs = -1;
  String timestamp = '';
  DateTime? lastReceived;

  bool get isWifiActive   => wifiStatus == 'ACTIVE' && isUp;
  bool get isShutdown     => wifiStatus == 'SHUTDOWN';
  bool get isDisabled     => wifiStatus == 'DISABLED';
  // 구버전 wifi_disabled 필드 하위 호환
  bool get wifiDisabled   => isShutdown || isDisabled;

  void update(Map<String, dynamic> json) {
    id        = json['device_id']   ?? id;
    type      = json['device_type'] ?? type;
    ip        = json['ip']          ?? ip;
    isUp      = (json['status'] ?? 'DOWN') == 'UP';
    pingMs    = ((json['ping_ms'] ?? -1) as num).toDouble();
    timestamp = json['timestamp']   ?? '';
    lastReceived = DateTime.now();

    if (json.containsKey('wifi_status')) {
      wifiStatus = json['wifi_status'] as String;
    } else if (json.containsKey('wifi_disabled')) {
      // 구버전 서버 호환
      final disabled = json['wifi_disabled'] as bool? ?? false;
      wifiStatus = disabled ? 'DISABLED' : (isUp ? 'ACTIVE' : 'DOWN');
    } else {
      wifiStatus = isUp ? 'ACTIVE' : 'DOWN';
    }
  }
}

// ============================================================
// [D] 메인 관제 화면
// ============================================================
class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({super.key});
  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  final String broker = 'ws://${Uri.base.host}:${Uri.base.port > 0 ? Uri.base.port : 80}/mqtt';
  late MqttClient client;
  Map<String, RobotData>   robots       = {};
  Map<String, InfraDevice> infraDevices = {};
  final Set<String> _collapsedRobots = {};
  bool    isConnected       = false;
  bool    _showLayerHeader  = true;
  bool    _tableView        = true;
  bool    _infraExpanded    = true;
  String? _expandedTableRow;
  bool _disposed = false;
  DateTime? _lastDataTime;
  Timer? _ticker;

  // 서버 진단 요약 (amr_diagnostics.py → infra_test/diagnosis/summary)
  List<Map<String, dynamic>> _crossFaults = [];
  int _diagOnline      = 0;
  int _diagAlertCount  = 0;
  int _diagNormalCount = 0;
  List<String> _diagOffline = [];

  static const int _dataTimeoutSec = 30;

  String get _connectionLabel {
    if (!isConnected) return 'MQTT 끊김';
    if (_lastDataTime == null) return 'MQTT 연결됨 (데이터 없음)';
    final sec = DateTime.now().difference(_lastDataTime!).inSeconds;
    if (sec > _dataTimeoutSec) return '에이전트 무응답 (${sec}s)';
    return '정상 수신 중';
  }

  Color get _connectionColor {
    if (!isConnected) return Colors.redAccent;
    if (_lastDataTime == null) return Colors.orangeAccent;
    final sec = DateTime.now().difference(_lastDataTime!).inSeconds;
    return sec > _dataTimeoutSec ? Colors.orangeAccent : Colors.greenAccent;
  }

  IconData get _connectionIcon {
    if (!isConnected) return Icons.cloud_off;
    if (_lastDataTime == null) return Icons.cloud_queue;
    final sec = DateTime.now().difference(_lastDataTime!).inSeconds;
    return sec > _dataTimeoutSec ? Icons.cloud_queue : Icons.cloud_done;
  }

  @override
  void initState() {
    super.initState();
    _connectMQTT();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_disposed) setState(() {});
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _ticker?.cancel();
    client.disconnect();
    super.dispose();
  }

  Future<void> _connectMQTT() async {
    if (_disposed) return;
    final clientId = 'amr_dashboard_${DateTime.now().millisecondsSinceEpoch}';
    client = createMqttClient(broker, clientId);
    client.websocketProtocols = MqttClientConstants.protocolsSingleDefault;
    client.port = Uri.base.port > 0 ? Uri.base.port : 80;
    client.keepAlivePeriod = 20;
    client.autoReconnect = true;
    client.onConnected = _onConnected;
    client.onDisconnected = _onDisconnected;
    client.onAutoReconnected = _onAutoReconnected;
    client.connectionMessage = MqttConnectMessage()
        .authenticateAs('cloud', 'zmfhatm*0')
        .withClientIdentifier(clientId)
        .startClean();
    try {
      await client.connect();
      client.updates!.listen((List<MqttReceivedMessage<MqttMessage?>>? c) {
        final msg     = c![0];
        final topic   = msg.topic;
        final recMess = msg.payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        try {
          final json = jsonDecode(payload);
          if (!_disposed) {
            setState(() {
              _lastDataTime = DateTime.now();
              if (topic == 'infra_test/diagnosis/summary') {
                // v2 진단 서비스 summary
                _diagOnline      = (json['connected']  as num? ?? 0).toInt();
                _diagAlertCount  = (json['offline']    as num? ?? 0).toInt();
                _diagNormalCount = (json['connected']  as num? ?? 0).toInt();
                _diagOffline     = List<String>.from(
                    (json['offline_robots'] as List? ?? [])
                        .map((e) => e['id']?.toString() ?? ''));
                _crossFaults     = List<Map<String, dynamic>>.from(
                    json['freq_1h'] as List? ?? []);
              } else if (topic.startsWith('infra_test/diagnosis/') &&
                         topic != 'infra_test/diagnosis/summary') {
                // 개별 로봇 진단 결과 (v2)
                final rid = topic.split('/').last;
                if (rid.isNotEmpty && robots.containsKey(rid)) {
                  robots[rid]!.updateDiagnosis(json);
                }
              } else if (topic.startsWith('infra_test/network_infra/')) {
                final did = json['device_id'] as String? ?? '';
                if (did.isNotEmpty) {
                  infraDevices.putIfAbsent(did, () => InfraDevice());
                  infraDevices[did]!.update(json);
                }
              } else {
                final rid = json['robot_id'] as String? ?? '';
                if (rid.isNotEmpty) {
                  robots.putIfAbsent(rid, () => RobotData());
                  robots[rid]!.update(json);
                }
              }
            });
          }
        } catch (e) { debugPrint("Parsing error: $e"); }
      });
    } catch (e) {
      debugPrint('MQTT 연결 실패: $e');
      if (!_disposed) {
        setState(() => isConnected = false);
        Future.delayed(const Duration(seconds: 5), _connectMQTT);
      }
    }
  }

  void _onConnected() {
    if (!_disposed) setState(() => isConnected = true);
    client.subscribe('infra_test/network_status/#',  MqttQos.atMostOnce);
    client.subscribe('infra_test/network_infra/#',   MqttQos.atMostOnce);
    client.subscribe('infra_test/diagnosis/#',       MqttQos.atMostOnce);
  }
  void _onDisconnected()    { if (!_disposed) setState(() => isConnected = false); }
  void _onAutoReconnected() {
    if (!_disposed) setState(() => isConnected = true);
    client.subscribe('infra_test/network_status/#',  MqttQos.atMostOnce);
    client.subscribe('infra_test/network_infra/#',   MqttQos.atMostOnce);
    client.subscribe('infra_test/diagnosis/#',       MqttQos.atMostOnce);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade200,
      appBar: AppBar(
        title: const Text('세방전지 AMR 통신 관제',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: Colors.indigo.shade900,
        elevation: 5,
        actions: [
          Row(children: [
            // ── 보고서 내보내기 ──────────────────────────────
            IconButton(
              icon: const Icon(Icons.summarize_outlined, color: Colors.white70),
              tooltip: '통신 현황 보고서 (CSV)',
              onPressed: robots.isEmpty ? null : () => _showCsvReportDialog(context),
            ),
            const SizedBox(width: 4),
            // ── 뷰 전환 토글 ────────────────────────────────
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white24),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _viewToggleBtn(Icons.table_rows_rounded,  '테이블', true),
                _viewToggleBtn(Icons.view_agenda_rounded, '카드',   false),
              ]),
            ),
            const SizedBox(width: 16),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(_connectionLabel,
                    style: TextStyle(color: _connectionColor, fontWeight: FontWeight.bold, fontSize: 13)),
                if (_lastDataTime != null)
                  Text('마지막 수신 ${DateTime.now().difference(_lastDataTime!).inSeconds}초 전',
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
              ],
            ),
            const SizedBox(width: 8),
            Icon(_connectionIcon, color: _connectionColor),
            const SizedBox(width: 20),
          ]),
        ],
      ),
      body: Column(children: [
        if (_crossFaults.isNotEmpty || _diagOffline.isNotEmpty) _buildDiagBanner(),
        if (infraDevices.isNotEmpty) _buildInfraPanel(),
        if (robots.isEmpty)
          const Expanded(
            child: Center(
              child: Text("데이터 수신 대기 중... (로봇의 에이전트를 켜주세요)",
                  style: TextStyle(fontSize: 18, color: Colors.grey))))
        else ...[
          if (robots.length > 1) _buildSummaryBar(),
          if (_tableView)
            Expanded(child: _buildTableView())
          else ...[
            _buildSharedLayerHeader(),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.fromLTRB(12, 6, 12, 12),
                itemCount: robots.length,
                itemBuilder: (ctx, i) => _buildRobotCard(robots.values.elementAt(i)),
              ),
            ),
          ],
        ],
      ]),
    );
  }

  // ============================================================
  // [D-REPORT] 통신 현황 보고서 내보내기 (CSV)
  // ============================================================

  void _showCsvReportDialog(BuildContext context) {
    // 필터 상태
    String period   = '오늘';        // 최근 1h / 3h / 6h / 오늘 / 전체
    String severity = '전체';        // 전체 / 경고이상 / 위험이상 / 끊김만
    String robotId  = '전체';        // 전체 / 개별 로봇 ID

    final robotIds = ['전체', ...robots.keys.toList()..sort()];

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx2, setDlg) => AlertDialog(
          title: const Text('통신 현황 보고서 내보내기',
              style: TextStyle(fontWeight: FontWeight.bold)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('기간', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: ['최근 1h', '최근 3h', '최근 6h', '오늘', '전체']
                    .map((v) => ChoiceChip(
                          label: Text(v),
                          selected: period == v,
                          onSelected: (_) => setDlg(() => period = v),
                        ))
                    .toList()),
                const SizedBox(height: 16),
                const Text('심각도 필터', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Wrap(spacing: 8, children: ['전체', '경고이상', '위험이상', '끊김만']
                    .map((v) => ChoiceChip(
                          label: Text(v),
                          selected: severity == v,
                          onSelected: (_) => setDlg(() => severity = v),
                        ))
                    .toList()),
                const SizedBox(height: 16),
                const Text('로봇', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                DropdownButton<String>(
                  value: robotId,
                  isExpanded: true,
                  items: robotIds.map((id) => DropdownMenuItem(value: id, child: Text(id))).toList(),
                  onChanged: (v) => setDlg(() => robotId = v!),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx2),
              child: const Text('취소'),
            ),
            ElevatedButton.icon(
              icon: const Icon(Icons.download),
              label: const Text('CSV 다운로드'),
              onPressed: () {
                Navigator.pop(ctx2);
                _downloadCsv(period, severity, robotId);
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 필터 조건에 맞는 이벤트를 CSV로 생성
  String _generateCsv(String period, String severity, String robotId) {
    final now = DateTime.now();

    DateTime? cutoff;
    switch (period) {
      case '최근 1h': cutoff = now.subtract(const Duration(hours: 1)); break;
      case '최근 3h': cutoff = now.subtract(const Duration(hours: 3)); break;
      case '최근 6h': cutoff = now.subtract(const Duration(hours: 6)); break;
      case '오늘':
        cutoff = DateTime(now.year, now.month, now.day); break;
      default: cutoff = null; // 전체
    }

    // 심각도 필터: type 기반 — CRIT/WARN/ROAM/STATUS/INFO/AGT/SYS
    bool typeMatches(String type) {
      switch (severity) {
        case '끊김만':   return type == 'CRIT';
        case '위험이상': return type == 'CRIT' || type == 'WARN';
        case '경고이상': return type == 'CRIT' || type == 'WARN' || type == 'ROAM';
        default: return true; // 전체
      }
    }

    // 헤더
    final rows = <String>[];
    rows.add('날짜시간,로봇ID,유형,메시지');

    final targetRobots = robotId == '전체'
        ? robots.values.toList()
        : [if (robots.containsKey(robotId)) robots[robotId]!];

    for (final robot in targetRobots) {
      for (final log in robot.structuredLogs) {
        final dateStr = log['datetime'] as String? ?? '';
        if (dateStr.isEmpty) continue;

        if (cutoff != null) {
          final dt = DateTime.tryParse(dateStr);
          if (dt == null || dt.isBefore(cutoff)) continue;
        }

        final type = log['type'] as String? ?? '';
        if (!typeMatches(type)) continue;

        // CSV 이스케이프
        String esc(String s) {
          if (s.contains(',') || s.contains('"') || s.contains('\n')) {
            return '"${s.replaceAll('"', '""')}"';
          }
          return s;
        }

        rows.add([
          esc(dateStr),
          esc(robot.id),
          esc(type),
          esc(log['message'] as String? ?? ''),
        ].join(','));
      }
    }

    // UTF-8 BOM 추가 (Excel 한글 깨짐 방지)
    return '\uFEFF${rows.join('\n')}';
  }

  /// CSV 생성 후 브라우저 다운로드 트리거
  void _downloadCsv(String period, String severity, String robotId) {
    final csv = _generateCsv(period, severity, robotId);
    final now = DateTime.now();
    final stamp = '${now.year}${now.month.toString().padLeft(2,'0')}${now.day.toString().padLeft(2,'0')}'
        '_${now.hour.toString().padLeft(2,'0')}${now.minute.toString().padLeft(2,'0')}';
    final filename = 'amr_report_${stamp}.csv';

    final bytes = const Utf8Encoder().convert(csv);
    final blob = html.Blob([bytes], 'text/csv;charset=utf-8');
    final url  = html.Url.createObjectUrlFromBlob(blob);
    html.AnchorElement(href: url)
      ..setAttribute('download', filename)
      ..click();
    html.Url.revokeObjectUrl(url);
  }

  // ============================================================
  // [D-0] 서버 자동 진단 배너 (amr_diagnostics.py 결과)
  // ============================================================
  Widget _buildDiagBanner() {
    final layerColors = {
      'backbone': Colors.red.shade700,
      'ap':       Colors.orange.shade700,
      'channel':  Colors.amber.shade800,
      'moxa':     Colors.deepOrange.shade700,
      'network':  Colors.orange.shade800,
      'agent':    Colors.deepOrange.shade900,
    };
    final layerIcons = {
      'backbone': Icons.device_hub,
      'ap':       Icons.router,
      'channel':  Icons.wifi_tethering,
      'moxa':     Icons.settings_ethernet,
      'network':  Icons.network_check,
      'agent':    Icons.computer,
    };

    return Container(
      width: double.infinity,
      color: Colors.red.shade900.withOpacity(0.92),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 헤더 행
          Row(children: [
            const Icon(Icons.warning_amber_rounded, color: Colors.amber, size: 16),
            const SizedBox(width: 6),
            Text(
              '자동 진단 알림  |  이상 $_diagAlertCount대 / 정상 $_diagNormalCount대 / 오프라인 ${_diagOffline.length}대',
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12),
            ),
          ]),
          // 크로스 진단 항목
          if (_crossFaults.isNotEmpty) ...[
            const SizedBox(height: 4),
            ..._crossFaults.map((cf) {
              final layer  = cf['layer'] as String? ?? '';
              final color  = layerColors[layer] ?? Colors.grey.shade700;
              final icon   = layerIcons[layer]  ?? Icons.warning;
              final ids    = (cf['ids'] as List?)?.join(', ') ?? '';
              return Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(children: [
                  Icon(icon, color: Colors.white70, size: 13),
                  const SizedBox(width: 5),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      cf['summary'] as String? ?? '',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      ids.isNotEmpty ? '[$ids]  ${cf['action'] ?? ''}' : (cf['action'] ?? ''),
                      style: const TextStyle(color: Colors.white70, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ]),
              );
            }),
          ],
          // 오프라인 로봇
          if (_diagOffline.isNotEmpty) ...[
            const SizedBox(height: 3),
            Row(children: [
              const Icon(Icons.power_off, color: Colors.white38, size: 13),
              const SizedBox(width: 5),
              Text(
                '오프라인: ${_diagOffline.join(', ')}',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // [D-1] 뷰 토글 버튼 헬퍼
  // ============================================================
  Widget _viewToggleBtn(IconData icon, String label, bool isTable) {
    final active = _tableView == isTable;
    return InkWell(
      onTap: () => setState(() {
        _tableView = isTable;
        _expandedTableRow = null;
      }),
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: active ? Colors.white.withOpacity(0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: active ? Colors.white : Colors.white54),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  fontSize: 11,
                  color: active ? Colors.white : Colors.white54,
                  fontWeight: active ? FontWeight.bold : FontWeight.normal)),
        ]),
      ),
    );
  }

  // ============================================================
  // [E-infra] 네트워크 인프라 패널 (AP / 스위치)
  // ============================================================
  Widget _buildInfraPanel() {
    final aps      = infraDevices.values.where((d) => d.type == 'AP').toList()
        ..sort((a, b) => a.id.compareTo(b.id));
    final switches = infraDevices.values.where((d) => d.type == 'SWITCH').toList()
        ..sort((a, b) => a.id.compareTo(b.id));

    final activeAp   = aps.where((d) => d.isWifiActive).length;
    final shutdownAp = aps.where((d) => d.isShutdown).length;
    final disabledAp = aps.where((d) => d.isDisabled).length;
    final downAp     = aps.where((d) => !d.isUp).length;
    final upSw       = switches.where((d) => d.isUp).length;
    final totalAp    = aps.length;
    final totalSw    = switches.length;
    // 운영 대상 AP = ACTIVE + DOWN (SHUTDOWN/DISABLED 제외)
    final operationalAp = aps.where((d) => !d.isShutdown && !d.isDisabled).length;

    return Container(
      color: Colors.blueGrey.shade900,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 헤더 바 ─────────────────────────────────────────
          InkWell(
            onTap: () => setState(() => _infraExpanded = !_infraExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                const Icon(Icons.router, size: 15, color: Colors.white70),
                const SizedBox(width: 8),
                const Text('네트워크 인프라',
                    style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
                const SizedBox(width: 16),
                if (totalAp > 0) ...[
                  _infraSummaryChip('AP', activeAp, operationalAp),
                  if (shutdownAp > 0) ...[
                    const SizedBox(width: 6),
                    _infraStatusChip('관리비활성 $shutdownAp', Colors.orange.shade300),
                  ],
                  if (disabledAp > 0) ...[
                    const SizedBox(width: 6),
                    _infraStatusChip('미운영 $disabledAp', Colors.blueGrey),
                  ],
                  if (downAp > 0) ...[
                    const SizedBox(width: 6),
                    _infraStatusChip('장애 $downAp', Colors.red),
                  ],
                  const SizedBox(width: 8),
                ],
                if (totalSw > 0) _infraSummaryChip('SW', upSw, totalSw),
                const Spacer(),
                Icon(_infraExpanded ? Icons.expand_less : Icons.expand_more,
                    size: 18, color: Colors.white54),
              ]),
            ),
          ),
          // ── 펼침 영역 ────────────────────────────────────────
          if (_infraExpanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (aps.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: aps.map((d) => _infraDeviceBadge(d)).toList(),
                    ),
                    const SizedBox(height: 6),
                  ],
                  if (switches.isNotEmpty)
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: switches.map((d) => _infraDeviceBadge(d)).toList(),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _infraSummaryChip(String label, int up, int total) {
    final allUp = up == total;
    final color = allUp ? Colors.greenAccent : (up == 0 ? Colors.redAccent : Colors.orangeAccent);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text('$label $up/$total',
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _infraStatusChip(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withOpacity(0.6)),
      ),
      child: Text(text,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  Widget _infraDeviceBadge(InfraDevice d) {
    final stale = d.lastReceived != null &&
        DateTime.now().difference(d.lastReceived!).inSeconds > 60;

    // 색상 결정
    Color color;
    String subLabel;
    String tooltipStatus;

    if (stale) {
      color = Colors.grey;
      subLabel = 'No data';
      tooltipStatus = 'No data';
    } else if (!d.isUp) {
      color = Colors.red.shade400;
      subLabel = 'DOWN';
      tooltipStatus = 'DOWN — 전원/케이블/PoE 장애 의심';
    } else if (d.isShutdown) {
      color = Colors.orange.shade300;
      subLabel = '관리비활성';
      tooltipStatus = 'ping OK / radio shutdown (관리자 비활성)';
    } else if (d.isDisabled) {
      color = Colors.blueGrey.shade400;
      subLabel = '미운영';
      tooltipStatus = 'ping OK / WiFi 미운영 구역';
    } else {
      // ACTIVE
      final pingStr = d.pingMs >= 0 ? '${d.pingMs.toStringAsFixed(0)}ms' : '';
      color = Colors.green.shade400;
      subLabel = pingStr;
      tooltipStatus = 'UP  $pingStr';
    }

    final label = d.id.replaceFirst('SW-PoE-', 'PoE-').replaceFirst('SW-Main-', 'Main-');

    return Tooltip(
      message: '${d.id}  ${d.ip}\n$tooltipStatus',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: color.withOpacity(0.18),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: color, width: 1.2),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
          if (subLabel.isNotEmpty)
            Text(subLabel, style: TextStyle(color: color.withOpacity(0.85), fontSize: 9)),
        ]),
      ),
    );
  }

  // ============================================================
  // [E-table] 테이블 뷰
  // ============================================================
  Widget _buildTableView() {
    return Column(children: [
      _buildTableHeader(),
      Expanded(
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: robots.length,
          itemBuilder: (ctx, i) => _buildTableRow(robots.values.elementAt(i)),
        ),
      ),
    ]);
  }

  Widget _buildTableHeader() {
    return Container(
      color: Colors.grey.shade50,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade300, width: 1.5)),
      ),
      child: Row(children: [
        Expanded(flex: 3, child: _thCell("로봇 ID")),
        Expanded(flex: 4, child: _thCell("진단 상태")),
        Expanded(flex: 2, child: _thCell("RSSI")),
        Expanded(flex: 2, child: _thCell("경로")),
        Expanded(flex: 2, child: _thCell("Ping")),
        Expanded(flex: 3, child: _thCell("채널")),
        Expanded(flex: 2, child: _thCell("마지막 수신")),
        const SizedBox(width: 36),
      ]),
    );
  }

  Widget _thCell(String label) => Text(label,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade500));

  Widget _tdDash() =>
      Text('—', style: TextStyle(color: Colors.grey.shade400, fontSize: 13));

  Widget _tdValue(String value, String unit, Color color) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text(value,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: color)),
      const SizedBox(width: 2),
      Text(unit, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
    ]);
  }

  Widget _buildTableRow(RobotData data) {
    final diag       = DiagnosisEngine.analyze(data, allRobots: robots);
    final isExpanded = _expandedTableRow == data.id;
    final isStale    = data.lastReceived != null &&
        DateTime.now().difference(data.lastReceived!).inSeconds > _dataTimeoutSec;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── 메인 행 ────────────────────────────────────────
        InkWell(
          onTap: () => setState(() =>
              _expandedTableRow = isExpanded ? null : data.id),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            decoration: BoxDecoration(
              color: isExpanded
                  ? Colors.indigo.shade50
                  : (isStale ? Colors.orange.shade50 : Colors.white),
              border: Border(
                bottom: BorderSide(color: Colors.grey.shade200),
                left: isExpanded
                    ? const BorderSide(color: Colors.indigo, width: 3)
                    : BorderSide.none,
              ),
            ),
            child: Row(children: [
              // 로봇 ID
              Expanded(flex: 3, child: Row(children: [
                Icon(
                  isStale ? Icons.warning_amber_rounded : Icons.precision_manufacturing,
                  size: 15,
                  color: isStale ? Colors.orange : Colors.indigo,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(data.id,
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                      overflow: TextOverflow.ellipsis),
                ),
              ])),
              // 진단 상태
              Expanded(flex: 4, child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: diag.badgeColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: diag.badgeColor.withOpacity(0.4)),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_diagIcon(diag.layer), size: 11, color: diag.badgeColor),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(diag.summary,
                        style: TextStyle(
                            fontSize: 11,
                            color: diag.badgeColor,
                            fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis),
                  ),
                ]),
              )),
              // RSSI
              Expanded(flex: 2, child: _tdValue(
                  '${data.currentRssi}', 'dBm', _rssiColor(data.currentRssi))),
              // 경로 (60초 평균 기반 우선, 없으면 순간값)
              Expanded(flex: 2, child: _buildLatencySrcBadge(
                  data.latencySrc60s.isNotEmpty ? data.latencySrc60s : data.latencySrc)),
              // Ping (60초 평균 우선)
              Expanded(flex: 2, child: _buildPingCell(data)),
              // 채널
              Expanded(flex: 3, child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Ch ${data.currentChannel}',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w600)),
                  if (data.band.isNotEmpty)
                    Text(data.band,
                        style: TextStyle(
                            fontSize: 10, color: Colors.grey.shade500)),
                ],
              )),
              // 마지막 수신
              Expanded(flex: 2, child: data.lastReceived == null
                  ? _tdDash()
                  : Text(
                      '${DateTime.now().difference(data.lastReceived!).inSeconds}s',
                      style: TextStyle(
                          fontSize: 12,
                          color: isStale ? Colors.orange : Colors.grey.shade600),
                    )),
              // 펼치기 버튼
              SizedBox(
                width: 36,
                child: Icon(
                  isExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: Colors.grey.shade400,
                ),
              ),
            ]),
          ),
        ),
        // ── 펼친 상세 패널 ─────────────────────────────────
        if (isExpanded) _buildTableRowDetail(data, diag),
      ],
    );
  }

  Widget _buildTableRowDetail(RobotData data, DiagnosisResult diag) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.indigo.shade50.withOpacity(0.4),
        border: Border(
          left:   const BorderSide(color: Colors.indigo, width: 3),
          bottom: BorderSide(color: Colors.grey.shade200),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // 계층 패널 + 보고서 버튼
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          Expanded(child: _buildLayerPanel(data)),
          Tooltip(
            message: '장애 보고서 생성',
            child: IconButton(
              icon: const Icon(Icons.description_outlined, color: Colors.indigo),
              onPressed: () => _showReportDialog(context, data),
            ),
          ),
        ]),
        const SizedBox(height: 8),
        // ── 끊김 이력 패널 (핵심) ──────────────────────────────
        _buildDisconnectHistory(data),
        const SizedBox(height: 8),
        // 채널 품질 바
        if (data.txRetryRate >= 0) ...[
          _buildChannelQualityBar(data),
          const SizedBox(height: 8),
        ],
        // 차트 (Ping + RSSI)
        Row(children: [
          Expanded(child: _buildChart(
            data.pingHistory, "Ping (ms)", Colors.orange,
            minY: 0, baseMaxY: 100, isRssi: false,
          )),
          const SizedBox(width: 14),
          Expanded(child: _buildChart(
            data.rssiHistory, "RSSI (dBm)", Colors.blue,
            minY: -100, baseMaxY: -30, isRssi: true,
          )),
        ]),
        // 권장 조치 배너
        if (diag.alertLevel != AlertLevel.normal) ...[
          const SizedBox(height: 8),
          _buildActionBanner(diag),
        ],
        const SizedBox(height: 8),
        // 이벤트 로그
        Text("🕒 이벤트 기록",
            style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 12,
                color: Colors.grey.shade700)),
        const SizedBox(height: 4),
        Container(
          height: 90,
          decoration: BoxDecoration(
            color: Colors.grey.shade900,
            borderRadius: BorderRadius.circular(6),
          ),
          child: data.eventLogs.isEmpty
              ? const Center(
                  child: Text("이벤트 없음",
                      style: TextStyle(color: Colors.grey, fontSize: 12)))
              : ListView.builder(
                  padding: const EdgeInsets.all(8),
                  itemCount: data.eventLogs.length,
                  itemBuilder: (ctx, i) {
                    final log = data.eventLogs[i];
                    Color c = Colors.white70;
                    if (log.contains("[ROAM]"))                         c = Colors.cyanAccent;
                    else if (log.contains("[WARN]") || log.contains("[SYS]")) c = Colors.redAccent;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Text(log,
                          style: TextStyle(
                              color: c, fontSize: 11, fontFamily: 'Consolas')),
                    );
                  },
                ),
        ),
      ]),
    );
  }

  // ============================================================
  // [E-ping] Ping 3단계 경로 분석 패널
  // ============================================================
  // 끊김 이력 패널 — 서버 진단 서비스(amr_diagnostics v2)에서 수신
  // ============================================================
  Widget _buildDisconnectHistory(RobotData data) {
    final hasHistory = data.diagHistory.isNotEmpty;
    final count1h    = data.diagDisconnect1h;

    // 원인별 색상
    Color causeColor(String cause) {
      switch (cause) {
        case 'backbone':     return Colors.red;
        case 'ap_failure':   return Colors.deepOrange;
        case 'sticky_client':return Colors.orange;
        case 'roaming':      return Colors.amber.shade700;
        case 'device':       return Colors.purple.shade300;
        default:             return Colors.grey;
      }
    }
    String causeLabel(String cause) {
      switch (cause) {
        case 'backbone':     return '백본/서버';
        case 'ap_failure':   return 'AP장애';
        case 'sticky_client':return 'Sticky로밍';
        case 'roaming':      return '로밍';
        case 'device':       return '디바이스';
        default:             return cause;
      }
    }

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.blueGrey.shade50,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.blueGrey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.history, size: 14, color: Colors.blueGrey),
            const SizedBox(width: 6),
            Text('끊김 이력',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold,
                    color: Colors.blueGrey.shade700)),
            const SizedBox(width: 10),
            if (count1h > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: count1h >= 5 ? Colors.red.shade100 : Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text('1시간 내 $count1h회',
                    style: TextStyle(
                        fontSize: 10, fontWeight: FontWeight.bold,
                        color: count1h >= 5 ? Colors.red : Colors.orange.shade800)),
              )
            else
              Text('최근 1시간 이상 없음',
                  style: TextStyle(fontSize: 10, color: Colors.green.shade600)),
          ]),
          if (!hasHistory)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('기록된 단절 이벤트 없음',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade500)),
            )
          else ...[
            const SizedBox(height: 6),
            ...data.diagHistory.map((ev) {
              final cause   = ev['cause'] as String? ?? '';
              final detail  = ev['detail'] as String? ?? '';
              final action  = ev['action'] as String? ?? '';
              final time    = ev['time'] as String? ?? '';
              final dur     = (ev['duration_sec'] as num? ?? 0).toDouble();
              final color   = causeColor(cause);
              final label   = causeLabel(cause);
              // 시간 표시: "HH:MM:SS" 형식에서 "HH:MM" 추출
              final timeShort = time.length >= 5 ? time.substring(11, 16) : time;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: color.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: color.withOpacity(0.5)),
                    ),
                    child: Text(label,
                        style: TextStyle(fontSize: 9, color: color, fontWeight: FontWeight.bold)),
                  ),
                  const SizedBox(width: 6),
                  Text(timeShort,
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade600)),
                  const SizedBox(width: 4),
                  Text('${dur.toStringAsFixed(0)}초',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade700,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(detail,
                          style: TextStyle(fontSize: 10, color: Colors.blueGrey.shade700),
                          overflow: TextOverflow.ellipsis),
                      if (action.isNotEmpty)
                        Text('→ $action',
                            style: TextStyle(fontSize: 9, color: Colors.teal.shade600),
                            overflow: TextOverflow.ellipsis),
                    ]),
                  ),
                ]),
              );
            }),
          ],
        ],
      ),
    );
  }

  // ============================================================
  Widget _buildPingBreakdown(RobotData data) {
    Widget seg(String label, double ms) {
      final color = ms < 0 ? Colors.grey : _latencyColor(ms);
      final val   = ms < 0 ? '—' : '${ms.toInt()}ms';
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Text(label, style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
        const SizedBox(height: 3),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: color.withOpacity(0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: color.withOpacity(0.4)),
          ),
          child: Text(val,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        ),
      ]);
    }
    Widget arrow() => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Icon(Icons.arrow_forward, size: 12, color: Colors.grey.shade400),
    );

    final wifiHop = (data.pingGwMs >= 0 && data.pingMoxaMs >= 0)
        ? data.pingGwMs - data.pingMoxaMs : -1.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          seg('로봇 PC', 0),
          arrow(),
          seg('MOXA LAN', data.pingMoxaMs),
          Column(mainAxisSize: MainAxisSize.min, children: [
            arrow(),
            if (wifiHop >= 0)
              Text('WiFi +${wifiHop.toInt()}ms',
                  style: TextStyle(fontSize: 9, color: _latencyColor(wifiHop))),
          ]),
          seg('AP GW', data.pingGwMs),
          arrow(),
          seg('서버', data.currentPing),
          const SizedBox(width: 12),
          Column(mainAxisSize: MainAxisSize.min, children: [
            Text('경로 진단', style: TextStyle(fontSize: 10, color: Colors.grey.shade500)),
            const SizedBox(height: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: _latencySrcColor(data.latencySrc).withOpacity(0.1),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: _latencySrcColor(data.latencySrc).withOpacity(0.4)),
              ),
              child: Text(
                data.latencySrc.isEmpty ? '—' : data.latencySrc,
                style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: _latencySrcColor(data.latencySrc)),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  // Ping 셀: 60초 평균 우선 표시 + 손실률 부가정보
  Widget _buildPingCell(RobotData d) {
    final hasAvg = d.pingAvg60s > 0;
    final displayMs = hasAvg ? d.pingAvg60s : d.currentPing;
    final color = _pingColor(displayMs);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          Text('${displayMs.toInt()}',
              style: TextStyle(fontSize: 13, color: color, fontWeight: FontWeight.bold)),
          Text('ms', style: TextStyle(fontSize: 10, color: color.withOpacity(0.8))),
        ]),
        if (hasAvg)
          Text('avg60s', style: TextStyle(fontSize: 8, color: Colors.grey.shade500))
        else
          Text('now', style: TextStyle(fontSize: 8, color: Colors.grey.shade400)),
        if (d.pingLossPct > 0)
          Text('손실 ${d.pingLossPct.toStringAsFixed(0)}%',
              style: TextStyle(
                  fontSize: 8,
                  color: d.pingLossPct >= 15 ? Colors.red
                      : d.pingLossPct >= 5 ? Colors.orange
                      : Colors.grey.shade500,
                  fontWeight: d.pingLossPct >= 5 ? FontWeight.bold : FontWeight.normal)),
      ],
    );
  }

  Widget _buildLatencySrcBadge(String src) {
    if (src.isEmpty) return _tdDash();
    final color = _latencySrcColor(src);
    final label = _latencySrcLabel(src);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withOpacity(0.4)),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 9, color: color, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis),
    );
  }

  // 표시 레이블 (영문 코드 → 한국어 약어)
  String _latencySrcLabel(String src) {
    switch (src) {
      case 'NORMAL':        return 'NORMAL';
      case 'WIFI_POOR':     return 'WiFi불량';
      case 'DEGRADED':      return '성능저하';
      case 'PACKET_LOSS':   return '패킷손실';
      case 'WIFI_DOWN':     return 'WiFi단절';
      case 'MOXA_LAN_DOWN': return 'MOXA끊김';
      case 'SERVER_DOWN':   return '서버단절';
      case 'NETWORK_ISSUE': return '네트워크';
      default:              return src;
    }
  }

  Color _latencyColor(double ms) {
    if (ms < 0)   return Colors.grey;
    if (ms < 10)  return Colors.green;
    if (ms < 50)  return Colors.amber.shade700;
    if (ms < 100) return Colors.orange;
    return Colors.red;
  }

  Color _latencySrcColor(String src) {
    switch (src) {
      case 'NORMAL':        return Colors.green;
      case 'DEGRADED':      return Colors.amber.shade700;
      case 'WIFI_POOR':     return Colors.orange;
      case 'PACKET_LOSS':   return Colors.deepOrange;
      case 'WIFI_DOWN':     return Colors.red;
      case 'MOXA_LAN_DOWN': return Colors.red;
      case 'SERVER_DOWN':   return Colors.deepOrange;
      case 'NETWORK_ISSUE': return Colors.amber.shade700;
      default:              return Colors.grey;
    }
  }

  // ============================================================
  // [E-0] 공유 계층 헤더 (RF/AP ~ 미니PC 라벨 최상단 1회 표시)
  //       토글로 숨기기/표시 가능 — 숨기면 각 배지에 Tooltip으로 대체
  // ============================================================
  Widget _buildSharedLayerHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: GestureDetector(
        onTap: () => setState(() => _showLayerHeader = !_showLayerHeader),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: EdgeInsets.symmetric(
            horizontal: 16,
            vertical: _showLayerHeader ? 8 : 5,
          ),
          decoration: BoxDecoration(
            color: _showLayerHeader ? Colors.indigo.shade50 : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _showLayerHeader ? Colors.indigo.shade100 : Colors.grey.shade200,
            ),
          ),
          child: Row(children: [
            if (_showLayerHeader) ...[
              Expanded(
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    _headerLabel("RF / AP",  Icons.wifi_rounded),
                    _headerLabel("MOXA",     Icons.device_hub_outlined),
                    _headerLabel("GW Ping",  Icons.router_outlined),
                    _headerLabel("서버 Ping", Icons.cloud_outlined),
                    _headerLabel("미니PC",   Icons.computer_outlined),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.expand_less, size: 15, color: Colors.indigo.shade300),
            ] else ...[
              Icon(Icons.expand_more, size: 14, color: Colors.grey.shade400),
              const SizedBox(width: 6),
              Text('계층 헤더 표시',
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
            ],
          ]),
        ),
      ),
    );
  }

  Widget _headerLabel(String label, IconData icon) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 12, color: Colors.indigo.shade400),
      const SizedBox(width: 4),
      Text(label,
          style: TextStyle(
              fontSize: 11, fontWeight: FontWeight.w600, color: Colors.indigo.shade600)),
    ]);
  }

  // ============================================================
  // [E-1] 다중 로봇 요약 바 (상단 고정, 2대 이상 시 표시)
  //       각 로봇의 이름 + 진단 상태를 한 줄로 표시
  // ============================================================
  Widget _buildSummaryBar() {
    final normalCount = robots.values.where((d) {
      final diag = DiagnosisEngine.analyze(d, allRobots: robots);
      final stale = d.lastReceived != null &&
          DateTime.now().difference(d.lastReceived!).inSeconds > _dataTimeoutSec;
      return diag.alertLevel == AlertLevel.normal && !stale;
    }).length;
    final alertCount = robots.length - normalCount;

    return Container(
      color: Colors.indigo.shade900,
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 요약 헤더
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(children: [
              Text('전체 ${robots.length}대',
                  style: const TextStyle(color: Colors.white54, fontSize: 11, fontWeight: FontWeight.bold)),
              const SizedBox(width: 10),
              if (normalCount > 0)
                _summaryCountChip('정상 $normalCount', Colors.green),
              const SizedBox(width: 6),
              if (alertCount > 0)
                _summaryCountChip('이상 $alertCount', Colors.orange),
            ]),
          ),
          // 로봇 그리드
          Wrap(
            spacing: 5,
            runSpacing: 5,
            children: robots.values.map((data) {
              final diag = DiagnosisEngine.analyze(data, allRobots: robots);
              final isStale = data.lastReceived != null &&
                  DateTime.now().difference(data.lastReceived!).inSeconds > _dataTimeoutSec;
              final isNormal = diag.alertLevel == AlertLevel.normal && !isStale;
              final shortId = data.id.replaceAll('sebang', '');
              final rssiText = data.rssiAvailable ? '${data.currentRssi}' : 'N/A';
              final bgColor = isStale
                  ? Colors.orange.shade700
                  : isNormal
                      ? Colors.green.shade700.withOpacity(0.6)
                      : diag.badgeColor.withOpacity(0.9);
              return GestureDetector(
                onTap: () => setState(() {
                  _tableView = true;
                  _expandedTableRow = (_expandedTableRow == data.id) ? null : data.id;
                }),
                child: Container(
                  width: 52,
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                  decoration: BoxDecoration(
                    color: bgColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: _expandedTableRow == data.id
                          ? Colors.white
                          : Colors.white.withOpacity(0.15),
                      width: _expandedTableRow == data.id ? 2 : 1,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(shortId,
                          style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.bold)),
                      Text(rssiText,
                          style: TextStyle(
                              color: Colors.white.withOpacity(0.85),
                              fontSize: 9)),
                      // 끊김 횟수 (1시간 내) — 핵심 운영 지표
                      if (data.diagDisconnect1h > 0)
                        Text('✕${data.diagDisconnect1h}',
                            style: TextStyle(
                                color: data.diagDisconnect1h >= 3
                                    ? Colors.red.shade300
                                    : Colors.orange.shade300,
                                fontSize: 8,
                                fontWeight: FontWeight.bold))
                      // 끊김 없고 로밍만 있으면 로밍 카운터 표시
                      else if (data.roamCount10min > 0)
                        Text('${data.roamCount10min}r',
                            style: TextStyle(
                                color: Colors.white.withOpacity(0.6),
                                fontSize: 8)),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _summaryCountChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.2),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.5)),
      ),
      child: Text(label,
          style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold)),
    );
  }

  // ============================================================
  // [E-2] 개별 로봇 카드
  // ============================================================
  Widget _buildRobotCard(RobotData data) {
    final diag        = DiagnosisEngine.analyze(data, allRobots: robots);
    final isStale     = data.lastReceived != null &&
        DateTime.now().difference(data.lastReceived!).inSeconds > _dataTimeoutSec;
    final isCollapsed = _collapsedRobots.contains(data.id);

    return Card(
      elevation: 3,
      margin: const EdgeInsets.only(bottom: 10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: diag.alertLevel == AlertLevel.normal ? Colors.transparent : diag.badgeColor,
          width: 3,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [

            // ── 헤더: ID + 진단 뱃지 + 보고서 버튼 ─────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(children: [
                  const Icon(Icons.precision_manufacturing, size: 26, color: Colors.indigo),
                  const SizedBox(width: 8),
                  Text(data.id, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                ]),
                Row(children: [
                  Chip(
                    avatar: Icon(_diagIcon(diag.layer), size: 15, color: Colors.white),
                    label: Text(diag.summary,
                        style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 12)),
                    backgroundColor: diag.badgeColor,
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                  ),
                  const SizedBox(width: 6),
                  Tooltip(
                    message: '장애 보고서 생성',
                    child: IconButton(
                      icon: const Icon(Icons.description_outlined, color: Colors.indigo),
                      onPressed: () => _showReportDialog(context, data),
                    ),
                  ),
                  Tooltip(
                    message: isCollapsed ? '펼치기' : '접기',
                    child: IconButton(
                      icon: Icon(
                        isCollapsed ? Icons.expand_more : Icons.expand_less,
                        color: Colors.grey.shade600,
                      ),
                      onPressed: () => setState(() {
                        isCollapsed
                            ? _collapsedRobots.remove(data.id)
                            : _collapsedRobots.add(data.id);
                      }),
                    ),
                  ),
                ]),
              ],
            ),

            // ── 마지막 수신 시각 ─────────────────────────────────
            if (data.lastReceived != null)
              Padding(
                padding: const EdgeInsets.only(top: 2, bottom: 6),
                child: Row(children: [
                  Icon(isStale ? Icons.warning_amber_rounded : Icons.check_circle_outline,
                      size: 14, color: isStale ? Colors.orange : Colors.green),
                  const SizedBox(width: 6),
                  Text(
                    isStale
                        ? '⚠ 에이전트 무응답: ${DateTime.now().difference(data.lastReceived!).inSeconds}초 전 마지막 수신'
                        : '마지막 수신: ${DateTime.now().difference(data.lastReceived!).inSeconds}초 전',
                    style: TextStyle(
                      fontSize: 12,
                      color: isStale ? Colors.orange : Colors.grey.shade600,
                      fontWeight: isStale ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ]),
              ),

            // ── 접혔을 때는 헤더+수신 시각만 표시 ──────────────
            if (!isCollapsed) ...[

              // ── OSI 계층별 상태 패널 ─────────────────────────────
              _buildLayerPanel(data),
              const SizedBox(height: 8),

              // ── 인터페이스 정보 ──────────────────────────────────
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: data.interfaceType.contains("Internal") ? Colors.blue.shade50 : Colors.purple.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(data.interfaceType.contains("Internal") ? Icons.wifi : Icons.settings_ethernet,
                      size: 18, color: Colors.black54),
                  const SizedBox(width: 8),
                  Text("Interface: ", style: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.bold)),
                  Text("${data.interfaceName} ", style: const TextStyle(fontWeight: FontWeight.bold)),
                  Text("(${data.interfaceType})", style: TextStyle(color: Colors.grey.shade600, fontSize: 13)),
                ]),
              ),
              const Divider(height: 18, thickness: 1),

              // ── WiFi 상세 정보 ───────────────────────────────────
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _infoTile("SSID",       data.currentSsid,   Icons.wifi),
                  _infoTile("채널",
                    data.band.isNotEmpty
                        ? "Ch ${data.currentChannel}  ·  ${data.band}"
                        : "Ch ${data.currentChannel}",
                    Icons.settings_input_antenna),
                  _infoTile("BSSID (AP)", data.currentBssid,  Icons.router),
                ],
              ),
              const SizedBox(height: 8),

              // ── 채널 품질 표시줄 (station stats 수신 시에만 표시) ──
              if (data.txRetryRate >= 0) _buildChannelQualityBar(data),

              const SizedBox(height: 8),

              // ── 실시간 차트 (동적 Y축 + 품질 뱃지) ───────────────
              Row(children: [
                Expanded(child: _buildChart(
                  data.pingHistory, "Ping 지연율 (ms)", Colors.orange,
                  minY: 0, baseMaxY: 100, isRssi: false,
                )),
                const SizedBox(width: 20),
                Expanded(child: _buildChart(
                  data.rssiHistory, "RSSI 신호강도 (dBm)", Colors.blue,
                  minY: -100, baseMaxY: -30, isRssi: true,
                )),
              ]),

              // ── 권장 조치 배너 ───────────────────────────────────
              if (diag.alertLevel != AlertLevel.normal) ...[
                const SizedBox(height: 16),
                _buildActionBanner(diag),
              ],

              const SizedBox(height: 10),

              // ── 이벤트 로그 ─────────────────────────────────────
              const Text("🕒 이동 간 통신 이벤트 기록",
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
              const SizedBox(height: 6),
              Container(
                height: 110,
                decoration: BoxDecoration(
                  color: Colors.grey.shade900,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: data.eventLogs.isEmpty
                    ? const Center(
                        child: Text("기록된 이벤트가 없습니다. (로밍 / 음영 / 시스템 이상 없음)",
                            style: TextStyle(color: Colors.grey)))
                    : ListView.builder(
                        padding: const EdgeInsets.all(12),
                        itemCount: data.eventLogs.length,
                        itemBuilder: (ctx, i) {
                          final log = data.eventLogs[i];
                          Color c = Colors.white70;
                          if (log.contains("[ROAM]")) c = Colors.cyanAccent;
                          else if (log.contains("[WARN]") || log.contains("[SYS]")) c = Colors.redAccent;
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(log, style: TextStyle(color: c, fontSize: 12, fontFamily: 'Consolas')),
                          );
                        },
                      ),
              ),

            ], // if (!isCollapsed)
          ],
        ),
      ),
    );
  }

  // ============================================================
  // [F-0] 채널 품질 표시줄 (TX Retry율 + 대역 + Bitrate)
  // ============================================================
  Widget _buildChannelQualityBar(RobotData d) {
    final retryColor = d.txRetryRate > 30 ? Colors.red
        : d.txRetryRate > 20              ? Colors.deepOrange
        : d.txRetryRate > 10              ? Colors.amber
        :                                   Colors.green;

    final bandColor = d.band == '5GHz'   ? Colors.blue.shade700
        : d.band == '2.4GHz'             ? Colors.orange.shade700
        :                                  Colors.grey.shade600;

    final retryLabel = d.txRetryRate > 30 ? '혼잡 심각'
        : d.txRetryRate > 20              ? '간섭 의심'
        : d.txRetryRate > 10              ? '주의'
        :                                   '양호';

    // 5GHz DFS 채널 여부 (52~144번 채널: 5260~5720 MHz)
    final isDfs = d.band == '5GHz' && d.freqMhz >= 5260 && d.freqMhz <= 5720;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Row(
        children: [
          // 주파수 대역 뱃지
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: bandColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: bandColor, width: 1.2),
            ),
            child: Text(
              d.band.isEmpty ? '?' : d.band,
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: bandColor),
            ),
          ),
          // DFS 채널 경고
          if (isDfs) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: 'DFS 채널(${d.freqMhz}MHz) — 레이더 감지 시 AP 채널 전환 발생 가능\n비DFS 권장: 36~48번 또는 149~165번',
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.amber.shade50,
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: Colors.amber.shade600),
                ),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.radar, size: 12, color: Colors.amber.shade700),
                  const SizedBox(width: 3),
                  Text('DFS', style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold,
                      color: Colors.amber.shade700)),
                ]),
              ),
            ),
          ],
          const SizedBox(width: 14),
          // TX Retry율
          Icon(Icons.replay_rounded, size: 14, color: Colors.grey.shade500),
          const SizedBox(width: 4),
          Text('Retry  ', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          Text(
            '${d.txRetryRate.toStringAsFixed(1)}%',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: retryColor),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: retryColor.withOpacity(0.12),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              retryLabel,
              style: TextStyle(fontSize: 10, color: retryColor, fontWeight: FontWeight.bold),
            ),
          ),
          const Spacer(),
          // RX / TX Bitrate
          if (d.rxBitrate > 0) ...[
            Icon(Icons.arrow_downward_rounded, size: 12, color: Colors.blueGrey.shade400),
            const SizedBox(width: 2),
            Text('${d.rxBitrate.toInt()} Mbps',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
            const SizedBox(width: 10),
          ],
          if (d.txBitrate > 0) ...[
            Icon(Icons.arrow_upward_rounded, size: 12, color: Colors.blueGrey.shade400),
            const SizedBox(width: 2),
            Text('${d.txBitrate.toInt()} Mbps',
                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ],
        ],
      ),
    );
  }

  // ============================================================
  // [F] OSI 계층별 상태 패널 (IP 정보 포함)
  // ============================================================
  Widget _buildLayerPanel(RobotData d) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceAround,
        children: [
          _layerBadge("RF / AP",  _rssiLabel(d.currentRssi), _rssiColor(d.currentRssi),
              sub: "${d.currentRssi} dBm"),
          _layerBadge("MOXA",     _moxaLabel(d),             _moxaColor(d),
              sub: d.moxaIp.isNotEmpty ? d.moxaIp : (d.moxaRssi != 0 ? "${d.moxaRssi}dBm" : "")),
          _layerBadge("GW Ping",  d.pingGwMs  < 0 ? "-" : "${d.pingGwMs.toInt()}ms",  _pingColor(d.pingGwMs),
              sub: d.gwIp),
          _layerBadge("서버 Ping", d.pingSrvMs < 0 ? "-" : "${d.pingSrvMs.toInt()}ms", _pingColor(d.pingSrvMs),
              sub: d.srvIp),
          _layerBadge("미니PC",   _pcLabel(d),               _pcColor(d),
              sub: d.pcIp),
        ],
      ),
    );
  }

  Widget _layerBadge(String label, String value, Color color, {String sub = ""}) {
    return Tooltip(
      message: label,
      child: Column(children: [
        // 공유 헤더가 숨겨졌을 때만 카드 내부에 라벨 표시
        if (!_showLayerHeader || _tableView) ...[
          Text(label,
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
          const SizedBox(height: 4),
        ],
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: color.withOpacity(0.12),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: color, width: 1.2),
          ),
          child: Text(value,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
        ),
        if (sub.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(sub,
                style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                overflow: TextOverflow.ellipsis),
          ),
      ]),
    );
  }

  // ── 계층 뱃지 헬퍼 ──────────────────────────────────────────
  String _rssiLabel(int r) {
    if (r >= -65) return '우수';
    if (r >= -75) return '양호';
    if (r >= -85) return '약함 ⚠';
    return '불량 ✗';
  }
  Color _rssiColor(int r) {
    if (r >= -65) return Colors.green;
    if (r >= -75) return Colors.lightGreen.shade700;
    if (r >= -85) return Colors.orange;
    return Colors.red;
  }
  String _moxaLabel(RobotData d) {
    if (d.moxaConnected == null) return '-';
    return d.moxaConnected! ? '연결됨' : '단절 ✗';
  }
  Color _moxaColor(RobotData d) {
    if (d.moxaConnected == null) return Colors.grey;
    return d.moxaConnected! ? Colors.green : Colors.red;
  }
  Color _pingColor(double ms) {
    if (ms < 0)   return Colors.grey;
    if (ms == 0)  return Colors.red;
    if (ms < 50)  return Colors.green;
    if (ms < 100) return Colors.orange;
    return Colors.red;
  }
  String _pcLabel(RobotData d) {
    if (d.cpuPct < 0) return '-';
    return 'CPU ${d.cpuPct.toInt()}%${d.cpuPct > 85 ? " !" : ""}';
  }
  Color _pcColor(RobotData d) {
    if (d.cpuPct < 0)  return Colors.grey;
    if (d.cpuPct > 85) return Colors.red;
    if (d.cpuPct > 60) return Colors.orange;
    return Colors.green;
  }

  // ============================================================
  // [G] 권장 조치 배너
  // ============================================================
  Widget _buildActionBanner(DiagnosisResult diag) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: diag.badgeColor.withOpacity(0.07),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: diag.badgeColor.withOpacity(0.4)),
      ),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.build_outlined, size: 18, color: diag.badgeColor),
        const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text("현장 조치 방법",
              style: TextStyle(fontWeight: FontWeight.bold, color: diag.badgeColor, fontSize: 13)),
          const SizedBox(height: 6),
          Text(diag.action,
              style: TextStyle(color: Colors.grey.shade800, fontSize: 12, height: 1.6)),
        ])),
      ]),
    );
  }

  // ============================================================
  // [H] 보고서 다이얼로그
  // ============================================================
  void _showReportDialog(BuildContext context, RobotData data) {
    final report = data.generateReport(allRobots: robots);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.description, color: Colors.indigo),
          const SizedBox(width: 8),
          Flexible(child: Text('장애 진단 보고서 — ${data.id}',
              style: const TextStyle(fontSize: 16))),
        ]),
        content: SizedBox(
          width: 640, height: 480,
          child: SingleChildScrollView(
            child: SelectableText(report,
                style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.6)),
          ),
        ),
        actions: [
          TextButton.icon(
            icon: const Icon(Icons.copy),
            label: const Text('클립보드 복사'),
            onPressed: () async {
              bool copied = false;
              try {
                await Clipboard.setData(ClipboardData(text: report));
                copied = true;
              } catch (_) {}
              if (!copied) {
                // HTTP 환경에서 clipboard API 실패 시 선택 가능한 텍스트 다이얼로그 표시
                showDialog(
                  context: ctx,
                  builder: (_) => AlertDialog(
                    title: const Text('텍스트 선택 후 복사'),
                    content: SizedBox(
                      width: 640, height: 400,
                      child: SelectableText(report,
                          style: const TextStyle(fontFamily: 'Consolas', fontSize: 12, height: 1.6)),
                    ),
                    actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기'))],
                  ),
                );
                return;
              }
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('보고서가 클립보드에 복사되었습니다.')));
            },
          ),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('닫기')),
        ],
      ),
    );
  }

  // ============================================================
  // [I] 실시간 차트 (동적 Y축 범위 + 품질 뱃지)
  //     isRssi=true 이면 RSSI 기준, false 이면 Ping 기준으로 품질 판단
  // ============================================================
  Widget _buildChart(
    List<FlSpot> spots,
    String title,
    Color color, {
    required double minY,
    required double baseMaxY,
    required bool isRssi,
  }) {
    if (spots.isEmpty) return const SizedBox(height: 120);

    // 데이터 범위에 따라 Y축을 동적으로 확장 (삐져나감 방지)
    final dataMax = spots.map((s) => s.y).reduce((a, b) => a > b ? a : b);
    final dataMin = spots.map((s) => s.y).reduce((a, b) => a < b ? a : b);
    final effectiveMax = (dataMax > baseMaxY) ? (dataMax + (dataMax.abs() * 0.15)) : baseMaxY;
    final effectiveMin = (dataMin < minY)     ? (dataMin - (dataMin.abs() * 0.05)) : minY;

    final lastVal = spots.last.y;

    // 품질 판단
    String qualLabel;
    Color  qualColor;
    if (isRssi) {
      qualLabel = _rssiLabel(lastVal.toInt());
      qualColor = _rssiColor(lastVal.toInt());
    } else {
      // Ping 품질 기준
      if (lastVal == 0)       { qualLabel = '측정불가'; qualColor = Colors.grey; }
      else if (lastVal < 20)  { qualLabel = '매우좋음'; qualColor = Colors.green; }
      else if (lastVal < 50)  { qualLabel = '좋음';    qualColor = Colors.lightGreen.shade700; }
      else if (lastVal < 100) { qualLabel = '보통';    qualColor = Colors.orange; }
      else if (lastVal < 200) { qualLabel = '나쁨';    qualColor = Colors.deepOrange; }
      else                    { qualLabel = '매우나쁨'; qualColor = Colors.red; }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            Row(children: [
              Text("${lastVal.toInt()}",
                  style: TextStyle(color: qualColor, fontWeight: FontWeight.bold, fontSize: 16)),
              const SizedBox(width: 6),
              // 품질 뱃지
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: qualColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: qualColor.withOpacity(0.6)),
                ),
                child: Text(qualLabel,
                    style: TextStyle(color: qualColor, fontSize: 10, fontWeight: FontWeight.bold)),
              ),
            ]),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 100,
          child: LineChart(LineChartData(
            minY: effectiveMin,
            maxY: effectiveMax,
            minX: spots.first.x,
            maxX: spots.last.x,
            clipData: const FlClipData.all(), // 범위 초과 시 클리핑
            lineBarsData: [
              LineChartBarData(
                spots: spots,
                isCurved: true,
                color: color,
                barWidth: 2.5,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(show: true, color: color.withOpacity(0.08)),
              ),
            ],
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: true, border: Border.all(color: Colors.grey.shade300)),
            gridData: FlGridData(
              show: true,
              drawVerticalLine: false,
              getDrawingHorizontalLine: (v) => FlLine(color: Colors.grey.shade200, strokeWidth: 1),
            ),
          )),
        ),
      ],
    );
  }

  // ── 공용 헬퍼 ────────────────────────────────────────────────
  /// AlertLevel 기반 아이콘 — 심각도를 직관적으로 표현
  IconData _diagIcon(FaultLayer layer) {
    switch (layer) {
      case FaultLayer.normal:  return Icons.check_circle;
      case FaultLayer.ap:      return Icons.wifi_off;
      case FaultLayer.moxa:    return Icons.device_hub;
      case FaultLayer.network: return Icons.lan;
      case FaultLayer.server:  return Icons.cloud_off;
      case FaultLayer.agent:   return Icons.computer;
    }
  }

  IconData _alertIcon(AlertLevel level) {
    switch (level) {
      case AlertLevel.offline: return Icons.signal_wifi_off;
      case AlertLevel.danger:  return Icons.warning_rounded;
      case AlertLevel.warning: return Icons.warning_amber_rounded;
      case AlertLevel.caution: return Icons.info_outline;
      case AlertLevel.normal:  return Icons.check_circle_outline;
    }
  }

  String _alertLabel(AlertLevel level) {
    switch (level) {
      case AlertLevel.offline: return '끊김';
      case AlertLevel.danger:  return '위험';
      case AlertLevel.warning: return '경고';
      case AlertLevel.caution: return '주의';
      case AlertLevel.normal:  return '정상';
    }
  }

  Widget _infoTile(String title, String value, IconData icon) {
    return Column(children: [
      Row(children: [
        Icon(icon, size: 16, color: Colors.grey.shade600),
        const SizedBox(width: 6),
        Text(title, style: TextStyle(color: Colors.grey.shade600, fontWeight: FontWeight.w500)),
      ]),
      const SizedBox(height: 6),
      Text(value,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
    ]);
  }
}
