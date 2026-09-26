//+------------------------------------------------------------------+
//|                                                XauusdScalper.mq5 |
//|  Multi-strategy, regime-adaptive XAUUSD M5 scalper for MT5.      |
//|                                                                  |
//|  Pipeline per closed bar:                                        |
//|   market context -> strategy state -> liquidity map ->           |
//|   regime detector (with hysteresis) -> strategy selector ->      |
//|   entry filters -> central risk manager -> trade manager         |
//|                                                                  |
//|  No EA guarantees profit. Backtest and demo-test before live use.|
//+------------------------------------------------------------------+
#property copyright "TRADING SYSTEM"
#property version   "1.20"
#property description "Regime-adaptive XAUUSD M5 scalper: trend pullback, mean reversion, volatility breakout"
#property description "and liquidity-sweep reversal strategies under one shared risk manager."
#property description "On-chart dashboard + equity-drawdown circuit breaker with DD-aware lot sizing."
#property description "v1.20: denser scalp cadence (quiet AND-gate, wider sessions, softer entries)."

#include "Include/Common.mqh"
#include "Include/MarketData.mqh"
#include "Include/RegimeDetector.mqh"
#include "Include/LiquidityMap.mqh"
#include "Include/StrategySelector.mqh"
#include "Include/Strategies/TrendPullback.mqh"
#include "Include/Strategies/MeanReversion.mqh"
#include "Include/Strategies/VolatilityBreakout.mqh"
#include "Include/Strategies/SweepReversal.mqh"
#include "Include/RiskManager.mqh"
#include "Include/TradeManager.mqh"
#include "Include/NewsFilter.mqh"
#include "Include/Dashboard.mqh"

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== General ==="
input long              InpMagic                 = 26092300;          // Base magic (strategies use +1..+9)
input ENUM_TIMEFRAMES   InpSignalTF              = PERIOD_M5;         // Signal timeframe
input string            InpComment               = "XS";              // Order comment prefix
input bool              InpShowDashboard         = true;              // Show on-chart status

input group "=== Risk profile (shared by every strategy) ==="
input ENUM_RISK_PROFILE InpRiskProfile           = PROFILE_BALANCED;  // Risk profile
input ENUM_RISK_BASE    InpRiskBase              = RISK_BASE_MIN;     // Risk % is taken from
input double            InpMaxDrawdownPercent    = 0.0;               // Max equity DD % (0 = use profile)
input double            InpMaxLots               = 0.0;               // Hard lot cap (0 = none)
input double            InpMaxMarginUsePct       = 30.0;              // Max % of free margin per new trade
input double            InpMinLotRiskTolerance   = 1.5;               // Allow min lot up to N x target risk
input double            InpCommissionPerLot      = 7.0;               // Round-turn commission per lot (account ccy)
input double            InpDailyProfitTargetPct  = 0.0;               // Stop new trades after +X% today (0 = off)
input int               InpDDPauseHours          = 24;                // Breaker pause hours (0 = halt until reset)
input bool              InpCloseOnBreaker        = false;             // Close all when equity-DD breaker trips
input bool              InpCloseOnDailyLimit     = true;              // Close all when daily loss limit hits
input bool              InpRequireRiskFreeToAdd  = false;             // Add positions only if others are at breakeven
input int               InpMinMinutesBetween     = 3;                 // Minimum minutes between entries
input bool              InpResetRiskState        = false;             // Reset persisted peak / limits / breaker

input group "=== Custom risk profile (only used when profile = Custom) ==="
input double            InpCRiskPct              = 1.0;               // Risk per trade %
input double            InpCDailyLossPct         = 3.0;               // Daily loss limit %
input double            InpCMaxDDPct             = 12.0;              // Max drawdown breaker %
input double            InpCThrottleDDPct        = 6.0;               // Throttle risk from drawdown %
input double            InpCThrottleFactor       = 0.5;               // Risk multiplier while throttled
input int               InpCMaxPositions         = 2;                 // Max open positions
input double            InpCMaxOpenRiskPct       = 2.0;               // Max total open risk %
input int               InpCMaxTradesPerDay      = 18;                // Max entries per day
input double            InpCSlAtrMult            = 1.8;               // Base stop = ATR x
input double            InpCMaxStopAtrMult       = 3.5;               // Skip if stop must exceed ATR x
input double            InpCBeTriggerR           = 0.8;               // Breakeven trigger (R)
input double            InpCBeLockR              = 0.1;               // Profit locked at breakeven (R)
input double            InpCPartialPct           = 50.0;              // % closed at breakeven trigger
input double            InpCTrailStartR          = 1.0;               // Start trailing at (R)
input double            InpCTrailAtrMult         = 1.8;               // Trailing distance ATR x
input double            InpCTpR                  = 1.8;               // Take profit (R, 0 = trail only)
input int               InpCLossStreak           = 3;                 // Losing streak length for cool-down
input double            InpCLossStreakFactor     = 0.5;               // Risk multiplier after streak
input int               InpCLossStreakPauseMin   = 30;                // Cool-down minutes after streak

input group "=== Stop placement (anti stop-hunt) ==="
input double            InpStructBufferAtr       = 0.3;               // Buffer beyond structure / sweep extreme (ATR)
input double            InpMinStopDistance       = 3.0;               // Absolute minimum stop (price units, $ on gold)
input double            InpMinStopSpreadMult     = 8.0;               // Stop >= spread x
input double            InpSpreadBufferMult      = 1.0;               // Extra stop cushion = spread x
input double            InpRoundNumberStep       = 5.0;               // Round-number grid (price, 0 = off)
input double            InpLiquidityBufferAtr    = 0.2;               // Keep stops this far past liquidity levels (ATR)
input int               InpMaxHoldBars           = 18;                // Close trades still at risk after N bars (0 = off)
input double            InpTrailStepAtr          = 0.1;               // Min trailing-stop improvement (ATR)

input group "=== Spread & execution ==="
input double            InpMaxSpreadPrice        = 0.80;              // Max spread (price units, 0 = off)
input double            InpMaxSpreadToRisk       = 0.15;              // Max spread / stop distance
input double            InpSpreadSpikeMult       = 3.5;               // Skip if spread > average x (0 = off)
input int               InpSpreadAvgTicks        = 300;               // Ticks in the spread average
input int               InpSlippagePoints        = 30;                // Max slippage (points)
input int               InpSignalValiditySec     = 90;                // Seconds a signal may wait for filters

input group "=== Market data ==="
input int               InpFastEma               = 21;                // Fast EMA
input int               InpSlowEma               = 50;                // Slow EMA
input bool              InpUseHtf                = true;              // Use higher-timeframe trend
input ENUM_TIMEFRAMES   InpHtf                   = PERIOD_H1;         // Higher timeframe
input int               InpHtfEma                = 50;                // Higher-timeframe EMA
input int               InpHtfSlopeBars          = 3;                 // HTF EMA slope bars
input int               InpAtrPeriod             = 14;                // ATR period
input int               InpAdxPeriod             = 14;                // ADX period
input int               InpBbPeriod              = 20;                // Bollinger period
input double            InpBbDeviation           = 2.0;               // Bollinger deviation
input int               InpRsiPeriod             = 9;                 // RSI period
input int               InpPctLookback           = 288;               // Percentile lookback bars (288 = 1 day of M5)
input int               InpSlopeBars             = 10;                // Slow-EMA slope bars
input int               InpBbExpandBars          = 5;                 // Bollinger expansion lookback
input int               InpVolAvgPeriod          = 20;                // Tick-volume average bars
input int               InpActivityLookback      = 288;               // Activity baseline bars

input group "=== Regime detector ==="
input double            InpChaoticAtrPct         = 99.0;              // Chaotic if ATR percentile >=
input double            InpChaoticBarAtr         = 4.0;               // ...or a bar range >= ATR x
input double            InpQuietAtrPct           = 8.0;               // Quiet if ATR percentile <= (AND activity)
input double            InpQuietActivity         = 0.40;              // Quiet if activity ratio <= (AND ATR%)
input double            InpBreakoutAtrPct        = 60.0;              // Breakout: ATR percentile >=
input double            InpBreakoutExpansion     = 1.15;              // Breakout: Bollinger width expansion >=
input double            InpBreakoutVolRatio      = 1.25;              // Breakout: tick-volume surge >=
input double            InpTrendAdxEnter         = 22.0;              // Trend: ADX to enter
input double            InpTrendAdxExit          = 18.0;              // Trend: ADX to stay
input double            InpTrendSlopeAtr         = 0.50;              // Trend: slow-EMA slope (ATR over slope bars)
input bool              InpTrendNeedsHtf         = false;             // Trend: require HTF agreement
input double            InpRangeAdxEnter         = 26.0;              // Range: ADX below to enter
input double            InpRangeAdxExit          = 30.0;              // Range: ADX below to stay
input double            InpRangeBbwPctMin        = 5.0;               // Range: Bollinger width percentile min
input double            InpRangeBbwPctMax        = 90.0;              // Range: Bollinger width percentile max
input int               InpRegimeConfirmBars     = 2;                 // Bars a new regime must persist
input int               InpRegimeMinHoldBars     = 3;                 // Min bars before leaving a tradeable regime
input ENUM_REGIME_EXIT  InpRegimeExit            = REGIME_EXIT_PROTECT; // Open trades when regime changes
input double            InpProtectMinR           = 0.3;               // Protect: lock breakeven from (R)

input group "=== Strategy: liquidity-sweep reversal ==="
input bool              InpUseSweepReversal      = true;              // Enable
input bool              InpSweepInRange          = true;              // Trade in RANGE regime
input bool              InpSweepInTrend          = true;              // Trade in TREND regime
input bool              InpSweepInBreakout       = true;              // Trade in BREAKOUT regime (failed breakouts)
input bool              InpSweepInQuiet          = true;              // Trade in QUIET (low-vol fades)
input bool              InpSweepWithTrendOnly    = false;             // In TREND only trade with the trend
input int               InpSweepMinStrength      = 1;                 // Min pool strength (confluence)
input double            InpSweepMinReclaimAtr    = 0.03;              // Close back inside level by (ATR)

input group "=== Strategy: volatility breakout ==="
input bool              InpUseVolBreakout        = true;              // Enable
input int               InpBoRangeBars           = 8;                 // Range lookback bars
input double            InpBoBufferAtr           = 0.05;              // Close beyond level by (ATR)
input double            InpBoMinBodyFrac         = 0.40;              // Min body / range
input double            InpBoMinCloseLoc         = 0.60;              // Close location in bar (0.7 = top 30%)
input double            InpBoMinVolRatio         = 1.20;              // Min tick-volume surge
input double            InpBoMaxExtensionAtr     = 2.0;               // Max distance from fast EMA (ATR)
input bool              InpBoRespectHtf          = false;             // Skip breakouts against HTF trend
input ENUM_BREAKOUT_CONFIRM InpBoConfirm         = BO_CONFIRM_CLOSE;  // Confirmation mode
input int               InpBoMaxWaitBars         = 2;                 // Bars allowed for confirmation
input double            InpBoRetestTolAtr        = 0.20;              // Retest / hold tolerance (ATR)

input group "=== Strategy: trend pullback ==="
input bool              InpUseTrendPullback      = true;              // Enable
input double            InpTpZoneAtr             = 0.50;              // Pullback zone around fast EMA (ATR)
input double            InpTpMinVolRatio         = 0.6;               // Min tick volume vs average
input double            InpTpRsiMin              = 40.0;              // RSI window min (longs; mirrored)
input double            InpTpRsiMax              = 80.0;              // RSI window max (longs; mirrored)
input int               InpTpAnchorBars          = 5;                 // Swing lookback for stop anchor

input group "=== Strategy: mean reversion ==="
input bool              InpUseMeanReversion      = true;              // Enable
input bool              InpMrInQuiet             = true;              // Also trade mean-rev in QUIET regime
input double            InpMrRsiOversold         = 35.0;              // RSI oversold (overbought = 100 - x)
input double            InpMrMaxVolRatio         = 2.2;               // Skip if tick-volume surge above
input double            InpMrMinTargetR          = 0.5;               // Band mean must be >= R away
input int               InpMrAnchorBars          = 3;                 // Excursion lookback for stop anchor

input group "=== Liquidity map ==="
input int               InpLiqSwingLookback      = 120;               // Swing lookback bars
input int               InpLiqSwingStrength      = 3;                 // Fractal strength (bars each side)
input double            InpLiqEqualTolAtr        = 0.15;              // Equal highs/lows tolerance (ATR)
input bool              InpLiqUseSwings          = true;              // Pools: swing highs/lows
input bool              InpLiqUseEqual           = true;              // Pools: equal highs/lows
input bool              InpLiqUseAsian           = true;              // Pools: Asian range
input bool              InpLiqUsePrevDay         = true;              // Pools: previous-day high/low
input bool              InpLiqUseRound           = true;              // Pools: round numbers
input bool              InpLiqUseFailedBO        = true;              // Pools: failed breakouts
input string            InpAsianWindow           = "01:00-09:00";     // Asian session (server time)
input double            InpSweepMinPierceAtr     = 0.05;              // Sweep: min pierce beyond level (ATR)
input double            InpSweepMaxPierceAtr     = 1.5;               // Sweep: max pierce (ATR)
input double            InpSweepMinWickFrac      = 0.30;              // Sweep: min rejection wick / range
input double            InpSweepMinVolRatio      = 0.0;               // Sweep: min tick-volume spike (0 = off)
input int               InpLiqFailedBoExpiry     = 12;                // Failed-breakout level expiry (bars)

input group "=== Sessions & time (broker server time) ==="
input string            InpSessions              = "07:00-21:00";      // Trading windows (London+NY overlap)
input string            InpFridayNoNewTime       = "19:00";           // Friday: no new trades after
input string            InpFridayCloseTime       = "21:30";           // Friday: close everything at
input string            InpDailyFlattenTime      = "23:30";           // Daily: close before rollover ("" = off)

input group "=== News filter ==="
input bool              InpUseCalendar           = true;              // Use MQL5 economic calendar (live)
input string            InpNewsCurrencies        = "USD";             // Currencies (comma separated)
input bool              InpNewsIncludeModerate   = false;             // Include moderate-impact events
input int               InpNewsMinsBefore        = 20;                // Minutes before event
input int               InpNewsMinsAfter         = 20;                // Minutes after event
input bool              InpNewsFlatten           = false;             // Close open trades during blackout
input ENUM_MANUAL_BLACKOUT InpManualBlackoutMode = MANUAL_BLACKOUT_TESTER_ONLY; // Manual blackout windows
input string            InpManualBlackouts       = "15:25-15:45;16:55-17:10"; // Manual windows (server, Mon-Fri)

input group "=== Optimisation ==="
input int               InpOptMinTrades          = 100;               // Min trades for custom criterion

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CMarketData       g_data;
CRegimeDetector   g_regime;
CLiquidityMap     g_liq;
CStrategySelector g_selector;
CRiskManager      g_risk;
CTradeManager     g_trade;
CNewsFilter       g_news;
CDashboard        g_dash;

SRiskProfile      g_profile;
ENUM_TIMEFRAMES   g_tf;
STimeWindow       g_sessions[];
int               g_fridayNoNew  = -1;
int               g_fridayClose  = -1;
int               g_dailyFlatten = -1;

datetime          g_lastBar      = 0;
double            g_avgSpread    = 0.0;
bool              g_pendingValid = false;
STradeIntent      g_pending;
datetime          g_pendingExpiry = 0;
string            g_why          = "starting";
string            g_selectedName = "-";
bool              g_showDash     = false;
bool              g_forceDash    = true;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool ParseOptionalTime(const string text, int &minutes, const string name)
  {
   string t = text;
   StringTrimLeft(t);
   StringTrimRight(t);
   if(t == "")
     {
      minutes = -1;
      return true;
     }
   if(!ParseHHMM(t, minutes))
     {
      PrintFormat("Invalid time for %s: '%s' (expected HH:MM)", name, text);
      return false;
     }
   return true;
  }

void ResolveProfile()
  {
   GetProfilePreset(InpRiskProfile, g_profile);
   if(InpRiskProfile == PROFILE_CUSTOM)
     {
      g_profile.name               = "Custom";
      g_profile.riskPct            = InpCRiskPct;
      g_profile.dailyLossPct       = InpCDailyLossPct;
      g_profile.maxDDPct           = InpCMaxDDPct;
      g_profile.throttleDDPct      = InpCThrottleDDPct;
      g_profile.throttleFactor     = InpCThrottleFactor;
      g_profile.maxPositions       = InpCMaxPositions;
      g_profile.maxOpenRiskPct     = InpCMaxOpenRiskPct;
      g_profile.maxTradesPerDay    = InpCMaxTradesPerDay;
      g_profile.slAtrMult          = InpCSlAtrMult;
      g_profile.maxStopAtrMult     = InpCMaxStopAtrMult;
      g_profile.beTriggerR         = InpCBeTriggerR;
      g_profile.beLockR            = InpCBeLockR;
      g_profile.partialPct         = InpCPartialPct;
      g_profile.trailStartR        = InpCTrailStartR;
      g_profile.trailAtrMult       = InpCTrailAtrMult;
      g_profile.tpR                = InpCTpR;
      g_profile.lossStreakCount    = InpCLossStreak;
      g_profile.lossStreakFactor   = InpCLossStreakFactor;
      g_profile.lossStreakPauseMin = InpCLossStreakPauseMin;
     }
   //--- Optional override keeps the rest of Conservative / Balanced / Aggressive intact
   if(InpMaxDrawdownPercent > 0.0)
      g_profile.maxDDPct = InpMaxDrawdownPercent;
   if(g_profile.throttleDDPct >= g_profile.maxDDPct)
      g_profile.throttleDDPct = g_profile.maxDDPct * 0.5;
  }

bool ValidateInputs()
  {
   bool ok = true;
   if(g_profile.riskPct <= 0.0 || g_profile.riskPct > 5.0)
     { Print("Risk per trade must be in (0, 5] %"); ok = false; }
   if(g_profile.slAtrMult < 1.0)
     { Print("Stop ATR multiple below 1.0 is too tight for gold (stop-hunt prone)"); ok = false; }
   if(g_profile.maxStopAtrMult <= g_profile.slAtrMult)
     { Print("Max stop ATR multiple must exceed the base stop multiple"); ok = false; }
   if(InpMaxDrawdownPercent < 0.0 || InpMaxDrawdownPercent > 50.0)
     { Print("Max equity drawdown % must be 0 (use profile) or in (0, 50]"); ok = false; }
   if(InpMaxDrawdownPercent > 0.0 && InpMaxDrawdownPercent < 0.5)
     { Print("Max equity drawdown % below 0.5 is too tight"); ok = false; }
   if(g_profile.dailyLossPct <= 0.0 || g_profile.maxDDPct <= 0.0 || g_profile.throttleDDPct >= g_profile.maxDDPct)
     { Print("Daily loss / drawdown limits invalid (throttle must be below max drawdown)"); ok = false; }
   if(g_profile.maxPositions < 1 || g_profile.maxPositions > 5)
     { Print("Max positions must be 1..5"); ok = false; }
   if(g_profile.partialPct < 0.0 || g_profile.partialPct >= 100.0)
     { Print("Partial close % must be in [0, 100)"); ok = false; }
   if(InpFastEma >= InpSlowEma || InpFastEma < 2)
     { Print("Fast EMA must be shorter than slow EMA"); ok = false; }
   if(InpPctLookback < 50 || InpActivityLookback < InpVolAvgPeriod || InpVolAvgPeriod < 5)
     { Print("Lookback periods too short"); ok = false; }
   if(InpSlopeBars < 2 || InpBbExpandBars < 1 || InpHtfSlopeBars < 1)
     { Print("Slope / expansion bars must be positive"); ok = false; }
   if(InpBoRangeBars < 3 || InpBoRangeBars >= XS_CTX_BARS)
     { PrintFormat("Breakout range bars must be 3..%d", XS_CTX_BARS - 1); ok = false; }
   if(InpTpAnchorBars < 1 || InpMrAnchorBars < 1 || InpLiqSwingStrength < 1 || InpLiqSwingLookback < 20)
     { Print("Anchor / swing settings invalid"); ok = false; }
   if(InpRegimeConfirmBars < 1 || InpRegimeMinHoldBars < 0)
     { Print("Regime confirmation bars must be >= 1"); ok = false; }
   if(InpMaxMarginUsePct <= 0.0 || InpMaxMarginUsePct > 100.0)
     { Print("Max margin use % must be in (0, 100]"); ok = false; }
   if(!InpUseSweepReversal && !InpUseVolBreakout && !InpUseTrendPullback && !InpUseMeanReversion)
     { Print("Enable at least one strategy"); ok = false; }
   return ok;
  }

bool RegisterStrategies()
  {
   //--- Registration order = priority within a regime
   if(InpUseSweepReversal)
     {
      SSweepReversalConfig c;
      c.minStrength   = InpSweepMinStrength;
      c.minReclaimAtr = InpSweepMinReclaimAtr;
      c.withTrendOnly = InpSweepWithTrendOnly;
      CSweepReversal *s = new CSweepReversal(c, GetPointer(g_liq));
      s.AllowRegime(REGIME_RANGE, InpSweepInRange);
      s.AllowRegime(REGIME_TREND, InpSweepInTrend);
      s.AllowRegime(REGIME_BREAKOUT, InpSweepInBreakout);
      s.AllowRegime(REGIME_QUIET, InpSweepInQuiet);
      if(!g_selector.Add(s))
         return false;
     }

   //--- The breakout module is always registered so it keeps tracking failed
   //--- breakouts for the sweep module; the input only controls whether it trades.
   SVolBreakoutConfig b;
   b.rangeBars       = InpBoRangeBars;
   b.bufferAtr       = InpBoBufferAtr;
   b.minBodyFrac     = InpBoMinBodyFrac;
   b.minCloseLoc     = InpBoMinCloseLoc;
   b.minVolRatio     = InpBoMinVolRatio;
   b.maxExtensionAtr = InpBoMaxExtensionAtr;
   b.respectHtf      = InpBoRespectHtf;
   b.confirm         = InpBoConfirm;
   b.maxWaitBars     = InpBoMaxWaitBars;
   b.retestTolAtr    = InpBoRetestTolAtr;
   CVolatilityBreakout *bo = new CVolatilityBreakout(b, GetPointer(g_liq));
   bo.SetEnabled(InpUseVolBreakout);
   if(!g_selector.Add(bo))
      return false;

   if(InpUseTrendPullback)
     {
      STrendPullbackConfig t;
      t.zoneAtr     = InpTpZoneAtr;
      t.minVolRatio = InpTpMinVolRatio;
      t.rsiMin      = InpTpRsiMin;
      t.rsiMax      = InpTpRsiMax;
      t.anchorBars  = InpTpAnchorBars;
      if(!g_selector.Add(new CTrendPullback(t)))
         return false;
     }

   if(InpUseMeanReversion)
     {
      SMeanReversionConfig m;
      m.rsiOversold = InpMrRsiOversold;
      m.maxVolRatio = InpMrMaxVolRatio;
      m.minTargetR  = InpMrMinTargetR;
      m.anchorBars  = InpMrAnchorBars;
      CMeanReversion *mr = new CMeanReversion(m);
      mr.AllowRegime(REGIME_QUIET, InpMrInQuiet);
      if(!g_selector.Add(mr))
         return false;
     }
   return true;
  }

void UpdateSpread()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
      return;
   double s = tick.ask - tick.bid;
   double alpha = 2.0 / (MathMax(InpSpreadAvgTicks, 1) + 1.0);
   g_avgSpread = (g_avgSpread <= 0.0) ? s : g_avgSpread + alpha * (s - g_avgSpread);
  }

double CurrentSpread()
  {
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick))
      return 0.0;
   return tick.ask - tick.bid;
  }

bool IsNewBar()
  {
   datetime t = iTime(_Symbol, g_tf, 0);
   if(t == 0 || t == g_lastBar)
      return false;
   g_lastBar = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Entry filters that are independent of the strategy               |
//+------------------------------------------------------------------+
bool EntryFiltersOk(const ENUM_SIGNAL dir, const ENUM_GUARD_STATE guard, string &reason)
  {
   if(guard != GUARD_OK)
     { reason = g_risk.Status(); return false; }
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     { reason = "algo trading disabled in terminal"; return false; }

   ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY ||
      (mode == SYMBOL_TRADE_MODE_LONGONLY && dir == SIGNAL_SELL) ||
      (mode == SYMBOL_TRADE_MODE_SHORTONLY && dir == SIGNAL_BUY))
     { reason = "symbol trade mode does not allow this entry"; return false; }

   datetime now = TimeCurrent();
   int dow = DayOfWeek(now);
   int minute = MinuteOfDay(now);
   if(dow == 0 || dow == 6)
     { reason = "weekend"; return false; }
   if(ArraySize(g_sessions) > 0 && !MinuteInAnyWindow(minute, g_sessions))
     { reason = "outside trading sessions"; return false; }
   if(dow == 5 && g_fridayNoNew >= 0 && minute >= g_fridayNoNew)
     { reason = "Friday cut-off"; return false; }
   if(g_dailyFlatten >= 0 && minute >= g_dailyFlatten)
     { reason = "after daily flatten time"; return false; }

   string newsWhy;
   if(g_news.IsBlackout(TimeTradeServer(), newsWhy))
     { reason = newsWhy; return false; }

   double spread = CurrentSpread();
   if(InpMaxSpreadPrice > 0.0 && spread > InpMaxSpreadPrice)
     { reason = StringFormat("spread %.2f > max %.2f", spread, InpMaxSpreadPrice); return false; }
   if(InpSpreadSpikeMult > 0.0 && g_avgSpread > 0.0 && spread > g_avgSpread * InpSpreadSpikeMult)
     { reason = "spread spike vs average"; return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Closed-bar processing: context, regime, strategy selection       |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   string err;
   if(!g_data.Update(err))
     {
      g_why = err;
      g_lastBar = 0; // retry on the next tick
      return;
     }
   SMarketContext ctx;
   g_data.Get(ctx);

   g_selector.OnBarAll(ctx);   // breakout module may report a failed breakout here
   g_liq.Update(ctx);          // ...which the liquidity map turns into a sweep
   if(g_regime.Update(ctx))
      PrintFormat("Regime -> %s (dir %d) | raw %s | ADX %.1f ATR%% %.0f BBW%% %.0f slope %.2f vol %.2f",
                  RegimeToString(g_regime.Regime()), g_regime.Direction(), RegimeToString(g_regime.Raw()),
                  ctx.adx, ctx.atrPct, ctx.bbWidthPct, ctx.slopeAtr, ctx.volRatio);
   g_risk.MarkHistoryDirty();

   g_pendingValid = false;
   ENUM_REGIME regime = g_regime.Regime();
   g_selectedName = SelectedStrategyName(regime);
   g_forceDash = true;
   if(!g_regime.IsTradeable())
     {
      g_why = "standing aside: " + RegimeToString(regime) + " regime";
      return;
     }
   if(g_selector.CountFor(regime) == 0)
     {
      g_why = "no enabled strategy for " + RegimeToString(regime);
      return;
     }

   string lastWhy = "";
   for(int i = 0; i < g_selector.Count(); i++)
     {
      CStrategy *s = g_selector.At(i);
      if(s == NULL || !s.Enabled() || !s.SuitsRegime(regime))
         continue;
      STradeIntent intent;
      string why = "";
      if(!s.CheckEntry(ctx, regime, g_regime.Direction(), intent, why))
        {
         lastWhy = why;
         continue;
        }
      //--- Fake-out guard for every strategy: never enter into a fresh opposite sweep
      if(intent.strategyId != XS_STRATEGY_SWEEP_REVERSAL && g_liq.HasFreshSweep(-(int)intent.signal))
        {
         lastWhy = s.Name() + ": fresh opposite liquidity sweep";
         continue;
        }
      g_pending       = intent;
      g_pendingValid  = true;
      g_pendingExpiry = TimeCurrent() + InpSignalValiditySec;
      g_why = StringFormat("signal %s %s (%s)", intent.strategyName, intent.signal == SIGNAL_BUY ? "BUY" : "SELL", intent.setup);
      return;
     }
   g_why = RegimeToString(regime) + ": " + lastWhy;
  }

void TryEntry(const ENUM_GUARD_STATE guard)
  {
   if(!g_pendingValid)
      return;
   if(TimeCurrent() > g_pendingExpiry)
     {
      g_pendingValid = false;
      g_why = "signal expired: " + g_why;
      return;
     }
   string reason;
   if(!EntryFiltersOk(g_pending.signal, guard, reason))
     {
      g_why = "signal held: " + reason;
      return;
     }
   if(!g_risk.CanOpen(g_pending.signal, reason))
     {
      g_pendingValid = false;
      g_why = "signal skipped: " + reason;
      return;
     }

   double levels[];
   g_liq.StopAvoidLevels(levels);
   STradePlan plan;
   if(!g_risk.PlanTrade(g_pending, g_data.Atr(), g_avgSpread, levels, plan, reason))
     {
      g_why = "signal held: " + reason;
      return;
     }

   string comment = StringSubstr(StringFormat("%s %s %s", InpComment, g_pending.strategyName, g_pending.setup), 0, 31);
   g_pendingValid = false;
   if(g_trade.Open(plan, g_pending.strategyId, comment))
     {
      g_risk.NoteFill(plan.lots);
      g_why = StringFormat("opened %s via %s", plan.type == ORDER_TYPE_BUY ? "BUY" : "SELL", g_pending.strategyName);
     }
   else
      g_why = "order failed";
   g_risk.MarkHistoryDirty();
   g_forceDash = true;
  }

void TimeExits(const datetime now)
  {
   if(g_trade.OpenCount() == 0)
      return;
   int dow = DayOfWeek(now);
   int minute = MinuteOfDay(now);
   if(dow == 5 && g_fridayClose >= 0 && minute >= g_fridayClose)
      g_trade.CloseAll("weekend close");
   else
      if(g_dailyFlatten >= 0 && minute >= g_dailyFlatten)
         g_trade.CloseAll("daily flatten before rollover");
  }

string TimeframeName(const ENUM_TIMEFRAMES tf)
  {
   string s = EnumToString(tf);
   if(StringFind(s, "PERIOD_") == 0)
      return StringSubstr(s, 7);
   return s;
  }

string SelectedStrategyName(const ENUM_REGIME regime)
  {
   if(!g_regime.IsTradeable())
      return "- (stand aside: " + RegimeToString(regime) + ")";
   string first = "";
   string alts  = "";
   for(int i = 0; i < g_selector.Count(); i++)
     {
      CStrategy *s = g_selector.At(i);
      if(s == NULL || !s.Enabled() || !s.SuitsRegime(regime))
         continue;
      if(first == "")
         first = s.Name();
      else
         alts += (alts == "" ? s.Name() : "+" + s.Name());
     }
   if(first == "")
      return "- (none enabled for " + RegimeToString(regime) + ")";
   if(alts != "")
      return first + "  (also " + alts + ")";
   return first;
  }

string RunningStrategyName()
  {
   SPositionInfo pos[];
   int n = CollectPositions(_Symbol, InpMagic, pos);
   if(n <= 0)
      return "none";
   string out = "";
   for(int i = 0; i < n; i++)
     {
      string name = g_selector.NameOf(pos[i].strategyId);
      if(StringFind(out, name) >= 0)
         continue;
      out += (out == "" ? "" : ", ") + name;
     }
   return (out == "" ? "none" : out);
  }

void UpdateDashboard(const ENUM_GUARD_STATE guard, const bool newBar)
  {
   if(!g_showDash)
      return;

   if(g_data.Atr() <= 0.0)
     {
      string err;
      g_data.Update(err);
     }
   g_risk.RefreshStats();
   double nextLots = 0.0, nextRisk = 0.0;
   string previewWhy = "";
   g_risk.PreviewLots(g_data.Atr(), g_avgSpread, nextLots, nextRisk, previewWhy);

   SDashboardSnapshot s;
   s.symbol            = _Symbol;
   s.timeframe         = TimeframeName(g_tf);
   s.profile           = g_profile.name;
   s.regime            = RegimeToString(g_regime.Regime());
   s.regimeDir         = g_regime.Direction();
   s.barsInRegime      = g_regime.BarsInRegime();
   s.rawRegime         = RegimeToString(g_regime.Raw());
   s.selectedStrategy  = (g_selectedName == "-" ? SelectedStrategyName(g_regime.Regime()) : g_selectedName);
   s.runningStrategy   = RunningStrategyName();
   if(g_pendingValid)
      s.signalText = StringFormat("%s %s (%s)",
                                  g_pending.strategyName,
                                  g_pending.signal == SIGNAL_BUY ? "BUY" : "SELL",
                                  g_pending.setup);
   else
      s.signalText = "none";
   s.nextLots     = nextLots;
   s.lastLots     = (g_risk.LastFillLots() > 0.0 ? g_risk.LastFillLots() : g_risk.LastPlanLots());
   s.nextRiskPct  = nextRisk;
   s.equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   s.balance      = AccountInfoDouble(ACCOUNT_BALANCE);
   s.floating     = s.equity - s.balance;
   s.todayPlPct   = g_risk.DayPnlNow();
   s.todayPl      = (g_risk.DayStartEquity() > 0.0 ? s.equity - g_risk.DayStartEquity() : s.floating);
   s.peakEquity   = g_risk.PeakEquity();
   s.ddPct        = g_risk.DrawdownNow();
   s.maxDdPct     = g_risk.MaxDrawdownPct();
   s.roomPct      = g_risk.RemainingDdPct();
   s.roomMoney    = g_risk.RemainingDdMoney();
   s.openRisk     = g_risk.OpenRiskNow();
   s.sizeFactor   = g_risk.LastSizeFactor();
   s.sizeNote     = g_risk.SizeNote();
   if(s.sizeNote == "" && previewWhy != "")
      s.sizeNote = previewWhy;
   s.guard        = g_risk.Status();
   if(guard == GUARD_BLOCK_NEW && StringFind(s.guard, "PAUSED") < 0 && StringFind(s.guard, "HALTED") < 0)
      s.guard = "BLOCK NEW  " + s.guard;
   s.status       = g_why;
   s.newBar       = newBar;
   for(int id = 0; id < XS_MAGIC_SLOTS; id++)
      g_risk.GetStrategyPnL(id, s.pnl[id]);

   SPositionInfo pos[];
   int n = CollectPositions(_Symbol, InpMagic, pos);
   s.openLots = 0.0;
   for(int i = 0; i < n; i++)
      s.openLots += pos[i].volume;

   bool force = g_forceDash || newBar;
   g_forceDash = false;
   g_dash.Render(s, force);
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_tf = (InpSignalTF == PERIOD_CURRENT) ? (ENUM_TIMEFRAMES)_Period : InpSignalTF;
   ResolveProfile();
   if(!ValidateInputs())
      return INIT_PARAMETERS_INCORRECT;

   if(!ParseWindows(InpSessions, g_sessions))
     { Print("Invalid sessions: ", InpSessions); return INIT_PARAMETERS_INCORRECT; }
   if(!ParseOptionalTime(InpFridayNoNewTime, g_fridayNoNew, "Friday no-new time") ||
      !ParseOptionalTime(InpFridayCloseTime, g_fridayClose, "Friday close time") ||
      !ParseOptionalTime(InpDailyFlattenTime, g_dailyFlatten, "daily flatten time"))
      return INIT_PARAMETERS_INCORRECT;

   SMarketDataConfig dc;
   dc.tf               = g_tf;
   dc.fastEma          = InpFastEma;
   dc.slowEma          = InpSlowEma;
   dc.useHtf           = InpUseHtf;
   dc.htf              = InpHtf;
   dc.htfEma           = InpHtfEma;
   dc.htfSlopeBars     = InpHtfSlopeBars;
   dc.atrPeriod        = InpAtrPeriod;
   dc.adxPeriod        = InpAdxPeriod;
   dc.bbPeriod         = InpBbPeriod;
   dc.bbDeviation      = InpBbDeviation;
   dc.rsiPeriod        = InpRsiPeriod;
   dc.pctLookback      = InpPctLookback;
   dc.slopeBars        = InpSlopeBars;
   dc.bbExpandBars     = InpBbExpandBars;
   dc.volAvgPeriod     = InpVolAvgPeriod;
   dc.activityLookback = InpActivityLookback;
   if(!g_data.Init(_Symbol, dc))
      return INIT_FAILED;

   SRegimeConfig rc;
   rc.chaoticAtrPct     = InpChaoticAtrPct;
   rc.chaoticBarAtr     = InpChaoticBarAtr;
   rc.quietAtrPct       = InpQuietAtrPct;
   rc.quietActivity     = InpQuietActivity;
   rc.breakoutAtrPct    = InpBreakoutAtrPct;
   rc.breakoutExpansion = InpBreakoutExpansion;
   rc.breakoutVolRatio  = InpBreakoutVolRatio;
   rc.trendAdxEnter     = InpTrendAdxEnter;
   rc.trendAdxExit      = InpTrendAdxExit;
   rc.trendSlopeAtr     = InpTrendSlopeAtr;
   rc.trendNeedsHtf     = InpTrendNeedsHtf && InpUseHtf;
   rc.rangeAdxEnter     = InpRangeAdxEnter;
   rc.rangeAdxExit      = InpRangeAdxExit;
   rc.rangeBbwPctMin    = InpRangeBbwPctMin;
   rc.rangeBbwPctMax    = InpRangeBbwPctMax;
   rc.confirmBars       = InpRegimeConfirmBars;
   rc.minHoldBars       = InpRegimeMinHoldBars;
   g_regime.Init(rc);

   SLiquidityConfig lc;
   lc.tf                 = g_tf;
   lc.swingLookback      = InpLiqSwingLookback;
   lc.swingStrength      = InpLiqSwingStrength;
   lc.equalTolAtr        = InpLiqEqualTolAtr;
   lc.useSwings          = InpLiqUseSwings;
   lc.useEqual           = InpLiqUseEqual;
   lc.useAsian           = InpLiqUseAsian;
   lc.usePrevDay         = InpLiqUsePrevDay;
   lc.useRound           = InpLiqUseRound && InpRoundNumberStep > 0.0;
   lc.useFailedBreakouts = InpLiqUseFailedBO;
   lc.roundStep          = InpRoundNumberStep;
   lc.minPierceAtr       = InpSweepMinPierceAtr;
   lc.maxPierceAtr       = InpSweepMaxPierceAtr;
   lc.minWickFrac        = InpSweepMinWickFrac;
   lc.minVolRatio        = InpSweepMinVolRatio;
   lc.minStrength        = 1;
   lc.failedBoExpiryBars = InpLiqFailedBoExpiry;
   STimeWindow asian[];
   if(!ParseWindows(InpAsianWindow, asian) || ArraySize(asian) != 1)
     {
      if(InpLiqUseAsian)
        { Print("Invalid Asian window: ", InpAsianWindow); return INIT_PARAMETERS_INCORRECT; }
      lc.useAsian = false;
      lc.asianWindow.startMin = 0;
      lc.asianWindow.endMin = 0;
     }
   else
      lc.asianWindow = asian[0];
   g_liq.Init(_Symbol, lc);

   if(!RegisterStrategies())
      return INIT_FAILED;

   SRiskConfig rk;
   rk.riskBase                = InpRiskBase;
   rk.maxLots                 = InpMaxLots;
   rk.maxMarginUsePct         = InpMaxMarginUsePct;
   rk.minLotRiskTolerance     = InpMinLotRiskTolerance;
   rk.commissionPerLot        = InpCommissionPerLot;
   rk.dailyProfitTargetPct    = InpDailyProfitTargetPct;
   rk.ddPauseHours            = InpDDPauseHours;
   rk.closeOnBreaker          = InpCloseOnBreaker;
   rk.closeOnDailyLimit       = InpCloseOnDailyLimit;
   rk.resetState              = InpResetRiskState;
   rk.requireRiskFreeToAdd    = InpRequireRiskFreeToAdd;
   rk.minMinutesBetweenTrades = InpMinMinutesBetween;
   rk.structBufferAtr         = InpStructBufferAtr;
   rk.minStopDistance         = InpMinStopDistance;
   rk.minStopSpreadMult       = InpMinStopSpreadMult;
   rk.spreadBufferMult        = InpSpreadBufferMult;
   rk.roundStep               = InpRoundNumberStep;
   rk.liquidityBufferAtr      = InpLiquidityBufferAtr;
   rk.maxSpreadToRisk         = InpMaxSpreadToRisk;
   if(!g_risk.Init(_Symbol, InpMagic, g_profile, rk))
      return INIT_FAILED;

   STradeConfig tc;
   tc.tf             = g_tf;
   tc.slippagePoints = InpSlippagePoints;
   tc.maxHoldBars    = InpMaxHoldBars;
   tc.regimeExit     = InpRegimeExit;
   tc.protectMinR    = InpProtectMinR;
   tc.trailStepAtr   = InpTrailStepAtr;
   if(!g_trade.Init(_Symbol, InpMagic, g_profile, tc))
      return INIT_FAILED;

   SNewsConfig nc;
   nc.useCalendar     = InpUseCalendar;
   nc.currencies      = InpNewsCurrencies;
   nc.includeModerate = InpNewsIncludeModerate;
   nc.minutesBefore   = InpNewsMinsBefore;
   nc.minutesAfter    = InpNewsMinsAfter;
   nc.manualMode      = InpManualBlackoutMode;
   nc.manualWindows   = InpManualBlackouts;
   if(!g_news.Init(nc))
      return INIT_PARAMETERS_INCORRECT;

   g_showDash = InpShowDashboard && !MQLInfoInteger(MQL_OPTIMIZATION);
   g_dash.Init(ChartID(), InpMagic, g_showDash);
   g_forceDash = true;
   g_selectedName = "-";
   if(StringFind(_Symbol, "XAU") < 0 && StringFind(_Symbol, "GOLD") < 0)
      Print("Note: defaults are tuned for XAUUSD. Re-check price-unit inputs (min stop, max spread, round-number step) for ", _Symbol);
   PrintFormat("XauusdScalper ready on %s %s | digits %d point %g | profile %s risk %.2f%% maxDD %.2f%% | strategies: %s | %s",
               _Symbol, EnumToString(g_tf), _Digits, _Point, g_profile.name, g_profile.riskPct, g_profile.maxDDPct,
               g_selector.Summary(), IsHedgingAccount() ? "hedging" : "netting");
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   g_dash.Remove();
   g_data.Release();
   g_selector.Clear();
   Comment("");
  }

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   if(id == CHARTEVENT_CHART_CHANGE)
     {
      g_dash.OnChartChange();
      g_forceDash = true;
     }
  }

//+------------------------------------------------------------------+
//| Tick                                                             |
//+------------------------------------------------------------------+
void OnTick()
  {
   UpdateSpread();

   ENUM_GUARD_STATE guard = g_risk.Update();
   if(guard == GUARD_CLOSE_ALL && g_trade.OpenCount() > 0)
      g_trade.CloseAll(g_risk.Status());

   datetime now = TimeCurrent();
   TimeExits(now);

   if(InpNewsFlatten && g_trade.OpenCount() > 0)
     {
      string newsWhy;
      if(g_news.IsBlackout(TimeTradeServer(), newsWhy))
         g_trade.CloseAll(newsWhy);
     }

   bool newBar = IsNewBar();
   if(newBar)
      OnNewBar();

   bool suits[XS_MAGIC_SLOTS];
   for(int id = 0; id < XS_MAGIC_SLOTS; id++)
      suits[id] = g_selector.StrategySuits(id, g_regime.Regime());
   g_trade.Manage(g_data.Atr(), suits);

   TryEntry(guard);
   UpdateDashboard(guard, newBar);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      g_risk.MarkHistoryDirty();
  }

//+------------------------------------------------------------------+
//| Custom optimisation criterion: recovery x capped profit factor,  |
//| scaled by trade count; rejects thin or losing results.           |
//+------------------------------------------------------------------+
double OnTester()
  {
   double trades = TesterStatistics(STAT_TRADES);
   double profit = TesterStatistics(STAT_PROFIT);
   double pf     = TesterStatistics(STAT_PROFIT_FACTOR);
   double rf     = TesterStatistics(STAT_RECOVERY_FACTOR);
   if(trades < InpOptMinTrades || profit <= 0.0 || pf <= 1.0)
      return 0.0;
   return rf * MathMin(pf, 3.0) * MathSqrt(trades / MathMax(InpOptMinTrades, 1));
  }
//+------------------------------------------------------------------+
