//+------------------------------------------------------------------+
//|                                                   Dashboard.mqh  |
//|  Always-visible on-chart pane (rectangle + label objects).       |
//|  Own charcoal background so it stays readable on dark or light   |
//|  charts. Recreated on chart change; removed on deinit.           |
//+------------------------------------------------------------------+
#ifndef XS_DASHBOARD_MQH
#define XS_DASHBOARD_MQH

#include "Common.mqh"

#define XS_DASH_LINES     20
#define XS_DASH_LINE_H    16
#define XS_DASH_PAD_X     10
#define XS_DASH_PAD_Y      8
#define XS_DASH_WIDTH    392
#define XS_DASH_X          8
#define XS_DASH_Y         20

struct SDashboardSnapshot
  {
   string            symbol;
   string            timeframe;
   string            profile;
   string            regime;
   int               regimeDir;
   int               barsInRegime;
   string            rawRegime;
   string            selectedStrategy;  // priority module for the confirmed regime
   string            runningStrategy;   // strategies with open positions
   string            signalText;
   double            nextLots;
   double            lastLots;
   double            openLots;
   double            nextRiskPct;
   double            equity;
   double            balance;
   double            floating;
   double            todayPl;
   double            todayPlPct;
   double            peakEquity;
   double            ddPct;
   double            maxDdPct;
   double            roomPct;
   double            roomMoney;
   double            openRisk;
   double            sizeFactor;
   string            sizeNote;
   string            guard;
   string            status;
   SStrategyPnL      pnl[XS_MAGIC_SLOTS];
   bool              newBar;
  };

class CDashboard
  {
private:
   long              m_chart;
   string            m_prefix;
   bool              m_enabled;
   bool              m_created;
   bool              m_useComment;
   string            m_fingerprint;
   datetime          m_lastPaint;
   string            m_lineNames[XS_DASH_LINES];
   string            m_bgName;

   color             ColBg()      const { return C'22,28,38'; }
   color             ColBorder()  const { return C'70,82,102'; }
   color             ColTitle()   const { return C'214,226,242'; }
   color             ColText()    const { return C'214,220,230'; }
   color             ColDim()     const { return C'140,148,162'; }
   color             ColAccent()  const { return C'120,176,230'; }
   color             ColGood()    const { return C'86,198,128'; }
   color             ColBad()     const { return C'230,96,96'; }
   color             ColWarn()    const { return C'230,176,72'; }

   color             SignedColor(const double v) const
     {
      if(v > 0.0)
         return ColGood();
      if(v < 0.0)
         return ColBad();
      return ColDim();
     }

   string            Money(const double v, const bool signedValue) const
     {
      if(!signedValue)
         return StringFormat("%.2f", v);
      if(v > 0.0)
         return StringFormat("+%.2f", v);
      if(v < 0.0)
         return StringFormat("-%.2f", MathAbs(v));
      return "0.00";
     }

   string            DirGlyph(const int dir) const
     {
      if(dir > 0)
         return "up";
      if(dir < 0)
         return "dn";
      return "-";
     }

   string            Trunc(const string s, const int maxChars) const
     {
      if(StringLen(s) <= maxChars)
         return s;
      return StringSubstr(s, 0, maxChars - 1) + ".";
     }

   string            Fingerprint(const SDashboardSnapshot &s) const
     {
      return StringFormat("%s|%s|%s|%s|%s|%.2f|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|%s|%d|%s",
                          s.regime, s.selectedStrategy, s.runningStrategy, s.signalText, s.guard,
                          s.equity, s.floating, s.todayPl, s.ddPct,
                          s.nextLots, s.lastLots, s.openLots, s.sizeNote, s.newBar ? 1 : 0, s.status);
     }

   bool              EnsureObjects()
     {
      if(!m_enabled)
         return false;
      if(m_created && ObjectFind(m_chart, m_bgName) >= 0)
         return true;

      int height = XS_DASH_PAD_Y * 2 + XS_DASH_LINES * XS_DASH_LINE_H;
      if(!ObjectCreate(m_chart, m_bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0))
        {
         m_useComment = true;
         return false;
        }
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_XDISTANCE, XS_DASH_X);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_YDISTANCE, XS_DASH_Y);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_XSIZE, XS_DASH_WIDTH);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_YSIZE, height);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_BGCOLOR, ColBg());
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_COLOR, ColBorder());
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_BACK, false);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_ZORDER, 100);
      ObjectSetInteger(m_chart, m_bgName, OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);

      for(int i = 0; i < XS_DASH_LINES; i++)
        {
         if(ObjectFind(m_chart, m_lineNames[i]) < 0)
           {
            if(!ObjectCreate(m_chart, m_lineNames[i], OBJ_LABEL, 0, 0, 0))
              {
               m_useComment = true;
               return false;
              }
           }
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_ANCHOR, ANCHOR_LEFT_UPPER);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_XDISTANCE, XS_DASH_X + XS_DASH_PAD_X);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_YDISTANCE, XS_DASH_Y + XS_DASH_PAD_Y + i * XS_DASH_LINE_H);
         ObjectSetString(m_chart, m_lineNames[i], OBJPROP_FONT, "Arial");
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_FONTSIZE, 8);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_COLOR, ColText());
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_SELECTABLE, false);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_HIDDEN, true);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_BACK, false);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_ZORDER, 101);
         ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_TIMEFRAMES, OBJ_ALL_PERIODS);
        }
      m_created = true;
      m_useComment = false;
      return true;
     }

   void              SetLine(const int i, const string text, const color clr)
     {
      if(i < 0 || i >= XS_DASH_LINES)
         return;
      ObjectSetString(m_chart, m_lineNames[i], OBJPROP_TEXT, text);
      ObjectSetInteger(m_chart, m_lineNames[i], OBJPROP_COLOR, clr);
     }

   void              PaintComment(const SDashboardSnapshot &s)
     {
      Comment(StringFormat(
                 "XauusdScalper | %s %s | %s\n"
                 "Regime %s %s | selected %s | running %s\n"
                 "Lots next %.2f last %.2f open %.2f | %s\n"
                 "Eq %.2f  float %s  today %s (%.2f%%)\n"
                 "Equity DD %.2f%% / %.2f%%  room %.2f%%\n"
                 "%s\n%s",
                 s.symbol, s.timeframe, s.profile,
                 s.regime, DirGlyph(s.regimeDir), s.selectedStrategy, s.runningStrategy,
                 s.nextLots, s.lastLots, s.openLots, s.sizeNote,
                 s.equity, Money(s.floating, true), Money(s.todayPl, true), s.todayPlPct,
                 s.ddPct, s.maxDdPct, s.roomPct,
                 s.guard, s.status));
     }

public:
                     CDashboard() : m_chart(0), m_enabled(false), m_created(false),
                     m_useComment(false), m_lastPaint(0) {}

   bool              Init(const long chartId, const long magic, const bool enabled)
     {
      Remove();
      m_chart   = (chartId > 0 ? chartId : ChartID());
      m_prefix  = StringFormat("XS.DASH.%I64d.%I64d.", m_chart, magic);
      m_bgName  = m_prefix + "BG";
      for(int i = 0; i < XS_DASH_LINES; i++)
         m_lineNames[i] = StringFormat("%sL%02d", m_prefix, i);
      m_enabled     = enabled;
      m_created     = false;
      m_useComment  = false;
      m_fingerprint = "";
      if(!m_enabled)
         return true;
      return EnsureObjects();
     }

   void              Remove()
     {
      if(m_prefix != "")
        {
         int total = ObjectsTotal(m_chart, 0, -1);
         for(int i = total - 1; i >= 0; i--)
           {
            string name = ObjectName(m_chart, i, 0, -1);
            if(StringFind(name, m_prefix) == 0)
               ObjectDelete(m_chart, name);
           }
        }
      Comment("");
      m_created     = false;
      m_fingerprint = "";
      m_enabled     = false;
     }

   void              OnChartChange()
     {
      if(!m_enabled)
         return;
      m_created = false;
      EnsureObjects();
      m_fingerprint = ""; // force a repaint with current numbers
     }

   void              Render(const SDashboardSnapshot &s, const bool force)
     {
      if(!m_enabled)
         return;

      datetime now = TimeCurrent();
      string fp = Fingerprint(s);
      if(!force && fp == m_fingerprint && now == m_lastPaint)
         return;
      if(!force && fp == m_fingerprint && now < m_lastPaint + 1)
         return;
      m_fingerprint = fp;
      m_lastPaint   = now;

      if(!EnsureObjects() || m_useComment)
        {
         PaintComment(s);
         return;
        }

      int i = 0;
      SetLine(i++, StringFormat("XAUUSD SCALPER    %s  %s    profile %s",
                                s.symbol, s.timeframe, s.profile), ColTitle());
      SetLine(i++, "------------------------------------------------", ColBorder());

      color regimeClr = (s.regime == "QUIET" || s.regime == "CHAOTIC" || s.regime == "NONE")
                        ? ColWarn() : ColAccent();
      SetLine(i++, StringFormat("Regime     %s %s   %d bars    raw %s",
                                s.regime, DirGlyph(s.regimeDir), s.barsInRegime, s.rawRegime), regimeClr);
      SetLine(i++, StringFormat("Selected   %s", Trunc(s.selectedStrategy, 46)), ColText());
      SetLine(i++, StringFormat("Running    %s", Trunc(s.runningStrategy, 46)), ColText());
      SetLine(i++, StringFormat("Signal     %s", Trunc(s.signalText, 46)), ColDim());

      SetLine(i++, StringFormat("Lots       next %.2f (%.2f%%)   last %.2f   open %.2f",
                                s.nextLots, s.nextRiskPct, s.lastLots, s.openLots), ColText());
      color facClr = (s.sizeFactor < 0.999 ? ColWarn() : ColDim());
      SetLine(i++, StringFormat("Size       %.2fx  %s",
                                s.sizeFactor, Trunc(s.sizeNote, 40)), facClr);

      SetLine(i++, StringFormat("Account    equity %s   balance %s",
                                Money(s.equity, false), Money(s.balance, false)), ColText());
      SetLine(i++, StringFormat("P/L        float %s    today %s  (%.2f%%)",
                                Money(s.floating, true), Money(s.todayPl, true), s.todayPlPct),
                  SignedColor(s.todayPl));

      color ddClr = (s.maxDdPct > 0.0 && s.ddPct >= s.maxDdPct) ? ColBad()
                    : (s.maxDdPct > 0.0 && s.ddPct >= s.maxDdPct * 0.5) ? ColWarn() : ColText();
      SetLine(i++, StringFormat("Drawdown   %.2f%% / %.2f%% max    peak %s",
                                s.ddPct, s.maxDdPct, Money(s.peakEquity, false)), ddClr);
      SetLine(i++, StringFormat("DD room    %.2f%%  %s    open risk %s",
                                s.roomPct, Money(s.roomMoney, false), Money(s.openRisk, false)), ColDim());

      SetLine(i++, "P/L by strategy (open + closed 90d, by magic)", ColAccent());
      int ids[4];
      ids[0] = XS_STRATEGY_SWEEP_REVERSAL;
      ids[1] = XS_STRATEGY_VOL_BREAKOUT;
      ids[2] = XS_STRATEGY_TREND_PULLBACK;
      ids[3] = XS_STRATEGY_MEAN_REVERSION;
      for(int k = 0; k < 4; k++)
        {
         int id = ids[k];
         double tot = s.pnl[id].openPl + s.pnl[id].closed;
         SetLine(i++, StringFormat("  %-14s  tot %s   open %s  cl %s",
                                   StrategyIdName(id),
                                   Money(tot, true),
                                   Money(s.pnl[id].openPl, true),
                                   Money(s.pnl[id].closed, true)),
                    SignedColor(tot));
        }

      SetLine(i++, StringFormat("Guard      %s", Trunc(s.guard, 46)),
              (StringFind(s.guard, "PAUSED") >= 0 || StringFind(s.guard, "HALTED") >= 0) ? ColBad() : ColDim());
      SetLine(i++, StringFormat("Status     %s", Trunc(s.status, 46)), ColDim());
      while(i < XS_DASH_LINES)
         SetLine(i++, "", ColDim());

      ChartRedraw(m_chart);
     }
  };

#endif // XS_DASHBOARD_MQH
//+------------------------------------------------------------------+
