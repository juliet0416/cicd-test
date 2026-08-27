#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = (
    ROOT / ".github/workflows/jcef_offline.yml",
    ROOT / ".github/workflows/jcef_release.yml",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


require(
    not (ROOT / ".github/scripts/invoke-winscp-with-retry.ps1").exists(),
    "remote signing must not use the retired whole-operation retry helper",
)

for workflow in WORKFLOWS:
    source = workflow.read_text(encoding="utf-8")
    require("SuccessProbe" not in source, f"{workflow.name} must not use an ambient exit-code probe")
    require("invoke-winscp-with-retry" not in source, f"{workflow.name} must not retry the full signing flow")
    require(source.count('"/log=winscp-msi.log"') == 1, f"{workflow.name} must invoke MSI signing once")
    require(source.count('"/log=winscp-exe.log"') == 1, f"{workflow.name} must invoke EXE signing once")
    require(source.count("Get-AuthenticodeSignature") == 2,
            f"{workflow.name} must validate both signed MSI and EXE artifacts")
    require(source.count("signedDownloadDirectory") == 4,
            f"{workflow.name} must download the signed EXE away from the existing unsigned package path")
    require(source.count("Copy-Item -LiteralPath $signedPackagePath -Destination $packagePath -Force") == 1,
            f"{workflow.name} must replace the unsigned EXE only after signature validation")
    require(source.count("${{ github.run_id }}-${{ github.run_attempt }}") >= 8,
            f"{workflow.name} signing paths must be isolated by run and attempt")
    require(source.count("will be validated independently") == 2,
            f"{workflow.name} must defer WinSCP exit-code decisions to artifact validation")

print("remote signing workflow tests passed")
