"""Prepare licensed, pinned translation resources in an isolated scratch directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path

os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")

MODELS = {
    "opus-en-zh": {"repo": "Helsinki-NLP/opus-mt-en-zh", "license": "apache-2.0"},
    "opus-zh-en": {"repo": "Helsinki-NLP/opus-mt-zh-en", "license": "cc-by-4.0"},
    "m2m100": {"repo": "facebook/m2m100_418M", "license": "mit"},
}
FILES = {
    "README.md", "config.json", "generation_config.json", "pytorch_model.bin",
    "model.safetensors", "source.spm", "target.spm", "vocab.json",
    "sentencepiece.bpe.model", "tokenizer_config.json", "special_tokens_map.json",
    "LICENSE", "LICENSE.txt", "NOTICE", "NOTICE.txt",
}


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(2 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(root, names):
    from huggingface_hub import HfApi, snapshot_download
    api = HfApi()
    manifests = []
    for name in names:
        model = MODELS[name]
        directory = root / name / "source"
        manifest_path = root / name / "manifest.json"
        previous = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
        info = api.model_info(model["repo"], revision=previous["revision"] if previous else "main", files_metadata=True)
        license_name = info.card_data.to_dict().get("license")
        if license_name != model["license"]:
            raise RuntimeError(f"License changed or unknown for {name}: {license_name}")
        available = {entry.rfilename: entry for entry in info.siblings}
        selected = sorted(FILES.intersection(available))
        if "model.safetensors" in selected:
            selected.remove("pytorch_model.bin")
        required = {"config.json", "vocab.json", "README.md"}
        required |= {"sentencepiece.bpe.model"} if name == "m2m100" else {"source.spm", "target.spm"}
        if not required.issubset(selected) or not ({"pytorch_model.bin", "model.safetensors"} & set(selected)):
            raise RuntimeError(f"Missing required files for {name}")
        print(f"Preparing {model['repo']} at {info.sha}, license={license_name}", flush=True)
        snapshot_download(model["repo"], revision=info.sha, local_dir=str(directory), allow_patterns=selected, max_workers=3)
        entries = []
        for file in selected:
            path = directory / file
            digest = sha256(path)
            metadata = available[file]
            lfs = metadata.lfs
            expected = lfs.sha256 if lfs else None
            if expected and expected != digest:
                raise RuntimeError(f"Hash mismatch for {path}")
            entries.append({"path": file, "bytes": path.stat().st_size, "sha256": digest, "lfs_sha256": expected})
        manifest = {"name": name, "repository": model["repo"], "revision": info.sha, "license": license_name, "files": entries}
        manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n")
        manifests.append(manifest)
        print(f"Verified {name}: {sum(entry['bytes'] for entry in entries)} bytes", flush=True)
    return manifests


def convert(root, names):
    os.environ["OMP_NUM_THREADS"] = "1"
    import ctranslate2
    import torch
    torch.set_num_threads(1)
    for name in names:
        source = root / name / "source"
        manifest = json.loads((root / name / "manifest.json").read_text())
        for precision in ["float32", "int8"]:
            destination = root / name / ("ct2-" + precision)
            metadata_path = root / name / ("ct2-" + precision + "-manifest.json")
            if metadata_path.exists():
                metadata = json.loads(metadata_path.read_text())
                if metadata["revision"] == manifest["revision"] and metadata["ctranslate2"] == ctranslate2.__version__ and all(sha256(destination / entry["path"]) == entry["sha256"] for entry in metadata["files"]):
                    print(f"Verified existing conversion: {name}/{precision}", flush=True)
                    continue
                raise RuntimeError(f"Existing conversion does not match {destination}")
            if destination.exists():
                raise RuntimeError(f"Incomplete conversion directory exists: {destination}; inspect it before retrying")
            print(f"Converting {name} to CTranslate2 {precision}", flush=True)
            converter = ctranslate2.converters.TransformersConverter(str(source), load_as_float16=False)
            converter.convert(str(destination), quantization=precision)
            entries = [{"path": str(path.relative_to(destination)), "bytes": path.stat().st_size, "sha256": sha256(path)} for path in sorted(destination.rglob("*")) if path.is_file()]
            metadata = {"name": name, "revision": manifest["revision"], "license": manifest["license"], "ctranslate2": ctranslate2.__version__, "torch": torch.__version__, "precision": precision, "files": entries}
            metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n")
            print(f"Converted {name}/{precision}: {sum(entry['bytes'] for entry in entries)} bytes", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path("/tmp/gogaku-benchmark/models"))
    parser.add_argument("--models", nargs="+", choices=list(MODELS), default=list(MODELS))
    parser.add_argument("--phase", choices=["download", "convert"], required=True)
    args = parser.parse_args()
    if args.phase == "download":
        download(args.root, args.models)
    else:
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["TRANSFORMERS_OFFLINE"] = "1"
        convert(args.root, args.models)
