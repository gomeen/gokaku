#!/usr/bin/env python3
"""写入火山翻译凭据文件（供 volcengine_translate_worker.py 读取，0600）。

用法（在仓库检出目录）：
  python3 scripts/set-volcengine-credentials.py \
      --access-key-id AKLT... --secret-access-key TWp... \
      [--region cn-north-1] [--host translate.volcengineapi.com] \
      [--request-overrides '{"TermRepoID":"..."}']

凭据文件路径：~/Library/Application Support/Gogaku/translation/volcengine-credentials.json
settings.json 的 learningTranslationBackend 设为 "volcengine" 即启用；
仅学习模式联网（普通模式不经任何翻译路径）。
"""
import argparse
import json
import os
import sys
from pathlib import Path

DEFAULT_ROOT = Path.home() / "Library/Application Support/Gogaku/translation"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--access-key-id", required=True)
    parser.add_argument("--secret-access-key", required=True)
    parser.add_argument("--region", default="cn-north-1")
    parser.add_argument("--host", default="translate.volcengineapi.com")
    parser.add_argument("--request-overrides", default="{}",
                        help="JSON 对象，合并进 TranslateText 请求体（垂类/术语库等参数口子）")
    parser.add_argument("--root", type=Path, default=DEFAULT_ROOT, help="装配目录")
    args = parser.parse_args()
    try:
        overrides = json.loads(args.request_overrides)
        if not isinstance(overrides, dict):
            raise ValueError("requestOverrides 必须是 JSON 对象")
    except ValueError as error:
        raise SystemExit(f"requestOverrides 解析失败：{error}")
    args.root.mkdir(parents=True, exist_ok=True)
    path = args.root / "volcengine-credentials.json"
    payload = {
        "accessKeyId": args.access_key_id,
        "secretAccessKey": args.secret_access_key,
        "region": args.region,
        "host": args.host,
        "requestOverrides": overrides,
    }
    path.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    os.chmod(path, 0o600)
    print(f"凭据已写入：{path}（权限 0600）")
    print('启用：settings.json → "learningTranslationBackend": "volcengine"')


if __name__ == "__main__":
    main()
