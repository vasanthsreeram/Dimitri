"""What Mac we are on, and the runtime defaults that follow from it.

All inference runs on Apple Silicon unified memory, shared with macOS, the app
and whatever else is open. The defaults here size three things to the machine:

- the GPU memory budget a model process may use before it gets a clean
  out-of-memory error instead of pushing the Mac into heavy swap
  (RAM minus a headroom of max(4 GB, 20 %));
- the MLX buffer cache (5 % of RAM, 0.5–4 GB), which MLX otherwise lets grow to
  the memory limit;
- how many models stay loaded and for how long once a job finishes.

Workers apply the budget themselves with ``torch.mps.set_per_process_memory_fraction``
(relative to Metal's recommended working set) or ``mx.set_memory_limit``.
"""

from __future__ import annotations

import platform
import subprocess
from dataclasses import dataclass
from functools import lru_cache

from .models import DeviceInfo

GB = 1024**3


def _sysctl(name: str) -> str | None:
    try:
        out = subprocess.run(
            ["/usr/sbin/sysctl", "-n", name],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    value = out.stdout.strip()
    return value or None


def _int(value: str | None) -> int | None:
    try:
        return int(value) if value is not None else None
    except ValueError:
        return None


@dataclass(frozen=True)
class DeviceProfile:
    chip: str
    memory_bytes: int
    performance_cores: int | None
    efficiency_cores: int | None
    macos: str

    @property
    def memory_gb(self) -> float:
        return round(self.memory_bytes / GB, 1)

    @property
    def tier(self) -> str:
        if self.memory_gb <= 18:
            return "compact"
        if self.memory_gb <= 40:
            return "standard"
        return "large"

    @property
    def tier_label(self) -> str:
        return {
            "compact": "16 GB class: memory-saving settings",
            "standard": "24–36 GB class: balanced settings",
            "large": "48 GB+ class: speed-first settings",
        }[self.tier]

    @property
    def headroom_gb(self) -> float:
        return max(4.0, 0.2 * self.memory_gb)

    @property
    def gpu_budget_gb(self) -> float:
        return round(max(2.0, self.memory_gb - self.headroom_gb), 1)

    @property
    def mlx_cache_limit_gb(self) -> float:
        return round(min(4.0, max(0.5, 0.05 * self.memory_gb)), 1)

    @property
    def keep_warm_minutes(self) -> int:
        return {"compact": 5, "standard": 15, "large": 30}[self.tier]

    @property
    def max_resident_models(self) -> int:
        return {"compact": 1, "standard": 2, "large": 3}[self.tier]

    def worker_env(self) -> dict[str, str]:
        """Environment every model worker gets; workers apply the limits."""
        env = {
            "DIMITRI_MEMORY_GB": f"{self.memory_gb}",
            "DIMITRI_GPU_BUDGET_GB": f"{self.gpu_budget_gb}",
            "DIMITRI_MLX_CACHE_GB": f"{self.mlx_cache_limit_gb}",
            "DIMITRI_DEVICE_TIER": self.tier,
        }
        if self.performance_cores:
            # CPU-side work (featurisation, fallbacks) on the performance cores.
            env["OMP_NUM_THREADS"] = str(self.performance_cores)
        return env

    def info(self) -> DeviceInfo:
        notes = [
            f"Models may use up to {self.gpu_budget_gb:g} GB of unified memory; "
            f"{self.headroom_gb:g} GB stays free for macOS and other apps.",
            f"Up to {self.max_resident_models} model(s) stay loaded between jobs.",
        ]
        if self.tier == "compact":
            notes.append(
                "AlphaFold 3 streams its weights layer by layer (mac-af3) to fit in 16 GB."
            )
        return DeviceInfo(
            chip=self.chip,
            memory_gb=self.memory_gb,
            performance_cores=self.performance_cores,
            efficiency_cores=self.efficiency_cores,
            macos=self.macos,
            tier=self.tier,
            tier_label=self.tier_label,
            keep_warm_minutes=self.keep_warm_minutes,
            max_resident_models=self.max_resident_models,
            gpu_budget_gb=self.gpu_budget_gb,
            mlx_cache_limit_gb=self.mlx_cache_limit_gb,
            notes=notes,
        )


@lru_cache(maxsize=1)
def detect() -> DeviceProfile:
    chip = _sysctl("machdep.cpu.brand_string") or platform.processor() or "Apple Silicon"
    memory = _int(_sysctl("hw.memsize")) or 16 * GB
    return DeviceProfile(
        chip=chip,
        memory_bytes=memory,
        performance_cores=_int(_sysctl("hw.perflevel0.physicalcpu")),
        efficiency_cores=_int(_sysctl("hw.perflevel1.physicalcpu")),
        macos=platform.mac_ver()[0],
    )
