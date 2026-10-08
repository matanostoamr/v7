//+------------------------------------------------------------------+
//|                                Gold_Regime_Scalper_v10.00.mq5    |
//|        Gold Regime Scalper v10 - regime-adaptive XAUUSD scalper  |
//|                                                                  |
//|  BUILD R1 (Round 1 of 3)                                         |
//|  Market data, market-state engine, dashboard and chart marks.    |
//|  OBSERVE ONLY: this build contains no order code. It never       |
//|  sends, modifies or closes orders.                               |
//|                                                                  |
//|  Spec: docs/V10_SPEC.md                                          |
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "10.00"
#property description "Gold Regime Scalper v10 - build R1 (observe only)."
#property description "Market-state engine and dashboard. This build sends no orders."

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define V10_BUILD               "R1"
#define V10_TICKBUF             4096      // tick ring buffer size (power of two)
#define V10_TICKMASK            4095      // V10_TICKBUF - 1
#define V10_SPREAD_SAMPLES      300       // 5 minutes of 1-second spread samples
#define V10_SPREAD_BINS         1024      // spread histogram bins (points)
#define V10_MIN_SPREAD_SAMPLES  30        // samples needed before the median is trusted
#define V10_MAX_MARKS           1500      // max state marks kept on the chart
#define V10_PANEL_LINES         16
#define V10_STATE_COUNT         7
#define V10_RATE_WINDOW_MS      10000     // window for the ticks-per-second figure

const string V10_PREFIX = "V10_";        // prefix of every chart object created by v10

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_V10_MODE
  {
   V10_MODE_TRADE   = 0,   // TRADE (orders from Round 2)
   V10_MODE_OBSERVE = 1    // OBSERVE (states only, no orders)
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

input group "5. Trend playbooks [active from Round 2]"
input bool             InpUsePullback         = true;             // Use Trend Pullback
input int              InpSwingWindowSec      = 180;              // Window for the recent micro high/low (s)
input double           InpPullbackMinATR      = 0.35;             // Min pullback depth (ATR)
input double           InpPullbackMaxATR      = 1.50;             // Max pullback depth (ATR)
input int              InpTriggerWindowSec    = 8;                // Trigger: re-break of the last N seconds high/low
input int              InpTriggerBufferPts    = 3;                // Trigger buffer (points)
input bool             InpUseBreakout         = true;             // Use Trend Breakout
input int              InpBreakoutBars        = 10;               // Breakout: M1 micro-range bars
input int              InpBreakoutBufferPts   = 5;                // Breakout buffer (points)
input double           InpBreakoutVelATR      = 0.35;             // Breakout: min move (ATR) ...
input int              InpVelWindowSec        = 10;               // ... within this many seconds
input double           InpBreakoutMaxChaseATR = 0.40;             // Breakout: max distance past the level (ATR)

input group "6. Range playbook [active from Round 2]"
input bool             InpUseFade             = true;             // Use Range Fade
input int              InpBandPeriod          = 20;               // Bollinger period (M1)
input double           InpBandDev             = 2.0;              // Bollinger deviation
input double           InpFadeRejectATR       = 0.15;             // Must come back inside the band by (ATR)
input double           InpFadeMaxVelATR       = 0.60;             // Push faster than this (ATR per 10 s) = no fade

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

input group "9. Aggression and pacing [active from Round 2]"
input int              InpMaxPositions        = 4;                // Max open positions (total)
input int              InpMaxPerDirection     = 3;                // Max open positions per direction
input bool             InpStackNeedsBE        = true;             // Stack only when existing trades are locked
input int              InpMinSpacingPts       = 40;               // Min distance between stacked entries (points)
input int              InpCooldownWinSec      = 3;                // Re-entry delay after a win (s)
input int              InpCooldownLossSec     = 45;               // Re-entry delay after a loss (s)
input int              InpMaxTradesPerHour    = 40;               // Max new trades per hour
input int              InpMaxRequestsPerMin   = 20;               // Max trade requests per minute

input group "10. Capital protection [active from Round 2]"
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
input int              InpMaxAvgSlipPts       = 25;               // Pause if avg slippage of last 10 fills exceeds (points)
input double           InpMinMarginLevel      = 500.0;            // Min margin level for entries (%)

input group "11. Sessions and news (server time)"
input string           InpTradeStart          = "01:30";          // Entries from (HH:MM)
input string           InpTradeEnd            = "23:00";          // Entries until (HH:MM)
input string           InpDailyFlatten        = "23:30";          // Daily flatten time (HH:MM) [Round 2]
input int              InpMondayDelayMin      = 60;               // Monday: extra delay after the start time (min)
input string           InpFridayLastEntry     = "21:00";          // Friday: last entry (HH:MM)
input string           InpFridayFlatten       = "22:45";          // Friday: flatten time (HH:MM) [Round 2]
input bool             InpUseNews             = true;             // News filter, MT5 calendar [Round 2]
input string           InpNewsCurrencies      = "USD";            // News currencies (comma separated) [Round 2]
input int              InpNewsBeforeMin       = 10;               // No entries before news (min) [Round 2]
input int              InpNewsAfterMin        = 15;               // No entries after news (min) [Round 2]
input bool             InpNewsFlatten         = true;             // Close open trades when a news window starts [Round 2]

input group "12. Execution and display"
input int              InpDeviationPts        = 20;               // Max deviation, Instant execution only (points) [Round 2]
input int              InpMaxRetries          = 2;                // Order retries [Round 2]
input int              InpMaxTickAgeMs        = 2000;             // Quotes older than this are stale (ms)
input bool             InpShowDashboard       = true;             // Show dashboard
input bool             InpDrawStates          = true;             // Draw state-change marks on the chart
input bool             InpWriteCsv            = true;             // Per-trade CSV [Round 3]

//+------------------------------------------------------------------+
//| Environment                                                      |
//+------------------------------------------------------------------+
double   g_point       = 0.0;
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

//+------------------------------------------------------------------+
//| Tick store: ring buffer addressed by an ever-increasing sequence |
//+------------------------------------------------------------------+
long     g_tickSeq = -1;                 // sequence number of the newest stored tick
long     g_tickMsc[V10_TICKBUF];
double   g_tickBid[V10_TICKBUF];
double   g_tickAsk[V10_TICKBUF];
MqlTick  g_last;                          // latest quote
bool     g_haveTick   = false;
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
  };

V10Features g_f;
string      g_dataReason = "waiting for data";

//+------------------------------------------------------------------+
//| Trade plan preview (stop/target in money for the current ATR)    |
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

V10Plan  g_plan;
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
bool     g_readyNow     = false;
string   g_readyReason  = "";

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
      double perLot = PointsToMoney(p.slPts, 1.0) + InpCommissionPerLotRT;
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
   double comm    = InpCommissionPerLotRT * p.lots;
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
   if(!Need(InpMaxPositions >= 1 && InpMaxPerDirection >= 1 && InpMaxPerDirection <= InpMaxPositions, "Need 1 <= InpMaxPerDirection <= InpMaxPositions", err)) return false;
   if(!Need(InpMinSpacingPts >= 0 && InpCooldownWinSec >= 0 && InpCooldownLossSec >= 0, "Check the spacing / cooldown inputs", err)) return false;
   if(!Need(InpMaxTradesPerHour >= 1 && InpMaxRequestsPerMin >= 1, "Check the trade / request rate limits", err)) return false;
   if(!Need(InpMaxOpenRisk >= InpMaxLossPerTrade, "InpMaxOpenRisk must be >= InpMaxLossPerTrade", err)) return false;
   if(!Need(InpStreakPause >= 1 && InpStreakPauseMin >= 0 && InpStreakHalt > InpStreakPause, "Need InpStreakHalt > InpStreakPause >= 1", err)) return false;
   if(!Need(InpDailyLossLimit > 0.0 && InpDailyProfitLock >= 0.0, "Check the daily limits", err)) return false;
   if(!Need(InpEquityKillPct > 0.0 && InpEquityKillPct < 100.0, "InpEquityKillPct must be between 0 and 100", err)) return false;
   if(!Need(InpGuardTrades >= 2 && InpGuardPauseMin >= 0, "Check the playbook guard inputs", err)) return false;
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
   if(!Need(InpDeviationPts >= 0 && InpMaxRetries >= 0 && InpMaxTickAgeMs >= 100, "Check the execution inputs", err)) return false;
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
   return (g_hAtrM1 != INVALID_HANDLE && g_hAtrM5 != INVALID_HANDLE && g_hEmaFast != INVALID_HANDLE &&
           g_hEmaSlow != INVALID_HANDLE && g_hEmaM5 != INVALID_HANDLE);
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
  }

//+------------------------------------------------------------------+
//| Reset every runtime variable.                                    |
//| (EA globals survive a chart/parameter change, so OnInit must     |
//| reset them explicitly.)                                          |
//+------------------------------------------------------------------+
void ResetAll()
  {
   g_tickSeq = -1;
   ArrayInitialize(g_tickMsc, 0);
   ArrayInitialize(g_tickBid, 0.0);
   ArrayInitialize(g_tickAsk, 0.0);
   ZeroMemory(g_last);
   g_haveTick   = false;
   g_lastTickUs = 0;
   g_wShock.Init((long)InpShockWindowSec * 1000);
   g_wRate.Init(V10_RATE_WINDOW_MS);

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
      g_tickSeq++;
      int i = TickIdx(g_tickSeq);
      g_tickMsc[i] = t.time_msc;
      g_tickBid[i] = t.bid;
      g_tickAsk[i] = t.ask;
      g_wShock.Add(g_tickSeq);
      g_wRate.Add(g_tickSeq);
      g_lastTickUs = (long)GetMicrosecondCount();
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

   int    nCl = InpErBars + 1;
   double cl[];
   ArraySetAsSeries(cl, true);
   if(CopyClose(_Symbol, PERIOD_M1, shift, nCl, cl) != nCl)
     {
      g_dataReason = "loading M1 closes";
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

   f.barTime    = bt[0];
   f.atrPts     = atr[0] / g_point;
   f.atrBasePts = (sum / n) / g_point;
   f.atrRatio   = (f.atrBasePts > 0.0 ? f.atrPts / f.atrBasePts : 0.0);
   f.atrM5      = a5[0];
   f.emaFast    = ef[0];
   f.emaSlow    = es[0];
   f.slopeAtr   = (em[0] - em[InpSlopeBars]) / a5[0];
   f.er         = (path > 0.0 ? (cl[0] - cl[InpErBars]) / path : 0.0);
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
//| Session window and entry readiness (preview of the Round 2 gate) |
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

void UpdateReadiness()
  {
   g_readyNow = false;
   if(!IsTradeable(g_state))
     {
      g_readyReason = "state " + StateName(g_state);
      return;
     }
   string why = "";
   if(!SessionOpen(NowServer(), why))
     {
      g_readyReason = "session " + why;
      return;
     }
   double sp = CurrentSpreadPts();
   if(sp > InpMaxSpreadPts)
     {
      g_readyReason = StringFormat("spread %.0f > max %d", sp, InpMaxSpreadPts);
      return;
     }
   if(!g_isTester && g_haveTick)
     {
      long ageMs = ((long)GetMicrosecondCount() - g_lastTickUs) / 1000;
      if(ageMs > InpMaxTickAgeMs)
        {
         g_readyReason = StringFormat("quotes stale (%I64d ms)", ageMs);
         return;
        }
     }
   if(!g_plan.ok)
     {
      g_readyReason = "plan: " + g_plan.reason;
      return;
     }
   g_readyNow    = true;
   g_readyReason = "ready";
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

void LogDaySummary()
  {
   double total = TotalStateSecs();
   if(total <= 0.0 || g_dayKey == 0)
      return;
   V10Log(1, StringFormat("DAY %s | %s | ready %.0f%% | state changes %d | observed %s",
                          DayKeyText(g_dayKey), ShareText(), 100.0 * g_readySecs / total, g_stateChanges,
                          FormatDuration((long)total)));
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
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 780);
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
   string modeText = (InpMode == V10_MODE_OBSERVE ? "OBSERVE" : "OBSERVE (TRADE mode starts in Round 2)");
   PanelLine(0, StringFormat("GOLD REGIME SCALPER v10.00   build %s   |   %s", V10_BUILD, modeText), clrWhite);
   string ageText = "-";
   if(!g_isTester && g_haveTick)
      ageText = StringFormat("%I64d ms ago", ((long)GetMicrosecondCount() - g_lastTickUs) / 1000);
   PanelLine(1, StringFormat("%s   server %s   |   %.1f ticks/s   |   last tick %s",
                             _Symbol, TimeToString(now, TIME_SECONDS), g_wRate.Count() / 10.0, ageText), clrSilver);

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
      PanelLine(5, StringFormat("M1 EMA%d %s EMA%d   |   M5 EMA%d slope over %d bars   |   M5 ATR %.2f",
                                InpEmaFast, emaRel, InpEmaSlow, InpEmaTrendM5, InpSlopeBars, g_f.atrM5), clrSilver);
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
   PanelLine(7, StringFormat("Spread %.0f pts   5-min median %s   [entry max %d, spike > %.1fx]   DEAD if ATR < %.0f",
                             sp, medText, InpMaxSpreadPts, InpSpreadSpikeRatio, InpDeadAtrSpread * SpreadRef()), spClr);
   PanelLine(8, StringFormat("Shock: %.0f pts range in the last %d s   [VOLATILE at %.0f = %.1f x ATR]",
                             g_shockRangePts, InpShockWindowSec, InpShockATR * g_f.atrPts, InpShockATR), clrSilver);

   //--- 9-10: trade plan preview
   if(g_f.ready)
     {
      string verdict = (g_plan.ok ? "FITS" : "SKIP: " + g_plan.reason);
      color  plClr   = (g_plan.ok ? clrLime : clrTomato);
      PanelLine(9, StringFormat("Trade plan @ %.2f lot:  stop %.0f pts -> loss %s  (cap %s)",
                                g_plan.lots, g_plan.slPts, FmtMoney(g_plan.slMoney), FmtMoney(g_plan.cap)), plClr);
      PanelLine(10, StringFormat("                      target %.0f pts -> net %s   RR %.2f   ->  %s",
                                 g_plan.tpPts, FmtMoney(g_plan.tpNet), g_plan.rr, verdict), plClr);
     }
   else
     {
      PanelLine(9, "Trade plan: waiting for data", clrKhaki);
      PanelLine(10, " ", clrSilver);
     }

   //--- 11-12: session and readiness
   string sw    = "";
   bool   sOpen = SessionOpen(now, sw);
   color  ssClr = (sOpen ? clrSilver : clrOrange);
   PanelLine(11, StringFormat("Session %s   (entries %s-%s server time, Fri until %s, Mon +%d min)",
                              sw, MinToHHMM(g_tradeStartMin), MinToHHMM(g_tradeEndMin), MinToHHMM(g_fridayLastMin),
                              InpMondayDelayMin), ssClr);
   if(g_readyNow)
      PanelLine(12, "ENTRY READINESS: READY  (the playbooks that place entries arrive in Round 2)", clrLime);
   else
      PanelLine(12, "ENTRY READINESS: BLOCKED - " + g_readyReason, clrOrange);

   //--- 13-15: today
   double total    = TotalStateSecs();
   double readyPct = (total > 0.0 ? 100.0 * g_readySecs / total : 0.0);
   PanelLine(13, "Today: " + ShareText(), clrSilver);
   PanelLine(14, StringFormat("Ready %.0f%% of observed time   |   state changes %d   |   observed %s",
                              readyPct, g_stateChanges, FormatDuration((long)total)), clrSilver);
   string acctType = (g_isHedging ? "hedging" : "NETTING");
   PanelLine(15, StringFormat("Account %s %s   equity %s   |   magics %d-%d   |   log level %d",
                              g_ccy, acctType, FmtMoney(AccountInfoDouble(ACCOUNT_EQUITY)),
                              InpMagicBase + 1, InpMagicBase + 3, InpLogLevel), clrGray);
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
   UpdateReadiness();
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
   if(!g_isHedging)
     {
      if(InpMode == V10_MODE_TRADE)
        {
         Print("[V10] ERROR: v10 needs a hedging account (it stacks positions). Use OBSERVE mode to watch states on this account.");
         return INIT_FAILED;
        }
      V10Log(0, "WARNING: netting account - OBSERVE only.");
     }
   if(StringFind(_Symbol, "XAU") < 0)
      V10Log(0, "WARNING: v10 is built and calibrated for gold (XAU...). Current symbol: " + _Symbol);
   if(_Period != PERIOD_M1)
      V10Log(1, "Note: attach v10 to an M1 chart for the clearest state marks. Calculations always use M1 and M5.");

   ResetAll();
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

   V10Log(1, StringFormat("Gold Regime Scalper v10.00 build %s | %s | %s | %s | equity %s",
                          V10_BUILD, _Symbol, g_ccy, (g_isHedging ? "hedging" : "netting"),
                          FmtMoney(AccountInfoDouble(ACCOUNT_EQUITY))));
   V10Log(1, "Round 1 build: market-state engine and dashboard only. This build sends NO orders.");
   if(InpMode == V10_MODE_TRADE)
      V10Log(1, "Mode TRADE selected: order code arrives in Round 2, so v10 only observes for now.");
   V10Log(1, StringFormat("Rules: trend ER>=%.2f and M5 slope>=%.2f ATR | range ER<=%.2f | VOLATILE ATR>=%.2fx, shock %.1f ATR in %d s, spread>%.1fx median | DEAD ATR<%.1fx spread | confirm %d bars",
                          InpErTrend, InpSlopeMinATR, InpErRange, InpVolSpikeRatio, InpShockATR, InpShockWindowSec,
                          InpSpreadSpikeRatio, InpDeadAtrSpread, InpConfirmBars));

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
