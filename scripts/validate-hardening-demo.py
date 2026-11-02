#!/usr/bin/env python3
"""加固层处置效果验证：对真实模型失败输出逐条跑五件套检查，验证「错误译文不进入默认候选」。

输入：quickmt 2026-11-02 烟测观察到的失败片段（probes/results/quickmt-speed/report.md）
      ＋small100 门槛语义审阅的历史失败输出（probes/results/small100-gate/semantic-review.md）。
判定链：重复 → 时间 → 长度 → 脚本（繁体先归一再验）；任一拦截即回退原文，归一成功转候选。
输出：probes/results/quickmt-speed/hardening-demo.json（含逐条处置记录）。
"""
import ctypes
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DYLIB = ROOT / ".build/core/libgogaku_core.dylib"
OUT = ROOT / "probes/results/quickmt-speed/hardening-demo.json"

# (来源, 方向, 源文, 模型原始输出, 已知失败说明)
CASES = [
    ("quickmt-2026-11-02", "en-zh", "attend a meeting", "参加会议 会议", "尾部重复"),
    ("quickmt-2026-11-02", "en-zh", "good morning", "早上好 好 好", "词元复读"),
    ("quickmt-2026-11-02", "en-zh", "see you tomorrow", "明天见,你明天见", "短语复现"),
    ("quickmt-2026-11-02", "en-zh", "thanks", "謝謝你!", "繁体漂移"),
    ("quickmt-2026-11-02", "en-zh", "how are you", "你怎麼會這樣?", "繁体＋语义跑偏"),
    ("quickmt-2026-11-02", "en-zh", "I cannot open the attachment, please send it again.",
     "我无法打开附件,请再寄。 联系方式", "尾部多余"),
    ("quickmt-2026-11-02", "en-zh", "Alice will meet Bob in Beijing on Friday.",
     "爱丽丝将于周五在北京与鲍勃见面。", "修复对照（应通过）"),
    ("quickmt-2026-11-02", "zh-en", "谢谢", "Thanks for the", "截断"),
    ("quickmt-2026-11-02", "zh-en", "我明天有一个会议。", "I have a meeting tomorrow.", "修复对照（应通过）"),
    ("small100-gate", "en-zh", "9 a.m. to 4 p.m.", "下午9点至下午4点", "时段翻转"),
    ("small100-gate", "en-zh", "The meeting has been moved to next Tuesday at 10:30 a.m. Please don't invite Alice.",
     "会议将于下周二下午10点30点,…", "时段翻转＋语病"),
    ("small100-gate", "en-zh", "attend a meeting", "參加會議", "繁体输出"),
    ("small100-gate", "en-zh", "Alice will meet Bob in Beijing on Friday.",
     "艾丽丝星期五将在北京见面。", "人名丢失（加固层不修，交专名层/审阅）"),
    ("small100-gate", "en-zh", "Gogaku v3.2.1", "古巴 v3.2.1", "品牌改写（交保护层/审阅）"),
    ("small100-gate", "en-zh", "qqxzzv", "Q" * 181, "乱码编造"),
]

LIB = None


def load_lib():
    global LIB
    import ctypes
    LIB = ctypes.CDLL(str(DYLIB))
    LIB.gc_translate_repeat_classify.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    LIB.gc_translate_repeat_classify.restype = ctypes.c_int32
    LIB.gc_translate_t2s.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                     ctypes.c_char_p, ctypes.c_size_t]
    LIB.gc_translate_t2s.restype = ctypes.c_size_t
    LIB.gc_translate_has_traditional.argtypes = [ctypes.c_char_p, ctypes.c_size_t]
    LIB.gc_translate_has_traditional.restype = ctypes.c_int32
    LIB.gc_translate_time_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                            ctypes.c_char_p, ctypes.c_size_t]
    LIB.gc_translate_time_check.restype = ctypes.c_int32
    LIB.gc_translate_script_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t, ctypes.c_char]
    LIB.gc_translate_script_check.restype = ctypes.c_int32
    LIB.gc_translate_length_check.argtypes = [ctypes.c_char_p, ctypes.c_size_t,
                                              ctypes.c_char_p, ctypes.c_size_t]
    LIB.gc_translate_length_check.restype = ctypes.c_int32


def t2s(text: str) -> str:
    raw = text.encode("utf-8")
    needed = LIB.gc_translate_t2s(raw, len(raw), None, 0)
    buf = ctypes.create_string_buffer(needed)
    LIB.gc_translate_t2s(raw, len(raw), buf, needed)
    return buf.value.decode("utf-8")


def check(text: str, direction: str) -> dict:
    raw = text.encode("utf-8")
    expected_script = b"Z" if direction == "en-zh" else b"E"
    return {
        "repeat": LIB.gc_translate_repeat_classify(raw, len(raw)),
        "time": None,  # 需源文，在外层填
        "length": None,
        "script": LIB.gc_translate_script_check(raw, len(raw), expected_script),
    }


def main() -> int:
    if not DYLIB.exists():
        print("先构建核心：cmake --build .build/core", file=sys.stderr)
        return 1
    load_lib()
    results = []
    for origin, direction, source, output, note in CASES:
        s_raw = source.encode("utf-8")
        o_raw = output.encode("utf-8")
        expected_script = b"Z" if direction == "en-zh" else b"E"
        record = {
            "origin": origin, "direction": direction, "source": source,
            "rawOutput": output, "knownIssue": note,
            "checks": {
                "repeat": LIB.gc_translate_repeat_classify(o_raw, len(o_raw)),
                "time": LIB.gc_translate_time_check(s_raw, len(s_raw), o_raw, len(o_raw)),
                "length": LIB.gc_translate_length_check(s_raw, len(s_raw), o_raw, len(o_raw)),
                "script": LIB.gc_translate_script_check(o_raw, len(o_raw), expected_script),
            },
        }
        c = record["checks"]
        verdict = "candidate"
        fix = None
        if c["repeat"] >= 1 or c["time"] in (1, 2, 3) or c["length"] in (1, 2):
            verdict = "fallback-original"
        elif c["script"] != 0:
            fixed = t2s(output)
            f_raw = fixed.encode("utf-8")
            recheck = LIB.gc_translate_script_check(f_raw, len(f_raw), expected_script)
            if recheck == 0:
                verdict = "candidate-normalized"
                fix = fixed
            else:
                verdict = "fallback-original"
        record["verdict"] = verdict
        record["normalized"] = fix
        results.append(record)

    OUT.write_text(json.dumps({"dylib": str(DYLIB), "cases": results}, ensure_ascii=False, indent=1) + "\n")
    print(f"{'来源':14s} {'处置':10s} 修正  说明 / 源文")
    for r in results:
        mark = {"candidate": "候选", "candidate-normalized": "归一→候选",
                "fallback-original": "回退原文"}[r["verdict"]]
        print(f"{r['origin']:14s} {mark:8s} {(r['normalized'] or '')[:12]:12s} "
              f"{r['knownIssue']}｜{r['source'][:24]} → {r['rawOutput'][:18]}")
    ok = sum(1 for r in results if r["verdict"] != "candidate")
    print(f"\n共 {len(results)} 条：候选 {len(results) - ok}，归一 {sum(1 for r in results if r['verdict'] == 'candidate-normalized')}，"
          f"回退原文 {sum(1 for r in results if r['verdict'] == 'fallback-original')}（证据：{OUT}）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
