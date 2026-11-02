"""quickmt 双向模型在 Mac 门槛机上的速度实测（速度探针，非质量门槛）。

方法学对齐 scripts/validate-small100-gate.py 的 evaluate 子命令：
CT2 4.6.0、int8（fp16 原生权重加载时在线转换）、greedy、batch=1、2 线程、12 轮热态、
同一组 4 个速度句。协议按 quickmt 官方库 translator.py：
src spm encode(out_type=str) → 追加 "</s>"；输出用 tgt spm decode。

本脚本只产出延迟数据与可用性分类（空/重复/超时），语义质量结论归独立门槛流程。
运行：venv-ct2/bin/python scripts/validate-quickmt-speed.py evaluate
"""
import argparse
import json
import statistics
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_ROOT = Path.home() / "Library/Caches/Gogaku/models/quickmt-speed"
MODELS = {"enToZh": "quickmt-en-zh", "zhToEn": "quickmt-zh-en"}
# 风险集用 "en-zh"/"zh-en"，留存集用 "enToZh"/"zhToEn"（同 small100 门槛脚本）
CASE_DIRS = {"en-zh": "enToZh", "enToZh": "enToZh", "zhToEn": "zhToEn", "zh-en": "zhToEn"}
SPEED_PAIRS = [
    ("short-expression", "Good morning."),
    ("short-expression", "我明天有一个会议。"),
    ("short-sentence", "I cannot open the attachment, please send it again."),
    ("short-sentence", "我明天上午十点有一个会议，可能要迟到十分钟。"),
]


def load_cases():
    risk = json.loads((ROOT / "probes/translation-cases.json").read_text())
    holdout = json.loads((ROOT / "validation/translation-holdout.json").read_text())["cases"]
    return risk, holdout


class QuickmtProtocol:
    """quickmt 官方协议的最小实现（不含分句/缓存，单句直译）。"""

    def __init__(self, model_dir: Path, threads: int, compute_type: str):
        import ctranslate2
        import sentencepiece

        self.src_spm = sentencepiece.SentencePieceProcessor(
            model_file=str(model_dir / "src.spm.model"))
        self.tgt_spm = sentencepiece.SentencePieceProcessor(
            model_file=str(model_dir / "tgt.spm.model"))
        self.translator = ctranslate2.Translator(
            str(model_dir), intra_threads=threads, inter_threads=1,
            compute_type=compute_type)

    def translate(self, text: str, beam_size: int = 1, max_decoding_length: int = 256) -> str:
        pieces = self.src_spm.encode(text, out_type=str) + ["</s>"]
        result = self.translator.translate_batch(
            [pieces], max_batch_size=1, batch_type="examples",
            beam_size=beam_size, max_decoding_length=max_decoding_length,
            return_scores=False)
        return self.tgt_spm.decode(result[0].hypotheses[0])


def classify(output_text, elapsed_ms, timeout_ms):
    if elapsed_ms > timeout_ms:
        return "timeout"
    stripped = (output_text or "").strip()
    if not stripped:
        return "empty"
    unit = max(2, len(stripped) // 4)
    chunk = stripped[:unit]
    if len(stripped) >= 3 * unit and stripped.replace(chunk, "") == "":
        return "repeat"
    return "available"


def pctile(values, q):
    ordered = sorted(values)
    return ordered[max(0, int(round(q * len(ordered))) - 1)]


def cmd_evaluate(args):
    import ctranslate2

    root = args.models_root
    risk, holdout = load_cases()
    output = {
        "probe": "quickmt-speed", "beam": args.beam, "rounds": args.rounds,
        "threads": args.threads, "computeType": args.compute_type,
        "environment": {"platform": sys.platform, "machine": __import__("os").uname().machine,
                        "ctranslate2": ctranslate2.__version__},
        "models": {}, "latency": {}, "risk": [], "holdout": [],
    }

    for direction, model_name in MODELS.items():
        model_dir = root / model_name
        begin = time.perf_counter()
        proto = QuickmtProtocol(model_dir, threads=args.threads, compute_type=args.compute_type)
        load_seconds = time.perf_counter() - begin
        output["models"][direction] = {"name": model_name, "loadSeconds": round(load_seconds, 2)}

        # 热身（计入 load 后的准备，不计入计时）
        for _, text in SPEED_PAIRS:
            proto.translate(text, beam_size=args.beam)

        latencies = {"short-expression": [], "short-sentence": []}
        for name, text in SPEED_PAIRS:
            for _ in range(args.rounds):
                begin = time.perf_counter()
                proto.translate(text, beam_size=args.beam)
                latencies[name].append((time.perf_counter() - begin) * 1000.0)
        output["latency"][direction] = {name: {
            "n": len(v), "min": round(min(v), 1), "p50": round(statistics.median(v), 1),
            "p95": round(pctile(v, 0.95), 1), "max": round(max(v), 1)}
            for name, v in latencies.items()}

        for case in risk + holdout:
            if CASE_DIRS[case["direction"]] != direction:
                continue
            begin = time.perf_counter()
            text = proto.translate(case["source"], beam_size=args.beam)
            elapsed = (time.perf_counter() - begin) * 1000.0
            expected = case.get("expectedAction", "translate")
            output["risk" if case in risk else "holdout"].append({
                "id": case["id"], "kind": case["kind"], "source": case["source"],
                "reference": case.get("reference"), "expectedAction": expected,
                "output": text, "ms": round(elapsed, 1),
                "availability": "preserve-expected" if expected == "preserve" else classify(text, elapsed, args.timeout_ms)})
        del proto

    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, ensure_ascii=False, indent=1) + "\n")

    summary = dict(output)
    summary["risk"] = _bucket_stats(output["risk"])
    summary["holdout"] = _bucket_stats(output["holdout"])
    Path(str(path) + ".summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps({k: summary[k] for k in ("latency", "models", "risk", "holdout")}, ensure_ascii=False, indent=1))


def _bucket_stats(entries):
    translate_cases = [e for e in entries if e["expectedAction"] == "translate"]
    counts = {}
    for e in translate_cases:
        counts[e["availability"]] = counts.get(e["availability"], 0) + 1
    ms = sorted(e["ms"] for e in translate_cases)
    return {
        "total": len(translate_cases),
        "available": counts.get("available", 0),
        "usableRate": round(counts.get("available", 0) / max(1, len(translate_cases)), 4),
        "empty": counts.get("empty", 0), "repeat": counts.get("repeat", 0),
        "timeout": counts.get("timeout", 0),
        "p50ms": ms[len(ms) // 2] if ms else None,
        "p95ms": pctile(ms, 0.95) if ms else None,
        "maxMs": max(ms) if ms else None,
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["evaluate"])
    parser.add_argument("--models-root", type=Path, default=DEFAULT_ROOT)
    parser.add_argument("--output", default=str(ROOT / "probes/results/quickmt-speed/evaluate.json"))
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--beam", type=int, default=1)
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--timeout-ms", type=float, default=10000)
    args = parser.parse_args()
    {"evaluate": cmd_evaluate}[args.command](args)
