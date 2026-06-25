#!/usr/bin/env python3
"""No-audio proof that the barge-in race loop (mirrored from streaming.py) cuts the
instant stop_event fires — it must NOT wait for the next slow HTTP chunk."""
import asyncio
import time
import sys

fails = 0


def check(c, m):
    global fails
    print(("  ok   " if c else "  FAIL ") + m, flush=True)
    if not c:
        fails += 1


class FakeStream:
    def __init__(self):
        self.aborted = False
        self.stopped = False
        self.written = 0

    def write(self, a):
        self.written += 1

    def abort(self):
        self.aborted = True

    def stop(self):
        self.stopped = True


async def slow_iter(n_fast, trailing_gap):
    """Yield n_fast quick chunks, then stall trailing_gap seconds before ending
    (simulating Kokoro still generating — the window where a naive loop blocks)."""
    for i in range(n_fast):
        await asyncio.sleep(0.02)
        yield b"\x00\x01" * 16
    await asyncio.sleep(trailing_gap)


async def race_play(stop_event, aiter_obj, stream):
    """EXACT mirror of streaming.py's barge-in branch."""
    interrupted = False
    chunk_iter = aiter_obj.__aiter__()
    stop_wait = asyncio.ensure_future(stop_event.wait()) if stop_event is not None else None
    try:
        while True:
            nxt = asyncio.ensure_future(chunk_iter.__anext__())
            if stop_wait is not None:
                done, _pending = await asyncio.wait({nxt, stop_wait}, return_when=asyncio.FIRST_COMPLETED)
                if stop_wait in done:
                    nxt.cancel()
                    try:
                        await nxt
                    except (asyncio.CancelledError, Exception):
                        pass
                    interrupted = True
                    stream.abort()
                    break
                try:
                    chunk = nxt.result()
                except StopAsyncIteration:
                    break
            else:
                try:
                    chunk = await nxt
                except StopAsyncIteration:
                    break
            if chunk:
                stream.write(chunk)
    finally:
        if stop_wait is not None and not stop_wait.done():
            stop_wait.cancel()
    if not interrupted:
        stream.stop()
    return interrupted


async def main():
    # 1) Normal completion: no stop -> all chunks played, clean stop(), no abort.
    st = FakeStream()
    ev = asyncio.Event()
    interrupted = await race_play(ev, slow_iter(5, 0.0), st)
    check(not interrupted, "no-stop: not interrupted")
    check(st.written == 5, f"no-stop: all 5 chunks played (got {st.written})")
    check(st.stopped and not st.aborted, "no-stop: clean stop(), no abort()")

    # 2) Barge-in during the long trailing gap: must break IMMEDIATELY, not wait 5s.
    st = FakeStream()
    ev = asyncio.Event()
    aiter_obj = slow_iter(2, 5.0)  # 2 quick chunks then a 5s stall

    async def fire():
        await asyncio.sleep(0.25)  # let the 2 chunks play, land in the stall
        ev.set()

    t0 = time.perf_counter()
    interrupted, _ = await asyncio.gather(race_play(ev, aiter_obj, st), fire())
    elapsed = time.perf_counter() - t0
    check(interrupted, "barge-in: interrupted=True")
    check(st.aborted, "barge-in: stream.abort() called")
    check(not st.stopped, "barge-in: did NOT drain via stop()")
    check(elapsed < 0.6, f"barge-in: cut was IMMEDIATE ({elapsed*1000:.0f}ms, not the 5s stall)")

    print("\nALL PASS" if fails == 0 else f"\n{fails} FAILURE(S)", flush=True)
    sys.exit(0 if fails == 0 else 1)


asyncio.run(main())
