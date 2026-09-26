//+------------------------------------------------------------------+
//|                                              SweepReversal.mqh   |
//|  Trades the reclaim after a liquidity sweep: price runs the      |
//|  stops resting beyond a pool (swing / equal highs-lows, Asian    |
//|  range, previous day, round number, failed breakout), then       |
//|  closes back inside. The stop goes beyond the sweep extreme plus |
//|  the shared ATR buffer - never at the obvious level itself.      |
//+------------------------------------------------------------------+
#ifndef XS_SWEEP_REVERSAL_MQH
#define XS_SWEEP_REVERSAL_MQH

#include "StrategyBase.mqh"
#include "../LiquidityMap.mqh"

struct SSweepReversalConfig
  {
   int               minStrength;     // summed pool weight required (confluence)
   double            minReclaimAtr;   // close must be this far back inside the level
   bool              withTrendOnly;   // in TREND regime only take sweeps in the trend direction
  };

class CSweepReversal : public CStrategy
  {
private:
   SSweepReversalConfig m_cfg;
   CLiquidityMap    *m_liq;

public:
                     CSweepReversal(const SSweepReversalConfig &cfg, CLiquidityMap *liq)
      : CStrategy(XS_STRATEGY_SWEEP_REVERSAL, "SweepReversal", REGIME_RANGE)
     {
      m_cfg = cfg;
      m_liq = liq;
     }

   virtual bool      CheckEntry(const SMarketContext &c, const ENUM_REGIME regime, const int regimeDir,
                                STradeIntent &intent, string &why)
     {
      ResetIntent(intent);
      if(CheckPointer(m_liq) == POINTER_INVALID)
        { why = "sweep: liquidity map unavailable"; return false; }

      SSweep s;
      m_liq.LastSweep(s);
      if(!s.valid || s.barTime != c.barTime)
        { why = "sweep: no fresh liquidity sweep"; return false; }
      if(s.strength < m_cfg.minStrength)
        { why = StringFormat("sweep: pool strength %d < %d", s.strength, m_cfg.minStrength); return false; }
      if(regime == REGIME_TREND && m_cfg.withTrendOnly && s.tradeDir != regimeDir)
        { why = "sweep: counter-trend sweep in TREND regime"; return false; }

      double reclaim = (s.tradeDir > 0) ? c.close[0] - s.level : s.level - c.close[0];
      if(reclaim < m_cfg.minReclaimAtr * c.atr)
        { why = "sweep: reclaim too shallow"; return false; }

      Fill(intent, (s.tradeDir > 0) ? SIGNAL_BUY : SIGNAL_SELL, "sweep:" + s.sources, s.extreme, 0.0, 0.0);
      return true;
     }
  };

#endif // XS_SWEEP_REVERSAL_MQH
//+------------------------------------------------------------------+
