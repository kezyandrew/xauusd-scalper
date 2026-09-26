//+------------------------------------------------------------------+
//|                                             RegimeDetector.mqh   |
//|  Classifies the market into a regime once per closed bar and     |
//|  applies hysteresis so the active strategy does not flip-flop.   |
//+------------------------------------------------------------------+
#ifndef XS_REGIME_DETECTOR_MQH
#define XS_REGIME_DETECTOR_MQH

#include "Common.mqh"
#include "MarketData.mqh"

struct SRegimeConfig
  {
   //--- Stand-aside regimes
   double            chaoticAtrPct;       // ATR percentile at/above which the market is disorderly
   double            chaoticBarAtr;       // single bar range >= N x ATR also counts as chaotic
   double            quietAtrPct;         // ATR percentile at/below which the market is too quiet
   double            quietActivity;       // activity ratio at/below which the market is too quiet
   //--- Breakout (volatility expansion)
   double            breakoutAtrPct;      // ATR percentile needed to enter
   double            breakoutExpansion;   // Bollinger width expansion ratio needed to enter
   double            breakoutVolRatio;    // last-bar tick-volume surge needed to enter
   //--- Trend
   double            trendAdxEnter;
   double            trendAdxExit;        // lower threshold to stay in trend (hysteresis)
   double            trendSlopeAtr;       // |slow EMA slope| in ATR units needed to enter
   bool              trendNeedsHtf;       // require higher-timeframe agreement
   //--- Range
   double            rangeAdxEnter;       // ADX must be below this to enter
   double            rangeAdxExit;        // higher threshold to stay in range (hysteresis)
   double            rangeBbwPctMin;      // Bollinger-width percentile band that qualifies
   double            rangeBbwPctMax;
   //--- Hysteresis
   int               confirmBars;         // candidate must persist this many bars
   int               minHoldBars;         // minimum bars in a tradeable regime before switching
  };

class CRegimeDetector
  {
private:
   SRegimeConfig     m_cfg;
   ENUM_REGIME       m_regime;
   int               m_dir;
   ENUM_REGIME       m_candidate;
   int               m_candidateDir;
   int               m_candidateCount;
   int               m_barsInRegime;
   bool              m_changed;
   ENUM_REGIME       m_raw;

   int               Sign(const double v) const { return (v > 0.0) ? 1 : ((v < 0.0) ? -1 : 0); }

   bool              IsStandAside(const ENUM_REGIME r) const
     {
      //--- QUIET is tradeable for modules that opt in (mean-rev / sweeps).
      //--- Only NONE and CHAOTIC force a full stand-aside.
      return (r == REGIME_NONE || r == REGIME_CHAOTIC);
     }

   //--- Single-bar classification. "sticky" thresholds apply to the regime we are already in.
   ENUM_REGIME       Classify(const SMarketContext &c, int &dir) const
     {
      dir = 0;
      double range0 = c.high[0] - c.low[0];
      if(c.atrPct >= m_cfg.chaoticAtrPct || (c.atr > 0.0 && range0 >= m_cfg.chaoticBarAtr * c.atr))
         return REGIME_CHAOTIC;

      //--- Quiet only when BOTH volatility and participation are dead. Using OR
      //--- parked the EA for weeks whenever one metric dipped (false "dead market").
      if(c.atrPct <= m_cfg.quietAtrPct && c.activityRatio <= m_cfg.quietActivity)
         return REGIME_QUIET;

      //--- Breakout: expanding volatility with participation
      bool inBreakout = (m_regime == REGIME_BREAKOUT);
      double needPct  = inBreakout ? m_cfg.breakoutAtrPct - 10.0 : m_cfg.breakoutAtrPct;
      double needExp  = inBreakout ? 1.0 : m_cfg.breakoutExpansion;
      bool   volOk    = inBreakout ? (c.activityRatio >= 1.0) : (c.volRatio >= m_cfg.breakoutVolRatio);
      if(c.atrPct >= needPct && c.bbExpansion >= needExp && volOk)
        {
         dir = Sign(c.close[0] - c.bbMid[0]);
         if(dir != 0)
            return REGIME_BREAKOUT;
        }

      //--- Trend: ADX strength + slow-EMA slope + EMA stack (+ optional HTF agreement)
      bool   inTrend   = (m_regime == REGIME_TREND);
      double needAdx   = inTrend ? m_cfg.trendAdxExit : m_cfg.trendAdxEnter;
      double needSlope = inTrend ? m_cfg.trendSlopeAtr * 0.6 : m_cfg.trendSlopeAtr;
      int    slopeDir  = Sign(c.slopeAtr);
      int    stackDir  = (c.emaFast[0] > c.emaSlow[0]) ? 1 : -1;
      bool   htfOk     = !m_cfg.trendNeedsHtf || (c.htfBias == slopeDir);
      if(c.adx >= needAdx && MathAbs(c.slopeAtr) >= needSlope && slopeDir == stackDir && htfOk)
        {
         dir = slopeDir;
         return REGIME_TREND;
        }

      //--- Range: weak ADX, flat slope, bands neither squeezed shut nor blown out
      bool   inRange = (m_regime == REGIME_RANGE);
      double maxAdx  = inRange ? m_cfg.rangeAdxExit : m_cfg.rangeAdxEnter;
      if(c.adx <= maxAdx && MathAbs(c.slopeAtr) < m_cfg.trendSlopeAtr &&
         c.bbWidthPct >= m_cfg.rangeBbwPctMin && c.bbWidthPct <= m_cfg.rangeBbwPctMax)
         return REGIME_RANGE;

      //--- Soft fallback: mild ADX with no clearer label -> RANGE so fades/sweeps
      //--- can still fire instead of parking in NONE for long stretches.
      if(c.adx <= m_cfg.rangeAdxExit)
         return REGIME_RANGE;

      return REGIME_NONE;
     }

public:
                     CRegimeDetector() : m_regime(REGIME_NONE), m_dir(0), m_candidate(REGIME_NONE), m_candidateDir(0),
                     m_candidateCount(0), m_barsInRegime(0), m_changed(false), m_raw(REGIME_NONE) {}

   void              Init(const SRegimeConfig &cfg)
     {
      m_cfg = cfg;
      m_regime = REGIME_NONE;
      m_dir = 0;
      m_candidate = REGIME_NONE;
      m_candidateDir = 0;
      m_candidateCount = 0;
      m_barsInRegime = 0;
     }

   //+---------------------------------------------------------------+
   //| Call once per closed bar. Returns true if the confirmed       |
   //| regime (or its direction) changed on this bar.                |
   //+---------------------------------------------------------------+
   bool              Update(const SMarketContext &c)
     {
      m_changed = false;
      int rawDir = 0;
      m_raw = Classify(c, rawDir);
      m_barsInRegime++;

      if(m_raw == m_regime && rawDir == m_dir)
        {
         m_candidate      = m_raw;
         m_candidateDir   = rawDir;
         m_candidateCount = 0;
         return false;
        }

      if(m_raw == m_candidate && rawDir == m_candidateDir)
         m_candidateCount++;
      else
        {
         m_candidate      = m_raw;
         m_candidateDir   = rawDir;
         m_candidateCount = 1;
        }

      //--- Safety first: a chaotic market is acted on immediately, without confirmation
      bool urgent    = (m_raw == REGIME_CHAOTIC);
      bool confirmed = (m_candidateCount >= m_cfg.confirmBars);
      bool holdOk    = IsStandAside(m_regime) || (m_barsInRegime >= m_cfg.minHoldBars);
      if(urgent || (confirmed && holdOk))
        {
         m_regime         = m_raw;
         m_dir            = rawDir;
         m_barsInRegime   = 0;
         m_candidateCount = 0;
         m_changed        = true;
        }
      return m_changed;
     }

   ENUM_REGIME       Regime() const { return m_regime; }
   int               Direction() const { return m_dir; }
   ENUM_REGIME       Raw() const { return m_raw; }
   ENUM_REGIME       Candidate() const { return m_candidate; }
   int               CandidateCount() const { return m_candidateCount; }
   int               BarsInRegime() const { return m_barsInRegime; }
   bool              Changed() const { return m_changed; }
   bool              IsTradeable() const { return !IsStandAside(m_regime); }
  };

#endif // XS_REGIME_DETECTOR_MQH
//+------------------------------------------------------------------+
