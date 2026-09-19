# ZZ_ScalpHFT

A tick-driven ZigZag swing-retrace scalper for MetaTrader 5.

The EA maps the last two ZigZag swing points once per closed bar, derives a single price
level from the most recent leg, and then watches every tick for a cross of that level.
When the cross happens and the gates pass, it fires a market order (or parks a
short-lived stop order at the level). Exits are a fixed stop and target, break-even,
a stepped trail and a time stop.

Everything on the tick path is O(1). The only expensive work — the ZigZag rebuild — runs
once per new bar.

> **Status: untested.** The code compiles as a single file with no external dependencies,
> but it has not been backtested or run on a live account. Every default is a placeholder,
> not an optimized value. Read [Before you trade it](#before-you-trade-it).

---

## Contents

- [Where it came from](#where-it-came-from)
- [How it works](#how-it-works)
  - [Tick pipeline](#tick-pipeline)
  - [The swing map](#the-swing-map)
  - [From swing to trigger](#from-swing-to-trigger)
  - [The entry state machine](#the-entry-state-machine)
  - [Gates](#gates)
  - [Position management](#position-management)
  - [Account guards](#account-guards)
- [Inputs](#inputs)
- [Installing and testing](#installing-and-testing)
- [Tuning guide](#tuning-guide)
- [Known gaps and limitations](#known-gaps-and-limitations)
- [Before you trade it](#before-you-trade-it)

---

## Where it came from

The starting point was a swing-breakout EA built around three modules: a ZigZag signal
engine, a trade engine, and a thin EA shell. That design targeted a slow strategy — one
evaluation per closed M15 bar, stop orders parked up to twelve hours, stop distances in
the hundreds-to-thousands of points.

Scalping inverts most of those assumptions, so the execution layer was rebuilt rather than
patched. What carried over, what changed, and why:

| Area | Original | Here | Reason |
|---|---|---|---|
| ZigZag algorithm | Two-pass depth/deviation/backstep map | Same, unchanged | The extrema logic was sound; only its cadence was wrong |
| Evaluation cadence | Once per new bar, full 300-bar rebuild | Rebuild once per closed bar, cached; decide on every tick | A scalper that only looks once a bar misses its own entry |
| Signal timeframe | M15 / M30 | M1 by default | Leg size has to match the target size |
| Entry | Stop order at the swing level, GTC-managed for up to 12h | Market order on the cross, or a stop order with a seconds-scale TTL | A pending order that outlives its setup is a different trade by the time it fills |
| Setup lifetime | Expiry measured in hours | Expiry tied to the setup itself — new swing invalidates it | The reason for the trade decays in minutes, not hours |
| Loss/limit tracking | `HistorySelect` over the full history on every tick | `OnTradeTransaction` event, history read once at init and on day rollover | A full history scan per tick is the single most expensive thing you can do in `OnTick` |
| Exits | Fixed SL/TP plus trailing | Adds break-even and a hard time stop | Scalps that stall are cost, not opportunity |
| Structure | Three files, shared globals across includes | One file, explicit state block | Easier to reason about the tick path |
| Parameter set | Vendor-derived named profiles | Own inputs, no profile tables | See [Provenance](#provenance) |

Deliberately dropped: sticky directional exposure latches, pre-management exposure
snapshots, and the hour-relative session quirks. Those existed to reproduce a specific
binary's behavior. They aren't strategy.

### Provenance

The original header described the code as reconstructed from a commercial EA's observed
runtime behavior. This rebuild contains none of that vendor's named profiles, parameter
tables or branding — those were left out entirely. The ZigZag routine is the standard
public algorithm shipped with MetaTrader, not vendor-specific work. If you intend to
distribute or sell this, check the terms attached to whatever you derived the original
from.

---

## How it works

### Tick pipeline

`OnTick` runs in a fixed order. Each step is cheap and the expensive one is gated.

```
OnTick
 ├─ SymbolInfoTick              fail → return
 ├─ PushTick                    ring buffer, 256 slots, O(1)
 ├─ new bar?  → RefreshSetup    the only heavy call; once per closed bar
 ├─ UpdateDailyLatch            day rollover + daily loss/profit latch
 ├─ ManagePositions             time stop, break-even, trail
 ├─ throttle (InpEvalIntervalMs)   optional; 0 = evaluate every tick
 ├─ ManagePendings              drop stale/expired stop orders
 └─ EvaluateEntry               arm, cross, gates, send
```

Position management sits **before** the throttle, so protective logic still runs on every
tick even when entry evaluation is being rate-limited.

`OnTradeTransaction` handles closed deals, updating the consecutive-loss counter without
touching history on the tick path.

### The swing map

`RefreshSetup()` fires when `iTime(_Symbol, InpSignalTF, 0)` changes — i.e. a bar has just
closed.

1. `CopyRates` from index **1**, so the forming bar never participates. `InpBarsToScan`
   bars are copied as a series array.
2. `BuildZigZag()` runs the standard two-pass algorithm:
   - **Pass 1** walks oldest → newest, marking each bar that holds the lowest low (or
     highest high) of the `InpZZDepth` window ahead of it. Candidates further than
     `InpZZDeviationPts` from the current bar's own extreme are discarded, and each new
     candidate clears weaker candidates in the preceding `InpZZBackstep` slots.
   - **Pass 2** forces strict alternation: a high must be followed by a low. When two
     same-side candidates appear in a row, the more extreme one survives and the earlier
     one is erased.
3. The two newest non-zero points in the composite buffer become the last leg.

If `CopyRates` returns too little data, the function returns `false` and the bar marker is
**not** advanced, so the rebuild is retried on the next tick rather than skipped for the
whole bar.

**Note on point scaling:** the deviation is applied as raw `SYMBOL_POINT`, with no 3/5-digit
multiplier. On a 5-digit FX pair, `InpZZDeviationPts = 10` means 1 pip, not 10. Scale the
input to your symbol rather than assuming pip semantics.

### From swing to trigger

Given the newest swing `P₁` and the one before it `P₂`:

```
leg size   = |P₂ − P₁|                       (rejected outside Min/MaxLegPts)
direction  = +1 if P₂ > P₁   (leg went down → look to buy)
             −1 if P₁ > P₂   (leg went up   → look to sell)
level      = P₁ + (P₂ − P₁) × InpLegFraction
trigger    = level ∓ InpTriggerLeadPts × Point
```

With `InpLegFraction = 1.0` the level is the leg's **origin** — the swing the market moved
away from. The trade is taken when price travels all the way back to that origin and
crosses it. Lower the fraction (0.618, 0.5) to trigger partway back instead.

`InpTriggerLeadPts` shifts the trigger slightly in front of the level so the order fires
just before the crowd's level rather than into it.

The setup is rejected when the newest swing is older than `InpMaxSwingAgeBars`, or when
the leg is outside `[InpMinLegPts, InpMaxLegPts]`. Rejection means no setup, not a stale
one — `g_setup.valid` goes false and nothing can fire.

A setup is identified by the open time of its newest swing bar. When that key changes, the
arm and consume flags reset and a fresh setup begins.

### The entry state machine

Two flags per setup, both reset when the setup key changes:

- **`g_armed`** — set once price has been observed on the *pre-trigger* side. Without this,
  a setup created while price already sits past the level would fire instantly on a
  meaningless "cross".
- **`g_consumed`** — one entry attempt per setup, win or lose. Prevents a chopping market
  from re-firing the same level repeatedly.

**Market mode** (`ENTRY_MARKET_ON_TRIGGER`):

```
armed?  and  price has crossed the trigger?
  └─ distance past trigger > InpMaxChasePts?  → mark consumed, skip (gapped through)
  └─ momentum check passes?                   → send market order, mark consumed
```

Marking a gapped-through setup as consumed is deliberate. If price blew past the level,
the level is history, and chasing it is the worst version of this trade.

**Pending mode** (`ENTRY_PENDING_STOP`): while price is still approaching and within
`InpPendingMaxDistPts` of the trigger, a Buy/Sell Stop is placed at the level. Only one
per direction. `ManagePendings` deletes it once it exceeds `InpPendingTTLSec` or stops
matching the current setup's direction and price.

Pending mode gets you queue position and a known fill price. Market mode gets you the
momentum filter, which can't be evaluated at fill time by a resting order. Pick per broker.

### Gates

`EntriesAllowed()` — all must pass:

| Gate | Behavior |
|---|---|
| Daily latch | Hard block once a daily loss/profit limit has triggered, until the next server day |
| Session | Server-hour window, wraps midnight correctly; optional Friday early cutoff |
| Spread | Blocks above `InpMaxSpreadPts` (0 disables) |
| Exposure | Positions + pendings vs `InpMaxOpenPositions` |
| Cooldown | `InpMinSecBetweenEntries` since the last entry |
| Loss streak | After `InpMaxConsecLosses`, blocked for `InpLossPauseMin` minutes, then the counter clears |

**Momentum filter** (`InpUseMomentum`) is separate and applies to entries only. A 256-slot
tick ring buffer stores `time_msc` and mid-price. The filter walks backwards until it
leaves the `InpMomentumWindowMs` window and requires both a minimum tick count
(`InpMomentumMinTicks`) and a net mid-price move of `InpMomentumPts` in the trade's
direction. It rejects a cross that is drifting rather than being pushed.

A failed order send sets a 1-second back-off (`g_blockUntilMsc`) so a rejecting broker
can't be hammered tick after tick.

### Position management

Runs every tick, per position, magic- and symbol-filtered.

- **Time stop** — closes at `InpMaxHoldSec` regardless of P/L. First check in the loop.
- **Break-even** — at `InpBEStartPts` profit, the stop moves to entry ± `InpBELockPts`.
- **Trail** — at `InpTrailStartPts` profit, the stop follows at `InpTrailDistPts`.

Break-even and trail both feed through `BetterStop()`, which only ever accepts a *more*
protective level. A stop never moves backwards, including after a restart onto an existing
position.

Before any modification is sent, four checks:

1. The change must exceed `InpTrailStepPts` — no sub-step churn.
2. The candidate must clear `SYMBOL_TRADE_STOPS_LEVEL` plus a small buffer.
3. Nothing is modified while the existing SL or TP is inside `SYMBOL_TRADE_FREEZE_LEVEL`.
4. A 150 ms global throttle between modifications.

SL and TP at entry are clamped the same way: `BuildSLTP()` enforces
`max(requested, StopsLevel + spread + 2 points)`, so a tight input on a wide-stops broker
is widened rather than rejected.

### Account guards

`UpdateDailyLatch()` compares current equity against the day-start balance.

The day-start balance is **reconstructed**, not snapshotted: at init and on every server-day
rollover, the EA sums realized trading P/L since midnight and subtracts it from the current
balance. Restarting the terminal mid-session therefore does not reset your daily loss
limit.

When a limit trips, entries stop for the rest of the server day, and — if
`InpCloseOnDailyStop` is set — open positions and pendings are flattened immediately.

The consecutive-loss counter is maintained incrementally from `OnTradeTransaction`, counting
only closing deals (`DEAL_ENTRY_OUT`, `OUT_BY`, `INOUT`) with commission, swap and fees
included in the net. Any profitable close resets it to zero.

---

## Inputs

Defaults are sized for a **2-digit XAUUSD** symbol, where 100 points = 1.00 in price.
They are starting points for testing, not recommendations.

### Signal: ZigZag swing map

| Input | Default | Meaning |
|---|---|---|
| `InpSignalTF` | `PERIOD_M1` | Timeframe the swing map is built on |
| `InpZZDepth` | 6 | ZigZag window, in bars |
| `InpZZDeviationPts` | 10 | ZigZag deviation, raw points |
| `InpZZBackstep` | 3 | Slots cleared behind a new candidate |
| `InpBarsToScan` | 150 | Closed bars copied per rebuild |
| `InpMinLegPts` | 200 | Reject legs smaller than this |
| `InpMaxLegPts` | 2000 | Reject legs larger than this |
| `InpMaxSwingAgeBars` | 15 | Newest swing must be no older than this |
| `InpLegFraction` | 1.00 | Fraction of the leg to trigger at (1.0 = origin) |
| `InpTriggerLeadPts` | 20 | Fire this far in front of the level |

### Entry

| Input | Default | Meaning |
|---|---|---|
| `InpEntryMode` | Market | Market on cross, or short-lived stop order |
| `InpMaxChasePts` | 40 | Market: abandon if price is already this far past |
| `InpPendingMaxDistPts` | 120 | Pending: only place within this distance |
| `InpPendingTTLSec` | 20 | Pending: delete after this many seconds |
| `InpUseMomentum` | true | Require tick momentum toward the trade |
| `InpMomentumWindowMs` | 1500 | Momentum window |
| `InpMomentumPts` | 30 | Net mid move required in the window |
| `InpMomentumMinTicks` | 4 | Minimum ticks in the window |
| `InpMaxSpreadPts` | 35 | Spread ceiling (0 = off) |
| `InpMaxOpenPositions` | 1 | Positions + pendings (0 = unlimited) |
| `InpMinSecBetweenEntries` | 5 | Entry cooldown |
| `InpEvalIntervalMs` | 0 | Throttle entry evaluation (0 = every tick) |
| `InpDeviationPts` | 20 | Max slippage on market orders |

### Exits

| Input | Default | Meaning |
|---|---|---|
| `InpSLPts` | 120 | Stop loss — **must be > 0** |
| `InpTPPts` | 180 | Take profit (0 = none) |
| `InpBEStartPts` | 70 | Break-even trigger (0 = off) |
| `InpBELockPts` | 10 | Points locked at break-even |
| `InpTrailStartPts` | 100 | Trail activation (0 = off) |
| `InpTrailDistPts` | 45 | Trail distance |
| `InpTrailStepPts` | 10 | Minimum improvement per modification |
| `InpMaxHoldSec` | 180 | Time stop (0 = off) |

### Risk

| Input | Default | Meaning |
|---|---|---|
| `InpLotMode` | Fixed | Fixed lots or equity-risk sizing |
| `InpFixedLots` | 0.01 | Fixed volume, also the fallback |
| `InpRiskPercent` | 0.25 | % equity risked at the stop |
| `InpDailyLossPercent` | 3.0 | Daily loss cutoff vs day-start balance (0 = off) |
| `InpDailyProfitPercent` | 0.0 | Daily profit cutoff (0 = off) |
| `InpCloseOnDailyStop` | true | Flatten when a daily limit trips |
| `InpMaxConsecLosses` | 4 | Losses before a pause (0 = off) |
| `InpLossPauseMin` | 30 | Pause length in minutes |

### Session and misc

| Input | Default | Meaning |
|---|---|---|
| `InpUseSession` | true | Enable the server-hour window |
| `InpSessionStartHour` / `InpSessionEndHour` | 7 / 21 | Window, wraps midnight if start > end |
| `InpFridayEarlyStop` | true | Stop early on Friday |
| `InpFridayStopHour` | 20 | Friday cutoff hour |
| `InpMagic` | 424242 | Magic number |
| `InpComment` | `ZZScalpHFT` | Order comment |
| `InpVerbose` | false | Diagnostic logging |

Risk sizing falls back to `InpFixedLots` whenever `OrderCalcProfit` fails or the computed
volume lands below `SYMBOL_VOLUME_MIN` — volume is floored to the step and **never**
rounded up to the minimum.

Validated at init: `InpSLPts > 0`, `InpZZDepth ≥ 2`, `InpBarsToScan ≥ InpZZDepth + 20`,
`0 < InpLegFraction ≤ 1.5`.

---

## Installing and testing

1. Copy `ZZ_ScalpHFT.mq5` into `MQL5/Experts/`.
2. Compile in MetaEditor (F7). No external includes beyond `Trade\Trade.mqh`.
3. Backtest in the Strategy Tester with modelling set to **Every tick based on real ticks**.

The real-ticks requirement is not optional. The momentum filter reads `time_msc` deltas and
intra-bar tick sequence; on generated ticks it measures an artifact of the tester's
interpolation, and any result you get is fiction.

Run with `InpVerbose = true` for the first sessions. The log reports each new setup with
its direction, trigger and leg size, plus the retcode and description behind every rejected
send — which is usually where the first real problem shows up.

**A sane first pass:**

1. Fixed lots at minimum, momentum off, pending mode off. Confirm setups appear at sensible
   levels and orders fill at all.
2. Turn momentum on. Compare trade count and average result.
3. Only then touch stop and target sizing.
4. Forward-test on demo before anything else. A tick-level scalper's backtest hides exactly
   the costs — latency, slippage, requotes, variable spread — that decide whether it works.

---

## Tuning guide

**The stop-to-leg relationship is the thing that matters.** `InpSLPts` should be sized
against typical leg size, not picked in isolation. If the ZigZag is producing 200-point
legs on your symbol and your stop is 120, you're stopping out inside normal noise.

**Symbol scaling.** All point inputs are raw `SYMBOL_POINT`. Moving from 2-digit gold to a
5-digit FX pair means rescaling essentially every distance input.

**Fewer, better setups:** raise `InpZZDepth`, raise `InpMinLegPts`, lower
`InpMaxSwingAgeBars`.

**Earlier entries:** lower `InpLegFraction` toward 0.5–0.618 so you enter partway into the
retrace rather than at the origin. Expect more trades and a lower hit rate.

**Broker rejects your orders:** check `SYMBOL_TRADE_STOPS_LEVEL`. If it exceeds your stop
distance, `BuildSLTP` silently widens your stop, and your real risk per trade is larger than
your input says. Verify with `InpVerbose`.

**Too much CPU / too many evaluations:** set `InpEvalIntervalMs` to 100–250. Position
management still runs every tick.

---

## Known gaps and limitations

- **Single symbol, single position.** One chart, one instrument. No basket or portfolio
  logic, no correlation awareness.
- **No news filter.** Nothing blocks entries around scheduled releases. A scalper with a
  120-point stop into an NFP print is a donation.
- **No partial closes.** Positions exit whole.
- **Momentum uses mid-price only.** No volume, no order-book imbalance, no microstructure
  beyond net drift over a window.
- **Session logic is server-hour based.** No DST handling, no broker-session awareness, no
  holiday calendar.
- **Time stop is unconditional.** It closes a winner at `InpMaxHoldSec` as readily as a
  loser.
- **The daily-loss reconstruction assumes one EA per account** for account-wide P/L. Running
  several EAs on the same account will make them see each other's results.
- **Ring buffer is 256 ticks.** On a very fast symbol that may not span the full momentum
  window; the filter then measures whatever it has and reports fewer ticks, which usually
  fails the `InpMomentumMinTicks` check rather than lying.

---

## Before you trade it

- **This has never been tested.** It compiles as written; it has not been backtested, demo
  traded or run live. Treat it as a starting implementation, not a finished product.
- **The defaults are placeholders.** They were chosen for readability on a 2-digit XAUUSD,
  not derived from any test.
- **Scalping is the strategy class most sensitive to costs you can't see in a backtest.**
  Spread, commission, slippage, latency and broker execution quality will dominate the
  result. A strategy that looks profitable in the tester routinely isn't once these are
  real.
- **Prop firm accounts:** check the rules before deploying. Many firms restrict or ban
  HFT-style entries, impose minimum hold times, and penalize tick-scalping patterns. The
  `InpMaxHoldSec` time stop in particular can put you in direct conflict with a minimum-hold
  rule.
- **Nothing here is financial advice.** You own the outcome of anything you run.
