# XauusdScalper design

Regime-adaptive XAUUSD M5 Expert Advisor for MetaTrader 5. Version **1.10**.

This document is the source of truth for regime logic, the four strategies, liquidity sweeps / fake-breakout handling, shared risk and **equity-drawdown-aware** lot sizing, the on-chart dashboard, every input and its default, how to backtest, and the disclaimer.

Source lives in `MQL5/Experts/XauusdScalper/`. Compile `XauusdScalper.mq5` in MetaEditor.

**No EA guarantees profit.** See [Disclaimer](#disclaimer).

---

## 1. Pipeline

Per **closed signal-timeframe bar** (default M5):

1. `CMarketData` builds one `SMarketContext` (index 0 = last closed bar).
2. Every strategy `OnBar` runs (the breakout module may report a failed breakout).
3. `CLiquidityMap` rebuilds pools and looks for a fresh sweep (including that failed breakout).
4. `CRegimeDetector` classifies with hysteresis.
5. `CStrategySelector` asks enabled, regime-suited modules in **registration order**. First setup that passes the fake-out guard wins and is held for `InpSignalValiditySec`.
6. Tick path: session / news / spread / symbol-mode filters → `CRiskManager.CanOpen` + `PlanTrade` (stop + DD-aware size) → `CTradeManager.Open`.
7. Every tick: equity guard, time exits, shared trade management, dashboard.

Strategies only choose **direction**, a **structural invalidation** (optional), and a **natural target** (optional). They never pick a lot size or a raw stop distance.

Magic number = `InpMagic + strategyId` (1..4). Positions and deals are tagged so the dashboard can split P/L.

---

## 2. Market context

Built from the last closed bar, shared by every module.

| Field | Source / meaning |
|---|---|
| OHLC `[40]` | Signal TF, series, index 0 = last closed |
| Fast / slow EMA | Close EMA 21 / 50 (3 bars) |
| ATR + ATR percentile | ATR(14) rank vs `InpPctLookback` (288 ≈ 1 day of M5) |
| ADX / +DI / −DI | ADX(14) |
| Bollinger mid / upper / lower | 20, 2σ |
| BB width % and expansion | Width rank vs lookback; width now / width `InpBbExpandBars` ago |
| RSI | RSI(9), 3 bars |
| Slow-EMA slope | `(EMA_slow[0] − EMA_slow[slopeBars]) / ATR` |
| HTF bias | H1 EMA(50): +1 / −1 / 0 from close vs EMA and EMA slope |
| Volume ratio | Last-bar tick volume / average of previous `InpVolAvgPeriod` |
| Activity ratio | Recent average tick volume / `InpActivityLookback` baseline |

If indicators or history are not ready, the bar is retried on the next tick.

---

## 3. Regime logic

Single-bar raw class, then hysteresis so the active strategy does not flip-flop.

### 3.1 Raw class (first match)

1. **CHAOTIC** (stand aside) — ATR percentile ≥ 99 **or** last bar range ≥ 4 × ATR.
2. **QUIET** (stand aside) — ATR percentile ≤ 15 **or** activity ratio ≤ 0.6.
3. **BREAKOUT** — ATR percentile ≥ 70, Bollinger-width expansion ≥ 1.3, tick-volume surge ≥ 1.5. Direction = close vs band middle. While already in breakout, thresholds ease (percentile −10, expansion 1.0, activity ≥ 1).
4. **TREND** — ADX ≥ 25, |slow-EMA slope| ≥ 0.8 ATR over the slope window, slope direction matches EMA stack, and (if enabled) HTF bias agrees. While already in trend: ADX ≥ 20, slope ≥ 0.48 ATR.
5. **RANGE** — ADX ≤ 20, |slope| < trend-enter slope, BB-width percentile in [15, 70]. While already in range: ADX ≤ 24.
6. **NONE** — mixed / undefined: stand aside.

### 3.2 Hysteresis

- A new regime must persist `InpRegimeConfirmBars` (3) bars.
- A tradeable regime is held at least `InpRegimeMinHoldBars` (6) bars before a non-urgent switch.
- **CHAOTIC is applied immediately** (no confirm), so the EA steps aside in a spike.

Tradeable regimes: TREND, RANGE, BREAKOUT. Quiet / chaotic / none: no new entries.

### 3.3 Open trades when the regime changes

`InpRegimeExit` (default **Protect**):

- **Keep** — shared BE / trail / stale rules only.
- **Protect** — if the opening strategy no longer suits the regime: lock breakeven once profit ≥ `InpProtectMinR` (0.3R); cut a loser at half of `InpMaxHoldBars`.
- **Close** — exit immediately.

---

## 4. Strategies

Registration order = priority inside a regime. Default order: SweepReversal → VolBreakout → TrendPullback → MeanReversion.

A non-sweep setup is **rejected** if the liquidity map has a fresh sweep in the opposite direction (fake-out guard).

### 4.1 SweepReversal (`id=4`)

Trades the **reclaim after a liquidity sweep**.

Enabled in RANGE / TREND / BREAKOUT (all on by default). In TREND, `InpSweepWithTrendOnly` keeps only with-trend reversals.

Needs a sweep on the current closed bar, pool strength ≥ `InpSweepMinStrength` (2), and close back inside the level by at least `InpSweepMinReclaimAtr` (0.05 ATR).

Stop anchor = sweep **extreme** (furthest wick), not the obvious pool price. The risk manager then adds the structural ATR buffer and pushes the stop off nearby pools.

### 4.2 VolBreakout (`id=3`)

BREAKOUT regime only. Always registered (even if `InpUseVolBreakout` is false) so it can still **report failed breakouts** to the liquidity map.

A qualifying break bar:

- Donchian of the prior `InpBoRangeBars` (12) bars
- Close beyond the range by `InpBoBufferAtr` (0.1 ATR) — **wicks through do not count**
- Body ≥ 50% of the bar, close in the extreme 30%, tick-volume surge ≥ 1.5
- Not more than 1.5 ATR from the fast EMA (no chase)
- Optional HTF agreement

Confirmation (`InpBoConfirm`, default **Hold**):

- **Close** — trade the break bar (fastest, most fake-outs)
- **Hold** — next bar stays beyond the level (default)
- **Retest** — price returns to the level and holds

Invalidation = back inside the broken range.

If price closes back through the level, the module calls `ReportFailedBreakout`. That level becomes sweep liquidity.

### 4.3 TrendPullback (`id=1`)

TREND regime. With-trend only.

- Touch the fast EMA within `InpTpZoneAtr` (0.3 ATR), still on the slow-EMA side
- Rejection body in the trend direction, close through the fast EMA and beyond the prior close
- RSI in [45, 75] for longs (mirrored for shorts), DI agrees
- Tick volume ≥ 0.8 × average

Stop anchor = swing low/high over `InpTpAnchorBars` (6).

### 4.4 MeanReversion (`id=2`)

RANGE regime.

- Pierce the Bollinger band (this bar or previous), then close back inside with a rejection body
- RSI ≤ 30 (long) or ≥ 70 (short) and turning
- Skip if tick-volume surge > 1.8 (breakout risk, not a fade)
- Natural target = band middle; reject if that target is closer than `InpMrMinTargetR` (0.7R)

Stop anchor = excursion extreme over `InpMrAnchorBars` (3).

---

## 5. Liquidity sweeps and fake breakouts

### 5.1 Pools

Rebuilt every closed bar from (all on by default):

| Pool | Weight | Notes |
|---|---:|---|
| Swing high/low | 1 | Fractal, `InpLiqSwingStrength` = 3, lookback 120; must still be intact |
| Equal highs/lows | 2 | Two swings within 0.15 ATR |
| Asian range | 2 | Completed `InpAsianWindow` (`01:00-09:00` server); skipped while that window is live |
| Previous-day H/L | 3 | Daily bar 1, if still intact today |
| Round numbers | 1 | `InpRoundNumberStep` = 5.0 (gold dollars) |
| Failed breakout | 2 | From VolBreakout; expires after `InpLiqFailedBoExpiry` (12) bars |

### 5.2 Wick sweep

On bar 0 or bar 1:

- Wick beyond a pool by 0.05–1.5 ATR
- Rejection wick ≥ 40% of the bar
- Tick-volume spike ≥ 1.2 (0 = off)
- Close back inside the level
- Reversal-bar quality: close away from the swept side (bar 0) or a follow-through body (bar 1)

Strength = sum of pool weights. Trade direction = **opposite** the swept side (highs swept → sell).

### 5.3 Fake breakout → sweep

A VolBreakout that closes back inside its range on a later bar is injected as a failed-breakout pool and can fire SweepReversal the same bar, with extra weight if it sits on another pool.

### 5.4 Stops vs liquidity

`CRiskManager` only **widens** stops: structural ATR buffer, spread cushion, broker minimum, then pushes the stop `InpLiquidityBufferAtr` (0.2 ATR) beyond nearby pools and round numbers. If the required stop exceeds `maxStopAtrMult` × ATR, the trade is skipped rather than using a tight “obvious” stop.

---

## 6. Shared risk and equity-DD-aware sizing

### 6.1 Equity drawdown (not balance)

```
peak     = max(equity seen since last reset / breaker rebase)
DD%      = max(0, (peak − equity) / peak × 100)
room%    = max(0, maxDD% − DD%)
room$    = peak × room% / 100
```

Peak is persisted in a terminal global variable (`XS_<magic>_<symbol>_peak`) so a restart does not forget the high-water mark. `InpResetRiskState` clears it.

`InpMaxDrawdownPercent`:

- `0` (default) → use the risk profile (Conservative 8, Balanced 12, Aggressive 20, Custom `InpCMaxDDPct`)
- `> 0` → override **only** max DD; other profile fields stay
- If the override lands at or below the profile throttle level, throttle is cut to `0.5 × maxDD`

### 6.2 Circuit breaker

When `DD% >= maxDD%`:

- Latch: pause for `InpDDPauseHours` (24) or until manual reset if hours = 0
- **Default: block new trades, keep managing open ones** (`InpCloseOnBreaker = false`)
- Set `InpCloseOnBreaker = true` to flatten on the trip
- When a timed pause ends, peak is re-based to current equity

Daily loss (`dailyLossPct` of start-of-day equity) still uses `InpCloseOnDailyLimit` (default true). Daily profit lock (`InpDailyProfitTargetPct`, default off) only blocks new entries.

Start-of-day equity is stored as `max(balance, equity)` at the first tick of a new server day.

### 6.3 Lot size vs remaining DD room

Unconstrained risk money:

```
unconstrained = RiskBase × risk% × RiskMultiplier
RiskMultiplier = (DD% ≥ throttleDD% ? throttleFactor : 1) × (loss streak ? lossStreakFactor : 1)
RiskBase      = balance, equity, or min(balance, equity)   // default: min
```

Then the remaining-room cap (10% of remaining room is left unused as slippage/gap reserve):

```
reserved  = room$ × 0.90
leftover  = reserved − money still at risk on open stops
N         = profile maxPositions          // not the throttled-to-1 count
slots     = max(1, N − openCount)

cap = min(
        leftover,          // one full SL must not breach the floor
        reserved / N,      // N concurrent full SLs must not breach the floor
        leftover / slots   // remaining slots share what is left
      )

target = min(unconstrained, cap)
```

If `target <= 0` or the broker minimum lot would spend more than `target`, the trade is skipped. The min-lot tolerance (`InpMinLotRiskTolerance`) **cannot** override the DD-room cap.

As current DD approaches the max, `room$` shrinks and lots fall (shown on the pane as a size factor `< 1.00` plus the room note). At the cap, new risk is zero.

Also applied after that: hard `InpMaxLots`, symbol volume limit, and `InpMaxMarginUsePct` of free margin.

Open-risk % cap (`maxOpenRiskPct`) is a second ceiling on `openStopRisk + newRisk` vs **current equity**.

### 6.4 Other shared guards

- Max positions (1 while throttled)
- Same-direction only; add-on only if existing trades are at breakeven (`InpRequireRiskFreeToAdd`)
- Max trades / day, min minutes between entries
- Loss-streak cool-down
- Netting accounts: one net position per symbol
- Spread: absolute cap, spread/stop ratio, spike vs EMA of recent spreads
- Sessions, Friday cut-off / flatten, daily flatten, news blackout

### 6.5 Shared exits (every strategy)

- Partial close `partialPct` at `beTriggerR`, then stop to `beLockR`
- ATR trail after `trailStartR`
- Stale close after `InpMaxHoldBars` (36) if still at risk
- Regime-change handling above

---

## 7. Dashboard

`CDashboard` draws a **charcoal `OBJ_RECTANGLE_LABEL` pane** plus `OBJ_LABEL` lines in the upper-left (own background, so it stays readable on dark *and* light charts). If object create fails, it falls back to `Comment()`. Hidden in the tester optimiser.

| Line | Content |
|---|---|
| Title | Symbol, signal TF, risk profile |
| Regime | Confirmed regime, direction, bars held, raw class |
| Selected | First enabled module that suits the regime (plus alts) |
| Running | Strategy names of open positions (by magic) |
| Signal | Pending setup, or `none` |
| Lots | **next** (ATR-stop preview, already DD-capped) / **last** fill / **open** volume; next also shows risk % |
| Size | Factor vs unconstrained risk, plus the remaining-room note |
| Account | Equity, balance |
| P/L | Floating (equity − balance), today's P/L $ and % vs day-start |
| Drawdown | Current equity DD% / max%, peak equity |
| DD room | Remaining %, remaining $, open stop risk |
| Per strategy | Total = open + closed; closed = deals in the last **90 days** tagged `magic = base + id` |
| Guard / status | Equity-guard state and last why-string |

Refresh: new bar, or when the fingerprint (regime, strategy, lots, equity, DD, guard, status) changes; at most once per second otherwise.

Lifecycle:

- Created in `OnInit` when `InpShowDashboard` is true
- `CHARTEVENT_CHART_CHANGE` rebuilds objects (template / colour / scale)
- Symbol or period change re-inits the EA (`REASON_CHARTCHANGE`); `OnDeinit` deletes every object with the `XS.DASH.<chart>.<magic>.` prefix and clears `Comment`

---

## 8. News and sessions

**Live:** MQL5 economic calendar, currencies in `InpNewsCurrencies` (default `USD`), high-impact (optional moderate), `InpNewsMinsBefore` / `After` (30).

**Tester:** calendar is unavailable. Manual windows (`InpManualBlackouts`, default `15:25-15:45;16:55-17:10` server, Mon–Fri) apply when `InpManualBlackoutMode` is Always (default) or Tester only.

Sessions, Friday no-new / flatten, and daily flatten are **broker server time**. Defaults assume a typical London/NY gold window; shift them.

---

## 9. Inputs and defaults

### General

| Input | Default |
|---|---|
| `InpMagic` | 26092300 (strategies use +1..+4) |
| `InpSignalTF` | PERIOD_M5 |
| `InpComment` | `XS` |
| `InpShowDashboard` | true |

### Risk profile

| Input | Default |
|---|---|
| `InpRiskProfile` | Balanced |
| `InpRiskBase` | Lower of balance and equity |
| **`InpMaxDrawdownPercent`** | **0 = use profile** |
| `InpMaxLots` | 0 (none) |
| `InpMaxMarginUsePct` | 30 |
| `InpMinLotRiskTolerance` | 1.5 |
| `InpCommissionPerLot` | 7.0 (account ccy, round-turn) |
| `InpDailyProfitTargetPct` | 0 (off) |
| `InpDDPauseHours` | 24 (0 = halt until reset) |
| `InpCloseOnBreaker` | **false** (pause; manage open) |
| `InpCloseOnDailyLimit` | true |
| `InpRequireRiskFreeToAdd` | true |
| `InpMinMinutesBetween` | 10 |
| `InpResetRiskState` | false |

Preset numbers are in the root README risk table. Conservative / Balanced / Aggressive as in §6. Custom uses `InpC*` (risk 1%, daily loss 3%, max DD 12%, throttle 6% × 0.5, 2 positions, 2% open risk, 10 trades/day, SL 1.8 ATR, max stop 3.5 ATR, BE 1.0R / 0.1R lock, 50% partial, trail 1.2R / 2.0 ATR, TP 2.2R, streak 3 / 0.5 / 45 min).

### Stops, spread, data, regime, strategies, liquidity, sessions, news, optimiser

Same names and defaults as in `XauusdScalper.mq5` inputs (see source). Highlights:

| Input | Default |
|---|---|
| `InpMinStopDistance` | 3.0 (gold $) |
| `InpMinStopSpreadMult` | 8.0 |
| `InpRoundNumberStep` | 5.0 |
| `InpMaxHoldBars` | 36 |
| `InpMaxSpreadPrice` | 0.50 |
| `InpFastEma` / `InpSlowEma` | 21 / 50 |
| `InpHtf` | H1 |
| `InpPctLookback` | 288 |
| `InpRegimeConfirmBars` / `InpRegimeMinHoldBars` | 3 / 6 |
| `InpRegimeExit` | Protect |
| All four `InpUse*` strategies | true |
| `InpBoConfirm` | Hold |
| `InpSessions` | `10:00-13:00;15:00-19:00` |
| `InpFridayNoNewTime` / `InpFridayCloseTime` | 18:00 / 21:30 |
| `InpDailyFlattenTime` | 23:30 |
| `InpUseCalendar` | true |
| `InpNewsCurrencies` | USD |
| `InpManualBlackoutMode` | Always |
| `InpManualBlackouts` | `15:25-15:45;16:55-17:10` |
| `InpOptMinTrades` | 100 |

---

## 10. Backtest guide

1. MT5 Strategy Tester → Expert `XauusdScalper`, symbol **XAUUSD** (or broker `GOLD`), period **M5**.
2. Model: **Every tick based on real ticks** when the broker provides them.
3. Use a sample that includes ranging Asia, London/NY trend days, and at least one news spike. Several months minimum; do not tune on a single week.
4. Deposit / leverage near the live account. Visual mode to confirm the pane.
5. Start **Balanced**, `InpMaxDrawdownPercent = 0`. Then Conservative vs Aggressive. Then stress a tighter `InpMaxDrawdownPercent` (e.g. 6) and confirm lots shrink and new entries pause at the cap while open trades are still managed.
6. Shift `InpSessions` and news windows to **that** tester agent's server time.
7. Expect the calendar filter to be inactive; rely on manual blackouts.
8. Custom `OnTester` score: `recovery × min(profitFactor, 3) × √(trades / InpOptMinTrades)`, or 0 if trades < min, profit ≤ 0, or PF ≤ 1.
9. Walk-forward or out-of-sample the inputs you touch. Commission (`InpCommissionPerLot`) must match the account.

See also the root `README.md` install steps.

---

## 11. File map

| File | Role |
|---|---|
| `XauusdScalper.mq5` | Inputs, wiring, dashboard snapshot |
| `Include/Common.mqh` | Enums, magic/strategy ids, helpers |
| `Include/MarketData.mqh` | Shared context |
| `Include/RegimeDetector.mqh` | Regime + hysteresis |
| `Include/LiquidityMap.mqh` | Pools, sweeps, failed breakouts |
| `Include/StrategySelector.mqh` | Priority registry |
| `Include/Strategies/*.mqh` | Four modules + base |
| `Include/RiskManager.mqh` | Profile, equity guard, DD-aware lots, P/L by magic |
| `Include/TradeManager.mqh` | Execution + shared exits |
| `Include/NewsFilter.mqh` | Calendar + manual windows |
| `Include/Dashboard.mqh` | Chart pane |

---

## Disclaimer

XauusdScalper is research and education software. It is **not** financial advice, a signal service, or a promise of profit. XAUUSD / gold CFDs are leveraged and can gap; you can lose the entire account (and more, depending on the venue). Backtests omit fills, slippage, halt, and news the way a live book will not. You are solely responsible for any use of this code, including live trading.
