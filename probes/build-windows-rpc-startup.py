#!/usr/bin/env python3
"""交叉编译 Windows RPC 冷启动回归夹具；只构建，不运行 Windows 程序。

将输出目录复制到 Windows，依次运行 fixture/bin/x64/RpcStartupTest.exe、
fixture/bin/x86/RpcStartupTest.exe；退出码与输出目录 result.json 给出结论。
使用独立 rpc-startup-test 管道，不读产品设置、不发送按键。
"""
from pathlib import Path
import argparse
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / '.build/windows-rpc-startup')
    args = parser.parse_args()
    fixture = args.out.resolve() / 'fixture'
    for arch, prefix in [('x64', 'x86_64'), ('x86', 'i686')]:
        compiler = f'{prefix}-w64-mingw32-g++'
        if not shutil.which(compiler):
            parser.error(f'缺少编译器 {compiler}')
        binary = fixture / 'bin' / arch / 'RpcStartupTest.exe'
        binary.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run([
            compiler, '-std=c++20', '-O2', '-static', '-municode', '-mwindows',
            '-DNOMINMAX', '-DUNICODE', '-D_UNICODE',
            '-DGOGAKU_CHANNEL="rpc-startup-test"', '-DGOGAKU_SETTINGS_CONTRACT_STATIC',
            str(ROOT / 'probes/windows-rpc-startup.cpp'),
            str(ROOT / 'windows/GogakuWindows/platform.cpp'),
            str(ROOT / 'shared/GogakuCore/settings_contract.cpp'),
            '-o', str(binary), '-ladvapi32', '-lbcrypt', '-lcrypt32',
            '-lshell32', '-lole32', '-luuid'], check=True)
        if arch == 'x64':
            shutil.copyfile(binary, binary.with_name('GogakuAgent.exe'))
    print(f'已构建双架构夹具：{args.out.resolve()}；未运行 Windows 程序')


if __name__ == '__main__':
    main()
