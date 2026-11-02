#!/usr/bin/env python3
"""按住 Ctrl+Space 触发输入源切换 HUD 并连拍（桌面验收专用）。

短暂按住系统「选择上一个输入源」快捷键（Ctrl+Space，symbolic 60）让切换
HUD 浮层出现，同时后台连拍全屏。结束用 TIS 静默恢复 Gogaku 输入源。
用法：python3 probes/hud-hold-capture.py --tag dark --frames 14
"""
import argparse
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))
import first_key_regression as fkr  # noqa: E402

OUT = ROOT / 'docs/validation/verify/round-build6/hud'


def sh(*cmd):
    return subprocess.run(list(cmd), capture_output=True, text=True, env=fkr.ENV)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--tag', required=True)
    parser.add_argument('--frames', type=int, default=14)
    parser.add_argument('--hold', type=float, default=0.8)
    args = parser.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)

    stop = threading.Event()
    paths = []

    def burst():
        for i in range(args.frames):
            path = OUT / f'hudhold-{args.tag}-{i}.png'
            sh('screencapture', '-x', str(path))
            paths.append(str(path))
            if stop.wait(0.25):
                break

    worker = threading.Thread(target=burst, daemon=True)
    worker.start()
    script = f'''
tell application "System Events"
  key down control
  key down space
  delay {args.hold}
  key up space
  key up control
end tell
'''
    time.sleep(0.5)
    sh('osascript', '-e', script)
    time.sleep(1.5)
    stop.set()
    worker.join(timeout=args.frames * 0.3 + 5)
    sh('swift', str(ROOT / 'scripts/tis-select.swift'), fkr.SOURCE)
    print(f'{len(paths)} 帧：hudhold-{args.tag}-*.png')


if __name__ == '__main__':
    raise SystemExit(main())
