name: MQTT Connect
method: GET
url: mqtt://broker.test.local:1883/telemetry/sensors
headers:
  - X-MQTT-QoS: 1
  - X-MQTT-Client-Id: volt-test-client
variables:
  topic: telemetry/sensors
  qos: 1
