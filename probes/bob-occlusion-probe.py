#!/usr/bin/env python3
"""Bob 候选窗遮挡证据探针（只读桌面证据采集，结束恢复输入源与焦点）。

目的：Gogaku 候选窗在 Bob（翻译应用，自建浮窗层级较高）输入框中的真实层叠证据。
判定用 CGWindowList 前后序（对象事实），截图仅供人工复核；不做像素推断。

前提：Bob 是菜单栏翻译应用，输入框只存在于其弹窗内。运行前必须先由人
（或 GUI 自动化）唤起 Bob 输入弹窗并把焦点放进输入框；本探针不负责唤起。
若屏上只有 Bob 的 1×1 辅助窗（弹窗未打开），探针拒绝投键并退出码 4。

流程：
1. 构建探针宿主，切换输入源到 Gogaku（结束恢复原输入源与前台应用）；
2. 断言前台为 Bob 且存在面积可用的 Bob 窗口（bundle 级守卫，不匹配立即中止，不投键）；
3. 投递 nihc 四键（真实 CGEvent，经 IMK 进入组合）；
4. 记录 GogakuInput 候选窗与 Bob 窗口在 CGWindowList 屏上列表中的相对序、层级、bounds；
5. Esc 取消组合，清空 Bob 输入框（Cmd+A Delete），恢复环境。

用法：python3 probes/bob-occlusion-probe.py --report <json> --shots <dir>
退出码：0＝采集完成（遮挡与否看 JSON 字段）；5＝前台身份断言失败；2＝环境失败。
"""
import argparse
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))

import first_key_regression as fkr  # noqa: E402

BOB_BUNDLE = 'com.hezongyidev.Bob'


def osa(script, timeout=25):
    result = subprocess.run(['osascript', '-'], input=script, text=True,
                            capture_output=True, timeout=timeout, env=fkr.ENV)
    if result.returncode != 0:
        raise fkr.HostError(f'osascript 失败：{result.stderr.strip()[:200]}')
    return result.stdout.strip()


def window_inventory():
    """屏上窗口清单（前台到后台）：owner、层、bounds、窗口号。Swift 单探针，字段稳定。"""
    swift = r'''
import AppKit
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for (i, w) in list.enumerated() {
    let owner = w["kCGWindowOwnerName"] as? String ?? ""
    let layer = w["kCGWindowLayer"] as? Int ?? -1
    let number = w["kCGWindowNumber"] as? Int ?? -1
    let name = (w["kCGWindowName"] as? String ?? "").replacingOccurrences(of: "\t", with: " ")
    let bounds = w["kCGWindowBounds"] as? [String: Any] ?? [:]
    let b = "\(bounds["X"] ?? 0),\(bounds["Y"] ?? 0),\(bounds["Width"] ?? 0),\(bounds["Height"] ?? 0)"
    let pid = w["kCGWindowOwnerPID"] as? Int ?? -1
    print("\(i)\t\(owner)\t\(pid)\t\(layer)\t\(number)\t\(name)\t\(b)")
}
'''
    result = subprocess.run(['swift', '-'], input=swift, text=True,
                            capture_output=True, timeout=120, env=fkr.ENV)
    if result.returncode != 0:
        raise fkr.HostError(f'窗口清单失败：{result.stderr.strip()[:200]}')
    rows = []
    for line in result.stdout.splitlines():
        parts = line.split('\t')
        if len(parts) >= 7:
            rows.append({'index': int(parts[0]), 'owner': parts[1], 'pid': int(parts[2]),
                         'layer': int(parts[3]), 'number': int(parts[4]),
                         'name': parts[5], 'bounds': parts[6]})
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--shots', type=Path, required=True)
    parser.add_argument('--composition', default='nihc')
    parser.add_argument('--settle', type=float, default=1.2, help='投键后等待面板渲染（秒）')
    args = parser.parse_args()

    driver = fkr.Driver()
    checks = []
    failures = 0
    try:
        ready = driver.build()
        state = driver.ask(op='select', id=fkr.SOURCE)
        if state.get('source') != fkr.SOURCE:
            print(f'输入源切换失败：当前 {state.get("source")!r}')
            return 2
        checks.append({'check': '输入源已切换到 Gogaku', 'ok': True})
        # 驱动自激活会关掉 Bob 弹窗：必须在驱动就绪后再唤起，并立刻断言＋投键。
        osa('tell application "System Events" to tell process "Bob"\n  click menu bar item 1 of menu bar 2\n  delay 0.3\n  click menu item "输入翻译" of menu 1 of menu bar item 1 of menu bar 2\nend tell')
        time.sleep(1.2)
        osa(f'tell application id "{BOB_BUNDLE}" to activate')
        time.sleep(0.6)
        info = driver.ax(op='check', marker='')
        front = info.get('frontBundle') or ''
        if front != BOB_BUNDLE:
            print(f'前台不是 Bob（{front!r}），中止，不投键')
            return 5
        pid = int(info.get('pid') or 0)
        bob_windows = [r for r in window_inventory()
                       if r['pid'] == pid and r['bounds'] not in ('', '0,0,0,0')
                       and int(float(r['bounds'].split(',')[2])) > 100
                       and int(float(r['bounds'].split(',')[3])) > 60]
        if not bob_windows:
            print('Bob 输入弹窗未打开（屏上无面积可用的 Bob 窗口）；请先唤起 Bob 输入弹窗并聚焦输入框')
            return 4
        checks.append({'check': '前台身份断言通过（Bob，弹窗在屏）', 'ok': True,
                       'detail': f'pid={pid}, windows={len(bob_windows)}'})
        # 组合键入：每个字母一次 combo 调用（宿主原生节奏）。
        for ch in args.composition:
            driver.ask(op='combo', steps=[[{'key': ch}]],
                       guard={'bundle': BOB_BUNDLE, 'pid': pid, 'marker': ''})
            time.sleep(0.15)
        time.sleep(args.settle)
        rows = window_inventory()
        bob_rows = [r for r in rows if r['pid'] == pid]
        panel_rows = [r for r in rows if r['owner'] == 'GogakuInput']
        panel = panel_rows[0] if panel_rows else None
        bob_front = bob_rows[0] if bob_rows else None
        occluded = bool(panel and bob_front and bob_front['index'] < panel['index'])
        report = {
            'schema': 'gogaku.bob-occlusion.v1',
            'capturedAt': fkr.now_iso(),
            'composition': args.composition,
            'inputSource': {'id': fkr.SOURCE,
                            'installedSHA256': fkr.sha256_file(fkr.INSTALLED_BINARY)},
            'bobWindow': bob_front, 'bobWindows': bob_rows[:4],
            'panelWindow': panel, 'panelWindows': panel_rows[:4],
            'occluded': occluded,
            'verdict': ('Bob 窗口在候选窗之前（遮挡）' if occluded else
                        ('候选窗在 Bob 之前（不遮挡）' if panel and bob_front else
                         '候选窗未出现在屏上清单（组合可能未建立）')),
            'windowOrder': [{'index': r['index'], 'owner': r['owner'], 'layer': r['layer'],
                             'number': r['number'], 'bounds': r['bounds']}
                            for r in rows[:12]],
            'checks': checks, 'failures': failures,
        }
        args.shots.mkdir(parents=True, exist_ok=True)
        shot = args.shots / 'bob-composition-full.png'
        subprocess.run(['screencapture', '-x', str(shot)], check=False, env=fkr.ENV)
        report['screenshot'] = str(shot)
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(json.dumps({'verdict': report['verdict'], 'occluded': occluded,
                          'panel': report['panelWindow'], 'bob': report['bobWindow'],
                          'screenshot': str(shot)}, ensure_ascii=False))
        # 取消组合并清空 Bob 输入框，不留测试内容。
        driver.ask(op='combo', steps=[[{'key': 'esc'}]],
                   guard={'bundle': BOB_BUNDLE, 'pid': pid, 'marker': ''})
        time.sleep(0.3)
        driver.ask(op='combo', steps=[[{'key': 'a', 'command': True}, {'key': 'delete'}]],
                   guard={'bundle': BOB_BUNDLE, 'pid': pid, 'marker': ''})
        return 0
    except fkr.GuardError as error:
        print(f'前台身份断言失败，中止（未投递的按键不再补发）：{error}')
        return 5
    finally:
        driver.close()


if __name__ == '__main__':
    raise SystemExit(main())
