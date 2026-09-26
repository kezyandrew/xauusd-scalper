//+------------------------------------------------------------------+
//|                                           StrategySelector.mqh   |
//|  Registry of strategy modules. Registration order is priority:   |
//|  for the confirmed regime, the first enabled strategy suited to  |
//|  it that produces a setup wins. Owns (and deletes) the modules.  |
//+------------------------------------------------------------------+
#ifndef XS_STRATEGY_SELECTOR_MQH
#define XS_STRATEGY_SELECTOR_MQH

#include "Strategies/StrategyBase.mqh"

class CStrategySelector
  {
private:
   CStrategy        *m_items[];

public:
                    ~CStrategySelector() { Clear(); }

   void              Clear()
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(CheckPointer(m_items[i]) == POINTER_DYNAMIC)
            delete m_items[i];
      ArrayResize(m_items, 0);
     }

   //--- Takes ownership of the strategy object
   bool              Add(CStrategy *strategy)
     {
      if(CheckPointer(strategy) == POINTER_INVALID)
         return false;
      if(strategy.Id() <= 0 || strategy.Id() >= XS_MAGIC_SLOTS)
        {
         PrintFormat("StrategySelector: id %d of %s is outside 1..%d", strategy.Id(), strategy.Name(), XS_MAGIC_SLOTS - 1);
         delete strategy;
         return false;
        }
      int n = ArraySize(m_items);
      ArrayResize(m_items, n + 1);
      m_items[n] = strategy;
      return true;
     }

   int               Count() const { return ArraySize(m_items); }
   CStrategy        *At(const int i) { return (i >= 0 && i < ArraySize(m_items)) ? m_items[i] : NULL; }

   //--- Let every module update its multi-bar state
   void              OnBarAll(const SMarketContext &c)
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         m_items[i].OnBar(c);
     }

   //--- Number of enabled strategies allowed in a regime
   int               CountFor(const ENUM_REGIME regime)
     {
      int n = 0;
      for(int i = 0; i < ArraySize(m_items); i++)
         if(m_items[i].Enabled() && m_items[i].SuitsRegime(regime))
            n++;
      return n;
     }

   //--- Whether the strategy that opened a position still suits the regime
   bool              StrategySuits(const int strategyId, const ENUM_REGIME regime)
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(m_items[i].Id() == strategyId)
            return m_items[i].SuitsRegime(regime);
      return false;
     }

   string            NameOf(const int strategyId)
     {
      for(int i = 0; i < ArraySize(m_items); i++)
         if(m_items[i].Id() == strategyId)
            return m_items[i].Name();
      return "unknown";
     }

   string            Summary()
     {
      string s = "";
      for(int i = 0; i < ArraySize(m_items); i++)
        {
         if(s != "")
            s += ", ";
         s += StringFormat("%s->%s%s", m_items[i].Name(), m_items[i].RegimesText(),
                           m_items[i].Enabled() ? "" : " (off)");
        }
      return s;
     }
  };

#endif // XS_STRATEGY_SELECTOR_MQH
//+------------------------------------------------------------------+
