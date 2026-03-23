// 플랫폼 감지 후 적절한 MQTT 클라이언트를 생성하는 팩토리 (stub)
// 실제 구현은 mqtt_factory_web.dart / mqtt_factory_native.dart 에 있음
import 'package:mqtt_client/mqtt_client.dart';

MqttClient createMqttClient(String broker, String clientId) {
  throw UnsupportedError('지원하지 않는 플랫폼입니다.');
}
