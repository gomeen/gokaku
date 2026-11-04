#!/usr/bin/env python3
"""装配学习模式 small100 翻译后端（2026-11-03 用户裁决：仅换模型的质量试验）。

产物（~/Library/Application Support/Gogaku/translation/small100/）：
  venv/            运行时环境（ctranslate2＋transformers，不含 PyTorch）
  source/          固定 revision 的 HF 模型文件（alirezamsh/small100 @ 8ab680e2，MIT）
  ct2-int8/        一次性转换的 CT2 INT8 权重（venv-convert 环境转换）
  venv-convert/    转换环境（含 PyTorch，仅构建期；两环境分离见 OpenMP 教训）
  small100_worker.py  与 quickmt_worker.py 同协议的辅助进程
  manifest.json    仓库／revision／许可证／文件 sha256 清单

与 prepare-learning-translation.py 同为一次性装配；输入法按
settings.json 的 "learningTranslationBackend": "small100" 选择本后端。
大文件（model.safetensors）用并行 range curl 下载（本机 python 单连接过慢）；
下载后记录 sha256，无远端校验和，清单仅作完整性留档。
"""
import argparse
import hashlib
import os
import json
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from urllib.request import Request, urlopen

REVISION = "8ab680e26a596d2e3d2d2d17ae0f68df1037328c"
REPO = "alirezamsh/small100"
BASE_URL = f"https://huggingface.co/{REPO}/resolve/{REVISION}"
# 固定 revision 文件清单（与 scripts/prepare-small100-gate.py 一致）。
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
REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = Path.home() / "Library/Application Support/Gogaku/translation/small100"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(2 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download_file(name: str, destination: Path, workers: int) -> None:
    url = f"{BASE_URL}/{name}"
    request = Request(url, method="HEAD")
    with urlopen(request, timeout=60) as response:
        total = int(response.headers.get("Content-Length") or 0)
    if total <= 32 * 1024 * 1024 or workers <= 1:
        subprocess.run(["curl", "-fSL", "--retry", "3", "-o", str(destination), url], check=True)
        return
    # 并行 range 下载：分段并发拉取后拼接（分段字节数校验失败重试一次）。
    bounds = [total * index // workers for index in range(workers + 1)]
    parts: list[Path | None] = [None] * workers

    def fetch_range(index: int) -> None:
        start, end = bounds[index], bounds[index + 1] - 1
        part = destination.with_suffix(f".part{index}")
        for _ in range(2):
            subprocess.run(["curl", "-fsSL", "--retry", "3",
                            "-r", f"{start}-{end}", "-o", str(part), url], check=True)
            if part.stat().st_size == end - start + 1:
                parts[index] = part
                return
        raise RuntimeError(f"range download failed: {name} #{index}")

    with ThreadPoolExecutor(max_workers=workers) as pool:
        list(pool.map(fetch_range, range(workers)))
    with destination.open("wb") as out:
        for part in parts:
            with part.open("rb") as stream:
                while True:
                    block = stream.read(4 * 1024 * 1024)
                    if not block:
                        break
                    out.write(block)
            part.unlink()


def venv(python: str, path: Path, requirements: Path) -> None:
    if not (path / "bin" / "python").exists():
        subprocess.run([python, "-m", "venv", str(path)], check=True)
    subprocess.run([str(path / "bin" / "python"), "-m", "pip", "install", "--quiet",
                    "--disable-pip-version-check", "-r", str(requirements)], check=True)
    print(f"venv ready: {path}", flush=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="装配目录")
    parser.add_argument("--python", default="/usr/bin/python3", help="建 venv 的基解释器")
    parser.add_argument("--skip-venv", action="store_true", help="跳过两个 venv 重建")
    parser.add_argument("--skip-download", action="store_true", help="跳过权重下载（已就位）")
    parser.add_argument("--skip-convert", action="store_true", help="跳过 CT2 转换（已就位）")
    parser.add_argument("--worker-only", action="store_true", help="只更新 worker 脚本")
    parser.add_argument("--download-workers", type=int, default=8, help="大文件并行分段数")
    args = parser.parse_args()
    root = args.root
    root.mkdir(parents=True, exist_ok=True)
    started = time.perf_counter()

    if args.worker_only:
        subprocess.run(["cp", str(REPO_ROOT / "scripts" / "small100_worker.py"),
                        str(root / "small100_worker.py")], check=True)
        print("worker updated", flush=True)
        return

    runtime_requirements = REPO_ROOT / "scripts" / "requirements" / "learning-small100-runtime.txt"
    convert_requirements = REPO_ROOT / "scripts" / "requirements" / "learning-small100-convert.txt"
    if not args.skip_venv:
        venv(args.python, root / "venv", runtime_requirements)
        venv(args.python, root / "venv-convert", convert_requirements)

    entries = []
    if not args.skip_download:
        source = root / "source"
        source.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            destination = source / name
            if not destination.exists():
                print(f"downloading {name}", flush=True)
                download_file(name, destination, args.download_workers)
            entries.append({"path": name, "bytes": destination.stat().st_size,
                            "sha256": sha256(destination)})
            print(f"ready {name} {destination.stat().st_size} bytes", flush=True)

    if not args.skip_convert:
        model_dir = root / "ct2-int8"
        # ctranslate2 4.6 转换器参数：--model/--output_dir（旧名 --model_path/--ct2_model 已废弃）。
        # 单线程转换：Intel Mac 上 Torch＋CT2 同环境多线程会撞重复 OpenMP runtime
        # （SIGSEGV，见 probes/results/translation-benchmark/conversion-diagnostic.json
        # 与 pi 记忆 isolate-macos-translation-runtimes；threads=1 实测成功）。
        env = dict(os.environ, OMP_NUM_THREADS="1", MKL_NUM_THREADS="1",
                   KMP_BLOCKTIME="0", OMP_WAIT_POLICY="PASSIVE")
        subprocess.run([str(root / "venv-convert" / "bin" / "ct2-transformers-converter"),
                        "--model", str(root / "source"),
                        "--output_dir", str(model_dir),
                        "--quantization", "int8", "--force"],
                       check=True, env=env)
        print(f"converted: {model_dir}", flush=True)

    subprocess.run(["cp", str(REPO_ROOT / "scripts" / "small100_worker.py"),
                    str(root / "small100_worker.py")], check=True)
    manifest = {
        "repository": REPO,
        "revision": REVISION,
        "license": "MIT (model card); tokenization_small100.py Apache-2.0",
        "backend": "small100（学习翻译质量试验，2026-11-03 用户裁决）",
        "files": entries,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({"root": str(root), "seconds": round(time.perf_counter() - started, 1),
                      "revision": REVISION}, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
