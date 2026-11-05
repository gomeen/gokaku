#!/usr/bin/env python3
"""组装 Gogaku 共享核心 Windows 自检包（gogaku-core-selfcheck.zip）。

内容：交叉编译产物（核心 DLL＋测试 exe）＋出厂数据（sc.dict／zh_CN.lm，
来自本机固定缓存，哈希记录在案）＋一键 run.bat（产出机器可读 JSON 报告，
不含任何原文文本）。供真实 Windows 硬件验证共享核心（KenLM／词库格式
兼容、ABI、DLL 加载），是 T2.1 验收证据来源之一；输入法本体（TSF 前端）
不在本包范围。

用法（Mac 开发机）：
  python3 scripts/package-win-selfcheck.py
产物：local/selfcheck/gogaku-core-selfcheck.zip ＋ assemble-log.txt
"""
import hashlib
import json
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
CORE_BIN = REPO / '.build/win-cross/core-build/bin'
DATA_SRC = Path.home() / 'Library/Caches/Gogaku/libime-1.1.17/data'
OUT_DIR = REPO / 'local/selfcheck'
STAGE = OUT_DIR / 'gogaku-core-selfcheck'

TEST_EXES = [
    'gogaku_core_abi_test.exe',
    'gogaku_core_translate_safety_test.exe',
    'gogaku_core_normal_test.exe',
    'gogaku_core_learning_test.exe',
    'gogaku_core_quality_test.exe',
    'gogaku_core_fuzz.exe',
]
DLLS = [
    'libgogaku_core.dll',
]
EXTRA_DLLS = {
    'libIMECore.dll': str(REPO / '.build/win-cross/libime-build/bin/libIMECore.dll'),
    'libIMEPinyin.dll': str(REPO / '.build/win-cross/libime-build/bin/libIMEPinyin.dll'),
    # MinGW 运行时（GCC 运行时例外许可允许随包分发）
    'libwinpthread-1.dll': '/usr/local/Cellar/mingw-w64/14.0.0_3/toolchain-x86_64/x86_64-w64-mingw32/bin/libwinpthread-1.dll',
    # Fcitx5Utils 为 SHARED；其依赖随包
    'libFcitx5Utils.dll': str(REPO / '.build/win-cross/fcitx5-build/bin/libFcitx5Utils.dll'),
    # MSYS2 垫片运行时（dlfcn/gettext/zstd 的 DLL 形态；许可随各自包：
    # dlfcn BSD-like、gettext LGPL＋运行时例外、zstd BSD，均可再分发）
    'libdl.dll': str(REPO / '.build/win-cross/msys-sysroot/clang64/bin/libdl.dll'),
    'libintl-8.dll': str(REPO / '.build/win-cross/msys-sysroot/clang64/bin/libintl-8.dll'),
    'libiconv-2.dll': str(REPO / '.build/win-cross/msys-sysroot/clang64/bin/libiconv-2.dll'),
    'libzstd.dll': str(REPO / '.build/win-cross/msys-sysroot/clang64/bin/libzstd.dll'),
}
DATA_FILES = ['sc.dict', 'zh_CN.lm']

RUN_BAT = r'''@echo off
setlocal EnableDelayedExpansion
cd /d "%~dp0"
set "GOGAKU_CORE_TEST_DATA=%~dp0data"
set "LOG=%~dp0selfcheck-report.txt"
set "JSON=%~dp0selfcheck-report.json"
> "%LOG%" echo Gogaku core self-check
>> "%LOG%" echo host=%COMPUTERNAME% user=%USERNAME% date=%DATE% %TIME%
for %%T in (gogaku_core_abi_test gogaku_core_translate_safety_test gogaku_core_normal_test gogaku_core_learning_test gogaku_core_quality_test gogaku_core_fuzz) do (
  >> "%LOG%" echo === %%T ===
  %%T.exe >> "%LOG%" 2>&1
  >> "%LOG%" echo exitcode=!errorlevel!
)
powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$lines = Get-Content '%LOG%'; $name=''; $out=@();" ^
  "foreach($l in $lines){" ^
  "  $l=$l.Trim();" ^
  "  if($l -match '^=== (.+) ===$'){$name=$Matches[1];}" ^
  "  elseif($l -match '^exitcode=(-?[0-9]+)$'){$out += [pscustomobject]@{test=$name;exitCode=[int]$Matches[1];passed=($Matches[1] -eq '0')}}" ^
  "}" ^
  "$allPass = @($out | Where-Object {-not $_.passed}).Count -eq 0;" ^
  "$json = [pscustomobject]@{kind='gogaku-core-selfcheck';version=1;host=$env:COMPUTERNAME;user=$env:USERNAME;date=(Get-Date -Format o);allPassed=$allPass;checks=$out} | ConvertTo-Json -Depth 4;" ^
  "[IO.File]::WriteAllText('%JSON%', $json, (New-Object System.Text.UTF8Encoding $false))"
echo.
if exist "%JSON%" (
  echo 完成！请把本目录下 selfcheck-report.json 和 selfcheck-report.txt 两个文件发回。
) else (
  echo 运行出现异常：请把本目录全部文件发回。
)
pause
'''

README = '''Gogaku 共享核心 Windows 自检包
==============================

用途：在一台真实 Windows 10/11 x64 机器上验证 Gogaku 共享核心（输入法
引擎库）能否正常加载和运行。这是开发诊断包，不是输入法本体——不会安装
任何输入法、不改动系统、不联网。

运行方法
--------
1. 解压本压缩包到任意目录
2. 双击 run.bat（可能需要稍等一两分钟）
3. 结束后把目录下生成的 selfcheck-report.json 和 selfcheck-report.txt
   两个文件发回即可

隐私说明
--------
- 测试使用包内自带的固定测试向量，不含任何个人输入内容
- 报告只有每项测试的通过/失败与机器名、用户名，无键盘记录、无上传
- 想先检查内容可以自行打开 run.bat 查看（纯文本批处理）

内容清单
--------
- libgogaku_core.dll 等核心与依赖库
- 6 个测试程序（ABI 合同、翻译加固、普通模式轨迹、学习模式轨迹、
  质量回归、随机序列冒烟）
- data/ 出厂数据（用于测试的词典与语言模型，来自固定数据源）
'''


def clear_immutable(path: Path) -> None:
    """缓存数据文件带 uchg（依赖管线防篡改）标志，copy2 会一并复制，
    导致重新打包时无法清理暂存目录。副本上清除，不动缓存本体。"""
    try:
        import stat as stat_module
        flags = path.stat().st_flags  # type: ignore[attr-defined]
        if flags & getattr(stat_module, 'UF_IMMUTABLE', 0):
            import os
            os.chflags(path, flags & ~getattr(stat_module, 'UF_IMMUTABLE', 0))
    except (AttributeError, OSError):
        pass


def digest(path: Path) -> str:
    with path.open('rb') as fh:
        return hashlib.file_digest(fh, 'sha256').hexdigest()


def main() -> int:
    if not CORE_BIN.exists():
        print('缺少交叉编译产物：先构建 .build/win-cross/core-build', file=sys.stderr)
        return 1
    missing = [n for n in TEST_EXES + DLLS if not (CORE_BIN / n).exists()]
    missing += [n for n, p in EXTRA_DLLS.items() if not Path(p).exists()]
    if missing:
        print('缺少产物：' + ', '.join(missing), file=sys.stderr)
        return 1
    if STAGE.exists():
        for f in STAGE.rglob('*'):
            clear_immutable(f)
        shutil.rmtree(STAGE)
    STAGE.mkdir(parents=True)

    manifest = {
        'kind': 'gogaku-core-selfcheck-manifest',
        'createdAt': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'commit': subprocess.run(['git', '-C', str(REPO), 'rev-parse', 'HEAD'],
                                 capture_output=True, text=True).stdout.strip(),
        'files': [],
    }
    for name in TEST_EXES + DLLS:
        shutil.copy2(CORE_BIN / name, STAGE / name)
    for name, src in EXTRA_DLLS.items():
        shutil.copy2(src, STAGE / name)
        clear_immutable(STAGE / name)
    data_dir = STAGE / 'data'
    data_dir.mkdir()
    for name in DATA_FILES:
        shutil.copy2(DATA_SRC / name, data_dir / name)
        clear_immutable(data_dir / name)
    (STAGE / 'run.bat').write_text(RUN_BAT, newline='\r\n')
    (STAGE / 'README.txt').write_text(README, encoding='utf-8')

    for f in sorted(STAGE.rglob('*')):
        if f.is_file():
            manifest['files'].append({'path': str(f.relative_to(STAGE)),
                                      'sha256': digest(f), 'bytes': f.stat().st_size})
    (STAGE / 'manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')

    zip_path = OUT_DIR / 'gogaku-core-selfcheck.zip'
    with zipfile.ZipFile(zip_path, 'w', zipfile.ZIP_DEFLATED) as zf:
        for f in sorted(STAGE.rglob('*')):
            if f.is_file():
                zf.write(f, Path('gogaku-core-selfcheck') / f.relative_to(STAGE))
    print(f'包完成：{zip_path}')
    print(f'  大小：{zip_path.stat().st_size / 1e6:.1f} MB，文件 {len(manifest["files"])} 个')
    for entry in manifest['files']:
        print(f"  {entry['sha256'][:12]}  {entry['path']}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
