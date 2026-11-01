#!/usr/bin/env python3
"""生成普通模式英文候选词表（english-words.txt）。

数据组合（许可与义务见 docs/research-gloss-data.md 与 docs/third-party.md）：
- SCOWL／ESDB en_US size≤60 词表（集体作品 MIT-like；逐来源声明随包附 README_en.txt）。
- wordfreq 英文词频排序（代码 Apache-2.0；数据 CC BY-SA 4.0，须署名 Robyn Speer
  及 SUBTLEX 作者；衍生词表本身也须按 CC BY-SA 4.0 提供并附署名）。

产物：english-words.txt（每行一词，按词频降序）+ english-wordlist-sources.json
（来源、版本与哈希）。两份文件进入输入法包 EngineData 前必须先完成
docs/third-party.md 的许可登记；本脚本只负责生成与记录。

用法：python3 scripts/build-english-wordlist.py [--limit 50000]
"""
import argparse
import hashlib
import json
import subprocess
import sys
import tempfile
import urllib.request
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CACHE = Path.home() / "Library/Caches/Gogaku/english"

# SCOWL 官方发布包（SourceForge wordlist 项目；github 仓库 v2 重构后不再随库
# 提供 final/ 预生成词表，发布包是稳定来源）。固定版本与哈希见
# docs/third-party.md 与 resources/english-wordlist-sources.json。
SCOWL_URL = ("https://downloads.sourceforge.net/project/wordlist/SCOWL/"
             "2020.12.07/scowl-2020.12.07.tar.gz")
SCOWL_VERSION = "2020.12.07"
SCOWL_TARBALL_SHA256 = "5587667caa20c4891390c2d42dbb4d5c4c3f41bee77af1457ece3ba23fb859cc"


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def download(url: str, dest: Path) -> None:
    print(f"下载 {url}")
    dest.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=60) as resp, open(dest, "wb") as out:
        out.write(resp.read())


def scowl_words() -> set[str]:
    words: set[str] = set()
    tarball = CACHE / f"scowl-{SCOWL_VERSION}.tar.gz"
    if not tarball.exists():
        download(SCOWL_URL, tarball)
    actual = sha256(tarball)
    if actual != SCOWL_TARBALL_SHA256:
        raise SystemExit(f"SCOWL tarball sha256 不符：{actual}")
    base = f"scowl-{SCOWL_VERSION}"
    if not (CACHE / base / "mk-list").exists():
        subprocess.run(["tar", "xzf", str(tarball)], cwd=CACHE, check=True)
    # 官方生成器：en_US size≤60 全部类别（基础词／美式专有／缩写／大小写），
    # 生成物即官方 hunspell en_US.dic 的原始词表（munch 前）。
    result = subprocess.run(["./mk-list", "-d", "final", "en_US", "60"],
                            cwd=CACHE / base, check=True, capture_output=True)
    # mk-list 输出为 ISO-8859-1（官方 hunspell 构建同用 iconv 转 UTF-8）。
    for line in result.stdout.decode("iso-8859-1").splitlines():
        word = line.strip()
        if word and word.isalpha() and word.isascii():
            words.add(word.lower())
    license_path = CACHE / "SCOWL-Copyright.txt"
    if not license_path.exists():
        license_path.write_bytes((CACHE / base / "Copyright").read_bytes())
    return words


def wordfreq_order(limit: int) -> list[str]:
    """在隔离 venv 中安装 wordfreq 并导出频率降序词表。"""
    venv = CACHE / "venv"
    if not (venv / "bin" / "python").exists():
        subprocess.run([sys.executable, "-m", "venv", str(venv)], check=True)
    pip = venv / "bin" / "pip"
    subprocess.run([str(pip), "install", "--quiet", "wordfreq==3.1.1"], check=True)
    script = f"""
from wordfreq import top_n_list
words = top_n_list('en', 200000)
print('\\n'.join(words))
"""
    result = subprocess.run([str(venv / "bin" / "python"), "-c", script], check=True,
                            capture_output=True, text=True)
    ordered = []
    seen = set()
    for word in result.stdout.splitlines():
        w = word.strip().lower()
        if w and w.isalpha() and w.isascii() and w not in seen:
            seen.add(w)
            ordered.append(w)
    return ordered


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--limit", type=int, default=50000, help="导出词数上限（按词频降序截取）")
    args = parser.parse_args()

    candidates = scowl_words()
    print(f"SCOWL size≤60 en_US 候选词：{len(candidates)}")
    ordered = wordfreq_order(args.limit)
    selected = [w for w in ordered if w in candidates][: args.limit]
    print(f"交集按词频降序取前 {len(selected)}")

    out = ROOT / "resources" / "english-words.txt"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text("\n".join(selected) + "\n", encoding="utf-8")
    manifest = {
        "description": "普通模式英文候选词表（SCOWL en_US size≤60 × wordfreq 英文词频排序）",
        "license": {
            "scowl": "MIT-like 集体作品；逐来源声明见 SCOWL-Copyright.txt（随包附 README_en.txt）",
            "wordfreq_data": "CC BY-SA 4.0；须署名 Robyn Speer 与 SUBTLEX 作者；衍生词表按同许可分发",
        },
        "sources": {
            "scowl": {"version": SCOWL_VERSION, "url": SCOWL_URL,
                      "tarball_sha256": SCOWL_TARBALL_SHA256,
                      "generator": "mk-list -d final en_US 60（官方 hunspell en_US 构建同一命令）"},
            "wordfreq": {"package": "wordfreq==3.1.1", "list": "top_n_list('en', 200000)"},
        },
        "word_count": len(selected),
        "output_sha256": sha256(out),
    }
    (ROOT / "resources" / "english-wordlist-sources.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"已写出 {out}")


if __name__ == "__main__":
    main()
