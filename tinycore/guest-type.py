#!/usr/bin/env python3
"""Type text (and press keys) into the guest via the QEMU monitor socket.

QEMU's `sendkey` speaks key names, not characters, so printable ASCII has to be
mapped back onto the US layout -- with shift for the upper register.

  guest-type.py "psi --tui" ret
  guest-type.py --delay 0.05 "hello world" ret
"""
import argparse
import socket
import sys
import time

BASE = {
    " ": "spc", "-": "minus", "=": "equal", "[": "bracket_left",
    "]": "bracket_right", "\\": "backslash", ";": "semicolon",
    "'": "apostrophe", "`": "grave_accent", ",": "comma", ".": "dot",
    "/": "slash",
}
SHIFTED = {
    "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7",
    "*": "8", "(": "9", ")": "0", "_": "minus", "+": "equal",
    "{": "bracket_left", "}": "bracket_right", "|": "backslash",
    ":": "semicolon", '"': "apostrophe", "~": "grave_accent",
    "<": "comma", ">": "dot", "?": "slash",
}
# Bare key names that may be passed as standalone arguments.
LITERAL = {
    "ret", "esc", "tab", "spc", "backspace", "delete", "up", "down",
    "left", "right", "home", "end", "pgup", "pgdn", "ctrl-c", "ctrl-d",
    "ctrl-l", "ctrl-u", "alt-f4",
}


def keys_for(text):
    for ch in text:
        if ch.isalpha():
            yield ("shift-" if ch.isupper() else "") + ch.lower()
        elif ch.isdigit():
            yield ch
        elif ch in BASE:
            yield BASE[ch]
        elif ch in SHIFTED:
            yield "shift-" + SHIFTED[ch]
        elif ch == "\n":
            yield "ret"
        else:
            print("skipping unmappable char: %r" % ch, file=sys.stderr)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", default="monitor.sock")
    ap.add_argument("--delay", type=float, default=0.02)
    ap.add_argument("args", nargs="+")
    opts = ap.parse_args()

    sequence = []
    for arg in opts.args:
        if arg in LITERAL:
            sequence.append(arg)
        else:
            sequence.extend(keys_for(arg))

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(opts.socket)
    time.sleep(0.3)
    sock.recv(65536)
    for key in sequence:
        sock.sendall(("sendkey %s\n" % key).encode())
        time.sleep(opts.delay)
        try:
            sock.recv(65536)
        except BlockingIOError:
            pass
    time.sleep(0.3)
    sock.close()


if __name__ == "__main__":
    main()
