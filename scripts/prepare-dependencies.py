#!/usr/bin/env python3
"""固定依赖的持久构建入口。构建工具来自本机，运行包不依赖 Homebrew。

依赖固定：libime／fcitx5／ECM／KenLM 的提交在 probes/prepare-libime-input.py
顶部常量中锁定；转换数据（sc.dict／zh_CN.lm）逐字节哈希校验；下载档案按
预期 sha256 校验。本机工具（git／cmake／ninja／clang）缺失时明确报错。
生产构建不依赖旧探针缓存、/tmp 遗留文件或隐式本机路径。
"""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sys

REPO = Path(__file__).resolve().parent.parent
CACHE = Path(os.environ.get('GOGAKU_DEPS', Path.home() / 'Library/Caches/Gogaku/libime-1.1.17'))


def require_tool(name: str) -> str:
    """本机工具缺失时明确报错（不静默降级、不依赖 /tmp 遗留物）。"""
    path = shutil.which(name)
    if path is None:
        raise SystemExit(f'缺少必需工具：{name}。请先安装（见 docs/native-development.md 构建要求）。')
    return path


for tool in ['git', 'cmake', 'ninja', 'clang']:
    require_tool(tool)

spec = importlib.util.spec_from_file_location('libime_builder', REPO / 'probes/prepare-libime-input.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
builder.ROOT = CACHE
CACHE.mkdir(parents=True, exist_ok=True)
# 已转换数据也必须逐字节匹配已冻结产物。
expected = {
    'sc.dict': '38b9ca9a350b68fb3c4dd1028ccb9a4f4fb9a14d01a6a71839aa074bdd34ef10',
    'zh_CN.lm': '3588b3942c8fd62e1a6bd3bae8c7cadc0faf928c175b245224ed475862218387',
}
for name, digest in expected.items():
    path = CACHE / 'data' / name
    if path.exists() and builder.digest(path) != digest:
        raise SystemExit(f'拒绝未匹配的资源：{path}')
builder.main()
for name, digest in expected.items():
    if builder.digest(CACHE / 'data' / name) != digest:
        raise SystemExit(f'转换结果不匹配：{name}')
lock = {
    'libime': builder.COMMIT, 'fcitx5': builder.FCITX, 'ecm': builder.ECM,
    'kenlm': builder.KENLM, 'archives': builder.ARCHIVES, 'artifacts': expected,
}
(CACHE / 'dependencies.lock.json').write_text(json.dumps(lock, indent=2) + '\n')
print(CACHE)
