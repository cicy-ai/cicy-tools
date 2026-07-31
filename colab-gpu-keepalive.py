#!/usr/bin/env python3
"""Write a Colab heartbeat log and periodically run a tiny CUDA operation."""

import time
from datetime import datetime

import torch


LOG_FILE = "/content/gpu-heartbeat.log"


def log(message: str) -> None:
    line = f"{datetime.now():%Y-%m-%d %H:%M:%S} {message}"
    print(line, flush=True)
    with open(LOG_FILE, "a", encoding="utf-8") as output:
        output.write(line + "\n")


for minute in range(10**9):
    if minute % 5 == 0 and torch.cuda.is_available():
        value = torch.randn(256, 256, device="cuda").sum().item()
        torch.cuda.synchronize()
        log(f"GPU OK checksum={value:.4f}")
    else:
        log("ALIVE")
    time.sleep(60)
