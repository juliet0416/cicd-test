#!/usr/bin/env python3

import argparse
import re
from dataclasses import dataclass
from urllib.parse import urlparse


SEMVER_PATTERN = re.compile(
    r"^(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)


@dataclass(frozen=True)
class SemVer:
    major: int
    minor: int
    patch: int
    prerelease: tuple[str, ...]

    @classmethod
    def parse(cls, value: str) -> "SemVer":
        match = SEMVER_PATTERN.fullmatch(value)
        if match is None:
            raise ValueError(f"invalid semantic version: {value}")
        prerelease = tuple(match.group(4).split(".")) if match.group(4) else ()
        return cls(int(match.group(1)), int(match.group(2)), int(match.group(3)), prerelease)

    def compare(self, other: "SemVer") -> int:
        core = (self.major, self.minor, self.patch)
        other_core = (other.major, other.minor, other.patch)
        if core != other_core:
            return -1 if core < other_core else 1
        if not self.prerelease and not other.prerelease:
            return 0
        if not self.prerelease:
            return 1
        if not other.prerelease:
            return -1
        for left, right in zip(self.prerelease, other.prerelease):
            if left == right:
                continue
            left_numeric = left.isdigit()
            right_numeric = right.isdigit()
            if left_numeric and right_numeric:
                return -1 if int(left) < int(right) else 1
            if left_numeric != right_numeric:
                return -1 if left_numeric else 1
            return -1 if left < right else 1
        if len(self.prerelease) == len(other.prerelease):
            return 0
        return -1 if len(self.prerelease) < len(other.prerelease) else 1


def non_negative_integer(value: str, name: str) -> int:
    if not re.fullmatch(r"0|[1-9][0-9]*", value):
        raise ValueError(f"{name} must be a non-negative integer")
    return int(value)


def resolve(args: argparse.Namespace) -> tuple[str, str]:
    version = SemVer.parse(args.version)
    release_epoch = non_negative_integer(args.release_epoch, "release_epoch")
    channel = args.channel.lower()
    if channel not in {"stable", "beta"}:
        raise ValueError("channel must be stable or beta")

    parsed_notes_url = urlparse(args.release_notes_url)
    if parsed_notes_url.scheme != "https" or not parsed_notes_url.netloc:
        raise ValueError("release_notes_url must be an absolute HTTPS URL")

    bridge = SemVer.parse("5.3.3")
    fat_release = SemVer.parse("5.3.4")
    transition_fat_release = SemVer.parse("5.3.5")
    comparison = version.compare(bridge)
    if comparison < 0:
        raise ValueError("desktop updates only support releases starting at 5.3.3")
    if args.version == "5.3.3":
        expected_epoch = 0 if channel == "stable" else 1
        if release_epoch != expected_epoch:
            raise ValueError(
                f"the 5.3.3 {channel} bridge requires release_epoch={expected_epoch}"
            )
        profile = "bridge-fat"
    elif version in (fat_release, transition_fat_release) and not version.prerelease:
        if channel != "stable":
            raise ValueError("the 5.3.4 fat release must use the stable channel")
        if release_epoch != 1:
            raise ValueError(f"the {args.version} fat release requires release_epoch=1")
        profile = "bridge-fat"
    else:
        if release_epoch == 0:
            raise ValueError("versioned-thin releases require a positive release_epoch")
        expected_channel = "beta" if version.prerelease else "stable"
        if channel != expected_channel:
            raise ValueError(
                f"version {args.version} must use the {expected_channel} channel"
            )
        profile = "versioned-thin"

    return profile, channel.upper()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--channel", required=True)
    parser.add_argument("--release-epoch", required=True)
    parser.add_argument("--release-notes-url", required=True)
    args = parser.parse_args()

    try:
        profile, channel_upper = resolve(args)
    except ValueError as exc:
        parser.error(str(exc))

    print(f"release_profile={profile}")
    print(f"release_channel_upper={channel_upper}")


if __name__ == "__main__":
    main()
