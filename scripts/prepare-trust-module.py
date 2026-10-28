#!/usr/bin/env python3
"""Unwrap an IPSW trust-cache IM4P into the raw version-2 module.

`unixnu ipsw fetch StaticTrustCache Cryptex1,SystemTrustCache` extracts the
manifest members as `Firmware/*.dmg.trustcache`, which are IM4P containers.
UniXNU's bundle builder reads raw modules from
`.cache/firmware/target-volumes/`, so this step does the DER unwrap and checks
each module against the hash that builder pins.

  prepare-trust-module.py <member.trustcache> <output.bin> [expected-sha256]
"""
import hashlib
import struct
import sys
from pathlib import Path

EXPECTED = {
    'static': 'da88460e6e513438d5307e5c526f76497a74754476a24da29f239f0c90120fc2',
    'system': 'd121ba89167e03aafd00fa687c30cd8ebc4ccafd10c1408adb2ba3de12403651',
}


def der(data, at):
    if at + 2 > len(data):
        raise SystemExit('truncated DER')
    tag, size = data[at], data[at + 1]
    at += 2
    if size & 128:
        count = size & 127
        if not 0 < count <= 4 or at + count > len(data):
            raise SystemExit('invalid DER length')
        size = int.from_bytes(data[at:at + count], 'big')
        at += count
    if at + size > len(data):
        raise SystemExit('DER exceeds input')
    return tag, data[at:at + size], at + size


def main():
    if len(sys.argv) not in (3, 4):
        raise SystemExit(__doc__)
    source, target = Path(sys.argv[1]), Path(sys.argv[2])
    expected = sys.argv[3] if len(sys.argv) == 4 else None
    data = source.read_bytes()
    tag, sequence, end = der(data, 0)
    if tag != 0x30 or end != len(data):
        raise SystemExit('not a single DER sequence')
    fields, cursor = [], 0
    while cursor < len(sequence):
        kind, value, cursor = der(sequence, cursor)
        fields.append((kind, value))
    if not fields or fields[0][1] != b'IM4P':
        raise SystemExit('not an IM4P container')
    module = fields[-1][1]
    if struct.unpack_from('<I', module)[0] != 2:
        raise SystemExit('not a version-2 trust module')
    if len(module) != 24 + struct.unpack_from('<I', module, 20)[0] * 24:
        raise SystemExit('module length does not match its entry count')
    digest = hashlib.sha256(module).hexdigest()
    if expected and digest != expected:
        raise SystemExit(f'trust module changed: {digest} != {expected}')
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(module)
    print(f'{target}: {len(module)} bytes sha256={digest}')


if __name__ == '__main__':
    main()
