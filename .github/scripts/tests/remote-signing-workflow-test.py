#!/usr/bin/env python3

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]
WORKFLOWS = (
    ROOT / ".github/workflows/local.yml",
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

pro = (ROOT / ".github/workflows/pro.yml").read_text(encoding="utf-8")
installer = (ROOT / ".github/workflows/pro-windows-installer.yml").read_text(encoding="utf-8")
signer = (ROOT / ".github/workflows/sign-windows-artifact.yml").read_text(encoding="utf-8")
require("WinSCP" not in pro and "WIN_SERVER_IP" not in pro,
        "Pro signing must not require an inbound SSH connection")
require("needs: [resolve_source, release]" in pro,
        "Windows finishing must wait for the locked source and unsigned build")
promote = pro.split("  promote:\n", 1)[1].split("  notify_summary:\n", 1)[0]
require("      - windows_release\n" in promote,
        "promotion must wait for verified Windows signatures")
require("if: inputs.publish_release" in promote,
        "build-only trials must not promote update pointers")
require("    needs: sign_msi\n" in installer and "    needs: wrap_exe\n" in installer
        and "    needs: sign_exe\n" in installer,
        "MSI signing, wrapping, EXE signing, and final verification must run in order")
require(installer.count("Get-AuthenticodeSignature") == 2,
        "Windows must verify both MSI and EXE signatures")
require("artifact-ids: ${{ needs.sign_msi.outputs.artifact_id }}" in installer
        and "artifact-ids: ${{ needs.sign_exe.outputs.artifact_id }}" in installer,
        "Windows must consume the exact artifacts returned by its signing jobs")
require("runs-on: [self-hosted, macOS, ARM64, macstudio-signing]" in signer,
        "signing must run on the native Mac Studio runner")
require("github.event_name == 'pull_request'" not in signer
        and "github.repository == 'juliet0416/cicd-test'" in signer,
        "the signing runner must be restricted to trusted repository events")
require("actions/checkout" not in signer and "secrets:" not in signer,
        "the signing host must not check out product code or inherit repository secrets")

print("remote signing workflow tests passed")
