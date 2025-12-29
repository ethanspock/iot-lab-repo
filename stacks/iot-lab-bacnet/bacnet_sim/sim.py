import os
import random

from bacpypes.app import BIPSimpleApplication
from bacpypes.core import deferred, run
from bacpypes.local.device import LocalDeviceObject
from bacpypes.object import AnalogValueObject
from bacpypes.primitivedata import Real
from bacpypes.task import FunctionTask

DEVICE_ID = int(os.getenv("BACNET_DEVICE_ID", "40001"))
DEVICE_NAME = os.getenv("BACNET_DEVICE_NAME", "NUKE-PLANT-01")

# bacpypes wants "ip:port"
BIND_IP = os.getenv("BACNET_BIND_IP", "0.0.0.0")
BIND_PORT = int(os.getenv("BACNET_PORT", "47808"))
BIND_ADDR = f"{BIND_IP}:{BIND_PORT}"

DRIFT_INTERVAL = float(os.getenv("DRIFT_INTERVAL_SEC", "2.0"))

device = LocalDeviceObject(
    objectName=DEVICE_NAME,
    objectIdentifier=("device", DEVICE_ID),
    maxApduLengthAccepted=1024,
    segmentationSupported="noSegmentation",
    vendorIdentifier=15,
)

app = BIPSimpleApplication(device, BIND_ADDR)

def av(instance: int, name: str, initial: float) -> AnalogValueObject:
    return AnalogValueObject(
        objectIdentifier=("analogValue", instance),
        objectName=name,
        presentValue=Real(initial),
    )

points = {
    "reactor_temp_c": av(1, "reactor_temp_c", 290.0),
    "core_pressure_bar": av(2, "core_pressure_bar", 155.0),
    "coolant_flow_lps": av(3, "coolant_flow_lps", 2200.0),
    "steam_temp_c": av(4, "steam_temp_c", 275.0),
    "turbine_rpm": av(5, "turbine_rpm", 3000.0),
    "net_mw": av(6, "net_mw", 950.0),
    "radiation_msvh": av(7, "radiation_msvh", 0.08),
}

for obj in points.values():
    app.add_object(obj)

drift = {
    "reactor_temp_c": (-0.2, 0.25),
    "core_pressure_bar": (-0.05, 0.05),
    "coolant_flow_lps": (-5.0, 5.0),
    "steam_temp_c": (-0.2, 0.2),
    "turbine_rpm": (-2.0, 2.0),
    "net_mw": (-1.5, 1.5),
    "radiation_msvh": (-0.005, 0.008),
}

limits = {
    "radiation_msvh": (0.01, 0.5),
    "turbine_rpm": (2900.0, 3100.0),
    "net_mw": (800.0, 1100.0),
}

def drift_once():
    for name, obj in points.items():
        lo, hi = drift[name]
        current = float(obj.presentValue.value)
        new_val = current + random.uniform(lo, hi)

        if name in limits:
            mn, mx = limits[name]
            new_val = max(mn, min(new_val, mx))

        obj.presentValue = Real(new_val)

    # schedule next drift tick
    FunctionTask(drift_once).install_task(delta=DRIFT_INTERVAL)

def start():
    print(f"[sim] listening on {BIND_ADDR} device_id={DEVICE_ID}", flush=True)
    FunctionTask(drift_once).install_task(delta=0)

deferred(start)
run()
