// 웹 브라우저 전용: MqttBrowserClient 사용
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_browser_client.dart';

MqttClient createMqttClient(String broker, String clientId) {
  return MqttBrowserClient(broker, clientId);
}
