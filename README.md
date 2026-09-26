# XauusdScalper

Regime-adaptive **XAUUSD M5** Expert Advisor for MetaTrader 5. One shared risk manager drives four strategy modules:

| Module | Default regime | Idea |
|---|---|---|
| **SweepReversal** | Range, Trend, Breakout | Fade a liquidity sweep after price reclaims the level |
| **VolBreakout** | Breakout | Trade a *confirmed* range break; report failures as sweep fuel |
| **TrendPullback** | Trend | Buy dips / sell rallies into the fast EMA |
| **MeanReversion** | Range | Fade a Bollinger excursion back toward the band mean |

The EA stands aside in **Quiet** and **Chaotic** regimes. Lot size shrinks as account **equity** drawdown approaches the configured max. An on-chart pane shows the live strategy, lots, P/L, and remaining drawdown room.

**This EA does not guarantee profit.** Gold is fast and gap-prone. Backtest and demo-test on *your* broker's XAUUSD (or GOLD) before any live use. Past results do not predict future results. You can lose more than you deposit.

## What it does

On each **closed M5 bar** the EA:

1. Builds one shared market context (EMA, ATR, ADX, Bollinger, RSI, volume, HTF bias).
2. Updates the liquidity map (swings, equal highs/lows, Asian range, previous day, round numbers, failed breakouts) and detects sweeps / fake breakouts.
3. Classifies the regime with hysteresis (confirm + minimum hold).
4. Asks enabled strategies in priority order for that regime. First valid setup wins.
5. Runs session, news, spread, and exposure filters.
6. Places the stop with the shared anti-stop-hunt rules and sizes the trade from risk-% **capped by remaining equity-DD room**.
7. Manages every open position the same way: partial + breakeven, ATR trail, stale-trade exit, optional regime-change protect.

Ticks between bars still manage open trades, refresh the equity guard, and update the dashboard.

## Risk profiles

`InpRiskProfile` sets the shared personality. `InpMaxDrawdownPercent = 0` keeps the profile's max equity DD.

| | Conservative | Balanced (default) | Aggressive |
|---|---:|---:|---:|
| Risk per trade | 0.5% | 1.0% | 1.5% |
| Daily loss limit | 2% | 3% | 5% |
| **Max equity DD** | **8%** | **12%** | **20%** |
| Throttle from DD | 4% × 0.5 | 6% × 0.5 | 10% × 0.6 |
| Max positions | 1 | 2 | 3 |
| Max open risk | 1.0% | 2.0% | 3.5% |
| Trades / day | 6 | 10 | 15 |
| Base stop (ATR) | 2.0 | 1.8 | 1.6 |
| TP (R) | 1.8 | 2.2 | 3.0 |

Set `InpMaxDrawdownPercent` > 0 to override **only** the max equity-DD limit; the rest of the profile stays. Custom profile uses the `InpC*` inputs.

Drawdown is **peak equity → current equity**, not balance. When current DD% reaches the max, the EA **pauses new trades** and keeps managing open ones (`InpCloseOnBreaker` is off by default; turn it on to flatten instead).

Lot size is cut so a full stop-loss — and N concurrent full stops — cannot spend the remaining DD budget (see the design doc).

## Dashboard

Top-left charcoal pane (readable on dark and light charts):

- Confirmed **regime** and the **selected** strategy for that regime
- **Running** strategy (open positions, tagged by magic)
- Pending **signal**, or `none`
- **Lots**: next (DD-aware preview) / last fill / currently open, plus the size factor
- Account **equity**, **balance**, **floating P/L**, **today's P/L**
- Equity **drawdown % / max %**, remaining **DD room**, open stop risk
- Per-strategy **open + closed** P/L (magic = base + strategy id; closed window = last 90 days)

Updates on a new bar or when those numbers change. Objects are removed on deinit and rebuilt on chart change. Hide with `InpShowDashboard = false`.

## Install

1. In MT5: **File → Open Data Folder**.
2. Copy the folder `MQL5/Experts/XauusdScalper` into `MQL5/Experts/` (keep the `Include` tree inside it).
3. Restart MT5 or right-click **Navigator → Expert Advisors → Refresh**.
4. Open `XauusdScalper.mq5` in MetaEditor and press **F7** (compile). The `.ex5` is gitignored; you compile locally.
5. Attach **XauusdScalper** to an **XAUUSD M5** chart (or your broker's GOLD symbol).
6. Allow Algo Trading. Use a **hedging** account if you want more than one position; netting is supported but limited to one net position.

Defaults are in **price units** for gold (~$1 = 1.00). Recheck min stop, max spread, and round-number step if the symbol quotes differently.

## Strategy Tester

1. Open **View → Strategy Tester**.
2. Expert: `XauusdScalper`. Symbol: `XAUUSD` (or `GOLD`). Period: **M5**.
3. Model: **Every tick based on real ticks** if your broker offers tick data; otherwise every tick.
4. Dates: at least several months that include both quiet Asian ranges and active London/NY overlap. Include news-heavy weeks if you care about the news filter.
5. Deposit / leverage close to the live account. Visual mode if you want to see the pane.
6. Start with **Balanced**. Then compare Conservative vs Aggressive. Do not trust a single year.
7. The custom optimisation criterion (`OnTester`) is recovery factor × capped profit factor × √(trades / min trades), and returns 0 if trades < `InpOptMinTrades` (default 100), profit ≤ 0, or profit factor ≤ 1.

**Calendar news is not available in the tester.** Manual blackout windows (`InpManualBlackouts`, default around typical USD releases) stand in when `InpManualBlackoutMode` is `Always` or `Tester only`.

Sessions default to `07:00-21:00` **server time** (London+NY). Shift them to match your broker.

## More trades (v1.20)

Defaults favour denser M5 scalps while keeping equity-DD sizing: quiet requires **both** low ATR% and low activity (was OR), QUIET allows mean-rev/sweeps, wider sessions, softer entries, 3-minute spacing, faster BE/TP. Recompile after copying the updated `XauusdScalper` folder. Expect more trades and a bit more DD than the ultra-selective v1.10 run.

## Important inputs

| Input | Default | Role |
|---|---|---|
| `InpRiskProfile` | Balanced | Shared risk personality |
| `InpMaxDrawdownPercent` | 0 (use profile) | Max **equity** DD % override |
| `InpCloseOnBreaker` | false | If true, flatten when the DD breaker trips |
| `InpResetRiskState` | false | Clear persisted peak / daily halt / breaker |
| `InpShowDashboard` | true | On-chart pane |
| `InpUseSweepReversal` / `InpUseVolBreakout` / `InpUseTrendPullback` / `InpUseMeanReversion` | true | Enable modules |
| `InpSessions` | 10:00-13:00;15:00-19:00 | Trading windows (server) |
| `InpUseCalendar` | true | Live economic calendar (USD high-impact) |

Full input list, regime rules, and sizing math: [docs/xauusd-scalper-design.md](docs/xauusd-scalper-design.md).

## Disclaimer

XauusdScalper is research / education software, not financial advice and not an offer to trade on your behalf. Forex and CFDs are leveraged; you can lose the entire account. No strategy, backtest, or dashboard number is a promise of future profit. You are solely responsible for how you use this code.
