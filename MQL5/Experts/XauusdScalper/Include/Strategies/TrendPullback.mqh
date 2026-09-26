//+------------------------------------------------------------------+
//|                                              TrendPullback.mqh   |
//|  TREND regime: buy dips / sell rallies into the fast EMA that    |
//|  are rejected in the trend direction with normal participation.  |
//+------------------------------------------------------------------+
#ifndef XS_TREND_PULLBACK_MQH
#define XS_TREND_PULLBACK_MQH

#include "StrategyBase.mqh"

struct STrendPullbackConfig
  {
   double            zoneAtr;      // how close to the fast EMA the pullback must reach (ATR units)
   double            minVolRatio;  // rejection bar tick volume vs average
   double            rsiMin;       // momentum window for longs (mirrored for shorts)
   double            rsiMax;
   int               anchorBars;   // swing lookback for the structural stop
  };

class CTrendPullback : public CStrategy
  {
private:
   STrendPullbackConfig m_cfg;

public:
                     CTrendPullback(const STrendPullbackConfig &cfg)
      : CStrategy(XS_STRATEGY_TREND_PULLBACK, "TrendPullback", REGIME_TREND)
     {
      m_cfg = cfg;
     }

   virtual bool      CheckEntry(const SMarketContext &c, const ENUM_REGIME regime, const int regimeDir,
                                STradeIntent &intent, string &why)
     {
      ResetIntent(intent);
      if(regimeDir == 0)
        { why = "trend direction unknown"; return false; }
      if(c.volRatio < m_cfg.minVolRatio)
        { why = StringFormat("pullback: weak participation (vol %.2f)", c.volRatio); return false; }

      double zone = m_cfg.zoneAtr * c.atr;
      double body = c.close[0] - c.open[0];

      if(regimeDir > 0)
        {
         bool touched  = (c.low[0] <= c.emaFast[0] + zone && c.low[0] >= c.emaSlow[0] - zone);
         bool rejected = (body > 0.0 && c.close[0] > c.emaFast[0] && c.close[0] > c.close[1]);
         bool momentum = (c.rsi[0] >= m_cfg.rsiMin && c.rsi[0] <= m_cfg.rsiMax && c.plusDi > c.minusDi);
         if(touched && rejected && momentum)
           {
            Fill(intent, SIGNAL_BUY, "ema-pullback", LowestLow(c, m_cfg.anchorBars), 0.0, 0.0);
            return true;
           }
        }
      else
        {
         bool touched  = (c.high[0] >= c.emaFast[0] - zone && c.high[0] <= c.emaSlow[0] + zone);
         bool rejected = (body < 0.0 && c.close[0] < c.emaFast[0] && c.close[0] < c.close[1]);
         bool momentum = (c.rsi[0] <= 100.0 - m_cfg.rsiMin && c.rsi[0] >= 100.0 - m_cfg.rsiMax && c.minusDi > c.plusDi);
         if(touched && rejected && momentum)
           {
            Fill(intent, SIGNAL_SELL, "ema-pullback", HighestHigh(c, m_cfg.anchorBars), 0.0, 0.0);
            return true;
           }
        }
      why = "pullback: waiting for EMA rejection";
      return false;
     }
  };

#endif // XS_TREND_PULLBACK_MQH
//+------------------------------------------------------------------+
