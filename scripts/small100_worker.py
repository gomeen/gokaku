#!/usr/bin/env python3
"""Gogaku 学习模式 small100 翻译辅助进程（2026-11-03 用户裁决：仅换模型的质量试验）。

协议与 scripts/quickmt_worker.py 完全一致（TranslationRequest／TranslationResult v1，
JSON 行、stdio），仅替换运行时：
  - 权重 alirezamsh/small100 @ 8ab680e2（MIT，模型卡口径；见 manifest.json），
    CT2 INT8（ct2-int8/）＋ 显式加载仓库自带 SMALL100Tokenizer（AutoTokenizer
    会误选 M2M100Tokenizer——small100 只有 tgt_lang，没有 src_lang）。
  - 方向协议（对齐 scripts/validate-small100-gate.py，质量实测 95%+ 的口径）：
    目标语言令牌（__en__／__zh__）作输入前缀＋eos 后缀；解码器从纯 eos 开始
    （target_prefix=[eos]）；解码过滤 </s>/<pad>/<unk>。
  - 输入上限按 max_position_embeddings 截断判定。
错误码、输入上限、行/响应字节上限、尾部孤立标点剥离与 quickmt worker 同口径。
无端口、无网络、无文本日志；进程常驻、单请求串行。
装配见 scripts/prepare-learning-small100.py；质量证据见
probes/results/translation-backends/decision.md（small100 可用率 95.15%／94.34%）。
"""
import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

# 权重与分词器全部来自本地装配；显式断网标志（本 worker 不引入会联网的库）。
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")
os.environ.setdefault("OMP_WAIT_POLICY", "PASSIVE")
os.environ.setdefault("KMP_BLOCKTIME", "0")

DIRECTIONS = {"zhToEn": ("zh", "en"), "enToZh": ("en", "zh")}
MAX_SOURCE_SCALARS = 512
MAX_LINE_BYTES = 65_535          # 与父进程 input_limit／response_limit 同口径
MAX_RESPONSE_BYTES = 60_000      # 父进程按 64KiB 行上限拒收，留出 JSON 包装余量


class ModelMissing(Exception):
    pass


class InputTooLong(Exception):
    pass


# 与 quickmt worker 同口径：剥离与正文以空白分隔的纯标点尾缀。
_ORPHAN_TAIL = re.compile(r"\s+[””’'\"」』）)!？?。．，,；;：:…·]+\s*$")


def strip_trailing_orphan_punctuation(text):
    result = text
    while True:
        match = _ORPHAN_TAIL.search(result)
        if not match:
            return result
        result = result[: match.start()].rstrip()


class BackendError(Exception):
    pass


def emit(value):
    line = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(line.encode("utf-8")) >= MAX_RESPONSE_BYTES:
        return  # 响应超限：与现有 helper 一致选择不发，父进程按超时处置
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class Small100Runtime:
    """small100 CT2 运行时（INT8、HF 分词器、语言令牌前缀协议）。"""

    def __init__(self, root, threads, compute_type, max_decoding_length):
        self.root = root
        self.threads = threads
        self.compute_type = compute_type
        self.max_decoding_length = max_decoding_length
        self.tokenizer = None
        self.limit = None
        self.translator = None

    def _ensure(self):
        if self.translator is not None:
            return
        model_dir = self.root / "ct2-int8"
        source = self.root / "source"
        if not (model_dir / "model.bin").is_file() or not (source / "config.json").is_file():
            raise ModelMissing("small100")
        import ctranslate2
        # 显式加载仓库自带 SMALL100Tokenizer：AutoTokenizer 会按 tokenizer_config
        # 误选 M2M100Tokenizer（src_lang 语义与 small100 训练协议不符，译文方向错乱）。
        sys.path.insert(0, str(source))
        import tokenization_small100
        self.tok_cls = tokenization_small100.SMALL100Tokenizer
        self.tokenizer = self.tok_cls.from_pretrained(
            str(source), local_files_only=True, tgt_lang="en")
        config = json.loads((source / "config.json").read_text())
        self.limit = int(config.get("max_position_embeddings", 1024))
        self.translator = ctranslate2.Translator(
            str(model_dir), device="cpu", compute_type=self.compute_type,
            inter_threads=1, intra_threads=self.threads)

    def translate(self, direction, text, beam):
        self._ensure()
        source_lang, target_lang = DIRECTIONS[direction]
        # small100 协议：目标语言令牌作输入前缀（tokenizer tgt_lang 属性即目标语言）；
        # 解码器从纯 eos 开始。与 validate-small100-gate.py 的 encode_protocol/
        # decode_output 逐项一致（beam>1 用 gate 同款默认 length_penalty）。
        self.tokenizer.tgt_lang = target_lang
        ids = self.tokenizer.encode(text, add_special_tokens=True)
        if len(ids) > self.limit:
            raise InputTooLong(f"{len(ids)} > {self.limit}")
        expected_prefix = self.tokenizer.get_lang_id(target_lang)
        if ids[0] != expected_prefix or ids[-1] != self.tokenizer.eos_token_id:
            raise BackendError("small100 输入形状不符（语言前缀／eos 后缀缺失）")
        tokens = self.tokenizer.convert_ids_to_tokens(ids)
        result = self.translator.translate_batch(
            [tokens], target_prefix=[[self.tokenizer.eos_token]],  # "</s>"（CT2 要求 token 字符串）
            beam_size=beam, max_decoding_length=self.max_decoding_length,
            return_scores=False)[0]
        output_ids = self.tokenizer.convert_tokens_to_ids(
            [t for t in result.hypotheses[0] if t not in ("</s>", "<pad>", "<unk>")])
        return strip_trailing_orphan_punctuation(
            self.tokenizer.decode(output_ids, skip_special_tokens=True).strip())


def read_line(stream):
    """读一行；超限行消费完即按丢弃处理（父进程本就不会发出超限请求）。"""
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


def handle(raw, runtime, beam):
    """处理一行请求；返回响应 dict 或 None（无法解析的行按丢弃处理）。"""
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
        text = runtime.translate(direction, source, beam)
    except ModelMissing:
        return response(error="model_missing", target=None)
    except InputTooLong:
        return response(error="invalid_request", target=None)
    except Exception:
        return response(error="backend_error", target=None)
    if not text:
        return response(error="empty_output", target=None)
    return response(target=text, error=None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                        help="包含 venv／source／ct2-int8 的装配目录")
    parser.add_argument("--beam", type=int, default=1, help="beam 大小（设置 1–10）")
    parser.add_argument("--threads", type=int, default=2, help="CT2 intra 线程数")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--max-decoding-length", type=int, default=256)
    args = parser.parse_args()
    beam = max(1, min(10, args.beam))
    for key in ("OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"):
        os.environ.setdefault(key, str(args.threads))
    runtime = Small100Runtime(args.root, args.threads, args.compute_type, args.max_decoding_length)
    stream = sys.stdin.buffer
    while True:
        raw = read_line(stream)
        if raw is None:
            return
        if not raw:
            continue
        reply = handle(raw, runtime, beam)
        if reply is not None:
            emit(reply)


if __name__ == "__main__":
    main()
