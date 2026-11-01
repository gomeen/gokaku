#!/usr/bin/env python3
"""PTY fixture for IMK tests; receives only synthetic test input in a new terminal."""
import os
from pathlib import Path
import sys
import termios
import tty

output = Path(sys.argv[1])
previous = termios.tcgetattr(sys.stdin.fileno())
received = bytearray()
try:
    tty.setraw(sys.stdin.fileno())
    output.write_bytes(received)
    os.write(sys.stdout.fileno(), b'Gogaku IMK byte receiver ready\r\n')
    while True:
        data = os.read(sys.stdin.fileno(), 4096)
        if not data:
            break
        received.extend(data)
        temporary = output.with_suffix('.tmp')
        temporary.write_bytes(received)
        os.replace(temporary, output)
        os.write(sys.stdout.fileno(), ('\r\x1b[Kreceived ' + str(len(received)) + ' bytes').encode())
finally:
    termios.tcsetattr(sys.stdin.fileno(), termios.TCSANOW, previous)
