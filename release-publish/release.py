#!/usr/bin/env python3
"""Small, pure helpers for release-publish/publish.sh. Standard library only.

  release.py tid <rfc3339>         the record key for a release published then
  release.py semver-check <v>      exit 0 when <v> is a SemVer 2.0.0 version
  release.py semver-cmp <a> <b>    print -1, 0 or 1 as <a> is lower, equal or higher

A TID (https://atproto.com/specs/tid) is a 64-bit integer, written as 13
characters of base32-sortable: the top bit is 0, the next 53 are microseconds
since the Unix epoch, and the low 10 are a clock id, always 0 here, so the same
timestamp always gives the same key.
"""

import calendar
import re
import sys

ALPHABET = "234567abcdefghijklmnopqrstuvwxyz"

RFC3339 = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})[Tt](\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?"
    r"([Zz]|[+-]\d{2}:\d{2})$"
)

# https://semver.org/#is-there-a-suggested-regular-expression-regex-to-check-a-semver-string
SEMVER = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?"
    r"(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$"
)


def microseconds(timestamp):
    m = RFC3339.match(timestamp)
    if not m:
        raise ValueError(f"{timestamp} is not an RFC 3339 timestamp")
    year, month, day, hour, minute, second = (int(g) for g in m.groups()[:6])
    if not (1 <= month <= 12 and 1 <= day <= calendar.monthrange(year, month)[1]
            and hour < 24 and minute < 60 and second < 60):
        raise ValueError(f"{timestamp} is not a valid date and time")
    seconds = calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))
    zone = m.group(8)
    if zone not in ("Z", "z"):
        sign = 1 if zone[0] == "+" else -1
        seconds -= sign * (int(zone[1:3]) * 3600 + int(zone[4:6]) * 60)
    # Whole microseconds; finer digits are dropped, never rounded up.
    fraction = int(((m.group(7) or "") + "000000")[:6])
    return seconds * 1_000_000 + fraction


def tid(timestamp, clock_id=0):
    us = microseconds(timestamp)
    if not 0 <= us < 2**53:
        raise ValueError(f"{timestamp} is outside the range a TID can hold")
    value = (us << 10) | clock_id
    chars = []
    for _ in range(13):
        chars.append(ALPHABET[value & 31])
        value >>= 5
    return "".join(reversed(chars))


def parse_semver(version):
    m = SEMVER.match(version)
    if not m:
        raise ValueError(f"{version} is not a SemVer version")
    core = tuple(int(g) for g in m.groups()[:3])
    pre = m.group(4).split(".") if m.group(4) else []
    return core, pre


def compare_identifiers(a, b):
    # Numeric identifiers compare numerically and sort before alphanumeric ones.
    a_num, b_num = a.isdigit(), b.isdigit()
    if a_num and b_num:
        return (int(a) > int(b)) - (int(a) < int(b))
    if a_num != b_num:
        return -1 if a_num else 1
    return (a > b) - (a < b)


def semver_cmp(a, b):
    (a_core, a_pre), (b_core, b_pre) = parse_semver(a), parse_semver(b)
    if a_core != b_core:
        return -1 if a_core < b_core else 1
    # A prerelease is lower than the release itself. Build metadata is ignored.
    if not a_pre or not b_pre:
        return (not a_pre) - (not b_pre)
    for x, y in zip(a_pre, b_pre):
        c = compare_identifiers(x, y)
        if c:
            return c
    return (len(a_pre) > len(b_pre)) - (len(a_pre) < len(b_pre))


def main(argv):
    try:
        if len(argv) == 2 and argv[0] == "tid":
            print(tid(argv[1]))
        elif len(argv) == 2 and argv[0] == "semver-check":
            parse_semver(argv[1])
        elif len(argv) == 3 and argv[0] == "semver-cmp":
            print(semver_cmp(argv[1], argv[2]))
        else:
            print(__doc__, file=sys.stderr)
            return 2
    except ValueError as error:
        print(error, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
