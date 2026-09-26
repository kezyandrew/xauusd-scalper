//+------------------------------------------------------------------+
//|                                                     Common.mqh   |
//|  Shared enums, structures and helper functions for XauusdScalper |
//+------------------------------------------------------------------+
#ifndef XS_COMMON_MQH
#define XS_COMMON_MQH

//--- Each strategy trades under magic = base magic + strategy id, so every
//--- position can be traced back to the strategy (and regime) that opened it.
#define XS_MAGIC_SLOTS 10

//--- Strategy ids double as magic-number offsets (base magic + id)
#define XS_STRATEGY_TREND_PULLBACK   1
#define XS_STRATEGY_MEAN_REVERSION   2
#define XS_STRATEGY_VOL_BREAKOUT     3
#define XS_STRATEGY_SWEEP_REVERSAL   4

string StrategyIdName(const int id)
  {
   switch(id)
     {
      case XS_STRATEGY_TREND_PULLBACK: return "TrendPullback";
      case XS_STRATEGY_MEAN_REVERSION: return "MeanReversion";
      case XS_STRATEGY_VOL_BREAKOUT:   return "VolBreakout";
      case XS_STRATEGY_SWEEP_REVERSAL: return "SweepReversal";
     }
   return (id > 0 ? StringFormat("id%d", id) : "none");
  }

//--- Per-strategy P/L tagged by magic = base + strategy id
struct SStrategyPnL
  {
   double            closed;       // realized (deals), account currency
   double            closedToday;  // realized today
   double            openPl;       // floating profit + swap
   double            openLots;
   int               openCount;
  };

//--- Market regimes recognised by the regime detector
enum ENUM_REGIME
  {
   REGIME_NONE      = 0, // Undefined / mixed: stand aside
   REGIME_TREND     = 1, // Directional trend
   REGIME_RANGE     = 2, // Two-sided range
   REGIME_BREAKOUT  = 3, // Volatility expansion with volume
   REGIME_QUIET     = 4, // Low volatility: optional fades/sweeps (not a full stand-aside)
   REGIME_CHAOTIC   = 5  // Extreme volatility (news spike): stand aside
  };

//--- Coherent presets for every risk-related setting
enum ENUM_RISK_PROFILE
  {
   PROFILE_CONSERVATIVE = 0, // Conservative
   PROFILE_BALANCED     = 1, // Balanced
   PROFILE_AGGRESSIVE   = 2, // Aggressive
   PROFILE_CUSTOM       = 3  // Custom (use the "Custom risk" inputs)
  };

//--- What to do with open trades whose strategy no longer matches the regime
enum ENUM_REGIME_EXIT
  {
   REGIME_EXIT_KEEP    = 0, // Keep: normal shared management only
   REGIME_EXIT_PROTECT = 1, // Protect: lock breakeven if in profit, cut stale losers sooner
   REGIME_EXIT_CLOSE   = 2  // Close: exit immediately
  };

string RegimeToString(const ENUM_REGIME r)
  {
   switch(r)
     {
      case REGIME_TREND:    return "TREND";
      case REGIME_RANGE:    return "RANGE";
      case REGIME_BREAKOUT: return "BREAKOUT";
      case REGIME_QUIET:    return "QUIET";
      case REGIME_CHAOTIC:  return "CHAOTIC";
      default:              return "NONE";
     }
  }

bool IsOwnMagic(const long magic, const long baseMagic)
  {
   return (magic >= baseMagic && magic < baseMagic + XS_MAGIC_SLOTS);
  }

//--- Account value used as the base for risk-% sizing
enum ENUM_RISK_BASE
  {
   RISK_BASE_BALANCE = 0, // Balance
   RISK_BASE_EQUITY  = 1, // Equity
   RISK_BASE_MIN     = 2  // Lower of balance and equity (most conservative)
  };

//--- When fixed "manual" news blackout windows apply
enum ENUM_MANUAL_BLACKOUT
  {
   MANUAL_BLACKOUT_OFF         = 0, // Off
   MANUAL_BLACKOUT_TESTER_ONLY = 1, // Only in Strategy Tester (calendar unavailable)
   MANUAL_BLACKOUT_ALWAYS      = 2  // Always (live and tester)
  };

enum ENUM_SIGNAL
  {
   SIGNAL_SELL = -1,
   SIGNAL_NONE = 0,
   SIGNAL_BUY  = 1
  };

//--- Result of the equity guard evaluated every tick
enum ENUM_GUARD_STATE
  {
   GUARD_OK        = 0, // New trades allowed (subject to other filters)
   GUARD_BLOCK_NEW = 1, // Manage open trades, but no new entries
   GUARD_CLOSE_ALL = 2  // Flatten everything now
  };

//--- Time window expressed in minutes from 00:00 server time
struct STimeWindow
  {
   int               startMin;
   int               endMin;
  };

//+------------------------------------------------------------------+
//| Parse "HH:MM" into minutes of day. Accepts "24:00".               |
//+------------------------------------------------------------------+
bool ParseHHMM(string text, int &minutes)
  {
   StringTrimLeft(text);
   StringTrimRight(text);
   string parts[];
   if(StringSplit(text, ':', parts) != 2)
      return false;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 24 || m < 0 || m > 59 || (h == 24 && m != 0))
      return false;
   minutes = h * 60 + m;
   return true;
  }

//+------------------------------------------------------------------+
//| Parse "HH:MM-HH:MM;HH:MM-HH:MM" into windows. Empty spec = none.  |
//+------------------------------------------------------------------+
bool ParseWindows(const string spec, STimeWindow &out[])
  {
   ArrayResize(out, 0);
   string trimmed = spec;
   StringTrimLeft(trimmed);
   StringTrimRight(trimmed);
   if(trimmed == "")
      return true;

   string items[];
   int n = StringSplit(trimmed, ';', items);
   for(int i = 0; i < n; i++)
     {
      string item = items[i];
      StringTrimLeft(item);
      StringTrimRight(item);
      if(item == "")
         continue;
      string ends[];
      if(StringSplit(item, '-', ends) != 2)
         return false;
      STimeWindow w;
      if(!ParseHHMM(ends[0], w.startMin) || !ParseHHMM(ends[1], w.endMin))
         return false;
      int sz = ArraySize(out);
      ArrayResize(out, sz + 1);
      out[sz] = w;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Window check that supports windows crossing midnight.            |
//+------------------------------------------------------------------+
bool MinuteInWindow(const int minute, const STimeWindow &w)
  {
   if(w.startMin == w.endMin)
      return false;
   if(w.startMin < w.endMin)
      return (minute >= w.startMin && minute < w.endMin);
   return (minute >= w.startMin || minute < w.endMin);
  }

bool MinuteInAnyWindow(const int minute, const STimeWindow &windows[])
  {
   int n = ArraySize(windows);
   for(int i = 0; i < n; i++)
      if(MinuteInWindow(minute, windows[i]))
         return true;
   return false;
  }

int MinuteOfDay(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.hour * 60 + dt.min;
  }

int DayOfWeek(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.day_of_week;
  }

//--- yyyymmdd as an integer; used as a "trading day" key
int DayKey(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return dt.year * 10000 + dt.mon * 100 + dt.day;
  }

datetime DayStart(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
  }

//+------------------------------------------------------------------+
//| Round a price to the symbol's tick size.                          |
//+------------------------------------------------------------------+
double NormalizePrice(const string symbol, const double price)
  {
   int    digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0)
      return NormalizeDouble(price, digits);
   return NormalizeDouble(MathRound(price / tickSize) * tickSize, digits);
  }

//--- Decimal places implied by the volume step (0.01 -> 2)
int VolumeDigits(const double step)
  {
   if(step <= 0.0)
      return 2;
   int d = (int)MathCeil(-MathLog10(step) - 1e-9);
   return (int)MathMax(0, d);
  }

//+------------------------------------------------------------------+
//| Floor a volume to the symbol's step (never rounds risk upwards).  |
//+------------------------------------------------------------------+
double FloorToVolumeStep(const string symbol, const double lots)
  {
   double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      step = 0.01;
   double floored = MathFloor(lots / step + 1e-9) * step;
   return NormalizeDouble(floored, VolumeDigits(step));
  }

//+------------------------------------------------------------------+
//| Snapshot of one position owned by this EA.                        |
//+------------------------------------------------------------------+
struct SPositionInfo
  {
   ulong             ticket;
   long              identifier;
   long              magic;
   int               strategyId;  // magic - base magic
   long              type;        // POSITION_TYPE_BUY / POSITION_TYPE_SELL
   double            volume;
   double            openPrice;
   double            sl;
   double            tp;
   datetime          openTime;
  };

//--- Collect all positions for symbol opened by any of this EA's strategies
int CollectPositions(const string symbol, const long baseMagic, SPositionInfo &out[])
  {
   ArrayResize(out, 0);
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      long magic = PositionGetInteger(POSITION_MAGIC);
      if(!IsOwnMagic(magic, baseMagic))
         continue;
      SPositionInfo p;
      p.ticket     = ticket;
      p.magic      = magic;
      p.strategyId = (int)(magic - baseMagic);
      p.identifier = PositionGetInteger(POSITION_IDENTIFIER);
      p.type       = PositionGetInteger(POSITION_TYPE);
      p.volume     = PositionGetDouble(POSITION_VOLUME);
      p.openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      p.sl         = PositionGetDouble(POSITION_SL);
      p.tp         = PositionGetDouble(POSITION_TP);
      p.openTime   = (datetime)PositionGetInteger(POSITION_TIME);
      int sz = ArraySize(out);
      ArrayResize(out, sz + 1);
      out[sz] = p;
     }
   return ArraySize(out);
  }

//--- True when the stop already sits at or beyond the entry (trade can no longer lose)
bool IsRiskFree(const SPositionInfo &p)
  {
   if(p.sl <= 0.0)
      return false;
   if(p.type == POSITION_TYPE_BUY)
      return (p.sl >= p.openPrice);
   return (p.sl <= p.openPrice);
  }

bool IsHedgingAccount()
  {
   return ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
  }

#endif // XS_COMMON_MQH
//+------------------------------------------------------------------+
