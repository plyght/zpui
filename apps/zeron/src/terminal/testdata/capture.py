#!/usr/bin/env python3
"""Record real program output under an 80x24 PTY for capture_test.zig.

Each fixture is a list of steps; the bytes printed after each step are saved
to <name>_<n>.bin so tests can assert intermediate screens (e.g. vim's alt
screen before quitting). Answers DA1/DSR-CPR queries like a terminal would.

Usage: python3 apps/zeron/src/terminal/testdata/capture.py   (from repo root)
"""
import fcntl, os, pty, select, struct, subprocess, sys, tempfile, termios, time

HERE = os.path.dirname(os.path.abspath(__file__))
COLS, ROWS = 80, 24


def run(name, argv, steps, cwd=None, env_extra=None):
    env = dict(os.environ, TERM="xterm-256color", LANG="C.UTF-8", LC_ALL="C.UTF-8",
               COLUMNS=str(COLS), LINES=str(ROWS), HOME=cwd or "/tmp")
    env.update(env_extra or {})
    pid, fd = pty.fork()
    if pid == 0:
        if cwd:
            os.chdir(cwd)
        os.execvpe(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", ROWS, COLS, 0, 0))
    outs = []

    def pump(quiet_ms, max_ms=5000):
        buf = b""
        start = last = time.time()
        while True:
            r, _, _ = select.select([fd], [], [], 0.01)
            now = time.time()
            if r:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return buf, True
                if not data:
                    return buf, True
                buf += data
                last = now
                # Minimal query answers so full-screen apps don't stall.
                if b"\x1b[c" in data or b"\x1b[0c" in data:
                    os.write(fd, b"\x1b[?62;22c")
                if b"\x1b[6n" in data:
                    os.write(fd, b"\x1b[1;1R")
            elif (now - last) * 1000 >= quiet_ms or (now - start) * 1000 >= max_ms:
                return buf, False

    done = False
    for i, (delay_ms, data) in enumerate(steps):
        out, done = pump(delay_ms)
        outs.append(out)
        if done:
            break
        if data:
            os.write(fd, data)
    if not done:
        out, done = pump(500, 3000)
        outs.append(out)
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    os.waitpid(pid, 0)
    for i, out in enumerate(outs):
        with open(os.path.join(HERE, "%s_%d.bin" % (name, i)), "wb") as f:
            f.write(out)
    print(name, [len(o) for o in outs])


def main():
    tmp = tempfile.mkdtemp(prefix="zeron-term-")
    for d in ("src", "docs", "build"):
        os.mkdir(os.path.join(tmp, d))
    for f in ("README.md", "notes.txt", "Cargo.toml"):
        open(os.path.join(tmp, f), "w").close()
    exe = os.path.join(tmp, "run.sh")
    open(exe, "w").write("#!/bin/sh\n")
    os.chmod(exe, 0o755)
    os.symlink("README.md", os.path.join(tmp, "link.md"))

    # ls --color: one step, the whole listing.
    run("ls_color", ["ls", "--color=always", "-C"], [], cwd=tmp)

    # vim alt-screen session: startup, type text, write+quit.
    run("vim", ["vim", "-u", "NONE", "-i", "NONE", "-N", "-n", "--noplugin", "demo.txt"],
        [(800, b"ihello from vim\x1bo\tindented line\x1b"),
         (400, b":set number\r"),
         (400, b":wq\r")], cwd=tmp)

    # htop-ish: top in interactive mode (alt screen, cursor addressing, SGR).
    run("top", ["top", "-d", "0.5"], [(1200, b"q")], cwd=tmp)


if __name__ == "__main__":
    main()
