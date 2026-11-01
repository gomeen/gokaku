"""G0 Mac 模型门槛准备：固定 revision 下载 small100 并建立隔离转换／推理环境。

转换环境含 PyTorch，推理环境不含 PyTorch（见 probes/results/translation-benchmark 的 OpenMP 教训）。
产物记录哈希；本脚本只做下载与环境，不做质量结论。

注意：两步需不同解释器——
  1. 建 venv：系统 python3 运行（不带 --skip-venv）。
  2. 下载：用 venv-ct2/bin/python 运行（--skip-venv），因为 huggingface_hub 装在 venv 内。
大文件建议改用并行 range curl＋LFS sha256 校验（本机 python 单连接仅约 0.5MB/s）。
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

REVISION = "8ab680e26a596d2e3d2d2d17ae0f68df1037328c"
REPO = "alirezamsh/small100"
FILES = [
    "README.md",
    "config.json",
    "model.safetensors",
    "sentencepiece.bpe.model",
    "special_tokens_map.json",
    "tokenization_small100.py",
    "tokenizer_config.json",
    "vocab.json",
]

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(2 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(root: Path) -> dict:
    from huggingface_hub import hf_hub_download

    directory = root / "source"
    directory.mkdir(parents=True, exist_ok=True)
    entries = []
    for name in FILES:
        path = hf_hub_download(REPO, filename=name, revision=REVISION, local_dir=str(directory))
        path = Path(path)
        entries.append({"path": name, "bytes": path.stat().st_size, "sha256": sha256(path)})
        print(f"downloaded {name} {path.stat().st_size} bytes", flush=True)
    manifest = {
        "repository": REPO,
        "revision": REVISION,
        "license": "stated-in-readme",
        "files": entries,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    return manifest


def venv(python: str, path: Path, requirements: Path) -> None:
    if not (path / "bin" / "python").exists():
        subprocess.run([python, "-m", "venv", str(path)], check=True)
    subprocess.run([str(path / "bin" / "python"), "-m", "pip", "install", "--quiet",
                    "--disable-pip-version-check", "-r", str(requirements)], check=True)
    print(f"venv ready: {path}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Caches/Gogaku/models/small100-gate")
    parser.add_argument("--system-python", default="/usr/bin/python3")
    parser.add_argument("--skip-venv", action="store_true")
    args = parser.parse_args()
    args.root.mkdir(parents=True, exist_ok=True)
    results = probes = Path(__file__).resolve().parent.parent / "probes" / "results" / "translation-benchmark"
    if not args.skip_venv:
        venv(args.system_python, args.root / "venv-convert", results / "venv-requirements.txt")
        venv(args.system_python, args.root / "venv-ct2", results / "venv-ct2-requirements.txt")
    manifest = download(args.root)
    print(json.dumps({"root": str(args.root), "revision": REVISION,
                      "total_bytes": sum(e["bytes"] for e in manifest["files"])}, flush=True))
