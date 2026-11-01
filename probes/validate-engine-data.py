#!/usr/bin/env python3
"""引擎数据集成烟测：真实 resources/english-words.txt 与 resources/gloss.tsv
在共享核心中的加载、英文候选合并、gloss 注释与缺文件降级。
判定：GLOSS hello…（你好 注释）、ENGLISH 1 company（英文排中文首位之后）、
DEGRADED_COMMIT 你好（缺数据文件时降级上屏正常）。
用法：python3 probes/validate-engine-data.py
"""
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CPP = r"""#include "gogaku_core.h"
#include <cstdio>
#include <cstring>
#include <string>
static GcSnapshot *send(GcNormalSession *s, int kind, const char *text, int64_t t) {
    GcKeyEvent ev{}; ev.kind = kind; ev.text = text; ev.app = "data.app"; ev.field = "f"; ev.time_ms = t;
    GcSnapshot *snap = nullptr; gc_normal_handle(s, &ev, &snap); return snap;
}
static void type_and_check(GcNormalSession *s, const char *keys, int64_t &t) {
    for (const char *p = keys; *p; ++p) {
        GcSnapshot *x = send(s, GC_EV_TEXT, std::string(1, *p).c_str(), ++t);
        if (x && *(p + 1) == 0) {
            for (size_t i = 1; i < x->count && i < 5; ++i) {
                if (x->candidates[i].kind == GC_CAND_ENGLISH) {
                    printf("ENGLISH %zu %s\n", i, x->candidates[i].text);
                    break;
                }
            }
            for (size_t i = 0; i < x->count; ++i) {
                if (strcmp(x->candidates[i].text, "你好") == 0 && x->candidates[i].gloss[0] != 0) {
                    printf("GLOSS %s\n", x->candidates[i].gloss);
                    break;
                }
            }
        }
        gc_snapshot_free(x);
    }
}
int main() {
    const char *dataDir = getenv("GOGAKU_CORE_TEST_DATA");
    std::string base = dataDir ? dataDir : std::string(getenv("HOME")) + "/Library/Caches/Gogaku/libime-1.1.17/data";
    std::string cwd = getenv("GOGAKU_REPO") ? getenv("GOGAKU_REPO") : ".";
    GcNormalConfig cfg{};
    std::string dict = base + "/sc.dict", model = base + "/zh_CN.lm";
    std::string eng = cwd + "/resources/english-words.txt", gl = cwd + "/resources/gloss.tsv";
    cfg.dict_path = dict.c_str(); cfg.model_path = model.c_str();
    cfg.english_words_path = eng.c_str(); cfg.gloss_path = gl.c_str();
    cfg.scheme = GC_SCHEME_XIAOHE; cfg.freq_enabled = 1; cfg.english_enabled = 1;
    GcNormalSession *s = nullptr; char err[256] = {0};
    if (gc_normal_session_create(&cfg, &s, err, sizeof err)) { printf("CREATE-FAIL %s\n", err); return 2; }
    int64_t t = 0;
    type_and_check(s, "nihc", t);
    { GcSnapshot *x = send(s, GC_EV_ESC, nullptr, ++t); gc_snapshot_free(x); }
    type_and_check(s, "compa", t);
    { GcSnapshot *x = send(s, GC_EV_ESC, nullptr, ++t); gc_snapshot_free(x); }
    gc_normal_session_destroy(s);
    cfg.english_words_path = nullptr; cfg.gloss_path = nullptr;
    s = nullptr;
    if (gc_normal_session_create(&cfg, &s, err, sizeof err)) { printf("DEGRADE-FAIL %s\n", err); return 2; }
    for (const char *p = "nihc"; *p; ++p) { GcSnapshot *y = send(s, GC_EV_TEXT, std::string(1, *p).c_str(), ++t); gc_snapshot_free(y); }
    GcSnapshot *y = send(s, GC_EV_SPACE, nullptr, ++t);
    printf("DEGRADED_COMMIT %s\n", y ? y->commit : "?");
    gc_snapshot_free(y);
    gc_normal_session_destroy(s);
    return 0;
}
"""


def main() -> int:
    src = Path(tempfile.mkdtemp(prefix="gogaku-engdata-")) / "smoke.cpp"
    src.write_text(CPP)
    binary = src.with_suffix("")
    env = {"GOGAKU_REPO": str(ROOT), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
           "HOME": str(Path.home()),
           "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer"}
    build = subprocess.run(["xcrun", "c++", "-std=gnu++20",
                            f"-I{ROOT}/native/GogakuCore/include",
                            str(src), "-L", str(ROOT / ".build/core"),
                            "-lgogaku_core", "-Wl,-rpath", str(ROOT / ".build/core"),
                            "-o", str(binary)], env=env, capture_output=True, text=True)
    if build.returncode != 0:
        print(f"构建失败：{build.stderr[-400:]}")
        return 2
    run = subprocess.run([str(binary)], env=env, capture_output=True, text=True, timeout=120)
    print(run.stdout, end="")
    failures = []
    if not run.stdout.startswith("GLOSS hello"):
        failures.append("你好 gloss 未出现（应为 hello; hi）")
    if "ENGLISH 1 company" not in run.stdout:
        failures.append("英文候选未在中文首位之后（company 应排第二）")
    if "DEGRADED_COMMIT 你好" not in run.stdout:
        failures.append("缺数据文件时降级上屏异常")
    if failures:
        print("数据集成烟测失败：", "；".join(failures))
        return 2
    print("数据集成烟测：全部通过 — PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
