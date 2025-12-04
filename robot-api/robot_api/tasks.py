import os
import shlex
import shutil
import subprocess
from pathlib import Path
from typing import Optional, Dict, Any

import psutil

WIFI_CONF_PATH = Path(os.environ.get("WIFI_CONF_PATH", "/var/lib/polyflow/wifi.conf"))
WIFI_SWITCH_CMD = os.environ.get("WIFI_SWITCH_CMD", "/run/current-system/sw/bin/polyflow-wifi-mode")


def write_wifi_conf(ssid: str, psk: Optional[str]) -> None:
    WIFI_CONF_PATH.parent.mkdir(parents=True, exist_ok=True)
    ssid_q = shlex.quote(ssid)
    psk_q = shlex.quote(psk or "")
    WIFI_CONF_PATH.write_text(f"WIFI_SSID={ssid_q}\nWIFI_PSK={psk_q}\n")


def clear_wifi_conf() -> None:
    if WIFI_CONF_PATH.exists():
        WIFI_CONF_PATH.unlink()


def run_switch() -> None:
    subprocess.run([WIFI_SWITCH_CMD], check=True)


def read_wifi_conf() -> Dict[str, Any]:
    if not WIFI_CONF_PATH.exists():
        return {"configured": False, "ssid": None, "pskSet": False}
    ssid = None
    psk = None
    for line in WIFI_CONF_PATH.read_text().splitlines():
        if line.startswith("WIFI_SSID="):
            ssid = line.split("=", 1)[1].strip().strip('"').strip("'")
        elif line.startswith("WIFI_PSK="):
            psk = line.split("=", 1)[1].strip().strip('"').strip("'")
    return {"configured": True, "ssid": ssid, "pskSet": bool(psk)}


_THERMAL_PATHS = [
    Path("/sys/class/thermal/thermal_zone0/temp"),
    Path("/sys/class/hwmon/hwmon0/temp1_input"),
]


def _read_temperature() -> Optional[float]:
    for path in _THERMAL_PATHS:
        try:
            raw = path.read_text().strip()
        except FileNotFoundError:
            continue
        if not raw:
            continue
        try:
            value = float(raw)
        except ValueError:
            continue
        # Many sysfs entries report millidegrees
        if value > 200:
            value = value / 1000.0
        return value

    vcgencmd = shutil.which("vcgencmd")
    if not vcgencmd:
        return None
    try:
        output = subprocess.check_output([vcgencmd, "measure_temp"], text=True).strip()
    except (subprocess.CalledProcessError, FileNotFoundError):
        return None
    if not output:
        return None
    try:
        # Typical output: temp=43.5'C
        value = output.split("=", 1)[1].split("'C", 1)[0]
        return float(value)
    except (IndexError, ValueError):
        return None


def read_system_stats() -> Dict[str, Any]:
    cpu_usage = psutil.cpu_percent(interval=0.1)
    memory = psutil.virtual_memory()
    return {
        "robotName": os.uname().nodename,
        "cpuUsage": cpu_usage,
        "ramUsage": memory.percent,
        "temperatureC": _read_temperature(),
    }
