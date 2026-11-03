#!/usr/bin/env python3
"""Fetch pinned official Q4 translation artifacts into an external cache."""
import concurrent.futures
import datetime
import hashlib
import json
import subprocess
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path.home() / "Library/Caches/Gogaku/models/gguf-translation"
MODELS = [
    ("index-2b", "IndexTeam/Index-Translate-2B-GGUF", "3a0eca6ce931d88d00614d427ab3ed8ff0743902", "Index-Translate-2B.Q4_K_M.gguf", 1312164352, "044b313d29342bd3b2c77cbb64023ca0d209bd9b3247763f9d162767ef2d746a"),
    ("qwen-05b", "Qwen/Qwen2.5-0.5B-Instruct-GGUF", "9217f5db79a29953eb74d5343926648285ec7e67", "qwen2.5-0.5b-instruct-q4_k_m.gguf", 491400032, "74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"),
    ("qwen3-06b", "Qwen/Qwen3-0.6B-GGUF", "23749fefcc72300e3a2ad315e1317431b06b590a", "Qwen3-0.6B-Q8_0.gguf", 639446688, "9465e63a22add5354d9bb4b99e90117043c7124007664907259bd16d043bb031"),
    ("hy-18b", "tencent/HY-MT1.5-1.8B-GGUF", "265b2e615a7dc9b06c435dc878829ad99a512ba2", "HY-MT1.5-1.8B-Q4_K_M.gguf", 1133080512, "4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7"),
]


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def fetch(url, destination, expected_size=None, expected_hash=None):
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.exists() and (expected_size is None or destination.stat().st_size == expected_size):
        if expected_hash is None or sha256(destination) == expected_hash:
            return
    partial = destination.with_suffix(destination.suffix + ".partial")
    subprocess.run(["curl", "--fail", "--location", "--retry", "2", "--connect-timeout", "20",
                    "--max-time", "1800", "--continue-at", "-", "--output", str(partial), url], check=True)
    if expected_size is not None and partial.stat().st_size != expected_size:
        raise RuntimeError("Size mismatch: " + str(partial))
    if expected_hash and sha256(partial) != expected_hash:
        raise RuntimeError("SHA256 mismatch: " + str(partial))
    partial.replace(destination)


def prepare_model(model):
    key, repo, revision, filename, size, digest = model
    directory = CACHE / key
    base = "https://huggingface.co/" + repo + "/resolve/" + revision + "/"
    fetch(base + "README.md", directory / "README.md")
    if key == "hy-18b":
        fetch(base + "License.txt", directory / "License.txt")
    fetch(base + filename, directory / filename, size, digest)
    print("Verified " + key, flush=True)
    return {"id": key, "repository": repo, "revision": revision, "file": filename,
            "path": str(directory / filename), "sizeBytes": size, "sha256": digest}


def main():
    CACHE.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen("https://api.github.com/repos/ggml-org/llama.cpp/releases/tags/b12064", timeout=30) as response:
        release = json.load(response)
    asset = next(a for a in release["assets"] if a["name"] == "llama-b12064-bin-macos-x64.tar.gz")
    digest = asset.get("digest", "").removeprefix("sha256:")
    if len(digest) != 64:
        raise RuntimeError("Release asset lacks official SHA256")
    archive = CACHE / asset["name"]
    fetch(asset["browser_download_url"], archive, asset["size"], digest)
    runtime = CACHE / "runtime-b12064"
    runtime.mkdir(exist_ok=True)
    subprocess.run(["tar", "-xzf", str(archive), "-C", str(runtime)], check=True)
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        models = list(pool.map(prepare_model, MODELS))
    manifest = {"preparedAt": datetime.datetime.now(datetime.timezone.utc).isoformat(),
                "runtime": {"tag": "b12064", "url": asset["browser_download_url"],
                            "sha256": digest, "directory": str(runtime)}, "models": models}
    output = ROOT / "probes/results/gguf-translation"
    output.mkdir(parents=True, exist_ok=True)
    (output / "artifacts.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
    print("Ready: " + str(output / "artifacts.json"), flush=True)


if __name__ == "__main__":
    main()
