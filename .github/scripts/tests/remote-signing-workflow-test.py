#!/usr/bin/env python3
"""Guard the release/signing boundary shared by the Pro and Local workflows."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


for product in ("pro", "local"):
    workflow = ROOT / f".github/workflows/{product}.yml"
    source = workflow.read_text(encoding="utf-8")
    require("WinSCP" not in source and "WIN_SERVER_IP" not in source,
            f"{product} signing must not require an inbound SSH connection")
    require("uses: ./.github/workflows/windows-installer.yml" in source,
            f"{product} must use the shared Windows signing pipeline")
    require("needs: [resolve_source, release]" in source,
            f"{product} Windows finishing must wait for locked source and unsigned build")
    require(f"unsigned-{product}-msi-${{{{ github.run_id }}}}" in source,
            f"{product} must keep unsigned MSI artifacts separate")
    promote = source.split("  promote:\n", 1)[1].split("  notify_summary:\n", 1)[0]
    require("      - windows_release\n" in promote,
            f"{product} promotion must wait for verified Windows signatures")
    require("if: inputs.publish_release" in promote,
            f"{product} build-only trials must not promote update pointers")
    require("if: ${{ always() && inputs.publish_release }}" in source,
            f"{product} build-only trials must not send release summaries")

local = (ROOT / ".github/workflows/local.yml").read_text(encoding="utf-8")
require("      edition: Local\n" in local,
        "Local must select its own Windows product instead of the Pro default")
installer = (ROOT / ".github/workflows/windows-installer.yml").read_text(encoding="utf-8")
signer = (ROOT / ".github/workflows/sign-windows-artifact.yml").read_text(encoding="utf-8")
require("        default: Pro\n" in installer,
        "Existing Pro callers must retain their default product")
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
