//+------------------------------------------------------------------+
//|                                              MeanReversion.mqh   |
//|  RANGE regime: fade a Bollinger-band excursion once price closes |
//|  back inside the band with RSI turning, targeting the band mean. |
//+------------------------------------------------------------------+
#ifndef XS_MEAN_REVERSION_MQH
#define XS_MEAN_REVERSION_MQH

#include "StrategyBase.mqh"

struct SMeanReversionConfig
  {
   double            rsiOversold;   // mirrored (100 - x) for overbought
   double            maxVolRatio;   // a tick-volume surge suggests a breakout, not a fade
   double            minTargetR;    // band mean must be at least this many R away
   int               anchorBars;    // excursion extreme lookback for the structural stop
  };

class CMeanReversion : public CStrategy
  {
private:
   SMeanReversionConfig m_cfg;

public:
                     CMeanReversion(const SMeanReversionConfig &cfg)
      : CStrategy(XS_STRATEGY_MEAN_REVERSION, "MeanReversion", REGIME_RANGE)
     {
      m_cfg = cfg;
     }

   virtual bool      CheckEntry(const SMarketContext &c, const ENUM_REGIME regime, const int regimeDir,
                                STradeIntent &intent, string &why)
     {
      ResetIntent(intent);
      if(c.volRatio > m_cfg.maxVolRatio)
        { why = StringFormat("mean-rev: volume surge %.2f (breakout risk)", c.volRatio); return false; }

      double body = c.close[0] - c.open[0];
      double rsiLow  = MathMin(c.rsi[0], c.rsi[1]);
      double rsiHigh = MathMax(c.rsi[0], c.rsi[1]);

      bool piercedLow  = (c.low[0] < c.bbLower[0] || c.low[1] < c.bbLower[1]);
      bool backInsideL = (c.close[0] > c.bbLower[0] && body > 0.0);
      if(piercedLow && backInsideL && rsiLow <= m_cfg.rsiOversold && c.rsi[0] > c.rsi[1])
        {
         Fill(intent, SIGNAL_BUY, "band-fade", LowestLow(c, m_cfg.anchorBars), c.bbMid[0], m_cfg.minTargetR);
         return true;
        }

      bool piercedHigh = (c.high[0] > c.bbUpper[0] || c.high[1] > c.bbUpper[1]);
      bool backInsideH = (c.close[0] < c.bbUpper[0] && body < 0.0);
      if(piercedHigh && backInsideH && rsiHigh >= 100.0 - m_cfg.rsiOversold && c.rsi[0] < c.rsi[1])
        {
         Fill(intent, SIGNAL_SELL, "band-fade", HighestHigh(c, m_cfg.anchorBars), c.bbMid[0], m_cfg.minTargetR);
         return true;
        }

      why = "mean-rev: waiting for band rejection";
      return false;
     }
  };

#endif // XS_MEAN_REVERSION_MQH
//+------------------------------------------------------------------+
