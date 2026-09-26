//+------------------------------------------------------------------+
//|                                                 NewsFilter.mqh   |
//|  Blocks entries around high-impact economic releases.            |
//|  Live: MQL5 economic calendar. Strategy Tester: the calendar is  |
//|  not available, so fixed daily blackout windows stand in.        |
//+------------------------------------------------------------------+
#ifndef XS_NEWS_FILTER_MQH
#define XS_NEWS_FILTER_MQH

#include "Common.mqh"

struct SNewsConfig
  {
   bool                  useCalendar;
   string                currencies;     // comma separated, e.g. "USD"
   bool                  includeModerate;
   int                   minutesBefore;
   int                   minutesAfter;
   ENUM_MANUAL_BLACKOUT  manualMode;
   string                manualWindows;  // "HH:MM-HH:MM;..." server time, Mon-Fri
  };

class CNewsFilter
  {
private:
   SNewsConfig       m_cfg;
   STimeWindow       m_manual[];
   string            m_currencies[];
   datetime          m_events[];
   string            m_names[];
   datetime          m_lastRefresh;
   datetime          m_nextRetry;
   bool              m_isTester;
   bool              m_calendarOk;

   bool              RefreshCalendar(const datetime now)
     {
      ArrayResize(m_events, 0);
      ArrayResize(m_names, 0);
      datetime from = now - m_cfg.minutesAfter * 60 - 3600;
      datetime to   = now + 36 * 3600;
      bool anyOk = false;
      for(int c = 0; c < ArraySize(m_currencies); c++)
        {
         MqlCalendarValue values[];
         ResetLastError();
         int got = CalendarValueHistory(values, from, to, NULL, m_currencies[c]);
         if(got <= 0 && GetLastError() != 0)
            continue;
         anyOk = true;
         for(int i = 0; i < ArraySize(values); i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev))
               continue;
            bool important = (ev.importance == CALENDAR_IMPORTANCE_HIGH) ||
                             (m_cfg.includeModerate && ev.importance == CALENDAR_IMPORTANCE_MODERATE);
            if(!important)
               continue;
            int n = ArraySize(m_events);
            ArrayResize(m_events, n + 1);
            ArrayResize(m_names, n + 1);
            m_events[n] = values[i].time;
            m_names[n]  = m_currencies[c] + " " + ev.name;
           }
        }
      return anyOk;
     }

public:
                     CNewsFilter() : m_lastRefresh(0), m_nextRetry(0), m_isTester(false), m_calendarOk(false) {}

   bool              Init(const SNewsConfig &cfg)
     {
      m_cfg      = cfg;
      m_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
      if(!ParseWindows(m_cfg.manualWindows, m_manual))
        {
         Print("NewsFilter: invalid manual blackout windows '", m_cfg.manualWindows, "'");
         return false;
        }
      string parts[];
      int n = StringSplit(m_cfg.currencies, ',', parts);
      ArrayResize(m_currencies, 0);
      for(int i = 0; i < n; i++)
        {
         string cur = parts[i];
         StringTrimLeft(cur);
         StringTrimRight(cur);
         StringToUpper(cur);
         if(cur == "")
            continue;
         int k = ArraySize(m_currencies);
         ArrayResize(m_currencies, k + 1);
         m_currencies[k] = cur;
        }
      if(m_cfg.useCalendar && m_isTester)
         Print("NewsFilter: economic calendar is unavailable in the Strategy Tester - using manual blackout windows.");
      return true;
     }

   bool              ManualActive() const
     {
      if(m_cfg.manualMode == MANUAL_BLACKOUT_ALWAYS)
         return true;
      return (m_cfg.manualMode == MANUAL_BLACKOUT_TESTER_ONLY && (m_isTester || !m_calendarOk));
     }

   //+---------------------------------------------------------------+
   //| True if serverNow is inside a news blackout (from             |
   //| minutesBefore an event until minutesAfter it).                |
   //+---------------------------------------------------------------+
   bool              IsBlackout(const datetime serverNow, string &reason)
     {
      reason = "";
      int dow = DayOfWeek(serverNow);
      if(ManualActive() && dow >= 1 && dow <= 5 && MinuteInAnyWindow(MinuteOfDay(serverNow), m_manual))
        {
         reason = "news blackout window";
         return true;
        }

      if(!m_cfg.useCalendar || m_isTester || ArraySize(m_currencies) == 0)
         return false;

      if(serverNow >= m_nextRetry && (m_lastRefresh == 0 || serverNow - m_lastRefresh >= 3600))
        {
         m_calendarOk = RefreshCalendar(serverNow);
         if(m_calendarOk)
            m_lastRefresh = serverNow;
         else
            m_nextRetry = serverNow + 300;
        }

      for(int i = 0; i < ArraySize(m_events); i++)
        {
         if(serverNow >= m_events[i] - m_cfg.minutesBefore * 60 && serverNow <= m_events[i] + m_cfg.minutesAfter * 60)
           {
            reason = "news: " + m_names[i] + " @ " + TimeToString(m_events[i], TIME_MINUTES);
            return true;
           }
        }
      return false;
     }
  };

#endif // XS_NEWS_FILTER_MQH
//+------------------------------------------------------------------+
