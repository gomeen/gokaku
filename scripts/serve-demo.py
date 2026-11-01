#!/usr/bin/env python3
"""demo 预览静态服务：仅绑定回环地址，禁缓存（避免浏览器用旧版原型）。

用法：python3 scripts/serve-demo.py [端口]   # 默认 8897
"""
import http.server
import sys

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 8897


class NoCache(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store, must-revalidate")
        self.send_header("Pragma", "no-cache")
        self.send_header("Expires", "0")
        super().end_headers()


if __name__ == "__main__":
    http.server.test(HandlerClass=NoCache, port=PORT, bind="127.0.0.1")
