#!/usr/bin/env python3
"""设置应用六页截图驱动（900×620 与 760×520 × 浅／深外观，桌面验收专用）。

通过 orca computer 点击侧栏页签，AppleScript 调整窗口尺寸，screencapture -l
按窗口截图。结束恢复原外观。
用法：python3 probes/settings-gui-capture.py
"""
import json
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'docs/validation/verify/round-build6/settings'

PAGES = [(3, 'resources'), (4, 'normal-input'), (5, 'custom-words'),
         (6, 'shortcuts'), (7, 'privacy'), (8, 'records')]
SIZES = [(900, 620, '900x620'), (760, 520, '760x520')]


def sh(*cmd, check=False):
    return subprocess.run(list(cmd), capture_output=True, text=True, check=check, env=None)


def window_id() -> int:
    swift = '''
import AppKit
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as! [[String: Any]]
for w in list {
    if (w["kCGWindowOwnerName"] as? String) == "Gogaku Settings",
       let number = w["kCGWindowNumber"] as? Int {
        print(number)
        break
    }
}
'''
    result = sh('swift', '-')
    result = subprocess.run(['swift', '-'], input=swift, text=True, capture_output=True)
    out = result.stdout.strip()
    return int(out) if out.isdigit() else 0


def set_size(w: int, h: int):
    sh('osascript', '-e', f'''
tell application "System Events" to tell process "Gogaku Settings"
  set position of window 1 to {{80, 60}}
  set size of window 1 to {{{w}, {h}}}
end tell''')
    time.sleep(0.6)


def set_appearance(dark: bool):
    value = 'true' if dark else 'false'
    sh('osascript', '-e',
       f'tell application "System Events" to tell appearance preferences to set dark mode to {value}')
    time.sleep(1.2)


def orca(*args):
    result = sh('orca', 'computer', *args, '--json')
    if result.returncode != 0:
        print('orca error:', result.stderr[:200])
    return result.stdout


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    original_dark = 'Dark' in sh('defaults', 'read', '-g', 'AppleInterfaceStyle').stdout
    manifest = {'sizes': [s[2] for s in SIZES], 'pages': [p[1] for p in PAGES], 'shots': []}
    try:
        sh('open', '-g', str(Path.home() / 'Applications/Gogaku Settings.app'))
        time.sleep(2.5)
        wid = window_id()
        if not wid:
            print('找不到设置窗口')
            return 2
        for dark in (True, False):
            appearance = 'dark' if dark else 'light'
            set_appearance(dark)
            for w, h, size in SIZES:
                set_size(w, h)
                for index, page in PAGES:
                    out = orca('click', '--app', 'Gogaku Settings', '--element-index', str(index))
                    time.sleep(0.7)
                    path = OUT / f'{page}-{size}-{appearance}.png'
                    sh('screencapture', '-x', '-o', f'-l{wid}', str(path))
                    ok = path.exists() and path.stat().st_size > 20000
                    manifest['shots'].append({'page': page, 'size': size, 'appearance': appearance,
                                              'file': str(path.relative_to(ROOT)), 'ok': ok})
                    print(f'{page}-{size}-{appearance}: {"ok" if ok else "FAIL"}')
        manifest['windowId'] = wid
        (OUT / 'capture-plan.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2))
        bad = [s for s in manifest['shots'] if not s['ok']]
        print(f'完成：{len(manifest["shots"])} 张，失败 {len(bad)}')
        return 1 if bad else 0
    finally:
        set_appearance(original_dark)


if __name__ == '__main__':
    raise SystemExit(main())
