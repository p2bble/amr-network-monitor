import 'dart:async';
import 'dart:convert';
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
      title: 'AMR Network Dashboard',
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
// [A] 장애 계층 + 자동 진단 결과 모델
// ============================================================
enum FaultLayer { normal, ap, moxa, network, server, agent }

class DiagnosisResult {
  final FaultLayer layer;
  final String summary;
  final String detail;
  final String action;
  final Color badgeColor;
  const DiagnosisResult({
    required this.layer,
    required this.summary,
    required this.detail,
    required this.action,
    required this.badgeColor,
  });
}

// ============================================================
// [B] 자동 장애 원인 분류 엔진
// ============================================================
class DiagnosisEngine {
  static const int    _rssiWeak      = -75;
  static const int    _rssiCritical  = -85;
  static const int    _pingHighMs    = 100;
  static const int    _pingCritMs    = 500;
  static const int    _agentTimeout  = 30;
  static const int    _roamingFreq   = 3;
  static const double _packetLossWarn = 5.0;
  static const double _cpuHigh       = 85.0;

  // 같은 BSSID(AP)의 다른 로봇들과 Retry율을 비교해 국소 간섭 여부를 판별합니다.
  // true  = 이 로봇만 Retry 높음 → 위치 특화 국소 간섭
  // false = 같은 AP 전체 Retry 높음 → Co-channel 혼잡
  // null  = 비교 대상 없음 (판별 불가)
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
    final avgRetry = peers.map((r) => r.txRetryRate).reduce((a, b) => a + b) / peers.length;
    return avgRetry < 10.0; // 다른 로봇 평균 Retry < 10% 이면 국소 간섭
  }

  static DiagnosisResult analyze(RobotData d, {Map<String, RobotData>? allRobots}) {
    final agentSilent = d.lastReceived != null &&
        DateTime.now().difference(d.lastReceived!).inSeconds > _agentTimeout;

    if (agentSilent) {
      if (d.cpuPct >= 0 && d.cpuPct > _cpuHigh) {
        return DiagnosisResult(
          layer: FaultLayer.agent,
          summary: '미니PC CPU 과부하',
          detail: 'CPU ${d.cpuPct.toInt()}% — 에이전트 프로세스 응답 불가',
          action: '미니PC 재시작 또는 프로세스 확인\n→ systemctl status amr-agent\n→ top / htop 으로 CPU 점유 프로세스 확인',
          badgeColor: Colors.deepOrange,
        );
      }
      final sec = DateTime.now().difference(d.lastReceived!).inSeconds;
      return DiagnosisResult(
        layer: FaultLayer.agent,
        summary: '에이전트 무응답',
        detail: '미니PC 에이전트가 ${sec}초째 데이터 미전송',
        action: '에이전트 프로세스 확인\n→ ps aux | grep amr_agent\n→ systemctl restart amr-agent\n→ 미니PC 전원 상태 및 네트워크 케이블 확인',
        badgeColor: Colors.deepOrange,
      );
    }
    if (d.moxaConnected == false) {
      return DiagnosisResult(
        layer: FaultLayer.moxa,
        summary: 'MOXA 연결 단절',
        detail: 'MOXA 장비와의 링크 단절 (MOXA RSSI: ${d.moxaRssi} dBm)',
        action: 'MOXA 전원/LED 상태 확인\n→ MOXA 관리 페이지 접속 (기본: 192.168.127.253)\n→ 안테나/케이블 체결 상태 점검\n→ MOXA 재부팅 후 링크 재확인',
        badgeColor: Colors.red,
      );
    }
    if (d.pingGwMs >= 0 && d.pingGwMs == 0) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        summary: 'AP 게이트웨이 도달 불가',
        detail: '게이트웨이 Ping 실패 — AP 장애 또는 VLAN 단절',
        action: 'FortiAP 연결 상태 확인\n→ FortiGate > WiFi Clients 탭 확인\n→ VLAN ${d.vlanId.isNotEmpty ? d.vlanId : "설정값"} 트렁크 포트 점검',
        badgeColor: Colors.red,
      );
    }
    if (d.pingGwMs > 0 && d.pingSrvMs >= 0 && d.pingSrvMs == 0) {
      return DiagnosisResult(
        layer: FaultLayer.server,
        summary: '관제서버 도달 불가',
        detail: 'AP 구간 정상 / 관제서버(MQTT) Ping 실패',
        action: '관제서버 상태 확인\n→ docker ps | grep emqx\n→ 방화벽 8083 포트 허용 여부 점검',
        badgeColor: Colors.red,
      );
    }
    if (d.packetLoss >= 0 && d.packetLoss > _packetLossWarn) {
      return DiagnosisResult(
        layer: FaultLayer.network,
        summary: '패킷 손실 ${d.packetLoss.toInt()}%',
        detail: '패킷 손실 ${d.packetLoss.toStringAsFixed(1)}% — 무선 간섭 또는 채널 혼잡',
        action: '무선 채널 점검\n→ 인접 AP 채널 분리 (5GHz 권장)\n→ MOXA Tx Power 조정',
        badgeColor: Colors.orange,
      );
    }
    if (d.currentRssi < _rssiCritical) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        summary: '음영구간 (${d.currentRssi}dBm)',
        detail: 'RSSI ${d.currentRssi} dBm — 통신 불가 수준',
        action: '해당 구역 AP 추가 설치 필요\n→ 로봇 동선 기반 RF 설계 재검토',
        badgeColor: Colors.red,
      );
    }
    if (d.currentRssi < _rssiWeak) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        summary: 'AP 신호 약함 (${d.currentRssi}dBm)',
        detail: 'RSSI ${d.currentRssi} dBm — 경계 구간, 로밍 빈발 가능성',
        action: 'AP Tx Power 상향 또는 AP 추가 검토\n→ MOXA 로밍 임계값 -70 dBm 권장',
        badgeColor: Colors.orange,
      );
    }
    // ── TX Retry율 기반 채널 간섭 진단 ──────────────────────────
    // 같은 AP(BSSID)의 타 로봇 Retry와 비교해 원인을 3분기로 구분:
    //   localized=true  → 이 로봇만 높음: 위치 특화 국소 간섭
    //   localized=false → 같은 AP 전체 높음: Co-channel 혼잡
    //   localized=null  → 비교 대상 없음: 원인 특정 불가
    if (d.txRetryRate >= 0 && d.txRetryRate > 30) {
      final localized = _isLocalizedInterference(d, allRobots);
      if (localized == true) {
        return DiagnosisResult(
          layer: FaultLayer.network,
          summary: '국소 간섭 심각 (Retry ${d.txRetryRate.toInt()}%)',
          detail: '같은 AP의 다른 로봇은 Retry 정상\n'
              '→ 이 로봇 위치 특화 RF 간섭 (Retry ${d.txRetryRate.toStringAsFixed(1)}%)\n'
              '채널 혼잡이 아닌 로봇 주변 환경 문제${d.band.isNotEmpty ? "\n대역: ${d.band}" : ""}',
          action: '→ 로봇 주변 금속 구조물 / 모터 / 인버터 EMI 점검\n'
              '→ USB WiFi 안테나 위치 조정 (로봇 상단 노출 권장)\n'
              '→ 로봇을 다른 위치로 이동 후 Retry 변화 확인\n'
              '→ WiFi 어댑터 드라이버 및 전원 절전 설정 점검',
          badgeColor: Colors.deepOrange,
        );
      }
      final coDetail = localized == false
          ? '같은 AP(${d.currentBssid}) 다른 로봇도 Retry 높음 → AP 레벨 채널 혼잡\n'
          : '(비교 대상 로봇 없음 — 원인 특정 불가)\n';
      final coAction = d.band == '2.4GHz'
          ? '2.4GHz 대역 — 5GHz 고정 운영 강력 권장\n→ AP 채널 1 / 6 / 11 비중복 배치 확인'
          : d.band == '5GHz'
              ? 'DFS 채널 회피 권장 (52~144번 → 36~48번 또는 149~165번)\n→ 주변 AP 채널 분리 점검'
              : 'AP 채널 재배치 검토\n→ 비중복 채널 사용 확인';
      return DiagnosisResult(
        layer: FaultLayer.network,
        summary: '채널 혼잡 심각 (Retry ${d.txRetryRate.toInt()}%)',
        detail: '${coDetail}TX Retry율 ${d.txRetryRate.toStringAsFixed(1)}% — 재전송 과다'
            '${d.band.isNotEmpty ? "\n현재 대역: ${d.band}" : ""}',
        action: coAction,
        badgeColor: Colors.deepOrange,
      );
    }
    if (d.txRetryRate >= 0 && d.txRetryRate > 20) {
      final localized = _isLocalizedInterference(d, allRobots);
      if (localized == true) {
        return DiagnosisResult(
          layer: FaultLayer.network,
          summary: '국소 간섭 의심 (Retry ${d.txRetryRate.toInt()}%)',
          detail: '같은 AP의 다른 로봇은 Retry 정상\n'
              '→ 이 로봇 위치 특화 간섭 의심 (Retry ${d.txRetryRate.toStringAsFixed(1)}%)'
              '${d.band.isNotEmpty ? "\n대역: ${d.band}" : ""}',
          action: '→ 로봇 주변 금속 / EMI 발생 장비 점검\n'
              '→ WiFi 안테나 위치 확인\n'
              '→ 로봇 이동 후 Retry율 변화 확인',
          badgeColor: Colors.orange,
        );
      }
      final coDetail = localized == false ? '같은 AP 다른 로봇도 Retry 높음 → AP 레벨 채널 경쟁\n' : '';
      final coAction = d.band == '2.4GHz'
          ? '2.4GHz 채널 간섭 — 5GHz 전환 검토\n→ AP 채널 1 / 6 / 11 비중복 배치'
          : d.band == '5GHz'
              ? '5GHz 채널 경쟁\n→ 비DFS 채널(36~48 / 149~165) 사용 확인\n→ 주변 AP와 채널 분리'
              : '채널 간섭 의심 — AP 채널 점검';
      return DiagnosisResult(
        layer: FaultLayer.network,
        summary: '채널 간섭 의심 (Retry ${d.txRetryRate.toInt()}%)',
        detail: '${coDetail}TX Retry율 ${d.txRetryRate.toStringAsFixed(1)}% — 채널 경쟁 발생 중'
            '${d.band.isNotEmpty ? "\n현재 대역: ${d.band}" : ""}',
        action: coAction,
        badgeColor: Colors.orange,
      );
    }
    if (d.recentRoamingCount >= _roamingFreq) {
      return DiagnosisResult(
        layer: FaultLayer.ap,
        summary: '잦은 로밍 (${d.recentRoamingCount}회/5분)',
        detail: '최근 5분간 ${d.recentRoamingCount}회 로밍 — Sticky Client 또는 커버리지 경계',
        action: 'MOXA 로밍 임계값 조정 (-70 dBm)\n→ 인접 AP 오버랩 구간 재설계',
        badgeColor: Colors.orange,
      );
    }
    if (d.currentPing > _pingCritMs) {
      return DiagnosisResult(
        layer: FaultLayer.network,
        summary: 'Ping 심각 지연 (${d.currentPing.toInt()}ms)',
        detail: '핑 ${d.currentPing.toInt()}ms — 네트워크 과부하 또는 루프 의심',
        action: '스위치 STP 루프 점검\n→ QoS 정책 적용 여부 확인',
        badgeColor: Colors.red,
      );
    }
    if (d.currentPing > _pingHighMs) {
      return DiagnosisResult(
        layer: FaultLayer.network,
        summary: 'Ping 지연 (${d.currentPing.toInt()}ms)',
        detail: '핑 ${d.currentPing.toInt()}ms — 정상 범위 초과',
        action: '네트워크 대역폭 및 채널 간섭 점검',
        badgeColor: Colors.amber,
      );
    }
    return const DiagnosisResult(
      layer: FaultLayer.normal,
      summary: '정상',
      detail: '모든 계층 정상 동작 중',
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

  // 확장 필드 (에이전트가 보낼 때 자동 활성화, -1 = 미지원)
  double pingGwMs    = -1;
  double pingSrvMs   = -1;
  double packetLoss  = -1;
  double cpuPct      = -1;
  double memPct      = -1;
  bool?  moxaConnected;
  int    moxaRssi    = 0;
  String vlanId      = "";
  int    ifErrors    = 0;
  int    reconnectCount = 0;

  // 채널 품질 필드 (iw station dump 기반, -1 = 미지원)
  double txRetryRate = -1;
  int    txFailed    = -1;
  double rxBitrate   = -1;
  double txBitrate   = -1;
  int    freqMhz     = 0;
  String band        = "";

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
    if (json['ping_srv_ms']     != null) pingSrvMs     = (json['ping_srv_ms']     as num).toDouble();
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

    int newRssi = int.tryParse(json['rssi'].toString().replaceAll('dBm', '').trim()) ?? -100;

    // ── 로밍 감지 ──────────────────────────────────────────
    if (currentBssid.isNotEmpty && currentBssid != json['bssid'] && json['bssid'] != "Disconnected") {
      _addLog("ROAM", "로밍: $currentBssid ➔ ${json['bssid']} (Ch: $currentChannel)");
      _roamingTimestamps.add(DateTime.now());
      _roamingTimestamps.removeWhere((t) => DateTime.now().difference(t).inMinutes > 30);
    }
    currentBssid = json['bssid'];
    currentRssi  = newRssi;

    // ── 상태 변화 감지 ─────────────────────────────────────
    if (_prevStatus.isNotEmpty && _prevStatus != status) {
      _addLog("STATUS", "상태 변화: $_prevStatus → $status");
    }
    _prevStatus = status;

    // ── RSSI 임계값 교차 감지 (debounce: 3초 연속 시에만 이벤트) ──
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
    if (packetLoss > 5)        _addLog("WARN", "패킷 손실: ${packetLoss.toInt()}%");
    if (reconnectCount > 0)    _addLog("SYS",  "에이전트 재연결 누적: $reconnectCount 회");

    pingHistory.add(FlSpot(timeIndex, currentPing));
    rssiHistory.add(FlSpot(timeIndex, currentRssi.toDouble()));
    if (pingHistory.length > 60) { pingHistory.removeAt(0); rssiHistory.removeAt(0); }
    timeIndex++;
  }

  void _addLog(String type, String message) {
    structuredLogs.insert(0, {"time": lastTime, "type": type, "message": message});
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
    buf.writeln('최근 5분 로밍 : $recentRoamingCount 회');
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
      case FaultLayer.ap:      return 'AP / 무선 계층';
      case FaultLayer.moxa:    return 'MOXA 장비';
      case FaultLayer.network: return '네트워크 계층';
      case FaultLayer.server:  return '관제서버';
      case FaultLayer.agent:   return '미니PC / 에이전트';
    }
  }

  String _rssiGrade(int r) {
    if (r >= -65) return '(우수)';
    if (r >= -75) return '(양호)';
    if (r >= -85) return '(약함 ⚠)';
    return '(불량 ✗)';
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
// [D] 메인 관제 화면
// ============================================================
class MonitorDashboard extends StatefulWidget {
  const MonitorDashboard({super.key});
  @override
  State<MonitorDashboard> createState() => _MonitorDashboardState();
}

class _MonitorDashboardState extends State<MonitorDashboard> {
  final String broker = 'ws://172.18.100.123/mqtt';
  late MqttClient client;
  Map<String, RobotData> robots = {};
  final Set<String> _collapsedRobots = {};
  bool    isConnected       = false;
  bool    _showLayerHeader  = true;
  bool    _tableView        = true;
  String? _expandedTableRow;
  bool _disposed = false;
  DateTime? _lastDataTime;
  Timer? _ticker;

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
    client.port = 8083;
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
        final recMess = c![0].payload as MqttPublishMessage;
        final payload = MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
        try {
          final json = jsonDecode(payload);
          final rid  = json['robot_id'];
          if (!_disposed) {
            setState(() {
              _lastDataTime = DateTime.now();
              robots.putIfAbsent(rid, () => RobotData());
              robots[rid]!.update(json);
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

  void _onConnected()      { if (!_disposed) setState(() => isConnected = true);  client.subscribe('infra_test/network_status/#', MqttQos.atMostOnce); }
  void _onDisconnected()   { if (!_disposed) setState(() => isConnected = false); }
  void _onAutoReconnected(){ if (!_disposed) setState(() => isConnected = true);  client.subscribe('infra_test/network_status/#', MqttQos.atMostOnce); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey.shade200,
      appBar: AppBar(
        title: const Text('AMR 인프라 실시간 관제 시스템',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
        backgroundColor: Colors.indigo.shade900,
        elevation: 5,
        actions: [
          Row(children: [
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
      body: robots.isEmpty
          ? const Center(
              child: Text("데이터 수신 대기 중... (로봇의 에이전트를 켜주세요)",
                  style: TextStyle(fontSize: 18, color: Colors.grey)))
          : Column(children: [
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
            ]),
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
        Expanded(flex: 2, child: _thCell("Retry")),
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

    final retryColor = data.txRetryRate < 0  ? Colors.grey
        : data.txRetryRate > 30              ? Colors.red
        : data.txRetryRate > 20              ? Colors.deepOrange
        : data.txRetryRate > 10              ? Colors.amber
        :                                      Colors.green;

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
              // Retry
              Expanded(flex: 2, child: data.txRetryRate >= 0
                  ? _tdValue(
                      data.txRetryRate.toStringAsFixed(1), '%', retryColor)
                  : _tdDash()),
              // Ping
              Expanded(flex: 2, child: _tdValue(
                  '${data.currentPing.toInt()}', 'ms',
                  _pingColor(data.currentPing))),
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
        if (diag.layer != FaultLayer.normal) ...[
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
    return Container(
      color: Colors.indigo.shade800,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            const Text('전체 현황: ', style: TextStyle(color: Colors.white70, fontSize: 12)),
            const SizedBox(width: 8),
            ...robots.values.map((data) {
              final diag = DiagnosisEngine.analyze(data, allRobots: robots);
              final isStale = data.lastReceived != null &&
                  DateTime.now().difference(data.lastReceived!).inSeconds > _dataTimeoutSec;
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Chip(
                  avatar: Icon(_diagIcon(diag.layer), size: 14, color: Colors.white),
                  label: Text(
                    '${data.id}  ${isStale ? "⚠" : ""}  RSSI ${data.currentRssi}dBm',
                    style: const TextStyle(color: Colors.white, fontSize: 11),
                  ),
                  backgroundColor: diag.badgeColor.withOpacity(0.85),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                ),
              );
            }),
          ],
        ),
      ),
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
          color: diag.layer == FaultLayer.normal ? Colors.transparent : diag.badgeColor,
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
              if (diag.layer != FaultLayer.normal) ...[
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
            onPressed: () {
              Clipboard.setData(ClipboardData(text: report));
              ScaffoldMessenger.of(context).showSnackBar(
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
