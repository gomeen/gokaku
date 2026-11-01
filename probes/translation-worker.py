"""One isolated translation configuration, speaking JSON lines over stdio."""
import argparse
import json
import os
import resource
import sys
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("--config", required=True)
parser.add_argument("--root", type=Path, required=True)
args = parser.parse_args()
config = json.loads(args.config)
threads = config["threads"]
for key in ["OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"]:
    os.environ[key] = str(threads)
os.environ.update({"HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TOKENIZERS_PARALLELISM": "false", "OMP_WAIT_POLICY": "PASSIVE", "KMP_BLOCKTIME": "0", "PYTORCH_ENABLE_MPS_FALLBACK": "1" if config.get("mps_cpu_fallback") else "0"})
if config["backend"] == "ct2":
    os.environ["USE_TORCH"] = "0"


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def peak_rss():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss


class Translator:
    def __init__(self):
        from transformers import AutoTokenizer
        self.models = {}
        self.tokenizers = {}
        self.limits = {}
        self.versions = {}
        self.torch = None
        if config["backend"] == "ct2":
            import ctranslate2
            self.versions["ctranslate2"] = ctranslate2.__version__
            self.ct2 = ctranslate2
            if "torch" in sys.modules:
                raise RuntimeError("CTranslate2 runtime must be isolated from PyTorch and its OpenMP library")
        else:
            import torch
            torch.set_num_threads(threads)
            torch.set_num_interop_threads(1)
            if config["device"] == "mps" and not torch.backends.mps.is_available():
                raise RuntimeError("MPS is not available")
            self.torch = torch
            self.versions["torch"] = torch.__version__
        start = time.perf_counter_ns()
        names = ["m2m100"] if config["model"] == "m2m100" else ["opus-en-zh", "opus-zh-en"]
        for name in names:
            source = args.root / name / "source"
            self.tokenizers[name] = AutoTokenizer.from_pretrained(str(source), local_files_only=True, trust_remote_code=False, clean_up_tokenization_spaces=False)
            self.limits[name] = json.loads((source / "config.json").read_text())["max_position_embeddings"]
            if config["backend"] == "ct2":
                self.models[name] = self.ct2.Translator(str(args.root / name / ("ct2-" + config["precision"])), device="cpu", compute_type=config["precision"], inter_threads=1, intra_threads=threads)
            else:
                from transformers import AutoModelForSeq2SeqLM
                dtype = self.torch.float16 if config["precision"] == "float16" else self.torch.float32
                self.models[name] = AutoModelForSeq2SeqLM.from_pretrained(str(source), local_files_only=True, trust_remote_code=False, torch_dtype=dtype).eval().to(config["device"])
        if config["model"] == "opus":
            tokenizer = self.tokenizers["opus-en-zh"]
            self.zh_prefix = ">>cmn_Hans<<"
            if tokenizer.convert_tokens_to_ids(self.zh_prefix) == tokenizer.unk_token_id:
                raise RuntimeError("Requested Simplified Chinese target token is not in the pinned model vocabulary")
        self.synchronize()
        self.load_ms = (time.perf_counter_ns() - start) / 1e6

    def synchronize(self):
        if self.torch is not None and config["device"] == "mps":
            self.torch.mps.synchronize()

    def translate(self, case):
        source = case["source"]
        if not source.strip():
            raise ValueError("Empty input is not a translation benchmark case")
        name = "m2m100" if config["model"] == "m2m100" else "opus-" + case["direction"]
        tokenizer = self.tokenizers[name]
        model = self.models[name]
        is_m2m = name == "m2m100"
        source_lang, target_lang = ("en", "zh") if case["direction"] == "en-zh" else ("zh", "en")
        self.synchronize()
        start = time.perf_counter_ns()
        cpu_start = time.process_time_ns()
        if is_m2m:
            tokenizer.src_lang = source_lang
        prepared = self.zh_prefix + " " + source if name == "opus-en-zh" else source
        ids = tokenizer.encode(prepared, add_special_tokens=True, truncation=False)
        if len(ids) > self.limits[name]:
            raise ValueError(f"Input exceeds model limit: {len(ids)} > {self.limits[name]}")
        if config["backend"] == "ct2":
            tokens = tokenizer.convert_ids_to_tokens(ids)
        else:
            input_ids = self.torch.tensor([ids], dtype=self.torch.long, device=config["device"])
            attention_mask = self.torch.ones_like(input_ids)
        self.synchronize()
        encoded = time.perf_counter_ns()
        if config["backend"] == "ct2":
            extra = {"target_prefix": [[tokenizer.get_lang_token(target_lang)]]} if is_m2m else {}
            result = model.translate_batch([tokens], beam_size=config["beam"], max_decoding_length=96, length_penalty=1.0, return_scores=True, **extra)[0]
            output_tokens = result.hypotheses[0]
            output_ids = tokenizer.convert_tokens_to_ids(output_tokens)
            truncated = len(output_tokens) >= 96
        else:
            extra = {"forced_bos_token_id": tokenizer.get_lang_id(target_lang)} if is_m2m else {}
            with self.torch.inference_mode():
                result = model.generate(input_ids=input_ids, attention_mask=attention_mask, num_beams=config["beam"], do_sample=False, use_cache=True, max_new_tokens=96, length_penalty=1.0, early_stopping=config["beam"] > 1, forced_eos_token_id=None, **extra)
            self.synchronize()
            output_ids = result[0].tolist()
            truncated = output_ids[-1] != tokenizer.eos_token_id
        generated = time.perf_counter_ns()
        text = tokenizer.decode(output_ids, skip_special_tokens=True, clean_up_tokenization_spaces=False).strip()
        self.synchronize()
        end = time.perf_counter_ns()
        special = set(tokenizer.all_special_ids)
        return {"id": case["id"], "direction": case["direction"], "kind": case["kind"], "source": source, "output": text, "input_tokens": len(ids), "output_tokens": sum(token not in special for token in output_ids), "source_unknown_tokens": ids.count(tokenizer.unk_token_id), "truncated": truncated, "generated": bool(text) and not truncated, "encode_ms": (encoded - start) / 1e6, "generate_ms": (generated - encoded) / 1e6, "decode_ms": (end - generated) / 1e6, "total_ms": (end - start) / 1e6, "cpu_ms": (time.process_time_ns() - cpu_start) / 1e6, "peak_rss_bytes": peak_rss()}


try:
    translator = Translator()
    emit({"event": "ready", "pid": os.getpid(), "config": config, "model_load_ms": translator.load_ms, "peak_rss_bytes": peak_rss(), "versions": translator.versions})
except Exception as error:
    emit({"event": "load_error", "error": repr(error), "config": config})
    raise SystemExit(2)

for line in sys.stdin:
    request = json.loads(line)
    if request.get("event") == "stop":
        emit({"event": "stopped", "peak_rss_bytes": peak_rss()})
        break
    for case in request["cases"]:
        try:
            result = translator.translate(case)
            emit({"event": "result", "phase": request["phase"], **result})
        except Exception as error:
            emit({"event": "result", "phase": request["phase"], "id": case["id"], "direction": case["direction"], "source": case["source"], "generated": False, "error": repr(error), "peak_rss_bytes": peak_rss()})
    emit({"event": "request_done"})
