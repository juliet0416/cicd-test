#!/usr/bin/env python3

import argparse
import importlib.util
import pathlib
import unittest


SCRIPT = pathlib.Path(__file__).parents[1] / "resolve-desktop-release.py"
SPEC = importlib.util.spec_from_file_location("resolve_desktop_release", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def arguments(**overrides):
    values = {
        "version": "5.3.4",
        "channel": "stable",
        "release_epoch": "1",
        "data_schema_version": "0",
        "rollback_compatible_from": "5.3.3",
        "release_notes_url": "https://chat2db.ai/release-notes",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class ResolveDesktopReleaseTest(unittest.TestCase):
    def test_resolves_533_bridge(self):
        profile, channel = MODULE.resolve(
            arguments(version="5.3.3", release_epoch="0")
        )
        self.assertEqual("bridge-fat", profile)
        self.assertEqual("STABLE", channel)

    def test_resolves_533_beta_as_fat_bridge(self):
        profile, channel = MODULE.resolve(
            arguments(
                version="5.3.3",
                channel="beta",
                release_epoch="1",
                rollback_compatible_from="5.3.0",
            )
        )
        self.assertEqual("bridge-fat", profile)
        self.assertEqual("BETA", channel)

    def test_resolves_stable_thin_release(self):
        self.assertEqual(
            ("versioned-thin", "STABLE"),
            MODULE.resolve(arguments()),
        )

    def test_resolves_beta_thin_release(self):
        self.assertEqual(
            ("versioned-thin", "BETA"),
            MODULE.resolve(
                arguments(version="5.3.4-beta.1", channel="beta")
            ),
        )

    def test_rejects_prerelease_on_stable_channel(self):
        with self.assertRaisesRegex(ValueError, "must use the beta channel"):
            MODULE.resolve(arguments(version="5.3.4-beta.1"))

    def test_rejects_bridge_with_nonzero_schema(self):
        with self.assertRaisesRegex(ValueError, "data_schema_version=0"):
            MODULE.resolve(
                arguments(
                    version="5.3.3",
                    release_epoch="0",
                    data_schema_version="1",
                )
            )

    def test_rejects_release_before_bridge(self):
        with self.assertRaisesRegex(ValueError, "starting at 5.3.3"):
            MODULE.resolve(arguments(version="5.3.2"))

    def test_rejects_newer_rollback_floor(self):
        with self.assertRaisesRegex(ValueError, "must not be newer"):
            MODULE.resolve(arguments(rollback_compatible_from="5.3.5"))

    def test_rejects_non_https_release_notes(self):
        with self.assertRaisesRegex(ValueError, "absolute HTTPS URL"):
            MODULE.resolve(arguments(release_notes_url="http://chat2db.ai/notes"))


if __name__ == "__main__":
    unittest.main()
