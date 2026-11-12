#!/usr/bin/env python3
"""交叉编译 Windows 主题覆盖补丁夹具；只构建，不运行 Windows 程序。

产物：.build/windows-theme/fixture/ThemeFixture.exe。把它复制到 Windows 上
直接运行即可：退出码 0 表示有效内置主题与 resolvedTheme 的行为符合预期，
非 0 时输出会列出失败项。夹具只构造内存里的设置对象，不读写用户设置、
不加载词典、不发送按键。
"""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / '.build/windows-theme')
    args = parser.parse_args()
    binary = args.out.resolve() / 'fixture' / 'ThemeFixture.exe'
    binary.parent.mkdir(parents=True, exist_ok=True)
    compiler = 'x86_64-w64-mingw32-g++'
    if not shutil.which(compiler):
        parser.error(f'缺少编译器 {compiler}')
    windows = ROOT / 'windows/GogakuWindows'
    subprocess.run([
        compiler, '-std=c++20', '-O2', '-static', '-DNOMINMAX', '-DUNICODE', '-D_UNICODE',
        '-DGOGAKU_CHANNEL="theme-fixture"', '-DGOGAKU_SETTINGS_CONTRACT_STATIC',
        str(ROOT / 'probes/windows-theme-fixture.cpp'),
        str(windows / 'platform.cpp'),
        str(windows / 'themes.cpp'),
        str(ROOT / 'shared/GogakuCore/settings_contract.cpp'),
        str(ROOT / 'shared/GogakuCore/theme_contract.cpp'),
        '-o', str(binary),
        '-ladvapi32', '-lbcrypt', '-lcrypt32', '-lshell32', '-lole32', '-luuid',
        '-lwindowscodecs', '-lgdi32', '-luser32', '-loleaut32',
    ], check=True)
    print(f'已构建主题夹具：{binary}；未运行 Windows 程序')


if __name__ == '__main__':
    main()
