#!/usr/bin/env python3
"""固定有效 PNG 的 C ABI 离屏探针；每种尺寸在独立子进程测冷帧与热态。

PNG 含确定性随机 RGBA 像素及合法 ancillary 填充块，文件大小精确覆盖
256KiB/1MiB/4MiB/8MiB；不读用户数据、不打开窗口、不注入按键。
"""
import argparse
import base64
import ctypes as C
import hashlib
import json
import math
from pathlib import Path
import platform
import random
import statistics
import struct
import subprocess
import sys
import time
import zlib

import runpy
Result = runpy.run_path(str(Path(__file__).with_name('render-shared-panel.py')))['Result']


def image_bytes(size):
    if not size:
        return b'', 0, 0
    width = 256 if size < 1024 * 1024 else 1024
    height = (size - 1024) // (width * 4 + 1)
    rng = random.Random(7301)
    raw = b''.join(b'\0' + rng.randbytes(width * 4) for _ in range(height))
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    prefix = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
              + chunk(b'IDAT', zlib.compress(raw, 0)))
    result = prefix + chunk(b'npAD', b'\0' * (size - len(prefix) - 24)) + chunk(b'IEND', b'')
    assert len(result) == size
    return result, width, height


def measure(args):
    lib = C.CDLL(str(args.library.resolve()))
    lib.gc_panel_render.argtypes = [C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t, C.c_double, C.c_int32, C.POINTER(C.POINTER(Result))]
    lib.gc_panel_render.restype = C.c_int32
    lib.gc_panel_result_free.argtypes = [C.POINTER(Result)]
    lib.gc_panel_result_free.restype = None
    png, width, height = image_bytes(args.size)
    theme = {'id': 'gogaku', 'light': {'background': 16777215, 'visual': {'imageOpacity': 25}},
             'typography': {'fontSize': 14, 'indexSize': 11}}
    if png:
        theme['light']['imageData'] = base64.b64encode(png).decode('ascii')
    skin = json.dumps(theme, separators=(',', ':')).encode()
    fonts = [{'path': str(args.font.resolve()), 'index': args.face}]
    frame = {'fonts': fonts, 'preedit': "ni'hao", 'preeditCaretUTF16': 6, 'pageCount': 4,
             'candidates': [{'text': word, 'gloss': gloss} for word, gloss in
                            zip(['你好', '学习', '语言', '输入'], ['hello', 'learn', 'language', 'input'])]}
    data = json.dumps(frame, ensure_ascii=False, separators=(',', ':')).encode()
    handle, prepare_ms = C.c_void_p(), 0
    if args.api == 'prepared':
        lib.gc_panel_theme_create.argtypes = [C.c_char_p, C.c_size_t, C.POINTER(C.c_void_p)]
        lib.gc_panel_theme_create.restype = C.c_int32
        lib.gc_panel_theme_free.argtypes = [C.c_void_p]
        lib.gc_panel_theme_free.restype = None
        lib.gc_panel_render_prepared.argtypes = [C.c_char_p, C.c_size_t, C.c_void_p, C.c_double, C.c_int32, C.POINTER(C.POINTER(Result))]
        lib.gc_panel_render_prepared.restype = C.c_int32
        start = time.perf_counter_ns()
        rc = lib.gc_panel_theme_create(skin, len(skin), C.byref(handle))
        prepare_ms = (time.perf_counter_ns() - start) / 1e6
        assert rc == 0, rc
    durations, first_hash, dimensions = [], None, None
    try:
        for i in range(args.repeat + args.warmup + 1):
            result = C.POINTER(Result)()
            start = time.perf_counter_ns()
            if args.api == 'prepared':
                rc = lib.gc_panel_render_prepared(data, len(data), handle, 2, 0, C.byref(result))
            else:
                rc = lib.gc_panel_render(data, len(data), skin, len(skin), 2, 0, C.byref(result))
            elapsed = (time.perf_counter_ns() - start) / 1e6
            assert rc == 0 and result, rc
            try:
                if i == 0:
                    cold = elapsed
                    r = result.contents
                    dimensions = [r.width, r.height]
                    first_hash = hashlib.sha256(C.string_at(r.pixels, r.width * r.height * 4)).hexdigest()
                if i > args.warmup:
                    durations.append(elapsed)
            finally:
                lib.gc_panel_result_free(result)
    finally:
        if handle:
            lib.gc_panel_theme_free(handle)
    ordered = sorted(durations)
    return dict(api=args.api, pngBytes=len(png), pngDimensions=[width, height], themeBytes=len(skin),
                pngSha256=hashlib.sha256(png).hexdigest(), themeSha256=hashlib.sha256(skin).hexdigest(),
                frame=frame, scale=2, dimensions=dimensions, rgbaSha256=first_hash,
                prepareMs=prepare_ms, coldRenderMs=cold, coldTotalMs=prepare_ms+cold,
                medianMs=statistics.median(durations), p95Ms=ordered[math.ceil(.95*len(ordered))-1],
                samplesMs=durations)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--library', type=Path, default=Path('.build/core/libgogaku_core.dylib'))
    p.add_argument('--font', type=Path, required=True)
    p.add_argument('--face', type=int, default=3)
    p.add_argument('--repeat', type=int, default=200)
    p.add_argument('--warmup', type=int, default=10)
    p.add_argument('--api', choices=['legacy', 'prepared'], default='legacy')
    p.add_argument('--out', type=Path)
    p.add_argument('--size', type=int)
    args = p.parse_args()
    if args.size is not None:
        print(json.dumps(measure(args), ensure_ascii=False))
        return
    cases = []
    for size in [0, 256*1024, 1024*1024, 4*1024*1024, 8*1024*1024]:
        result = subprocess.run([sys.executable, __file__, '--library', str(args.library), '--font', str(args.font),
                                 '--face', str(args.face), '--repeat', str(args.repeat), '--warmup', str(args.warmup),
                                 '--api', args.api, '--size', str(size)], capture_output=True, text=True, check=True)
        case = json.loads(result.stdout)
        cases.append(case)
        print(f'{args.api} PNG={size}: median={case["medianMs"]:.3f}ms p95={case["p95Ms"]:.3f}ms coldTotal={case["coldTotalMs"]:.3f}ms', flush=True)
    report = dict(machine=platform.platform(), library=str(args.library),
                  librarySha256=hashlib.sha256(args.library.read_bytes()).hexdigest(), hostTested=False,
                  scope='C ABI 离屏，四候选竖排，scale 2；不含平台封装与窗口；每尺寸新进程，不清 OS 文件缓存',
                  repeat=args.repeat, warmup=args.warmup, cases=cases)
    assert args.out
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')


if __name__ == '__main__':
    main()
