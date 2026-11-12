#!/usr/bin/env python3
"""Build an ad-hoc signed universal macOS app and distributable DMG/ZIP."""
import hashlib
import plistlib
import shutil
import subprocess
from pathlib import Path
from build_icon import build_icon

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / '.build' / 'release'
DIST = ROOT / 'dist'
APP = BUILD / 'Mic KeepAlive.app'


def run(*args):
    subprocess.run([str(arg) for arg in args], cwd=ROOT, check=True)


def main():
    info = plistlib.loads((ROOT / 'Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    if BUILD.exists():
        shutil.rmtree(BUILD)
    BUILD.mkdir(parents=True)
    DIST.mkdir(exist_ok=True)
    macos = APP / 'Contents' / 'MacOS'
    resources = APP / 'Contents' / 'Resources'
    macos.mkdir(parents=True)
    shutil.copytree(ROOT / 'Resources', resources)
    slices = []
    for arch in ('arm64', 'x86_64'):
        binary = BUILD / f'MicKeepAlive-{arch}'
        run('xcrun', 'swiftc', '-target', f'{arch}-apple-macosx14.0',
            '-swift-version', '5', '-O', '-framework', 'AppKit',
            '-framework', 'AVFoundation', '-framework', 'ServiceManagement', '-framework', 'CoreAudio', ROOT / 'Localization.swift', ROOT / 'RecoveryPolicy.swift',
            ROOT / 'SystemAudio.swift', ROOT / 'main.swift', '-o', binary)
        slices.append(binary)
    binary = macos / 'MicKeepAlive'
    run('xcrun', 'lipo', '-create', *slices, '-output', binary)
    archs = subprocess.check_output(['xcrun', 'lipo', '-archs', str(binary)], text=True).split()
    if set(archs) != {'arm64', 'x86_64'}:
        raise RuntimeError(f'Unexpected binary architectures: {archs}')

    (APP / 'Contents' / 'Info.plist').write_bytes(plistlib.dumps(info))
    build_icon(APP)
    run('codesign', '--force', '--sign', '-', APP)
    run('codesign', '--verify', '--strict', '--verbose=2', APP)
    run(binary, '--localization-report', '-AppleLanguages', '(en)')
    run(binary, '--localization-report', '-AppleLanguages', '(zh-Hans)')
    run(binary, '--localization-report', '-AppleLanguages', '(zh-Hant)')

    stage = BUILD / 'volume'
    stage.mkdir()
    run('ditto', APP, stage / APP.name)
    (stage / 'Applications').symlink_to('/Applications')
    (stage / 'READ ME FIRST.txt').write_text(
        f'Mic KeepAlive {version} — macOS 14+ (Apple Silicon & Intel)\n\n'
        'Drag Mic KeepAlive.app to Applications, then open it.\n'
        'This release is locally signed, not Apple-notarized. If macOS blocks it, '
        'open System Settings > Privacy & Security > Open Anyway after trying to launch it. '
        'Only approve a download you trust.\n'
        'Allow microphone access, select your microphone, and start keep-alive from the menu bar.\n'
        'No Dock window is expected; look for the microphone icon in the menu bar.\n\n'
        '将 Mic KeepAlive.app 拖入 Applications 后打开。\n'
        '此版本为本地签名，未经 Apple 公证。如果首次启动被拦截，请在尝试打开后前往'
        '系统设置 → 隐私与安全 → 仍要打开，仅允许你信任的下载。\n'
        '允许麦克风权限，在菜单栏选择麦克风并开启保活。应用仅显示菜单栏图标。\n\n'
        'https://github.com/ababdotai/macos-mic-keepalive\n'
        'https://support.apple.com/en-us/102445\n', encoding='utf-8')
    dmg = DIST / 'Mic-KeepAlive-universal.dmg'
    zipfile = DIST / 'Mic-KeepAlive-universal.zip'
    for artifact in (dmg, zipfile):
        artifact.unlink(missing_ok=True)
    run('hdiutil', 'create', '-volname', 'Mic KeepAlive', '-srcfolder', stage,
        '-format', 'UDZO', '-fs', 'HFS+', '-ov', dmg)
    run('hdiutil', 'verify', dmg)
    run('ditto', '-c', '-k', '--sequesterRsrc', '--keepParent', APP, zipfile)
    (DIST / 'SHA256SUMS.txt').write_text(''.join(
        f'{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n'
        for path in (dmg, zipfile)))
    print(f'Release {version} ready in {DIST}')


if __name__ == '__main__':
    main()
