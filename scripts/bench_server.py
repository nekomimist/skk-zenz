#!/usr/bin/env python3
"""Measure zenz-server round-trip latency over the JSON Lines protocol.

Usage: scripts/bench_server.py [SERVER] [-- SERVER_ARGS...]
The model comes from $ZENZ_MODEL unless SERVER_ARGS pass --model.
"""
import json
import subprocess
import sys
import time

REQUESTS = [
    ("きょうはいいてんきなのでさんぽにいきます", "日曜日の朝、"),
    ("かいとう", "試験問題の"),
    ("きしゃ", ""),
    ("こうこうのきょうし", "来月から"),
]
REPEAT = 10


def main():
    args = sys.argv[1:]
    server = args[0] if args and args[0] != "--" else "build/zenz-server"
    extra = args[args.index("--") + 1:] if "--" in args else []
    proc = subprocess.Popen([server, *extra], stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, text=True, encoding="utf-8")
    start = time.perf_counter()
    hello = proc.stdout.readline()
    if not hello:
        sys.exit("server exited before hello")
    print("startup until hello: %.1f ms  %s"
          % ((time.perf_counter() - start) * 1000, hello.strip()))
    for n in (1, 3, 5):
        for kana, left in REQUESTS:
            times = []
            for i in range(REPEAT):
                request = {"id": i, "kana": kana, "left": left, "n": n}
                t = time.perf_counter()
                proc.stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
                proc.stdin.flush()
                response = json.loads(proc.stdout.readline())
                times.append((time.perf_counter() - t) * 1000)
            print("n=%d %s  mean %.1f ms  max %.1f ms  %s"
                  % (n, kana, sum(times) / len(times), max(times),
                     response.get("candidates", response)[:3]))
    proc.stdin.close()
    proc.wait()


if __name__ == "__main__":
    main()
