#!/usr/bin/env python3
"""quickmt 学习翻译 worker 的协议与固定样例回归（2026-11 开发版裁决验收项）。

子命令：
  protocol  仅用系统 python3：回显断言、invalid_request 全路径、缺权重
            model_missing、非法行存活（不需要 ctranslate2／模型）。
  samples   用装配好的 venv python＋权重：两方向各 3 条固定样例输出必须与
            probes/results/translation-backends/requests.jsonl 探针记录一致
            （同 beam=1 同 2 线程同 INT8，CT2 贪心解码确定性对齐），
            并记录 milliseconds（延迟抽测只记录，不建基准）。

运行：
  python3 scripts/validate-learning-translation.py protocol
  venv/bin/python scripts/validate-learning-translation.py samples \\
      --python .../translation/venv/bin/python --root .../translation
"""
import argparse
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKER = ROOT / "scripts" / "quickmt_worker.py"
TIMEOUT = 30

# 与 probes 记录一致的固定样例（beam1、INT8、2 线程；2026-11-03 runId 20261103T012307Z）。
SAMPLES = [
    # zh→en（quickmt-zh-en；风险集＋保留集轮次 1 记录）
    {"direction": "zhToEn", "source": "我还没吃饭。", "expected": "I haven't eaten yet."},
    {"direction": "zhToEn", "source": "不要删除备份。", "expected": "Do not delete backups."},
    {"direction": "zhToEn", "source": "早上好。", "expected": "Good morning."},
    # en→zh（quickmt-en-zh；同上）
    {"direction": "enToZh", "source": "Alice will meet Bob in Beijing on Friday.",
     "expected": "爱丽丝将于周五在北京与鲍勃见面。"},
    {"direction": "enToZh", "source": "Could you speak more slowly?",
     "expected": "能说得更慢一点吗?"},
    {"direction": "enToZh", "source": "Do I have to book in advance?",
     "expected": "我必须提前预订吗?"},
]


class Worker:
    def __init__(self, python, args):
        self.process = subprocess.Popen(
            [str(python), str(WORKER), *args],
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
    print("worker 协议回归（系统 python，无模型）", flush=True)
    assertions = 0
    # 尾部孤立标点残片剥离（纯函数，导入即可测；含「我想去北京 。 ”」类网页
    # 模式残片与 attached 正常标点不受影响的反向用例）。
    sys.path.insert(0, str(WORKER.parent))
    import quickmt_worker as worker
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
    with tempfile.TemporaryDirectory() as tmp:
        worker = Worker(args.python, ["--root", tmp, "--beam", "1"])
        try:
            # 非法行不杀死进程：随后请求仍被回答。
            worker.send_raw(b"not-json-at-all")
            worker.send_raw(b"[1,2,3]")
            reply = worker.request(request_for("hello"))
            worker.check("非法 JSON 行被丢弃且进程存活", reply.get("error") == "model_missing",
                         json.dumps(reply, ensure_ascii=False))
            assertions += 1
            # 回显断言：stamp/id/sourceID/source/resource 原样，附 milliseconds。
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
            worker.check("缺权重按 model_missing 拒绝", reply.get("error") == "model_missing"
                         and reply.get("target") is None)
            # invalid_request 全路径。
            cases = [
                ("空输入", request_for("")),
                ("纯空白输入", request_for("   \n\t")),
                ("超 512 标量", request_for("a" * 513)),
                ("协议版本≠1", request_for("hello", protocol_version=2)),
                ("非 learning 方向", request_for("hello", direction="xxYy")),
            ]
            for name, payload in cases:
                reply = worker.request(payload)
                worker.check(f"invalid_request：{name}", reply.get("error") == "invalid_request",
                             json.dumps(reply, ensure_ascii=False)[:200])
            # 空白差异不误伤：合法长度的 512 标量请求进入模型路径（缺权重→model_missing）。
            reply = worker.request(request_for("a" * 512))
            worker.check("512 标量边界放行到模型路径", reply.get("error") == "model_missing")
        finally:
            worker.close()
        assertions = worker.assertions
    print(f"协议回归通过（{assertions} 项断言）", flush=True)


def cmd_samples(args):
    print("worker 固定样例回归（venv python＋pinned 权重，beam1，每方向预热一次）", flush=True)
    worker = Worker(args.python, ["--root", str(args.root), "--beam", "1"])
    latencies = []
    try:
        # 预热与探针同口径（probes/README：每方向预热一次；预热耗时含首次
        # 模型加载与冷盘读取，不计入逐句延迟，仅记录）。
        for direction in ("zhToEn", "enToZh"):
            warm = worker.request(request_for("warm up", direction=direction))
            print(f"  预热 {direction}：{warm.get('milliseconds', -1):.0f}ms"
                  f"（含模型加载；error={warm.get('error')}）", flush=True)
            if warm.get("error"):
                raise SystemExit(f"预热失败：{warm['error']}（权重未装配？先运行准备脚本）")
        for sample in SAMPLES:
            reply = worker.request(request_for(sample["source"], direction=sample["direction"]))
            ok = reply.get("error") is None and reply.get("target") == sample["expected"]
            worker.check(f"{sample['direction']} {sample['source']!r}",
                         ok, f"期望 {sample['expected']!r}，实际 "
                             f"{reply.get('target')!r}（error={reply.get('error')}）")
            ms = reply.get("milliseconds")
            latencies.append(ms)
            print(f"        {ms:.1f}ms", flush=True)
        slow = [m for m in latencies if m >= 500]
        worker.check("beam1 全部 <500ms", not slow, f"超预算：{slow}")
    finally:
        worker.close()
    print(f"固定样例回归通过（{worker.assertions} 项断言，"
          f"中位 {sorted(latencies)[len(latencies)//2]:.1f}ms）", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    p1 = sub.add_parser("protocol", help="协议回归（系统 python3 即可）")
    p1.add_argument("--python", default=sys.executable)
    p1.set_defaults(func=cmd_protocol)
    p2 = sub.add_parser("samples", help="固定样例回归（需装配好的权重）")
    p2.add_argument("--python", type=Path, required=True, help="装配 venv 的 python")
    p2.add_argument("--root", type=Path,
                    default=Path.home() / "Library/Application Support/Gogaku/translation")
    p2.set_defaults(func=cmd_samples)
    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
