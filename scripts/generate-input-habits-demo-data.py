#!/usr/bin/env python3
"""为 input-habits-demo.html 预生成候选数据（仅用于可丢弃原型）。

用本机已构建的 GogakuEngine 桥接（libime 1.1.17 出厂数据）对小鹤编码列表
逐前缀生成真实出厂候选（未开启个人调频），每个前缀最多 27 个（3 页），
另对分段选择场景生成"选中部分候选后的剩余编码"候选。数据嵌入单文件 HTML。

- 生成结果只供 demo 使用，不进入输入法包。
- 英文候选与英文释义是 HTML 内的手写示例数据，不在此脚本生成。

用法：
  python3 scripts/generate-input-habits-demo-data.py

前置条件：
  .build/native/libGogakuEngine.dylib          （cmake --build .build/native）
  ~/Library/Caches/Gogaku/libime-1.1.17/data/  （sc.dict、zh_CN.lm）
"""

import ctypes
import json
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DYLIB = ROOT / ".build/native/libGogakuEngine.dylib"           # 小鹤双拼（正式桥接）
DYLIB_FULL = ROOT / ".build/demo/libGogakuEngineFull.dylib"    # 全拼（demo 专用变体，双拼解析关闭）
DATA_DIR = Path.home() / "Library/Caches/Gogaku/libime-1.1.17/data"
TEMPLATE = ROOT / "prototypes/input-habits-demo.template.html"
OUT_HTML = ROOT / "prototypes/input-habits-demo.html"
OUT_JSON = ROOT / "prototypes/input-habits-demo-data.json"

PAGE_SIZE = 9
MAX_PAGES = 3
MAX_KEYS = 512

# 小鹤编码 + 预期首位候选应包含的字（仅做生成健全性检查，不进入页面数据）。
XIAOHE_ENCODINGS = [
    ("nihc", "你好"),
    ("jbtm", "今天"),
    ("kdhv", "开会"),
    ("hvyi", "会议"),
    ("woxlxtykyu", "我想学英语"),
    ("wojbtm", "我今天"),
    ("jbtmxxwu", "今天"),
    ("pj", "盘"),
    ("wo", "我"),
    ("xmxm", "显现"),
    ("xtxi", "学"),
    ("ykyu", "英"),
    ("ceui", "测"),
    ("uurufa", "输"),
    ("pjyn", "番禺你"),
    ("ulpj", "双"),
    ("dmnc", "电"),
    ("ubji", "上半场"),
    ("vsgo", "中"),
    ("mwgo", "美"),
    ("mytm", "蔓越莓"),
    ("xxwu", "下"),
    ("keyi", "可"),
    ("xmzl", "现在来"),
    ("yihb", "以后不"),
    ("rfhb", "任何不"),
    ("soyi", "所"),
    ("djui", "但"),
    ("hlui", "皇室"),
    ("ynww", "有内外"),
    ("xtuf", "学神"),
    ("lcui", "老"),
    ("tsxt", "同"),
    ("bhvu", "帮"),
    ("anvl", "安"),
    ("nihcukjb", "你好帅近"),
    # 英文候选演示编码：中文候选仍是真实出厂输出，英文排序规则在页面内演示。
    ("hello", None),
    ("comp", None),
    ("compa", None),
    ("meet", None),
]

# 分段选择轨迹：type 全编码 → 选中"text 且消费 raw_length 个键"的部分候选 → 捕获暂存态
# → 选中剩余第 next_index 个候选完成提交（生成器校验提交串）。键名不带方案前缀（两方案 base 不重名）。
SCHEMES = [
    {
        "prefix": "T:",
        "dylib": DYLIB,
        "label": "小鹤双拼",
        "encodings": XIAOHE_ENCODINGS,
        "traces": [
            {"base": "wojbtm", "select": {"text": "我", "raw_length": 2}, "next_index": 0},
            {"base": "woxlxtykyu", "select": {"text": "我想", "raw_length": 4}, "next_index": 0},
        ],
    },
    {
        "prefix": "Q:",
        "dylib": DYLIB_FULL,
        "label": "全拼",
        "encodings": [
            ("nihao", "你好"), ("jintian", "今天"), ("kaihui", "开会"), ("huiyi", "会议"),
            ("woxiangxueyingyu", "我想学英语"), ("wojintian", "我"), ("jintianxiawu", "今天"),
            ("pan", "盘"), ("wo", "我"), ("xiexie", "谢"), ("xuexi", "学习"), ("yingyu", "英语"),
            ("ceshi", "测试"), ("shurufa", "输入"), ("pinyin", "拼"), ("shuangpin", "双"),
            ("diannao", "电脑"), ("shouji", "手机"), ("zhongguo", "中国"), ("meiguo", "美国"),
            ("mingtian", "明天"), ("xiawu", "下午"), ("keyi", "可以"), ("xianzai", "现在"),
            ("yihou", "以后"), ("ranhou", "然后"), ("suoyi", "所以"), ("danshi", "但"),
            ("haishi", "还"), ("yinwei", "因"), ("xuesheng", "学生"), ("laoshi", "老师"),
            ("tongxue", "同学"), ("bangzhu", "帮助"), ("anzhuang", "安"), ("nihaoshijie", "你好"),
            ("hello", None), ("comp", None), ("compa", None), ("meet", None),
        ],
        "traces": [
            {"base": "wojintian", "select": {"text": "我", "raw_length": 2}, "next_index": 0},
            {"base": "woxiangxueyingyu", "select": {"text": "我想", "raw_length": 7}, "next_index": 0},
        ],
    },
]


class GECandidate(ctypes.Structure):
    _fields_ = [
        ("text", ctypes.c_char_p),
        ("index", ctypes.c_size_t),
        ("raw_start", ctypes.c_size_t),
        ("raw_length", ctypes.c_size_t),
        ("completes", ctypes.c_int),
    ]


class GESnapshot(ctypes.Structure):
    _fields_ = [
        ("raw", ctypes.c_char_p),
        ("preedit", ctypes.c_char_p),
        ("selected", ctypes.c_char_p),
        ("commit", ctypes.c_char_p),
        ("candidates", ctypes.POINTER(GECandidate)),
        ("count", ctypes.c_size_t),
        ("total", ctypes.c_size_t),
        ("page", ctypes.c_size_t),
        ("selected_length", ctypes.c_size_t),
        ("composing", ctypes.c_int),
    ]


OPS = {"peek": 0, "type": 1, "backspace": 2, "select": 3, "cancel": 4, "page": 5, "cursor": 6}


class Engine:
    def __init__(self, dylib=DYLIB):
        lib = ctypes.CDLL(str(dylib))
        lib.ge_create.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_void_p)]
        lib.ge_command.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int64, ctypes.POINTER(ctypes.POINTER(GESnapshot))]
        lib.ge_snapshot_free.argtypes = [ctypes.POINTER(GESnapshot)]
        self.lib = lib
        self.handle = ctypes.c_void_p()
        rc = lib.ge_create(str(DATA_DIR / "sc.dict").encode(), str(DATA_DIR / "zh_CN.lm").encode(), ctypes.byref(self.handle))
        if rc != 0 or not self.handle:
            raise SystemExit("ge_create 失败：请先构建 .build/native/libGogakuEngine.dylib 并确认数据目录")

    def close(self):
        self.lib.ge_destroy(self.handle)

    def _cmd(self, op, arg=0):
        snap = ctypes.POINTER(GESnapshot)()
        rc = self.lib.ge_command(self.handle, OPS[op], arg, ctypes.byref(snap))
        if rc != 0:
            raise RuntimeError(f"ge_command {op} {arg} 失败 rc={rc}")
        c = snap.contents
        out = {
            "raw": c.raw.decode(),
            "preedit": c.preedit.decode(),
            "selected": c.selected.decode(),
            "commit": c.commit.decode(),
            "page": c.page,
            "total": c.total,
            "selectedLength": c.selected_length,
            "composing": bool(c.composing),
            "cands": [
                {
                    "t": c.candidates[i].text.decode(),
                    "i": c.candidates[i].index,
                    "rs": c.candidates[i].raw_start,
                    "rl": c.candidates[i].raw_length,
                    "c": bool(c.candidates[i].completes),
                }
                for i in range(c.count)
            ],
        }
        self.lib.ge_snapshot_free(snap)
        return out

    def type(self, keys):
        for ch in keys:
            if not ("a" <= ch <= "z"):
                raise ValueError(f"引擎只接受 a-z，收到 {ch!r}")
            self._cmd("type", ord(ch))

    def page(self, delta):
        self._cmd("page", delta)


def capture_pages(eng):
    """当前引擎状态下翻页捕获，最多 MAX_PAGES 页。"""
    pages = []
    seen_pages = set()
    for _ in range(MAX_PAGES):
        snap = eng._cmd("peek")
        if snap["page"] in seen_pages:
            break
        seen_pages.add(snap["page"])
        pages.append({"page": snap["page"], "cands": snap["cands"]})
        if len(pages) * PAGE_SIZE >= snap["total"] or not snap["cands"]:
            break
        eng.page(1)
    return pages


def state_meta(snap):
    return {"preedit": snap["preedit"], "selected": snap["selected"], "total": snap["total"], "selLen": snap["selectedLength"]}


def main():
    if not DYLIB.exists():
        raise SystemExit(f"缺少 {DYLIB}，先运行 cmake --build .build/native")
    if not (DATA_DIR / "sc.dict").exists():
        raise SystemExit(f"缺少出厂数据 {DATA_DIR}")

    states = {}
    traces_out = {}
    for scheme in SCHEMES:
        if not scheme["dylib"].exists():
            raise SystemExit(f"缺少 {scheme['dylib']}（全拼变体由 scripts 从正式桥接派生，见脚本头部说明）")
        eng = Engine(scheme["dylib"])
        print(f"方案 {scheme['label']}（{scheme['prefix']}…，{scheme['dylib'].name}）")
        try:
            for enc, expect in scheme["encodings"]:
                if not enc.isascii() or not enc.isalpha():
                    raise ValueError(enc)
                for n in range(1, len(enc) + 1):
                    eng._cmd("cancel")
                    prefix = enc[:n]
                    eng.type(prefix)
                    snap = eng._cmd("peek")
                    pages = capture_pages(eng)
                    key = scheme["prefix"] + prefix
                    if expect and n == len(enc):
                        top = pages[0]["cands"][0]["t"] if pages and pages[0]["cands"] else ""
                        if expect not in top:
                            print(f"  提示：{scheme['prefix']}{prefix} 首位候选 {top!r} 不含预期 {expect!r}")
                    states[key] = {**state_meta(snap), "pages": pages}
                print(f"  {enc}: {len(enc)} 个前缀，首位 {states[scheme['prefix'] + enc]['pages'][0]['cands'][0]['t']!r}")

            for tr in scheme["traces"]:
                base = tr["base"]
                eng._cmd("cancel")
                eng.type(base)
                sel_spec = tr["select"]
                snap = eng._cmd("peek")
                idx = next(
                    (c["i"] for c in snap["cands"] if c["t"] == sel_spec["text"] and c["rl"] == sel_spec["raw_length"]),
                    None,
                )
                if idx is None:
                    raise SystemExit(f"{base} 中未找到部分候选 {sel_spec}；请改用实际存在的候选")
                staged = eng._cmd("select", idx)
                pages = capture_pages(eng)
                key = f"{base}>{idx}"
                if not staged["selected"]:
                    raise SystemExit(f"{base}> {idx} 未进入暂存态")
                # 验证剩余首个候选可完成提交（页面 JS 用 暂存+候选文本 组合提交串）。
                finish = eng._cmd("select", tr["next_index"])
                commit = finish["commit"]
                if not commit:
                    raise SystemExit(f"{base}>{idx} 后选择第 {tr['next_index']} 个候选未产生提交")
                expect_commit = staged["selected"] + pages[0]["cands"][tr["next_index"]]["t"] if pages else ""
                if commit != expect_commit:
                    print(f"  提示：{key} 提交 {commit!r} 与 暂存+候选 {expect_commit!r} 不一致")
                traces_out[key] = {
                    "base": base,
                    "selectIndex": idx,
                    "stagedText": staged["selected"],
                    "nextIndex": tr["next_index"],
                    "commit": commit,
                    **state_meta(staged),
                    "pages": pages,
                }
                print(f"  轨迹 {key}: 暂存 {staged['selected']!r}，提交 {commit!r}，剩余候选 {staged['total']} 个")
        finally:
            eng.close()

    data = {
        "meta": {
            "source": "libime 1.1.17 出厂数据（sc.dict + zh_CN.lm），真实出厂顺序，未开启个人调频",
            "engine": "GogakuEngine 桥接（libime PinyinIME）：T: 前缀＝小鹤双拼（正式桥接），Q: 前缀＝全拼（demo 专用变体，双拼解析关闭）；展开拼音预编辑",
            "pageSize": PAGE_SIZE,
            "maxPages": MAX_PAGES,
            "script": "scripts/generate-input-habits-demo-data.py",
            "note": "候选来自预生成数据；超过 27 个（3 页）的部分未截入演示。英文候选与英文释义为页面内手写示例。",
        },
        "states": states,
        "traces": traces_out,
    }
    OUT_JSON.write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")

    if not TEMPLATE.exists():
        raise SystemExit(f"缺少模板 {TEMPLATE}")
    html = TEMPLATE.read_text(encoding="utf-8")
    marker = "/*__GOGAKU_DEMO_DATA__*/null"
    if marker not in html:
        raise SystemExit(f"模板中找不到数据占位符 {marker}")
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    for ch, esc in (("<", "\\u003c"), (">", "\\u003e"), ("&", "\\u0026"), ("\u2028", "\\u2028"), ("\u2029", "\\u2029")):
        payload = payload.replace(ch, esc)
    html = html.replace(marker, payload, 1)
    OUT_HTML.write_text(html, encoding="utf-8")
    print(f"已写入 {OUT_HTML}（{OUT_HTML.stat().st_size} 字节）与 {OUT_JSON}（{OUT_JSON.stat().st_size} 字节）")


if __name__ == "__main__":
    main()
