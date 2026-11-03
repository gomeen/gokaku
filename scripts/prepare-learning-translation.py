#!/usr/bin/env python3
"""准备学习模式 quickmt 开发版翻译后端（2026-11 裁决，仅本机开发版自用）。

装配目录：~/Library/Application Support/Gogaku/translation/
  venv/                  /usr/bin/python3 建的无 PyTorch venv（pinned ctranslate2＋sentencepiece）
  quickmt-en-zh/         pinned 原生 CT2 INT8 权重（en→中）
  quickmt-zh-en/         pinned 原生 CT2 INT8 权重（中→en）
  quickmt_worker.py      辅助进程（源码：scripts/quickmt_worker.py，随装配复制）
  manifest.json          revision／SHA256／许可证／依赖版本记录

权重来源：本机探针缓存（~/Library/Caches/Gogaku/models/quickmt-speed，由
probes 统一实测下载），文件级 SHA256 必须与 pins 完全一致才装配——任何字节
被篡改都拒绝并退出非 0。revision／SHA256 沿用 probes/results/translation-backends/
models.json 既有记录。venv 权重与两向权重合计约 1GB，不进 app bundle。

幂等：重复运行时已就绪的步骤自动跳过（venv 版本核对、权重 SHA256 核对）。
本脚本只做本机装配与校验，不做网络下载；缺缓存时提示先按 probes/README.md
补齐模型缓存。离线环境装配完成后 worker 正常推理（无网络访问）。
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_INSTALL = Path.home() / "Library/Application Support/Gogaku/translation"
DEFAULT_CACHE = Path.home() / "Library/Caches/Gogaku/models/quickmt-speed"
DEFAULT_PYTHON = "/usr/bin/python3"
WORKER_SOURCE = ROOT / "scripts" / "quickmt_worker.py"

PINNED_CTRANSLATE2 = "4.6.0"
PINNED_SENTENCEPIECE = "0.2.0"

# pins 与文件清单/SHA256 来自 probes/results/translation-backends/models.json
# （runId 20261103T012307Z）。许可证：模型 CC-BY-4.0；quickmt 工具链 Apache-2.0。
PINNED_MODELS = {
    "quickmt-en-zh": {
        "repository": "quickmt/quickmt-en-zh",
        "revision": "f48b69e53866b717607b59f94350e9aae3ed021c",
        "license": "CC-BY-4.0 (model); quickmt tooling Apache-2.0",
        "files": {
            "README.md": (3864, "67d76ab2546bfbd92b59816725786ae4fb905c8d3dc2ba0acdf9aaaf987bb9d5"),
            "config.json": (223, "66edc5d58ceb812a41b4b784497001f815c35400884f40984b19de29e1bc3d69"),
            "model.bin": (409972810, "433e7c41b63223f2d4600c740ce2a00a1bbe6dba1190a5fc10e8cc245e2ef387"),
            "source_vocabulary.json": (542122, "3c0b368639ef67a374f38e572fe5a0cb001fc0ec99f16787065258be59179a10"),
            "src.spm.model": (800955, "c373f1d78753313b0dbc337058bf8450e1fdd6fe662a49e0941affce44ec14c5"),
            "target_vocabulary.json": (590619, "a3ef04026e4342b7ccc88dececdcdddbca0835b087ac2e7a9a54b08c01ff6d9f"),
            "tgt.spm.model": (733978, "23d03d562fc3f8fe57e497dac0ece4827c254675a80c103fc4bb4040638ceb67"),
        },
    },
    "quickmt-zh-en": {
        "repository": "quickmt/quickmt-zh-en",
        "revision": "c27cc8024e01a047733a1e34796e2ab19d74b237",
        "license": "CC-BY-4.0 (model); quickmt tooling Apache-2.0",
        "files": {
            "README.md": (5321, "39f59cf36cffa070245974275247a036efdf432cfd0a21a656dba88c53c392cc"),
            "config.json": (223, "66edc5d58ceb812a41b4b784497001f815c35400884f40984b19de29e1bc3d69"),
            "model.bin": (407101843, "e7cac9c2bc585e476d8fe47af11ed76723d4b5cf69ccef8f5ff821fb3ec05000"),
            "source_vocabulary.json": (554957, "f535f57bbdb306027e9ebbe8d8a41a9f9d3b9465279c903b42de7e50186ad522"),
            "src.spm.model": (720056, "56159dc3a8607805f0e3f2cf4c91f37ee221e91fb824ebb362622d22185872cb"),
            "target_vocabulary.json": (532214, "578cfc6b44f8e22a8556a19487adbc5b3935ecfaad310bc2dd79ad2b93c5b9f3"),
            "tgt.spm.model": (792100, "c23dc1aa66b7b98263da867137a7eb41d5e4573984fb100c0b295f3010381823"),
        },
    },
}


def fail(message):
    print(f"错误：{message}", file=sys.stderr, flush=True)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def venv_python(root: Path) -> Path:
    return root / "venv" / "bin" / "python"


def pinned_versions_ok(python: Path) -> bool:
    probe = (
        "import importlib.metadata as m, sys\n"
        "try:\n"
        f"    assert m.version('ctranslate2') == '{PINNED_CTRANSLATE2}', 'ctranslate2'\n"
        f"    assert m.version('sentencepiece') == '{PINNED_SENTENCEPIECE}', 'sentencepiece'\n"
        "except Exception:\n"
        "    sys.exit(1)\n"
    )
    return subprocess.run([str(python), "-c", probe], capture_output=True).returncode == 0


def step_venv(root: Path, python_executable: str, skip: bool) -> None:
    python = venv_python(root)
    if skip and python.exists() and pinned_versions_ok(python):
        print(f"venv 已就绪（ctranslate2=={PINNED_CTRANSLATE2}, "
              f"sentencepiece=={PINNED_SENTENCEPIECE}）：{python}", flush=True)
        return
    if not python.exists():
        print(f"创建 venv（{python_executable}）：{root / 'venv'}", flush=True)
        root.mkdir(parents=True, exist_ok=True)
        # 固定用系统 python（探针同源；ctranslate2==4.6.0 仅为其提供 wheel；
        # Homebrew 等新版本 Python 无对应 pinned wheel）。
        subprocess.run([python_executable, "-m", "venv", str(root / "venv")], check=True)
    print(f"安装 pinned 依赖（ctranslate2=={PINNED_CTRANSLATE2}，"
          f"sentencepiece=={PINNED_SENTENCEPIECE}；不安装 PyTorch）", flush=True)
    subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check",
                    f"ctranslate2=={PINNED_CTRANSLATE2}",
                    f"sentencepiece=={PINNED_SENTENCEPIECE}"], check=True)
    if not pinned_versions_ok(python):
        fail("venv 依赖版本与 pinned 值不一致")
    print("venv 依赖版本核对通过", flush=True)


def step_models(root: Path, cache: Path) -> list:
    """核对缓存权重 SHA256 后装配；任何不符直接失败，不装配被篡改的字节。"""
    assembled = []
    for name, pin in PINNED_MODELS.items():
        source_dir = cache / name
        target_dir = root / name
        for file_name, (size, digest) in pin["files"].items():
            source = source_dir / file_name
            if not source.is_file():
                fail(f"缓存缺失 {source}；先按 probes/README.md 补齐 quickmt 模型缓存")
            actual = sha256(source)
            if actual != digest:
                fail(f"{source} SHA256 不符（期望 {digest[:12]}…，实际 {actual[:12]}…）；"
                     "拒绝装配被篡改的权重")
            target_dir.mkdir(parents=True, exist_ok=True)
            target = target_dir / file_name
            if not target.exists() or sha256(target) != digest:
                shutil.copy2(source, target)
                if sha256(target) != digest:
                    fail(f"{target} 装配后校验失败")
        assembled.append({
            "name": name,
            "repository": pin["repository"],
            "revision": pin["revision"],
            "license": pin["license"],
            "files": {f: {"bytes": s, "sha256": d} for f, (s, d) in pin["files"].items()},
        })
        print(f"权重装配完成：{target_dir}（{pin['repository']}@{pin['revision'][:12]}）", flush=True)
    return assembled


def step_worker(root: Path) -> str:
    if not WORKER_SOURCE.is_file():
        fail(f"worker 源码缺失：{WORKER_SOURCE}")
    target = root / "quickmt_worker.py"
    shutil.copy2(WORKER_SOURCE, target)
    print(f"worker 已装配：{target}", flush=True)
    return sha256(target)


def step_manifest(root: Path, assembled: list, worker_sha: str) -> None:
    python = venv_python(root)
    versions_probe = (
        "import importlib.metadata as m, json\n"
        "print(json.dumps({'ctranslate2': m.version('ctranslate2'), "
        "'sentencepiece': m.version('sentencepiece')}))\n"
    )
    versions = json.loads(subprocess.run([str(python), "-c", versions_probe],
                                         capture_output=True, text=True, check=True).stdout)
    manifest = {
        "schemaVersion": 1,
        "preparedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "purpose": "学习模式 quickmt 开发版翻译后端（docs/learning-quickmt-dev-decision.md）",
        "qualityGate": "未过正式质量门槛，仅本机开发版体验；双端交付口径不变",
        "models": assembled,
        "worker": {"source": "scripts/quickmt_worker.py", "sha256": worker_sha},
        "inference": {"computeType": "int8", "threads": 2, "maxDecodingLength": 256,
                      "beam": "来自设置（1–10，默认 1）"},
        "versions": versions,
    }
    target = root / "manifest.json"
    target.write_text(json.dumps(manifest, ensure_ascii=False, indent=1) + "\n")
    print(f"manifest 已写入：{target}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_INSTALL, help="装配目录")
    parser.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="探针权重缓存目录")
    parser.add_argument("--python", default=DEFAULT_PYTHON,
                        help="建 venv 用的系统 python（默认 /usr/bin/python3）")
    parser.add_argument("--skip-venv", action="store_true",
                        help="venv 已就绪时跳过创建与安装（仍做版本核对）")
    args = parser.parse_args()
    # 先核权重（快失败：被篡改／缺失的字节在装 venv 之前就拒绝），
    # 再装 venv、worker，最后写 manifest（记录 venv 版本）。
    assembled = step_models(args.root, args.cache)
    step_venv(args.root, args.python, args.skip_venv)
    worker_sha = step_worker(args.root)
    step_manifest(args.root, assembled, worker_sha)
    print(f"学习翻译后端就绪：{args.root}", flush=True)


if __name__ == "__main__":
    main()
