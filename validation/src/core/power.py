from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class Sensors:
    power_uw: Path
    gpu_busy_percent: Path | None
    mem_busy_percent: Path | None


def _read_int(path: Path) -> int | None:
    try:
        return int(path.read_text(encoding="utf-8").strip())
    except Exception:
        return None


def discover_sensors() -> Sensors | None:
    """
    Discover an AMDGPU hwmon power sensor via sysfs.

    Works without rocm-smi/amd-smi and typically requires no root access.
    """
    drm = Path("/sys/class/drm")
    if not drm.is_dir():
        return None

    for card in sorted(drm.glob("card[0-9]*")):
        dev = card / "device"
        hwmon = dev / "hwmon"
        if not hwmon.is_dir():
            continue
        for hm in sorted(hwmon.glob("hwmon*")):
            name = (hm / "name").read_text(encoding="utf-8").strip() if (hm / "name").is_file() else ""
            if name != "amdgpu":
                continue
            power = hm / "power1_average"
            if not power.is_file():
                continue
            gpu_busy = dev / "gpu_busy_percent"
            mem_busy = dev / "mem_busy_percent"
            return Sensors(
                power_uw=power,
                gpu_busy_percent=gpu_busy if gpu_busy.is_file() else None,
                mem_busy_percent=mem_busy if mem_busy.is_file() else None,
            )
    return None


@dataclass
class Sample:
    t_s: float
    power_w: float | None
    gpu_busy: int | None
    mem_busy: int | None


class PowerSampler:
    def __init__(self, sensors: Sensors, interval_s: float = 0.5):
        self._sensors = sensors
        self._interval_s = interval_s
        self._samples: list[Sample] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._run, name="power-sampler", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        if self._thread is None:
            return
        self._stop.set()
        self._thread.join(timeout=2.0)
        self._thread = None

    def _run(self) -> None:
        t0 = time.monotonic()
        while not self._stop.is_set():
            t = time.monotonic() - t0
            puw = _read_int(self._sensors.power_uw)
            power_w = (puw / 1_000_000.0) if puw is not None else None
            gpu_busy = _read_int(self._sensors.gpu_busy_percent) if self._sensors.gpu_busy_percent else None
            mem_busy = _read_int(self._sensors.mem_busy_percent) if self._sensors.mem_busy_percent else None
            self._samples.append(Sample(t_s=t, power_w=power_w, gpu_busy=gpu_busy, mem_busy=mem_busy))
            self._stop.wait(self._interval_s)

    def samples(self) -> list[Sample]:
        return list(self._samples)

    def energy_ws(self) -> float | None:
        # Trapezoidal integration over power samples.
        s = [x for x in self._samples if x.power_w is not None]
        if len(s) < 2:
            return None
        e = 0.0
        for a, b in zip(s, s[1:], strict=False):
            dt = float(b.t_s - a.t_s)
            e += 0.5 * (float(a.power_w) + float(b.power_w)) * dt
        return e

    def avg_power_w(self) -> float | None:
        vals = [x.power_w for x in self._samples if x.power_w is not None]
        if not vals:
            return None
        return float(sum(vals)) / float(len(vals))

    def peak_power_w(self) -> float | None:
        vals = [x.power_w for x in self._samples if x.power_w is not None]
        if not vals:
            return None
        return float(max(vals))

    def avg_gpu_busy(self) -> float | None:
        vals = [x.gpu_busy for x in self._samples if x.gpu_busy is not None]
        if not vals:
            return None
        return float(sum(vals)) / float(len(vals))

    def avg_mem_busy(self) -> float | None:
        vals = [x.mem_busy for x in self._samples if x.mem_busy is not None]
        if not vals:
            return None
        return float(sum(vals)) / float(len(vals))


def format_power_metrics(s: PowerSampler, *, baseline_avg_w: float | None = None) -> str:
    e = s.energy_ws()
    avg = s.avg_power_w()
    maxw = s.peak_power_w()
    gpu = s.avg_gpu_busy()
    mem = s.avg_mem_busy()

    def fmt_ws(v: float | None) -> str:
        return f"{v:4.0f}Ws" if v is not None else "  n/a"

    def fmt_w(v: float | None) -> str:
        return f"{v:6.1f}W" if v is not None else "   n/a"

    def fmt_dw(v: float | None) -> str:
        return f"{v:+6.1f}W" if v is not None else "   n/a"

    def fmt_pct(v: float | None) -> str:
        return f"{v:3.0f}" if v is not None else "n/a"

    dw = (avg - baseline_avg_w) if (avg is not None and baseline_avg_w is not None) else None
    # Keep a stable column order for scanability.
    return (
        f"E={fmt_ws(e)}  "
        f"avgW={fmt_w(avg)}  "
        f"dW={fmt_dw(dw)}  "
        f"maxW={fmt_w(maxw)}  "
        f"gpu%={fmt_pct(gpu)}  "
        f"mem%={fmt_pct(mem)}"
    )


def write_csv(path: Path, samples: list[Sample]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = ["t_s,power_w,gpu_busy_percent,mem_busy_percent\n"]
    for s in samples:
        pw = "" if s.power_w is None else f"{s.power_w:.3f}"
        gb = "" if s.gpu_busy is None else str(s.gpu_busy)
        mb = "" if s.mem_busy is None else str(s.mem_busy)
        lines.append(f"{s.t_s:.3f},{pw},{gb},{mb}\n")
    path.write_text("".join(lines), encoding="utf-8")
