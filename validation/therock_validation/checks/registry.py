from __future__ import annotations

from .rocm_sanity import (
    CheckEnvironmentActivation,
    CheckHipccCompileRun,
    CheckMIOpenDriver,
    CheckMIOpenSmoke,
    CheckRocBLASGemm,
    CheckRocFFT1024,
    CheckRocMinInfo,
    CheckRocRandGenerate,
)
from .third_party import (
    CheckLlamaCppDocker,
    CheckMFEM,
    CheckOllama,
    CheckOpenInterpreter,
    CheckThirdPartyPlan,
    CheckWhisper,
)


def all_checks():
    return [
        CheckEnvironmentActivation(),
        CheckRocMinInfo(),
        CheckHipccCompileRun(),
        CheckRocBLASGemm(),
        CheckRocFFT1024(),
        CheckRocRandGenerate(),
        CheckMIOpenDriver(),
        CheckMIOpenSmoke(),
        CheckThirdPartyPlan(),
        CheckLlamaCppDocker(),
        CheckOllama(),
        CheckOpenInterpreter(),
        CheckWhisper(),
        CheckMFEM(),
    ]
