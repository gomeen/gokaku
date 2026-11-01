#!/usr/bin/env python3
"""从 assets/app-icon/*.svg 生成打包所需的图标资产。

产物（全部写回 assets/app-icon/，随仓库提交）：
- AppIcon.icns           两个 .app 的 Contents/Resources/AppIcon.icns
- gogaku-menu.pdf        16pt 矢量 PDF，输入源菜单与菜单栏图标
- gogaku-menu.png        32x32 预览图；不用于输入源菜单

应用图标依赖 qlmanage、sips 和 iconutil；菜单 PDF 由 CoreGraphics
直接从 menu.svg 的路径生成，并检查实际光栅化结果。SVG 是唯一手工维护的源头。
"""

import argparse
import shutil
import subprocess
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'assets/app-icon'

ICONSET_SIZES = [16, 32, 64, 128, 256, 512, 1024]


def run(*command: str) -> None:
    subprocess.run(command, check=True, capture_output=True, text=True)


def render_png(svg: Path, size: int, destination: Path, scratch: Path) -> None:
    ql_output = scratch / destination.stem
    ql_output.mkdir()
    run('qlmanage', '-t', '-s', str(size), '-o', str(ql_output), str(svg))
    produced = ql_output / f'{svg.name}.png'
    if size == 1024:
        shutil.copy2(produced, destination)
    else:
        run('sips', '-z', str(size), str(size), str(produced), '--out', str(destination))


def make_app_icon(scratch: Path) -> None:
    master = ASSETS / 'icon.svg'
    iconset = scratch / 'AppIcon.iconset'
    iconset.mkdir()
    for size in ICONSET_SIZES:
        if size > 16:
            render_png(master, size, iconset / f'icon_{size // 2}x{size // 2}@2x.png', scratch)
        render_png(master, size, iconset / f'icon_{size}x{size}.png', scratch)
    icns = ASSETS / 'AppIcon.icns'
    run('iconutil', '-c', 'icns', str(iconset), '-o', str(icns))
    print(f'已生成 {icns.relative_to(ROOT)}')


def make_menu_icon(scratch: Path) -> None:
    """生成实际含笔画的 16pt 矢量页面及 PNG 预览。"""
    png = ASSETS / 'gogaku-menu.png'
    render_png(ASSETS / 'menu.svg', 32, png, scratch)
    run('sips', '-s', 'dpiWidth', '144', '-s', 'dpiHeight', '144', str(png))
    pdf = ASSETS / 'gogaku-menu.pdf'
    run('swift', str(ROOT / 'scripts/menu-pdf.swift'), str(pdf), str(ASSETS / 'menu.svg'))
    run('swift', str(ROOT / 'scripts/check-menu-icon.swift'), str(pdf))
    print(f"已生成 {pdf.relative_to(ROOT)}")


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.parse_args()
    with tempfile.TemporaryDirectory() as directory:
        scratch = Path(directory)
        make_app_icon(scratch)
        make_menu_icon(scratch)
