#!/usr/bin/env python3
"""Spike timeline website with in-process STUN probing (no disk recorder)."""
from __future__ import annotations

import argparse
import json
import math
import mimetypes
import os
import re
import socket
import threading
import time
import webbrowser
from collections import deque
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent
WEB = ROOT / "timeline-web"
CYCLE_SEC = 31.0
LARGE_MS = 200.0
HIGHLIGHT_MS = 125.0  # mark milder spikes in the viewer
SPIKE_MS = 80.0       # log / keep peaks from this RTT up
CLUMP_GAP_MS = 400.0
RATE_HZ = 60  # closer to frame-rate jitter graphs; catches short blips
TIMEOUT_MS = 1500
KEEP_MS = 6 * 60 * 60 * 1000  # retain ~6h in memory
CLIENT_IDLE_SEC = 4.0  # stop probing shortly after the tab closes
STUN_SERVERS = [
    ("stun.l.google.com", 19302),
    ("stun1.l.google.com", 19302),
    ("stun.cloudflare.com", 3478),
]
MAGIC = b"\x21\x12\xa4\x42"


def now_ms() -> float:
    return time.time() * 1000.0


def parse_iso(s: str) -> float:
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s).timestamp() * 1000.0


def latest_run(logs: Path) -> Path | None:
    runs = sorted(logs.glob("long-*"), key=lambda p: p.stat().st_mtime, reverse=True)
    return runs[0] if runs else None


def stun_request() -> tuple[bytes, bytes]:
    tid = os.urandom(12)
    pkt = bytearray(20)
    pkt[1] = 0x01
    pkt[4:8] = MAGIC
    pkt[8:20] = tid
    return bytes(pkt), tid


def stun_tid(data: bytes) -> bytes | None:
    if len(data) < 20:
        return None
    return data[8:20]


class DataStore:
    """In-memory spike/sample store shared by live probe and optional CSV replay."""

    def __init__(self, label: str = "live"):
        self.lock = threading.Lock()
        self.label = label
        self.spikes: list[dict] = []
        self.samples: list[dict] = []
        self.events: deque[str] = deque(maxlen=200)
        self.anchor: float | None = None
        self._dur: list[float] = []
        self._count: list[int] = []
        self._clumps_dirty = False
        self.started = now_ms()
        self.sent = 0
        self.slow = 0
        self.large = 0
        self.recording = False
        self.last_client = 0.0
        self.probe_error = ""

    def touch_client(self):
        self.last_client = time.time()

    def client_active(self) -> bool:
        return (time.time() - self.last_client) <= CLIENT_IDLE_SEC

    def add_event(self, line: str):
        self.events.append(line)

    def _trim(self, t_now: float):
        cut = t_now - KEEP_MS
        if self.samples and self.samples[0]["t"] < cut:
            lo = 0
            while lo < len(self.samples) and self.samples[lo]["t"] < cut:
                lo += 1
            if lo:
                del self.samples[:lo]
        if self.spikes and self.spikes[0]["t"] < cut:
            lo = 0
            while lo < len(self.spikes) and self.spikes[lo]["t"] < cut:
                lo += 1
            if lo:
                del self.spikes[:lo]
                self._clumps_dirty = True

    def add_sample(self, t: float, rtt: float, flow: str = ""):
        self.samples.append({"t": t, "rtt": rtt, "flow": flow})
        self._trim(t)

    def add_spike(self, t: float, rtt: float, flow: str, large: bool):
        self.spikes.append({"t": t, "rtt": rtt, "large": large, "flow": flow})
        if self.anchor is None and large:
            self.anchor = t
        # Defer O(n) clump rebuild — doing it on every spike stalled the probe
        # thread and dropped delayed STUN replies (missed majors).
        self._clumps_dirty = True
        self._dur.append(1.0)
        self._count.append(1)
        self._trim(t)
        tag = "  LARGE" if large else ""
        hh = datetime.fromtimestamp(t / 1000.0).strftime("%H:%M:%S.%f")[:-3]
        self.add_event(f"{hh}  {flow}  {rtt:.1f}ms{tag}")

    def _rebuild_clumps(self):
        self._dur = []
        self._count = []
        n = len(self.spikes)
        i = 0
        while i < n:
            j = i
            while j + 1 < n and (self.spikes[j + 1]["t"] - self.spikes[j]["t"]) <= CLUMP_GAP_MS:
                j += 1
            dur = max(1.0, self.spikes[j]["t"] - self.spikes[i]["t"])
            cnt = j - i + 1
            for _ in range(i, j + 1):
                self._dur.append(dur)
                self._count.append(cnt)
            i = j + 1
        self._clumps_dirty = False

    def _ensure_clumps(self):
        if self._clumps_dirty or len(self._dur) != len(self.spikes):
            self._rebuild_clumps()

    def bounds(self) -> tuple[float, float]:
        ts = []
        if self.samples:
            ts.append(self.samples[0]["t"])
            ts.append(self.samples[-1]["t"])
        if self.spikes:
            ts.append(self.spikes[0]["t"])
            ts.append(self.spikes[-1]["t"])
        if not ts:
            n = now_ms()
            return n - 60_000.0, n
        return min(ts), max(ts)

    def status_text(self) -> str:
        elapsed = (now_ms() - self.started) / 1000.0
        rec = "recording" if self.recording else "idle"
        err = f"\nerror={self.probe_error}" if self.probe_error else ""
        return (
            f"status={rec}\n"
            f"mode=live-memory\n"
            f"elapsed_s={elapsed:.1f}\n"
            f"sent={self.sent}\n"
            f"slow={self.slow}\n"
            f"large={self.large}\n"
            f"label={self.label}"
            f"{err}"
        )

    def minimap(self, cols: int = 800) -> list[dict]:
        out = [{"has": False, "large": False} for _ in range(cols)]
        if not self.spikes:
            return out
        t0, t1 = self.bounds()
        span = max(1.0, t1 - t0)
        for s in self.spikes:
            if s["rtt"] < HIGHLIGHT_MS:
                continue
            frac = (s["t"] - t0) / span
            if frac < 0 or frac > 1:
                continue
            c = min(cols - 1, max(0, int(frac * cols)))
            out[c]["has"] = True
            if s["large"]:
                out[c]["large"] = True
        return out

    def spikes_in(self, t0: float, t1: float, budget: int = 400) -> list[dict]:
        self._ensure_clumps()
        lo, hi = 0, len(self.spikes)
        while lo < hi:
            mid = (lo + hi) // 2
            if self.spikes[mid]["t"] < t0:
                lo = mid + 1
            else:
                hi = mid
        vis = []
        i = lo
        while i < len(self.spikes) and self.spikes[i]["t"] <= t1:
            if self.spikes[i]["rtt"] >= HIGHLIGHT_MS:
                vis.append(i)
            i += 1
        step = 1
        if len(vis) > budget:
            step = math.ceil(len(vis) / budget)
        out = []
        for k, idx in enumerate(vis):
            s = self.spikes[idx]
            if (k % step) != 0 and not s["large"]:
                continue
            out.append(
                {
                    "t": s["t"],
                    "rtt": s["rtt"],
                    "large": s["large"],
                    "flow": s["flow"],
                    "durMs": int(self._dur[idx]) if idx < len(self._dur) else 1,
                    "count": int(self._count[idx]) if idx < len(self._count) else 1,
                }
            )
        return out

    def samples_in(self, t0: float, t1: float, budget: int = 1200) -> list[dict]:
        if not self.samples or t1 <= t0:
            return []
        lo, hi = 0, len(self.samples)
        while lo < hi:
            mid = (lo + hi) // 2
            if self.samples[mid]["t"] < t0:
                lo = mid + 1
            else:
                hi = mid
        span = t1 - t0
        bucket = max(1.0, span / max(1, budget))
        out = []
        bstart = None
        bmax = 0.0
        bmid = 0.0
        i = lo
        while i < len(self.samples) and self.samples[i]["t"] <= t1:
            t = self.samples[i]["t"]
            rtt = self.samples[i]["rtt"]
            b = math.floor((t - t0) / bucket)
            if b != bstart:
                if bstart is not None:
                    out.append({"t": bmid, "rtt": bmax})
                bstart = b
                bmax = rtt
                bmid = t
            else:
                if rtt > bmax:
                    bmax = rtt
                bmid = t
            i += 1
        if bstart is not None:
            out.append({"t": bmid, "rtt": bmax})
        return out


class StunProbe(threading.Thread):
    """Persistent UDP STUN flows; runs only while a browser tab is active."""

    def __init__(self, store: DataStore):
        super().__init__(daemon=True, name="stun-probe")
        self.store = store
        self._stop = threading.Event()

    def stop(self):
        self._stop.set()

    @staticmethod
    def _drain(sock: socket.socket) -> list[bytes]:
        out = []
        while True:
            try:
                out.append(sock.recv(2048))
            except (BlockingIOError, InterruptedError):
                break
            except OSError:
                break
        return out

    def run(self):
        flows = []
        try:
            for host, port in STUN_SERVERS:
                try:
                    infos = socket.getaddrinfo(host, port, socket.AF_INET, socket.SOCK_DGRAM)
                    if not infos:
                        continue
                    addr = infos[0][4]
                    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    try:
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024)
                        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 256 * 1024)
                    except OSError:
                        pass
                    sock.setblocking(False)
                    sock.connect(addr)
                    flows.append({"name": host, "sock": sock, "pending": {}})
                except OSError as e:
                    self.store.probe_error = f"{host}: {e}"
            if not flows:
                self.store.probe_error = "no STUN servers reachable"
                self.store.add_event("probe: no STUN servers reachable")
                return

            self.store.add_event(f"probe: {len(flows)} STUN flow(s) @ {RATE_HZ}Hz")
            interval = 1.0 / RATE_HZ
            next_tick = time.perf_counter()

            while not self._stop.is_set():
                active = self.store.client_active()
                with self.store.lock:
                    self.store.recording = active
                if not active:
                    time.sleep(0.2)
                    next_tick = time.perf_counter()
                    continue

                batch_samples: list[tuple[float, float, str]] = []
                batch_spikes: list[tuple[float, float, str, bool]] = []

                def take_replies():
                    now_perf = time.perf_counter()
                    for f in flows:
                        for data in self._drain(f["sock"]):
                            tid = stun_tid(data)
                            if not tid or tid not in f["pending"]:
                                continue
                            sent_at = f["pending"].pop(tid)
                            recv_t = time.perf_counter()
                            rtt = round((recv_t - sent_at) * 1000.0, 1)
                            if rtt < 0 or rtt > 5000:
                                continue
                            t_wall = now_ms()
                            batch_samples.append((t_wall, rtt, f["name"]))
                            if rtt >= SPIKE_MS:
                                batch_spikes.append(
                                    (t_wall, rtt, f["name"], rtt >= LARGE_MS)
                                )
                        dead = [
                            k
                            for k, v in f["pending"].items()
                            if (now_perf - v) * 1000.0 > TIMEOUT_MS
                        ]
                        for k in dead:
                            f["pending"].pop(k, None)

                # Drain first (catch replies that arrived during sleep), then send
                take_replies()
                for f in flows:
                    try:
                        pkt, tid = stun_request()
                        send_t = time.perf_counter()
                        f["sock"].send(pkt)
                        f["pending"][tid] = send_t
                        with self.store.lock:
                            self.store.sent += 1
                    except OSError:
                        pass
                take_replies()

                if batch_samples or batch_spikes:
                    with self.store.lock:
                        for t_wall, rtt, flow, large in batch_spikes:
                            self.store.slow += 1
                            if large:
                                self.store.large += 1
                            self.store.add_spike(t_wall, rtt, flow, large)
                        # One point per tick = worst reply among the 3 STUN flows.
                        # Plotting every flow separately zigzags between their
                        # different baselines (looks like a two-level square wave).
                        if batch_samples:
                            peak = max(batch_samples, key=lambda x: x[1])
                            self.store.add_sample(peak[0], peak[1], peak[2])

                next_tick += interval
                delay = next_tick - time.perf_counter()
                if delay > 0:
                    time.sleep(delay)
                else:
                    # fell behind — resync so we don't spin
                    next_tick = time.perf_counter()
        finally:
            for f in flows:
                try:
                    f["sock"].close()
                except OSError:
                    pass
            with self.store.lock:
                self.store.recording = False


class HistoryStore(DataStore):
    """Optional CSV replay for older disk runs (no probing)."""

    def __init__(self, run_dir: Path):
        super().__init__(label=str(run_dir))
        self.run_dir = run_dir
        self.spike_path = run_dir / "spikes.csv"
        self.sample_path = run_dir / "samples.csv"
        self.status_path = run_dir / "status.txt"
        self.anchor_path = run_dir / "cycle-anchor.txt"
        self.event_path = run_dir / "events.log"
        self.spike_pos = 0
        self.sample_pos = 0
        self.spike_partial = ""
        self.sample_partial = ""

    def _read_grow(self, path: Path, pos: int, partial: str) -> tuple[int, str, list[str]]:
        if not path.exists():
            return pos, partial, []
        size = path.stat().st_size
        if pos > size:
            pos = 0
            partial = ""
        if size <= pos:
            return pos, partial, []
        with path.open("rb") as f:
            f.seek(pos)
            chunk = f.read(size - pos)
        pos = size
        text = partial + chunk.decode("utf-8", errors="replace")
        parts = re.split(r"\r?\n", text)
        if text.endswith("\n") or text.endswith("\r"):
            partial = ""
            lines = parts
        else:
            partial = parts[-1]
            lines = parts[:-1]
        return pos, partial, lines

    def sync(self):
        with self.lock:
            sp_before = len(self.spikes)
            self.spike_pos, self.spike_partial, lines = self._read_grow(
                self.spike_path, self.spike_pos, self.spike_partial
            )
            for line in lines:
                if not line or line.startswith("timestamp"):
                    continue
                p = line.split(",")
                if len(p) < 3:
                    continue
                try:
                    t = parse_iso(p[0])
                    rtt = float(p[2])
                    large = (len(p) >= 4 and p[3].strip() == "1") or rtt >= LARGE_MS
                    flow = p[1] if len(p) > 1 else ""
                    self.spikes.append({"t": t, "rtt": rtt, "large": large, "flow": flow})
                    if self.anchor is None and large:
                        self.anchor = t
                except Exception:
                    continue
            if len(self.spikes) != sp_before:
                self._rebuild_clumps()

            self.sample_pos, self.sample_partial, lines = self._read_grow(
                self.sample_path, self.sample_pos, self.sample_partial
            )
            for line in lines:
                if not line or line.startswith("timestamp"):
                    continue
                p = line.split(",")
                if len(p) < 3:
                    continue
                try:
                    t = parse_iso(p[0])
                    rtt = float(p[2])
                    self.samples.append({"t": t, "rtt": rtt})
                except Exception:
                    continue

            if self.anchor is None and self.anchor_path.exists():
                try:
                    self.anchor = parse_iso(self.anchor_path.read_text(encoding="utf-8").strip())
                except Exception:
                    pass
            if self.status_path.exists():
                try:
                    self.recording = "status=recording" in self.status_path.read_text(
                        encoding="utf-8", errors="replace"
                    )
                except Exception:
                    pass
            if self.event_path.exists():
                try:
                    raw = self.event_path.read_bytes()
                    take = raw[-8000:] if len(raw) > 8000 else raw
                    text = take.decode("utf-8", errors="replace")
                    for ln in [x for x in text.splitlines() if x.strip()][-30:]:
                        if ln not in self.events:
                            self.events.append(ln)
                except Exception:
                    pass


STORE: DataStore | None = None
PROBE: StunProbe | None = None
LIVE_MODE = True


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        if args and str(args[0]).startswith("GET /api/"):
            return
        super().log_message(fmt, *args)

    def _cors(self):
        origin = self.headers.get("Origin", "")
        # Allow GitHub Pages (HTTPS) to call this local probe (HTTP localhost).
        # Chrome also requires Allow-Private-Network on the preflight.
        if (
            origin.endswith(".github.io")
            or origin.startswith("http://127.0.0.1")
            or origin.startswith("http://localhost")
        ):
            self.send_header("Access-Control-Allow-Origin", origin)
            self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
            self.send_header(
                "Access-Control-Allow-Headers",
                "Content-Type, Access-Control-Request-Private-Network",
            )
            self.send_header("Access-Control-Allow-Private-Network", "true")
            self.send_header("Vary", "Origin")

    def _json(self, obj, code=200):
        data = json.dumps(obj, separators=(",", ":")).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self._cors()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _file(self, path: Path):
        if not path.exists() or not path.is_file():
            self.send_error(404)
            return
        ctype = mimetypes.guess_type(str(path))[0] or "application/octet-stream"
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Cache-Control", "no-cache")
        self._cors()
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_OPTIONS(self):
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self):
        global STORE
        assert STORE is not None
        u = urlparse(self.path)
        path = u.path
        q = parse_qs(u.query)

        if path.startswith("/api/"):
            STORE.touch_client()
            if not LIVE_MODE and isinstance(STORE, HistoryStore):
                try:
                    STORE.sync()
                except Exception as e:
                    return self._json({"error": str(e)}, 500)

            if path in ("/api/meta", "/api/ping"):
                with STORE.lock:
                    t0, t1 = STORE.bounds()
                    payload = {
                        "runDir": STORE.label,
                        "t0": t0,
                        "t1": t1,
                        "anchor": STORE.anchor,
                        "recording": STORE.recording if LIVE_MODE else STORE.recording,
                        "live": LIVE_MODE,
                        "statusText": STORE.status_text(),
                        "spikeCount": len(STORE.spikes),
                        "sampleCount": len(STORE.samples),
                        "minimap": STORE.minimap(900),
                    }
                return self._json(payload)
            if path == "/api/spikes":
                t0 = float(q.get("t0", ["0"])[0])
                t1 = float(q.get("t1", ["0"])[0])
                budget = int(q.get("budget", ["400"])[0])
                with STORE.lock:
                    return self._json({"spikes": STORE.spikes_in(t0, t1, budget)})
            if path == "/api/samples":
                t0 = float(q.get("t0", ["0"])[0])
                t1 = float(q.get("t1", ["0"])[0])
                budget = int(q.get("budget", ["1200"])[0])
                with STORE.lock:
                    return self._json({"samples": STORE.samples_in(t0, t1, budget)})
            if path == "/api/events":
                tail = int(q.get("tail", ["30"])[0])
                with STORE.lock:
                    lines = list(STORE.events)[-tail:]
                return self._json({"lines": lines})
            return self._json({"error": "unknown api"}, 404)

        rel = "index.html" if path in ("/", "") else path.lstrip("/")
        rel = rel.split("?")[0]
        if ".." in rel or rel.startswith("/"):
            return self.send_error(400)
        return self._file(WEB / rel)


def main():
    global STORE, PROBE, LIVE_MODE
    ap = argparse.ArgumentParser(description="Spike timeline website (live in-memory recording)")
    ap.add_argument(
        "--run-dir",
        default="",
        help="Optional: replay an old disk run instead of live probing",
    )
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()

    if not WEB.is_dir():
        raise SystemExit(f"Missing {WEB}")

    if args.run_dir:
        run_dir = Path(args.run_dir)
        if not run_dir.is_dir():
            raise SystemExit(f"RunDir not found: {run_dir}")
        LIVE_MODE = False
        STORE = HistoryStore(run_dir)
        STORE.sync()
        print("Spike timeline (history replay)")
        print(f"  run : {run_dir}")
    else:
        LIVE_MODE = True
        STORE = DataStore(label="live-memory")
        PROBE = StunProbe(STORE)
        PROBE.start()
        print("Spike timeline (live — records in memory while the page is open)")
        print("  Close the browser tab to pause probing; close this server to stop.")

    print(f"  url : http://127.0.0.1:{args.port}/")

    httpd = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    if not args.no_browser:
        threading.Timer(0.4, lambda: webbrowser.open(f"http://127.0.0.1:{args.port}/")).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        if PROBE is not None:
            PROBE.stop()


if __name__ == "__main__":
    main()
