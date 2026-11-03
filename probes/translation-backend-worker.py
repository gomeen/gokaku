#!/usr/bin/env python3
"""One isolated translation backend, speaking JSON lines over stdio.

This is the helper-process layer of the unified benchmark: the parent sends one
JSON request per case and measures policy/transport overhead separately from
the tokenizer + CTranslate2 + decode work reported here.

Adapters:
  small100  one multilingual CT2 model; target language is an encoder prefix
  quickmt   one native CT2 model per direction; separate src/tgt spm, append </s>

The worker never downloads models. It expects a prepared local root and sets
HF/Transformers offline flags before importing tokenizers.
"""
import argparse
import json
import os
import re
import resource
import sys
import time
from pathlib import Path

DIRECTIONS = {"en-zh", "zh-en"}
DIRECTION_ALIASES = {"enToZh": "en-zh", "zhToEn": "zh-en"}

def emit(value):
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def peak_rss_bytes():
    return resource.getrusage(resource.RUSAGE_SELF).ru_maxrss


def normalize_direction(value):
    return DIRECTION_ALIASES.get(value, value)


def load_ms(start_ns):
    return (time.perf_counter_ns() - start_ns) / 1e6


class Small100Adapter:
    """SMALL100: [tgt_lang] + spm(source) + </s>; decoder starts from eos."""

    def __init__(self, args):
        import ctranslate2
        import sentencepiece  # noqa: F401  (imported by tokenization_small100)
        import transformers

        source = args.root / "source"
        model_dir = args.root / ("ct2-" + args.compute_type)
        if not source.is_dir():
            raise RuntimeError("small100 source dir is missing: %s" % source)
        if not (model_dir / "model.bin").is_file():
            raise RuntimeError("small100 CT2 model is missing: %s" % (model_dir / "model.bin"))
        sys.path.insert(0, str(source))
        import tokenization_small100  # noqa: E402

        self.tokenizers = {}
        self.tokenization_module = tokenization_small100
        self.source = source
        for direction in ("en-zh", "zh-en"):
            self._tokenizer(direction)
        self.translator = ctranslate2.Translator(
            str(model_dir),
            device="cpu",
            compute_type=args.compute_type,
            inter_threads=1,
            intra_threads=args.threads,
        )
        self.versions = {
            "ctranslate2": ctranslate2.__version__,
            "sentencepiece": sentencepiece.__version__,
            "transformers": transformers.__version__,
        }
        self.identity = {
            "backend": "small100",
            "adapter": "small100",
            "repository": "alirezamsh/small100",
            "revision": "8ab680e26a596d2e3d2d2d17ae0f68df1037328c",
            "modelDir": str(model_dir),
            "sourceDir": str(source),
            "computeType": args.compute_type,
            "threads": args.threads,
            "beam": args.beam,
            "maxDecodingLength": args.max_decoding_length,
            "protocol": "tgt_lang encoder prefix; decoder starts from eos",
        }

    def _tokenizer(self, direction):
        tokenizer = self.tokenizers.get(direction)
        if tokenizer is None:
            target = direction.split("-")[-1]
            tokenizer = self.tokenization_module.SMALL100Tokenizer.from_pretrained(
                str(self.source), tgt_lang=target
            )
            self.tokenizers[direction] = tokenizer
        return tokenizer

    def _encode(self, tokenizer, text):
        ids = tokenizer(text, return_attention_mask=False)["input_ids"]
        if not ids:
            raise ValueError("empty tokenizer output")
        lang_id = tokenizer.get_lang_id(tokenizer.tgt_lang)
        if ids[0] != lang_id:
            raise ValueError("SMALL100 target-language prefix missing")
        if ids[-1] != tokenizer.eos_token_id:
            raise ValueError("SMALL100 source suffix eos missing")
        tokens = tokenizer.convert_ids_to_tokens(ids)
        prefix = [tokenizer.convert_ids_to_tokens([tokenizer.eos_token_id])[0]]
        return ids, tokens, prefix

    def _decode(self, tokenizer, tokens):
        specials = {"</s>", "<pad>", "<unk>"}
        ids = tokenizer.convert_tokens_to_ids([t for t in tokens if t not in specials])
        text = tokenizer.decode(ids, skip_special_tokens=True)
        return text.strip(), len([t for t in tokens if t not in specials])

    def translate(self, case):
        direction = normalize_direction(case.get("direction"))
        if not re.match(r"^[a-z]{2,3}-[a-z]{2,3}$", direction or ""):
            raise ValueError("unsupported direction: %s" % case.get("direction"))
        source = case.get("source", "")
        if not source.strip():
            raise ValueError("empty input is not a translation case")
        tokenizer = self._tokenizer(direction)
        start = time.perf_counter_ns()
        cpu_start = time.process_time_ns()
        ids, tokens, prefix = self._encode(tokenizer, source)
        encoded = time.perf_counter_ns()
        result = self.translator.translate_batch(
            [tokens],
            target_prefix=[prefix],
            max_batch_size=1,
            batch_type="examples",
            beam_size=self.identity["beam"],
            max_decoding_length=self.identity["maxDecodingLength"],
            return_scores=True,
        )[0]
        generated = time.perf_counter_ns()
        out_tokens = result.hypotheses[0]
        text, output_tokens = self._decode(tokenizer, out_tokens)
        end = time.perf_counter_ns()
        truncated = len([t for t in out_tokens if t not in ("</s>", "<pad>", "<unk>")]) >= self.identity["maxDecodingLength"]
        return {
            "id": case.get("id"),
            "direction": direction,
            "kind": case.get("kind"),
            "source": source,
            "output": text,
            "inputTokens": len(ids),
            "outputTokens": output_tokens,
            "sourceUnknownTokens": ids.count(tokenizer.unk_token_id),
            "truncated": truncated,
            "generated": bool(text) and not truncated,
            "score": float(result.scores[0]) if getattr(result, "scores", None) else None,
            "encodeMs": (encoded - start) / 1e6,
            "generateMs": (generated - encoded) / 1e6,
            "decodeMs": (end - generated) / 1e6,
            "totalMs": (end - start) / 1e6,
            "cpuMs": (time.process_time_ns() - cpu_start) / 1e6,
            "peakRssBytes": peak_rss_bytes(),
        }


class QuickmtAdapter:
    """quickmt: source spm -> append </s>; target spm decode; one model per direction."""

    def __init__(self, args):
        import ctranslate2
        import sentencepiece

        direction = normalize_direction(args.direction)
        if direction not in DIRECTIONS:
            raise RuntimeError("quickmt needs a concrete --direction en-zh|zh-en")
        model_dir = args.root / ("quickmt-" + direction)
        if not (model_dir / "model.bin").is_file():
            raise RuntimeError("quickmt model is missing: %s" % (model_dir / "model.bin"))
        if not (model_dir / "src.spm.model").is_file() or not (model_dir / "tgt.spm.model").is_file():
            raise RuntimeError("quickmt sentencepiece files are missing: %s" % model_dir)
        self.direction = direction
        self.src_spm = sentencepiece.SentencePieceProcessor(
            model_file=str(model_dir / "src.spm.model")
        )
        self.tgt_spm = sentencepiece.SentencePieceProcessor(
            model_file=str(model_dir / "tgt.spm.model")
        )
        self.translator = ctranslate2.Translator(
            str(model_dir),
            device="cpu",
            compute_type=args.compute_type,
            inter_threads=1,
            intra_threads=args.threads,
        )
        self.versions = {
            "ctranslate2": ctranslate2.__version__,
            "sentencepiece": sentencepiece.__version__,
        }
        self.identity = {
            "backend": "quickmt",
            "adapter": "quickmt",
            "model": "quickmt-" + direction,
            "direction": direction,
            "modelDir": str(model_dir),
            "computeType": args.compute_type,
            "threads": args.threads,
            "beam": args.beam,
            "maxDecodingLength": args.max_decoding_length,
            "protocol": "src spm + </s>; tgt spm decode",
        }

    def translate(self, case):
        direction = normalize_direction(case.get("direction"))
        if direction != self.direction:
            raise ValueError(
                "quickmt worker %s cannot translate %s" % (self.direction, case.get("direction"))
            )
        source = case.get("source", "")
        if not source.strip():
            raise ValueError("empty input is not a translation case")
        start = time.perf_counter_ns()
        cpu_start = time.process_time_ns()
        pieces = self.src_spm.encode(source, out_type=str) + ["</s>"]
        encoded = time.perf_counter_ns()
        result = self.translator.translate_batch(
            [pieces],
            max_batch_size=1,
            batch_type="examples",
            beam_size=self.identity["beam"],
            max_decoding_length=self.identity["maxDecodingLength"],
            return_scores=True,
        )[0]
        generated = time.perf_counter_ns()
        out_tokens = result.hypotheses[0]
        text = self.tgt_spm.decode(out_tokens).strip()
        end = time.perf_counter_ns()
        output_tokens = len([t for t in out_tokens if t != "</s>"])
        truncated = output_tokens >= self.identity["maxDecodingLength"]
        return {
            "id": case.get("id"),
            "direction": direction,
            "kind": case.get("kind"),
            "source": source,
            "output": text,
            "inputTokens": len(pieces),
            "outputTokens": output_tokens,
            "sourceUnknownTokens": pieces.count(self.src_spm.id_to_piece(self.src_spm.unk_id())),
            "truncated": truncated,
            "generated": bool(text) and not truncated,
            "score": float(result.scores[0]) if getattr(result, "scores", None) else None,
            "encodeMs": (encoded - start) / 1e6,
            "generateMs": (generated - encoded) / 1e6,
            "decodeMs": (end - generated) / 1e6,
            "totalMs": (end - start) / 1e6,
            "cpuMs": (time.process_time_ns() - cpu_start) / 1e6,
            "peakRssBytes": peak_rss_bytes(),
        }


def build_adapter(args):
    if args.backend == "small100":
        return Small100Adapter(args)
    if args.backend == "quickmt":
        return QuickmtAdapter(args)
    raise RuntimeError("unknown backend: %s" % args.backend)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backend", choices=["small100", "quickmt"], required=True)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--direction", default="both")
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--compute-type", default="int8")
    parser.add_argument("--beam", type=int, default=1)
    parser.add_argument("--max-decoding-length", type=int, default=256)
    args = parser.parse_args()

    for key in ["OMP_NUM_THREADS", "MKL_NUM_THREADS", "OPENBLAS_NUM_THREADS", "VECLIB_MAXIMUM_THREADS"]:
        os.environ[key] = str(args.threads)
    os.environ.update(
        {
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "TOKENIZERS_PARALLELISM": "false",
            "OMP_WAIT_POLICY": "PASSIVE",
            "KMP_BLOCKTIME": "0",
        }
    )

    process_start = time.perf_counter()
    load_start = time.perf_counter_ns()
    try:
        adapter = build_adapter(args)
        if "torch" in sys.modules:
            raise RuntimeError("CTranslate2 runtime must be isolated from PyTorch/OpenMP")
        ready = {
            "event": "ready",
            "pid": os.getpid(),
            "backend": args.backend,
            "direction": args.direction,
            "identity": adapter.identity,
            "versions": adapter.versions,
            "modelLoadMs": load_ms(load_start),
            "processStartToReadyMs": (time.perf_counter() - process_start) * 1000.0,
            "peakRssBytes": peak_rss_bytes(),
        }
        emit(ready)
    except Exception as error:
        emit(
            {
                "event": "load_error",
                "backend": args.backend,
                "direction": args.direction,
                "error": repr(error),
                "peakRssBytes": peak_rss_bytes(),
            }
        )
        return 2

    for line in sys.stdin:
        try:
            request = json.loads(line)
        except Exception as error:
            emit({"event": "protocol_error", "error": repr(error)})
            continue
        if request.get("event") == "stop":
            emit({"event": "stopped", "peakRssBytes": peak_rss_bytes()})
            break
        phase = request.get("phase", "measure")
        cases = request.get("cases") or []
        for case in cases:
            try:
                row = adapter.translate(case)
                emit({"event": "result", "phase": phase, **row})
            except Exception as error:
                emit(
                    {
                        "event": "result",
                        "phase": phase,
                        "id": case.get("id"),
                        "direction": normalize_direction(case.get("direction")),
                        "kind": case.get("kind"),
                        "source": case.get("source"),
                        "generated": False,
                        "error": repr(error),
                        "errorType": type(error).__name__,
                        "peakRssBytes": peak_rss_bytes(),
                    }
                )
        emit({"event": "request_done", "phase": phase, "count": len(cases)})
    return 0


if __name__ == "__main__":
    sys.exit(main())
