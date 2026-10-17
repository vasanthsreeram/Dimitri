"""Runner registry.

Runners are registered explicitly: adding a model means adding a class with a
manifest and setting it up here. The HTTP layer only sees manifests and the
methods on :class:`~dimitri.runners.base.Runner`.
"""

from __future__ import annotations

from ..config import Settings
from ..models import RunnerManifestModel, RunnerStatusModel
from .alphafold3_mac import AlphaFold3MacRunner
from .base import Runner
from .demo import DemoRunner
from .openfold3 import OpenFold3Runner
from .rhofold import RhoFoldRunner


class RunnerRegistry:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._runners: dict[str, Runner] = {
            runner.manifest.id: runner
            for runner in (
                AlphaFold3MacRunner(settings),
                RhoFoldRunner(settings),
                OpenFold3Runner(settings),
                DemoRunner(),
            )
        }

    def get(self, runner_id: str) -> Runner:
        if runner_id not in self._runners:
            raise KeyError(runner_id)
        return self._runners[runner_id]

    def all(self, include_hidden: bool = False) -> list[Runner]:
        runners = list(self._runners.values())
        if include_hidden:
            return runners
        return [runner for runner in runners if runner.manifest.visible]

    def manifest(self, runner_id: str) -> RunnerManifestModel:
        return self.get(runner_id).manifest.to_model(self.settings)

    def manifests(self, include_hidden: bool = False) -> list[RunnerManifestModel]:
        return [
            runner.manifest.to_model(self.settings)
            for runner in self.all(include_hidden=include_hidden)
        ]

    def status(self, runner_id: str) -> RunnerStatusModel:
        return self.get(runner_id).status(self.settings)

    def statuses(self, include_hidden: bool = False) -> list[RunnerStatusModel]:
        return [
            runner.status(self.settings)
            for runner in self.all(include_hidden=include_hidden)
        ]
