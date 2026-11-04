#!/usr/bin/env python3
"""small100 学习翻译 worker 的协议与固定样例回归（2026-11-03 质量试验）。

子命令：
  protocol  仅用系统 python3：回显断言、invalid_request 全路径、缺权重
            model_missing、非法行存活（不需要 ctranslate2／模型）。
  samples   用装配好的 venv python＋权重：两方向各 3 条固定样例输出必须与
            probes/results/translation-backends/requests.jsonl 探针记录一致
            （worker 为 gate 协议 SMALL100Tokenizer tgt_lang 口径，同 beam=1 同
            2 线程同 INT8，CT2 贪心解码确定性对齐，2026-11-04 实测逐字一致；
            探针 max_decoding_length=96 对短句输出与 256 等价），
            并记录 milliseconds（延迟抽测只记录，不建基准）。

运行：
  python3 scripts/validate-learning-small100.py protocol
  .../translation/small100/venv/bin/python scripts/validate-learning-small100.py samples \\
      --python .../translation/small100/venv/bin/python --root .../translation/small100
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKER = ROOT / "scripts" / "small100_worker.py"
TIMEOUT = 60  # 首译含权重懒加载（small100 约 1–2s，冷盘更长）

# 与 probes 记录一致的固定样例（beam1、INT8、2 线程；runId 20261103T012307Z）。
SAMPLES = [
    # zh→en
    {"direction": "zhToEn", "source": "我还没吃饭。", "expected": "I have not eaten yet."},
    {"direction": "zhToEn", "source": "不要删除备份。", "expected": "Do not delete backup."},
    {"direction": "zhToEn", "source": "早上好。", "expected": "Good morning."},
    # en→zh
    {"direction": "enToZh", "source": "Alice will meet Bob in Beijing on Friday.",
     "expected": "艾丽丝星期五将在北京见面。"},
    {"direction": "enToZh", "source": "Could you speak more slowly?",
     "expected": "你能说话慢吗?"},
    {"direction": "enToZh", "source": "Do I have to book in advance?",
     "expected": "我需要提前预订吗?"},
]


class Worker:
    def __init__(self, python, args):
        self.process = subprocess.Popen(
            [str(python), str(WORKER), *[str(a) for a in args]],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self.assertions = 0

    def send_raw(self, line: bytes):
        self.process.stdin.write(line + b"\n")
        self.process.stdin.flush()

    def request(self, payload, timeout=TIMEOUT):
        self.send_raw(json.dumps(payload, ensure_ascii=False).encode("utf-8"))
        return self.read_response(timeout)

    def read_response(self, timeout=TIMEOUT):
        deadline = time.monotonic() + timeout
        line = self.process.stdout.readline()
        assert line, "worker 在超时前退出（stderr 已弃用，检查协议）"
        assert time.monotonic() <= deadline, "worker 响应超时"
        return json.loads(line.decode("utf-8"))

    def check(self, name, condition, detail=""):
        self.assertions += 1
        marker = "PASS" if condition else "FAIL"
        print(f"  [{marker}] {name}" + (f"：{detail}" if detail and not condition else ""),
              flush=True)
        if not condition:
            self.close()
            raise SystemExit(f"断言失败：{name} {detail}")

    def close(self):
        try:
            self.process.stdin.close()
        except Exception:
            pass
        self.process.wait(timeout=10)


def request_for(source, direction="enToZh", protocol_version=1, resource="quickmt-ct2-dev"):
    return {
        "protocolVersion": protocol_version,
        "id": "11111111-2222-3333-4444-555555555555",
        "stamp": {"session": "aaaa", "focus": 7, "composition": "bbbb", "revision": 3,
                  "mode": "learning", "direction": direction},
        "sourceID": "english:full",
        "source": source,
        "resource": resource,
    }


def cmd_protocol(args):
    print("small100 worker 协议回归（系统 python，无模型）", flush=True)
    assertions = 0
    sys.path.insert(0, str(WORKER.parent))
    import small100_worker as worker
    strip_cases = [
        ("我想去北京 。 ”", "我想去北京"),
        ("晚饭后你想出去散步吗 ? ”", "晚饭后你想出去散步吗"),
        ("你好。", "你好。"),
        ("Hello World.", "Hello World."),
        ("Hello World. ”", "Hello World."),
        ("How are you ?", "How are you"),
        ("", ""),
    ]
    for source, expected in strip_cases:
        actual = worker.strip_trailing_orphan_punctuation(source)
        assertions += 1
        if actual != expected:
            print(f"FAIL strip {source!r} -> {actual!r}（期望 {expected!r}）", flush=True)
            raise SystemExit(1)
    print(f"  [PASS] 尾部残片剥离 {len(strip_cases)} 例", flush=True)
    # 方向映射与超限异常类型（纯逻辑）。
    assert worker.DIRECTIONS == {"zhToEn": ("zh", "en"), "enToZh": ("en", "zh")}
    assertions += 1
    print("  [PASS] 方向映射 enToZh=en→zh、zhToEn=zh→en", flush=True)
    with tempfile.TemporaryDirectory() as tmp:
        worker = Worker(args.python, ["--root", tmp, "--beam", "1"])
        try:
            worker.send_raw(b"not-json-at-all")
            worker.send_raw(b"[1,2,3]")
            reply = worker.request(request_for("hello"))
            worker.check("非法 JSON 行被丢弃且进程存活", reply.get("error") == "model_missing",
                         json.dumps(reply, ensure_ascii=False))
            assertions += 1
            for field, value in [("protocolVersion", 1),
                                 ("id", "11111111-2222-3333-4444-555555555555"),
                                 ("sourceID", "english:full"),
                                 ("source", "hello"),
                                 ("resource", "quickmt-ct2-dev")]:
                worker.check(f"回显 {field}", reply.get(field) == value, repr(reply.get(field)))
            worker.check("stamp 原样回传", reply.get("stamp", {}).get("direction") == "enToZh"
                         and reply["stamp"].get("mode") == "learning"
                         and reply["stamp"].get("focus") == 7)
            worker.check("milliseconds 为非负数值",
                         isinstance(reply.get("milliseconds"), (int, float))
                         and reply["milliseconds"] >= 0)
            # invalid_request 全路径。
            reply = worker.request(request_for("hi", protocol_version=2))
            worker.check("协议版本不符 → invalid_request", reply.get("error") == "invalid_request")
            reply = worker.request(request_for(""))
            worker.check("空输入 → invalid_request", reply.get("error") == "invalid_request")
            reply = worker.request(request_for("x" * 513))
            worker.check("超 512 标量 → invalid_request", reply.get("error") == "invalid_request")
            reply = worker.request(request_for("hi", direction="zhZh"))
            worker.check("非法方向 → invalid_request", reply.get("error") == "invalid_request")
            assertions += 4
            print(f"  [PASS] invalid_request 4 路径", flush=True)
            # 合法请求（缺权重）→ model_missing，进程存活可续答。
            reply = worker.request(request_for("hello", direction="zhToEn"))
            worker.check("缺权重 → model_missing", reply.get("error") == "model_missing")
            reply = worker.request(request_for("hello"))
            worker.check("model_missing 后进程存活可续答", reply.get("error") == "model_missing")
            assertions += 2
        finally:
            worker.close()
    print(json.dumps({"suite": "protocol", "assertions": assertions}, ensure_ascii=False), flush=True)


def cmd_samples(args):
    print("small100 worker 固定样例回归（装配权重）", flush=True)
    worker = Worker(args.python, ["--root", args.root, "--beam", args.beam,
                                  "--threads", str(args.threads)])
    milliseconds = []
    try:
        for case in SAMPLES:
            started = time.perf_counter()
            reply = worker.request(request_for(case["source"], direction=case["direction"]))
            elapsed = (time.perf_counter() - started) * 1000
            actual = reply.get("target")
            worker.check(f"{case['direction']} {case['source']!r} → {case['expected']!r}",
                         reply.get("error") is None and actual == case["expected"],
                         f"实际 {actual!r} error={reply.get('error')}")
            milliseconds.append(round(elapsed, 1))
    finally:
        worker.close()
    print(json.dumps({"suite": "samples", "assertions": len(SAMPLES),
                      "milliseconds": milliseconds}, ensure_ascii=False), flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p1 = sub.add_parser("protocol", help="协议回归（系统 python3 即可）")
    p1.add_argument("--python", default=sys.executable)
    p2 = sub.add_parser("samples", help="固定样例回归（需装配好的权重）")
    p2.add_argument("--python", required=True, help="装配 venv 的 python")
    p2.add_argument("--root", default=str(Path.home() / "Library/Application Support/Gogaku/translation/small100"))
    p2.add_argument("--beam", type=int, default=1)
    p2.add_argument("--threads", type=int, default=2)
    args = parser.parse_args()
    if args.command == "protocol":
        cmd_protocol(args)
    else:
        cmd_samples(args)


if __name__ == "__main__":
    main()
