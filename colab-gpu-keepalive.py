#!/usr/bin/env python3
"""Write a Colab heartbeat log and periodically check the GPU or CPU."""

import os
import shutil
import subprocess
import time
from datetime import datetime

try:
    import torch
except ImportError:
    torch = None

try:
    import psutil
except ImportError:
    psutil = None


LOG_FILE = "/content/gpu-heartbeat.log"
VERSION = "1.2.1"


def log(message: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} version={VERSION} {message} {system_metrics()}"
    print(line, flush=True)
    with open(LOG_FILE, "a", encoding="utf-8") as output:
        output.write(line + "\n")


def size_gb(value: int) -> str:
    return f"{value / 1024**3:.1f}G"


def system_metrics() -> str:
    disk = shutil.disk_usage("/content")
    disk_text = f"disk={size_gb(disk.used)}/{size_gb(disk.total)}"

    if psutil is not None:
        memory = psutil.virtual_memory()
        cpu_text = f"cpu={psutil.cpu_percent():.1f}%"
        memory_text = f"memory={size_gb(memory.used)}/{size_gb(memory.total)}"
    else:
        cpu_text = f"load={os.getloadavg()[0]:.2f}"
        memory_text = "memory=unknown"

    gpu_text = "gpu=none"
    if torch is not None and torch.cuda.is_available():
        try:
            raw = subprocess.check_output(
                [
                    "nvidia-smi",
                    "--query-gpu=utilization.gpu,memory.used,memory.total",
                    "--format=csv,noheader,nounits",
                ],
                text=True,
                timeout=5,
            ).strip().splitlines()[0]
            utilization, used, total = (part.strip() for part in raw.split(","))
            gpu_text = f"gpu={utilization}% gpu_memory={used}/{total}MiB"
        except Exception:
            free, total = torch.cuda.mem_get_info()
            gpu_text = f"gpu=ready gpu_memory={size_gb(total - free)}/{size_gb(total)}"

    return f"{gpu_text} {cpu_text} {memory_text} {disk_text}"


for minute in range(10**9):
    if minute % 5 == 0:
        if torch is not None and torch.cuda.is_available():
            value = torch.randn(256, 256, device="cuda").sum().item()
            torch.cuda.synchronize()
            log(f"GPU OK checksum={value:.4f}")
        elif torch is not None:
            value = torch.randn(256, 256).sum().item()
            log(f"CPU OK checksum={value:.4f}")
        else:
            value = sum(number * number for number in range(10_000))
            log(f"CPU OK checksum={value}")
    else:
        log("ALIVE")
    time.sleep(60)
