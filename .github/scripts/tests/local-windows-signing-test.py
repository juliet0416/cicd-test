#!/usr/bin/env python3
"""Exercise the native signing step without using a certificate or the network."""

import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[3]
WORKFLOW = ROOT / ".github/workflows/sign-windows-artifact.yml"
step = WORKFLOW.read_text().split("      - name: Sign with the local hardware certificate\n", 1)[1]
step = step.split("      - name:", 1)[0]
SCRIPT = textwrap.dedent(step.split("        run: |\n", 1)[1])


class SigningStepTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chat2db-signing-step-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "input").mkdir()
        (self.root / "output").mkdir()
        self.filename = "Chat2DB-Pro-5.3.9-beta.2.msi"
        self.input = self.root / "input" / self.filename
        self.input.write_bytes(b"unsigned fixture\n")
        self.signer = self.root / "sign.sh"
        self.signer.write_text(
            '#!/bin/bash\nset -eu\n'
            'test "$1" = --alg\n'
            'if [ "${FAIL_ALG:-}" = "$2" ]; then exit 7; fi\n'
            'printf "signed:%s\\n" "$2" >> "$3"\n'
        )
        self.signer.chmod(0o700)

    def run_step(self, filename=None, fail_alg=""):
        return subprocess.run(
            ["bash", "-c", SCRIPT],
            env={
                **os.environ,
                "WORK_DIR": str(self.root),
                "PACKAGE_FILENAME": filename or self.filename,
                "WINDOWS_SIGN_SCRIPT": str(self.signer),
                "FAIL_ALG": fail_alg,
            },
            capture_output=True,
            text=True,
        )

    def test_signs_a_copy_with_both_algorithms(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.input.read_bytes(), b"unsigned fixture\n")
        self.assertEqual(
            (self.root / "output" / self.filename).read_bytes(),
            b"unsigned fixture\nsigned:SHA-1\nsigned:SHA-256\n",
        )

    def test_rejects_path_traversal(self):
        self.assertNotEqual(self.run_step("../outside.exe").returncode, 0)
        self.assertEqual(list((self.root / "output").iterdir()), [])

    def test_rejects_missing_input(self):
        self.input.unlink()
        self.assertNotEqual(self.run_step().returncode, 0)

    def test_rejects_multiple_files(self):
        (self.root / "input" / "stale.msi").write_bytes(b"stale")
        self.assertNotEqual(self.run_step().returncode, 0)

    def test_rejects_symlinks(self):
        self.input.unlink()
        outside = self.root / "outside.msi"
        outside.write_bytes(b"outside")
        self.input.symlink_to(outside)
        self.assertNotEqual(self.run_step().returncode, 0)

    def test_preserves_a_signing_failure(self):
        self.assertEqual(self.run_step(fail_alg="SHA-256").returncode, 7)


if __name__ == "__main__":
    unittest.main()
