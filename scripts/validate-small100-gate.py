"""G0 Mac 模型门槛：small100＋CT2 INT8 的转换、协议核对、质量与速度实测。

SMALL100 协议（依据仓库内 tokenization_small100.py，区别于 M2M100）：
- 只有 tgt_lang 一个语言设置；目标语言 token（如 ``__zh__``）是**编码器输入前缀**，
  源序列形如 ``[tgt_lang_token] + spm(X) + [eos]``。
- 解码器从纯 eos 开始，无 forced_bos；生成在 eos 结束。

三个子命令分别绑定不同隔离环境（OpenMP 冲突教训见 probes/results/translation-benchmark）：
  convert   在 venv-convert（含 PyTorch）内运行，OMP_NUM_THREADS=1。
  reference 在 venv-convert 内生成 HF greedy 参考输出（少量句子，模型只加载一次）。
  evaluate  在 venv-ct2（无 PyTorch）内运行完整质量与计时，HF_HUB_OFFLINE=1。

本脚本只产出数据与判定，用户语义盲测确认是独立门槛。
"""
import argparse
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REVISION = "8ab680e26a596d2e3d2d2d17ae0f68df1037328c"
DIRS = {"en-zh": "zh", "enToZh": "zh", "zhToEn": "en", "zh-en": "en"}


def load_cases():
    risk = json.loads((ROOT / "probes/translation-cases.json").read_text())
    holdout = json.loads((ROOT / "validation/translation-holdout.json").read_text())["cases"]
    return risk, holdout


def build_tokenizer(source_dir: Path, tgt: str):
    """显式加载仓库自带 SMALL100Tokenizer；small100 只有 tgt_lang，没有 src_lang。"""
    sys.path.insert(0, str(source_dir))
    import tokenization_small100  # noqa: E402

    tok = tokenization_small100.SMALL100Tokenizer.from_pretrained(str(source_dir), tgt_lang=tgt)
    return tok


def encode_protocol(tok, text: str):
    """返回 (encoder_tokens, target_prefix_tokens)，并断言协议形状。"""
    ids = tok(text, return_attention_mask=False)["input_ids"]
    tokens = tok.convert_ids_to_tokens(ids)
    lang_id = tok.get_lang_id(tok.tgt_lang)
    assert ids[0] == lang_id and ids[-1] == tok.eos_token_id, "SMALL100 协议形状不符"
    assert tokens[0] == tok.get_lang_token(tok.tgt_lang), "目标语言前缀缺失"
    return tokens, [tok.convert_ids_to_tokens([tok.eos_token_id])[0]]  # 解码器从纯 eos 开始


def decode_output(tok, tokens):
    ids = tok.convert_tokens_to_ids([t for t in tokens if t not in ("</s>", "<pad>", "<unk>")])
    return tok.decode(ids, skip_special_tokens=True)


def translate(translator, tok, text, max_decoding_length=256):
    encoder, prefix = encode_protocol(tok, text)
    result = translator.translate_batch(
        [encoder], target_prefix=[prefix], max_batch_size=1, batch_type="examples",
        beam_size=1, max_decoding_length=max_decoding_length, return_scores=False)
    return decode_output(tok, result[0].hypotheses[0])


def cmd_convert(args):
    os.environ["OMP_NUM_THREADS"] = "1"
    import ctranslate2  # noqa: F401 转换环境自检
    import torch
    torch.set_num_threads(1)
    source = args.root / "source"
    output = args.root / "ct2-int8"
    manifest = json.loads((args.root / "manifest.json").read_text())
    assert manifest["revision"] == REVISION, "下载 revision 不符"
    subprocess.run([
        sys.executable, "-m", "ctranslate2.converters.transformers",
        "--model", str(source), "--quantization", "int8",
        "--output_dir", str(output), "--force",
    ], check=True)
    files = sorted((p.name, p.stat().st_size) for p in output.iterdir() if p.is_file())
    print(json.dumps({"output": str(output), "files": files}, ensure_ascii=False))


def cmd_reference(args):
    """HF torch greedy 参考：验证协议并给 CT2 对照样本；模型只加载一次。"""
    os.environ["OMP_NUM_THREADS"] = "1"
    import torch
    from transformers import M2M100ForConditionalGeneration
    torch.set_num_threads(1)
    source = args.root / "source"
    risk, _ = load_cases()
    samples = [risk[0], risk[8], risk[16], risk[24], risk[1], risk[17]]
    model = M2M100ForConditionalGeneration.from_pretrained(str(source))
    model.eval()
    results = []
    for case in samples:
        tgt = DIRS[case["direction"]]
        tok = build_tokenizer(source, tgt)
        with torch.no_grad():
            encoded = tok(case["source"], return_tensors="pt", return_attention_mask=True)
            generated = model.generate(**encoded, num_beams=1, do_sample=False, max_length=256)
            text = tok.batch_decode(generated, skip_special_tokens=True)[0]
        encoder, prefix = encode_protocol(tok, case["source"])
        results.append({
            "id": case["id"], "direction": case["direction"], "source": case["source"],
            "tgt_lang": tgt, "hf_greedy": text,
            "encoder_prefix": encoder[:3], "encoder_suffix": encoder[-2:], "target_prefix": prefix,
        })
    del model
    (args.root / "hf-reference.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(results, ensure_ascii=False, indent=1))


def classify(output_text, elapsed_ms, timeout_ms):
    """可用性判定：空输出、显著重复、超时计失败。语义质量由用户审阅。"""
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


def cmd_evaluate(args):
    os.environ.setdefault("HF_HUB_OFFLINE", "1")
    os.environ.setdefault("HF_HUB_DISABLE_TELEMETRY", "1")
    import ctranslate2
    source = args.root / "source"
    model_dir = args.root / "ct2-int8"
    risk, holdout = load_cases()
    reference = {item["id"]: item for item in
                 json.loads((args.root / "hf-reference.json").read_text())}
    output = {"revision": REVISION, "threads": args.threads, "beam": 1, "batch": 1,
              "risk": [], "holdout": [], "latency": {}, "environment": {
                  "platform": sys.platform, "machine": os.uname().machine,
                  "ctranslate2": __import__("ctranslate2").__version__}}

    speed_pairs = [("short-expression", "Good morning."),
                   ("short-expression", "我明天有一个会议。"),
                   ("short-sentence", "I cannot open the attachment, please send it again."),
                   ("short-sentence", "我明天上午十点有一个会议，可能要迟到十分钟。")]

    for tag, cases in (("enToZh", None), ("zhToEn", None)):
        tgt = DIRS[tag]
        tok = build_tokenizer(source, tgt)
        translator = ctranslate2.Translator(str(model_dir), intra_threads=args.threads, inter_threads=1)
        latencies = {"short-expression": [], "short-sentence": []}
        for name, text in speed_pairs:
            for _ in range(args.rounds):
                begin = time.perf_counter()
                translate(translator, tok, text)
                latencies[name].append((time.perf_counter() - begin) * 1000.0)
        output["latency"][tag] = {name: {
            "n": len(v), "min": round(min(v), 1), "p50": round(statistics.median(v), 1),
            "p95": round(sorted(v)[int(round(0.95 * len(v))) - 1], 1), "max": round(max(v), 1)}
            for name, v in latencies.items()}
        for case in risk + holdout:
            if DIRS[case["direction"]] != tgt:
                continue
            begin = time.perf_counter()
            text = translate(translator, tok, case["source"])
            elapsed = (time.perf_counter() - begin) * 1000.0
            expected = case.get("expectedAction", "translate")
            entry = {"id": case["id"], "kind": case["kind"], "source": case["source"],
                     "reference": case.get("reference"), "expectedAction": expected,
                     "output": text, "ms": round(elapsed, 1),
                     "availability": "preserve-expected" if expected == "preserve" else classify(text, elapsed, args.timeout_ms)}
            if case["id"] in reference and reference[case["id"]]["tgt_lang"] == tgt:
                entry["hf_greedy"] = reference[case["id"]]["hf_greedy"]
            output["risk" if case in risk else "holdout"].append(entry)

    path = Path(args.output)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(output, ensure_ascii=False, indent=1) + "\n")

    summary = {"revision": REVISION, "threads": args.threads, "rounds": args.rounds,
               "latency": output["latency"], "environment": output["environment"]}
    for bucket in ("risk", "holdout"):
        translate_cases = [e for e in output[bucket] if e["expectedAction"] == "translate"]
        counts = {}
        for e in translate_cases:
            counts[e["availability"]] = counts.get(e["availability"], 0) + 1
        available = counts.get("available", 0)
        summary[bucket] = {
            "total": len(translate_cases), "available": available,
            "usableRate": round(available / max(1, len(translate_cases)), 4),
            "empty": counts.get("empty", 0), "repeat": counts.get("repeat", 0),
            "timeout": counts.get("timeout", 0),
            "p95ms": sorted(e["ms"] for e in translate_cases)[max(0, int(round(0.95 * len(translate_cases))) - 1)],
        }
    Path(str(path) + ".summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=1) + "\n")
    print(json.dumps(summary, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=["convert", "reference", "evaluate"])
    parser.add_argument("--root", type=Path, default=Path.home() / "Library/Caches/Gogaku/models/small100-gate")
    parser.add_argument("--output", default=str(ROOT / "probes/results/small100-gate/evaluate.json"))
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--timeout-ms", type=float, default=10000)
    args = parser.parse_args()
    {"convert": cmd_convert, "reference": cmd_reference, "evaluate": cmd_evaluate}[args.command](args)
