#!/usr/bin/env python3
"""Copy the device repository without the archives that need a candidate kernel.

  prepare-bootstrap-device.py <device dir> <bootstrap dir>

The first kernel pass exists only to produce the prelinked kernel that the
display and HID recipes use as their reference. Those recipes abort when no
candidate exists yet, so the bootstrap copy drops them (and the display switch,
whose stub LinkStubs.c provides) and leaves everything else identical.
"""
import shutil
import subprocess
import sys
from pathlib import Path

src, dst = Path(sys.argv[1]), Path(sys.argv[2])
if dst.exists():
    shutil.rmtree(dst)
shutil.copytree(src, dst, ignore=shutil.ignore_patterns('.git', 'drivers', 'uefi'))

board = dst / 'board.toml'
text = board.read_text()
for entry in ('build-munch-touch.py', 'component:ShengHidInput', 'build-gop-legacy-display.py'):
    line = f'  "{entry}",\n'
    if line not in text:
        raise SystemExit(f'{entry} is not in board.toml')
    text = text.replace(line, '')
for token in ('"GopFramebuffer", ', ', "ShengHidInput"'):
    if token not in text:
        raise SystemExit(f'components list does not contain {token}')
    text = text.replace(token, '')
board.write_text(text)

defconfig = dst / 'configs/munch_defconfig'
text = defconfig.read_text()
if 'CONFIG_XNU_NATIVE_LEGACY_DISPLAY=y' not in text:
    raise SystemExit('the defconfig does not enable the display switch')
text = text.replace('CONFIG_XNU_NATIVE_LEGACY_DISPLAY=y',
                    '# CONFIG_XNU_NATIVE_LEGACY_DISPLAY is not set')
defconfig.write_text(text)

# unixnu tree runs "git submodule update" inside the device directory, so the copy
# has to be a repository. It has no submodules: drivers/ and uefi/ are not copied.
(dst / '.gitmodules').unlink(missing_ok=True)
subprocess.run(['git', '-C', str(dst), 'init', '-q'], check=True)
subprocess.run(['git', '-C', str(dst), 'add', '-A'], check=True)
subprocess.run(['git', '-C', str(dst), '-c', 'user.name=bootstrap',
                '-c', 'user.email=bootstrap@local', 'commit', '-qm', 'bootstrap'], check=True)

print(f'bootstrap device: {dst}')
