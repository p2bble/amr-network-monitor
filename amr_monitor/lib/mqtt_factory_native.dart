// 네이티브 플랫폼 전용 (Windows, Android, iOS, Linux, macOS): MqttServerClient 사용
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

MqttClient createMqttClient(String broker, String clientId) {
  final client = MqttServerClient(broker, clientId);
  client.useWebSocket = true;
  return client;
}
