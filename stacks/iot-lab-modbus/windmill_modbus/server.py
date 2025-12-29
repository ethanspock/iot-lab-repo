import os
import math
import time
import random
from threading import Thread

from pymodbus.server.sync import StartTcpServer
from pymodbus.datastore import ModbusSlaveContext, ModbusServerContext, ModbusSequentialDataBlock

def env_float(name: str, default: float) -> float:
    try:
        return float(os.getenv(name, str(default)))
    except ValueError:
        return default

def env_int(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default

MODBUS_HOST = os.getenv("MODBUS_HOST", "0.0.0.0")
MODBUS_PORT = env_int("MODBUS_PORT", 5020)
UNIT_ID = env_int("MODBUS_UNIT_ID", 1)

WIND_BASE = env_float("WIND_BASE_MS", 8.0)   # base wind speed (m/s)
WIND_GUST = env_float("WIND_GUST_MS", 4.0)   # gust amplitude (m/s)

# Holding register addresses (0-based)
REG_WIND_X100 = 0
REG_RPM       = 1
REG_POWER_X10 = 2
REG_TEMP_X10  = 3
REG_STATUS    = 4
REG_FAULT     = 5

# Status bitfield
BIT_RUNNING   = 0
BIT_OVERSPEED = 1
BIT_FAULT     = 2

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def int16(v: int) -> int:
    # pymodbus expects 0..65535; convert signed -> unsigned
    return v & 0xFFFF

def update_loop(context: ModbusServerContext):
    t0 = time.time()
    temp_c = 22.0
    fault_code = 0

    while True:
        t = time.time() - t0

        # Wind model: base + sinusoid + random gust jitter
        wind = WIND_BASE + (WIND_GUST * math.sin(t / 6.0)) + random.uniform(-0.7, 0.7)
        wind = clamp(wind, 0.0, 30.0)

        # Simple turbine model:
        # rpm roughly proportional to wind until capped; overspeed if too high
        rpm = int(clamp(wind * 35.0 + random.uniform(-5, 5), 0, 2000))

        # Power curve (very simplified): ~wind^3, capped
        power_kw = clamp((wind ** 3) * 0.02, 0.0, 250.0)  # cap at 250 kW
        power_kw = power_kw + random.uniform(-1.0, 1.0)
        power_kw = clamp(power_kw, 0.0, 250.0)

        # Temperature drift
        temp_c += random.uniform(-0.05, 0.05)
        temp_c = clamp(temp_c, -20.0, 60.0)

        overspeed = rpm > 1750
        running = wind > 1.5

        # Fault logic: persistent overspeed triggers fault
        if overspeed and fault_code == 0 and random.random() < 0.15:
            fault_code = 1001  # arbitrary
        if fault_code != 0 and random.random() < 0.05:
            fault_code = 0

        status = 0
        if running:
            status |= (1 << BIT_RUNNING)
        if overspeed:
            status |= (1 << BIT_OVERSPEED)
        if fault_code != 0:
            status |= (1 << BIT_FAULT)

        # Scale to integer registers
        wind_x100 = int(round(wind * 100.0))
        power_x10 = int(round(power_kw * 10.0))
        temp_x10  = int(round(temp_c * 10.0))

        # Write holding registers via slave context
        slave = context[UNIT_ID]
        slave.setValues(3, REG_WIND_X100, [wind_x100])      # 3 = holding registers
        slave.setValues(3, REG_RPM,       [rpm])
        slave.setValues(3, REG_POWER_X10, [power_x10])
        slave.setValues(3, REG_TEMP_X10,  [int16(temp_x10)])
        slave.setValues(3, REG_STATUS,    [status])
        slave.setValues(3, REG_FAULT,     [fault_code])

        time.sleep(1)

def main():
    # Holding register block length: at least up to REG_FAULT
    hr_block = ModbusSequentialDataBlock(0, [0] * 64)

    store = ModbusSlaveContext(
        di=None,
        co=None,
        hr=hr_block,
        ir=None,
        zero_mode=True
    )
    context = ModbusServerContext(slaves={UNIT_ID: store}, single=False)

    Thread(target=update_loop, args=(context,), daemon=True).start()

    print(f"[modbus] Starting Modbus TCP server on {MODBUS_HOST}:{MODBUS_PORT}, unit_id={UNIT_ID}")
    StartTcpServer(context, address=(MODBUS_HOST, MODBUS_PORT))

if __name__ == "__main__":
    main()
