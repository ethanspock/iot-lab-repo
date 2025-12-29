import os
import json
import time
from dataclasses import dataclass
from typing import List, Dict, Tuple

import paho.mqtt.client as mqtt
from pymodbus.client.sync import ModbusTcpClient

# Registers
REG_WIND_X100 = 0
REG_RPM       = 1
REG_POWER_X10 = 2
REG_TEMP_X10  = 3
REG_STATUS    = 4
REG_FAULT     = 5

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

def uint16_to_int16(v: int) -> int:
    return v - 65536 if v > 32767 else v

def decode_values(regs: List[int]) -> Dict:
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

@dataclass
class WindmillTarget:
    name: str
    host: str
    port: int
    unit: int

def parse_targets(spec: str) -> List[WindmillTarget]:
    """
    spec format:
      Windmill-01@host:port:unit,Windmill-02@host:port:unit
    """
    targets: List[WindmillTarget] = []
    if not spec.strip():
        return targets

    parts = [p.strip() for p in spec.split(",") if p.strip()]
    for p in parts:
        # name@host:port:unit
        name, rest = p.split("@", 1)
        host, port, unit = rest.split(":", 2)
        targets.append(WindmillTarget(name=name, host=host, port=int(port), unit=int(unit)))
    return targets

def connect_mqtt(tb_host: str, tb_port: int, token: str) -> mqtt.Client:
    client = mqtt.Client(client_id="windfarm_poller")
    client.username_pw_set(token)
    client.connect(tb_host, tb_port, keepalive=60)
    client.loop_start()
    return client

def main():
    poll_interval = env_float("POLL_INTERVAL_SEC", 1.0)
    tb_host = os.getenv("TB_HOST", "thingsboard")
    tb_port = env_int("TB_MQTT_PORT", 1883)
    token = os.getenv("TB_GATEWAY_TOKEN", "")
    spec = os.getenv("WINDMILLS", "")

    if not token:
        raise SystemExit("TB_GATEWAY_TOKEN is empty. Set it to your ThingsBoard gateway device token.")
    targets = parse_targets(spec)
    if not targets:
        raise SystemExit("WINDMILLS is empty. Example: Windmill-01@windmill_modbus_01:5020:1,...")

    print(f"[windfarm] Targets: {', '.join([f'{t.name}({t.host}:{t.port} u{t.unit})' for t in targets])}")
    print(f"[windfarm] Connecting MQTT to {tb_host}:{tb_port} ...")
    mqtt_client = connect_mqtt(tb_host, tb_port, token)

    # Modbus clients per target
    modbus_clients: Dict[str, ModbusTcpClient] = {}
    for t in targets:
        modbus_clients[t.name] = ModbusTcpClient(t.host, port=t.port)

    try:
        while True:
            ts_ms = int(time.time() * 1000)

            gateway_payload: Dict[str, List[Dict]] = {}
            debug_line: List[str] = []

            for t in targets:
                client = modbus_clients[t.name]

                if not client.connect():
                    debug_line.append(f"{t.name}=MODBUS_CONNECT_FAIL")
                    continue

                rr = client.read_holding_registers(REG_WIND_X100, 6, unit=t.unit)
                if rr.isError():
                    debug_line.append(f"{t.name}=MODBUS_READ_ERR")
                    continue

                values = decode_values(rr.registers)
                gateway_payload[t.name] = [{"ts": ts_ms, "values": values}]
                debug_line.append(f"{t.name}=ok wind={values['wind_speed_ms']:.2f} rpm={values['rpm']} kw={values['power_kw']:.1f}")

            if gateway_payload:
                msg = json.dumps(gateway_payload)
                res = mqtt_client.publish("v1/gateway/telemetry", msg, qos=1)
                if res.rc != 0:
                    print(f"[windfarm] MQTT publish failed rc={res.rc}")
                else:
                    print("[windfarm] " + " | ".join(debug_line))
            else:
                print("[windfarm] No telemetry this cycle (all targets failed)")

            time.sleep(poll_interval)

    finally:
        mqtt_client.loop_stop()
        mqtt_client.disconnect()
        for c in modbus_clients.values():
            try:
                c.close()
            except Exception:
                pass

if __name__ == "__main__":
    main()
