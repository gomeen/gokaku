#!/usr/bin/env python3
"""构建双架构 TSF 组合与 Shift 回归；只用合成 COM，不连接代理或读取宿主。

复制输出目录到 Windows 并运行 x64/CompositionLifecycleTest.exe、
x86/CompositionLifecycleTest.exe。各自的 result.json 和退出码给出结论。
"""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import argparse
import subprocess

ROOT = Path(__file__).resolve().parent.parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, default=ROOT / '.build/windows-composition-lifecycle')
    parser.add_argument('--jobs', type=int, default=3)
    args = parser.parse_args()
    for arch, prefix in [('x64', 'x86_64'), ('x86', 'i686')]:
        compiler = f'{prefix}-w64-mingw32-g++'
        folder = args.out.resolve() / arch
        folder.mkdir(parents=True, exist_ok=True)
        sources = [ROOT / 'probes/windows-composition-lifecycle.cpp',
                   ROOT / 'windows/GogakuTsf/src/text_service.cpp',
                   ROOT / 'windows/GogakuWindows/platform.cpp',
                   ROOT / 'shared/GogakuCore/settings_contract.cpp']
        flags = ['-std=c++20', '-O2', '-DNOMINMAX', '-DUNICODE', '-D_UNICODE',
                 '-D_WIN32_WINNT=0x0A00', '-DGOGAKU_CHANNEL="composition-lifecycle-test"',
                 '-DGOGAKU_SETTINGS_CONTRACT_STATIC']

        def compile_one(source):
            target = folder / (source.stem + '.o')
            mock = ['-include', ROOT / 'probes/windows-composition-lifecycle-win32.h'] if source.stem == 'text_service' else []
            subprocess.run([compiler, *flags, *mock, '-c', source, '-o', target], check=True)
            return target

        with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
            objects = list(pool.map(compile_one, sources))
        libraries = ['user32', 'ole32', 'oleaut32', 'uuid', 'advapi32',
                     'shell32', 'bcrypt', 'crypt32']
        subprocess.run([compiler, '-static', '-o', folder / 'CompositionLifecycleTest.exe',
                        *objects, *['-l' + name for name in libraries]], check=True)
    print(f'双架构组合回归已构建：{args.out.resolve()}；未运行 Windows 程序')


if __name__ == '__main__':
    main()
