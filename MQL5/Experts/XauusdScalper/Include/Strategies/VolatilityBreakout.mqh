//+------------------------------------------------------------------+
//|                                         VolatilityBreakout.mqh   |
//|  BREAKOUT regime: trade a range break only once it is confirmed. |
//|  Fake-breakout protection:                                       |
//|   - the bar must CLOSE beyond the level plus an ATR buffer       |
//|     (wicks through the level never qualify),                     |
//|   - strong body, close near the bar extreme, tick-volume surge,  |
//|   - optional hold / retest confirmation on the following bars,   |
//|   - no chasing: max distance from the fast EMA.                  |
//|  Breakouts that close back inside the range are reported to the  |
//|  liquidity map as failed breakouts (sweep-reversal candidates).  |
//+------------------------------------------------------------------+
#ifndef XS_VOLATILITY_BREAKOUT_MQH
#define XS_VOLATILITY_BREAKOUT_MQH

#include "StrategyBase.mqh"
#include "../LiquidityMap.mqh"

enum ENUM_BREAKOUT_CONFIRM
  {
   BO_CONFIRM_CLOSE  = 0, // Close beyond level (fastest, most fake-outs)
   BO_CONFIRM_HOLD   = 1, // Next bar holds beyond level
   BO_CONFIRM_RETEST = 2  // Price retests the level and holds (fewest fake-outs)
  };

struct SVolBreakoutConfig
  {
   int                   rangeBars;       // Donchian lookback (bars before the signal bar)
   double                bufferAtr;       // close must exceed the level by this many ATR
   double                minBodyFrac;     // body / range of the breakout bar
   double                minCloseLoc;     // close location in the bar (0.7 = top 30% for longs)
   double                minVolRatio;     // tick-volume surge on the breakout bar
   double                maxExtensionAtr; // max distance of close from fast EMA (no chasing)
   bool                  respectHtf;      // skip breakouts against the higher-timeframe bias
   ENUM_BREAKOUT_CONFIRM confirm;
   int                   maxWaitBars;     // bars allowed for hold / retest confirmation
   double                retestTolAtr;    // how close to the level a retest must come
  };

class CVolatilityBreakout : public CStrategy
  {
private:
   SVolBreakoutConfig m_cfg;
   CLiquidityMap    *m_liq;

   //--- tracked breakout: m_active while watched for failure, m_pending while awaiting
   //--- confirmation, m_ready on the bar it becomes tradeable
   bool              m_active;
   int               m_age;
   bool              m_pending;
   bool              m_ready;
   int               m_dir;
   double            m_level;
   double            m_extreme;
   datetime          m_startTime;
   datetime          m_readyTime;
   int               m_waited;

   //--- Is bar 0 a qualified close-based breakout? Sets dir and level.
   bool              Qualifies(const SMarketContext &c, int &dir, double &level) const
     {
      int bars = MathMin(m_cfg.rangeBars, XS_CTX_BARS - 1);
      double hh = c.high[1];
      double ll = c.low[1];
      for(int i = 2; i <= bars; i++)
        {
         hh = MathMax(hh, c.high[i]);
         ll = MathMin(ll, c.low[i]);
        }
      double range = c.high[0] - c.low[0];
      double body  = c.close[0] - c.open[0];
      if(range <= 0.0 || MathAbs(body) < m_cfg.minBodyFrac * range || c.volRatio < m_cfg.minVolRatio)
         return false;
      double loc    = (c.close[0] - c.low[0]) / range;
      double buffer = m_cfg.bufferAtr * c.atr;
      if(body > 0.0 && c.close[0] > hh + buffer && loc >= m_cfg.minCloseLoc)
        { dir = 1; level = hh; return true; }
      if(body < 0.0 && c.close[0] < ll - buffer && loc <= 1.0 - m_cfg.minCloseLoc)
        { dir = -1; level = ll; return true; }
      return false;
     }

   void              Reset() { m_active = false; m_pending = false; m_ready = false; m_waited = 0; m_age = 0; }

public:
                     CVolatilityBreakout(const SVolBreakoutConfig &cfg, CLiquidityMap *liq)
      : CStrategy(XS_STRATEGY_VOL_BREAKOUT, "VolBreakout", REGIME_BREAKOUT)
     {
      m_cfg = cfg;
      m_liq = liq;
      m_dir = 0;
      m_level = 0.0;
      m_extreme = 0.0;
      m_startTime = 0;
      m_readyTime = 0;
      Reset();
     }

   virtual void      OnBar(const SMarketContext &c)
     {
      //--- 1. Follow up the tracked breakout: confirm it, or detect that it failed
      if(m_active && c.barTime != m_startTime)
        {
         m_age++;
         bool failed = (m_dir > 0) ? c.close[0] < m_level : c.close[0] > m_level;
         m_extreme = (m_dir > 0) ? MathMax(m_extreme, c.high[0]) : MathMin(m_extreme, c.low[0]);
         if(failed)
           {
            if(CheckPointer(m_liq) != POINTER_INVALID)
               m_liq.ReportFailedBreakout(m_dir, m_level, m_extreme, c.barTime);
            Reset();
           }
         else
            if(m_pending)
              {
               m_waited++;
               double tol    = m_cfg.retestTolAtr * c.atr;
               double body   = c.close[0] - c.open[0];
               bool   beyond = (m_dir > 0) ? c.close[0] > m_level : c.close[0] < m_level;
               bool   ok     = false;
               if(m_cfg.confirm == BO_CONFIRM_HOLD)
                  ok = beyond && ((m_dir > 0) ? c.low[0] >= m_level - tol : c.high[0] <= m_level + tol);
               else
                  ok = beyond && ((m_dir > 0) ? (c.low[0] <= m_level + tol && body > 0.0)
                                              : (c.high[0] >= m_level - tol && body < 0.0));
               if(ok)
                 {
                  m_pending   = false;
                  m_ready     = true;
                  m_readyTime = c.barTime;
                 }
               else
                  if(m_waited >= m_cfg.maxWaitBars)
                     m_pending = false;
              }
            else
               if(m_ready && c.barTime != m_readyTime)
                  m_ready = false; // a confirmation is only actionable on its own bar

         //--- keep watching for failure a few bars after the break, then forget it
         if(m_active && !m_pending && !m_ready && m_age >= m_cfg.maxWaitBars + 3)
            m_active = false;
        }

      //--- 2. Look for a new breakout
      if(!m_active)
        {
         int dir = 0;
         double level = 0.0;
         if(Qualifies(c, dir, level))
           {
            m_active    = true;
            m_age       = 0;
            m_dir       = dir;
            m_level     = level;
            m_extreme   = (dir > 0) ? c.high[0] : c.low[0];
            m_startTime = c.barTime;
            m_waited    = 0;
            if(m_cfg.confirm == BO_CONFIRM_CLOSE)
              {
               m_ready     = true;
               m_readyTime = c.barTime;
              }
            else
               m_pending = true;
           }
        }
     }

   virtual bool      CheckEntry(const SMarketContext &c, const ENUM_REGIME regime, const int regimeDir,
                                STradeIntent &intent, string &why)
     {
      ResetIntent(intent);
      if(m_pending)
        { why = StringFormat("breakout: awaiting confirmation (%d/%d)", m_waited, m_cfg.maxWaitBars); return false; }
      if(!m_ready || m_readyTime != c.barTime)
        { why = "breakout: no confirmed range break"; return false; }
      if(regimeDir != 0 && regimeDir != m_dir)
        { why = "breakout: against regime direction"; return false; }
      if(m_cfg.respectHtf && c.htfBias == -m_dir)
        { why = "breakout: against higher-timeframe trend"; return false; }
      double ext = (m_dir > 0) ? c.close[0] - c.emaFast[0] : c.emaFast[0] - c.close[0];
      if(ext > m_cfg.maxExtensionAtr * c.atr)
        { why = "breakout: over-extended, not chasing"; return false; }

      m_ready = false;
      //--- Invalidation = back inside the broken range; the risk manager adds the ATR buffer
      Fill(intent, (m_dir > 0) ? SIGNAL_BUY : SIGNAL_SELL,
           (m_cfg.confirm == BO_CONFIRM_CLOSE) ? "range-break" : "range-break-confirmed", m_level, 0.0, 0.0);
      return true;
     }
  };

#endif // XS_VOLATILITY_BREAKOUT_MQH
//+------------------------------------------------------------------+
