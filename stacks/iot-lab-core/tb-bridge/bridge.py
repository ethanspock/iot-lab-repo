import os
import json
import time
import paho.mqtt.client as mqtt

MOSQUITTO_HOST = os.getenv("MOSQUITTO_HOST", "mosquitto")
MOSQUITTO_PORT = int(os.getenv("MOSQUITTO_PORT", "1883"))

TB_HOST = os.getenv("TB_HOST", "thingsboard")
TB_PORT = int(os.getenv("TB_PORT", "1883"))
TB_GATEWAY_TOKEN = os.getenv("TB_GATEWAY_TOKEN", "").strip()

SUB_TOPIC = os.getenv("SUB_TOPIC", "sensors/#")
INTERVAL_FLUSH_SEC = float(os.getenv("INTERVAL_FLUSH_SEC", "1.0"))

if not TB_GATEWAY_TOKEN:
    raise SystemExit("TB_GATEWAY_TOKEN is required")

# Buffer telemetry so we can batch-send multiple devices in one gateway message
buffer = {}  # deviceName -> dict of telemetry kv
last_flush = time.time()

def topic_to_device_and_key(topic: str):
    # sensors/<type>/<room>/<sensor>
    parts = topic.split("/")
    if len(parts) < 4:
        return None, None

    sensor_type = parts[1]
    room = parts[2]
    sensor = parts[3]

    device_name = f"{room}_{sensor}"   # ex: livingroom_temp_livingroom_01
    key = sensor_type                  # ex: temperature/humidity/motion
    return device_name, key

def try_parse_payload(payload: bytes):
    s = payload.decode(errors="ignore").strip()
    # If it's JSON already, pass through (expect {"temp":22.1} etc.)
    if s.startswith("{") and s.endswith("}"):
        try:
            return json.loads(s)
        except Exception:
            pass
    # Otherwise try float/int; else string
    try:
        if "." in s:
            return float(s)
        return int(s)
    except Exception:
        return s

def flush(tb_client: mqtt.Client):
    global buffer, last_flush
    if not buffer:
        return

    ts = int(time.time() * 1000)
    msg = {}

    for dev, telemetry in buffer.items():
        msg[dev] = [{
            "ts": ts,
            "values": telemetry
        }]

    payload = json.dumps(msg)
    tb_client.publish("v1/gateway/telemetry", payload, qos=1)
    buffer = {}
    last_flush = time.time()


def on_mosq_message(client, userdata, msg):
    global buffer, last_flush
    device, key = topic_to_device_and_key(msg.topic)
    if not device:
        return

    val = try_parse_payload(msg.payload)

    # If sensor already publishes JSON object, merge it
    if isinstance(val, dict):
        telemetry = val
    else:
        telemetry = {key: val}

    buffer.setdefault(device, {}).update(telemetry)

def main():
    # Connect to ThingsBoard MQTT (Gateway token is MQTT username)
    tb = mqtt.Client()
    tb.username_pw_set(TB_GATEWAY_TOKEN)
    tb.connect(TB_HOST, TB_PORT, 60)
    tb.loop_start()

    # Connect to Mosquitto
    mosq = mqtt.Client()
    mosq.on_message = on_mosq_message
    mosq.connect(MOSQUITTO_HOST, MOSQUITTO_PORT, 60)
    mosq.subscribe(SUB_TOPIC)
    mosq.loop_start()

    while True:
        time.sleep(0.2)
        if time.time() - last_flush >= INTERVAL_FLUSH_SEC:
            flush(tb)

if __name__ == "__main__":
    main()
