//+------------------------------------------------------------------+
//|                                               StrategyBase.mqh   |
//|  Interface every strategy module implements. Strategies only     |
//|  decide direction, invalidation level and (optionally) a natural |
//|  target. Sizing, stop distance rules and trade management are    |
//|  owned by the central risk / trade managers.                     |
//+------------------------------------------------------------------+
#ifndef XS_STRATEGY_BASE_MQH
#define XS_STRATEGY_BASE_MQH

#include "../Common.mqh"
#include "../MarketData.mqh"

struct STradeIntent
  {
   ENUM_SIGNAL       signal;
   int               strategyId;
   string            strategyName;
   string            setup;
   double            stopAnchor;   // structural invalidation price, 0 = ATR stop only
   double            targetPrice;  // natural target (e.g. band mean), 0 = profile R-multiple
   double            minTargetR;   // reject if the natural target is closer than this many R
  };

void ResetIntent(STradeIntent &intent)
  {
   intent.signal       = SIGNAL_NONE;
   intent.strategyId   = 0;
   intent.strategyName = "";
   intent.setup        = "";
   intent.stopAnchor   = 0.0;
   intent.targetPrice  = 0.0;
   intent.minTargetR   = 0.0;
  }

class CStrategy
  {
protected:
   int               m_id;
   string            m_name;
   int               m_regimeMask;   // bit (1 << regime) per regime the strategy may trade in
   bool              m_enabled;

   void              Fill(STradeIntent &intent, const ENUM_SIGNAL signal, const string setup,
                          const double anchor, const double target, const double minTargetR)
     {
      intent.signal       = signal;
      intent.strategyId   = m_id;
      intent.strategyName = m_name;
      intent.setup        = setup;
      intent.stopAnchor   = anchor;
      intent.targetPrice  = target;
      intent.minTargetR   = minTargetR;
     }

   double            LowestLow(const SMarketContext &c, const int bars) const
     {
      double v = c.low[0];
      for(int i = 1; i < bars && i < XS_CTX_BARS; i++)
         v = MathMin(v, c.low[i]);
      return v;
     }

   double            HighestHigh(const SMarketContext &c, const int bars) const
     {
      double v = c.high[0];
      for(int i = 1; i < bars && i < XS_CTX_BARS; i++)
         v = MathMax(v, c.high[i]);
      return v;
     }

public:
                     CStrategy(const int id, const string name, const ENUM_REGIME regime)
     {
      m_id         = id;
      m_name       = name;
      m_regimeMask = (1 << (int)regime);
      m_enabled    = true;
     }

   virtual          ~CStrategy() {}

   int               Id() const { return m_id; }
   string            Name() const { return m_name; }
   bool              Enabled() const { return m_enabled; }
   void              SetEnabled(const bool on) { m_enabled = on; }

   void              AllowRegime(const ENUM_REGIME r, const bool allow)
     {
      if(allow)
         m_regimeMask |= (1 << (int)r);
      else
         m_regimeMask &= ~(1 << (int)r);
     }

   bool              SuitsRegime(const ENUM_REGIME r) const { return ((m_regimeMask & (1 << (int)r)) != 0); }

   string            RegimesText() const
     {
      string s = "";
      for(int r = REGIME_NONE; r <= REGIME_CHAOTIC; r++)
         if(SuitsRegime((ENUM_REGIME)r))
            s += (s == "" ? "" : "/") + RegimeToString((ENUM_REGIME)r);
      return (s == "") ? "-" : s;
     }

   //--- Called on every closed bar for every strategy (enabled or selected or not),
   //--- so stateful modules can track setups that span several bars.
   virtual void      OnBar(const SMarketContext &c) {}

   //--- Inspect the last closed bar; fill intent and return true when a setup fires.
   //--- regimeDir is the confirmed regime direction (+1/-1, 0 for non-directional regimes).
   virtual bool      CheckEntry(const SMarketContext &c, const ENUM_REGIME regime, const int regimeDir,
                                STradeIntent &intent, string &why)
     {
      why = "not implemented";
      return false;
     }
  };

#endif // XS_STRATEGY_BASE_MQH
//+------------------------------------------------------------------+
