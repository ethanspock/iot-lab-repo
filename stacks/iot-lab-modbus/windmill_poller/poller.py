import os
import json
import time

import paho.mqtt.client as mqtt
from pymodbus.client.sync import ModbusTcpClient

def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default

def env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default

MODBUS_HOST = os.getenv("MODBUS_HOST", "windmill_modbus")
MODBUS_PORT = env_int("MODBUS_PORT", 5020)
UNIT_ID = env_int("MODBUS_UNIT_ID", 1)
POLL_INTERVAL = env_float("POLL_INTERVAL_SEC", 1)

TB_HOST = os.getenv("TB_HOST", "thingsboard")
TB_PORT = env_int("TB_MQTT_PORT", 1883)
TB_TOKEN = os.getenv("TB_GATEWAY_TOKEN", "")
TB_DEVICE_NAME = os.getenv("TB_DEVICE_NAME", "Windmill-01")

# Register addresses
REG_WIND_X100 = 0
REG_RPM       = 1
REG_POWER_X10 = 2
REG_TEMP_X10  = 3
REG_STATUS    = 4
REG_FAULT     = 5

def uint16_to_int16(v: int) -> int:
    return v - 65536 if v > 32767 else v

def decode_values(regs):
    wind_ms = regs[0] / 100.0
    rpm = regs[1]
    power_kw = regs[2] / 10.0
    temp_c = uint16_to_int16(regs[3]) / 10.0
    status = regs[4]
    fault_code = regs[5]

    running = bool(status & (1 << 0))
    overspeed = bool(status & (1 << 1))
    fault = bool(status & (1 << 2))

    return {
        "wind_speed_ms": wind_ms,
        "rpm": rpm,
        "power_kw": power_kw,
        "temp_c": temp_c,
        "status_raw": status,
        "running": running,
        "overspeed": overspeed,
        "fault": fault,
        "fault_code": fault_code,
    }

def build_gateway_payload(device_name: str, values: dict, ts_ms: int) -> str:
    # ThingsBoard Gateway telemetry format
    payload = {
        device_name: [
            {
                "ts": ts_ms,
                "values": values
            }
        ]
    }
    return json.dumps(payload)

def main():
    if not TB_TOKEN:
        raise SystemExit("TB_GATEWAY_TOKEN is empty. Set it to your ThingsBoard *gateway device* token.")

    # MQTT client: username = token, password empty (TB default)
    client = mqtt.Client(client_id=f"windmill_poller_{TB_DEVICE_NAME}")
    client.username_pw_set(TB_TOKEN)

    print(f"[poller] Connecting MQTT to {TB_HOST}:{TB_PORT} (ThingsBoard) ...")
    client.connect(TB_HOST, TB_PORT, keepalive=60)
    client.loop_start()

    print(f"[poller] Connecting Modbus to {MODBUS_HOST}:{MODBUS_PORT}, unit_id={UNIT_ID} ...")
    modbus = ModbusTcpClient(MODBUS_HOST, port=MODBUS_PORT)

    # Basic connect loop (don’t die on startup ordering)
    while not modbus.connect():
        print("[poller] Modbus connect failed, retrying in 2s...")
        time.sleep(2)

    print("[poller] Started. Publishing to topic: v1/gateway/telemetry")

    try:
        while True:
            rr = modbus.read_holding_registers(REG_WIND_X100, 6, unit=UNIT_ID)
            if rr.isError():
                print(f"[poller] Modbus read error: {rr}")
                time.sleep(POLL_INTERVAL)
                continue

            values = decode_values(rr.registers)
            ts_ms = int(time.time() * 1000)
            msg = build_gateway_payload(TB_DEVICE_NAME, values, ts_ms)

            # QoS 1 is usually a good default for telemetry
            res = client.publish("v1/gateway/telemetry", msg, qos=1)
            if res.rc != 0:
                print(f"[poller] MQTT publish failed rc={res.rc}")
            else:
                print(f"[poller] {TB_DEVICE_NAME} -> {values}")

            time.sleep(POLL_INTERVAL)

    finally:
        client.loop_stop()
        client.disconnect()
        modbus.close()

if __name__ == "__main__":
    main()
