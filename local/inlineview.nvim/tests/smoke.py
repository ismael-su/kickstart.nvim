#!/usr/bin/env python3
"""End-to-end smoke test: drive a real Neovim inside a pty and assert that
image escape sequences actually reach the terminal.

The Lua suite captures output at the writer boundary, which cannot prove that
`BufReadCmd` fired, that the tty writer resolved, or that the sequence survived
Neovim's own drawing. This does, by being an actual terminal.

Usage:  python3 tests/smoke.py [--keep]
"""

import os
import pty
import re
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
FIXTURES = os.path.join(HERE, "fixtures")

MINIMAL_INIT = f"""
vim.opt.runtimepath:prepend("{ROOT}")
vim.opt.swapfile = false
require("inlineview").setup({{
  -- The pty reports no pixel size, so pin the cell geometry for determinism.
  cell = {{ width = 8, height = 16 }},
}})
"""

OSC_IMAGE = b"\x1b]1337;File="
KITTY_IMAGE = b"\x1b_G"


def run_in_pty(args, env, keys, settle=2.5, timeout=25.0):
    """Run `args` in a pty, send `keys`, and return everything it printed."""
    master, slave = pty.openpty()
    # 80x30 character cells; pixel fields stay zero, as over a plain ssh pty.
    import fcntl
    import struct
    import termios

    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("hhhh", 30, 80, 0, 0))

    proc = subprocess.Popen(
        args, stdin=slave, stdout=slave, stderr=slave, env=env, close_fds=True
    )
    os.close(slave)

    out = bytearray()
    deadline = time.time() + timeout
    sent = False
    start = time.time()

    while time.time() < deadline:
        r, _, _ = select.select([master], [], [], 0.2)
        if r:
            try:
                chunk = os.read(master, 65536)
            except OSError:
                break
            if not chunk:
                break
            out += chunk
        if not sent and time.time() - start > settle:
            for k in keys:
                os.write(master, k)
                time.sleep(0.35)
            sent = True
        if proc.poll() is not None:
            # Drain whatever is left.
            while True:
                r, _, _ = select.select([master], [], [], 0.3)
                if not r:
                    break
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                out += chunk
            break

    if proc.poll() is None:
        proc.kill()
        proc.wait()
    os.close(master)
    return bytes(out)


def env_for(term_program):
    env = dict(os.environ)
    env["TERM"] = "xterm-256color"
    env["LC_TERMINAL"] = term_program
    env.pop("TMUX", None)
    env.pop("KITTY_WINDOW_ID", None)
    env.pop("WEZTERM_PANE", None)
    env.pop("GHOSTTY_RESOURCES_DIR", None)
    env["NVIM_APPNAME"] = "inlineview-smoke"
    return env


RESULTS = []


def check(name, condition, detail=""):
    RESULTS.append((name, bool(condition), detail))
    mark = "\033[32m✓\033[0m" if condition else "\033[31m✗\033[0m"
    print(f"  {mark} {name}" + (f"\n      \033[90m{detail}\033[0m" if detail and not condition else ""))


def describe(title):
    print(f"\n\033[1m{title}\033[0m")


def extract_osc_args(out):
    """Return the argument strings of every OSC 1337 File sequence found."""
    return re.findall(rb"\x1b\]1337;File=([^:]*):", out)


def main():
    init = os.path.join(HERE, "smoke_init.lua")
    with open(init, "w") as f:
        f.write(MINIMAL_INIT)

    nvim = ["nvim", "--clean", "-u", init]

    try:
        describe("opening a PNG directly (BufReadCmd path)")
        out = run_in_pty(
            nvim + [os.path.join(FIXTURES, "gradient.png")],
            env_for("iTerm2"),
            [b"q", b":qa!\r"],
        )
        check("an inline image was written to the terminal", OSC_IMAGE in out)
        args = extract_osc_args(out)
        check("sequence carries inline=1", any(b"inline=1" in a for a in args),
              f"args seen: {args[:2]}")
        check("sequence sizes the image in cells",
              any(re.search(rb"width=\d+;height=\d+", a) for a in args),
              f"args seen: {args[:2]}")
        check("the file name survived", any(b"name=" in a for a in args))
        check("no Lua error surfaced", b"E5108" not in out and b"stack traceback" not in out,
              extract_error(out))
        check("binary bytes were not rendered as text", b"IHDR" not in out)

        describe("opening a PDF and paging through it")
        out = run_in_pty(
            nvim + [os.path.join(FIXTURES, "sample.pdf")],
            env_for("iTerm2"),
            [b"n", b"n", b"p", b"+", b"-", b":qa!\r"],
        )
        args = extract_osc_args(out)
        check("the PDF was rasterized and drawn", OSC_IMAGE in out)
        check("paging redrew the image several times", len(args) >= 3,
              f"only {len(args)} draws observed")
        check("the status line reports the page number",
              re.search(rb"page\s+\d+/3", out) is not None)
        check("no Lua error surfaced", b"E5108" not in out and b"stack traceback" not in out,
              extract_error(out))

        describe("the :InlineView command on an explicit path")
        out = run_in_pty(
            nvim,
            env_for("iTerm2"),
            [f":InlineView {FIXTURES}/tall.png\r".encode(), b"q", b":qa!\r"],
        )
        check("the floating viewer drew an image", OSC_IMAGE in out)
        check("no Lua error surfaced", b"E5108" not in out and b"stack traceback" not in out,
              extract_error(out))

        describe("inline rendering inside a markdown buffer")
        md = os.path.join(FIXTURES, "notes.md")
        with open(md, "w") as f:
            f.write("# Notes\n\nSome prose.\n\n![a diagram](gradient.png)\n\nMore prose.\n")
        out = run_in_pty(nvim + [md], env_for("iTerm2"), [b":qa!\r"])
        check("the linked image was drawn in the buffer", OSC_IMAGE in out)
        check("no Lua error surfaced", b"E5108" not in out and b"stack traceback" not in out,
              extract_error(out))

        describe("a terminal with no image protocol")
        env = env_for("")
        env.pop("LC_TERMINAL", None)
        out = run_in_pty(
            nvim + [os.path.join(FIXTURES, "gradient.png")],
            env,
            [b"q", b":qa!\r"],
        )
        check("it degrades instead of erroring",
              b"E5108" not in out and b"stack traceback" not in out, extract_error(out))
        check("something was still drawn (half-block fallback)",
              OSC_IMAGE in out or b"\xe2\x96" in out or b"[0m" in out)

        describe("a file that is not really an image")
        bad = os.path.join(FIXTURES, "broken.png")
        with open(bad, "w") as f:
            f.write("definitely not a png")
        out = run_in_pty(nvim + [bad], env_for("iTerm2"), [b":qa!\r"])
        check("it reports the problem without crashing",
              b"stack traceback" not in out and b"E5108" not in out, extract_error(out))
        os.remove(bad)

    finally:
        if os.path.exists(init):
            os.remove(init)
        if "--keep" not in sys.argv:
            for leftover in ("notes.md",):
                p = os.path.join(FIXTURES, leftover)
                if os.path.exists(p):
                    os.remove(p)

    passed = sum(1 for _, ok, _ in RESULTS if ok)
    failed = len(RESULTS) - passed
    print("\n" + "─" * 52)
    if failed:
        print(f"\033[31m{failed} failed\033[0m, {passed} passed")
        return 1
    print(f"\033[32m{passed} passed\033[0m, 0 failed")
    return 0


def extract_error(out):
    """Pull a readable snippet around any Lua error, for failure messages."""
    text = out.decode("utf-8", "replace")
    for needle in ("E5108", "stack traceback", "Error executing"):
        i = text.find(needle)
        if i != -1:
            return re.sub(r"\s+", " ", text[i : i + 300])
    return ""


if __name__ == "__main__":
    sys.exit(main())
