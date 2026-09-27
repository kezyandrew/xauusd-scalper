//+------------------------------------------------------------------+
//|                                                RiskManager.mqh   |
//|  The single "risk personality" shared by every strategy:         |
//|  risk profile presets, stop placement rules, position sizing,    |
//|  exposure limits and the equity guard (daily loss, drawdown      |
//|  circuit breaker, equity throttling, losing-streak cool-down).   |
//+------------------------------------------------------------------+
#ifndef XS_RISK_MANAGER_MQH
#define XS_RISK_MANAGER_MQH

#include "Common.mqh"
#include "MarketData.mqh"
#include "Strategies/StrategyBase.mqh"

//--- Every risk-related number, resolved from a preset or the Custom inputs
struct SRiskProfile
  {
   string            name;
   double            riskPct;          // % of account risked per trade
   double            dailyLossPct;     // daily loss limit, % of start-of-day equity
   double            maxDDPct;         // drawdown from equity peak that trips the breaker
   double            throttleDDPct;    // drawdown at which risk is throttled
   double            throttleFactor;   // risk multiplier while throttled
   int               maxPositions;
   double            maxOpenRiskPct;   // total open risk across positions
   int               maxTradesPerDay;
   double            slAtrMult;        // base stop = ATR x this (never "tight")
   double            maxStopAtrMult;   // skip trades whose required stop is wider
   double            beTriggerR;       // move to breakeven at this profit (R multiples)
   double            beLockR;          // profit locked when moving to breakeven
   double            partialPct;       // % closed at the breakeven trigger (0 = off)
   double            trailStartR;
   double            trailAtrMult;
   double            tpR;              // default take profit (R), 0 = trail only
   int               lossStreakCount;
   double            lossStreakFactor;
   int               lossStreakPauseMin;
  };

void GetProfilePreset(const ENUM_RISK_PROFILE p, SRiskProfile &r)
  {
   switch(p)
     {
      case PROFILE_CONSERVATIVE:
         r.name = "Conservative";
         r.riskPct = 0.5;  r.dailyLossPct = 2.0; r.maxDDPct = 8.0;  r.throttleDDPct = 4.0;  r.throttleFactor = 0.5;
         r.maxPositions = 1; r.maxOpenRiskPct = 1.0; r.maxTradesPerDay = 10;
         r.slAtrMult = 2.0; r.maxStopAtrMult = 3.5;
         r.beTriggerR = 0.8; r.beLockR = 0.10; r.partialPct = 50.0;
         r.trailStartR = 1.0; r.trailAtrMult = 1.8; r.tpR = 1.8;
         r.lossStreakCount = 3; r.lossStreakFactor = 0.5; r.lossStreakPauseMin = 60;
         break;
      case PROFILE_AGGRESSIVE:
         r.name = "Aggressive";
         r.riskPct = 1.5;  r.dailyLossPct = 5.0; r.maxDDPct = 20.0; r.throttleDDPct = 10.0; r.throttleFactor = 0.6;
         r.maxPositions = 3; r.maxOpenRiskPct = 3.5; r.maxTradesPerDay = 24;
         r.slAtrMult = 1.6; r.maxStopAtrMult = 3.5;
         r.beTriggerR = 1.2; r.beLockR = 0.05; r.partialPct = 30.0;
         r.trailStartR = 1.5; r.trailAtrMult = 2.2; r.tpR = 3.0;
         r.lossStreakCount = 4; r.lossStreakFactor = 0.5; r.lossStreakPauseMin = 30;
         break;
      case PROFILE_HIGH_GROWTH:
         r.name = "HighGrowth";
         r.riskPct = 3.5;  r.dailyLossPct = 8.0; r.maxDDPct = 30.0; r.throttleDDPct = 15.0; r.throttleFactor = 0.4;
         r.maxPositions = 4; r.maxOpenRiskPct = 8.0; r.maxTradesPerDay = 36;
         r.slAtrMult = 1.5; r.maxStopAtrMult = 3.0;
         r.beTriggerR = 0.6; r.beLockR = 0.15; r.partialPct = 40.0;
         r.trailStartR = 0.9; r.trailAtrMult = 1.5; r.tpR = 1.6;
         r.lossStreakCount = 2; r.lossStreakFactor = 0.35; r.lossStreakPauseMin = 20;
         break;
      default: // PROFILE_BALANCED (Custom starts from these values too)
         r.name = "Balanced";
         r.riskPct = 1.0;  r.dailyLossPct = 3.0; r.maxDDPct = 12.0; r.throttleDDPct = 6.0;  r.throttleFactor = 0.5;
         r.maxPositions = 2; r.maxOpenRiskPct = 2.0; r.maxTradesPerDay = 18;
         r.slAtrMult = 1.8; r.maxStopAtrMult = 3.5;
         r.beTriggerR = 0.8; r.beLockR = 0.10; r.partialPct = 50.0;
         r.trailStartR = 1.0; r.trailAtrMult = 1.8; r.tpR = 1.8;
         r.lossStreakCount = 3; r.lossStreakFactor = 0.5; r.lossStreakPauseMin = 30;
         break;
     }
  }

//--- Settings that are not profile-dependent
struct SRiskConfig
  {
   ENUM_RISK_BASE    riskBase;
   double            maxLots;              // hard cap, 0 = none
   double            maxMarginUsePct;      // max % of free margin a new trade may consume
   double            minLotRiskTolerance;  // allow min lot if it risks <= target x this
   double            commissionPerLot;     // round-turn commission in account currency
   double            dailyProfitTargetPct; // stop opening new trades after +X% (0 = off)
   int               ddPauseHours;         // breaker pause; 0 = halt until manual reset
   bool              closeOnBreaker;
   bool              closeOnDailyLimit;
   bool              resetState;
   bool              requireRiskFreeToAdd;
   int               minMinutesBetweenTrades;
   //--- stop placement (anti stop-hunt)
   double            structBufferAtr;      // buffer beyond the structural anchor, ATR units
   double            minStopDistance;      // absolute floor, price units
   double            minStopSpreadMult;    // stop >= spread x this
   double            spreadBufferMult;     // extra cushion = spread x this
   double            roundStep;            // round-number grid, price units (0 = off)
   double            liquidityBufferAtr;   // keep stops this far beyond liquidity levels, ATR units
   double            maxSpreadToRisk;      // spread / stop distance ceiling
  };

struct STradePlan
  {
   ENUM_ORDER_TYPE   type;
   double            entry;
   double            sl;
   double            tp;
   double            lots;
   double            riskDist;
   double            riskMoney;
   double            riskPct;
  };

class CRiskManager
  {
private:
   string            m_symbol;
   long              m_magic;
   SRiskProfile      m_p;
   SRiskConfig       m_cfg;
   string            m_gvPrefix;

   //--- persisted state
   double            m_peakEquity;
   double            m_savedPeak;
   int               m_dayKey;
   double            m_dayStartEquity;
   bool              m_dailyHalted;
   bool              m_profitLocked;
   datetime          m_breakerUntil;
   bool              m_breakerManual;

   //--- derived from deal history
   bool              m_historyDirty;
   int               m_consecutiveLosses;
   datetime          m_lastLossTime;
   int               m_tradesToday;
   datetime          m_lastEntryTime;
   SStrategyPnL      m_pnl[XS_MAGIC_SLOTS];

   //--- last / preview sizing (dashboard + DD-room effect)
   double            m_previewLots;
   double            m_lastPlanLots;
   double            m_lastFillLots;
   double            m_lastSizeFactor;     // capped / unconstrained (1 = no DD-room cut)
   double            m_lastUnconstrained;
   double            m_lastTargetRisk;
   string            m_lastSizeNote;

   string            m_status;

   string            Gv(const string key) const { return m_gvPrefix + key; }

   double            GvGet(const string key, const double def) const
     {
      return GlobalVariableCheck(Gv(key)) ? GlobalVariableGet(Gv(key)) : def;
     }

   void              GvSet(const string key, const double value) const { GlobalVariableSet(Gv(key), value); }

   void              SaveState()
     {
      GvSet("peak", m_peakEquity);
      GvSet("day", m_dayKey);
      GvSet("dayEq", m_dayStartEquity);
      GvSet("dHalt", m_dailyHalted ? 1.0 : 0.0);
      GvSet("pLock", m_profitLocked ? 1.0 : 0.0);
      GvSet("brkUntil", (double)m_breakerUntil);
      GvSet("brkMan", m_breakerManual ? 1.0 : 0.0);
      m_savedPeak = m_peakEquity;
     }

   void              LoadState()
     {
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      m_peakEquity     = GvGet("peak", eq);
      m_dayKey         = (int)GvGet("day", 0);
      m_dayStartEquity = GvGet("dayEq", eq);
      m_dailyHalted    = (GvGet("dHalt", 0) > 0.5);
      m_profitLocked   = (GvGet("pLock", 0) > 0.5);
      m_breakerUntil   = (datetime)(long)GvGet("brkUntil", 0);
      m_breakerManual  = (GvGet("brkMan", 0) > 0.5);
      if(m_peakEquity <= 0.0)
         m_peakEquity = eq;
      m_savedPeak = m_peakEquity;
     }

   void              DeleteState()
     {
      string keys[] = {"peak", "day", "dayEq", "dHalt", "pLock", "brkUntil", "brkMan"};
      for(int i = 0; i < ArraySize(keys); i++)
         GlobalVariableDel(Gv(keys[i]));
     }

   double            RiskBase() const
     {
      double bal = AccountInfoDouble(ACCOUNT_BALANCE);
      double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      switch(m_cfg.riskBase)
        {
         case RISK_BASE_BALANCE: return bal;
         case RISK_BASE_EQUITY:  return eq;
         default:                return MathMin(bal, eq);
        }
     }

   //--- Money lost by 1.0 lot moving from entry to sl (broker-computed where possible)
   double            LossPerLot(const ENUM_ORDER_TYPE type, const double entry, const double sl) const
     {
      double profit = 0.0;
      if(OrderCalcProfit(type, m_symbol, 1.0, entry, sl, profit) && profit < 0.0)
         return -profit;
      double tickSize  = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      double tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
      if(tickValue <= 0.0)
         tickValue = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      if(tickSize <= 0.0 || tickValue <= 0.0)
         return 0.0;
      return MathAbs(entry - sl) / tickSize * tickValue;
     }

   //--- Push a stop beyond any nearby liquidity level (round numbers, swing/equal
   //--- highs-lows, Asian range, previous day...). Only ever widens the stop.
   double            AvoidLiquidity(double sl, const bool isBuy, const double atr, const double &levels[]) const
     {
      if(m_cfg.liquidityBufferAtr <= 0.0)
         return sl;
      double buffer = m_cfg.liquidityBufferAtr * atr;
      int    n      = ArraySize(levels);
      for(int pass = 0; pass < 8; pass++)
        {
         bool moved = false;
         if(m_cfg.roundStep > 0.0)
           {
            double nearest = MathRound(sl / m_cfg.roundStep) * m_cfg.roundStep;
            if(MathAbs(sl - nearest) < buffer)
              {
               sl = isBuy ? MathMin(sl, nearest - buffer) : MathMax(sl, nearest + buffer);
               moved = true;
              }
           }
         for(int i = 0; i < n; i++)
           {
            if(levels[i] <= 0.0 || MathAbs(sl - levels[i]) >= buffer)
               continue;
            double pushed = isBuy ? MathMin(sl, levels[i] - buffer) : MathMax(sl, levels[i] + buffer);
            if(pushed != sl)
              {
               sl = pushed;
               moved = true;
              }
           }
         if(!moved)
            break;
        }
      return sl;
     }

   double            DrawdownPct() const
     {
      if(m_peakEquity <= 0.0)
         return 0.0;
      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      return MathMax(0.0, (m_peakEquity - eq) / m_peakEquity * 100.0);
     }

   double            DayPnlPct() const
     {
      if(m_dayStartEquity <= 0.0)
         return 0.0;
      return (AccountInfoDouble(ACCOUNT_EQUITY) - m_dayStartEquity) / m_dayStartEquity * 100.0;
     }

   //--- Money at risk in positions whose stop is still on the losing side
   double            OpenRiskMoney() const
     {
      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      double total = 0.0;
      for(int i = 0; i < n; i++)
        {
         if(IsRiskFree(pos[i]))
            continue;
         ENUM_ORDER_TYPE t = (pos[i].type == POSITION_TYPE_BUY) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
         if(pos[i].sl <= 0.0)
           {
            total += RiskBase() * m_p.riskPct / 100.0;
            continue;
           }
         total += (LossPerLot(t, pos[i].openPrice, pos[i].sl) + m_cfg.commissionPerLot) * pos[i].volume;
        }
      return total;
     }

   double            SymbolVolumeInUse() const
     {
      double v = 0.0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         if(PositionGetTicket(i) == 0)
            continue;
         if(PositionGetString(POSITION_SYMBOL) == m_symbol)
            v += PositionGetDouble(POSITION_VOLUME);
        }
      return v;
     }

   void              RefreshHistory()
     {
      if(!m_historyDirty)
         return;
      m_historyDirty      = false;
      m_consecutiveLosses = 0;
      m_lastLossTime      = 0;
      m_tradesToday       = 0;
      m_lastEntryTime     = 0;
      for(int s = 0; s < XS_MAGIC_SLOTS; s++)
        {
         m_pnl[s].closed      = 0.0;
         m_pnl[s].closedToday = 0.0;
        }

      datetime now = TimeCurrent();
      //--- 90 days covers the dashboard closed-P/L window; streak uses the same scan
      if(!HistorySelect(now - 90 * 86400, now + 86400))
         return;

      SPositionInfo openPos[];
      int openN = CollectPositions(m_symbol, m_magic, openPos);

      datetime today = DayStart(now);
      int total = HistoryDealsTotal();
      bool streakOpen = true;
      for(int i = total - 1; i >= 0; i--)
        {
         ulong deal = HistoryDealGetTicket(i);
         if(deal == 0)
            continue;
         if(HistoryDealGetString(deal, DEAL_SYMBOL) != m_symbol)
            continue;
         long magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
         if(!IsOwnMagic(magic, m_magic))
            continue;
         int sid = (int)(magic - m_magic);
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
         datetime t = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         double net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);
         ulong posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);

         bool inOfOpen = false;
         if(entry == DEAL_ENTRY_IN)
           {
            for(int p = 0; p < openN; p++)
               if((ulong)openPos[p].identifier == posId)
                 {
                  inOfOpen = true;
                  break;
                 }
            if(t >= today)
               m_tradesToday++;
            if(t > m_lastEntryTime)
               m_lastEntryTime = t;
           }

         //--- Realized P/L: every deal except the opening fill of a still-open position
         if(!inOfOpen && sid >= 0 && sid < XS_MAGIC_SLOTS)
           {
            m_pnl[sid].closed += net;
            if(t >= today)
               m_pnl[sid].closedToday += net;
           }

         if(entry == DEAL_ENTRY_IN)
            continue;
         if(!streakOpen || (entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT))
            continue;
         if(net < 0.0)
           {
            if(m_consecutiveLosses == 0)
               m_lastLossTime = t;
            m_consecutiveLosses++;
           }
         else
            streakOpen = false;
        }
     }

   //--- Peak-equity remaining room in account currency, before the reserve haircut
   double            RemainingDdMoneyRaw() const
     {
      if(m_peakEquity <= 0.0)
         return 0.0;
      return m_peakEquity * MathMax(0.0, m_p.maxDDPct - DrawdownPct()) / 100.0;
     }

   //--- Shrink a risk-money target so one full SL, and N concurrent full SLs,
   //--- cannot spend the remaining peak-to-floor equity-DD budget.
   double            CapRiskToDdRoom(const double unconstrained, string &note) const
     {
      const double reserve = 0.10; // keep 10% of remaining room unused (slippage / gap)
      double room     = RemainingDdMoneyRaw();
      double reserved = room * (1.0 - reserve);
      double openRisk = OpenRiskMoney();
      double leftover = reserved - openRisk;
      if(leftover <= 0.0)
        {
         note = "no remaining equity-DD room";
         return 0.0;
        }

      SPositionInfo pos[];
      int openN = CollectPositions(m_symbol, m_magic, pos);
      //--- N is the profile max (not the throttled-to-1 value) so a throttle
      //--- cannot loosen the concurrent-SL cap and accidentally raise size.
      int n     = MathMax(1, m_p.maxPositions);
      int slots = MathMax(1, n - openN);

      double cap = leftover;                 // one SL must not blow leftover
      double capN = reserved / n;            // N concurrent SLs at this size
      double capS = leftover / slots;        // remaining slots share leftover
      if(capN < cap)
         cap = capN;
      if(capS < cap)
         cap = capS;

      if(unconstrained <= cap)
        {
         note = StringFormat("full risk (room %.2f%% $%.0f, %d-pos cap $%.0f)",
                             MathMax(0.0, m_p.maxDDPct - DrawdownPct()), room, n, capN);
         return unconstrained;
        }
      note = StringFormat("DD-room %.2fx  room %.2f%% $%.0f  leftover $%.0f / %d slots",
                          (unconstrained > 0.0 ? cap / unconstrained : 0.0),
                          MathMax(0.0, m_p.maxDDPct - DrawdownPct()), room, leftover, slots);
      return cap;
     }

public:
                     CRiskManager() : m_magic(0), m_peakEquity(0), m_savedPeak(0), m_dayKey(0), m_dayStartEquity(0),
                     m_dailyHalted(false), m_profitLocked(false), m_breakerUntil(0), m_breakerManual(false),
                     m_historyDirty(true), m_consecutiveLosses(0), m_lastLossTime(0), m_tradesToday(0),
                     m_lastEntryTime(0), m_previewLots(0), m_lastPlanLots(0), m_lastFillLots(0),
                     m_lastSizeFactor(1.0), m_lastUnconstrained(0), m_lastTargetRisk(0) {}

   bool              Init(const string symbol, const long magic, const SRiskProfile &profile, const SRiskConfig &cfg)
     {
      m_symbol   = symbol;
      m_magic    = magic;
      m_p        = profile;
      m_cfg      = cfg;
      m_gvPrefix = StringFormat("XS_%I64d_%s_", magic, symbol);
      if(m_cfg.resetState)
        {
         DeleteState();
         Print("RiskManager: persisted risk state reset (peak equity, daily limits, circuit breaker).");
        }
      LoadState();
      m_historyDirty = true;
      m_lastSizeNote = "";
      for(int s = 0; s < XS_MAGIC_SLOTS; s++)
         ZeroMemory(m_pnl[s]);
      return true;
     }

   void              MarkHistoryDirty() { m_historyDirty = true; }
   const SRiskProfile Profile() const { return m_p; }

   //+---------------------------------------------------------------+
   //| Evaluate the equity guard. Call on every tick.                |
   //+---------------------------------------------------------------+
   ENUM_GUARD_STATE  Update()
     {
      datetime now = TimeCurrent();
      double   eq  = AccountInfoDouble(ACCOUNT_EQUITY);
      double   bal = AccountInfoDouble(ACCOUNT_BALANCE);

      int key = DayKey(now);
      if(key != m_dayKey)
        {
         m_dayKey         = key;
         m_dayStartEquity = MathMax(bal, eq);
         m_dailyHalted    = false;
         m_profitLocked   = false;
         m_historyDirty   = true;
         SaveState();
        }

      if(eq > m_peakEquity)
        {
         m_peakEquity = eq;
         if(m_peakEquity > m_savedPeak * 1.0005)
            SaveState();
        }

      //--- Drawdown circuit breaker
      if(m_breakerManual)
        {
         m_status = "PAUSED: equity DD breaker (Reset risk state to resume) - managing open trades";
         return m_cfg.closeOnBreaker ? GUARD_CLOSE_ALL : GUARD_BLOCK_NEW;
        }
      if(m_breakerUntil > 0)
        {
         if(now < m_breakerUntil)
           {
            m_status = "PAUSED: equity DD breaker until " + TimeToString(m_breakerUntil) + " - managing open trades";
            return m_cfg.closeOnBreaker ? GUARD_CLOSE_ALL : GUARD_BLOCK_NEW;
           }
         m_breakerUntil = 0;
         m_peakEquity   = eq;
         SaveState();
         PrintFormat("RiskManager: breaker pause over, peak equity re-based to %.2f", eq);
        }
      double dd = DrawdownPct();
      if(dd >= m_p.maxDDPct)
        {
         if(m_cfg.ddPauseHours > 0)
            m_breakerUntil = now + m_cfg.ddPauseHours * 3600;
         else
            m_breakerManual = true;
         SaveState();
         PrintFormat("RiskManager: MAX EQUITY DRAWDOWN %.2f%% >= %.2f%% - pause new trades (open trades still managed)",
                     dd, m_p.maxDDPct);
         m_status = "PAUSED: equity DD at limit - managing open trades only";
         return m_cfg.closeOnBreaker ? GUARD_CLOSE_ALL : GUARD_BLOCK_NEW;
        }

      //--- Daily loss limit / optional daily profit lock
      double day = DayPnlPct();
      if(!m_dailyHalted && day <= -m_p.dailyLossPct)
        {
         m_dailyHalted = true;
         SaveState();
         PrintFormat("RiskManager: daily loss %.2f%% hit limit %.2f%% - no new trades today", day, m_p.dailyLossPct);
        }
      if(m_dailyHalted)
        {
         m_status = "HALTED for today: daily loss limit";
         return m_cfg.closeOnDailyLimit ? GUARD_CLOSE_ALL : GUARD_BLOCK_NEW;
        }
      if(!m_profitLocked && m_cfg.dailyProfitTargetPct > 0.0 && day >= m_cfg.dailyProfitTargetPct)
        {
         m_profitLocked = true;
         SaveState();
         PrintFormat("RiskManager: daily profit target %.2f%% reached - no new trades today", day);
        }
      if(m_profitLocked)
        {
         m_status = "Daily profit target reached";
         return GUARD_BLOCK_NEW;
        }

      m_status = (dd >= m_p.throttleDDPct) ? StringFormat("THROTTLED (DD %.1f%%)", dd) : "OK";
      return GUARD_OK;
     }

   //--- Combined throttle from drawdown and losing streak
   double            RiskMultiplier()
     {
      RefreshHistory();
      double m = 1.0;
      if(DrawdownPct() >= m_p.throttleDDPct)
         m *= m_p.throttleFactor;
      if(m_p.lossStreakCount > 0 && m_consecutiveLosses >= m_p.lossStreakCount)
         m *= m_p.lossStreakFactor;
      return m;
     }

   int               MaxPositionsNow() const
     {
      return (DrawdownPct() >= m_p.throttleDDPct) ? 1 : m_p.maxPositions;
     }

   //+---------------------------------------------------------------+
   //| Exposure checks that do not depend on the exact stop.         |
   //+---------------------------------------------------------------+
   bool              CanOpen(const ENUM_SIGNAL dir, string &reason)
     {
      RefreshHistory();
      datetime now = TimeCurrent();
      if(m_p.maxTradesPerDay > 0 && m_tradesToday >= m_p.maxTradesPerDay)
        { reason = StringFormat("max trades per day (%d) reached", m_p.maxTradesPerDay); return false; }
      if(m_cfg.minMinutesBetweenTrades > 0 && m_lastEntryTime > 0 &&
         now - m_lastEntryTime < m_cfg.minMinutesBetweenTrades * 60)
        { reason = "spacing between trades"; return false; }
      if(m_p.lossStreakCount > 0 && m_consecutiveLosses >= m_p.lossStreakCount &&
         now < m_lastLossTime + m_p.lossStreakPauseMin * 60)
        { reason = StringFormat("cool-down after %d losses", m_consecutiveLosses); return false; }

      if(!IsHedgingAccount() && PositionSelect(m_symbol))
        { reason = "netting account: position already open on symbol"; return false; }

      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      if(n >= MaxPositionsNow())
        { reason = StringFormat("max positions (%d) open", MaxPositionsNow()); return false; }
      long wanted = (dir == SIGNAL_BUY) ? POSITION_TYPE_BUY : POSITION_TYPE_SELL;
      for(int i = 0; i < n; i++)
        {
         if(pos[i].type != wanted)
           { reason = "opposite position open"; return false; }
         if(m_cfg.requireRiskFreeToAdd && !IsRiskFree(pos[i]))
           { reason = "existing trade not yet at breakeven"; return false; }
        }

      double leftover = RemainingDdMoneyRaw() * 0.90 - OpenRiskMoney();
      if(leftover <= 0.0)
        { reason = "equity DD room exhausted - no new risk"; return false; }
      return true;
     }

   //+---------------------------------------------------------------+
   //| Build the stop, target and size for a strategy's intent. The  |
   //| same rules apply to every strategy.                           |
   //+---------------------------------------------------------------+
   bool              PlanTrade(const STradeIntent &intent, const double atr, const double avgSpread,
                               const double &avoidLevels[], STradePlan &plan, string &reason)
     {
      ZeroMemory(plan);
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
        { reason = "no quote"; return false; }
      if(atr <= 0.0)
        { reason = "ATR unavailable"; return false; }

      bool   isBuy  = (intent.signal == SIGNAL_BUY);
      double point  = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      double spread = tick.ask - tick.bid;

      //--- 1. Stop distance: ATR multiple, widened to the structural invalidation level
      double dist = atr * m_p.slAtrMult;
      if(intent.stopAnchor > 0.0)
        {
         double structDist = isBuy ? tick.bid - (intent.stopAnchor - m_cfg.structBufferAtr * atr)
                                   : (intent.stopAnchor + m_cfg.structBufferAtr * atr) - tick.ask;
         dist = MathMax(dist, structDist);
        }
      dist = MathMax(dist, MathMax(m_cfg.minStopDistance, spread * m_cfg.minStopSpreadMult));
      if(dist > atr * m_p.maxStopAtrMult)
        { reason = StringFormat("required stop %.1f x ATR exceeds cap", dist / atr); return false; }

      //--- 2. Cushion against spread widening, then keep clear of liquidity pools
      double cushion = MathMax(avgSpread, spread) * m_cfg.spreadBufferMult;
      double sl = isBuy ? tick.bid - dist - cushion : tick.ask + dist + cushion;
      sl = AvoidLiquidity(sl, isBuy, atr, avoidLevels);
      double finalDist = isBuy ? tick.bid - sl : sl - tick.ask;
      if(finalDist > atr * m_p.maxStopAtrMult + cushion)
        { reason = "stop pushed too wide by nearby liquidity levels"; return false; }

      //--- 3. Broker minimum distance
      double minDist = (double)MathMax(SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL),
                                       SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL)) * point + point;
      if(isBuy && tick.bid - sl < minDist)
         sl = tick.bid - minDist;
      if(!isBuy && sl - tick.ask < minDist)
         sl = tick.ask + minDist;
      sl = NormalizePrice(m_symbol, sl);

      double entry = isBuy ? tick.ask : tick.bid;
      double risk  = isBuy ? entry - sl : sl - entry;
      if(risk <= 0.0)
        { reason = "invalid stop"; return false; }
      if(m_cfg.maxSpreadToRisk > 0.0 && spread > m_cfg.maxSpreadToRisk * risk)
        { reason = "spread too large relative to stop"; return false; }

      //--- 4. Target: strategy's natural target (capped) or the profile's R-multiple
      double tp = 0.0;
      if(intent.targetPrice > 0.0)
        {
         double tDist = isBuy ? intent.targetPrice - entry : entry - intent.targetPrice;
         if(tDist < intent.minTargetR * risk)
           { reason = StringFormat("target only %.2fR away", tDist / risk); return false; }
         if(m_p.tpR > 0.0)
            tDist = MathMin(tDist, m_p.tpR * risk);
         tp = isBuy ? entry + tDist : entry - tDist;
        }
      else
         if(m_p.tpR > 0.0)
            tp = isBuy ? entry + m_p.tpR * risk : entry - m_p.tpR * risk;
      if(tp > 0.0)
        {
         if(isBuy && tp - tick.bid < minDist)
            tp = tick.bid + minDist;
         if(!isBuy && tick.ask - tp < minDist)
            tp = tick.ask - minDist;
         tp = NormalizePrice(m_symbol, tp);
        }

      //--- 5. Size from the actual stop distance
      plan.type     = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
      plan.entry    = entry;
      plan.sl       = sl;
      plan.tp       = tp;
      plan.riskDist = risk;
      if(!CalcLots(plan, reason, false))
         return false;

      double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      if(eq > 0.0 && m_p.maxOpenRiskPct > 0.0 &&
         (OpenRiskMoney() + plan.riskMoney) / eq * 100.0 > m_p.maxOpenRiskPct)
        { reason = "total open risk cap"; return false; }
      return true;
     }

   //--- Risk-% sizing: profile risk, streak/throttle, then remaining equity-DD room
   bool              CalcLots(STradePlan &plan, string &reason, const bool preview)
     {
      double base   = RiskBase();
      double unconstrained = base * m_p.riskPct / 100.0 * RiskMultiplier();
      string roomNote;
      double target = CapRiskToDdRoom(unconstrained, roomNote);
      double perLot = LossPerLot(plan.type, plan.entry, plan.sl) + m_cfg.commissionPerLot;
      if(base <= 0.0 || unconstrained <= 0.0 || perLot <= 0.0)
        { reason = "cannot compute risk per lot"; return false; }
      m_lastUnconstrained = unconstrained;
      m_lastTargetRisk    = target;
      m_lastSizeFactor    = (unconstrained > 0.0 && target > 0.0) ? target / unconstrained : 0.0;
      m_lastSizeNote      = roomNote;
      if(target <= 0.0)
        { reason = roomNote; return false; }

      double minLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      double maxLot = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      double lots   = FloorToVolumeStep(m_symbol, target / perLot);

      if(lots < minLot)
        {
         //--- Never inflate to min lot if that would spend more than the DD-room cap
         if(minLot * perLot <= target && minLot * perLot <= unconstrained * m_cfg.minLotRiskTolerance)
            lots = minLot;
         else
           {
            if(minLot * perLot > target)
               reason = "min lot would exceed remaining equity-DD room";
            else
               reason = StringFormat("min lot would risk %.2f%% (> target)", minLot * perLot / base * 100.0);
            return false;
           }
        }
      lots = MathMin(lots, maxLot);
      if(m_cfg.maxLots > 0.0)
         lots = MathMin(lots, m_cfg.maxLots);

      double limit = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_LIMIT);
      if(limit > 0.0)
         lots = MathMin(lots, limit - SymbolVolumeInUse());

      double margin = 0.0;
      if(OrderCalcMargin(plan.type, m_symbol, lots, plan.entry, margin) && margin > 0.0)
        {
         double allowed = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * m_cfg.maxMarginUsePct / 100.0;
         if(margin > allowed)
            lots = lots * allowed / margin;
        }
      lots = FloorToVolumeStep(m_symbol, lots);
      if(lots < minLot)
        { reason = "insufficient margin / volume for minimum lot"; return false; }

      plan.lots      = lots;
      plan.riskMoney = lots * perLot;
      plan.riskPct   = plan.riskMoney / base * 100.0;
      if(preview)
         m_previewLots = lots;
      else
         m_lastPlanLots = lots;
      return true;
     }

public:
   bool              PreviewLots(const double atr, const double avgSpread, double &lots, double &riskPct, string &reason)
     {
      lots = 0.0;
      riskPct = 0.0;
      reason = "";
      if(atr <= 0.0)
        { reason = "ATR unavailable"; return false; }
      MqlTick tick;
      if(!SymbolInfoTick(m_symbol, tick) || tick.ask <= 0.0 || tick.bid <= 0.0)
        { reason = "no quote"; return false; }

      STradePlan plan;
      ZeroMemory(plan);
      plan.type  = ORDER_TYPE_BUY;
      plan.entry = tick.ask;
      double spread = tick.ask - tick.bid;
      double dist   = atr * m_p.slAtrMult;
      dist = MathMax(dist, MathMax(m_cfg.minStopDistance, spread * m_cfg.minStopSpreadMult));
      double cushion = MathMax(avgSpread, spread) * m_cfg.spreadBufferMult;
      plan.sl = NormalizePrice(m_symbol, tick.bid - dist - cushion);
      plan.riskDist = plan.entry - plan.sl;
      if(plan.riskDist <= 0.0)
        { reason = "invalid preview stop"; return false; }
      if(!CalcLots(plan, reason, true))
         return false;
      lots    = plan.lots;
      riskPct = plan.riskPct;
      return true;
     }

   void              NoteFill(const double lots)
     {
      if(lots > 0.0)
         m_lastFillLots = lots;
     }

   void              RefreshStats()
     {
      RefreshHistory();
      RefreshOpenPnL();
     }

   void              RefreshOpenPnL()
     {
      for(int s = 0; s < XS_MAGIC_SLOTS; s++)
        {
         m_pnl[s].openPl    = 0.0;
         m_pnl[s].openLots  = 0.0;
         m_pnl[s].openCount = 0;
        }
      SPositionInfo pos[];
      int n = CollectPositions(m_symbol, m_magic, pos);
      for(int i = 0; i < n; i++)
        {
         if(!PositionSelectByTicket(pos[i].ticket))
            continue;
         int id = pos[i].strategyId;
         if(id < 0 || id >= XS_MAGIC_SLOTS)
            continue;
         m_pnl[id].openPl    += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         m_pnl[id].openLots  += pos[i].volume;
         m_pnl[id].openCount += 1;
        }
     }

   void              GetStrategyPnL(const int id, SStrategyPnL &out) const
     {
      if(id >= 0 && id < XS_MAGIC_SLOTS)
         out = m_pnl[id];
      else
         ZeroMemory(out);
     }

   //--- Dashboard helpers
   string            Status() const { return m_status; }
   double            DrawdownNow() const { return DrawdownPct(); }
   double            DayPnlNow() const { return DayPnlPct(); }
   double            PeakEquity() const { return m_peakEquity; }
   double            MaxDrawdownPct() const { return m_p.maxDDPct; }
   double            RemainingDdPct() const { return MathMax(0.0, m_p.maxDDPct - DrawdownPct()); }
   double            RemainingDdMoney() const { return RemainingDdMoneyRaw(); }
   double            OpenRiskNow() const { return OpenRiskMoney(); }
   double            DayStartEquity() const { return m_dayStartEquity; }
   int               ConsecutiveLosses() const { return m_consecutiveLosses; }
   int               TradesToday() const { return m_tradesToday; }
   double            PreviewLotsNow() const { return m_previewLots; }
   double            LastPlanLots() const { return m_lastPlanLots; }
   double            LastFillLots() const { return m_lastFillLots; }
   double            LastSizeFactor() const { return m_lastSizeFactor; }
   double            LastTargetRisk() const { return m_lastTargetRisk; }
   double            LastUnconstrainedRisk() const { return m_lastUnconstrained; }
   string            SizeNote() const { return m_lastSizeNote; }
  };

#endif // XS_RISK_MANAGER_MQH
//+------------------------------------------------------------------+
