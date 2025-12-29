import os
import time
import random
import traceback
import paho.mqtt.client as mqtt

BROKER_HOST = os.getenv("MQTT_BROKER", "mosquitto")
BROKER_PORT = int(os.getenv("MQTT_PORT", "1883"))

SENSOR_TYPE = os.getenv("SENSOR_TYPE", "temperature")     # temperature, humidity, motion, etc.
ROOM        = os.getenv("ROOM", "livingroom")
SENSOR_NAME = os.getenv("SENSOR_NAME", "sensor01")        # unique per container
INTERVAL    = float(os.getenv("INTERVAL", "5"))

TOPIC = f"sensors/{SENSOR_TYPE}/{ROOM}/{SENSOR_NAME}"

def log(msg):
    print(msg, flush=True)

def on_connect(client, userdata, flags, reason_code, properties=None):
    log(f"[{SENSOR_NAME}] Connected rc={reason_code}")

def connect_client():
    client = mqtt.Client(client_id=SENSOR_NAME)
    client.on_connect = on_connect

    while True:
        try:
            log(f"[{SENSOR_NAME}] Connecting to {BROKER_HOST}:{BROKER_PORT} ...")
            client.connect(BROKER_HOST, BROKER_PORT, 60)
            log(f"[{SENSOR_NAME}] Connected.")
            return client
        except Exception as e:
            log(f"[{SENSOR_NAME}] Connect failed: {e!r}")
            traceback.print_exc()
            time.sleep(5)

def generate_value(sensor_type: str):
    if sensor_type == "temperature":
        return f"{(20 + random.random() * 5):.2f}"
    if sensor_type == "humidity":
        return f"{(40 + random.random() * 20):.2f}"
    if sensor_type == "motion":
        return "1" if random.random() < 0.10 else "0"
    return str(random.random())

def main():
    client = connect_client()
    client.loop_start()

    log(f"[{SENSOR_NAME}] Publishing to topic: {TOPIC}")
    while True:
        payload = generate_value(SENSOR_TYPE)
        log(f"[{SENSOR_NAME}] {payload} -> {TOPIC}")
        client.publish(TOPIC, payload).wait_for_publish()
        time.sleep(INTERVAL)

if __name__ == "__main__":
    main()
