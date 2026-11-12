#!/usr/bin/env python3
"""Compile modern macOS icon resources and an ICNS fallback with Xcode 26+."""
import argparse
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def build_icon(app: Path):
    app = app.resolve()
    resources = app / 'Contents' / 'Resources'
    resources.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='mic-keepalive-icon-') as tmp:
        bundle = Path(tmp) / 'AppIcon.icon'
        (bundle / 'Assets').mkdir(parents=True)
        shutil.copy2(ROOT / 'assets/icon.json', bundle / 'icon.json')
        subprocess.run(['sips', '-z', '1024', '1024', str(ROOT / 'assets/logo.png'),
                        '--out', str(bundle / 'Assets/Artwork.png')],
                       check=True, stdout=subprocess.DEVNULL)
        partial = Path(tmp) / 'partial.plist'
        subprocess.run(['xcrun', 'actool', str(bundle), '--compile', str(resources),
                        '--platform', 'macosx', '--minimum-deployment-target', '14.0',
                        '--app-icon', 'AppIcon', '--include-all-app-icons',
                        '--output-partial-info-plist', str(partial)],
                       check=True, stdout=subprocess.DEVNULL)
        info_path = app / 'Contents/Info.plist'
        info = plistlib.loads(info_path.read_bytes())
        info.update(plistlib.loads(partial.read_bytes()))
        info['CFBundleIconFile'] = 'AppIcon.icns'
        info_path.write_bytes(plistlib.dumps(info))
    assert info['CFBundleIconName'] == 'AppIcon'
    assert (resources / 'AppIcon.icns').read_bytes().startswith(b'icns')
    assert (resources / 'Assets.car').stat().st_size > 0
    print('Modern Assets.car, legacy ICNS, and both bundle references verified.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('app', type=Path)
    build_icon(parser.parse_args().app)
