//+------------------------------------------------------------------+
//|                                Gold_Regime_Scalper_v10.00.mq5    |
//|        Gold Regime Scalper v10 - regime-adaptive XAUUSD scalper  |
//|                                                                  |
//|  BUILD R2 (Round 2 of 3) - TRADES in TRADE mode                  |
//|  R1: market data, market-state engine, dashboard, chart marks.   |
//|  R2: gatekeeper, risk manager, executor, three playbooks         |
//|      (Trend Pullback, Trend Breakout, Range Fade), capital       |
//|      protection, news filter, forced flatten, daily statistics.  |
//|  R3 (next): breakeven lock, runner, time stop, state exit,       |
//|      persistence across restarts, per-trade CSV.                 |
//|                                                                  |
//|  Every position is opened with a server-side stop and target.    |
//|                                                                  |
//|  Spec: docs/V10_SPEC.md                                          |
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "10.00"
#property description "Gold Regime Scalper v10 - build R2 (trading)."
#property description "Regime engine + three playbooks, server-side stops, capital protection."

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define V10_BUILD               "R2"
#define V10_TICKBUF             4096      // tick ring buffer size (power of two)
#define V10_TICKMASK            4095      // V10_TICKBUF - 1
#define V10_SPREAD_SAMPLES      300       // 5 minutes of 1-second spread samples
#define V10_SPREAD_BINS         1024      // spread histogram bins (points)
#define V10_MIN_SPREAD_SAMPLES  30        // samples needed before the median is trusted
#define V10_MAX_MARKS           1500      // max state marks kept on the chart
#define V10_PANEL_LINES         22
#define V10_STATE_COUNT         7
#define V10_RATE_WINDOW_MS      10000     // window for the ticks-per-second figure
#define V10_PB_COUNT            3         // number of playbooks
#define V10_PB_PULLBACK         0
#define V10_PB_BREAKOUT         1
#define V10_PB_FADE             2
#define V10_GUARD_MAX           50        // max InpGuardTrades
#define V10_SLIP_SAMPLES        10        // fills used for the slippage average
#define V10_TIME_RING           512       // ring size for entry / request timestamps
#define V10_MAX_POS             64        // max own positions tracked
#define V10_MAX_INTENTS         32        // remembered stop/target intents
#define V10_MAX_NEWS            64        // cached high-impact events
#define V10_CLOSE_TAGS          32        // remembered reasons for EA closes

const string V10_PREFIX = "V10_";        // prefix of every chart object created by v10

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_V10_MODE
  {
   V10_MODE_TRADE   = 0,   // TRADE (places orders)
   V10_MODE_OBSERVE = 1    // OBSERVE (signals only, no orders)
  };

enum ENUM_V10_LOTMODE
  {
   V10_LOT_FIXED = 0,      // FIXED lot
   V10_LOT_RISK  = 1       // RISK (% of equity per trade)
  };

enum ENUM_V10_STATE
  {
   V10_ST_WARMUP     = 0,
   V10_ST_TREND_UP   = 1,
   V10_ST_TREND_DOWN = 2,
   V10_ST_RANGE      = 3,
   V10_ST_UNCLEAR    = 4,
   V10_ST_DEAD       = 5,
   V10_ST_VOLATILE   = 6
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "1. General"
input ENUM_V10_MODE    InpMode                = V10_MODE_TRADE;   // Mode
input int              InpMagicBase           = 100000;           // Magic base (+1 Pullback, +2 Breakout, +3 Fade)
input string           InpComment             = "V10";            // Order comment
input int              InpLogLevel            = 1;                // Log level (0 errors, 1 events, 2 debug)
input bool             InpAllowRealAccount    = false;            // Allow TRADE mode on a real-money account

input group "2. Position size"
input ENUM_V10_LOTMODE InpLotMode             = V10_LOT_FIXED;    // Lot mode
input double           InpFixedLots           = 0.01;             // Fixed lot size
input double           InpRiskPct             = 0.20;             // RISK mode: % of equity risked per trade
input double           InpMaxLots             = 0.05;             // Max lot per trade

input group "3. Costs and spread"
input double           InpCommissionPerLotRT  = 4.00;             // Commission per 1.00 lot round trip (account ccy)
input int              InpMaxSpreadPts        = 30;               // Max spread for entries (points)
input double           InpSpreadSpikeRatio    = 1.8;              // Spread spike: spread > ratio x 5-min median

input group "4. Market-state engine"
input int              InpAtrPeriod           = 14;               // ATR period (M1 and M5)
input int              InpAtrBaseBars         = 120;              // ATR baseline window (M1 bars)
input int              InpEmaFast             = 9;                // M1 fast EMA
input int              InpEmaSlow             = 21;               // M1 slow EMA
input int              InpEmaTrendM5          = 50;               // M5 trend EMA
input int              InpSlopeBars           = 3;                // M5 bars used for the EMA slope
input double           InpSlopeMinATR         = 0.20;             // Min M5 slope for a trend (in M5 ATR)
input int              InpErBars              = 20;               // Efficiency Ratio window (M1 bars)
input double           InpErTrend             = 0.30;             // ER at or above this = trend
input double           InpErRange             = 0.22;             // ER at or below this = range
input double           InpVolSpikeRatio       = 2.2;              // ATR / baseline at or above this = VOLATILE
input double           InpShockATR            = 2.5;              // Shock: price range >= this x ATR(M1) ...
input int              InpShockWindowSec      = 20;               // ... within this many seconds
input int              InpVolatileCoolSec     = 120;              // Calm seconds needed to leave VOLATILE
input double           InpDeadAtrSpread       = 4.0;              // DEAD if ATR(M1) < this x spread
input int              InpConfirmBars         = 2;                // M1 bars a new TREND/RANGE state must hold

input group "5. Trend playbooks"
input bool             InpUsePullback         = true;             // Use Trend Pullback
input int              InpSwingWindowSec      = 180;              // Max age of the swing high/low (s)
input double           InpPullbackMinATR      = 0.35;             // Min pullback depth (ATR)
input double           InpPullbackMaxATR      = 1.50;             // Max pullback depth (ATR)
input int              InpTriggerWindowSec    = 8;                // Trigger: re-break of the last N seconds high/low
input int              InpTriggerBufferPts    = 3;                // Trigger / stop buffer (points)
input bool             InpUseBreakout         = true;             // Use Trend Breakout
input int              InpBreakoutBars        = 10;               // Breakout: M1 micro-range bars
input int              InpBreakoutBufferPts   = 5;                // Breakout buffer (points)
input double           InpBreakoutVelATR      = 0.35;             // Breakout: min move (ATR) ...
input int              InpVelWindowSec        = 10;               // ... within this many seconds
input double           InpBreakoutMaxChaseATR = 0.40;             // Breakout: max distance past the level (ATR)

input group "6. Range playbook"
input bool             InpUseFade             = true;             // Use Range Fade
input int              InpBandPeriod          = 20;               // Bollinger period (M1)
input double           InpBandDev             = 2.0;              // Bollinger deviation
input double           InpFadeRejectATR       = 0.15;             // Must come back inside the band by (ATR)
input double           InpFadeMaxVelATR       = 0.60;             // Push faster than this (ATR per velocity window) = no fade

input group "7. Targets and stops"
input double           InpTpATR               = 0.80;             // Target distance (ATR M1)
input double           InpSlATR               = 1.00;             // Stop distance (ATR M1)
input int              InpMinSlPts            = 60;               // Stop never tighter than (points)
input double           InpMinNetTP            = 0.30;             // Skip if the target nets less than (account ccy)
input double           InpMaxNetTP            = 1.50;             // Cap the target at this net (account ccy)
input double           InpMaxLossPerTrade     = 2.00;             // Hard cap: max loss per trade (account ccy)
input double           InpMinRR               = 0.60;             // Min net reward / net risk

input group "8. Exit management [active from Round 3]"
input double           InpBeTriggerFrac       = 0.50;             // Breakeven lock at this fraction of the target
input double           InpBeLockNet           = 0.05;             // Net profit locked by the breakeven stop
input bool             InpUseRunner           = true;             // Runner mode in strong trends
input double           InpRunnerMinER         = 0.45;             // Runner: min Efficiency Ratio
input double           InpRunnerLockFrac      = 0.80;             // Runner: lock at least this share of the target
input double           InpRunnerTrailATR      = 0.50;             // Runner: trailing distance (ATR)
input int              InpTimeStopSec         = 180;              // Time stop (s, 0 = off)
input bool             InpStateExit           = true;             // Close when the state turns against the trade
input int              InpModifyMinMs         = 500;              // Min ms between stop modifications
input int              InpModifyMinStepPts    = 5;                // Min stop move per modification (points)

input group "9. Aggression and pacing"
input int              InpMaxPositions        = 4;                // Max open positions (total)
input int              InpMaxPerDirection     = 3;                // Max open positions per direction
input bool             InpStackNeedsBE        = true;             // Stack only when existing trades are locked (locks from R3)
input int              InpMinSpacingPts       = 40;               // Min distance between stacked entries (points)
input int              InpCooldownWinSec      = 3;                // Re-entry delay after a win (s)
input int              InpCooldownLossSec     = 45;               // Re-entry delay after a loss (s)
input int              InpMaxTradesPerHour    = 40;               // Max new trades per hour
input int              InpMaxRequestsPerMin   = 20;               // Max trade requests per minute

input group "10. Capital protection"
input double           InpMaxOpenRisk         = 6.00;             // Max total open risk (account ccy)
input int              InpStreakPause         = 3;                // Losses in a row before a pause
input int              InpStreakPauseMin      = 10;               // Pause length (min)
input int              InpStreakHalt          = 7;                // Losses in a row = stop for the day
input double           InpDailyLossLimit      = 30.00;            // Daily loss limit, closed + floating (account ccy)
input double           InpDailyProfitLock     = 0.00;             // No new entries above this daily profit (0 = off)
input double           InpEquityKillPct       = 8.0;              // Equity kill switch: % below peak equity
input int              InpGuardTrades         = 12;               // Playbook guard: trades in the window
input double           InpGuardMinAvg         = 0.00;             // Playbook guard: min average net per trade
input int              InpGuardPauseMin       = 30;               // Playbook guard: pause length (min)
input int              InpMaxAvgSlipPts       = 25;               // Pause if avg slippage of last 10 fills exceeds (points, 0 = off)
input double           InpMinMarginLevel      = 200.0;            // Min margin level after a new entry (%)

input group "11. Sessions and news (server time)"
input string           InpTradeStart          = "01:30";          // Entries from (HH:MM)
input string           InpTradeEnd            = "23:00";          // Entries until (HH:MM)
input string           InpDailyFlatten        = "23:30";          // Daily flatten time (HH:MM)
input int              InpMondayDelayMin      = 60;               // Monday: extra delay after the start time (min)
input string           InpFridayLastEntry     = "21:00";          // Friday: last entry (HH:MM)
input string           InpFridayFlatten       = "22:45";          // Friday: flatten time (HH:MM)
input bool             InpUseNews             = true;             // News filter (MT5 calendar, live only)
input string           InpNewsCurrencies      = "USD";            // News currencies (comma separated)
input int              InpNewsBeforeMin       = 10;               // No entries before news (min)
input int              InpNewsAfterMin        = 15;               // No entries after news (min)
input bool             InpNewsFlatten         = true;             // Close open trades when a news window starts

input group "12. Execution and display"
input int              InpDeviationPts        = 20;               // Max deviation, Instant execution only (points)
input int              InpMaxRetries          = 2;                // Order retries (requote / price changed)
input int              InpMaxTickAgeMs        = 2000;             // Quotes older than this are stale (ms)
input bool             InpShowDashboard       = true;             // Show dashboard
input bool             InpDrawStates          = true;             // Draw state-change marks on the chart
input bool             InpWriteCsv            = true;             // Per-trade CSV [Round 3]

//+------------------------------------------------------------------+
//| Environment                                                      |
//+------------------------------------------------------------------+
double   g_point       = 0.0;
double   g_tickSize    = 0.0;
string   g_ccy         = "";
bool     g_isTester    = false;
bool     g_drawObjects = true;
bool     g_isHedging   = false;

//--- parsed session times (minutes after midnight, server time)
int      g_tradeStartMin    = 0;
int      g_tradeEndMin      = 0;
int      g_dailyFlattenMin  = 0;
int      g_fridayLastMin    = 0;
int      g_fridayFlattenMin = 0;

//--- indicator handles
int      g_hAtrM1   = INVALID_HANDLE;
int      g_hAtrM5   = INVALID_HANDLE;
int      g_hEmaFast = INVALID_HANDLE;
int      g_hEmaSlow = INVALID_HANDLE;
int      g_hEmaM5   = INVALID_HANDLE;
int      g_hBands   = INVALID_HANDLE;

//--- execution settings detected at start
ENUM_ORDER_TYPE_FILLING g_filling = ORDER_FILLING_FOK;
double   g_commPerLotRT   = 0.0;          // commission per 1.00 lot round trip (raised if deals show more)
int      g_stopsLevel     = 0;            // broker stops level (points)
double   g_marginPerTrade = 0.0;          // margin needed for one trade at the current lot

//+------------------------------------------------------------------+
//| Tick store: ring buffer addressed by an ever-increasing sequence |
//+------------------------------------------------------------------+
long     g_tickSeq = -1;                 // sequence number of the newest stored tick
long     g_tickMsc[V10_TICKBUF];
double   g_tickBid[V10_TICKBUF];
double   g_tickAsk[V10_TICKBUF];
MqlTick  g_last;                          // latest quote
bool     g_haveTick   = false;
bool     g_newTick    = false;            // a new tick was stored since the last Drive()
long     g_lastTickUs = 0;                // local receipt time of the last new tick (us)

int TickIdx(const long seq)
  {
   return (int)(seq & V10_TICKMASK);
  }

long TickOldestSeq()
  {
   long oldest = g_tickSeq - V10_TICKBUF + 1;
   return (oldest > 0 ? oldest : 0);
  }

//+------------------------------------------------------------------+
//| Sliding time window over the tick store.                         |
//| Monotonic deques give the bid high/low in O(1) amortised per     |
//| tick, so long windows stay cheap in real-tick backtests.         |
//+------------------------------------------------------------------+
class CTickWindow
  {
private:
   long              m_spanMs;
   long              m_maxQ[V10_TICKBUF];
   long              m_minQ[V10_TICKBUF];
   long              m_maxHead;
   long              m_maxTail;
   long              m_minHead;
   long              m_minTail;
   long              m_first;            // oldest tick sequence inside the window
   long              m_last;             // newest tick sequence added

public:
   void              Init(const long spanMs)
     {
      m_spanMs = spanMs;
      Reset();
     }

   void              Reset()
     {
      m_maxHead = 0;
      m_maxTail = 0;
      m_minHead = 0;
      m_minTail = 0;
      m_first   = -1;
      m_last    = -1;
     }

   //--- call once for every newly stored tick, in order
   void              Add(const long seq)
     {
      long newestMsc  = g_tickMsc[TickIdx(seq)];
      long oldestKept = TickOldestSeq();
      if(m_first < 0)
         m_first = seq;
      //--- expire ticks that left the window (by time or by buffer overwrite)
      while(m_first < seq && (m_first < oldestKept || g_tickMsc[TickIdx(m_first)] < newestMsc - m_spanMs))
         m_first++;
      while(m_maxTail > m_maxHead && m_maxQ[TickIdx(m_maxHead)] < m_first)
         m_maxHead++;
      while(m_minTail > m_minHead && m_minQ[TickIdx(m_minHead)] < m_first)
         m_minHead++;
      //--- push the new tick
      double b = g_tickBid[TickIdx(seq)];
      while(m_maxTail > m_maxHead && g_tickBid[TickIdx(m_maxQ[TickIdx(m_maxTail - 1)])] <= b)
         m_maxTail--;
      m_maxQ[TickIdx(m_maxTail)] = seq;
      m_maxTail++;
      while(m_minTail > m_minHead && g_tickBid[TickIdx(m_minQ[TickIdx(m_minTail - 1)])] >= b)
         m_minTail--;
      m_minQ[TickIdx(m_minTail)] = seq;
      m_minTail++;
      m_last = seq;
     }

   bool              HasData() const
     {
      return (m_last >= 0 && m_maxTail > m_maxHead && m_minTail > m_minHead);
     }

   double            Hi() const
     {
      return g_tickBid[TickIdx(m_maxQ[TickIdx(m_maxHead)])];
     }

   double            Lo() const
     {
      return g_tickBid[TickIdx(m_minQ[TickIdx(m_minHead)])];
     }

   int               Count() const
     {
      if(m_last < 0)
         return 0;
      return (int)(m_last - m_first + 1);
     }

   double            FirstBid() const
     {
      return g_tickBid[TickIdx(m_first)];
     }

   long              CoveredMs() const
     {
      if(m_last < 0)
         return 0;
      return g_tickMsc[TickIdx(m_last)] - g_tickMsc[TickIdx(m_first)];
     }
  };

CTickWindow g_wShock;                     // shock detector window
CTickWindow g_wRate;                      // ticks-per-second window
CTickWindow g_wTrig;                      // trigger window (re-break of the last N seconds)
CTickWindow g_wVel;                       // velocity window
bool        g_trigPrevOk = false;         // trigger window had data before the newest tick
double      g_trigHiPrev = 0.0;           // trigger-window high before the newest tick
double      g_trigLoPrev = 0.0;           // trigger-window low before the newest tick

//+------------------------------------------------------------------+
//| Spread statistics: 1-second samples, rolling 5-minute median     |
//+------------------------------------------------------------------+
int      g_spreadRing[V10_SPREAD_SAMPLES];
int      g_spreadHist[V10_SPREAD_BINS];
int      g_spreadHead       = -1;
int      g_spreadCount      = 0;
datetime g_lastSpreadSample = 0;
double   g_spreadMedian     = 0.0;

//+------------------------------------------------------------------+
//| Closed-bar market features                                       |
//+------------------------------------------------------------------+
struct V10Features
  {
   bool              ready;
   datetime          barTime;            // open time of the evaluated M1 bar
   double            atrPts;             // ATR(M1) in points
   double            atrBasePts;         // average ATR(M1) over InpAtrBaseBars, points
   double            atrRatio;           // atrPts / atrBasePts
   double            atrM5;              // ATR(M5), price units
   double            emaFast;            // M1 fast EMA
   double            emaSlow;            // M1 slow EMA
   double            slopeAtr;           // M5 EMA change over InpSlopeBars, in M5 ATR
   double            er;                 // signed Efficiency Ratio, -1..+1
   double            bandUp;             // M1 Bollinger upper band
   double            bandMid;            // M1 Bollinger middle band
   double            bandLo;             // M1 Bollinger lower band
   double            brkHigh;            // highest high of the last InpBreakoutBars M1 bars
   double            brkLow;             // lowest low of the last InpBreakoutBars M1 bars
  };

V10Features g_f;
string      g_dataReason = "waiting for data";

//+------------------------------------------------------------------+
//| Trade plan (stop/target in money, checked against the caps)      |
//+------------------------------------------------------------------+
struct V10Plan
  {
   bool              ok;
   string            reason;
   double            lots;
   double            slPts;
   double            tpPts;
   double            slMoney;            // loss incl. commission if the stop is hit
   double            tpNet;              // profit after commission if the target is hit
   double            rr;                 // tpNet / slMoney
   double            cap;                // max loss allowed for this trade
  };

V10Plan  g_plan;                          // preview for the trend playbooks at the current ATR
datetime g_planTime = 0;
double   g_atrMoney = 0.0;

//+------------------------------------------------------------------+
//| State engine                                                     |
//+------------------------------------------------------------------+
ENUM_V10_STATE g_state          = V10_ST_WARMUP;  // effective state used by the bot
ENUM_V10_STATE g_baseState      = V10_ST_WARMUP;  // bar-confirmed state (ignores the volatile latch)
ENUM_V10_STATE g_rawState       = V10_ST_WARMUP;  // latest single-bar classification
ENUM_V10_STATE g_pending        = V10_ST_WARMUP;  // candidate waiting for confirmation
int            g_pendingCount   = 0;              // 0 = no candidate
datetime       g_stateSince     = 0;
datetime       g_volatileUntil  = 0;
string         g_volatileReason = "";
datetime       g_lastM1Bar      = 0;
double         g_shockRangePts  = 0.0;

//+------------------------------------------------------------------+
//| Daily observation statistics                                     |
//+------------------------------------------------------------------+
int      g_dayKey       = 0;
double   g_stateSecs[V10_STATE_COUNT];
double   g_readySecs    = 0.0;
int      g_stateChanges = 0;
datetime g_lastAcct     = 0;
bool     g_readyNow     = false;          // market conditions allow entries (state, session, spread, quotes)
string   g_readyReason  = "";
bool     g_entryOpen    = false;          // market conditions AND all protection gates allow entries
string   g_entryReason  = "";

//+------------------------------------------------------------------+
//| Playbook setup trackers                                          |
//+------------------------------------------------------------------+
struct V10PbTrack                         // Trend Pullback, one per direction
  {
   bool              on;
   double            ext;                // swing extreme (high for buys, low for sells)
   datetime          extTime;
   double            counter;            // deepest pullback price since the extreme
   bool              fire;
  };

struct V10FdTrack                         // Range Fade, one per band
  {
   bool              armed;              // price is (or was) outside the band
   bool              blocked;            // the poke was too fast: treat as breakout, no fade
   double            ext;                // extreme of the poke
   double            maxVel;             // fastest push during the poke (ATR per velocity window)
   bool              fire;
  };

V10PbTrack     g_pbBuy;
V10PbTrack     g_pbSell;
V10FdTrack     g_fdBuy;                   // lower band -> buy
V10FdTrack     g_fdSell;                  // upper band -> sell
bool           g_boFireBuy  = false;
bool           g_boFireSell = false;
datetime       g_boBarBuy   = 0;          // M1 bar of the last breakout buy (one per bar)
datetime       g_boBarSell  = 0;
ENUM_V10_STATE g_trackState = V10_ST_WARMUP;

struct V10Signal
  {
   int               pb;                 // playbook index
   int               dir;                // +1 buy, -1 sell
   double            slPts;
   double            tpPts;
   string            why;
  };

//+------------------------------------------------------------------+
//| Own positions (rebuilt on every cycle)                           |
//+------------------------------------------------------------------+
struct V10Pos
  {
   ulong             ticket;
   ulong             id;                 // POSITION_IDENTIFIER (= opening order ticket)
   int               dir;
   int               pb;
   double            vol;
   double            open;
   double            sl;
   double            tp;
   double            floating;           // profit + swap - estimated exit commission
   double            risk;               // money lost if the stop is hit from here (0 when locked)
   bool              locked;             // stop at or beyond the entry price
  };

V10Pos   g_pos[V10_MAX_POS];
int      g_posCount = 0;
int      g_posBuy   = 0;
int      g_posSell  = 0;
double   g_floating = 0.0;
double   g_openRisk = 0.0;

//--- stop/target intent per position, used to re-attach a missing stop
struct V10Intent
  {
   ulong             ticket;             // position identifier
   double            slPts;
   double            tpPts;
   double            reqPrice;           // requested entry price (slippage)
   int               dir;
   int               attempts;           // stop-attach attempts
   datetime          lastTry;
   datetime          nakedSince;         // first seen without a stop (0 = has a stop)
  };

V10Intent g_intents[V10_MAX_INTENTS];
int       g_intentNext = 0;

//--- reason text for closes requested by the EA
ulong    g_closeTagTicket[V10_CLOSE_TAGS];
string   g_closeTagText[V10_CLOSE_TAGS];
int      g_closeTagNext = 0;

//+------------------------------------------------------------------+
//| Trading day, results and protection state                        |
//+------------------------------------------------------------------+
datetime g_dayStart       = 0;
double   g_realizedToday  = 0.0;          // closed money today incl. commissions (own magics)
int      g_tradesToday    = 0;
int      g_winsToday      = 0;
int      g_lossesToday    = 0;
int      g_pbTrades[V10_PB_COUNT];
double   g_pbNet[V10_PB_COUNT];

int      g_lossStreak     = 0;
datetime g_lastCloseTime  = 0;
bool     g_lastCloseWin   = true;
datetime g_pauseUntil     = 0;
string   g_pauseReason    = "";
datetime g_execPauseUntil = 0;
string   g_execPauseReason = "";
bool     g_haltDay        = false;
bool     g_flattenDay     = false;        // daily loss limit hit: keep the book flat today
string   g_haltReason     = "";
bool     g_haltKill       = false;        // equity kill switch (cleared only by a restart)
double   g_peakEquity     = 0.0;
datetime g_lastFlattenTry = 0;

datetime g_pbPauseUntil[V10_PB_COUNT];
double   g_guardBuf[V10_PB_COUNT * V10_GUARD_MAX];
int      g_guardCount[V10_PB_COUNT];
int      g_guardHead[V10_PB_COUNT];

double   g_slipBuf[V10_SLIP_SAMPLES];
int      g_slipCount = 0;
int      g_slipHead  = 0;

datetime g_entryTimes[V10_TIME_RING];
int      g_entryHead  = 0;
int      g_entryCount = 0;
datetime g_reqTimes[V10_TIME_RING];
int      g_reqHead    = 0;
int      g_reqCount   = 0;

//--- news cache
datetime g_newsTime[V10_MAX_NEWS];
string   g_newsName[V10_MAX_NEWS];
int      g_newsCount  = 0;
datetime g_newsLoaded = 0;
string   g_newsStatus = "";

//--- status texts for the dashboard
string   g_lastSignal = "-";
string   g_lastAction = "-";

//--- executor state
bool     g_tradeEnabled  = false;         // TRADE mode, hedging account, real-account interlock passed
string   g_tradeBlockMsg = "";            // why trading is locked (shown on the dashboard)
int      g_failStreak    = 0;             // consecutive failed open requests
datetime g_lastBlockLog  = 0;
datetime g_lastSkipLog   = 0;
int      g_skipsQuiet    = 0;             // skips not printed because of the throttle
int      g_noStopToday   = 0;             // positions closed today because no stop could be set
ulong    g_maxDealSeen   = 0;             // newest deal already counted (no double counting)

//+------------------------------------------------------------------+
//| Chart marks and dashboard                                        |
//+------------------------------------------------------------------+
int      g_markSeq     = 0;
int      g_markOldest  = 0;
long     g_lastPanelMs = 0;
bool     g_panelReady  = false;
string   g_panelText[V10_PANEL_LINES];
color    g_panelColor[V10_PANEL_LINES];

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void V10Log(const int level, const string msg)
  {
   if(level <= InpLogLevel)
      Print("[V10] ", msg);
  }

datetime NowServer()
  {
   if(g_isTester)
      return TimeCurrent();
   datetime t = TimeTradeServer();
   if(t <= 0)
      t = TimeCurrent();
   return t;
  }

int DayKey(const datetime t)
  {
   MqlDateTime s;
   TimeToStruct(t, s);
   return s.year * 10000 + s.mon * 100 + s.day;
  }

datetime DayStartOf(const datetime t)
  {
   long s = (long)t;
   return (datetime)(s - s % 86400);
  }

string DayKeyText(const int key)
  {
   return StringFormat("%04d.%02d.%02d", key / 10000, (key / 100) % 100, key % 100);
  }

string MinToHHMM(const int minutes)
  {
   int m = (minutes > 0 ? minutes : 0);
   return StringFormat("%02d:%02d", (m / 60) % 24, m % 60);
  }

string FormatDuration(const long seconds)
  {
   long total = (seconds > 0 ? seconds : 0);
   int  h = (int)(total / 3600);
   int  m = (int)((total % 3600) / 60);
   int  s = (int)(total % 60);
   if(h > 0)
      return StringFormat("%dh%02dm", h, m);
   if(m > 0)
      return StringFormat("%dm%02ds", m, s);
   return StringFormat("%ds", s);
  }

bool ParseHHMM(const string text, int &minutes)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   string parts[];
   ushort sep = StringGetCharacter(":", 0);
   if(StringSplit(s, sep, parts) != 2)
      return false;
   for(int p = 0; p < 2; p++)
     {
      string q = parts[p];
      StringTrimLeft(q);
      StringTrimRight(q);
      int len = StringLen(q);
      if(len < 1 || len > 2)
         return false;
      for(int i = 0; i < len; i++)
        {
         ushort c = StringGetCharacter(q, i);
         if(c < '0' || c > '9')
            return false;
        }
      parts[p] = q;
     }
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return false;
   minutes = h * 60 + m;
   return true;
  }

string FmtMoney(const double v)
  {
   return StringFormat("%s %.2f", g_ccy, v);
  }

string FmtPrice(const double p)
  {
   return DoubleToString(p, _Digits);
  }

string StateName(const ENUM_V10_STATE st)
  {
   switch(st)
     {
      case V10_ST_WARMUP:
         return "WARMUP";
      case V10_ST_TREND_UP:
         return "TREND_UP";
      case V10_ST_TREND_DOWN:
         return "TREND_DOWN";
      case V10_ST_RANGE:
         return "RANGE";
      case V10_ST_UNCLEAR:
         return "UNCLEAR";
      case V10_ST_DEAD:
         return "DEAD";
      case V10_ST_VOLATILE:
         return "VOLATILE";
     }
   return "?";
  }

string StateShort(const ENUM_V10_STATE st)
  {
   switch(st)
     {
      case V10_ST_WARMUP:
         return "WU";
      case V10_ST_TREND_UP:
         return "TU";
      case V10_ST_TREND_DOWN:
         return "TD";
      case V10_ST_RANGE:
         return "RG";
      case V10_ST_UNCLEAR:
         return "UN";
      case V10_ST_DEAD:
         return "DE";
      case V10_ST_VOLATILE:
         return "VO";
     }
   return "?";
  }

color StateColor(const ENUM_V10_STATE st)
  {
   switch(st)
     {
      case V10_ST_WARMUP:
         return clrKhaki;
      case V10_ST_TREND_UP:
         return clrLime;
      case V10_ST_TREND_DOWN:
         return clrTomato;
      case V10_ST_RANGE:
         return clrDeepSkyBlue;
      case V10_ST_UNCLEAR:
         return clrSilver;
      case V10_ST_DEAD:
         return clrGray;
      case V10_ST_VOLATILE:
         return clrOrange;
     }
   return clrSilver;
  }

bool IsTradeable(const ENUM_V10_STATE st)
  {
   return (st == V10_ST_TREND_UP || st == V10_ST_TREND_DOWN || st == V10_ST_RANGE);
  }

string PbShort(const int pb)
  {
   if(pb == V10_PB_PULLBACK)
      return "PB";
   if(pb == V10_PB_BREAKOUT)
      return "BO";
   if(pb == V10_PB_FADE)
      return "FD";
   return "??";
  }

string PbName(const int pb)
  {
   if(pb == V10_PB_PULLBACK)
      return "Pullback";
   if(pb == V10_PB_BREAKOUT)
      return "Breakout";
   if(pb == V10_PB_FADE)
      return "Fade";
   return "?";
  }

long PbMagic(const int pb)
  {
   return (long)InpMagicBase + 1 + pb;
  }

int PbOfMagic(const long magic)
  {
   long d = magic - (long)InpMagicBase - 1;
   if(d >= 0 && d < V10_PB_COUNT)
      return (int)d;
   return -1;
  }

string DirName(const int dir)
  {
   return (dir > 0 ? "BUY" : "SELL");
  }

double CurrentSpreadPts()
  {
   if(!g_haveTick || g_point <= 0.0)
      return 0.0;
   return (g_last.ask - g_last.bid) / g_point;
  }

//--- spread used for the DEAD test: the median once enough samples exist
double SpreadRef()
  {
   if(g_spreadCount >= V10_MIN_SPREAD_SAMPLES && g_spreadMedian > 0.0)
      return g_spreadMedian;
   return CurrentSpreadPts();
  }

//--- round a price to the symbol tick size
double NormPrice(const double price)
  {
   if(g_tickSize > 0.0)
      return NormalizeDouble(MathRound(price / g_tickSize) * g_tickSize, _Digits);
   return NormalizeDouble(price, _Digits);
  }

//+------------------------------------------------------------------+
//| Money helpers                                                    |
//+------------------------------------------------------------------+
//--- value in account currency (positive) of a move of 'pts' points for 'lots'
double PointsToMoney(const double pts, const double lots)
  {
   if(pts <= 0.0 || lots <= 0.0)
      return 0.0;
   double price = (g_haveTick ? g_last.ask : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
   if(price > 0.0)
     {
      double profit = 0.0;
      if(OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, lots, price, price + pts * g_point, profit) && profit > 0.0)
         return profit;
     }
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return pts * g_point / tickSize * tickValue * lots;
  }

int LotDigits(const double step)
  {
   int    d = 0;
   double s = step;
   while(s < 0.999999 && d < 8)
     {
      s *= 10.0;
      d++;
     }
   return d;
  }

//--- round a lot size DOWN to the broker step and cap it (never rounds up to the minimum)
double NormalizeLotsDown(const double lots)
  {
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(vstep <= 0.0)
      vstep = 0.01;
   double v = MathMin(lots, InpMaxLots);
   if(vmax > 0.0)
      v = MathMin(v, vmax);
   v = MathFloor(v / vstep + 1e-9) * vstep;
   return NormalizeDouble(v, LotDigits(vstep));
  }

void ResetPlan(V10Plan &p)
  {
   p.ok      = false;
   p.reason  = "";
   p.lots    = 0.0;
   p.slPts   = 0.0;
   p.tpPts   = 0.0;
   p.slMoney = 0.0;
   p.tpNet   = 0.0;
   p.rr      = 0.0;
   p.cap     = InpMaxLossPerTrade;
  }

//--- size a trade and check it against the money caps
bool BuildPlan(const double slPtsIn, const double tpPtsIn, V10Plan &p)
  {
   ResetPlan(p);
   p.slPts = MathMax((double)InpMinSlPts, slPtsIn);
   p.tpPts = tpPtsIn;
   if(p.tpPts <= 0.0)
     {
      p.reason = "no target distance";
      return false;
     }
   if(InpLotMode == V10_LOT_RISK)
     {
      p.cap = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
      double perLot = PointsToMoney(p.slPts, 1.0) + g_commPerLotRT;
      if(perLot <= 0.0)
        {
         p.reason = "no tick value";
         return false;
        }
      p.lots = NormalizeLotsDown(p.cap / perLot);
     }
   else
      p.lots = NormalizeLotsDown(InpFixedLots);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(p.lots <= 0.0 || p.lots < vmin - 1e-9)
     {
      p.reason = "lot below broker minimum";
      return false;
     }
   double comm    = g_commPerLotRT * p.lots;
   double tpGross = PointsToMoney(p.tpPts, p.lots);
   p.slMoney = PointsToMoney(p.slPts, p.lots) + comm;
   p.tpNet   = tpGross - comm;
   if(p.tpNet > InpMaxNetTP && tpGross > 0.0)
     {
      double perPt = tpGross / p.tpPts;
      p.tpPts = (InpMaxNetTP + comm) / perPt;
      p.tpNet = InpMaxNetTP;
     }
   p.rr = (p.slMoney > 0.0 ? p.tpNet / p.slMoney : 0.0);
   if(p.slMoney > p.cap + 1e-9)
     {
      p.reason = StringFormat("stop %s > cap %s", FmtMoney(p.slMoney), FmtMoney(p.cap));
      return false;
     }
   if(p.tpNet < InpMinNetTP)
     {
      p.reason = StringFormat("target %s < min %s", FmtMoney(p.tpNet), FmtMoney(InpMinNetTP));
      return false;
     }
   if(p.rr < InpMinRR)
     {
      p.reason = StringFormat("RR %.2f < min %.2f", p.rr, InpMinRR);
      return false;
     }
   p.ok     = true;
   p.reason = "fits";
   return true;
  }

//--- recompute the preview on every new bar and at most every 5 s otherwise
void RefreshPlan(const bool force)
  {
   datetime now = NowServer();
   if(!force && g_planTime > 0 && (long)(now - g_planTime) < 5)
      return;
   g_planTime = now;
   if(!g_f.ready)
     {
      ResetPlan(g_plan);
      g_plan.reason = "waiting for data";
      g_atrMoney    = 0.0;
      return;
     }
   BuildPlan(InpSlATR * g_f.atrPts, InpTpATR * g_f.atrPts, g_plan);
   double lots = (g_plan.lots > 0.0 ? g_plan.lots : NormalizeLotsDown(InpFixedLots));
   g_atrMoney = PointsToMoney(g_f.atrPts, lots);
   double margin = 0.0;
   if(g_haveTick && OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, lots, g_last.ask, margin))
      g_marginPerTrade = margin;
  }

//+------------------------------------------------------------------+
//| Input validation                                                 |
//+------------------------------------------------------------------+
bool Need(const bool cond, const string msg, string &err)
  {
   if(!cond)
      err = msg;
   return cond;
  }

bool ValidateInputs(string &err)
  {
   err = "";
   if(!Need(InpLogLevel >= 0 && InpLogLevel <= 2, "InpLogLevel must be 0, 1 or 2", err)) return false;
   if(!Need(InpMagicBase > 0, "InpMagicBase must be > 0", err)) return false;
   if(!Need(StringLen(InpComment) <= 16, "InpComment must be at most 16 characters", err)) return false;
   if(!Need(InpFixedLots > 0.0, "InpFixedLots must be > 0", err)) return false;
   if(!Need(InpRiskPct > 0.0 && InpRiskPct <= 5.0, "InpRiskPct must be above 0 and at most 5", err)) return false;
   if(!Need(InpMaxLots >= InpFixedLots, "InpMaxLots must be >= InpFixedLots", err)) return false;
   if(!Need(InpCommissionPerLotRT >= 0.0, "InpCommissionPerLotRT must be >= 0", err)) return false;
   if(!Need(InpMaxSpreadPts > 0, "InpMaxSpreadPts must be > 0", err)) return false;
   if(!Need(InpSpreadSpikeRatio > 1.0, "InpSpreadSpikeRatio must be > 1", err)) return false;
   if(!Need(InpAtrPeriod >= 2, "InpAtrPeriod must be >= 2", err)) return false;
   if(!Need(InpAtrBaseBars >= 20, "InpAtrBaseBars must be >= 20", err)) return false;
   if(!Need(InpEmaFast >= 2 && InpEmaSlow > InpEmaFast, "Need 2 <= InpEmaFast < InpEmaSlow", err)) return false;
   if(!Need(InpEmaTrendM5 >= 2, "InpEmaTrendM5 must be >= 2", err)) return false;
   if(!Need(InpSlopeBars >= 1, "InpSlopeBars must be >= 1", err)) return false;
   if(!Need(InpSlopeMinATR > 0.0, "InpSlopeMinATR must be > 0", err)) return false;
   if(!Need(InpErBars >= 5, "InpErBars must be >= 5", err)) return false;
   if(!Need(InpErRange > 0.0 && InpErRange < InpErTrend && InpErTrend < 1.0, "Need 0 < InpErRange < InpErTrend < 1", err)) return false;
   if(!Need(InpVolSpikeRatio > 1.0, "InpVolSpikeRatio must be > 1", err)) return false;
   if(!Need(InpShockATR > 0.0 && InpShockWindowSec >= 1, "Need InpShockATR > 0 and InpShockWindowSec >= 1", err)) return false;
   if(!Need(InpVolatileCoolSec >= 0, "InpVolatileCoolSec must be >= 0", err)) return false;
   if(!Need(InpDeadAtrSpread >= 0.0, "InpDeadAtrSpread must be >= 0", err)) return false;
   if(!Need(InpConfirmBars >= 1 && InpConfirmBars <= 20, "InpConfirmBars must be 1..20", err)) return false;
   if(!Need(InpSwingWindowSec >= 10, "InpSwingWindowSec must be >= 10", err)) return false;
   if(!Need(InpPullbackMinATR > 0.0 && InpPullbackMaxATR > InpPullbackMinATR, "Need 0 < InpPullbackMinATR < InpPullbackMaxATR", err)) return false;
   if(!Need(InpTriggerWindowSec >= 1 && InpTriggerBufferPts >= 0, "Check InpTriggerWindowSec / InpTriggerBufferPts", err)) return false;
   if(!Need(InpBreakoutBars >= 2 && InpBreakoutBufferPts >= 0, "Check InpBreakoutBars / InpBreakoutBufferPts", err)) return false;
   if(!Need(InpBreakoutVelATR >= 0.0 && InpVelWindowSec >= 1 && InpBreakoutMaxChaseATR > 0.0, "Check the breakout speed inputs", err)) return false;
   if(!Need(InpBandPeriod >= 2 && InpBandDev > 0.0, "Check the Bollinger inputs", err)) return false;
   if(!Need(InpFadeRejectATR >= 0.0 && InpFadeMaxVelATR > 0.0, "Check the fade inputs", err)) return false;
   if(!Need(InpTpATR > 0.0 && InpSlATR > 0.0 && InpMinSlPts >= 0, "Check InpTpATR / InpSlATR / InpMinSlPts", err)) return false;
   if(!Need(InpMinNetTP >= 0.0 && InpMaxNetTP > InpMinNetTP, "Need 0 <= InpMinNetTP < InpMaxNetTP", err)) return false;
   if(!Need(InpMaxLossPerTrade > 0.0, "InpMaxLossPerTrade must be > 0", err)) return false;
   if(!Need(InpMinRR >= 0.0, "InpMinRR must be >= 0", err)) return false;
   if(!Need(InpBeTriggerFrac > 0.0 && InpBeTriggerFrac < 1.0 && InpBeLockNet >= 0.0, "Check the breakeven inputs", err)) return false;
   if(!Need(InpRunnerMinER > 0.0 && InpRunnerMinER < 1.0 && InpRunnerLockFrac > 0.0 && InpRunnerLockFrac < 1.0 && InpRunnerTrailATR > 0.0, "Check the runner inputs", err)) return false;
   if(!Need(InpTimeStopSec >= 0 && InpModifyMinMs >= 0 && InpModifyMinStepPts >= 0, "Check the time stop / modify inputs", err)) return false;
   if(!Need(InpMaxPositions >= 1 && InpMaxPositions <= 20, "InpMaxPositions must be 1..20", err)) return false;
   if(!Need(InpMaxPerDirection >= 1 && InpMaxPerDirection <= InpMaxPositions, "Need 1 <= InpMaxPerDirection <= InpMaxPositions", err)) return false;
   if(!Need(InpMinSpacingPts >= 0 && InpCooldownWinSec >= 0 && InpCooldownLossSec >= 0, "Check the spacing / cooldown inputs", err)) return false;
   if(!Need(InpMaxTradesPerHour >= 1 && InpMaxTradesPerHour <= 500, "InpMaxTradesPerHour must be 1..500", err)) return false;
   if(!Need(InpMaxRequestsPerMin >= 1 && InpMaxRequestsPerMin <= 500, "InpMaxRequestsPerMin must be 1..500", err)) return false;
   if(!Need(InpMaxOpenRisk >= InpMaxLossPerTrade, "InpMaxOpenRisk must be >= InpMaxLossPerTrade", err)) return false;
   if(!Need(InpStreakPause >= 1 && InpStreakPauseMin >= 0 && InpStreakHalt > InpStreakPause, "Need InpStreakHalt > InpStreakPause >= 1", err)) return false;
   if(!Need(InpDailyLossLimit > 0.0 && InpDailyProfitLock >= 0.0, "Check the daily limits", err)) return false;
   if(!Need(InpEquityKillPct > 0.0 && InpEquityKillPct < 100.0, "InpEquityKillPct must be between 0 and 100", err)) return false;
   if(!Need(InpGuardTrades >= 2 && InpGuardTrades <= V10_GUARD_MAX && InpGuardPauseMin >= 0, "InpGuardTrades must be 2..50 and InpGuardPauseMin >= 0", err)) return false;
   if(!Need(InpMaxAvgSlipPts >= 0 && InpMinMarginLevel >= 0.0, "Check the slippage / margin inputs", err)) return false;
   if(!Need(ParseHHMM(InpTradeStart, g_tradeStartMin), "InpTradeStart must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpTradeEnd, g_tradeEndMin), "InpTradeEnd must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpDailyFlatten, g_dailyFlattenMin), "InpDailyFlatten must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpFridayLastEntry, g_fridayLastMin), "InpFridayLastEntry must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpFridayFlatten, g_fridayFlattenMin), "InpFridayFlatten must be HH:MM", err)) return false;
   if(!Need(g_tradeStartMin < g_tradeEndMin, "InpTradeStart must be before InpTradeEnd", err)) return false;
   if(!Need(g_dailyFlattenMin >= g_tradeEndMin, "InpDailyFlatten must not be before InpTradeEnd", err)) return false;
   if(!Need(g_fridayLastMin < g_fridayFlattenMin, "InpFridayLastEntry must be before InpFridayFlatten", err)) return false;
   if(!Need(InpMondayDelayMin >= 0, "InpMondayDelayMin must be >= 0", err)) return false;
   if(!Need(InpNewsBeforeMin >= 0 && InpNewsAfterMin >= 0, "Check the news window inputs", err)) return false;
   if(!Need(InpDeviationPts >= 0 && InpMaxRetries >= 0 && InpMaxRetries <= 5 && InpMaxTickAgeMs >= 100, "Check the execution inputs", err)) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Indicator handles                                                |
//+------------------------------------------------------------------+
bool CreateHandles()
  {
   g_hAtrM1   = iATR(_Symbol, PERIOD_M1, InpAtrPeriod);
   g_hAtrM5   = iATR(_Symbol, PERIOD_M5, InpAtrPeriod);
   g_hEmaFast = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaM5   = iMA(_Symbol, PERIOD_M5, InpEmaTrendM5, 0, MODE_EMA, PRICE_CLOSE);
   g_hBands   = iBands(_Symbol, PERIOD_M1, InpBandPeriod, 0, InpBandDev, PRICE_CLOSE);
   return (g_hAtrM1 != INVALID_HANDLE && g_hAtrM5 != INVALID_HANDLE && g_hEmaFast != INVALID_HANDLE &&
           g_hEmaSlow != INVALID_HANDLE && g_hEmaM5 != INVALID_HANDLE && g_hBands != INVALID_HANDLE);
  }

void ReleaseOne(int &handle)
  {
   if(handle != INVALID_HANDLE)
      IndicatorRelease(handle);
   handle = INVALID_HANDLE;
  }

void ReleaseHandles()
  {
   ReleaseOne(g_hAtrM1);
   ReleaseOne(g_hAtrM5);
   ReleaseOne(g_hEmaFast);
   ReleaseOne(g_hEmaSlow);
   ReleaseOne(g_hEmaM5);
   ReleaseOne(g_hBands);
  }

//--- best filling mode for market orders on this symbol
ENUM_ORDER_TYPE_FILLING DetectFilling()
  {
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

ENUM_ORDER_TYPE_FILLING NextFilling(const ENUM_ORDER_TYPE_FILLING f)
  {
   if(f == ORDER_FILLING_FOK)
      return ORDER_FILLING_IOC;
   if(f == ORDER_FILLING_IOC)
      return ORDER_FILLING_RETURN;
   return ORDER_FILLING_FOK;
  }

string FillingName(const ENUM_ORDER_TYPE_FILLING f)
  {
   if(f == ORDER_FILLING_FOK)
      return "FOK";
   if(f == ORDER_FILLING_IOC)
      return "IOC";
   return "RETURN";
  }

//+------------------------------------------------------------------+
//| Reset every runtime variable.                                    |
//| (EA globals survive a chart/parameter change, so OnInit must     |
//| reset them explicitly.)                                          |
//+------------------------------------------------------------------+
void ResetTrackers()
  {
   g_pbBuy.on        = false;
   g_pbBuy.fire      = false;
   g_pbBuy.ext       = 0.0;
   g_pbBuy.counter   = 0.0;
   g_pbBuy.extTime   = 0;
   g_pbSell.on       = false;
   g_pbSell.fire     = false;
   g_pbSell.ext      = 0.0;
   g_pbSell.counter  = 0.0;
   g_pbSell.extTime  = 0;
   g_fdBuy.armed     = false;
   g_fdBuy.blocked   = false;
   g_fdBuy.fire      = false;
   g_fdBuy.ext       = 0.0;
   g_fdBuy.maxVel    = 0.0;
   g_fdSell.armed    = false;
   g_fdSell.blocked  = false;
   g_fdSell.fire     = false;
   g_fdSell.ext      = 0.0;
   g_fdSell.maxVel   = 0.0;
   g_boFireBuy       = false;
   g_boFireSell      = false;
  }

void ResetAll()
  {
   g_tickSeq = -1;
   ArrayInitialize(g_tickMsc, 0);
   ArrayInitialize(g_tickBid, 0.0);
   ArrayInitialize(g_tickAsk, 0.0);
   ZeroMemory(g_last);
   g_haveTick   = false;
   g_newTick    = false;
   g_lastTickUs = 0;
   g_wShock.Init((long)InpShockWindowSec * 1000);
   g_wRate.Init(V10_RATE_WINDOW_MS);
   g_wTrig.Init((long)InpTriggerWindowSec * 1000);
   g_wVel.Init((long)InpVelWindowSec * 1000);
   g_trigPrevOk = false;
   g_trigHiPrev = 0.0;
   g_trigLoPrev = 0.0;

   ArrayInitialize(g_spreadRing, 0);
   ArrayInitialize(g_spreadHist, 0);
   g_spreadHead       = -1;
   g_spreadCount      = 0;
   g_lastSpreadSample = 0;
   g_spreadMedian     = 0.0;

   ZeroMemory(g_f);
   g_dataReason = "waiting for data";
   ResetPlan(g_plan);
   g_planTime = 0;
   g_atrMoney = 0.0;
   g_marginPerTrade = 0.0;

   g_state          = V10_ST_WARMUP;
   g_baseState      = V10_ST_WARMUP;
   g_rawState       = V10_ST_WARMUP;
   g_pending        = V10_ST_WARMUP;
   g_pendingCount   = 0;
   g_stateSince     = 0;
   g_volatileUntil  = 0;
   g_volatileReason = "";
   g_lastM1Bar      = 0;
   g_shockRangePts  = 0.0;

   g_dayKey = 0;
   ArrayInitialize(g_stateSecs, 0.0);
   g_readySecs    = 0.0;
   g_stateChanges = 0;
   g_lastAcct     = 0;
   g_readyNow     = false;
   g_readyReason  = "";
   g_entryOpen    = false;
   g_entryReason  = "";

   ResetTrackers();
   g_boBarBuy   = 0;
   g_boBarSell  = 0;
   g_trackState = V10_ST_WARMUP;

   g_posCount = 0;
   g_posBuy   = 0;
   g_posSell  = 0;
   g_floating = 0.0;
   g_openRisk = 0.0;
   for(int i = 0; i < V10_MAX_INTENTS; i++)
     {
      g_intents[i].ticket     = 0;
      g_intents[i].slPts      = 0.0;
      g_intents[i].tpPts      = 0.0;
      g_intents[i].reqPrice   = 0.0;
      g_intents[i].dir        = 0;
      g_intents[i].attempts   = 0;
      g_intents[i].lastTry    = 0;
      g_intents[i].nakedSince = 0;
     }
   g_intentNext = 0;
   for(int i = 0; i < V10_CLOSE_TAGS; i++)
     {
      g_closeTagTicket[i] = 0;
      g_closeTagText[i]   = "";
     }
   g_closeTagNext = 0;

   g_dayStart      = 0;
   g_realizedToday = 0.0;
   g_tradesToday   = 0;
   g_winsToday     = 0;
   g_lossesToday   = 0;
   for(int pb = 0; pb < V10_PB_COUNT; pb++)
     {
      g_pbTrades[pb]     = 0;
      g_pbNet[pb]        = 0.0;
      g_pbPauseUntil[pb] = 0;
      g_guardCount[pb]   = 0;
      g_guardHead[pb]    = 0;
     }
   ArrayInitialize(g_guardBuf, 0.0);
   g_lossStreak      = 0;
   g_lastCloseTime   = 0;
   g_lastCloseWin    = true;
   g_pauseUntil      = 0;
   g_pauseReason     = "";
   g_execPauseUntil  = 0;
   g_execPauseReason = "";
   g_haltDay         = false;
   g_flattenDay      = false;
   g_haltReason      = "";
   g_haltKill        = false;
   g_peakEquity      = 0.0;
   g_lastFlattenTry  = 0;
   ArrayInitialize(g_slipBuf, 0.0);
   g_slipCount  = 0;
   g_slipHead   = 0;
   ArrayInitialize(g_entryTimes, 0);
   g_entryHead  = 0;
   g_entryCount = 0;
   ArrayInitialize(g_reqTimes, 0);
   g_reqHead    = 0;
   g_reqCount   = 0;
   g_newsCount  = 0;
   g_newsLoaded = 0;
   g_newsStatus = "";
   g_lastSignal = "-";
   g_lastAction = "-";
   g_failStreak    = 0;
   g_lastBlockLog  = 0;
   g_lastSkipLog   = 0;
   g_skipsQuiet    = 0;
   g_noStopToday   = 0;
   g_maxDealSeen   = 0;

   g_markSeq     = 0;
   g_markOldest  = 0;
   g_lastPanelMs = 0;
   g_panelReady  = false;
   for(int i = 0; i < V10_PANEL_LINES; i++)
     {
      g_panelText[i]  = "";
      g_panelColor[i] = clrNONE;
     }
  }

//+------------------------------------------------------------------+
//| Market data                                                      |
//+------------------------------------------------------------------+
//--- read the latest quote; store it in the tick buffer if it is new
bool RefreshTick()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return false;
   if(t.bid <= 0.0 || t.ask <= 0.0 || t.ask < t.bid)
      return false;
   bool changed = (!g_haveTick || t.time_msc != g_last.time_msc || t.bid != g_last.bid || t.ask != g_last.ask);
   g_last     = t;
   g_haveTick = true;
   if(changed)
     {
      //--- remember the trigger window before this tick joins it
      g_trigPrevOk = g_wTrig.HasData();
      if(g_trigPrevOk)
        {
         g_trigHiPrev = g_wTrig.Hi();
         g_trigLoPrev = g_wTrig.Lo();
        }
      g_tickSeq++;
      int i = TickIdx(g_tickSeq);
      g_tickMsc[i] = t.time_msc;
      g_tickBid[i] = t.bid;
      g_tickAsk[i] = t.ask;
      g_wShock.Add(g_tickSeq);
      g_wRate.Add(g_tickSeq);
      g_wTrig.Add(g_tickSeq);
      g_wVel.Add(g_tickSeq);
      g_lastTickUs = (long)GetMicrosecondCount();
      g_newTick    = true;
     }
   return true;
  }

//--- one spread sample per server second; median from a histogram (O(1) update)
void SampleSpread()
  {
   if(!g_haveTick)
      return;
   datetime now = NowServer();
   if(now == g_lastSpreadSample)
      return;
   g_lastSpreadSample = now;
   int bin = (int)MathRound(CurrentSpreadPts());
   if(bin < 0)
      bin = 0;
   if(bin >= V10_SPREAD_BINS)
      bin = V10_SPREAD_BINS - 1;
   int next = (g_spreadHead + 1) % V10_SPREAD_SAMPLES;
   if(g_spreadCount == V10_SPREAD_SAMPLES)
      g_spreadHist[g_spreadRing[next]]--;
   else
      g_spreadCount++;
   g_spreadRing[next] = bin;
   g_spreadHist[bin]++;
   g_spreadHead = next;
   int target = (g_spreadCount + 1) / 2;
   int cum    = 0;
   for(int b = 0; b < V10_SPREAD_BINS; b++)
     {
      cum += g_spreadHist[b];
      if(cum >= target)
        {
         g_spreadMedian = (double)b;
         break;
        }
     }
  }

//+------------------------------------------------------------------+
//| Closed-bar features for the M1 bar at 'shift' (1 = last closed). |
//| M5 values always come from the last closed M5 bar.               |
//+------------------------------------------------------------------+
bool ComputeFeatures(const int shift, V10Features &f)
  {
   ZeroMemory(f);
   f.ready = false;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hAtrM1, 0, shift, InpAtrBaseBars, atr) != InpAtrBaseBars)
     {
      g_dataReason = "loading M1 ATR";
      return false;
     }
   if(atr[0] <= 0.0 || atr[0] == EMPTY_VALUE)
     {
      g_dataReason = "M1 ATR not ready";
      return false;
     }
   double sum = 0.0;
   int    n   = 0;
   for(int i = 0; i < InpAtrBaseBars; i++)
     {
      if(atr[i] > 0.0 && atr[i] != EMPTY_VALUE)
        {
         sum += atr[i];
         n++;
        }
     }
   if(n < InpAtrBaseBars / 2)
     {
      g_dataReason = "M1 ATR history too short";
      return false;
     }

   double ef[];
   double es[];
   ArraySetAsSeries(ef, true);
   ArraySetAsSeries(es, true);
   if(CopyBuffer(g_hEmaFast, 0, shift, 1, ef) != 1 || CopyBuffer(g_hEmaSlow, 0, shift, 1, es) != 1)
     {
      g_dataReason = "loading M1 EMAs";
      return false;
     }

   int    nEm = InpSlopeBars + 1;
   double em[];
   double a5[];
   ArraySetAsSeries(em, true);
   ArraySetAsSeries(a5, true);
   if(CopyBuffer(g_hEmaM5, 0, 1, nEm, em) != nEm || CopyBuffer(g_hAtrM5, 0, 1, 1, a5) != 1)
     {
      g_dataReason = "loading M5 data";
      return false;
     }
   if(a5[0] <= 0.0 || a5[0] == EMPTY_VALUE || em[0] == EMPTY_VALUE || em[InpSlopeBars] == EMPTY_VALUE)
     {
      g_dataReason = "M5 indicators not ready";
      return false;
     }

   double bu[];
   double bm[];
   double bl[];
   ArraySetAsSeries(bu, true);
   ArraySetAsSeries(bm, true);
   ArraySetAsSeries(bl, true);
   if(CopyBuffer(g_hBands, 1, shift, 1, bu) != 1 || CopyBuffer(g_hBands, 0, shift, 1, bm) != 1 ||
      CopyBuffer(g_hBands, 2, shift, 1, bl) != 1)
     {
      g_dataReason = "loading M1 Bollinger bands";
      return false;
     }
   if(bu[0] <= 0.0 || bu[0] == EMPTY_VALUE || bl[0] <= 0.0 || bl[0] == EMPTY_VALUE)
     {
      g_dataReason = "Bollinger bands not ready";
      return false;
     }

   int    nCl = InpErBars + 1;
   double cl[];
   ArraySetAsSeries(cl, true);
   if(CopyClose(_Symbol, PERIOD_M1, shift, nCl, cl) != nCl)
     {
      g_dataReason = "loading M1 closes";
      return false;
     }
   double hh[];
   double ll[];
   ArraySetAsSeries(hh, true);
   ArraySetAsSeries(ll, true);
   if(CopyHigh(_Symbol, PERIOD_M1, shift, InpBreakoutBars, hh) != InpBreakoutBars ||
      CopyLow(_Symbol, PERIOD_M1, shift, InpBreakoutBars, ll) != InpBreakoutBars)
     {
      g_dataReason = "loading M1 highs/lows";
      return false;
     }
   datetime bt[];
   ArraySetAsSeries(bt, true);
   if(CopyTime(_Symbol, PERIOD_M1, shift, 1, bt) != 1)
     {
      g_dataReason = "loading M1 times";
      return false;
     }

   double path = 0.0;
   for(int k = 0; k < InpErBars; k++)
      path += MathAbs(cl[k] - cl[k + 1]);
   double hi = hh[0];
   double lo = ll[0];
   for(int k = 1; k < InpBreakoutBars; k++)
     {
      if(hh[k] > hi)
         hi = hh[k];
      if(ll[k] < lo)
         lo = ll[k];
     }

   f.barTime    = bt[0];
   f.atrPts     = atr[0] / g_point;
   f.atrBasePts = (sum / n) / g_point;
   f.atrRatio   = (f.atrBasePts > 0.0 ? f.atrPts / f.atrBasePts : 0.0);
   f.atrM5      = a5[0];
   f.emaFast    = ef[0];
   f.emaSlow    = es[0];
   f.slopeAtr   = (em[0] - em[InpSlopeBars]) / a5[0];
   f.er         = (path > 0.0 ? (cl[0] - cl[InpErBars]) / path : 0.0);
   f.bandUp     = bu[0];
   f.bandMid    = bm[0];
   f.bandLo     = bl[0];
   f.brkHigh    = hi;
   f.brkLow     = lo;
   f.ready      = true;
   g_dataReason = "";
   return true;
  }

//+------------------------------------------------------------------+
//| State engine                                                     |
//+------------------------------------------------------------------+
//--- classify one closed bar (checked in priority order)
ENUM_V10_STATE ClassifyBar(const V10Features &f, string &why)
  {
   why = "";
   if(!f.ready)
     {
      why = g_dataReason;
      return V10_ST_WARMUP;
     }
   if(f.atrRatio >= InpVolSpikeRatio)
     {
      why = StringFormat("ATR %.2fx its baseline", f.atrRatio);
      return V10_ST_VOLATILE;
     }
   double sp = SpreadRef();
   if(sp > 0.0 && f.atrPts < InpDeadAtrSpread * sp)
     {
      why = StringFormat("ATR %.0f < %.1f x spread %.0f", f.atrPts, InpDeadAtrSpread, sp);
      return V10_ST_DEAD;
     }
   bool up = (f.slopeAtr >=  InpSlopeMinATR && f.emaFast > f.emaSlow && f.er >=  InpErTrend);
   bool dn = (f.slopeAtr <= -InpSlopeMinATR && f.emaFast < f.emaSlow && f.er <= -InpErTrend);
   if(up)
     {
      why = "trend up";
      return V10_ST_TREND_UP;
     }
   if(dn)
     {
      why = "trend down";
      return V10_ST_TREND_DOWN;
     }
   if(MathAbs(f.er) <= InpErRange && MathAbs(f.slopeAtr) < InpSlopeMinATR)
     {
      why = "range";
      return V10_ST_RANGE;
     }
   why = "mixed signals";
   return V10_ST_UNCLEAR;
  }

bool VolatileActive()
  {
   return (g_volatileUntil > 0 && NowServer() < g_volatileUntil);
  }

//--- start or extend the VOLATILE latch (instant safety override)
void TriggerVolatile(const string reason)
  {
   bool     wasActive = VolatileActive();
   datetime until     = NowServer() + InpVolatileCoolSec;
   if(until > g_volatileUntil)
      g_volatileUntil = until;
   g_volatileReason = reason;
   if(!wasActive)
     {
      V10Log(1, "VOLATILE trigger: " + reason);
      if(g_baseState != V10_ST_WARMUP)
         g_baseState = V10_ST_UNCLEAR;   // after the latch, every state must be confirmed again
      g_pendingCount = 0;
     }
  }

//+------------------------------------------------------------------+
//| Turn a bar classification into the confirmed base state.         |
//|  - VOLATILE and DEAD apply at once (safety first).               |
//|  - Bars inside a volatile latch never count toward confirmation. |
//|  - A trade state contradicted by another trade state drops to    |
//|    UNCLEAR at once; the new state still needs confirmation.      |
//|  - Entering a trade state, or leaving one for UNCLEAR, needs     |
//|    InpConfirmBars consecutive bars.                              |
//+------------------------------------------------------------------+
void ApplyClassification(const ENUM_V10_STATE raw, const string why)
  {
   g_rawState = raw;
   if(raw == V10_ST_WARMUP)
     {
      g_baseState    = V10_ST_WARMUP;
      g_pendingCount = 0;
      return;
     }
   if(raw == V10_ST_VOLATILE)
     {
      TriggerVolatile(why);
      g_baseState    = V10_ST_UNCLEAR;
      g_pendingCount = 0;
      return;
     }
   if(VolatileActive())
     {
      g_pendingCount = 0;
      return;
     }
   if(raw == V10_ST_DEAD)
     {
      g_baseState    = V10_ST_DEAD;
      g_pendingCount = 0;
      return;
     }
   if(raw == g_baseState)
     {
      g_pendingCount = 0;
      return;
     }
   bool baseTradeable = IsTradeable(g_baseState);
   bool rawTradeable  = IsTradeable(raw);
   if(!baseTradeable && !rawTradeable)
     {
      g_baseState    = raw;              // e.g. DEAD -> UNCLEAR: both are no-trade states
      g_pendingCount = 0;
      return;
     }
   if(baseTradeable && rawTradeable)
     {
      g_baseState    = V10_ST_UNCLEAR;   // contradiction: stop trading the old state now
      g_pending      = raw;
      g_pendingCount = 1;
     }
   else if(g_pendingCount > 0 && g_pending == raw)
      g_pendingCount++;
   else
     {
      g_pending      = raw;
      g_pendingCount = 1;
     }
   if(g_pendingCount >= InpConfirmBars)
     {
      g_baseState    = raw;
      g_pendingCount = 0;
     }
  }

//--- on the first successful bar, replay the previous closed bars so that
//--- a restart does not have to wait InpConfirmBars minutes
void SeedState()
  {
   for(int s = InpConfirmBars; s >= 2; s--)
     {
      V10Features fs;
      if(!ComputeFeatures(s, fs))
         continue;
      string why = "";
      ENUM_V10_STATE raw = ClassifyBar(fs, why);
      ApplyClassification(raw, why);
     }
  }

//--- tick-level safety overrides: shock move and spread spike
void CheckLiveOverrides()
  {
   if(!g_haveTick)
      return;
   if(g_wShock.HasData())
      g_shockRangePts = (g_wShock.Hi() - g_wShock.Lo()) / g_point;
   else
      g_shockRangePts = 0.0;
   if(g_f.ready && g_f.atrPts > 0.0)
     {
      double limit = InpShockATR * g_f.atrPts;
      if(g_shockRangePts >= limit)
         TriggerVolatile(StringFormat("shock %.0f pts in %d s (limit %.0f)", g_shockRangePts, InpShockWindowSec, limit));
     }
   if(g_spreadCount >= V10_MIN_SPREAD_SAMPLES && g_spreadMedian > 0.0)
     {
      double sp  = CurrentSpreadPts();
      double lim = InpSpreadSpikeRatio * g_spreadMedian;
      if(sp > lim)
         TriggerVolatile(StringFormat("spread %.0f > %.1f x median %.0f", sp, InpSpreadSpikeRatio, g_spreadMedian));
     }
  }

void MarkState(const ENUM_V10_STATE st)
  {
   if(!g_drawObjects || !InpDrawStates || !g_haveTick)
      return;
   string   name = V10_PREFIX + "ST_" + IntegerToString(g_markSeq);
   datetime t    = g_last.time;
   if(ObjectCreate(0, name, OBJ_TEXT, 0, t, g_last.bid))
     {
      ObjectSetString(0, name, OBJPROP_TEXT, StateShort(st));
      ObjectSetString(0, name, OBJPROP_FONT, "Arial");
      ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 8);
      ObjectSetInteger(0, name, OBJPROP_COLOR, StateColor(st));
      ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_LEFT_LOWER);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TOOLTIP, StateName(st) + " from " + TimeToString(t, TIME_DATE | TIME_SECONDS));
     }
   g_markSeq++;
   while(g_markSeq - g_markOldest > V10_MAX_MARKS)
     {
      ObjectDelete(0, V10_PREFIX + "ST_" + IntegerToString(g_markOldest));
      g_markOldest++;
     }
  }

void OnStateChanged(const ENUM_V10_STATE prevSt, const ENUM_V10_STATE newSt)
  {
   string extra = "";
   if(newSt == V10_ST_VOLATILE)
      extra = " | " + g_volatileReason;
   string emaDir = (g_f.emaFast > g_f.emaSlow ? "up" : "down");
   V10Log(1, StringFormat("STATE %s -> %s | ER %+.2f slope %+.2f EMA %s | ATR %.0f pts ratio %.2f | spread %.0f (median %.0f)%s",
                          StateName(prevSt), StateName(newSt), g_f.er, g_f.slopeAtr, emaDir,
                          g_f.atrPts, g_f.atrRatio, CurrentSpreadPts(), g_spreadMedian, extra));
   MarkState(newSt);
  }

//--- effective state = VOLATILE while latched, otherwise the confirmed base state
void ResolveState()
  {
   ENUM_V10_STATE eff = (VolatileActive() ? V10_ST_VOLATILE : g_baseState);
   if(eff == g_state)
      return;
   ENUM_V10_STATE prevSt = g_state;
   g_state      = eff;
   g_stateSince = NowServer();
   g_stateChanges++;
   OnStateChanged(prevSt, eff);
  }

//+------------------------------------------------------------------+
//| Session window                                                   |
//+------------------------------------------------------------------+
bool SessionOpen(const datetime now, string &why)
  {
   MqlDateTime s;
   TimeToStruct(now, s);
   if(s.day_of_week == 0 || s.day_of_week == 6)
     {
      why = "closed (weekend)";
      return false;
     }
   int mod   = s.hour * 60 + s.min;
   int start = g_tradeStartMin;
   if(s.day_of_week == 1)
      start += InpMondayDelayMin;
   int end = g_tradeEndMin;
   if(s.day_of_week == 5 && g_fridayLastMin < end)
      end = g_fridayLastMin;
   if(mod < start)
     {
      why = "closed until " + MinToHHMM(start);
      return false;
     }
   if(mod >= end)
     {
      why = "closed since " + MinToHHMM(end);
      return false;
     }
   why = "open until " + MinToHHMM(end);
   return true;
  }

//+------------------------------------------------------------------+
//| News filter (MT5 economic calendar; not available in the tester) |
//+------------------------------------------------------------------+
void RefreshNews(const bool force)
  {
   if(!InpUseNews)
     {
      g_newsStatus = "off";
      g_newsCount  = 0;
      return;
     }
   if(g_isTester)
     {
      g_newsStatus = "skipped (the calendar is not available in the Strategy Tester)";
      g_newsCount  = 0;
      return;
     }
   datetime now = NowServer();
   if(!force && g_newsLoaded > 0 && (long)(now - g_newsLoaded) < 300)
      return;
   g_newsLoaded = now;
   g_newsCount  = 0;
   string curs[];
   ushort sep    = StringGetCharacter(",", 0);
   int    nc     = StringSplit(InpNewsCurrencies, sep, curs);
   int    errors = 0;
   for(int c = 0; c < nc; c++)
     {
      string cur = curs[c];
      StringTrimLeft(cur);
      StringTrimRight(cur);
      if(StringLen(cur) == 0)
         continue;
      MqlCalendarValue vals[];
      ResetLastError();
      if(!CalendarValueHistory(vals, now - 3600, now + 86400, NULL, cur))
        {
         if(GetLastError() != 0)
            errors++;
         continue;
        }
      int nv = ArraySize(vals);
      for(int i = 0; i < nv && g_newsCount < V10_MAX_NEWS; i++)
        {
         MqlCalendarEvent ev;
         if(!CalendarEventById(vals[i].event_id, ev))
            continue;
         if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
            continue;
         g_newsTime[g_newsCount] = vals[i].time;
         g_newsName[g_newsCount] = cur + " " + ev.name;
         g_newsCount++;
        }
     }
   if(errors > 0)
      g_newsStatus = StringFormat("calendar error for %d currency(ies) - filter open", errors);
   else
      g_newsStatus = StringFormat("%d high-impact event(s) in the next 24 h", g_newsCount);
  }

bool NewsWindow(const datetime now, string &what)
  {
   for(int i = 0; i < g_newsCount; i++)
     {
      datetime t = g_newsTime[i];
      if(now >= t - InpNewsBeforeMin * 60 && now <= t + InpNewsAfterMin * 60)
        {
         what = g_newsName[i] + " at " + TimeToString(t, TIME_MINUTES);
         return true;
        }
     }
   return false;
  }

string NextNewsText(const datetime now)
  {
   int      best  = -1;
   datetime bestT = 0;
   for(int i = 0; i < g_newsCount; i++)
     {
      if(g_newsTime[i] > now && (best < 0 || g_newsTime[i] < bestT))
        {
         best  = i;
         bestT = g_newsTime[i];
        }
     }
   if(best < 0)
      return "no upcoming high-impact event";
   return StringFormat("next %s at %s (in %s)", g_newsName[best], TimeToString(bestT, TIME_MINUTES),
                       FormatDuration((long)(bestT - now)));
  }

//+------------------------------------------------------------------+
//| Own positions                                                    |
//+------------------------------------------------------------------+
void ScanPositions()
  {
   g_posCount = 0;
   g_posBuy   = 0;
   g_posSell  = 0;
   g_floating = 0.0;
   g_openRisk = 0.0;
   int total = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      int pb = PbOfMagic(PositionGetInteger(POSITION_MAGIC));
      if(pb < 0)
         continue;
      if(g_posCount >= V10_MAX_POS)
         break;
      int    dir  = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double fl   = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP) - 0.5 * g_commPerLotRT * vol;
      double risk   = 0.0;
      bool   locked = false;
      if(sl <= 0.0)
         risk = InpMaxLossPerTrade;      // no stop yet: count the full cap
      else
        {
         double riskPts = (dir > 0 ? open - sl : sl - open) / g_point;
         if(riskPts <= 0.0)
            locked = true;
         else
            risk = PointsToMoney(riskPts, vol) + g_commPerLotRT * vol;
        }
      g_pos[g_posCount].ticket   = ticket;
      g_pos[g_posCount].id       = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      g_pos[g_posCount].dir      = dir;
      g_pos[g_posCount].pb       = pb;
      g_pos[g_posCount].vol      = vol;
      g_pos[g_posCount].open     = open;
      g_pos[g_posCount].sl       = sl;
      g_pos[g_posCount].tp       = tp;
      g_pos[g_posCount].floating = fl;
      g_pos[g_posCount].risk     = risk;
      g_pos[g_posCount].locked   = locked;
      g_posCount++;
      if(dir > 0)
         g_posBuy++;
      else
         g_posSell++;
      g_floating += fl;
      g_openRisk += risk;
     }
  }

bool AllLocked(const int dir)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].dir == dir && !g_pos[i].locked)
         return false;
   return true;
  }

bool SpacingOk(const int dir, const double price)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].dir == dir && MathAbs(price - g_pos[i].open) / g_point < InpMinSpacingPts)
         return false;
   return true;
  }

double DayNet()
  {
   return g_realizedToday + g_floating;
  }

//+------------------------------------------------------------------+
//| Intents (stop/target distances per position)                     |
//+------------------------------------------------------------------+
int FindIntent(const ulong ticket)
  {
   for(int i = 0; i < V10_MAX_INTENTS; i++)
      if(g_intents[i].ticket == ticket)
         return i;
   return -1;
  }

int AddIntent(const ulong ticket, const double slPts, const double tpPts, const double reqPrice, const int dir)
  {
   int k = FindIntent(ticket);
   if(k < 0)
     {
      k = g_intentNext;
      g_intentNext = (g_intentNext + 1) % V10_MAX_INTENTS;
     }
   g_intents[k].ticket     = ticket;
   g_intents[k].slPts      = slPts;
   g_intents[k].tpPts      = tpPts;
   g_intents[k].reqPrice   = reqPrice;
   g_intents[k].dir        = dir;
   g_intents[k].attempts   = 0;
   g_intents[k].lastTry    = 0;
   g_intents[k].nakedSince = 0;
   return k;
  }

void TagClose(const ulong ticket, const string reason)
  {
   for(int i = 0; i < V10_CLOSE_TAGS; i++)
      if(g_closeTagTicket[i] == ticket)
        {
         g_closeTagText[i] = reason;
         return;
        }
   g_closeTagTicket[g_closeTagNext] = ticket;
   g_closeTagText[g_closeTagNext]   = reason;
   g_closeTagNext = (g_closeTagNext + 1) % V10_CLOSE_TAGS;
  }

string CloseTag(const ulong ticket)
  {
   for(int i = 0; i < V10_CLOSE_TAGS; i++)
      if(g_closeTagTicket[i] == ticket)
         return g_closeTagText[i];
   return "";
  }

//+------------------------------------------------------------------+
//| Rate limiters and protection helpers                             |
//+------------------------------------------------------------------+
void NoteRequest()
  {
   g_reqTimes[g_reqHead] = NowServer();
   g_reqHead = (g_reqHead + 1) % V10_TIME_RING;
   if(g_reqCount < V10_TIME_RING)
      g_reqCount++;
  }

int RequestsLastMinute()
  {
   datetime now = NowServer();
   int      n   = 0;
   int      idx = g_reqHead;
   for(int k = 0; k < g_reqCount; k++)
     {
      idx = (idx - 1 + V10_TIME_RING) % V10_TIME_RING;
      if((long)(now - g_reqTimes[idx]) >= 60)
         break;
      n++;
     }
   return n;
  }

void NoteEntry()
  {
   g_entryTimes[g_entryHead] = NowServer();
   g_entryHead = (g_entryHead + 1) % V10_TIME_RING;
   if(g_entryCount < V10_TIME_RING)
      g_entryCount++;
  }

int EntriesLastHour()
  {
   datetime now = NowServer();
   int      n   = 0;
   int      idx = g_entryHead;
   for(int k = 0; k < g_entryCount; k++)
     {
      idx = (idx - 1 + V10_TIME_RING) % V10_TIME_RING;
      if((long)(now - g_entryTimes[idx]) >= 3600)
         break;
      n++;
     }
   return n;
  }

void Pause(const int seconds, const string reason)
  {
   datetime until = NowServer() + seconds;
   if(until > g_pauseUntil)
     {
      g_pauseUntil  = until;
      g_pauseReason = reason;
     }
   V10Log(1, StringFormat("PAUSE %s: %s", FormatDuration((long)seconds), reason));
  }

void ExecPause(const int seconds, const string reason)
  {
   datetime until = NowServer() + seconds;
   if(until > g_execPauseUntil)
     {
      g_execPauseUntil  = until;
      g_execPauseReason = reason;
     }
  }

void HaltDay(const string reason, const bool flatten)
  {
   if(flatten)
      g_flattenDay = true;
   if(g_haltDay)
      return;
   g_haltDay    = true;
   g_haltReason = reason;
   V10Log(1, "HALT for the rest of the server day: " + reason);
  }

//--- playbook guard: pause a playbook whose recent trades lose on average
void GuardPush(const int pb, const double net)
  {
   g_guardBuf[pb * V10_GUARD_MAX + g_guardHead[pb]] = net;
   g_guardHead[pb] = (g_guardHead[pb] + 1) % InpGuardTrades;
   if(g_guardCount[pb] < InpGuardTrades)
      g_guardCount[pb]++;
   if(g_guardCount[pb] < InpGuardTrades)
      return;
   double sum = 0.0;
   for(int k = 0; k < InpGuardTrades; k++)
      sum += g_guardBuf[pb * V10_GUARD_MAX + k];
   double avg = sum / InpGuardTrades;
   if(avg < InpGuardMinAvg)
     {
      g_pbPauseUntil[pb] = NowServer() + InpGuardPauseMin * 60;
      g_guardCount[pb]   = 0;
      g_guardHead[pb]    = 0;
      V10Log(1, StringFormat("GUARD: %s paused %d min - last %d trades average %s per trade",
                             PbName(pb), InpGuardPauseMin, InpGuardTrades, FmtMoney(avg)));
     }
  }

//--- slippage guard: pause entries when fills get worse than the limit
void SlipPush(const double pts)
  {
   g_slipBuf[g_slipHead] = pts;
   g_slipHead = (g_slipHead + 1) % V10_SLIP_SAMPLES;
   if(g_slipCount < V10_SLIP_SAMPLES)
      g_slipCount++;
   if(InpMaxAvgSlipPts <= 0 || g_slipCount < V10_SLIP_SAMPLES)
      return;
   double sum = 0.0;
   for(int k = 0; k < V10_SLIP_SAMPLES; k++)
      sum += g_slipBuf[k];
   double avg = sum / V10_SLIP_SAMPLES;
   if(avg > InpMaxAvgSlipPts)
     {
      Pause(15 * 60, StringFormat("average slippage %.0f pts over the last %d fills", avg, V10_SLIP_SAMPLES));
      g_slipCount = 0;
      g_slipHead  = 0;
     }
  }

//+------------------------------------------------------------------+
//| Trading day and deal accounting                                  |
//+------------------------------------------------------------------+
double DealMoney(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_FEE);
  }

//--- net result of a closed position from its deals
void PositionHistory(const ulong posId, double &net, double &comm, double &volIn, double &volOut,
                     datetime &opened, int &dir, int &pbIn)
  {
   net    = 0.0;
   comm   = 0.0;
   volIn  = 0.0;
   volOut = 0.0;
   opened = 0;
   dir    = 0;
   pbIn   = -1;
   if(!HistorySelectByPosition((long)posId))
      return;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      net  += DealMoney(deal);
      comm += HistoryDealGetDouble(deal, DEAL_COMMISSION);
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN)
        {
         volIn += HistoryDealGetDouble(deal, DEAL_VOLUME);
         opened = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
         dir    = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1);
         pbIn   = PbOfMagic(HistoryDealGetInteger(deal, DEAL_MAGIC));
        }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         volOut += HistoryDealGetDouble(deal, DEAL_VOLUME);
     }
  }

void AddUniqueId(ulong &ids[], int &pbs[], int &n, const ulong id, const int pb)
  {
   for(int q = 0; q < n; q++)
      if(ids[q] == id)
         return;
   ArrayResize(ids, n + 1);
   ArrayResize(pbs, n + 1);
   ids[n] = id;
   pbs[n] = pb;
   n++;
  }

//--- today's closed money from history (used at start-up and at the day change)
void RebuildToday(const datetime now)
  {
   if(!HistorySelect(g_dayStart, now + 3600))
      return;
   ulong  ids[];
   int    pbs[];
   int    nIds = 0;
   ulong  candId[];
   double candMoney[];
   int    nCand = 0;
   int    n     = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(deal > g_maxDealSeen)
         g_maxDealSeen = deal;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      bool   isOut = (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY);
      int    pb    = PbOfMagic(HistoryDealGetInteger(deal, DEAL_MAGIC));
      ulong  id    = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      double money = DealMoney(deal);
      if(pb < 0)
        {
         if(isOut)
           {
            ArrayResize(candId, nCand + 1);
            ArrayResize(candMoney, nCand + 1);
            candId[nCand]    = id;
            candMoney[nCand] = money;
            nCand++;
           }
         continue;
        }
      g_realizedToday += money;
      g_pbNet[pb]     += money;
      if(isOut)
         AddUniqueId(ids, pbs, nIds, id, pb);
     }
   double   net    = 0.0;
   double   comm   = 0.0;
   double   volIn  = 0.0;
   double   volOut = 0.0;
   datetime opened = 0;
   int      dir    = 0;
   int      pbIn   = -1;
   //--- closes that carry no v10 magic belong to v10 if v10 opened the position
   for(int c = 0; c < nCand; c++)
     {
      PositionHistory(candId[c], net, comm, volIn, volOut, opened, dir, pbIn);
      if(pbIn < 0)
         continue;
      g_realizedToday += candMoney[c];
      g_pbNet[pbIn]   += candMoney[c];
      AddUniqueId(ids, pbs, nIds, candId[c], pbIn);
     }
   //--- classify each fully closed trade by its full net (entry and exit costs)
   for(int j = 0; j < nIds; j++)
     {
      PositionHistory(ids[j], net, comm, volIn, volOut, opened, dir, pbIn);
      if(volIn <= 0.0 || volOut < volIn - 1e-9)
         continue;
      g_tradesToday++;
      g_pbTrades[pbs[j]]++;
      if(net >= 0.0)
         g_winsToday++;
      else
         g_lossesToday++;
     }
  }

void ResetTradingDay(const datetime now)
  {
   g_dayStart      = DayStartOf(now);
   g_realizedToday = 0.0;
   g_tradesToday   = 0;
   g_winsToday     = 0;
   g_lossesToday   = 0;
   for(int pb = 0; pb < V10_PB_COUNT; pb++)
     {
      g_pbTrades[pb] = 0;
      g_pbNet[pb]    = 0.0;
     }
   if(g_haltDay)
      V10Log(1, "New server day: the daily halt is cleared.");
   g_haltDay    = false;
   g_flattenDay = false;
   g_haltReason = "";
   g_lossStreak = 0;
   g_noStopToday = 0;
   RebuildToday(now);
  }

string CloseReasonText(const ENUM_DEAL_REASON reason, const ulong posId)
  {
   if(reason == DEAL_REASON_SL)
      return "SL";
   if(reason == DEAL_REASON_TP)
      return "TP";
   if(reason == DEAL_REASON_SO)
      return "STOP_OUT";
   if(reason == DEAL_REASON_EXPERT)
     {
      string tag = CloseTag(posId);
      return (tag == "" ? "EA" : tag);
     }
   if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB)
      return "MANUAL";
   return "OTHER";
  }

void OnPositionClosed(const int pb, const int dir, const ulong posId, const double net, const double comm,
                      const double volIn, const datetime opened, const datetime closed, const string why,
                      const bool today)
  {
   bool win = (net >= 0.0);
   if(today)
     {
      g_tradesToday++;
      g_pbTrades[pb]++;
      if(win)
         g_winsToday++;
      else
         g_lossesToday++;
     }
   g_lastCloseTime = NowServer();
   g_lastCloseWin  = win;
   if(win)
      g_lossStreak = 0;
   else
      g_lossStreak++;

   //--- learn the real commission from the deals
   if(volIn > 0.0)
     {
      double perLot = -comm / volIn;
      if(perLot > g_commPerLotRT + 0.01)
        {
         V10Log(1, StringFormat("Commission from real deals is %s per lot round trip (was %s) - using the higher value.",
                                FmtMoney(perLot), FmtMoney(g_commPerLotRT)));
         g_commPerLotRT = perLot;
        }
     }

   string held = (opened > 0 ? FormatDuration((long)(closed - opened)) : "?");
   g_lastAction = StringFormat("CLOSE %s %s net %s (%s) held %s", DirName(dir), PbName(pb), FmtMoney(net), why, held);
   V10Log(1, StringFormat("CLOSE %s %s #%I64u net %s (%s) held %s | today %s closed, %d trades W%d L%d | loss streak %d",
                          DirName(dir), PbName(pb), posId, FmtMoney(net), why, held,
                          FmtMoney(g_realizedToday), g_tradesToday, g_winsToday, g_lossesToday, g_lossStreak));

   GuardPush(pb, net);
   if(g_lossStreak >= InpStreakHalt)
      HaltDay(StringFormat("%d losses in a row", g_lossStreak), false);
   else if(g_lossStreak > 0 && g_lossStreak % InpStreakPause == 0)
      Pause(InpStreakPauseMin * 60, StringFormat("%d losses in a row", g_lossStreak));
  }

//+------------------------------------------------------------------+
//| Global entry gates (protection that does not depend on a signal) |
//+------------------------------------------------------------------+
bool GlobalGate(string &why)
  {
   datetime now = NowServer();
   if(g_haltKill)
     {
      why = "EQUITY KILL SWITCH - remove and re-attach the EA to reset";
      return false;
     }
   if(g_haltDay)
     {
      why = "halted for today: " + g_haltReason;
      return false;
     }
   if(now < g_pauseUntil)
     {
      why = StringFormat("paused %s more: %s", FormatDuration((long)(g_pauseUntil - now)), g_pauseReason);
      return false;
     }
   if(now < g_execPauseUntil)
     {
      why = StringFormat("execution back-off %s: %s", FormatDuration((long)(g_execPauseUntil - now)), g_execPauseReason);
      return false;
     }
   if(InpDailyProfitLock > 0.0 && DayNet() >= InpDailyProfitLock)
     {
      why = StringFormat("daily profit lock reached (%s)", FmtMoney(DayNet()));
      return false;
     }
   string nw = "";
   if(NewsWindow(now, nw))
     {
      why = "news window: " + nw;
      return false;
     }
   if(g_lastCloseTime > 0)
     {
      int  wait  = (g_lastCloseWin ? InpCooldownWinSec : InpCooldownLossSec);
      long since = (long)(now - g_lastCloseTime);
      if(since < wait)
        {
         why = StringFormat("cooldown after a %s (%I64d s)", (g_lastCloseWin ? "win" : "loss"), (long)wait - since);
         return false;
        }
     }
   if(EntriesLastHour() >= InpMaxTradesPerHour)
     {
      why = StringFormat("max %d trades per hour reached", InpMaxTradesPerHour);
      return false;
     }
   if(RequestsLastMinute() >= InpMaxRequestsPerMin)
     {
      why = StringFormat("max %d trade requests per minute reached", InpMaxRequestsPerMin);
      return false;
     }
   if(g_tradeEnabled && !g_isTester &&
      (TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) == 0 || MQLInfoInteger(MQL_TRADE_ALLOWED) == 0 ||
       AccountInfoInteger(ACCOUNT_TRADE_EXPERT) == 0 || AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) == 0))
     {
      why = "Algo Trading is switched off (terminal button, EA settings or account)";
      return false;
     }
   if(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
     {
      why = "the broker does not allow full trading on this symbol right now";
      return false;
     }
   return true;
  }

bool MarginOk(const int dir, const double lots, const double price, string &why)
  {
   double margin = 0.0;
   if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin))
     {
      why = "margin calculation failed";
      return false;
     }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double used   = AccountInfoDouble(ACCOUNT_MARGIN);
   double free   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > free)
     {
      why = StringFormat("not enough free margin (%s needed, %s free)", FmtMoney(margin), FmtMoney(free));
      return false;
     }
   double level = (used + margin > 0.0 ? equity / (used + margin) * 100.0 : 1.0e9);
   if(level < InpMinMarginLevel)
     {
      why = StringFormat("margin level would be %.0f%% (min %.0f%%)", level, InpMinMarginLevel);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Playbook setup trackers (updated on every new tick)              |
//+------------------------------------------------------------------+
//--- Trend Pullback: swing extreme -> pullback of 0.35-1.5 ATR -> re-break of the last N seconds
void TrackPullback(V10PbTrack &t, const int dir, const double b, const datetime now, const double atrPx)
  {
   t.fire = false;
   if(dir > 0)
     {
      if(!t.on || b > t.ext || (long)(now - t.extTime) > InpSwingWindowSec)
        {
         t.on      = true;
         t.ext     = b;
         t.extTime = now;
         t.counter = b;
        }
      else if(b < t.counter)
         t.counter = b;
      double depth = t.ext - t.counter;
      if(depth > InpPullbackMaxATR * atrPx)
        {
         t.ext     = b;                  // too deep: the trend is in doubt, wait for a new swing
         t.extTime = now;
         t.counter = b;
         return;
        }
      t.fire = (depth >= InpPullbackMinATR * atrPx && g_trigPrevOk &&
                b >= g_trigHiPrev + InpTriggerBufferPts * g_point && b < t.ext);
     }
   else
     {
      if(!t.on || b < t.ext || (long)(now - t.extTime) > InpSwingWindowSec)
        {
         t.on      = true;
         t.ext     = b;
         t.extTime = now;
         t.counter = b;
        }
      else if(b > t.counter)
         t.counter = b;
      double depth = t.counter - t.ext;
      if(depth > InpPullbackMaxATR * atrPx)
        {
         t.ext     = b;
         t.extTime = now;
         t.counter = b;
         return;
        }
      t.fire = (depth >= InpPullbackMinATR * atrPx && g_trigPrevOk &&
                b <= g_trigLoPrev - InpTriggerBufferPts * g_point && b > t.ext);
     }
  }

//--- Range Fade: poke outside the band -> come back inside by InpFadeRejectATR; a fast poke is a breakout
void TrackFade(V10FdTrack &t, const int dir, const double b, const double vel, const double atrPx)
  {
   t.fire = false;
   double band = (dir < 0 ? g_f.bandUp : g_f.bandLo);
   double mid  = g_f.bandMid;
   if(band <= 0.0 || mid <= 0.0)
      return;
   bool   outside  = (dir < 0 ? b > band : b < band);
   double push     = (dir < 0 ? vel : -vel) / atrPx;          // push toward the band, in ATR
   bool   rejected = (dir < 0 ? b <= band - InpFadeRejectATR * atrPx : b >= band + InpFadeRejectATR * atrPx);
   bool   atMid    = (dir < 0 ? b <= mid : b >= mid);
   if(outside)
     {
      if(!t.armed)
        {
         t.armed   = true;
         t.blocked = false;
         t.ext     = b;
         t.maxVel  = 0.0;
        }
      if(dir < 0 ? b > t.ext : b < t.ext)
         t.ext = b;
      if(push > t.maxVel)
         t.maxVel = push;
      if(t.maxVel > InpFadeMaxVelATR)
         t.blocked = true;
      return;
     }
   if(!t.armed)
      return;
   if(atMid)
     {
      t.armed   = false;                 // back at the middle without a signal: reset
      t.blocked = false;
      return;
     }
   if(rejected)
     {
      if(t.blocked)
        {
         t.armed   = false;
         t.blocked = false;
        }
      else
         t.fire = true;
     }
  }

//--- Trend Breakout: break of the M1 micro-range with speed, without chasing
void TrackBreakout(const int dir, const double b, const double vel, const double atrPx)
  {
   double buf   = InpBreakoutBufferPts * g_point;
   double chase = InpBreakoutMaxChaseATR * atrPx;
   double need  = InpBreakoutVelATR * atrPx;
   if(dir > 0)
      g_boFireBuy = (g_f.brkHigh > 0.0 && b >= g_f.brkHigh + buf && b - g_f.brkHigh <= chase &&
                     vel >= need && g_boBarBuy != g_lastM1Bar);
   else
      g_boFireSell = (g_f.brkLow > 0.0 && b <= g_f.brkLow - buf && g_f.brkLow - b <= chase &&
                      -vel >= need && g_boBarSell != g_lastM1Bar);
  }

void UpdateTrackers()
  {
   g_pbBuy.fire  = false;
   g_pbSell.fire = false;
   g_fdBuy.fire  = false;
   g_fdSell.fire = false;
   g_boFireBuy   = false;
   g_boFireSell  = false;
   if(!g_f.ready || !g_haveTick || g_f.atrPts <= 0.0)
      return;
   if(g_trackState != g_state)
     {
      ResetTrackers();
      g_trackState = g_state;
     }
   double   b     = g_last.bid;
   datetime now   = NowServer();
   double   atrPx = g_f.atrPts * g_point;
   double   vel   = (g_wVel.HasData() ? b - g_wVel.FirstBid() : 0.0);
   if(g_state == V10_ST_TREND_UP)
     {
      TrackPullback(g_pbBuy, 1, b, now, atrPx);
      TrackBreakout(1, b, vel, atrPx);
     }
   else if(g_state == V10_ST_TREND_DOWN)
     {
      TrackPullback(g_pbSell, -1, b, now, atrPx);
      TrackBreakout(-1, b, vel, atrPx);
     }
   else if(g_state == V10_ST_RANGE)
     {
      TrackFade(g_fdSell, -1, b, vel, atrPx);
      TrackFade(g_fdBuy, 1, b, vel, atrPx);
     }
  }

string TrackerText()
  {
   if(!g_f.ready || g_f.atrPts <= 0.0)
      return "Setups: waiting for data";
   double atrPx = g_f.atrPts * g_point;
   if(g_state == V10_ST_TREND_UP || g_state == V10_ST_TREND_DOWN)
     {
      bool   up    = (g_state == V10_ST_TREND_UP);
      double depth = 0.0;
      if(up && g_pbBuy.on)
         depth = (g_pbBuy.ext - g_pbBuy.counter) / atrPx;
      if(!up && g_pbSell.on)
         depth = (g_pbSell.counter - g_pbSell.ext) / atrPx;
      double lvl = (up ? g_f.brkHigh : g_f.brkLow);
      return StringFormat("Setups: pullback depth %.2f ATR (needs %.2f-%.2f)   |   breakout level %s",
                          depth, InpPullbackMinATR, InpPullbackMaxATR, FmtPrice(lvl));
     }
   if(g_state == V10_ST_RANGE)
     {
      string up = "watching upper band " + FmtPrice(g_f.bandUp);
      if(g_fdSell.armed)
         up = (g_fdSell.blocked ? "upper poke too fast (no fade)" : "upper band poked - waiting for rejection");
      string dn = "watching lower band " + FmtPrice(g_f.bandLo);
      if(g_fdBuy.armed)
         dn = (g_fdBuy.blocked ? "lower poke too fast (no fade)" : "lower band poked - waiting for rejection");
      return "Setups: " + up + "   |   " + dn;
     }
   return "Setups: none in state " + StateName(g_state);
  }

//--- pick at most one signal for this tick
bool PickSignal(V10Signal &sig)
  {
   sig.pb    = -1;
   sig.dir   = 0;
   sig.slPts = 0.0;
   sig.tpPts = 0.0;
   sig.why   = "";
   if(!g_f.ready || g_f.atrPts <= 0.0)
      return false;
   datetime now    = NowServer();
   double   atrPts = g_f.atrPts;
   double   atrPx  = atrPts * g_point;
   if(g_state == V10_ST_TREND_UP || g_state == V10_ST_TREND_DOWN)
     {
      int  dir    = (g_state == V10_ST_TREND_UP ? 1 : -1);
      bool pbFire = (dir > 0 ? g_pbBuy.fire : g_pbSell.fire);
      bool boFire = (dir > 0 ? g_boFireBuy : g_boFireSell);
      if(InpUsePullback && pbFire && now >= g_pbPauseUntil[V10_PB_PULLBACK])
        {
         double depth = (dir > 0 ? g_pbBuy.ext - g_pbBuy.counter : g_pbSell.counter - g_pbSell.ext) / atrPx;
         sig.pb    = V10_PB_PULLBACK;
         sig.dir   = dir;
         sig.slPts = InpSlATR * atrPts;
         sig.tpPts = InpTpATR * atrPts;
         sig.why   = StringFormat("pullback %.2f ATR then re-break of the last %d s", depth, InpTriggerWindowSec);
         return true;
        }
      if(InpUseBreakout && boFire && now >= g_pbPauseUntil[V10_PB_BREAKOUT])
        {
         sig.pb    = V10_PB_BREAKOUT;
         sig.dir   = dir;
         sig.slPts = InpSlATR * atrPts;
         sig.tpPts = InpTpATR * atrPts;
         sig.why   = StringFormat("break of the %d-bar %s %s", InpBreakoutBars, (dir > 0 ? "high" : "low"),
                                  FmtPrice(dir > 0 ? g_f.brkHigh : g_f.brkLow));
         return true;
        }
      return false;
     }
   if(g_state == V10_ST_RANGE && InpUseFade && now >= g_pbPauseUntil[V10_PB_FADE])
     {
      double maxSl = InpSlATR * atrPts;
      if(g_fdSell.fire)
        {
         double b = g_last.bid;
         sig.pb    = V10_PB_FADE;
         sig.dir   = -1;
         sig.slPts = MathMin((g_fdSell.ext - b) / g_point + CurrentSpreadPts() + InpTriggerBufferPts, maxSl);
         sig.tpPts = (b - g_f.bandMid) / g_point;
         sig.why   = StringFormat("upper band rejection, poke high %s, target middle %s", FmtPrice(g_fdSell.ext), FmtPrice(g_f.bandMid));
         return true;
        }
      if(g_fdBuy.fire)
        {
         double a = g_last.ask;
         sig.pb    = V10_PB_FADE;
         sig.dir   = 1;
         sig.slPts = MathMin((a - g_fdBuy.ext) / g_point + InpTriggerBufferPts, maxSl);
         sig.tpPts = (g_f.bandMid - a) / g_point;
         sig.why   = StringFormat("lower band rejection, poke low %s, target middle %s", FmtPrice(g_fdBuy.ext), FmtPrice(g_f.bandMid));
         return true;
        }
     }
   return false;
  }

//--- a decided signal is used once (traded, skipped or observed)
void ConsumeSignal(const V10Signal &sig)
  {
   if(sig.pb == V10_PB_PULLBACK)
     {
      if(sig.dir > 0)
        {
         g_pbBuy.on   = false;
         g_pbBuy.fire = false;
        }
      else
        {
         g_pbSell.on   = false;
         g_pbSell.fire = false;
        }
     }
   else if(sig.pb == V10_PB_BREAKOUT)
     {
      if(sig.dir > 0)
        {
         g_boBarBuy  = g_lastM1Bar;
         g_boFireBuy = false;
        }
      else
        {
         g_boBarSell  = g_lastM1Bar;
         g_boFireSell = false;
        }
     }
   else if(sig.pb == V10_PB_FADE)
     {
      if(sig.dir < 0)
        {
         g_fdSell.armed   = false;
         g_fdSell.blocked = false;
         g_fdSell.fire    = false;
        }
      else
        {
         g_fdBuy.armed   = false;
         g_fdBuy.blocked = false;
         g_fdBuy.fire    = false;
        }
     }
  }

//--- per-signal checks: position limits, stacking, spacing, money caps, open risk, margin
bool CheckSignal(V10Signal &sig, V10Plan &plan, string &why, bool &important)
  {
   important = false;
   int dirCount = (sig.dir > 0 ? g_posBuy : g_posSell);
   int oppCount = (sig.dir > 0 ? g_posSell : g_posBuy);
   if(oppCount > 0 && !AllLocked(-sig.dir))
     {
      why = "an open " + DirName(-sig.dir) + " is not locked yet (no self-hedging)";
      return false;
     }
   if(g_posCount >= InpMaxPositions)
     {
      why = StringFormat("max %d positions open", InpMaxPositions);
      return false;
     }
   if(dirCount >= InpMaxPerDirection)
     {
      why = StringFormat("max %d %s positions open", InpMaxPerDirection, DirName(sig.dir));
      return false;
     }
   if(dirCount > 0 && InpStackNeedsBE && !AllLocked(sig.dir))
     {
      why = "stacking needs the open trade locked at breakeven";
      return false;
     }
   double price = (sig.dir > 0 ? g_last.ask : g_last.bid);
   if(!SpacingOk(sig.dir, price))
     {
      why = StringFormat("closer than %d pts to an open %s", InpMinSpacingPts, DirName(sig.dir));
      return false;
     }
   double spreadPts = CurrentSpreadPts();
   double minSl     = MathMax((double)InpMinSlPts, g_stopsLevel + spreadPts + 1.0);
   if(sig.slPts < minSl)
      sig.slPts = minSl;
   important = true;                     // from here on, a skip says something about the settings
   if(g_stopsLevel > 0 && sig.tpPts + spreadPts < g_stopsLevel + 1.0)
     {
      why = "target inside the broker stops level";
      return false;
     }
   if(!BuildPlan(sig.slPts, sig.tpPts, plan))
     {
      why = plan.reason;
      return false;
     }
   if(g_openRisk + plan.slMoney > InpMaxOpenRisk + 1e-9)
     {
      why = StringFormat("open risk %s + %s > max %s", FmtMoney(g_openRisk), FmtMoney(plan.slMoney), FmtMoney(InpMaxOpenRisk));
      return false;
     }
   if(!MarginOk(sig.dir, plan.lots, price, why))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Executor                                                         |
//+------------------------------------------------------------------+

string RetcodeText(const uint rc)
  {
   switch(rc)
     {
      case TRADE_RETCODE_REQUOTE:
         return "requote";
      case TRADE_RETCODE_REJECT:
         return "rejected";
      case TRADE_RETCODE_DONE:
         return "done";
      case TRADE_RETCODE_DONE_PARTIAL:
         return "partially done";
      case TRADE_RETCODE_ERROR:
         return "processing error";
      case TRADE_RETCODE_TIMEOUT:
         return "timeout";
      case TRADE_RETCODE_INVALID:
         return "invalid request";
      case TRADE_RETCODE_INVALID_VOLUME:
         return "invalid volume";
      case TRADE_RETCODE_INVALID_PRICE:
         return "invalid price";
      case TRADE_RETCODE_INVALID_STOPS:
         return "invalid stops";
      case TRADE_RETCODE_TRADE_DISABLED:
         return "trade disabled";
      case TRADE_RETCODE_MARKET_CLOSED:
         return "market closed";
      case TRADE_RETCODE_NO_MONEY:
         return "not enough money";
      case TRADE_RETCODE_PRICE_CHANGED:
         return "price changed";
      case TRADE_RETCODE_PRICE_OFF:
         return "no quotes";
      case TRADE_RETCODE_TOO_MANY_REQUESTS:
         return "too many requests";
      case TRADE_RETCODE_NO_CHANGES:
         return "no changes";
      case TRADE_RETCODE_SERVER_DISABLES_AT:
         return "autotrading disabled by server";
      case TRADE_RETCODE_CLIENT_DISABLES_AT:
         return "autotrading disabled in the terminal";
      case TRADE_RETCODE_FROZEN:
         return "position frozen";
      case TRADE_RETCODE_INVALID_FILL:
         return "unsupported filling mode";
      case TRADE_RETCODE_CONNECTION:
         return "no connection";
      case TRADE_RETCODE_LIMIT_VOLUME:
         return "volume limit reached";
      case TRADE_RETCODE_POSITION_CLOSED:
         return "position already closed";
      case TRADE_RETCODE_LIMIT_POSITIONS:
         return "position limit reached";
     }
   return "code " + IntegerToString((long)rc);
  }

//--- live only: no quote for over a minute means the market is closed (weekend, daily break)
bool MarketQuiet()
  {
   if(g_isTester || !g_haveTick)
      return false;
   return (((long)GetMicrosecondCount() - g_lastTickUs) / 1000 > 60000);
  }

bool IsDone(const uint rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

bool IsPriceRetry(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF);
  }

//--- back off new entries after a failed open request
void BackOff(const uint rc)
  {
   int    sec    = 30;
   string reason = RetcodeText(rc);
   if(rc == TRADE_RETCODE_NO_MONEY || rc == TRADE_RETCODE_TRADE_DISABLED || rc == TRADE_RETCODE_LIMIT_VOLUME ||
      rc == TRADE_RETCODE_LIMIT_POSITIONS)
      sec = 300;
   else if(rc == TRADE_RETCODE_MARKET_CLOSED)
      sec = 60;
   else if(rc == TRADE_RETCODE_CONNECTION || rc == TRADE_RETCODE_TIMEOUT)
      sec = 10;
   g_failStreak++;
   if(g_failStreak >= 3 && sec < 120)
     {
      sec    = 120;
      reason = StringFormat("%d failed requests in a row (last: %s)", g_failStreak, reason);
     }
   ExecPause(sec, reason);
  }

//--- set the stop (and the target, if the position has none) on an open position
bool SendSLTP(const ulong ticket, const double sl, const double tp)
  {
   if(!g_tradeEnabled)
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = _Symbol;
   req.sl       = sl;
   req.tp       = tp;
   if(PositionSelectByTicket(ticket))
      req.magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   NoteRequest();
   bool sent = OrderSend(req, res);
   if(IsDone(res.retcode) || res.retcode == TRADE_RETCODE_NO_CHANGES)
      return true;
   V10Log(0, StringFormat("Set stop/target on #%I64u failed: %s (sent %s, sl %s, tp %s)",
                          ticket, RetcodeText(res.retcode), (sent ? "yes" : "no"), FmtPrice(sl), FmtPrice(tp)));
   return false;
  }

//--- close one own position at market; the reason is reported when the deal arrives
bool ClosePosition(const ulong ticket, const string reason)
  {
   if(!g_tradeEnabled)
      return false;
   if(!PositionSelectByTicket(ticket))
      return true;                       // already gone
   int    dir   = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
   double vol   = PositionGetDouble(POSITION_VOLUME);
   ulong  magic = (ulong)PositionGetInteger(POSITION_MAGIC);
   ulong  posId = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   TagClose(posId, reason);
   ENUM_ORDER_TYPE_FILLING filling = g_filling;
   int fillSwitches = 0;
   int priceRetries = 0;
   while(true)
     {
      MqlTick t;
      if(!SymbolInfoTick(_Symbol, t))
         return false;
      MqlTradeRequest req;
      MqlTradeResult  res;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = _Symbol;
      req.volume       = vol;
      req.type         = (dir > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
      req.price        = (dir > 0 ? t.bid : t.ask);
      req.deviation    = (ulong)MathMax(InpDeviationPts, 50);
      req.magic        = magic;
      req.comment      = InpComment + " " + reason;
      req.type_filling = filling;
      NoteRequest();
      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;
      if(IsDone(rc) || rc == TRADE_RETCODE_POSITION_CLOSED)
        {
         if(filling != g_filling)
            g_filling = filling;
         return true;
        }
      if(rc == TRADE_RETCODE_INVALID_FILL && fillSwitches < 2)
        {
         filling = NextFilling(filling);
         fillSwitches++;
         continue;
        }
      if(IsPriceRetry(rc) && priceRetries < InpMaxRetries + 1)
        {
         priceRetries++;
         continue;
        }
      V10Log(0, StringFormat("Close #%I64u (%s) failed: %s (sent %s)", ticket, reason, RetcodeText(rc), (sent ? "yes" : "no")));
      return false;
     }
   return false;
  }

//--- close every own position; returns the number of failed closes
int FlattenAll(const string reason)
  {
   if(!g_tradeEnabled || g_posCount == 0 || MarketQuiet())
      return 0;
   datetime now = NowServer();
   if(g_lastFlattenTry == now)
      return g_posCount;                 // at most one attempt per second
   g_lastFlattenTry = now;
   int failed = 0;
   for(int i = 0; i < g_posCount; i++)
      if(!ClosePosition(g_pos[i].ticket, reason))
         failed++;
   V10Log(1, StringFormat("FLATTEN (%s): %d position(s), %d failed", reason, g_posCount, failed));
   g_lastAction = StringFormat("FLATTEN %s (%d positions)", reason, g_posCount);
   ScanPositions();
   return failed;
  }

//--- every own position must carry a server-side stop
void ProtectPositions()
  {
   if(!g_tradeEnabled || MarketQuiet())
      return;
   datetime now     = NowServer();
   bool     changed = false;
   for(int i = 0; i < g_posCount; i++)
     {
      if(g_pos[i].sl > 0.0)
        {
         int kk = FindIntent(g_pos[i].id);
         if(kk >= 0)
            g_intents[kk].nakedSince = 0;
         continue;
        }
      int k = FindIntent(g_pos[i].id);
      if(k < 0)
        {
         //--- no remembered plan (e.g. after a restart): use the default distances
         double slPts = MathMax((double)InpMinSlPts, (g_f.ready ? InpSlATR * g_f.atrPts : 0.0));
         double tpPts = (g_f.ready ? InpTpATR * g_f.atrPts : 0.0);
         k = AddIntent(g_pos[i].id, slPts, tpPts, 0.0, g_pos[i].dir);
        }
      if(g_intents[k].nakedSince == 0)
         g_intents[k].nakedSince = now;
      if(g_intents[k].lastTry == now)
         continue;                       // one attempt per second per position
      int    dir  = g_pos[i].dir;
      double bid  = g_last.bid;
      double ask  = g_last.ask;
      double sl   = NormPrice(dir > 0 ? g_pos[i].open - g_intents[k].slPts * g_point : g_pos[i].open + g_intents[k].slPts * g_point);
      double tp   = 0.0;
      if(g_pos[i].tp > 0.0)
         tp = g_pos[i].tp;
      else if(g_intents[k].tpPts > 0.0)
         tp = NormPrice(dir > 0 ? g_pos[i].open + g_intents[k].tpPts * g_point : g_pos[i].open - g_intents[k].tpPts * g_point);
      double lvl  = (g_stopsLevel + 1) * g_point;
      bool   slOk = (dir > 0 ? bid - sl >= lvl : sl - ask >= lvl);
      bool   tpOk = (tp <= 0.0 || (dir > 0 ? tp - bid >= lvl : ask - tp >= lvl));
      string reason = "";
      if(!slOk)
         reason = "NO_STOP_AT_STOP";     // price is already at the planned stop
      else if(!tpOk)
         reason = "NO_STOP_AT_TARGET";   // price is already beyond the planned target
      else if(g_intents[k].attempts >= 3 || (long)(now - g_intents[k].nakedSince) >= 10)
         reason = "NO_STOP_TIMEOUT";
      if(reason != "")
        {
         V10Log(0, StringFormat("Position #%I64u has no stop - closing it (%s)", g_pos[i].ticket, reason));
         ClosePosition(g_pos[i].ticket, reason);
         changed = true;
         g_noStopToday++;
         if(g_noStopToday >= 2)
            HaltDay("the broker refused stop losses twice today", false);
         else
            ExecPause(1800, "a position had to be closed because its stop loss could not be set");
         continue;
        }
      g_intents[k].attempts++;
      g_intents[k].lastTry = now;
      if(SendSLTP(g_pos[i].ticket, sl, tp))
        {
         V10Log(1, StringFormat("Stop attached to #%I64u: sl %s tp %s", g_pos[i].ticket, FmtPrice(sl), FmtPrice(tp)));
         changed = true;
        }
     }
   if(changed)
      ScanPositions();
  }

//--- send a market order with the stop and target attached
bool OpenTrade(const V10Signal &sig, const V10Plan &plan)
  {
   if(!g_tradeEnabled)
      return false;
   int     dir       = sig.dir;
   double  atrPx     = g_f.atrPts * g_point;
   double  refPrice  = (dir > 0 ? g_last.ask : g_last.bid);
   bool    withStops = true;
   int     priceRetries = 0;
   int     stopFails    = 0;
   int     fillSwitches = 0;
   ENUM_ORDER_TYPE_FILLING filling = g_filling;
   MqlTradeResult res;
   ZeroMemory(res);
   double  price = refPrice;
   double  sl    = 0.0;
   double  tp    = 0.0;
   while(true)
     {
      price = (dir > 0 ? g_last.ask : g_last.bid);
      if(MathAbs(price - refPrice) > 0.25 * atrPx)
        {
         V10Log(1, StringFormat("OPEN %s %s cancelled: price moved %.0f pts while retrying",
                                DirName(dir), PbName(sig.pb), MathAbs(price - refPrice) / g_point));
         return false;
        }
      sl = NormPrice(dir > 0 ? price - plan.slPts * g_point : price + plan.slPts * g_point);
      tp = NormPrice(dir > 0 ? price + plan.tpPts * g_point : price - plan.tpPts * g_point);
      MqlTradeRequest req;
      ZeroMemory(req);
      ZeroMemory(res);
      req.action       = TRADE_ACTION_DEAL;
      req.symbol       = _Symbol;
      req.volume       = plan.lots;
      req.type         = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
      req.price        = price;
      req.sl           = (withStops ? sl : 0.0);
      req.tp           = (withStops ? tp : 0.0);
      req.deviation    = (ulong)InpDeviationPts;
      req.magic        = (ulong)PbMagic(sig.pb);
      req.comment      = InpComment + " " + PbShort(sig.pb);
      req.type_filling = filling;
      req.type_time    = ORDER_TIME_GTC;
      NoteRequest();
      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;
      if(IsDone(rc))
         break;
      if(rc == TRADE_RETCODE_INVALID_FILL && fillSwitches < 2)
        {
         filling = NextFilling(filling);
         fillSwitches++;
         continue;
        }
      if(IsPriceRetry(rc) && priceRetries < InpMaxRetries)
        {
         priceRetries++;
         RefreshTick();
         continue;
        }
      if(rc == TRADE_RETCODE_INVALID_STOPS && withStops)
        {
         stopFails++;
         if(stopFails == 1)
           {
            RefreshTick();               // fresh prices, same distances
            continue;
           }
         V10Log(0, "Broker rejected the stop on the order twice - opening without it and attaching it at once.");
         withStops = false;
         continue;
        }
      V10Log(0, StringFormat("OPEN %s %s failed: %s (sent %s) - entries paused", DirName(dir), PbName(sig.pb),
                             RetcodeText(rc), (sent ? "yes" : "no")));
      BackOff(rc);
      return false;
     }
   if(filling != g_filling)
     {
      V10Log(1, "Filling mode switched to " + FillingName(filling));
      g_filling = filling;
     }
   g_failStreak = 0;
   ulong posId = res.order;              // hedging: position identifier = opening order ticket
   AddIntent(posId, plan.slPts, plan.tpPts, price, dir);
   NoteEntry();
   double fill = (res.price > 0.0 ? res.price : price);
   g_lastAction = StringFormat("OPEN %s %s %.2f @ %s  SL %s  TP %s", DirName(dir), PbName(sig.pb), plan.lots,
                               FmtPrice(fill), FmtPrice(sl), FmtPrice(tp));
   V10Log(1, StringFormat("OPEN %s %s #%I64u %.2f lot @ %s | SL %s (%.0f pts, risk %s) TP %s (%.0f pts, net %s) RR %.2f | %s | state %s ATR %.0f spread %.0f",
                          DirName(dir), PbName(sig.pb), posId, plan.lots, FmtPrice(fill), FmtPrice(sl), plan.slPts,
                          FmtMoney(plan.slMoney), FmtPrice(tp), plan.tpPts, FmtMoney(plan.tpNet), plan.rr, sig.why,
                          StateName(g_state), g_f.atrPts, CurrentSpreadPts()));
   if(!withStops)
     {
      ScanPositions();
      ProtectPositions();               // attach the stop now; the position is closed if that fails
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Account-level protection and forced exits                        |
//+------------------------------------------------------------------+
string FlattenTimeReason(const datetime now)
  {
   MqlDateTime s;
   TimeToStruct(now, s);
   if(s.day_of_week == 0 || s.day_of_week == 6)
      return "";                         // market closed: nothing can be done
   int mod = s.hour * 60 + s.min;
   if(s.day_of_week == 5 && mod >= g_fridayFlattenMin)
      return "FRIDAY_FLATTEN";
   if(mod >= g_dailyFlattenMin)
      return "DAILY_FLATTEN";
   return "";
  }

void CheckProtection()
  {
   datetime now    = NowServer();
   double   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
      g_peakEquity = equity;
   if(!g_haltKill && g_peakEquity > 0.0 && equity <= g_peakEquity * (1.0 - InpEquityKillPct / 100.0))
     {
      g_haltKill = true;
      V10Log(0, StringFormat("EQUITY KILL SWITCH: equity %s is %.1f%% below its peak %s. v10 closes its positions and stops. Remove and re-attach the EA to reset.",
                             FmtMoney(equity), 100.0 * (1.0 - equity / g_peakEquity), FmtMoney(g_peakEquity)));
     }
   double dayNet = DayNet();
   if(!g_flattenDay && dayNet <= -InpDailyLossLimit)
      HaltDay(StringFormat("daily loss limit hit: %s (closed %s, open %s)", FmtMoney(dayNet),
                           FmtMoney(g_realizedToday), FmtMoney(g_floating)), true);
   if(g_posCount == 0)
      return;
   string why = "";
   string nw  = "";
   if(g_haltKill)
      why = "KILL_SWITCH";
   else if(g_flattenDay)
      why = "DAILY_LIMIT";
   else
     {
      why = FlattenTimeReason(now);
      if(why == "" && InpNewsFlatten && NewsWindow(now, nw))
         why = "NEWS";
     }
   if(why != "")
      FlattenAll(why);
  }

//+------------------------------------------------------------------+
//| Deal accounting                                                  |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong deal = trans.deal;
   if(deal == 0 || deal <= g_maxDealSeen)
      return;
   if(!HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   int              pb    = PbOfMagic(HistoryDealGetInteger(deal, DEAL_MAGIC));
   double           money = DealMoney(deal);
   datetime         dt    = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   ENUM_DEAL_ENTRY  entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   ulong            posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   ulong            order = (ulong)HistoryDealGetInteger(deal, DEAL_ORDER);
   double           fill  = HistoryDealGetDouble(deal, DEAL_PRICE);
   ENUM_DEAL_REASON rsn   = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
   bool             isOut = (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY);
   if(pb < 0 && !isOut)
      return;                            // not a v10 deal
   double   net    = 0.0;
   double   comm   = 0.0;
   double   volIn  = 0.0;
   double   volOut = 0.0;
   datetime opened = 0;
   int      dir    = 0;
   int      pbIn   = -1;
   if(isOut)
     {
      PositionHistory(posId, net, comm, volIn, volOut, opened, dir, pbIn);
      if(pb < 0)
         pb = pbIn;                      // e.g. closed by hand: that deal carries no magic
      if(pb < 0)
         return;                         // not a v10 position
     }
   g_maxDealSeen = deal;
   bool today = (dt >= g_dayStart);
   if(today)
     {
      g_realizedToday += money;
      g_pbNet[pb]     += money;
     }
   if(entry == DEAL_ENTRY_IN)
     {
      int k = FindIntent(order);
      if(k >= 0 && g_intents[k].reqPrice > 0.0)
        {
         double adverse = (g_intents[k].dir > 0 ? fill - g_intents[k].reqPrice : g_intents[k].reqPrice - fill) / g_point;
         SlipPush(MathMax(0.0, adverse));
         if(adverse >= 5.0)
            V10Log(1, StringFormat("Slippage %.0f pts on #%I64u (asked %s, filled %s)", adverse, order,
                                   FmtPrice(g_intents[k].reqPrice), FmtPrice(fill)));
        }
      return;
     }
   if(!isOut)
      return;
   if(volIn <= 0.0 || volOut < volIn - 1e-9)
      return;                            // partial close: the position is still open
   OnPositionClosed(pb, dir, posId, net, comm, volIn, opened, dt, CloseReasonText(rsn, posId), today);
  }

//+------------------------------------------------------------------+
//| Entry readiness: market conditions, then protection gates        |
//+------------------------------------------------------------------+
void UpdateReadiness()
  {
   g_readyNow  = false;
   g_entryOpen = false;
   string why  = "";
   if(!IsTradeable(g_state))
      g_readyReason = "state " + StateName(g_state);
   else if(!SessionOpen(NowServer(), why))
      g_readyReason = "session " + why;
   else if(CurrentSpreadPts() > InpMaxSpreadPts)
      g_readyReason = StringFormat("spread %.0f > max %d", CurrentSpreadPts(), InpMaxSpreadPts);
   else if(!g_isTester && g_haveTick && ((long)GetMicrosecondCount() - g_lastTickUs) / 1000 > InpMaxTickAgeMs)
      g_readyReason = StringFormat("quotes stale (%I64d ms)", ((long)GetMicrosecondCount() - g_lastTickUs) / 1000);
   else
     {
      g_readyNow    = true;
      g_readyReason = "ready";
     }
   if(!g_readyNow)
     {
      g_entryReason = g_readyReason;
      return;
     }
   if(!GlobalGate(why))
     {
      g_entryReason = why;
      return;
     }
   g_entryOpen   = true;
   g_entryReason = (g_tradeEnabled ? "open" : "open (no orders: " + g_tradeBlockMsg + ")");
  }

//--- evaluate the playbooks on a new tick and act on at most one signal
void TryEntry()
  {
   V10Signal sig;
   if(!PickSignal(sig))
      return;
   datetime now  = NowServer();
   string   desc = StringFormat("%s %s %s - %s", TimeToString(now, TIME_SECONDS), DirName(sig.dir), PbName(sig.pb), sig.why);
   if(!g_entryOpen)
     {
      g_lastSignal = desc + "  [blocked: " + g_entryReason + "]";
      if(InpLogLevel >= 2 && (long)(now - g_lastBlockLog) >= 10)
        {
         g_lastBlockLog = now;
         V10Log(2, "SIGNAL blocked: " + desc + " | " + g_entryReason);
        }
      return;                            // not consumed: checked again on the next tick
     }
   V10Plan plan;
   string  why       = "";
   bool    important = false;
   if(!CheckSignal(sig, plan, why, important))
     {
      g_lastSignal = desc + "  [skip: " + why + "]";
      if(important && (long)(now - g_lastSkipLog) >= 30)
        {
         string more = (g_skipsQuiet > 0 ? StringFormat(" (+%d similar skips not shown)", g_skipsQuiet) : "");
         V10Log(1, "SKIP " + desc + " | " + why + more);
         g_lastSkipLog = now;
         g_skipsQuiet  = 0;
        }
      else
        {
         if(important)
            g_skipsQuiet++;
         V10Log(2, "SKIP " + desc + " | " + why);
        }
      ConsumeSignal(sig);
      return;
     }
   if(!g_tradeEnabled)
     {
      g_lastSignal = desc + "  [observe: would trade]";
      V10Log(1, StringFormat("SIGNAL (no order: %s) %s | SL %.0f pts risk %s, TP %.0f pts net %s, RR %.2f",
                             g_tradeBlockMsg, desc, plan.slPts, FmtMoney(plan.slMoney), plan.tpPts,
                             FmtMoney(plan.tpNet), plan.rr));
      ConsumeSignal(sig);
      return;
     }
   g_lastSignal = desc;
   OpenTrade(sig, plan);
   ConsumeSignal(sig);
   ScanPositions();
  }

//+------------------------------------------------------------------+
//| Daily statistics                                                 |
//+------------------------------------------------------------------+
double TotalStateSecs()
  {
   double total = 0.0;
   for(int i = 0; i < V10_STATE_COUNT; i++)
      total += g_stateSecs[i];
   return total;
  }

string ShareText()
  {
   double total = TotalStateSecs();
   if(total <= 0.0)
      return "no data yet";
   return StringFormat("TU %.0f%%  TD %.0f%%  RG %.0f%%  UN %.0f%%  DE %.0f%%  VO %.0f%%  WU %.0f%%",
                       100.0 * g_stateSecs[(int)V10_ST_TREND_UP]   / total,
                       100.0 * g_stateSecs[(int)V10_ST_TREND_DOWN] / total,
                       100.0 * g_stateSecs[(int)V10_ST_RANGE]      / total,
                       100.0 * g_stateSecs[(int)V10_ST_UNCLEAR]    / total,
                       100.0 * g_stateSecs[(int)V10_ST_DEAD]       / total,
                       100.0 * g_stateSecs[(int)V10_ST_VOLATILE]   / total,
                       100.0 * g_stateSecs[(int)V10_ST_WARMUP]     / total);
  }

string PlaybookText()
  {
   string out = "";
   datetime now = NowServer();
   for(int pb = 0; pb < V10_PB_COUNT; pb++)
     {
      string paused = (now < g_pbPauseUntil[pb] ? " (paused)" : "");
      out += StringFormat("%s%s %d / %s%s", (pb > 0 ? "   |   " : ""), PbName(pb), g_pbTrades[pb], FmtMoney(g_pbNet[pb]), paused);
     }
   return out;
  }

void LogDaySummary()
  {
   double total = TotalStateSecs();
   if(g_dayKey == 0 || (total <= 0.0 && g_tradesToday == 0))
      return;
   double readyPct = (total > 0.0 ? 100.0 * g_readySecs / total : 0.0);
   V10Log(1, StringFormat("DAY %s | trades %d W%d L%d | net %s | %s | %s | ready %.0f%% | state changes %d | observed %s",
                          DayKeyText(g_dayKey), g_tradesToday, g_winsToday, g_lossesToday, FmtMoney(g_realizedToday),
                          PlaybookText(), ShareText(), readyPct, g_stateChanges, FormatDuration((long)total)));
  }

//--- attribute the time since the last call to the current state
void AccountStateTime(const datetime now)
  {
   if(g_lastAcct == 0 || now < g_lastAcct)
     {
      g_lastAcct = now;
      return;
     }
   long dt = (long)(now - g_lastAcct);
   if(dt <= 0)
      return;
   if(dt > 60)
      dt = 60;                           // ignore gaps (weekend, disconnect, no ticks)
   g_stateSecs[(int)g_state] += (double)dt;
   if(g_readyNow)
      g_readySecs += (double)dt;
   g_lastAcct = now;
  }

void CheckDayRollover(const datetime now)
  {
   int key = DayKey(now);
   if(key == g_dayKey)
      return;
   LogDaySummary();
   g_dayKey = key;
   ArrayInitialize(g_stateSecs, 0.0);
   g_readySecs    = 0.0;
   g_stateChanges = 0;
   ResetTradingDay(now);
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
string PanelName(const int i)
  {
   return V10_PREFIX + "P_" + IntegerToString(i);
  }

void PanelCreate()
  {
   string bg = V10_PREFIX + "P_BG";
   if(ObjectFind(0, bg) < 0 && ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 24);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 820);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, V10_PANEL_LINES * 16 + 12);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,28');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,80,100');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   for(int i = 0; i < V10_PANEL_LINES; i++)
     {
      string n = PanelName(i);
      if(ObjectFind(0, n) < 0 && ObjectCreate(0, n, OBJ_LABEL, 0, 0, 0))
        {
         ObjectSetInteger(0, n, OBJPROP_CORNER, CORNER_LEFT_UPPER);
         ObjectSetInteger(0, n, OBJPROP_XDISTANCE, 16);
         ObjectSetInteger(0, n, OBJPROP_YDISTANCE, 30 + i * 16);
         ObjectSetInteger(0, n, OBJPROP_FONTSIZE, 9);
         ObjectSetString(0, n, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, n, OBJPROP_COLOR, clrSilver);
         ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, n, OBJPROP_HIDDEN, true);
         ObjectSetString(0, n, OBJPROP_TEXT, " ");
        }
      g_panelText[i]  = "";
      g_panelColor[i] = clrNONE;
     }
   g_panelReady = true;
  }

void PanelLine(const int i, const string text, const color clr)
  {
   if(i < 0 || i >= V10_PANEL_LINES)
      return;
   string n = PanelName(i);
   if(text != g_panelText[i])
     {
      ObjectSetString(0, n, OBJPROP_TEXT, (text == "" ? " " : text));
      g_panelText[i] = text;
     }
   if(clr != g_panelColor[i])
     {
      ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
      g_panelColor[i] = clr;
     }
  }

void UpdatePanel(const bool force)
  {
   if(!g_drawObjects || !InpShowDashboard)
      return;
   long nowMs = (long)(GetMicrosecondCount() / 1000);
   if(!force && g_lastPanelMs > 0 && nowMs - g_lastPanelMs < 250)
      return;
   g_lastPanelMs = nowMs;
   if(!g_panelReady)
      PanelCreate();

   datetime now  = NowServer();
   double   sp   = CurrentSpreadPts();
   double   lots = (g_plan.lots > 0.0 ? g_plan.lots : NormalizeLotsDown(InpFixedLots));

   //--- 0-1: header
   string modeText = (g_tradeEnabled ? "TRADE - places real orders" : "NO ORDERS - " + g_tradeBlockMsg);
   PanelLine(0, StringFormat("GOLD REGIME SCALPER v10.00   build %s   |   %s", V10_BUILD, modeText), (g_tradeEnabled ? clrWhite : clrOrange));
   string ageText = "-";
   if(!g_isTester && g_haveTick)
      ageText = StringFormat("%I64d ms ago", ((long)GetMicrosecondCount() - g_lastTickUs) / 1000);
   PanelLine(1, StringFormat("%s   server %s   |   %.1f ticks/s   |   last tick %s   |   filling %s",
                             _Symbol, TimeToString(now, TIME_SECONDS), g_wRate.Count() / 10.0, ageText, FillingName(g_filling)), clrSilver);

   //--- 2-3: state
   string pend = "";
   if(g_pendingCount > 0)
      pend = StringFormat("   pending %s %d/%d", StateName(g_pending), g_pendingCount, InpConfirmBars);
   PanelLine(2, StringFormat("STATE  %-10s  for %s   |   last bar: %s%s", StateName(g_state),
                             FormatDuration((long)(now - g_stateSince)), StateName(g_rawState), pend), StateColor(g_state));
   if(VolatileActive())
      PanelLine(3, StringFormat("VOLATILE latch: %I64d s left  -  %s", (long)(g_volatileUntil - now), g_volatileReason), clrOrange);
   else
      PanelLine(3, "VOLATILE latch: off", clrGray);

   //--- 4-6: features
   if(g_f.ready)
     {
      PanelLine(4, StringFormat("ER(%d) %+.2f  [trend >= %.2f, range <= %.2f]   |   M5 slope %+.2f ATR  [trend >= %.2f]",
                                InpErBars, g_f.er, InpErTrend, InpErRange, g_f.slopeAtr, InpSlopeMinATR), clrSilver);
      string emaRel = (g_f.emaFast > g_f.emaSlow ? "above" : "below");
      PanelLine(5, StringFormat("M1 EMA%d %s EMA%d   |   bands %s / %s / %s   |   %d-bar range %s - %s",
                                InpEmaFast, emaRel, InpEmaSlow, FmtPrice(g_f.bandLo), FmtPrice(g_f.bandMid), FmtPrice(g_f.bandUp),
                                InpBreakoutBars, FmtPrice(g_f.brkLow), FmtPrice(g_f.brkHigh)), clrSilver);
      PanelLine(6, StringFormat("ATR(M1) %.0f pts = %s @ %.2f lot   |   baseline %.0f   ratio %.2f  [VOLATILE >= %.2f]",
                                g_f.atrPts, FmtMoney(g_atrMoney), lots, g_f.atrBasePts, g_f.atrRatio, InpVolSpikeRatio), clrSilver);
     }
   else
     {
      PanelLine(4, "Market data: " + g_dataReason, clrKhaki);
      PanelLine(5, " ", clrSilver);
      PanelLine(6, " ", clrSilver);
     }

   //--- 7-8: spread and shock
   string medText = (g_spreadCount >= V10_MIN_SPREAD_SAMPLES ? StringFormat("%.0f", g_spreadMedian) : "collecting");
   color  spClr   = (sp > InpMaxSpreadPts ? clrOrange : clrSilver);
   PanelLine(7, StringFormat("Spread %.0f pts   5-min median %s   [entry max %d, spike > %.1fx]   |   shock %.0f pts in %d s [VOLATILE at %.0f]",
                             sp, medText, InpMaxSpreadPts, InpSpreadSpikeRatio, g_shockRangePts, InpShockWindowSec,
                             InpShockATR * g_f.atrPts), spClr);

   //--- 8-9: trend trade plan preview
   if(g_f.ready)
     {
      string verdict = (g_plan.ok ? "FITS" : "SKIP: " + g_plan.reason);
      color  plClr   = (g_plan.ok ? clrLime : clrTomato);
      PanelLine(8, StringFormat("Trend plan @ %.2f lot:  stop %.0f pts -> loss %s (cap %s)   |   margin per trade %s",
                                g_plan.lots, g_plan.slPts, FmtMoney(g_plan.slMoney), FmtMoney(g_plan.cap), FmtMoney(g_marginPerTrade)), plClr);
      PanelLine(9, StringFormat("                      target %.0f pts -> net %s   RR %.2f   ->  %s",
                                g_plan.tpPts, FmtMoney(g_plan.tpNet), g_plan.rr, verdict), plClr);
     }
   else
     {
      PanelLine(8, "Trend plan: waiting for data", clrKhaki);
      PanelLine(9, " ", clrSilver);
     }

   //--- 10-11: session and news
   string sw    = "";
   bool   sOpen = SessionOpen(now, sw);
   PanelLine(10, StringFormat("Session %s   (entries %s-%s, Fri until %s, Mon +%d min)   |   flatten %s, Fri %s",
                              sw, MinToHHMM(g_tradeStartMin), MinToHHMM(g_tradeEndMin), MinToHHMM(g_fridayLastMin),
                              InpMondayDelayMin, MinToHHMM(g_dailyFlattenMin), MinToHHMM(g_fridayFlattenMin)), (sOpen ? clrSilver : clrOrange));
   string nw = "";
   if(NewsWindow(now, nw))
      PanelLine(11, "NEWS WINDOW: " + nw, clrOrange);
   else
      PanelLine(11, "News: " + g_newsStatus + (g_newsCount > 0 ? "   |   " + NextNewsText(now) : ""), clrSilver);

   //--- 12-15: entries, setups, last signal, last action
   if(g_entryOpen)
      PanelLine(12, "ENTRIES: OPEN - " + g_entryReason, clrLime);
   else
      PanelLine(12, "ENTRIES: BLOCKED - " + g_entryReason, clrOrange);
   PanelLine(13, TrackerText(), clrSilver);
   PanelLine(14, "Last signal: " + g_lastSignal, clrSilver);
   PanelLine(15, "Last action: " + g_lastAction, clrSilver);

   //--- 16-18: positions and today
   PanelLine(16, StringFormat("Positions %d (buy %d, sell %d)   floating %s   |   open risk %s / max %s",
                              g_posCount, g_posBuy, g_posSell, FmtMoney(g_floating), FmtMoney(g_openRisk), FmtMoney(InpMaxOpenRisk)),
             (g_posCount > 0 ? clrWhite : clrSilver));
   double dayNet = DayNet();
   string halt   = "";
   if(g_haltKill)
      halt = "   |   KILL SWITCH";
   else if(g_haltDay)
      halt = "   |   HALTED: " + g_haltReason;
   PanelLine(17, StringFormat("Today: closed %s   with open %s / limit -%s   |   trades %d  W%d L%d   |   loss streak %d%s",
                              FmtMoney(g_realizedToday), FmtMoney(dayNet), FmtMoney(InpDailyLossLimit), g_tradesToday,
                              g_winsToday, g_lossesToday, g_lossStreak, halt),
             (dayNet >= 0.0 ? clrLime : (g_haltDay || g_haltKill ? clrOrange : clrTomato)));
   PanelLine(18, "Playbooks today: " + PlaybookText(), clrSilver);

   //--- 19-21: state shares and account
   double total    = TotalStateSecs();
   double readyPct = (total > 0.0 ? 100.0 * g_readySecs / total : 0.0);
   PanelLine(19, "States today: " + ShareText(), clrSilver);
   PanelLine(20, StringFormat("Market ready %.0f%% of observed time   |   state changes %d   |   observed %s   |   trades last hour %d / %d",
                              readyPct, g_stateChanges, FormatDuration((long)total), EntriesLastHour(), InpMaxTradesPerHour), clrSilver);
   string acctType = (g_isHedging ? "hedging" : "NETTING");
   PanelLine(21, StringFormat("Account %s %s   equity %s (peak %s, kill at -%.1f%%)   |   commission %s/lot RT   |   magics %d-%d",
                              g_ccy, acctType, FmtMoney(AccountInfoDouble(ACCOUNT_EQUITY)), FmtMoney(g_peakEquity), InpEquityKillPct,
                              FmtMoney(g_commPerLotRT), InpMagicBase + 1, InpMagicBase + 3), clrGray);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Main cycle (OnTick and OnTimer)                                  |
//+------------------------------------------------------------------+
void Drive()
  {
   datetime now = NowServer();
   AccountStateTime(now);
   CheckDayRollover(now);
   SampleSpread();

   bool     newBar = false;
   datetime bar0   = iTime(_Symbol, PERIOD_M1, 0);
   if(bar0 > 0 && bar0 != g_lastM1Bar)
     {
      V10Features f;
      if(ComputeFeatures(1, f))
        {
         if(g_lastM1Bar == 0)
            SeedState();
         g_f         = f;
         g_lastM1Bar = bar0;
         newBar      = true;
         string why  = "";
         ENUM_V10_STATE raw = ClassifyBar(g_f, why);
         ApplyClassification(raw, why);
         if(InpLogLevel >= 2)
            V10Log(2, StringFormat("BAR %s | raw %s (%s) | ER %+.2f slope %+.2f | ATR %.0f ratio %.2f | spread ref %.0f",
                                   TimeToString(g_f.barTime, TIME_DATE | TIME_MINUTES), StateName(raw), why,
                                   g_f.er, g_f.slopeAtr, g_f.atrPts, g_f.atrRatio, SpreadRef()));
        }
     }

   CheckLiveOverrides();
   ResolveState();
   RefreshPlan(newBar);
   RefreshNews(false);

   //--- exits first: every position gets a stop, then account protection and forced closes
   ScanPositions();
   ProtectPositions();
   CheckProtection();

   //--- entries: at most one per new tick
   UpdateReadiness();
   if(g_newTick)
     {
      g_newTick = false;
      UpdateTrackers();
      TryEntry();
     }
   UpdatePanel(false);
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester    = (MQLInfoInteger(MQL_TESTER) != 0);
   g_drawObjects = (!g_isTester || MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   g_point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_ccy         = AccountInfoString(ACCOUNT_CURRENCY);
   if(g_point <= 0.0)
     {
      Print("[V10] ERROR: symbol point size is 0 - cannot run.");
      return INIT_FAILED;
     }

   string err = "";
   if(!ValidateInputs(err))
     {
      Print("[V10] INPUT ERROR: ", err);
      return INIT_PARAMETERS_INCORRECT;
     }

   g_isHedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!g_isHedging && InpMode == V10_MODE_TRADE)
     {
      Print("[V10] ERROR: v10 needs a hedging account (it can hold several positions). Use OBSERVE mode to watch states on this account.");
      return INIT_FAILED;
     }
   if(StringFind(_Symbol, "XAU") < 0)
      V10Log(0, "WARNING: v10 is built and calibrated for gold (XAU...). Current symbol: " + _Symbol);
   if(_Period != PERIOD_M1)
      V10Log(1, "Note: attach v10 to an M1 chart for the clearest state marks. Calculations always use M1 and M5.");

   ResetAll();
   g_commPerLotRT = InpCommissionPerLotRT;
   g_filling      = DetectFilling();
   g_stopsLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_peakEquity   = AccountInfoDouble(ACCOUNT_EQUITY);

   //--- may this instance send orders?
   bool isReal = ((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   g_tradeEnabled  = false;
   g_tradeBlockMsg = "";
   if(InpMode == V10_MODE_OBSERVE)
      g_tradeBlockMsg = "OBSERVE mode";
   else if(isReal && !g_isTester && !InpAllowRealAccount)
      g_tradeBlockMsg = "real-money account locked (set InpAllowRealAccount = true)";
   else
      g_tradeEnabled = true;

   if(!CreateHandles())
     {
      Print("[V10] ERROR: could not create indicator handles, error ", GetLastError());
      ReleaseHandles();
      return INIT_FAILED;
     }

   if(!g_isTester)
     {
      ObjectsDeleteAll(0, V10_PREFIX);
      if(!EventSetMillisecondTimer(250))
         EventSetTimer(1);
     }
   g_stateSince = NowServer();

   ENUM_SYMBOL_TRADE_EXECUTION exe = (ENUM_SYMBOL_TRADE_EXECUTION)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_EXEMODE);
   V10Log(1, StringFormat("Gold Regime Scalper v10.00 build %s | %s | %s %s account | %s | equity %s",
                          V10_BUILD, _Symbol, (isReal ? "REAL" : "demo/contest"), (g_isHedging ? "hedging" : "netting"),
                          g_ccy, FmtMoney(AccountInfoDouble(ACCOUNT_EQUITY))));
   if(g_tradeEnabled)
      V10Log(1, "TRADING ENABLED: v10 places orders. Every order carries a server-side stop loss and take profit.");
   else
      V10Log(1, "NO ORDERS: " + g_tradeBlockMsg + ". v10 shows states and signals only.");
   V10Log(1, StringFormat("Execution %s, filling %s, stops level %d pts, commission %s per lot round trip",
                          EnumToString(exe), FillingName(g_filling), g_stopsLevel, FmtMoney(g_commPerLotRT)));
   V10Log(1, StringFormat("Risk: max loss %s per trade, open risk %s, daily limit %s, kill switch -%.1f%% from peak, lot %.2f (%s)",
                          FmtMoney(InpMaxLossPerTrade), FmtMoney(InpMaxOpenRisk), FmtMoney(InpDailyLossLimit), InpEquityKillPct,
                          InpFixedLots, (InpLotMode == V10_LOT_FIXED ? "fixed" : "risk %")));
   V10Log(1, StringFormat("Rules: trend ER>=%.2f and M5 slope>=%.2f ATR | range ER<=%.2f | VOLATILE ATR>=%.2fx, shock %.1f ATR in %d s, spread>%.1fx median | DEAD ATR<%.1fx spread | confirm %d bars",
                          InpErTrend, InpSlopeMinATR, InpErRange, InpVolSpikeRatio, InpShockATR, InpShockWindowSec,
                          InpSpreadSpikeRatio, InpDeadAtrSpread, InpConfirmBars));
   if(g_isTester)
      V10Log(1, "Strategy Tester: the news filter is skipped (no economic calendar in the tester).");

   RefreshNews(true);
   if(RefreshTick())
      Drive();
   UpdatePanel(true);
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   LogDaySummary();
   ReleaseHandles();
   ObjectsDeleteAll(0, V10_PREFIX + "P_");
   if(!g_isTester)
      ObjectsDeleteAll(0, V10_PREFIX + "ST_");   // in the tester the marks stay for review
   ChartRedraw(0);
   if(g_posCount > 0)
      V10Log(1, StringFormat("Stopped with %d open position(s). They keep their server-side stop and target.", g_posCount));
   V10Log(1, StringFormat("Stopped (deinit reason %d).", reason));
  }

//+------------------------------------------------------------------+
//| Tick / timer                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(RefreshTick())
      Drive();
  }

void OnTimer()
  {
   RefreshTick();
   Drive();
  }
//+------------------------------------------------------------------+
