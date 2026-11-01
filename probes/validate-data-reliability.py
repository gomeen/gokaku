#!/usr/bin/env python3
"""数据可靠性验证：调频数据（model.userlm／learned.txt）在真实文件路径下的表现。

场景与判定：
1. 写入中途 SIGKILL：worker 反复「学习→flush」，随机时刻强杀；随后 verify
   会话必须能创建并完成输入＋flush（文件要么完好旧内容、要么完好新内容，
   损坏时核心自动备份为 .corrupt 并重建）。不因半截文件不可用。
   （.tmp 残留允许：下次写入会覆盖。）
2. 损坏注入：向 model.userlm 写入垃圾后，会话创建必须成功（备份＋重建），
   不得让输入法不可用。custom-words.tsv／learned.txt 损坏路径由核心单测
   （corrupt_userlm、custom_store）覆盖，不在此重复。
3. 删除不复活：学习→flush→Control＋Backspace 删词→flush→重载，学习词
   标记必须消失。

用法：python3 probes/validate-data-reliability.py [--rounds 40]
前提：.build/core 已构建（gogaku_data_reliability_worker）；
GOGAKU_CORE_TEST_DATA 或默认缓存提供出厂词典／模型。
"""
import argparse
import random
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKER = ROOT / ".build/core/gogaku_data_reliability_worker"

failures: list[str] = []


def check(ok: bool, what: str) -> None:
    print(("  ok  " if ok else "  FAIL") + f" {what}")
    if not ok:
        failures.append(what)


def run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def verify(user_dir: Path) -> tuple[bool, str]:
    r = run([str(WORKER), "--verify", str(user_dir)], timeout=60)
    return r.returncode == 0, r.stdout.strip() + r.stderr.strip()


def kill_during_write(rounds: int) -> None:
    print("场景 1：写入中途 SIGKILL")
    rng = random.Random(20261031)
    for i in range(rounds):
        user_dir = Path(tempfile.mkdtemp(prefix="gogaku-rel-"))
        proc = subprocess.Popen(
            [str(WORKER), str(user_dir), "10000"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(rng.uniform(0.05, 0.45))
        if proc.poll() is None:
            proc.send_signal(signal.SIGKILL)
        proc.wait()
        ok, message = verify(user_dir)
        leftovers = sorted(p.name for p in user_dir.iterdir())
        check(ok, f"第{i + 1}轮强杀后可恢复（文件：{leftovers}）")
        shutil.rmtree(user_dir, ignore_errors=True)


def corrupt_injection() -> None:
    print("场景 2：model.userlm 损坏注入")
    user_dir = Path(tempfile.mkdtemp(prefix="gogaku-rel-corrupt-"))
    (user_dir / "model.userlm").write_bytes(bytes(range(256)) * 16 + b"\x00garbage-not-a-model")
    ok, message = verify(user_dir)
    check(ok, f"损坏后会话可用（{message}）")
    check((user_dir / "model.userlm.corrupt").exists(), "损坏文件已备份为 .corrupt")
    check((user_dir / "model.userlm").exists(), "model.userlm 已重建（flush 写回）")
    shutil.rmtree(user_dir, ignore_errors=True)


DELETE_PROBE = r'''
#include "gogaku_core.h"
#include <cstdio>
#include <string>
static GcSnapshot *send(GcNormalSession *s, int kind, const char *text = nullptr) {
    GcKeyEvent ev{}; ev.kind = kind; ev.text = text; ev.app = "rel.app"; ev.field = "f";
    GcSnapshot *snap = nullptr; gc_normal_handle(s, &ev, &snap); return snap;
}
static void type(GcNormalSession *s, const char *keys) {
    for (const char *p = keys; *p; ++p) { GcSnapshot *x = send(s, GC_EV_TEXT, std::string(1, *p).c_str()); gc_snapshot_free(x); }
}
int main() {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir ? dataDir : std::string(getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    GcNormalConfig cfg{}; std::string dict = base + "/sc.dict", model = base + "/zh_CN.lm";
    cfg.dict_path = dict.c_str(); cfg.model_path = model.c_str();
    cfg.user_dir = "__USER_DIR__"; cfg.freq_enabled = 1;
    GcNormalSession *s = nullptr; char err[256] = {0};
    if (gc_normal_session_create(&cfg, &s, err, sizeof err)) { printf("CREATE-FAIL %s\n", err); return 2; }
    type(s, "nihc");
    { GcSnapshot *x = send(s, GC_EV_SPACE); gc_snapshot_free(x); }   // 学习 你好
    if (gc_normal_flush(s)) { printf("FLUSH-FAIL\n"); return 2; }
    type(s, "nih");
    { GcSnapshot *x = send(s, GC_EV_TEXT, "c");
      if (x == nullptr || x->count == 0 || !x->candidates[0].deletable) { printf("NO-LEARNED\n"); return 2; }
      gc_snapshot_free(x); }
    { GcSnapshot *x = send(s, GC_EV_DELETE_WORD); gc_snapshot_free(x); }  // 删除
    if (gc_normal_flush(s)) { printf("FLUSH-FAIL\n"); return 2; }
    gc_normal_session_destroy(s);
    // 重载：nihc 首候选不得再带学习词标记。
    s = nullptr;
    if (gc_normal_session_create(&cfg, &s, err, sizeof err)) { printf("CREATE-FAIL %s\n", err); return 2; }
    type(s, "nihc");
    int resurrected = 0;
    { GcSnapshot *x = send(s, GC_EV_DOWN);
      if (x) for (size_t i = 0; i < x->count; ++i) if (x->candidates[i].kind == GC_CAND_LEARNED) resurrected = 1;
      gc_snapshot_free(x); }
    gc_normal_session_destroy(s);
    printf(resurrected ? "RESURRECTED\n" : "VERIFY-OK\n");
    return resurrected ? 2 : 0;
}
'''


def delete_not_resurrected() -> None:
    print("场景 3：删除学习词后不被迟到写入复活")
    user_dir = Path(tempfile.mkdtemp(prefix="gogaku-rel-delete-"))
    code_path = user_dir / "probe.cpp"
    code_path.write_text(DELETE_PROBE.replace("__USER_DIR__", str(user_dir)))
    binary = user_dir / "probe"
    build = run(["c++", "-std=gnu++20", f"-I{ROOT}/native/GogakuCore/include",
                 str(code_path), "-L", str(ROOT / ".build/core"), "-lgogaku_core",
                 "-Wl,-rpath", str(ROOT / ".build/core"), "-o", str(binary)])
    if build.returncode != 0:
        check(False, f"删除复活探针构建失败：{build.stderr[-300:]}")
    else:
        r = run([str(binary)], timeout=120)
        check(r.returncode == 0 and "VERIFY-OK" in r.stdout,
              f"删除后重载不复活（{r.stdout.strip()}）")
    shutil.rmtree(user_dir, ignore_errors=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rounds", type=int, default=40)
    args = parser.parse_args()
    if not WORKER.exists():
        print(f"SKIP: 先构建核心（{WORKER} 不存在）")
        return 0
    kill_during_write(args.rounds)
    corrupt_injection()
    delete_not_resurrected()
    if failures:
        print(f"数据可靠性：{len(failures)} 项失败 — FAIL")
        return 2
    print("数据可靠性：全部通过 — PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
