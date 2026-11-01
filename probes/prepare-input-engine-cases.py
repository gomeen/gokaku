#!/usr/bin/env python3
"""Generate the frozen, synthetic Xiaohe cases; no third-party lexicon is used."""
import argparse
import json
from pathlib import Path

# Standard Xiaohe pinyin layout; zero-initial vowels use the vowel key twice
# or the literal two-letter syllable. ui/iu/un follow spelling, not expansion.
FINALS = {
    "a": "a", "o": "o", "e": "e", "i": "i", "u": "u", "v": "v",
    "ai": "d", "ei": "w", "ao": "c", "ou": "z", "an": "j", "en": "f",
    "ang": "h", "eng": "g", "ong": "s", "ia": "x", "ie": "p", "iao": "n",
    "iu": "q", "ian": "m", "in": "b", "iang": "l", "ing": "k", "iong": "s",
    "ua": "x", "uo": "o", "uai": "k", "ui": "v", "uan": "r", "un": "y",
    "uang": "l", "ue": "t", "ve": "t",
}
INITIALS = {"zh": "v", "ch": "i", "sh": "u"}
ZERO = {"a": "aa", "o": "oo", "e": "ee", "ai": "ai", "ei": "ei", "ao": "ao",
        "ou": "ou", "an": "an", "en": "en", "ang": "ah", "eng": "eg", "er": "er"}

# id, stratum, accepted full outputs, explicit pronunciation.
SCENARIOS = [
    ("hello", "daily", ["你好"], "ni hao"),
    ("thanks", "daily", ["谢谢"], "xie xie"),
    ("goodbye", "daily", ["再见"], "zai jian"),
    ("morning", "daily", ["早上好"], "zao shang hao"),
    ("no-problem", "daily", ["没关系"], "mei guan xi"),
    ("i-know", "daily", ["我知道"], "wo zhi dao"),
    ("think", "daily", ["想一想"], "xiang yi xiang"),
    ("available", "daily", ["今天晚上有空"], "jin tian wan shang you kong"),
    ("eat", "daily", ["你吃饭了吗"], "ni chi fan le ma"),
    ("learn", "learning", ["学习英语"], "xue xi ying yu"),
    ("want-learn", "learning", ["我想学英语"], "wo xiang xue ying yu"),
    ("no-understanding", "learning", ["我没有听懂"], "wo mei you ting dong"),
    ("repeat", "learning", ["请再说一遍"], "qing zai shuo yi bian"),
    ("meeting", "work", ["开会"], "kai hui"),
    ("tomorrow-meeting", "work", ["明天下午开会"], "ming tian xia wu kai hui"),
    ("send-file", "work", ["请把文件发给我"], "qing ba wen jian fa gei wo"),
    ("next-week", "work", ["我们下周再讨论"], "wo men xia zhou zai tao lun"),
    ("plan", "work", ["这个方案可以"], "zhe ge fang an ke yi"),
    ("send-email", "work", ["发送邮件"], "fa song you jian"),
    ("negation", "work", ["不要发送邮件"], "bu yao fa song you jian"),
    ("long-work", "long", ["请把明天下午开会的时间发给我"], "qing ba ming tian xia wu kai hui de shi jian fa gei wo"),
    ("long-learning", "long", ["我想每天花一点时间学习英语"], "wo xiang mei tian hua yi dian shi jian xue xi ying yu"),
    ("database", "technical", ["数据库"], "shu ju ku"),
    ("ai", "technical", ["人工智能"], "ren gong zhi neng"),
    ("quantum", "technical", ["量子计算"], "liang zi ji suan"),
    ("xiaohe", "technical", ["小鹤双拼"], "xiao he shuang pin"),
    ("nvidia", "entity", ["英伟达"], "ying wei da"),
    ("tsmc", "entity", ["台积电"], "tai ji dian"),
    ("lark", "entity", ["飞书"], "fei shu"),
    ("deepseek", "entity", ["深度求索"], "shen du qiu suo"),
    ("meituan", "entity", ["美团"], "mei tuan"),
    ("unconstrained-huiyi", "ambiguous", ["会议", "回忆"], "hui yi"),
    ("bank", "polyphone", ["银行"], "yin hang"),
    ("walk", "polyphone", ["行走"], "xing zou"),
    ("chongqing", "polyphone", ["重庆"], "chong qing"),
    ("music", "polyphone", ["音乐"], "yin yue"),
    ("safety", "zero-initial", ["安全"], "an quan"),
    ("occasionally", "zero-initial", ["偶尔"], "ou er"),
    ("scheme", "zero-initial", ["方案"], "fang an"),
    ("love", "zero-initial", ["爱好"], "ai hao"),
]


def encode_syllable(syllable):
    if syllable in ZERO:
        return ZERO[syllable]
    initial = syllable[:2] if syllable[:2] in INITIALS else syllable[:1]
    final = syllable[len(initial):]
    if not final or final not in FINALS:
        raise ValueError("Unsupported or misspelled pinyin syllable: " + syllable)
    return INITIALS.get(initial, initial) + FINALS[final]


def make_cases():
    cases = []
    for case_id, stratum, targets, pinyin in SCENARIOS:
        keys = "".join(encode_syllable(s) for s in pinyin.split())
        cases.append({"id": case_id, "stratum": stratum, "targets": targets,
                      "pinyin": pinyin, "keys": keys, "syllables": len(pinyin.split())})
    known = {"ni hao": "nihc", "kai hui": "kdhv", "wo xiang xue ying yu": "woxlxtykyu"}
    for pinyin, expected in known.items():
        actual = "".join(encode_syllable(s) for s in pinyin.split())
        if actual != expected:
            raise ValueError((pinyin, actual, expected))
    return {"version": 1, "scope": "Handwritten synthetic regression set, not a general quality benchmark",
            "created_before_measurement": True, "layout": "Xiaohe pinyin (not shape codes)",
            "cases": cases}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).with_name("input-engine-cases.json"))
    args = parser.parse_args()
    args.output.write_text(json.dumps(make_cases(), ensure_ascii=False, indent=2) + "\n")
    print(str(args.output))
