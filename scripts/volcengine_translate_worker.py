#!/usr/bin/env python3
"""火山翻译（Volcengine TranslateText）云端 NMT 后端 worker——仅学习模式使用。

协议为 TranslationRequest／TranslationResult v1（JSON 行、stdio）：
  - 普通 NMT 云端调用：无 beam／线程／精度概念；V4 HMAC-SHA256 签名（stdlib 实现）。
  - HTTPS 连接跨请求复用（http.client keep-alive），失败重连一次。
  - 凭据从 --credentials 指向的 JSON 文件读取（0600，不进命令行避免 ps 泄露）：
      {"accessKeyId": "...", "secretAccessKey": "...",
       "region": "cn-north-1"(可选), "host": "translate.volcengineapi.com"(可选),
       "requestOverrides": {...}(可选，合并进请求体——垂类引擎/术语库等未来参数口子)}
  - 联网仅限学习模式：本 worker 只被学习翻译服务拉起，普通模式不经此路径。

错误码保持既有学习请求协议，凭据缺失为 credentials_missing。
无端口、无文本日志；进程常驻、单请求串行。
"""
import argparse
import hashlib
import hmac
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from http.client import HTTPSConnection
from pathlib import Path

DIRECTIONS = {"zhToEn": ("zh", "en"), "enToZh": ("en", "zh")}
MAX_SOURCE_SCALARS = 512
MAX_LINE_BYTES = 65_535
MAX_RESPONSE_BYTES = 60_000


class CredentialsMissing(Exception):
    pass


class BackendError(Exception):
    pass


_ORPHAN_TAIL = re.compile(r"\s+[””’'\"」』）)!？?。．，,；;：:…·]+\s*$")


def strip_trailing_orphan_punctuation(text):
    result = text
    while True:
        match = _ORPHAN_TAIL.search(result)
        if not match:
            return result
        result = result[: match.start()].rstrip()


def emit(value):
    line = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(line.encode("utf-8")) >= MAX_RESPONSE_BYTES:
        return
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class VolcengineRuntime:
    """火山翻译运行时：凭据文件 + 复用 HTTPS 连接 + V4 签名。"""

    def __init__(self, credentials_path, host, region, timeout):
        self.credentials_path = credentials_path
        self.host = host
        self.region = region
        self.timeout = timeout
        self.access_key = None
        self.secret_key = None
        self.overrides = {}
        self.connection = None
        self.last_characters = None
        self.credentials_mtime = None

    def _ensure_credentials(self):
        # 按 mtime 热加载：设置页保存凭据后无需重建 worker 即生效。
        path = Path(self.credentials_path)
        if not path.is_file():
            raise CredentialsMissing(str(path))
        try:
            mtime = path.stat().st_mtime
        except OSError as error:
            raise CredentialsMissing(str(error)) from error
        if self.access_key is not None and self.credentials_mtime == mtime:
            return
        try:
            config = json.loads(path.read_text())
        except (OSError, ValueError) as error:
            raise CredentialsMissing(f"{path}: {error}") from error
        self.credentials_mtime = mtime
        self.access_key = config.get("accessKeyId")
        self.secret_key = config.get("secretAccessKey")
        if not self.access_key or not self.secret_key:
            raise CredentialsMissing("accessKeyId/secretAccessKey 缺失")
        self.host = config.get("host", self.host)
        self.region = config.get("region", self.region)
        self.overrides = config.get("requestOverrides") or {}

    def _sign(self, query, body, now):
        x_date = now.strftime("%Y%m%dT%H%M%SZ")
        date_stamp = x_date[:8]
        canonical_headers = f"content-type:application/json\nhost:{self.host}\nx-date:{x_date}\n"
        signed_headers = "content-type;host;x-date"
        payload_hash = hashlib.sha256(body).hexdigest()
        canonical = f"POST\n/\n{query}\n{canonical_headers}\n{signed_headers}\n{payload_hash}"
        scope = f"{date_stamp}/{self.region}/{SERVICE}/request"

        def hm(key, msg):
            return hmac.new(key, msg.encode(), hashlib.sha256).digest()

        k_date = hm(self.secret_key.encode(), date_stamp)
        k_region = hm(k_date, self.region)
        k_service = hm(k_region, SERVICE)
        k_signing = hm(k_service, "request")
        string_to_sign = "\n".join([
            "HMAC-SHA256", x_date, scope,
            hashlib.sha256(canonical.encode()).hexdigest()])
        signature = hmac.new(k_signing, string_to_sign.encode(), hashlib.sha256).hexdigest()
        return (f"HMAC-SHA256 Credential={self.access_key}/{scope}, "
                f"SignedHeaders={signed_headers}, Signature={signature}"), x_date

    def _request(self, payload):
        self._ensure_credentials()
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        query = f"Action={ACTION}&Version={VERSION}"
        authorization, x_date = self._sign(query, body, datetime.now(timezone.utc))
        headers = {"Content-Type": "application/json", "Host": self.host,
                   "X-Date": x_date, "Authorization": authorization}
        if self.connection is None:
            self.connection = HTTPSConnection(self.host, timeout=self.timeout)
        self.connection.request("POST", f"/?{query}", body=body, headers=headers)
        response = self.connection.getresponse()
        data = response.read()
        if response.status != 200:
            self.connection.close()
            self.connection = None
            raise BackendError(f"HTTP {response.status}: {data[:200].decode('utf-8', 'replace')}")
        return json.loads(data.decode("utf-8"))

    def translate(self, direction, text):
        self._ensure_credentials()
        source_language, target_language = DIRECTIONS[direction]
        request = {"TargetLanguage": target_language, "SourceLanguage": source_language,
                   "TextList": [text]}
        request.update(self.overrides)
        result = self._request(request)
        translation_list = result.get("TranslationList") or []
        if not translation_list:
            raise BackendError(f"missing TranslationList: {json.dumps(result, ensure_ascii=False)[:200]}")
        entry = translation_list[0]
        # 服务端计费口径字符数（Extra.input_characters）：带回给父进程做额度计量，
        # 与官方账本逐字对齐（客户端标量估算仅作回退）。
        entry_extra = entry.get("Extra") or {}
        try:
            self.last_characters = int(entry_extra.get("input_characters"))
        except (TypeError, ValueError):
            self.last_characters = None
        return strip_trailing_orphan_punctuation(
            (entry.get("Translation") or "").strip())


ACTION = "TranslateText"
VERSION = "2020-06-01"
SERVICE = "translate"


def read_line(stream):
    data = bytearray()
    oversized = False
    while True:
        byte = stream.read(1)
        if not byte:
            return None
        if byte == b"\n":
            return b"" if oversized else bytes(data)
        if len(data) < MAX_LINE_BYTES:
            data += byte
        else:
            oversized = True


def handle(raw, runtime):
    try:
        request = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(request, dict):
        return None
    start = time.perf_counter_ns()

    def response(**extra):
        out = dict(request)
        out.update(extra)
        out["milliseconds"] = (time.perf_counter_ns() - start) / 1e6
        return out

    stamp = request.get("stamp") if isinstance(request.get("stamp"), dict) else {}
    source = request.get("source")
    direction = stamp.get("direction")
    if request.get("protocolVersion") != 1 \
            or not isinstance(source, str) or not source.strip() \
            or len(source) > MAX_SOURCE_SCALARS \
            or direction not in DIRECTIONS:
        return response(error="invalid_request", target=None)
    try:
        text = runtime.translate(direction, source)
    except CredentialsMissing as error:
        return response(error="credentials_missing", target=None,
                        detail=str(error)[:120])
    except BackendError:
        return response(error="backend_error", target=None)
    except Exception:
        return response(error="backend_error", target=None)
    if not text:
        return response(error="empty_output", target=None)
    return response(target=text, error=None, characters=runtime.last_characters)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--credentials", type=Path, required=True,
                        help="凭据 JSON 文件（0600，见文件头注释）")
    parser.add_argument("--host", default="translate.volcengineapi.com")
    parser.add_argument("--region", default="cn-north-1")
    parser.add_argument("--timeout", type=float, default=5.0,
                        help="单次云端请求超时秒数（父进程另有 10s 总超时）")
    args = parser.parse_args()
    runtime = VolcengineRuntime(args.credentials, args.host, args.region, args.timeout)
    stream = sys.stdin.buffer
    while True:
        raw = read_line(stream)
        if raw is None:
            return
        if not raw:
            continue
        reply = handle(raw, runtime)
        if reply is not None:
            emit(reply)


if __name__ == "__main__":
    main()
