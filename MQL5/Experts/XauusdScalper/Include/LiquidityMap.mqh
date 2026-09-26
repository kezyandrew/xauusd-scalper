//+------------------------------------------------------------------+
//|                                               LiquidityMap.mqh   |
//|  Finds resting-liquidity pools (swing / equal highs & lows,      |
//|  Asian range, previous-day high/low, round numbers, failed       |
//|  breakout levels) and detects sweeps of them: a wick beyond the  |
//|  level that closes back inside, ideally on a tick-volume spike.  |
//+------------------------------------------------------------------+
#ifndef XS_LIQUIDITY_MAP_MQH
#define XS_LIQUIDITY_MAP_MQH

#include "Common.mqh"
#include "MarketData.mqh"

enum ENUM_POOL_TYPE
  {
   POOL_SWING     = 0,
   POOL_EQUAL     = 1,
   POOL_ASIAN     = 2,
   POOL_PREV_DAY  = 3,
   POOL_ROUND     = 4,
   POOL_FAILED_BO = 5
  };

struct SLiquidityPool
  {
   double            price;
   int               side;    // +1 buy-side liquidity (stops above highs), -1 sell-side (below lows)
   ENUM_POOL_TYPE    type;
   int               weight;
  };

struct SSweep
  {
   bool              valid;
   int               tradeDir;   // direction of the reversal trade (-1 after highs are swept)
   double            level;      // swept level closest to price (must be reclaimed)
   double            extreme;    // furthest price reached by the sweep
   int               strength;   // summed weight of the pools taken
   string            sources;
   int               barIndex;   // 0 = last closed bar, 1 = the bar before
   datetime          barTime;    // time of the last closed bar when detected
   double            volRatio;
  };

struct SLiquidityConfig
  {
   ENUM_TIMEFRAMES   tf;
   int               swingLookback;
   int               swingStrength;     // bars on each side of a fractal pivot
   double            equalTolAtr;       // two swings within this many ATR = equal highs/lows
   bool              useSwings;
   bool              useEqual;
   bool              useAsian;
   bool              usePrevDay;
   bool              useRound;
   bool              useFailedBreakouts;
   STimeWindow       asianWindow;       // server time
   double            roundStep;         // price units, 0 = off
   double            minPierceAtr;      // wick must exceed the level by at least this
   double            maxPierceAtr;      // ...but not by more (that is a real breakout)
   double            minWickFrac;       // rejection wick / bar range
   double            minVolRatio;       // tick-volume spike on the sweep bar (0 = off)
   int               minStrength;       // summed pool weight needed
   int               failedBoExpiryBars;
  };

class CLiquidityMap
  {
private:
   string            m_symbol;
   SLiquidityConfig  m_cfg;
   SLiquidityPool    m_pools[];
   SSweep            m_sweep;
   MqlRates          m_rates[];
   int               m_count;
   double            m_atr;

   //--- latest failed breakout reported by the breakout strategy
   bool              m_fbValid;
   int               m_fbDir;
   double            m_fbLevel;
   double            m_fbExtreme;
   datetime          m_fbTime;

   void              AddPool(const double price, const int side, const ENUM_POOL_TYPE type, const int weight)
     {
      int n = ArraySize(m_pools);
      ArrayResize(m_pools, n + 1);
      m_pools[n].price  = price;
      m_pools[n].side   = side;
      m_pools[n].type   = type;
      m_pools[n].weight = weight;
     }

   string            TypeName(const ENUM_POOL_TYPE t) const
     {
      switch(t)
        {
         case POOL_SWING:     return "swing";
         case POOL_EQUAL:     return "equal";
         case POOL_ASIAN:     return "asian";
         case POOL_PREV_DAY:  return "prevDay";
         case POOL_ROUND:     return "round";
         case POOL_FAILED_BO: return "failedBO";
        }
      return "?";
     }

   //--- Level still untouched between bar `from` (older) and bar 2 (bars 0/1 are sweep candidates)
   bool              Intact(const double level, const int side, const int from) const
     {
      for(int j = 2; j < from && j < m_count; j++)
        {
         if(side > 0 && m_rates[j].high >= level)
            return false;
         if(side < 0 && m_rates[j].low <= level)
            return false;
        }
      return true;
     }

   double            BarVolRatio(const int k) const
     {
      int n = 20;
      if(k + n >= m_count)
         return 0.0;
      double sum = 0.0;
      for(int j = k + 1; j <= k + n; j++)
         sum += (double)m_rates[j].tick_volume;
      double avg = sum / n;
      return (avg > 0.0) ? (double)m_rates[k].tick_volume / avg : 0.0;
     }

   void              BuildSwings()
     {
      int s = m_cfg.swingStrength;
      int last = MathMin(m_cfg.swingLookback, m_count - s - 1);
      for(int i = s + 2; i <= last; i++)
        {
         bool isHigh = true, isLow = true;
         for(int j = i - s; j <= i + s; j++)
           {
            if(j == i)
               continue;
            if(m_rates[j].high >= m_rates[i].high)
               isHigh = false;
            if(m_rates[j].low <= m_rates[i].low)
               isLow = false;
           }
         if(isHigh && Intact(m_rates[i].high, 1, i))
            AddPool(m_rates[i].high, 1, POOL_SWING, 1);
         if(isLow && Intact(m_rates[i].low, -1, i))
            AddPool(m_rates[i].low, -1, POOL_SWING, 1);
        }
     }

   void              BuildEqual()
     {
      double tol = m_cfg.equalTolAtr * m_atr;
      int n = ArraySize(m_pools);
      for(int a = 0; a < n; a++)
         for(int b = a + 1; b < n; b++)
           {
            if(m_pools[a].type != POOL_SWING || m_pools[b].type != POOL_SWING)
               continue;
            if(m_pools[a].side != m_pools[b].side || MathAbs(m_pools[a].price - m_pools[b].price) > tol)
               continue;
            double lvl = (m_pools[a].side > 0) ? MathMax(m_pools[a].price, m_pools[b].price)
                                               : MathMin(m_pools[a].price, m_pools[b].price);
            AddPool(lvl, m_pools[a].side, POOL_EQUAL, 2);
           }
     }

   void              BuildPrevDay()
     {
      double pdh = iHigh(m_symbol, PERIOD_D1, 1);
      double pdl = iLow(m_symbol, PERIOD_D1, 1);
      if(pdh <= 0.0 || pdl <= 0.0)
         return;
      datetime today = DayStart(m_rates[0].time);
      int from = 2;
      while(from < m_count && m_rates[from].time >= today)
         from++;
      if(Intact(pdh, 1, from))
         AddPool(pdh, 1, POOL_PREV_DAY, 3);
      if(Intact(pdl, -1, from))
         AddPool(pdl, -1, POOL_PREV_DAY, 3);
     }

   //--- Most recent completed Asian window
   void              BuildAsian()
     {
      if(MinuteInWindow(MinuteOfDay(m_rates[0].time), m_cfg.asianWindow))
         return;
      int j = 0;
      while(j < m_count && !MinuteInWindow(MinuteOfDay(m_rates[j].time), m_cfg.asianWindow))
         j++;
      if(j >= m_count)
         return;
      int newest = j;
      double hi = m_rates[j].high, lo = m_rates[j].low;
      while(j < m_count && MinuteInWindow(MinuteOfDay(m_rates[j].time), m_cfg.asianWindow))
        {
         hi = MathMax(hi, m_rates[j].high);
         lo = MathMin(lo, m_rates[j].low);
         j++;
        }
      if(j >= m_count)
         return; // window not fully inside the loaded history
      if(Intact(hi, 1, newest))
         AddPool(hi, 1, POOL_ASIAN, 2);
      if(Intact(lo, -1, newest))
         AddPool(lo, -1, POOL_ASIAN, 2);
     }

   void              BuildRound()
     {
      if(m_cfg.roundStep <= 0.0 || m_count < 3)
         return;
      double ref = m_rates[2].close;
      AddPool(MathCeil(ref / m_cfg.roundStep) * m_cfg.roundStep, 1, POOL_ROUND, 1);
      AddPool(MathFloor(ref / m_cfg.roundStep) * m_cfg.roundStep, -1, POOL_ROUND, 1);
     }

   //--- Wick-based sweep of pools on bar k (0 or 1)
   bool              DetectWickSweep(const int k, const int side, SSweep &out) const
     {
      MqlRates b = m_rates[k];
      double range = b.high - b.low;
      if(range <= 0.0 || m_atr <= 0.0)
         return false;
      double wick = (side > 0) ? b.high - MathMax(b.open, b.close) : MathMin(b.open, b.close) - b.low;
      if(wick < m_cfg.minWickFrac * range)
         return false;
      double volRatio = BarVolRatio(k);
      if(m_cfg.minVolRatio > 0.0 && volRatio < m_cfg.minVolRatio)
         return false;

      double extreme = (side > 0) ? b.high : b.low;
      if(k == 1)
         extreme = (side > 0) ? MathMax(b.high, m_rates[0].high) : MathMin(b.low, m_rates[0].low);

      int strength = 0;
      double level = 0.0;
      string src = "";
      for(int i = 0; i < ArraySize(m_pools); i++)
        {
         SLiquidityPool p = m_pools[i];
         if(p.side != side || p.type == POOL_FAILED_BO)
            continue;
         double pierce = (side > 0) ? b.high - p.price : p.price - b.low;
         if(pierce < m_cfg.minPierceAtr * m_atr || pierce > m_cfg.maxPierceAtr * m_atr)
            continue;
         bool closedInside = (side > 0) ? b.close < p.price : b.close > p.price;
         if(!closedInside)
            continue;
         if(k == 0 && ((side > 0 && m_rates[1].high >= p.price) || (side < 0 && m_rates[1].low <= p.price)))
            continue; // bar 1 already took it; that sweep is evaluated with k = 1
         if(k == 1 && ((side > 0 && m_rates[0].close >= p.price) || (side < 0 && m_rates[0].close <= p.price)))
            continue; // reclaim did not hold on the following bar
         strength += p.weight;
         if(level == 0.0 || (side > 0 && p.price < level) || (side < 0 && p.price > level))
            level = p.price;
         src += (src == "" ? "" : "+") + TypeName(p.type);
        }
      if(strength < m_cfg.minStrength)
         return false;

      //--- Reversal bar quality: close away from the swept side
      if(k == 0)
        {
         double loc = (b.close - b.low) / range;
         if((side > 0 && loc > 0.5) || (side < 0 && loc < 0.5))
            return false;
        }
      else
        {
         double body0 = m_rates[0].close - m_rates[0].open;
         if((side > 0 && body0 >= 0.0) || (side < 0 && body0 <= 0.0))
            return false;
        }

      out.valid    = true;
      out.tradeDir = -side;
      out.level    = level;
      out.extreme  = extreme;
      out.strength = strength;
      out.sources  = src;
      out.barIndex = k;
      out.barTime  = m_rates[0].time;
      out.volRatio = volRatio;
      return true;
     }

   //--- Close-based sweep: a breakout that closed beyond a level and has now closed back inside
   bool              DetectFailedBreakout(SSweep &out) const
     {
      if(!m_cfg.useFailedBreakouts || !m_fbValid || m_fbTime != m_rates[0].time)
         return false;
      int strength = 2;
      string src = "failedBO";
      for(int i = 0; i < ArraySize(m_pools); i++)
        {
         SLiquidityPool p = m_pools[i];
         if(p.side == m_fbDir && p.type != POOL_FAILED_BO &&
            MathAbs(p.price - m_fbLevel) <= m_cfg.equalTolAtr * m_atr)
           {
            strength += p.weight;
            src += "+" + TypeName(p.type);
           }
        }
      out.valid    = true;
      out.tradeDir = -m_fbDir;
      out.level    = m_fbLevel;
      out.extreme  = m_fbExtreme;
      out.strength = strength;
      out.sources  = src;
      out.barIndex = 0;
      out.barTime  = m_rates[0].time;
      out.volRatio = BarVolRatio(0);
      return true;
     }

public:
                     CLiquidityMap() : m_count(0), m_atr(0.0), m_fbValid(false), m_fbDir(0), m_fbLevel(0.0),
                     m_fbExtreme(0.0), m_fbTime(0)
     {
      ZeroMemory(m_sweep);
     }

   void              Init(const string symbol, const SLiquidityConfig &cfg)
     {
      m_symbol = symbol;
      m_cfg    = cfg;
      ArraySetAsSeries(m_rates, true);
     }

   //--- Called by the breakout strategy when a breakout closes back inside its range
   void              ReportFailedBreakout(const int breakoutDir, const double level, const double extreme,
                                          const datetime barTime)
     {
      m_fbValid   = true;
      m_fbDir     = breakoutDir;
      m_fbLevel   = level;
      m_fbExtreme = extreme;
      m_fbTime    = barTime;
     }

   //+---------------------------------------------------------------+
   //| Rebuild pools and look for a fresh sweep on the last 2 bars.  |
   //+---------------------------------------------------------------+
   bool              Update(const SMarketContext &c)
     {
      ZeroMemory(m_sweep);
      ArrayResize(m_pools, 0);
      m_atr = c.atr;
      int need = MathMax(m_cfg.swingLookback + m_cfg.swingStrength + 2, 300);
      m_count = CopyRates(m_symbol, m_cfg.tf, 1, need, m_rates);
      if(m_count < m_cfg.swingLookback || m_atr <= 0.0)
         return false;

      if(m_cfg.useSwings)
         BuildSwings();
      if(m_cfg.useEqual)
         BuildEqual();
      if(m_cfg.usePrevDay)
         BuildPrevDay();
      if(m_cfg.useAsian)
         BuildAsian();
      if(m_cfg.useRound)
         BuildRound();

      if(m_fbValid && m_fbTime < m_rates[MathMin(m_cfg.failedBoExpiryBars, m_count - 1)].time)
         m_fbValid = false;
      if(m_fbValid)
         AddPool(m_fbLevel, m_fbDir, POOL_FAILED_BO, 2);

      SSweep s;
      ZeroMemory(s);
      if(DetectFailedBreakout(s) ||
         DetectWickSweep(0, 1, s) || DetectWickSweep(0, -1, s) ||
         DetectWickSweep(1, 1, s) || DetectWickSweep(1, -1, s))
         m_sweep = s;
      return true;
     }

   //--- Sweep detected on the most recent Update (valid == false if none)
   void              LastSweep(SSweep &out) const { out = m_sweep; }

   bool              HasFreshSweep(const int tradeDir) const
     {
      return (m_sweep.valid && m_sweep.tradeDir == tradeDir);
     }

   //--- Prices where resting stops cluster; the risk manager keeps our stops clear of them
   int               StopAvoidLevels(double &out[]) const
     {
      int n = ArraySize(m_pools);
      ArrayResize(out, n);
      for(int i = 0; i < n; i++)
         out[i] = m_pools[i].price;
      return n;
     }

   int               PoolCount() const { return ArraySize(m_pools); }
  };

#endif // XS_LIQUIDITY_MAP_MQH
//+------------------------------------------------------------------+
