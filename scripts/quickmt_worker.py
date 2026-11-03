#!/usr/bin/env python3
"""Gogaku 学习模式 quickmt 开发版翻译辅助进程（2026-11 裁决，仅本机开发版自用）。

协议对齐 GogakuCore 的 TranslationRequest／TranslationResult v1（JSON 行、stdio）：
  stdin  每行一个 TranslationRequest JSON；
  stdout 每行一个响应：原样回传 protocolVersion／id／stamp／sourceID／source／resource，
         附 target（成功时）或 error（失败时）与 milliseconds。
错误码：invalid_request（协议版本、空输入、超 512 标量、非法方向）、
        model_missing（权重未装配）、empty_output（模型空输出）、backend_error（其余异常）。
无端口、无网络、无文本日志；进程常驻、单请求串行；两方向权重按请求方向懒加载。
推理配置与探针一致：CT2 INT8、CPU 2 线程、max_decoding_length 256；
quickmt 官方协议 src spm + </s> → tgt spm decode；beam 来自 --beam（设置 1–10，默认 1）。
准备与装配见 scripts/prepare-learning-translation.py；已知风险清单见
docs/learning-quickmt-dev-decision.md（beam1 的重复句等缺陷被开发版接受）。
"""
import argparse
import json
import os
import sys
import time
from pathlib import Path

# 权重与分词器全部来自本地装配；显式断网标志（本 worker 不引入会联网的库）。
os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")

DIRECTIONS = {"zhToEn": "quickmt-zh-en", "enToZh": "quickmt-en-zh"}
MAX_SOURCE_SCALARS = 512
MAX_LINE_BYTES = 65_535          # 与父进程 input_limit／response_limit 同口径
MAX_RESPONSE_BYTES = 60_000      # 父进程按 64KiB 行上限拒收，留出 JSON 包装余量


class ModelMissing(Exception):
    pass


class BackendError(Exception):
    pass


def emit(value):
    line = json.dumps(value, ensure_ascii=False, separators=(",", ":"))
    if len(line.encode("utf-8")) >= MAX_RESPONSE_BYTES:
        return  # 响应超限：与现有 helper 一致选择不发，父进程按超时处置
    sys.stdout.write(line + "\n")
    sys.stdout.flush()


class QuickmtRuntime:
    """按方向懒加载的 quickmt CT2 运行时（INT8、2 线程、官方分词协议）。"""

    def __init__(self, root, threads, compute_type, max_decoding_length):
        self.root = root
        self.threads = threads
        self.compute_type = compute_type
        self.max_decoding_length = max_decoding_length
        self.loaded = {}

    def _runtime(self, direction):
        model = self.loaded.get(direction)
        if model is not None:
            return model
        name = DIRECTIONS[direction]
        model_dir = self.root / name
        if not (model_dir / "model.bin").is_file() \
                or not (model_dir / "src.spm.model").is_file() \
                or not (model_dir / "tgt.spm.model").is_file():
            raise ModelMissing(name)
        import ctranslate2
        import sentencepiece
        src = sentencepiece.SentencePieceProcessor(model_file=str(model_dir / "src.spm.model"))
        tgt = sentencepiece.SentencePieceProcessor(model_file=str(model_dir / "tgt.spm.model"))
        translator = ctranslate2.Translator(
            str(model_dir), device="cpu", compute_type=self.compute_type,
            inter_threads=1, intra_threads=self.threads)
        model = (src, tgt, translator)
        self.loaded[direction] = model
        return model

    def translate(self, direction, text, beam):
        src, tgt, translator = self._runtime(direction)
        pieces = src.encode(text, out_type=str) + ["</s>"]
        result = translator.translate_batch(
            [pieces], max_batch_size=1, batch_type="examples",
            beam_size=beam, num_hypotheses=1,
            max_decoding_length=self.max_decoding_length,
            return_scores=False, return_end_token=True)
        tokens = result[0].hypotheses[0]
        return tgt.decode([t for t in tokens if t != "</s>"]).strip()


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
    except Exception:
        return response(error="backend_error", target=None)
    if not text:
        return response(error="empty_output", target=None)
    return response(target=text, error=None)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent,
                        help="包含 venv／quickmt-en-zh／quickmt-zh-en 的装配目录")
    parser.add_argument("--beam", type=int, default=1, help="beam 大小（设置 1–10）")
    parser.add_argument("--threads", type=int, default=2, help="CT2 intra 线程数")
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--max-decoding-length", type=int, default=256)
    args = parser.parse_args()
    beam = max(1, min(10, args.beam))
    runtime = QuickmtRuntime(args.root, args.threads, args.compute_type, args.max_decoding_length)
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
