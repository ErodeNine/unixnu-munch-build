#!/usr/bin/env python3
"""Create a VerifiedRoot policy for one original iPadOS volume.

The fork ships a producer for the OS volume (build-owner-os-policy.py) but only
consumers for the SystemOS volume, so build-verified-root-probe.py
--include-systemos could never run. This script covers both components with the
same code path: sign the whole virtual disk with the owner key, then verify the
RSA signature and every 4096-byte block against the manifest table.

Run on macOS from the UniXNU checkout, after `unixnu tree`:

  build-root-policy.py --component os --dmg out/ipsw/21H461/044-76040-038.dmg \
      --out out/<device>/<os>/<config>/tree/build/verified-root-os \
      --expected-sha256 3f99... --expected-blocks 1483785 \
      --expected-uuid 04769D26-2CA0-4825-B443-E2E5F88300F2 --mountpoint <os-mount>

  build-root-policy.py --component systemos --dmg .../044-76034-038.dmg \
      --out .../tree/build/verified-root-systemos \
      --expected-sha256 b490... --expected-blocks 806400

The key pair is generated once under <out>/../verified-root-host/keys and shared
by both components, which build-verified-root-probe.py requires.
"""
import argparse
import hashlib
import importlib.util
import json
import plistlib
import shutil
import stat
import subprocess
import sys
import uuid
from pathlib import Path

PAGE = 4096


def run(*args, **kwargs):
    return subprocess.run(args, check=True, capture_output=True, text=True, **kwargs).stdout


def hdiutil_info():
    return plistlib.loads(subprocess.check_output(['hdiutil', 'info', '-plist']))['images']


def find_attach(dmg):
    for image in hdiutil_info():
        if Path(image['image-path']).resolve() == dmg.resolve() and image.get('writeable') is False:
            return image
    return None


def attach(dmg):
    run('hdiutil', 'attach', '-nomount', '-readonly', '-noverify', '-noautofsck', str(dmg))
    image = find_attach(dmg)
    if not image:
        raise SystemExit(f'{dmg} did not attach read-only')
    return image


def whole_disk(image):
    entries = image['system-entities']
    whole = [e for e in entries if e.get('content-hint') == 'GUID_partition_scheme']
    if len(whole) != 1:
        raise SystemExit('require one whole virtual media mapping')
    return whole[0]['dev-entry'], entries


def volume_uuid_of(device):
    info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', device]))
    return info.get('VolumeUUID'), info


def ensure_keys(keys):
    keys.mkdir(parents=True, exist_ok=True)
    private, public = keys / 'owner.pem', keys / 'owner-public.pem'
    if not private.is_file():
        run('openssl', 'genrsa', '-out', str(private), '3072')
        private.chmod(0o600)
    if not public.is_file():
        run('openssl', 'rsa', '-in', str(private), '-pubout', '-out', str(public))
    return private, public


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--component', choices=('os', 'systemos'), required=True)
    parser.add_argument('--dmg', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--expected-sha256', required=True)
    parser.add_argument('--expected-blocks', type=int, required=True)
    parser.add_argument('--expected-uuid')
    parser.add_argument('--mountpoint', type=Path)
    parser.add_argument('--image-source', choices=('disk', 'file'), default='disk',
                        help='os signs the expanded whole disk; systemos signs the dmg file itself')
    args = parser.parse_args()

    dmg = args.dmg.resolve()
    if not dmg.is_file():
        raise SystemExit(f'{dmg} is not a file')
    digest = hashlib.sha256()
    with dmg.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    if digest.hexdigest() != args.expected_sha256:
        raise SystemExit(f'compressed image changed: {digest.hexdigest()}')

    attached_here = False
    image = find_attach(dmg)
    if image is None:
        image = attach(dmg)
        attached_here = True
    whole, entries = whole_disk(image)
    info = plistlib.loads(subprocess.check_output(['diskutil', 'info', '-plist', whole]))
    if info.get('BusProtocol') != 'Disk Image' or info.get('Writable') is not False:
        raise SystemExit('require an actual read-only Disk Image mapping')

    if args.mountpoint:
        uuid_text, _ = volume_uuid_of(str(args.mountpoint))
    else:
        partitions = [e['dev-entry'] for e in entries if e.get('content-hint') != 'GUID_partition_scheme']
        uuid_text = None
        for device in partitions:
            uuid_text, _ = volume_uuid_of(device)
            if uuid_text:
                break
    if not uuid_text:
        raise SystemExit('no APFS volume UUID on the attached image')
    volume_uuid = uuid.UUID(uuid_text)
    if args.expected_uuid and str(volume_uuid).upper() != args.expected_uuid.upper():
        raise SystemExit(f'volume UUID {volume_uuid} != {args.expected_uuid}')

    if args.image_source == 'file':
        # SystemOS: the UFS window carries the IPSW member itself, so the policy covers
        # the .dmg bytes, not the expanded APFS disk.
        source = dmg
        total = dmg.stat().st_size
        if attached_here:
            subprocess.run(['hdiutil', 'detach', whole, '-force'], capture_output=True)
            attached_here = False
    else:
        source = Path('/dev/r' + Path(whole).name)
        if not stat.S_ISCHR(source.stat().st_mode):
            raise SystemExit(f'{source} is not the raw character device')
        total = int(info['TotalSize'])
    if total // PAGE + (1 if total % PAGE else 0) != args.expected_blocks:
        raise SystemExit(f'block count {total // PAGE} does not match {args.expected_blocks}')

    spec = importlib.util.spec_from_file_location('verified_manifest',
                                                  Path.cwd() / 'kits/VerifiedRoot/tools/manifest.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    keys = args.out.parent / 'verified-root-host/keys'
    private, public = ensure_keys(keys)

    if args.out.exists():
        shutil.rmtree(args.out)
    args.out.mkdir(parents=True)
    with source.open('rb', buffering=1024 * 1024) as stream:
        record = module.make(stream, total, private, public, volume_uuid, 1, args.out)

    # Independent verification of the signed envelope and of every block.
    envelope = (args.out / 'manifest.bin').read_bytes()
    header = envelope[:160]
    runs = subprocess.run(['openssl', 'dgst', '-sha256', '-verify', str(public),
                           '-signature', str(args.out / 'signature.bin')], input=header,
                          capture_output=True)
    if runs.returncode != 0:
        raise SystemExit('manifest signature does not verify')

    table = (args.out / 'hashes.bin').read_bytes()
    if len(table) != record['block_count'] * 32:
        raise SystemExit('hash table length is not block_count * 32')
    image_hash = hashlib.sha256()
    indices = [0, 1, record['block_count'] // 2, record['block_count'] - 1]
    samples, lengths = [], []
    remaining = total
    with source.open('rb', buffering=1024 * 1024) as stream:
        index = 0
        while remaining:
            length = min(PAGE, remaining)
            block = stream.read(length)
            if len(block) != length:
                raise SystemExit(f'short read at block {index}')
            if hashlib.sha256(block).digest() != table[index * 32:(index + 1) * 32]:
                raise SystemExit(f'block {index} does not match the manifest table')
            image_hash.update(block)
            if index in indices:
                samples.append(block.ljust(PAGE, b'\0'))
                lengths.append(length)
            remaining -= length
            index += 1
        if stream.read(1):
            raise SystemExit('raw device is larger than the manifest image')
    if image_hash.hexdigest() != record['image_sha256']:
        raise SystemExit('image digest differs from the manifest')
    (args.out / 'original-samples.bin').write_bytes(b''.join(samples))

    report = dict(image_bytes=record['image_bytes'], blocks_verified=record['block_count'],
                  image_sha256=record['image_sha256'], volume_uuid=record['volume_uuid'],
                  generation=record['generation'], source_compressed_sha256=digest.hexdigest(),
                  source_format='UDIF', host_bus_protocol=info.get('BusProtocol'),
                  host_media_writable=False, trusted_key_sha256=record['trusted_key_sha256'],
                  actual_sample_indices=indices, actual_sample_lengths=lengths,
                  real_c_signature_and_block_verification=True,
                  signature_verification='openssl RSA3072 PKCS1v1.5 SHA-256',
                  block_verification='python sha256 over /dev/rdiskN',
                  original_image_modified=False, host_only=True, boot_root_authenticated=False,
                  qemu_tested=False, hardware_tested=False)
    (args.out / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    if attached_here:
        subprocess.run(['hdiutil', 'detach', whole, '-force'], capture_output=True)
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    sys.exit(main())
