# Network outage detector

Cross-machine tools to tell whether brief network dropouts are **this PC** or **the network/path**.

Run the same test on two machines on the same Wi‑Fi. If both see similar loss/outages, it's the network. If only one does, it's that machine.

## Quick start (Windows)

1. Clone or download this repo.
2. Open PowerShell in the repo folder.
3. Double‑click `Run-OutageTest.bat` on both machines.

The test waits until the next 5‑minute clock mark (`:00`, `:05`, `:10`, …), then runs for 10 minutes. Start both machines any time in the same 5‑minute window and they begin together.

```powershell
powershell -ExecutionPolicy Bypass -File .\Test-PersistentFlow.ps1 -Label laptop
```

Results are written under `logs\`.

## What each script does

| Script | Use when |
|--------|----------|
| `Test-PersistentFlow.ps1` | **Best A/B test.** Holds long-lived UDP flows (like games/Discord) and reports loss, multi-packet outages, every packet slower than 100 ms, and NAT rebinds. |
| `Monitor-Long.ps1` | Long session (default 45 min). Note the clock when you feel a stutter and match it to the live log. |
| `Detect-Dropout.ps1` | High-rate gateway ping dropout detector (gateway ICMP can be rate-limited — treat carefully). |
| `Detect-Correlated.ps1` | Low-rate multi-target check: gateway vs public IPs vs local freezes. |
| `Test-RealTraffic.ps1` | UDP DNS + ICMP + TCP comparison. |
| `Watch-UdpBurst.ps1` | Watches for local UDP socket bursts / port exhaustion. |

## Laptop vs desktop comparison

On **both** machines, start `Run-OutageTest.bat` before the same 5‑minute mark. Each run lasts 10 minutes from that mark.

Compare the summary lines:

- `outages (>=3 consecutive)` and `Outages hitting 2+ flows`
- per-flow loss %
- `NAT rebinds observed`

**Same outages on both** → path / Wi‑Fi / ISP.  
**Only one machine** → that PC (driver, VPN, filter, power save, etc.).

No admin rights required for the main tests. Logs stay local; nothing is uploaded.
