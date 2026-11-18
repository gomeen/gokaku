#!/usr/bin/env python3
"""直接调用共享 C ABI 的离屏图像/计时探针；不打开窗口、不注入按键。"""
import argparse
import ctypes as C
import hashlib
import json
import platform
from pathlib import Path
import statistics
import struct
import time
import zlib

class Hit(C.Structure):
    _fields_ = [(name, C.c_int32) for name in ('action', 'arg', 'x', 'y', 'w', 'h')]

class Result(C.Structure):
    _fields_ = [('pixels', C.POINTER(C.c_ubyte)), ('width', C.c_int32),
                ('height', C.c_int32), ('hits', C.POINTER(Hit)), ('hit_count', C.c_size_t)]

def png(path, pixels, width, height):
    # ABI 是预乘 RGBA，PNG 存直通 alpha；仅导出时解除预乘。
    data = bytearray(pixels)
    for offset in range(0, len(data), 4):
        alpha = data[offset + 3]
        if 0 < alpha < 255:
            for channel in range(3):
                data[offset + channel] = min(255, round(data[offset + channel] * 255 / alpha))
    def chunk(kind, body):
        return struct.pack('>I', len(body)) + kind + body + struct.pack('>I', zlib.crc32(kind + body))
    scanlines = b''.join(b'\0' + data[y * width * 4:(y + 1) * width * 4] for y in range(height))
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0))
                     + chunk(b'IDAT', zlib.compress(scanlines)) + chunk(b'IEND', b''))

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, default=Path('.build/core/libgogaku_core.dylib'))
    parser.add_argument('--font', type=Path, required=True)
    parser.add_argument('--face', type=int, default=0)
    parser.add_argument('--latin-font', type=Path)
    parser.add_argument('--emoji-font', type=Path)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--repeat', type=int, default=200)
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    lib = C.CDLL(str(args.library.resolve()))
    lib.gc_panel_render.argtypes = [C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t, C.c_double, C.c_int32, C.POINTER(C.POINTER(Result))]
    lib.gc_panel_render.restype = C.c_int32
    lib.gc_panel_result_free.argtypes = [C.POINTER(Result)]
    lib.gc_themes_builtin.argtypes = [C.POINTER(C.c_void_p), C.POINTER(C.c_size_t)]
    lib.gc_contract_free.argtypes = [C.c_void_p]
    buf, count = C.c_void_p(), C.c_size_t()
    if lib.gc_themes_builtin(C.byref(buf), C.byref(count)):
        raise RuntimeError('gc_themes_builtin failed')
    themes = json.loads(C.string_at(buf, count.value)); lib.gc_contract_free(buf)
    fonts = [{'path': str(args.font.resolve()), 'index': args.face}]
    if args.latin_font:
        fonts.insert(0, {'path': str(args.latin_font.resolve()), 'index': 0, 'role': 'latin'})
    if args.emoji_font:
        fonts.append({'path': str(args.emoji_font.resolve()), 'index': 0, 'emoji': True})
    words = ['你好', '学习', '语言', '输入', '世界', '今天', '朋友', '工作', '谢谢']
    glosses = ['int. hello · hi', 'v. learn · study', 'n. language', 'v. input', 'n. world', 'today', 'n. friend', 'n. work', 'thank you']
    base = dict(fonts=fonts, preedit="ni'hao", preeditCaretUTF16=6, page=0, pageCount=4, selected=0)
    records = []
    for theme in themes:
        for horizontal in (False, True):
            for dark in (False, True):
                frame = dict(base, layout='horizontal' if horizontal else 'vertical', pageSize=7 if horizontal else 9, glossRow=True,
                             candidates=[dict(text=w, gloss=g) for w, g in zip(words[:7 if horizontal else 9], glosses)])
                if args.emoji_font:
                    frame['candidates'][1]['text'] = '中文 hello 🙂 日本語'
                data, skin = json.dumps(frame, ensure_ascii=False).encode(), json.dumps(theme).encode()
                durations, first_pixels, dimensions, hits = [], None, None, []
                for iteration in range(max(2, args.repeat)):
                    result = C.POINTER(Result)()
                    start = time.perf_counter_ns()
                    rc = lib.gc_panel_render(data, len(data), skin, len(skin), 2, int(dark), C.byref(result))
                    durations.append((time.perf_counter_ns() - start) / 1e6)
                    if rc:
                        raise RuntimeError(f'gc_panel_render rc={rc}')
                    try:
                        if iteration == 0:
                            r = result.contents
                            first_pixels = C.string_at(r.pixels, r.width * r.height * 4)
                            dimensions = (r.width, r.height)
                            hits = [{name: getattr(r.hits[i], name) for name, _ in Hit._fields_} for i in range(r.hit_count)]
                    finally:
                        lib.gc_panel_result_free(result)
                name = f'{theme["id"]}-{"horizontal" if horizontal else "vertical"}-{"dark" if dark else "light"}'
                path = args.out / f'{name}.png'
                png(path, first_pixels, *dimensions)
                steady = sorted(durations[1:])
                records.append(dict(name=name, width=dimensions[0], height=dimensions[1], firstMs=durations[0],
                                    medianMs=statistics.median(steady), p95Ms=steady[int((len(steady)-1)*.95)],
                                    png=path.name, rgbaSha256=hashlib.sha256(first_pixels).hexdigest(), hits=hits))
                print(f'{name}: {dimensions}, first {durations[0]:.3f}ms median {records[-1]["medianMs"]:.3f}ms p95 {records[-1]["p95Ms"]:.3f}ms')
    (args.out / 'report.json').write_text(json.dumps(dict(machine=platform.platform(), library=str(args.library), fonts=fonts,
        scale=2, repeat=args.repeat, hostTested=False, cases=records), ensure_ascii=False, indent=2) + '\n')

if __name__ == '__main__':
    main()
