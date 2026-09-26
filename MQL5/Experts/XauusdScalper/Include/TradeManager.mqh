//+------------------------------------------------------------------+
//|                                               TradeManager.mqh   |
//|  Order execution and the shared exit rules applied to every      |
//|  position regardless of the strategy that opened it: breakeven   |
//|  (+ optional partial close), ATR trailing, stale-trade exit and   |
//|  regime-change handling.                                         |
//+------------------------------------------------------------------+
#ifndef XS_TRADE_MANAGER_MQH
#define XS_TRADE_MANAGER_MQH

#include <Trade/Trade.mqh>
#include "Common.mqh"
#include "RiskManager.mqh"

struct STradeConfig
  {
   ENUM_TIMEFRAMES   tf;
   int               slippagePoints;
   int               maxHoldBars;      // close trades still at risk after this many bars (0 = off)
   ENUM_REGIME_EXIT  regimeExit;
   double            protectMinR;      // PROTECT: lock breakeven once profit >= this many R
   double            trailStepAtr;     // minimum stop improvement per modification, ATR units
  };

//--- Per-position facts recovered from history (survive EA restarts)
struct SPositionMeta
  {
   ulong             ticket;
   double            initialRisk;     // |open - initial SL|
   double            initialVolume;
  };

class CTradeManager
  {
private:
   CTrade            m_trade;
   string            m_symbol;
   long              m_magic;
   SRiskProfile      m_p;
   STradeConfig      m_cfg;
   SPositionMeta     m_meta[];

   bool              IsRetryable(const uint rc) const
     {
      return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED ||
              rc == TRADE_RETCODE_PRICE_OFF || rc == TRADE_RETCODE_TIMEOUT || rc == TRADE_RETCODE_CONNECTION);
     }

   bool              IsDone(const uint rc) const
     {
      return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_DONE_PARTIAL || rc == TRADE_RETCODE_PLACED);
     }

   double            MinStopDistance() const
     {
      double point = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      return (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL) * point + point;
     }

   double            FreezeDistance() const
     {
      return (double)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL) * SymbolInfoDouble(m_symbol, SYMBOL_POINT);
     }

   //--- Initial risk and volume of a position, cached; read from the opening order in history
   bool              GetMeta(const SPositionInfo &p, const double fallbackRisk, SPositionMeta &out)
     {
      for(int i = 0; i < ArraySize(m_meta); i++)
         if(m_meta[i].ticket == p.ticket)
           {
            out = m_meta[i];
            return true;
           }

      out.ticket        = p.ticket;
      out.initialRisk   = 0.0;
      out.initialVolume = p.volume;
      ulong orderTicket = (ulong)p.identifier;
      if(HistoryOrderSelect(orderTicket))
        {
         double sl = HistoryOrderGetDouble(orderTicket, ORDER_SL);
         if(sl > 0.0)
            out.initialRisk = MathAbs(p.openPrice - sl);
         double vol = HistoryOrderGetDouble(orderTicket, ORDER_VOLUME_INITIAL);
         if(vol > 0.0)
            out.initialVolume = vol;
        }
      if(out.initialRisk <= 0.0 && p.sl > 0.0 && !IsRiskFree(p))
         out.initialRisk = MathAbs(p.openPrice - p.sl);
      if(out.initialRisk <= 0.0)
        {
         out.initialRisk = fallbackRisk;
         return true; // not cached: try history again next time
        }

      if(ArraySize(m_meta) > 64)
         PruneMeta();
      int n = ArraySize(m_meta);
      ArrayResize(m_meta, n + 1);
      m_meta[n] = out;
      return true;
     }

   void              PruneMeta()
     {
      SPositionMeta keep[];
      for(int i = 0; i < ArraySize(m_meta); i++)
         if(PositionSelectByTicket(m_meta[i].ticket))
           {
            int n = ArraySize(keep);
            ArrayResize(keep, n + 1);
            keep[n] = m_meta[i];
           }
      ArrayFree(m_meta);
      ArrayCopy(m_meta, keep);
     }

   //--- Move the stop only in the protective direction, respecting stops/freeze levels
   bool              ImproveStop(const SPositionInfo &p, double newSl, const string why)
     {
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick))
         return false;
      bool   isBuy   = (p.type == POSITION_TYPE_BUY);
      double minDist = MinStopDistance();
      double freeze  = FreezeDistance();
      double price   = isBuy ? tick.bid : tick.ask;

      if(freeze > 0.0 && p.sl > 0.0 && MathAbs(price - p.sl) <= freeze)
         return false;
      if(isBuy && newSl > price - minDist)
         newSl = price - minDist;
      if(!isBuy && newSl < price + minDist)
         newSl = price + minDist;
      newSl = NormalizePrice(m_symbol, newSl);

      bool improves = isBuy ? (p.sl <= 0.0 || newSl > p.sl) : (p.sl <= 0.0 || newSl < p.sl);
      if(!improves)
         return false;
      if(!m_trade.PositionModify(p.ticket, newSl, p.tp) || !IsDone(m_trade.ResultRetcode()))
        {
         PrintFormat("TradeManager: modify #%I64u (%s) failed: %s", p.ticket, why, m_trade.ResultRetcodeDescription());
         return false;
        }
      return true;
     }

   bool              ClosePosition(const ulong ticket, const string why)
     {
      if(m_trade.PositionClose(ticket, (ulong)m_cfg.slippagePoints) && IsDone(m_trade.ResultRetcode()))
        {
         PrintFormat("TradeManager: closed #%I64u (%s)", ticket, why);
         return true;
        }
      PrintFormat("TradeManager: close #%I64u (%s) failed: %s", ticket, why, m_trade.ResultRetcodeDescription());
      return false;
     }

   bool              MoveToBreakeven(const SPositionInfo &p, const double risk)
     {
      bool isBuy = (p.type == POSITION_TYPE_BUY);
      double target = isBuy ? p.openPrice + m_p.beLockR * risk : p.openPrice - m_p.beLockR * risk;
      return ImproveStop(p, target, "breakeven");
     }

public:
                     CTradeManager() : m_magic(0) {}

   bool              Init(const string symbol, const long magic, const SRiskProfile &profile, const STradeConfig &cfg)
     {
      m_symbol = symbol;
      m_magic  = magic;
      m_p      = profile;
      m_cfg    = cfg;
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)cfg.slippagePoints);
      m_trade.SetTypeFillingBySymbol(symbol);
      m_trade.SetMarginMode();
      m_trade.LogLevel(LOG_LEVEL_ERRORS);
      return true;
     }

   //+---------------------------------------------------------------+
   //| Send a market order for a plan built by the risk manager.     |
   //+---------------------------------------------------------------+
   bool              Open(const STradePlan &plan, const int strategyId, const string comment)
     {
      m_trade.SetExpertMagicNumber((ulong)(m_magic + strategyId));
      bool isBuy = (plan.type == ORDER_TYPE_BUY);
      for(int attempt = 0; attempt < 3; attempt++)
        {
         MqlTick tick;
         if(!SymbolInfoTick(m_symbol, tick))
            return false;
         double price = isBuy ? tick.ask : tick.bid;
         double risk  = isBuy ? price - plan.sl : plan.sl - price;
         if(risk <= 0.0 || risk > plan.riskDist * 1.15)
           {
            PrintFormat("TradeManager: price moved too far before entry (risk %.5f vs planned %.5f)", risk, plan.riskDist);
            return false;
           }

         bool sent = isBuy ? m_trade.Buy(plan.lots, m_symbol, price, plan.sl, plan.tp, comment)
                           : m_trade.Sell(plan.lots, m_symbol, price, plan.sl, plan.tp, comment);
         uint rc = m_trade.ResultRetcode();
         if(sent && IsDone(rc))
           {
            PrintFormat("TradeManager: %s %.2f lots @ %.5f SL %.5f TP %.5f risk %.2f (%.2f%%) [%s]",
                        isBuy ? "BUY" : "SELL", plan.lots, m_trade.ResultPrice(), plan.sl, plan.tp,
                        plan.riskMoney, plan.riskPct, comment);
            return true;
           }

         //--- Some execution models reject stops on the entry order: open, then attach
         //--- them immediately, and never leave a position without a stop.
         if(rc == TRADE_RETCODE_INVALID_STOPS)
           {
            sent = isBuy ? m_trade.Buy(plan.lots, m_symbol, price, 0.0, 0.0, comment)
                         : m_trade.Sell(plan.lots, m_symbol, price, 0.0, 0.0, comment);
            if(!sent || !IsDone(m_trade.ResultRetcode()))
               break;
            ulong deal = m_trade.ResultDeal();
            ulong ticket = 0;
            if(deal > 0 && HistoryDealSelect(deal))
               ticket = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
            if(ticket > 0 && m_trade.PositionModify(ticket, plan.sl, plan.tp) && IsDone(m_trade.ResultRetcode()))
               return true;
            Print("TradeManager: could not attach stop after entry - closing position for safety");
            if(ticket > 0)
               ClosePosition(ticket, "no stop attached");
            return false;
           }
         if(!IsRetryable(rc))
            break;
         Sleep(250);
        }
      PrintFormat("TradeManager: order failed: %s (%u)", m_trade.ResultRetcodeDescription(), m_trade.ResultRetcode());
      return false;
     }

   //+---------------------------------------------------------------+
   //| Shared management for all open positions. suits[id] tells     |
   //| whether strategy id still suits the confirmed regime.         |
   //+---------------------------------------------------------------+
   void              Manage(const double atr, const bool &suits[])
     {
      if(atr <= 0.0)
         return;
      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      double minLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);

      for(int i = 0; i < n; i++)
        {
         SPositionInfo p = pos[i];
         SPositionMeta meta;
         GetMeta(p, atr * m_p.slAtrMult, meta);
         double r = meta.initialRisk;

         MqlTick tick;
         if(!SymbolInfoTick(m_symbol, tick) || r <= 0.0)
            continue;
         bool   isBuy    = (p.type == POSITION_TYPE_BUY);
         double profit   = isBuy ? tick.bid - p.openPrice : p.openPrice - tick.ask;
         double profitR  = profit / r;
         bool   riskFree = IsRiskFree(p);
         int    barsHeld = iBarShift(m_symbol, m_cfg.tf, p.openTime, false);
         bool   suitsNow = (p.strategyId >= 0 && p.strategyId < ArraySize(suits)) ? suits[p.strategyId] : false;

         //--- 1. Regime no longer suits the strategy that opened the trade
         if(!suitsNow && m_cfg.regimeExit == REGIME_EXIT_CLOSE)
           {
            ClosePosition(p.ticket, "regime changed");
            continue;
           }
         if(!suitsNow && m_cfg.regimeExit == REGIME_EXIT_PROTECT && !riskFree)
           {
            if(profitR >= m_cfg.protectMinR)
              {
               if(MoveToBreakeven(p, r) && PositionSelectByTicket(p.ticket))
                 {
                  p.sl = PositionGetDouble(POSITION_SL);
                  riskFree = IsRiskFree(p);
                 }
              }
            else
               if(profitR < 0.0 && m_cfg.maxHoldBars > 0 && barsHeld >= m_cfg.maxHoldBars / 2)
                 {
                  ClosePosition(p.ticket, "regime changed, trade not working");
                  continue;
                 }
           }

         //--- 2. Breakeven (+ optional partial close) at the shared R trigger
         if(!riskFree && m_p.beTriggerR > 0.0 && profitR >= m_p.beTriggerR)
           {
            bool partialDone = (p.volume < meta.initialVolume - 1e-8);
            if(m_p.partialPct > 0.0 && !partialDone)
              {
               double vol = FloorToVolumeStep(m_symbol, p.volume * m_p.partialPct / 100.0);
               if(vol >= minLot && p.volume - vol >= minLot - 1e-8)
                 {
                  if(m_trade.PositionClosePartial(p.ticket, vol, (ulong)m_cfg.slippagePoints) && IsDone(m_trade.ResultRetcode()))
                     PrintFormat("TradeManager: partial close %.2f of #%I64u at %.2fR", vol, p.ticket, profitR);
                 }
              }
            if(PositionSelectByTicket(p.ticket))
              {
               p.volume = PositionGetDouble(POSITION_VOLUME);
               p.sl     = PositionGetDouble(POSITION_SL);
              }
            if(MoveToBreakeven(p, r) && PositionSelectByTicket(p.ticket))
              {
               p.sl = PositionGetDouble(POSITION_SL);
               riskFree = IsRiskFree(p);
              }
           }

         //--- 3. ATR trailing once the trade has proven itself
         if(m_p.trailAtrMult > 0.0 && profitR >= m_p.trailStartR)
           {
            double cand = isBuy ? tick.bid - m_p.trailAtrMult * atr : tick.ask + m_p.trailAtrMult * atr;
            double step = m_cfg.trailStepAtr * atr;
            bool   locks   = isBuy ? cand > p.openPrice : cand < p.openPrice;
            bool   enough  = isBuy ? (p.sl <= 0.0 || cand >= p.sl + step) : (p.sl <= 0.0 || cand <= p.sl - step);
            if(locks && enough)
               ImproveStop(p, cand, "trailing");
           }

         //--- 4. Stale trade: still at risk after the maximum holding time
         if(m_cfg.maxHoldBars > 0 && barsHeld >= m_cfg.maxHoldBars && !riskFree)
            ClosePosition(p.ticket, StringFormat("stale after %d bars", barsHeld));
        }
     }

   int               CloseAll(const string why)
     {
      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      int closed = 0;
      for(int i = 0; i < n; i++)
         if(ClosePosition(pos[i].ticket, why))
            closed++;
      return closed;
     }

   //--- Close only positions that are currently losing money
   int               CloseLosers(const string why)
     {
      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      int closed = 0;
      for(int i = 0; i < n; i++)
        {
         if(!PositionSelectByTicket(pos[i].ticket))
            continue;
         double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(pl < 0.0 && ClosePosition(pos[i].ticket, why))
            closed++;
        }
      return closed;
     }

   int               OpenCount() const
     {
      SPositionInfo pos[];
      return CollectPositions(m_symbol, m_magic, pos);
     }
  };

#endif // XS_TRADE_MANAGER_MQH
//+------------------------------------------------------------------+
