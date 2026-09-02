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
        "version": "5.3.6",
        "channel": "stable",
        "release_epoch": "2",
        "release_notes_url": "https://chat2db.ai/release-notes",
    }
    values.update(overrides)
    return argparse.Namespace(**values)


class ResolveDesktopReleaseTest(unittest.TestCase):
    def test_resolves_stable_thin_release(self):
        self.assertEqual(
            ("versioned-thin", "STABLE"),
            MODULE.resolve(arguments()),
        )

    def test_resolves_beta_thin_release(self):
        self.assertEqual(
            ("versioned-thin", "BETA"),
            MODULE.resolve(arguments(version="5.3.6-beta.3", channel="beta")),
        )

    def test_resolves_later_thin_release(self):
        self.assertEqual(
            ("versioned-thin", "BETA"),
            MODULE.resolve(arguments(version="5.4.0-beta.1", channel="beta")),
        )

    def test_rejects_prerelease_on_stable_channel(self):
        with self.assertRaisesRegex(ValueError, "must use the beta channel"):
            MODULE.resolve(arguments(version="5.3.6-beta.1"))

    def test_rejects_zero_epoch(self):
        with self.assertRaisesRegex(ValueError, "positive release_epoch"):
            MODULE.resolve(arguments(release_epoch="0"))

    def test_rejects_retired_release(self):
        with self.assertRaisesRegex(ValueError, "before 5.3.6 are retired"):
            MODULE.resolve(arguments(version="5.3.5"))

    def test_rejects_non_https_release_notes(self):
        with self.assertRaisesRegex(ValueError, "absolute HTTPS URL"):
            MODULE.resolve(arguments(release_notes_url="http://chat2db.ai/notes"))


if __name__ == "__main__":
    unittest.main()
