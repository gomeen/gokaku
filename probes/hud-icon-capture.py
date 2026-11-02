#!/usr/bin/env python3
"""HUD 图标截图序列（桌面验收专用，结束恢复外观、输入源与前台应用）。

按真实系统快捷键（Ctrl+Space，symbolic hotkey 60）切换输入源并连拍全屏，
供人工核对切换浮层（HUD）与菜单栏的 Gogaku 图标形态。浅／深外观各一轮，
结束恢复原外观、输入源 Gogaku 与前台应用。
"""
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'probes'))
import first_key_regression as fkr  # noqa: E402

OUT = ROOT / 'docs/validation/verify/round-build6/hud'
SOURCE = fkr.SOURCE


def sh(*cmd, check=False):
    return subprocess.run(list(cmd), capture_output=True, text=True, check=check, env=fkr.ENV)


def set_appearance(dark: bool):
    value = 'true' if dark else 'false'
    sh('osascript', '-e',
       f'tell application "System Events" to tell appearance preferences to set dark mode to {value}')
    time.sleep(1.2)


def current_appearance() -> bool:
    result = sh('defaults', 'read', '-g', 'AppleInterfaceStyle')
    return 'Dark' in result.stdout


def burst(tag: str, frames: int = 6, interval: float = 0.35):
    paths = []
    for i in range(frames):
        path = OUT / f'{tag}-{i}.png'
        sh('screencapture', '-x', str(path))
        paths.append(str(path))
        time.sleep(interval)
    return paths


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    original_dark = current_appearance()
    original_front = sh('osascript', '-e',
                        'tell application "System Events" to get name of first application process whose frontmost is true').stdout.strip()
    print(f'原外观：{"深色" if original_dark else "浅色"}；原前台：{original_front}')

    driver = fkr.Driver()
    frames = {}
    try:
        driver.build()
        state = driver.ask(op='select', id=SOURCE)
        assert state.get('source') == SOURCE, f'输入源切换失败：{state}'
        for appearance in ('dark', 'light'):
            set_appearance(dark=(appearance == 'dark'))
            # 真实系统快捷键切换（HUD 随切换浮现），连拍；随后用 TIS 静默切回。
            driver.ask(op='hotkey', modifier='control', code=49)
            frames[appearance + '-switch'] = burst(f'hud-{appearance}')
            time.sleep(0.8)
            driver.ask(op='select', id=SOURCE)
            time.sleep(0.6)
            # 菜单栏 Gogaku 图标（顶条右段）。
            sh('screencapture', '-x', '-R1600,0,1984,60', str(OUT / f'menubar-{appearance}.png'))
        set_appearance(dark=original_dark)
        result = {'frames': frames, 'originalDark': original_dark,
                  'inputSource': {'id': SOURCE,
                                  'installedSHA256': fkr.sha256_file(fkr.INSTALLED_BINARY)}}
        (OUT / 'capture-plan.json').write_text(fkr.json.dumps(result, ensure_ascii=False, indent=2))
        print('连拍完成：', len(sum(frames.values(), [])), '帧 ＋ 菜单栏 2 张')
        return 0
    finally:
        try:
            driver.ask(op='select', id=SOURCE)
        except Exception:
            pass
        driver.close()
        if original_front:
            sh('osascript', '-e', f'tell application "{original_front}" to activate')


if __name__ == '__main__':
    raise SystemExit(main())
