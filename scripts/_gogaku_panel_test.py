"""构建与验证共用的本机渲染测试字体；不复制或分发系统字体。"""
import os
from pathlib import Path


def panel_font_environment():
    if os.environ.get('GOGAKU_PANEL_FONT'):
        return {'GOGAKU_PANEL_FONT': os.environ['GOGAKU_PANEL_FONT'],
                'GOGAKU_PANEL_FONT_INDEX': os.environ.get('GOGAKU_PANEL_FONT_INDEX', '0')}
    candidates = [
        (Path.home() / 'Library/Application Support/com.electron.lark.font_workaround/PingFang.ttc', 3),
        (Path('/System/Library/Fonts/Hiragino Sans GB.ttc'), 0),
    ]
    for path, index in candidates:
        if path.is_file():
            return {'GOGAKU_PANEL_FONT': str(path), 'GOGAKU_PANEL_FONT_INDEX': str(index)}
    # 测试会返回 SKIP；交付门拒绝将跳过算作通过。
    return {'GOGAKU_PANEL_FONT': '', 'GOGAKU_PANEL_FONT_INDEX': '0'}
