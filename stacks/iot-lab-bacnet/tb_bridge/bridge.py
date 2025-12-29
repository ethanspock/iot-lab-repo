import os
import json
import time
import socket

import paho.mqtt.client as mqtt

from bacpypes.app import BIPSimpleApplication
from bacpypes.local.device import LocalDeviceObject
from bacpypes.pdu import Address
from bacpypes.apdu import ReadPropertyRequest
from bacpypes.constructeddata import Any
from bacpypes.primitivedata import Real
from bacpypes.iocb import IOCB
from bacpypes.core import deferred, run
from bacpypes.task import FunctionTask

BACNET_BIND = os.getenv("BACNET_BIND", "0.0.0.0:47809")
BACNET_TARGET = os.getenv("BACNET_TARGET", "nuke_bacnet_sim_01:47808")
POINTS_FILE = os.getenv("POINTS_FILE", "/app/points.json")

POLL_SECONDS = float(os.getenv("POLL_SECONDS", "2"))
READ_TIMEOUT_SEC = float(os.getenv("READ_TIMEOUT_SEC", "2"))

TB_HOST = os.getenv("TB_MQTT_HOST", "thingsboard")
TB_PORT = int(os.getenv("TB_MQTT_PORT", "1883"))
TB_GATEWAY_TOKEN = os.getenv("TB_GATEWAY_TOKEN", "")
TB_DEVICE_NAME = os.getenv("TB_DEVICE_NAME", "NuclearPlant-Quantico")

if not TB_GATEWAY_TOKEN:
    raise SystemExit("TB_GATEWAY_TOKEN is required")

with open(POINTS_FILE, "r") as f:
    points = json.load(f)

# MQTT client
m = mqtt.Client()
m.username_pw_set(TB_GATEWAY_TOKEN)
m.connect(TB_HOST, TB_PORT, 60)
m.loop_start()

# Register device under gateway

device = LocalDeviceObject(
    objectName="BACNET-TB-GW-POLLER",
    objectIdentifier=("device", int(os.getenv("BACNET_DEVICE_ID", "41001"))),
    maxApduLengthAccepted=1024,
    segmentationSupported="noSegmentation",
    vendorIdentifier=15,
)

app = BIPSimpleApplication(device, BACNET_BIND)

def resolve_target():
    host, port = BACNET_TARGET.split(":")
    while True:
        try:
            ip = socket.gethostbyname(host)
            addr = Address(f"{ip}:{port}")
            print(f"[bridge] local bind: {BACNET_BIND}", flush=True)
            print(f"[bridge] target resolved: {host}:{port} -> {ip}:{port}", flush=True)
            return addr
        except Exception:
            print(f"[bridge] waiting for DNS for '{host}' ...", flush=True)
            time.sleep(1)

target = resolve_target()

_polling = False

def publish_telemetry(values: dict):
    print("[telemetry]", values, flush=True)
    m.publish("v1/devices/me/telemetry", json.dumps(values), qos=1)


def read_one_point(p, on_done):
    req = ReadPropertyRequest(
        objectIdentifier=(p["type"], int(p["instance"])),
        propertyIdentifier="presentValue",
    )
    req.pduDestination = target

    iocb = IOCB(req)

    def _cb(i):
        if i.ioError:
            on_done(None, str(i.ioError))
            return

        apdu = i.ioResponse
        if not apdu:
            on_done(None, "No response")
            return

        val = apdu.propertyValue
        if isinstance(val, Any):
            # most of your points are Real
            try:
                val = val.cast_out(Real)
            except Exception:
                pass

        try:
            # Real in bacpypes has .value
            out = float(val.value) if hasattr(val, "value") else float(val)
            on_done(out, None)
        except Exception as e:
            on_done(None, f"value parse error: {e}")

    iocb.add_callback(_cb)
    app.request_io(iocb)

    # timeout guard: if no response, mark as timeout and proceed
    def _timeout():
        if not iocb.ioResponse and not iocb.ioError:
            iocb.set_timeout()
            on_done(None, "BACnet read timed out")

    FunctionTask(_timeout).install_task(delta=READ_TIMEOUT_SEC)

def poll_cycle():
    global _polling

    if _polling:
        FunctionTask(poll_cycle).install_task(delta=POLL_SECONDS)
        return

    _polling = True
    telemetry = {"_heartbeat": 1}

    def step(idx: int):
        nonlocal telemetry
        if idx >= len(points):
            publish_telemetry(telemetry)
            _finish()
            return

        p = points[idx]
        key = p["key"]

        def done(val, err):
            if err:
                telemetry[key + "_error"] = err
            else:
                telemetry[key] = val
            step(idx + 1)

        read_one_point(p, done)

    def _finish():
        global _polling
        _polling = False
        FunctionTask(poll_cycle).install_task(delta=POLL_SECONDS)

    try:
        step(0)
    except Exception as e:
        telemetry["poll_error"] = str(e)
        publish_telemetry(telemetry)
        _finish()

def start():
    # kick off first cycle once task manager is live
    FunctionTask(poll_cycle).install_task(delta=0)

deferred(start)
run()
