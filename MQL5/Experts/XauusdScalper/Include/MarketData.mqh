//+------------------------------------------------------------------+
//|                                                 MarketData.mqh   |
//|  Builds one shared market context per closed bar. Every strategy |
//|  and the regime detector read the same numbers.                  |
//+------------------------------------------------------------------+
#ifndef XS_MARKET_DATA_MQH
#define XS_MARKET_DATA_MQH

#include "Common.mqh"

#define XS_CTX_BARS 40   // closed bars exposed to strategies (index 0 = last closed bar)

struct SMarketDataConfig
  {
   ENUM_TIMEFRAMES   tf;
   int               fastEma;
   int               slowEma;
   bool              useHtf;
   ENUM_TIMEFRAMES   htf;
   int               htfEma;
   int               htfSlopeBars;
   int               atrPeriod;
   int               adxPeriod;
   int               bbPeriod;
   double            bbDeviation;
   int               rsiPeriod;
   int               pctLookback;      // bars used for ATR / Bollinger-width percentiles
   int               slopeBars;        // bars used to measure slow-EMA slope
   int               bbExpandBars;     // Bollinger width now vs N bars ago
   int               volAvgPeriod;
   int               activityLookback;
  };

struct SMarketContext
  {
   bool              valid;
   datetime          barTime;
   double            open[XS_CTX_BARS];
   double            high[XS_CTX_BARS];
   double            low[XS_CTX_BARS];
   double            close[XS_CTX_BARS];
   double            emaFast[3];
   double            emaSlow[3];
   double            bbUpper[3];
   double            bbMid[3];
   double            bbLower[3];
   double            rsi[3];
   double            atr;
   double            atrPct;          // 0..100 percentile of ATR over the lookback
   double            adx;
   double            plusDi;
   double            minusDi;
   double            bbWidth;         // (upper - lower) / middle
   double            bbWidthPct;      // 0..100 percentile of width over the lookback
   double            bbExpansion;     // width now / width bbExpandBars ago
   double            slopeAtr;        // slow-EMA change over slopeBars, in ATR units
   int               htfBias;         // +1 / -1 / 0 (0 when disabled or flat)
   double            volRatio;        // last bar tick volume / average of previous bars
   double            activityRatio;   // recent average tick volume / long baseline
  };

class CMarketData
  {
private:
   string            m_symbol;
   SMarketDataConfig m_cfg;
   int               m_hFast;
   int               m_hSlow;
   int               m_hHtf;
   int               m_hAtr;
   int               m_hAdx;
   int               m_hBands;
   int               m_hRsi;
   SMarketContext    m_ctx;

   bool              CopySeries(const int handle, const int buffer, const int count, double &out[])
     {
      ArraySetAsSeries(out, true);
      return (CopyBuffer(handle, buffer, 1, count, out) == count);
     }

   //--- Percentile rank (0..100) of values[0] among values[0..count-1]
   double            PercentileRank(const double &values[], const int count)
     {
      if(count <= 1)
         return 50.0;
      int below = 0;
      for(int i = 1; i < count; i++)
         if(values[i] <= values[0])
            below++;
      return 100.0 * below / (count - 1);
     }

   double            MeanLong(const long &arr[], const int from, const int count)
     {
      if(count <= 0)
         return 0.0;
      double sum = 0.0;
      for(int i = from; i < from + count; i++)
         sum += (double)arr[i];
      return sum / count;
     }

   void              ReleaseHandle(int &h)
     {
      if(h != INVALID_HANDLE)
         IndicatorRelease(h);
      h = INVALID_HANDLE;
     }

public:
                     CMarketData() : m_hFast(INVALID_HANDLE), m_hSlow(INVALID_HANDLE), m_hHtf(INVALID_HANDLE),
                     m_hAtr(INVALID_HANDLE), m_hAdx(INVALID_HANDLE), m_hBands(INVALID_HANDLE), m_hRsi(INVALID_HANDLE)
     {
      ZeroMemory(m_ctx);
     }

                    ~CMarketData() { Release(); }

   bool              Init(const string symbol, const SMarketDataConfig &cfg)
     {
      m_symbol = symbol;
      m_cfg    = cfg;
      m_hFast  = iMA(m_symbol, m_cfg.tf, m_cfg.fastEma, 0, MODE_EMA, PRICE_CLOSE);
      m_hSlow  = iMA(m_symbol, m_cfg.tf, m_cfg.slowEma, 0, MODE_EMA, PRICE_CLOSE);
      m_hAtr   = iATR(m_symbol, m_cfg.tf, m_cfg.atrPeriod);
      m_hAdx   = iADX(m_symbol, m_cfg.tf, m_cfg.adxPeriod);
      m_hBands = iBands(m_symbol, m_cfg.tf, m_cfg.bbPeriod, 0, m_cfg.bbDeviation, PRICE_CLOSE);
      m_hRsi   = iRSI(m_symbol, m_cfg.tf, m_cfg.rsiPeriod, PRICE_CLOSE);
      if(m_cfg.useHtf)
         m_hHtf = iMA(m_symbol, m_cfg.htf, m_cfg.htfEma, 0, MODE_EMA, PRICE_CLOSE);

      if(m_hFast == INVALID_HANDLE || m_hSlow == INVALID_HANDLE || m_hAtr == INVALID_HANDLE ||
         m_hAdx == INVALID_HANDLE || m_hBands == INVALID_HANDLE || m_hRsi == INVALID_HANDLE ||
         (m_cfg.useHtf && m_hHtf == INVALID_HANDLE))
        {
         PrintFormat("MarketData: failed to create indicator handles (error %d)", GetLastError());
         return false;
        }
      return true;
     }

   void              Release()
     {
      ReleaseHandle(m_hFast);
      ReleaseHandle(m_hSlow);
      ReleaseHandle(m_hHtf);
      ReleaseHandle(m_hAtr);
      ReleaseHandle(m_hAdx);
      ReleaseHandle(m_hBands);
      ReleaseHandle(m_hRsi);
     }

   bool              IsValid() const { return m_ctx.valid; }
   double            Atr() const { return m_ctx.valid ? m_ctx.atr : 0.0; }

   //--- Copy of the last built context
   void              Get(SMarketContext &out) const { out = m_ctx; }

   //+---------------------------------------------------------------+
   //| Rebuild the context from the last closed bar.                 |
   //+---------------------------------------------------------------+
   bool              Update(string &error)
     {
      error = "";
      int lookback = MathMax(m_cfg.pctLookback, MathMax(m_cfg.slopeBars, m_cfg.bbExpandBars) + 1);
      int volBars  = MathMax(m_cfg.volAvgPeriod + 1, m_cfg.activityLookback);

      double fast[], slow[], atr[], adx[], pdi[], mdi[], up[], mid[], lo[], rsi[];
      if(!CopySeries(m_hFast, 0, 3, fast) ||
         !CopySeries(m_hSlow, 0, m_cfg.slopeBars + 1, slow) ||
         !CopySeries(m_hAtr, 0, lookback, atr) ||
         !CopySeries(m_hAdx, 0, 1, adx) || !CopySeries(m_hAdx, 1, 1, pdi) || !CopySeries(m_hAdx, 2, 1, mdi) ||
         !CopySeries(m_hBands, 0, lookback, mid) || !CopySeries(m_hBands, 1, lookback, up) ||
         !CopySeries(m_hBands, 2, lookback, lo) ||
         !CopySeries(m_hRsi, 0, 3, rsi))
        {
         error = "indicator data not ready";
         return false;
        }

      double o[], h[], l[], c[];
      long   v[];
      ArraySetAsSeries(o, true);
      ArraySetAsSeries(h, true);
      ArraySetAsSeries(l, true);
      ArraySetAsSeries(c, true);
      ArraySetAsSeries(v, true);
      if(CopyOpen(m_symbol, m_cfg.tf, 1, XS_CTX_BARS, o) != XS_CTX_BARS ||
         CopyHigh(m_symbol, m_cfg.tf, 1, XS_CTX_BARS, h) != XS_CTX_BARS ||
         CopyLow(m_symbol, m_cfg.tf, 1, XS_CTX_BARS, l) != XS_CTX_BARS ||
         CopyClose(m_symbol, m_cfg.tf, 1, XS_CTX_BARS, c) != XS_CTX_BARS ||
         CopyTickVolume(m_symbol, m_cfg.tf, 1, volBars, v) != volBars)
        {
         error = "price history not ready";
         return false;
        }

      SMarketContext x;
      ZeroMemory(x);
      x.barTime = iTime(m_symbol, m_cfg.tf, 1);
      for(int i = 0; i < XS_CTX_BARS; i++)
        {
         x.open[i]  = o[i];
         x.high[i]  = h[i];
         x.low[i]   = l[i];
         x.close[i] = c[i];
        }
      for(int i = 0; i < 3; i++)
        {
         x.emaFast[i] = fast[i];
         x.emaSlow[i] = slow[i];
         x.bbUpper[i] = up[i];
         x.bbMid[i]   = mid[i];
         x.bbLower[i] = lo[i];
         x.rsi[i]     = rsi[i];
        }

      x.atr     = atr[0];
      x.atrPct  = PercentileRank(atr, lookback);
      x.adx     = adx[0];
      x.plusDi  = pdi[0];
      x.minusDi = mdi[0];

      double widths[];
      ArrayResize(widths, lookback);
      for(int i = 0; i < lookback; i++)
         widths[i] = (mid[i] > 0.0) ? (up[i] - lo[i]) / mid[i] : 0.0;
      x.bbWidth     = widths[0];
      x.bbWidthPct  = PercentileRank(widths, lookback);
      x.bbExpansion = (widths[m_cfg.bbExpandBars] > 0.0) ? widths[0] / widths[m_cfg.bbExpandBars] : 1.0;

      x.slopeAtr = (x.atr > 0.0) ? (slow[0] - slow[m_cfg.slopeBars]) / x.atr : 0.0;

      double volAvg = MeanLong(v, 1, m_cfg.volAvgPeriod);
      x.volRatio = (volAvg > 0.0) ? (double)v[0] / volAvg : 0.0;
      double recent   = MeanLong(v, 0, m_cfg.volAvgPeriod);
      double baseline = MeanLong(v, 0, m_cfg.activityLookback);
      x.activityRatio = (baseline > 0.0) ? recent / baseline : 0.0;

      x.htfBias = 0;
      if(m_cfg.useHtf)
        {
         double htf[], htfClose[];
         ArraySetAsSeries(htfClose, true);
         if(!CopySeries(m_hHtf, 0, m_cfg.htfSlopeBars + 1, htf) ||
            CopyClose(m_symbol, m_cfg.htf, 1, 1, htfClose) != 1)
           {
            error = "higher-timeframe data not ready";
            return false;
           }
         if(htfClose[0] > htf[0] && htf[0] > htf[m_cfg.htfSlopeBars])
            x.htfBias = 1;
         else
            if(htfClose[0] < htf[0] && htf[0] < htf[m_cfg.htfSlopeBars])
               x.htfBias = -1;
        }

      x.valid = true;
      m_ctx   = x;
      return true;
     }
  };

#endif // XS_MARKET_DATA_MQH
//+------------------------------------------------------------------+
