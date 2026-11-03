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
        beam = int(case.get("beam") or self.identity["beam"])
        num_hypotheses = max(1, min(int(case.get("numHypotheses") or 1), beam))
        start = time.perf_counter_ns()
        cpu_start = time.process_time_ns()
        ids, tokens, prefix = self._encode(tokenizer, source)
        encoded = time.perf_counter_ns()
        result = self.translator.translate_batch(
            [tokens],
            target_prefix=[prefix],
            max_batch_size=1,
            batch_type="examples",
            beam_size=beam,
            num_hypotheses=num_hypotheses,
            max_decoding_length=self.identity["maxDecodingLength"],
            return_scores=True,
            return_end_token=True,
        )[0]
        generated = time.perf_counter_ns()
        candidates = []
        for out_tokens, score in zip(result.hypotheses, result.scores):
            text, output_tokens = self._decode(tokenizer, out_tokens)
            ended = bool(out_tokens) and out_tokens[-1] in ("</s>",)
            candidates.append({
                "text": text,
                "score": float(score),
                "tokens": output_tokens,
                "ended": ended,
                "truncated": not ended,
            })
        out_tokens = result.hypotheses[0]
        text, output_tokens = self._decode(tokenizer, out_tokens)
        end = time.perf_counter_ns()
        truncated = not candidates[0]["ended"] if candidates else True
        return {
            "id": case.get("id"),
            "direction": direction,
            "kind": case.get("kind"),
            "source": source,
            "output": text,
            "beam": beam,
            "numHypotheses": num_hypotheses,
            "candidates": candidates,
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
            "scoring": bool(args.enable_scoring),
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
        beam = int(case.get("beam") or self.identity["beam"])
        num_hypotheses = max(1, min(int(case.get("numHypotheses") or 1), beam))
        start = time.perf_counter_ns()
        cpu_start = time.process_time_ns()
        pieces = self.src_spm.encode(source, out_type=str) + ["</s>"]
        encoded = time.perf_counter_ns()
        result = self.translator.translate_batch(
            [pieces],
            max_batch_size=1,
            batch_type="examples",
            beam_size=beam,
            num_hypotheses=num_hypotheses,
            max_decoding_length=self.identity["maxDecodingLength"],
            return_scores=True,
            return_end_token=True,
        )[0]
        generated = time.perf_counter_ns()
        candidates = []
        for out_tokens, score in zip(result.hypotheses, result.scores):
            ended = bool(out_tokens) and out_tokens[-1] in ("</s>",)
            candidates.append({
                "text": self.tgt_spm.decode([t for t in out_tokens if t != "</s>"]).strip(),
                "score": float(score),
                "tokens": len([t for t in out_tokens if t != "</s>"]),
                "ended": ended,
                "truncated": not ended,
            })
        out_tokens = result.hypotheses[0]
        text = self.tgt_spm.decode([t for t in out_tokens if t != "</s>"]).strip()
        end = time.perf_counter_ns()
        output_tokens = len([t for t in out_tokens if t != "</s>"])
        truncated = not candidates[0]["ended"] if candidates else True
        return {
            "id": case.get("id"),
            "direction": direction,
            "kind": case.get("kind"),
            "source": source,
            "output": text,
            "beam": beam,
            "numHypotheses": num_hypotheses,
            "candidates": candidates,
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


class ReverseScorer:
    """用 quickmt 反向给候选打分（只评分，不自由生成回译）。

    中→英方向：候选是英语，用 quickmt-en-zh 以候选英语为源、原中文为目标，
    分数即「把候选英语译回中文能还原原文」的可信度。
    英→中方向：候选是中文，用 quickmt-zh-en 以候选中文为源、原英语为目标。
    """

    def __init__(self, root, compute_type, threads):
        import ctranslate2
        import sentencepiece

        self.ctranslate2 = ctranslate2
        self.sentencepiece = sentencepiece
        self.root = root
        self.compute_type = compute_type
        self.threads = threads
        self.models = {}

    def _model(self, direction):
        model = self.models.get(direction)
        if model is not None:
            return model
        model_dir = self.root / ("quickmt-" + direction)
        if not (model_dir / "model.bin").is_file():
            raise RuntimeError("reverse scoring model missing: %s" % model_dir)
        model = {
            "translator": self.ctranslate2.Translator(
                str(model_dir), device="cpu", compute_type=self.compute_type,
                inter_threads=1, intra_threads=self.threads),
            "src": self.sentencepiece.SentencePieceProcessor(
                model_file=str(model_dir / "src.spm.model")),
            "tgt": self.sentencepiece.SentencePieceProcessor(
                model_file=str(model_dir / "tgt.spm.model")),
        }
        self.models[direction] = model
        return model

    def score(self, case):
        """case: {direction, source, candidates: [str]}

        源/目标是「候选译文 → 原文」，模型取候选语言那一边的 quickmt。
        """
        direction = normalize_direction(case.get("direction"))
        if direction not in DIRECTIONS:
            raise ValueError("reverse scoring needs a concrete direction")
        reverse = "en-zh" if direction == "zh-en" else "zh-en"
        source = case.get("source", "")
        candidates = case.get("candidates") or []
        if not source.strip() or not candidates:
            return {"event": "score_result", "id": case.get("id"), "scores": []}
        model = self._model(reverse)
        tgt_batch = [model["tgt"].encode(source, out_type=str)] * len(candidates)
        src_batch = [model["src"].encode(text, out_type=str) + ["</s>"] for text in candidates]
        start = time.perf_counter_ns()
        results = model["translator"].score_batch(
            src_batch, tgt_batch, max_batch_size=len(src_batch), batch_type="examples")
        elapsed = (time.perf_counter_ns() - start) / 1e6
        scores = []
        for result in results:
            log_probs = list(result.log_probs)
            total = float(sum(log_probs))
            count = len(log_probs) or 1
            scores.append({
                "logProb": total,
                "tokens": len(log_probs),
                "normalized": total / count,
            })
        return {
            "event": "score_result",
            "id": case.get("id"),
            "direction": direction,
            "reverseModel": "quickmt-" + reverse,
            "scores": scores,
            "scoreMs": elapsed,
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
    parser.add_argument("--enable-scoring", action="store_true",
                        help="quickmt worker 额外加载双向模型做反向评分")
    parser.add_argument("--scoring-only", action="store_true",
                        help="只提供 score 请求（反向评分 worker）")
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
    scorer = None
    try:
        adapter = None if args.scoring_only else build_adapter(args)
        if args.backend == "quickmt" and args.enable_scoring:
            scorer = ReverseScorer(args.root, args.compute_type, args.threads)
            for direction in sorted(DIRECTIONS):
                scorer._model(direction)
        if "torch" in sys.modules:
            raise RuntimeError("CTranslate2 runtime must be isolated from PyTorch/OpenMP")
        ready = {
            "event": "ready",
            "pid": os.getpid(),
            "backend": args.backend,
            "direction": args.direction,
            "identity": adapter.identity if adapter is not None else {
                "backend": "quickmt",
                "adapter": "reverse-scorer",
                "models": ["quickmt-en-zh", "quickmt-zh-en"],
                "computeType": args.compute_type,
                "threads": args.threads,
                "protocol": "candidate -> original scoring via score_batch",
            },
            "versions": adapter.versions if adapter is not None else {"ctranslate2": __import__("ctranslate2").__version__},
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
        if request.get("event") == "score":
            try:
                emit(scorer.score(request))
            except Exception as error:
                emit({"event": "score_result", "id": request.get("id"), "error": repr(error),
                      "scores": []})
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
