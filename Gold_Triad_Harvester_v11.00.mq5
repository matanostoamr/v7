//+------------------------------------------------------------------+
//|                               Gold_Triad_Harvester_v11.00.mq5    |
//|        Gold Triad Harvester v11 - 3-trade harvesting basket      |
//|                                                                  |
//|  Up to 3 trades. The basket follows the market direction:        |
//|    UP      = 2 BUY + 1 SELL                                      |
//|    DOWN    = 1 BUY + 2 SELL                                      |
//|    NEUTRAL = 1 BUY + 1 SELL (the third slot waits)               |
//|  Every trade is harvested at a fixed net profit. The close and   |
//|  its replacement are sent together ("swap"), one swap at a time. |
//|  Harvest profit goes into the Harvest Bank, which pays for       |
//|  re-anchoring trades that are stuck far from the price.          |
//|                                                                  |
//|  Spec: docs/V11_SPEC.md                                          |
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "11.00"
#property description "Gold Triad Harvester v11 - 3-trade harvesting basket for XAUUSD."
#property description "Swap harvesting, Harvest Bank re-anchoring, basket protection."

//+------------------------------------------------------------------+
//| Constants                                                        |
//+------------------------------------------------------------------+
#define V11_BUILD               "1.1"
#define V11_TICKBUF             4096      // tick ring buffer size (power of two)
#define V11_TICKMASK            4095      // V11_TICKBUF - 1
#define V11_SPREAD_SAMPLES      300       // 5 minutes of 1-second spread samples
#define V11_SPREAD_BINS         1024      // spread histogram bins (points)
#define V11_MIN_SPREAD_SAMPLES  30        // samples needed before the median is trusted
#define V11_MAX_POS             12        // basket positions tracked (3 normal, extras tolerated)
#define V11_MAX_NEWS            64        // cached high-impact events
#define V11_TIME_RING           512       // ring size for request timestamps
#define V11_TAGS                32        // remembered reasons for closes sent by the EA
#define V11_HOLES               8         // remembered empty-slot start times (gap meter)
#define V11_PANEL_LINES         18
#define V11_SEED_BARS           40        // closed M1 bars replayed at start to set the direction
#define V11_RATE_WINDOW_MS      10000     // window for the ticks-per-second figure
#define V11_TR_TIMEOUT_MS       15000     // a swap that has not settled by then is reconciled
#define V11_REANCHOR_GAP_SEC    10        // minimum time between two re-anchors

//--- transition (swap) kinds
#define V11_TR_NONE             0
#define V11_TR_FILL             1         // open only: start pair, third slot, waiting slot
#define V11_TR_HARVEST          2         // close a winner (+ its replacement)
#define V11_TR_REANCHOR         3         // close a stuck trade (+ its replacement)

//--- request states inside a transition
#define V11_ST_TODO             0         // not sent yet
#define V11_ST_SENT             1         // sent, waiting for the server
#define V11_ST_ACCEPTED         2         // server done, waiting to see it in the position list
#define V11_ST_DONE             3         // confirmed
#define V11_ST_FAILED           4         // gave up

//--- dispatch results
#define V11_SEND_FAIL           0
#define V11_SEND_PENDING        1
#define V11_SEND_DONE           2

const string V11_PREFIX = "V11_";        // prefix of every chart object created by v11

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_V11_MODE
  {
   V11_MODE_TRADE   = 0,   // TRADE (places orders)
   V11_MODE_OBSERVE = 1    // OBSERVE (shows the plan, no orders)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "1. General"
input ENUM_V11_MODE InpMode               = V11_MODE_TRADE;   // Mode
input long          InpMagic              = 110001;           // Magic number (all v11 trades)
input string        InpComment            = "V11";            // Order comment prefix
input bool          InpAllowRealAccount   = false;            // Allow TRADE mode on a real-money account
input int           InpLogLevel           = 1;                // Log level (0 errors, 1 events, 2 debug)

input group "2. Harvest"
input double        InpLots               = 0.01;             // Lot size of every trade
input double        InpHarvestNet         = 0.50;             // Harvest a trade at this net profit (account ccy)
input double        InpBackupTpNet        = 0.80;             // Backup TP on the server at this net profit
input double        InpCommissionPerLotRT = 4.00;             // Commission per 1.00 lot round trip (account ccy)
input bool          InpUseAsync           = true;             // Send the close and its replacement together (async)

input group "3. Pulse (market direction)"
input double        InpPulseOn            = 40.0;             // Score for UP or DOWN (0-100)
input double        InpPulseOff           = 15.0;             // Score within +/- this = trend gone (NEUTRAL)
input int           InpPulseConfirmBars   = 2;                // Closed M1 bars needed to change direction
input int           InpAtrPeriod          = 14;               // ATR period (M1 and M5)
input int           InpEmaFast            = 9;                // M1 fast EMA
input int           InpEmaSlow            = 21;               // M1 slow EMA
input int           InpEmaTrendM5         = 50;               // M5 trend EMA
input int           InpSlopeBars          = 3;                // M5 bars used for the EMA slope
input double        InpSlopeFullATR       = 0.30;             // M5 EMA slope (in M5 ATR) that counts as a full trend
input int           InpErBars             = 10;               // Efficiency Ratio window (M1 bars)

input group "4. Re-anchor (Harvest Bank)"
input bool          InpUseReanchor        = true;             // Re-anchor stuck trades with bank money
input double        InpReanchorLoss       = 1.50;             // A trade is stuck at this net loss
input double        InpBankKeep           = 0.50;             // The bank must keep at least this after paying
input bool          InpResetBank          = false;            // Reset the bank to 0 at start

input group "5. Entry gate"
input int           InpMaxSpreadPts       = 30;               // Max spread for new trades (points)
input double        InpSpreadSpikeRatio   = 1.8;              // No new trades if spread > ratio x 5-min median
input double        InpShockATR           = 3.0;              // Shock: price range >= this x ATR(M1) ...
input int           InpShockWindowSec     = 20;               // ... within this many seconds
input int           InpShockPauseSec      = 120;              // No new trades for this long after a shock (s)
input int           InpMaxTickAgeMs       = 2000;             // Quotes older than this are stale (ms)
input double        InpMinMarginLevel     = 150.0;            // Min margin level after a new trade (%)
input string        InpTradeStart         = "01:30";          // New trades from (HH:MM, server time)
input string        InpTradeEnd           = "23:00";          // New trades until (HH:MM, server time)
input int           InpMondayDelayMin     = 60;               // Monday: extra delay after the start time (min)
input bool          InpUseNews            = true;             // News filter (MT5 calendar, live only)
input string        InpNewsCurrencies     = "USD";            // News currencies (comma separated)
input int           InpNewsBeforeMin      = 10;               // No new trades before high-impact news (min)
input int           InpNewsAfterMin       = 15;               // No new trades after high-impact news (min)

input group "6. Protection"
input double        InpDisasterLoss       = 25.00;            // Server stop on every trade at this loss
input double        InpBasketStop         = 25.00;            // Close all when the open trades together lose this
input int           InpBasketCooldownMin  = 60;               // Wait after a basket stop before a new cycle (min)
input double        InpDailyLossLimit     = 50.00;            // Close all and stop for the day at this loss
input string        InpFridayLastEntry    = "21:00";          // Friday: last new trade (HH:MM)
input string        InpFridayFlatten      = "22:45";          // Friday: close all (HH:MM)
input double        InpEquityKillPct      = 10.0;             // Stop if equity falls this % below its peak
input bool          InpResetKillSwitch    = false;            // Reset the equity kill switch at start

input group "7. Execution and display"
input int           InpDeviationPts       = 20;               // Max deviation, Instant execution only (points)
input int           InpMaxRetries         = 2;                // Retries for a failed request
input int           InpMaxRequestsPerMin  = 60;               // Max trade requests per minute
input bool          InpShowDashboard      = true;             // Show dashboard
input bool          InpWriteCsv           = true;             // Event CSV in Common\Files

//+------------------------------------------------------------------+
//| Environment                                                      |
//+------------------------------------------------------------------+
double   g_point       = 0.0;
double   g_tickSize    = 0.0;
string   g_ccy         = "";
bool     g_isTester    = false;
bool     g_isOptim     = false;
bool     g_drawObjects = true;
bool     g_isHedging   = false;
double   g_lots        = 0.0;            // InpLots checked against the broker volume rules

//--- parsed session times (minutes after midnight, server time)
int      g_tradeStartMin    = 0;
int      g_tradeEndMin      = 0;
int      g_fridayLastMin    = 0;
int      g_fridayFlattenMin = 0;

//--- indicator handles
int      g_hAtrM1   = INVALID_HANDLE;
int      g_hAtrM5   = INVALID_HANDLE;
int      g_hEmaFast = INVALID_HANDLE;
int      g_hEmaSlow = INVALID_HANDLE;
int      g_hEmaM5   = INVALID_HANDLE;

//--- execution settings
ENUM_ORDER_TYPE_FILLING g_filling = ORDER_FILLING_FOK;
double   g_commPerLotRT  = 0.0;          // commission per 1.00 lot round trip (raised if deals show more)
int      g_stopsLevel    = 0;            // broker stops level (points)
bool     g_stopsOnOpen   = true;         // SL/TP sent with the market order (false after the broker rejects it)
bool     g_tradeEnabled  = false;        // TRADE mode, hedging account, real-account interlock passed
string   g_tradeBlockMsg = "";

//+------------------------------------------------------------------+
//| Tick store: ring buffer addressed by an ever-increasing sequence |
//+------------------------------------------------------------------+
long     g_tickSeq = -1;
long     g_tickMsc[V11_TICKBUF];
double   g_tickBid[V11_TICKBUF];
MqlTick  g_last;
bool     g_haveTick   = false;
long     g_lastTickUs = 0;               // local receipt time of the last new tick (us)

int TickIdx(const long seq)
  {
   return (int)(seq & V11_TICKMASK);
  }

long TickOldestSeq()
  {
   long oldest = g_tickSeq - V11_TICKBUF + 1;
   return (oldest > 0 ? oldest : 0);
  }

//+------------------------------------------------------------------+
//| Sliding time window over the tick store (bid high/low in O(1)).  |
//+------------------------------------------------------------------+
class CTickWindow
  {
private:
   long              m_spanMs;
   long              m_maxQ[V11_TICKBUF];
   long              m_minQ[V11_TICKBUF];
   long              m_maxHead;
   long              m_maxTail;
   long              m_minHead;
   long              m_minTail;
   long              m_first;
   long              m_last;

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

   void              Add(const long seq)
     {
      long newestMsc  = g_tickMsc[TickIdx(seq)];
      long oldestKept = TickOldestSeq();
      if(m_first < 0)
         m_first = seq;
      while(m_first < seq && (m_first < oldestKept || g_tickMsc[TickIdx(m_first)] < newestMsc - m_spanMs))
         m_first++;
      while(m_maxTail > m_maxHead && m_maxQ[TickIdx(m_maxHead)] < m_first)
         m_maxHead++;
      while(m_minTail > m_minHead && m_minQ[TickIdx(m_minHead)] < m_first)
         m_minHead++;
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
  };

CTickWindow g_wShock;                     // shock detector window
CTickWindow g_wRate;                      // ticks-per-second window

//+------------------------------------------------------------------+
//| Spread statistics: 1-second samples, rolling 5-minute median     |
//+------------------------------------------------------------------+
int      g_spreadRing[V11_SPREAD_SAMPLES];
int      g_spreadHist[V11_SPREAD_BINS];
int      g_spreadHead       = -1;
int      g_spreadCount      = 0;
datetime g_lastSpreadSample = 0;
double   g_spreadMedian     = 0.0;

//+------------------------------------------------------------------+
//| Pulse: market direction from closed bars                         |
//+------------------------------------------------------------------+
struct V11Pulse
  {
   bool              ready;
   datetime          barTime;            // open time of the evaluated M1 bar
   double            atrPts;             // ATR(M1) in points
   double            t;                  // M5 trend component, -1..+1
   double            e;                  // M1 EMA component, -1..+1
   double            s;                  // M1 structure component, -1..+1
   double            m;                  // Efficiency Ratio component, -1..+1
   double            score;              // -100..+100
  };

V11Pulse g_p;
int      g_bias       = 0;               // +1 UP, -1 DOWN, 0 NEUTRAL
int      g_candidate  = 0;               // direction waiting for confirmation
int      g_candCount  = 0;               // bars it has held (0 = no candidate)
datetime g_biasSince  = 0;
datetime g_lastM1Bar  = 0;
string   g_dataReason = "waiting for data";

//+------------------------------------------------------------------+
//| Basket                                                           |
//+------------------------------------------------------------------+
struct V11Pos
  {
   ulong             ticket;
   int               dir;                // +1 BUY, -1 SELL
   double            vol;
   double            open;
   double            sl;
   double            tp;
   double            net;                // net if closed now: profit + swap - round-trip commission
   datetime          opened;
   bool              closing;            // a close for it is in flight
  };

struct V11Plan
  {
   int               n;
   int               dir[3];
  };

V11Pos   g_pos[V11_MAX_POS];
int      g_posCount   = 0;
int      g_nb         = 0;               // BUYs that are not closing
int      g_ns         = 0;               // SELLs that are not closing
double   g_floating   = 0.0;             // sum of the nets of all basket positions
ulong    g_known[V11_MAX_POS];           // tickets seen by the previous scan
int      g_knownCount = 0;

//+------------------------------------------------------------------+
//| Transition (swap): at most one in flight                         |
//+------------------------------------------------------------------+
struct V11Open
  {
   int               dir;
   int               state;
   uint              reqId;
   ulong             ticket;
   int               attempts;
   int               fillSwitches;
   long              inMsc;              // fill time from the deal (0 = unknown)
   long              holeMsc;            // start of the empty slot it fills (0 = none)
  };

struct V11Tr
  {
   int               kind;
   int               seq;
   long              startMs;            // ClockMs() when started
   ulong             closeTicket;        // 0 = no close
   int               closeState;
   uint              closeReqId;
   int               closeAttempts;
   int               closeFillSwitches;
   long              closeMsc;           // close time from the deal (0 = unknown)
   double            closeNet;           // planned net of the close
   int               nOpen;
   V11Open           open[3];
   long              settledMs;          // ClockMs() when everything was seen (0 = not yet)
  };

V11Tr    g_tr;
int      g_trSeq          = 0;
string   g_trWhy          = "";
ulong    g_trBefore[V11_MAX_POS];        // basket tickets when the transition started
int      g_trBeforeCount  = 0;

//+------------------------------------------------------------------+
//| Accounting, Harvest Bank and gap meter                           |
//+------------------------------------------------------------------+
datetime g_dayStart         = 0;
int      g_dayKey           = 0;
double   g_realizedToday    = 0.0;       // closed money today incl. commissions (basket positions)
int      g_harvestsToday    = 0;
double   g_harvestNetToday  = 0.0;
int      g_reanchorsToday   = 0;
double   g_reanchorNetToday = 0.0;
int      g_closesToday      = 0;
double   g_bank             = 0.0;
ulong    g_maxDealSeen      = 0;         // newest deal already processed
datetime g_lastReanchor     = 0;

long     g_holeMsc[V11_HOLES];           // FIFO of empty-slot start times
int      g_holeCount  = 0;
int      g_gapCount   = 0;
double   g_gapSumMs   = 0.0;
double   g_gapMaxMs   = 0.0;
double   g_gapLastMs  = -1.0;

ulong    g_tagTicket[V11_TAGS];          // reason text for closes sent by the EA
string   g_tagText[V11_TAGS];
int      g_tagNext = 0;

//+------------------------------------------------------------------+
//| Protection state                                                 |
//+------------------------------------------------------------------+
bool     g_haltDay         = false;      // daily loss limit hit
int      g_haltDayKey      = 0;
string   g_haltReason      = "";
bool     g_haltKill        = false;      // equity kill switch (reset with InpResetKillSwitch)
double   g_peakEquity      = 0.0;
datetime g_cooldownUntil   = 0;          // basket stop cooldown
datetime g_execPauseUntil  = 0;          // back-off after failed requests
string   g_execPauseReason = "";
int      g_failStreak      = 0;
datetime g_shockUntil      = 0;
string   g_shockReason     = "";
double   g_shockRangePts   = 0.0;
datetime g_lastFlattenTry  = 0;
string   g_flattenMode     = "";         // why the basket must stay flat right now ("" = it need not)

datetime g_reqTimes[V11_TIME_RING];
int      g_reqHead  = 0;
int      g_reqCount = 0;

//--- positions without a server stop (stop guard)
ulong    g_nakedTicket[V11_MAX_POS];
datetime g_nakedSince[V11_MAX_POS];
datetime g_nakedLastTry[V11_MAX_POS];
int      g_nakedTries[V11_MAX_POS];

//--- news cache
datetime g_newsTime[V11_MAX_NEWS];
string   g_newsName[V11_MAX_NEWS];
int      g_newsCount  = 0;
datetime g_newsLoaded = 0;
string   g_newsStatus = "";

//--- persistence, CSV and status texts
string   g_gvPrefix   = "";
bool     g_stateDirty = false;
datetime g_lastSave   = 0;
string   g_csvName    = "";
bool     g_csvOk      = false;
string   g_lastAction = "-";
string   g_nextText   = "-";
string   g_gateReason = "";
bool     g_gateOpen   = false;

//--- dashboard
long     g_lastPanelMs = 0;
bool     g_panelReady  = false;
string   g_panelText[V11_PANEL_LINES];
color    g_panelColor[V11_PANEL_LINES];

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void V11Log(const int level, const string msg)
  {
   if(level <= InpLogLevel)
      Print("[V11] ", msg);
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

//--- clock for timeouts: tick time in the tester, a local monotonic clock live
long ClockMs()
  {
   if(g_isTester)
      return (g_haveTick ? g_last.time_msc : (long)TimeCurrent() * 1000);
   return (long)(GetMicrosecondCount() / 1000);
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

string FmtSigned(const double v)
  {
   return StringFormat("%+.2f", v);
  }

string FmtPrice(const double p)
  {
   return DoubleToString(p, _Digits);
  }

string DirName(const int dir)
  {
   return (dir > 0 ? "BUY" : "SELL");
  }

string BiasName(const int bias)
  {
   if(bias > 0)
      return "UP";
   if(bias < 0)
      return "DOWN";
   return "NEUTRAL";
  }

string TargetText(const int bias)
  {
   if(bias > 0)
      return "2 BUY + 1 SELL";
   if(bias < 0)
      return "1 BUY + 2 SELL";
   return "1 BUY + 1 SELL";
  }

string BasketText(const int nb, const int ns)
  {
   return StringFormat("%d BUY + %d SELL", nb, ns);
  }

double Clamp(const double v, const double lo, const double hi)
  {
   if(v < lo)
      return lo;
   if(v > hi)
      return hi;
   return v;
  }

double SignOf(const double v)
  {
   if(v > 0.0)
      return 1.0;
   if(v < 0.0)
      return -1.0;
   return 0.0;
  }

double CurrentSpreadPts()
  {
   if(!g_haveTick || g_point <= 0.0)
      return 0.0;
   return (g_last.ask - g_last.bid) / g_point;
  }

string CsvSafe(const string text)
  {
   string s = text;
   StringReplace(s, ",", ";");
   StringReplace(s, "\r", " ");
   StringReplace(s, "\n", " ");
   return s;
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

double MoneyPerPoint(const double lots)
  {
   return PointsToMoney(1000.0, lots) / 1000.0;
  }

double CommRT(const double lots)
  {
   return g_commPerLotRT * lots;
  }

//--- distance (points) from the entry to the backup TP
double BackupTpPts(const double lots)
  {
   double mpp = MoneyPerPoint(lots);
   if(mpp <= 0.0)
      return 0.0;
   return (InpBackupTpNet + CommRT(lots)) / mpp;
  }

//--- distance (points) from the entry to the disaster stop
double DisasterPts(const double lots)
  {
   double mpp = MoneyPerPoint(lots);
   if(mpp <= 0.0)
      return 0.0;
   return (InpDisasterLoss - CommRT(lots)) / mpp;
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

//--- round a lot size DOWN to the broker step; 0 if below the broker minimum
double NormalizeLotsDown(const double lots)
  {
   double vstep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(vstep <= 0.0)
      vstep = 0.01;
   double v = lots;
   if(vmax > 0.0)
      v = MathMin(v, vmax);
   v = MathFloor(v / vstep + 1e-9) * vstep;
   v = NormalizeDouble(v, LotDigits(vstep));
   if(v < vmin - 1e-9)
      return 0.0;
   return v;
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
   if(!Need(InpMagic > 0, "InpMagic must be > 0", err)) return false;
   if(!Need(StringLen(InpComment) <= 12, "InpComment must be at most 12 characters", err)) return false;
   if(!Need(InpLots > 0.0, "InpLots must be > 0", err)) return false;
   if(!Need(InpHarvestNet > 0.0, "InpHarvestNet must be > 0", err)) return false;
   if(!Need(InpBackupTpNet > InpHarvestNet, "InpBackupTpNet must be above InpHarvestNet", err)) return false;
   if(!Need(InpCommissionPerLotRT >= 0.0, "InpCommissionPerLotRT must be >= 0", err)) return false;
   if(!Need(InpPulseOff >= 0.0 && InpPulseOn > InpPulseOff && InpPulseOn <= 100.0, "Need 0 <= InpPulseOff < InpPulseOn <= 100", err)) return false;
   if(!Need(InpPulseConfirmBars >= 1 && InpPulseConfirmBars <= 10, "InpPulseConfirmBars must be 1..10", err)) return false;
   if(!Need(InpAtrPeriod >= 2, "InpAtrPeriod must be >= 2", err)) return false;
   if(!Need(InpEmaFast >= 2 && InpEmaSlow > InpEmaFast, "Need 2 <= InpEmaFast < InpEmaSlow", err)) return false;
   if(!Need(InpEmaTrendM5 >= 2, "InpEmaTrendM5 must be >= 2", err)) return false;
   if(!Need(InpSlopeBars >= 1 && InpSlopeBars <= 20, "InpSlopeBars must be 1..20", err)) return false;
   if(!Need(InpSlopeFullATR > 0.0, "InpSlopeFullATR must be > 0", err)) return false;
   if(!Need(InpErBars >= 3 && InpErBars <= 100, "InpErBars must be 3..100", err)) return false;
   if(!Need(InpReanchorLoss > 0.0, "InpReanchorLoss must be > 0", err)) return false;
   if(!Need(InpBankKeep >= 0.0, "InpBankKeep must be >= 0", err)) return false;
   if(!Need(InpMaxSpreadPts > 0, "InpMaxSpreadPts must be > 0", err)) return false;
   if(!Need(InpSpreadSpikeRatio > 1.0, "InpSpreadSpikeRatio must be > 1", err)) return false;
   if(!Need(InpShockATR > 0.0 && InpShockWindowSec >= 1 && InpShockPauseSec >= 0, "Check the shock inputs", err)) return false;
   if(!Need(InpMaxTickAgeMs >= 100, "InpMaxTickAgeMs must be >= 100", err)) return false;
   if(!Need(InpMinMarginLevel >= 0.0, "InpMinMarginLevel must be >= 0", err)) return false;
   if(!Need(ParseHHMM(InpTradeStart, g_tradeStartMin), "InpTradeStart must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpTradeEnd, g_tradeEndMin), "InpTradeEnd must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpFridayLastEntry, g_fridayLastMin), "InpFridayLastEntry must be HH:MM", err)) return false;
   if(!Need(ParseHHMM(InpFridayFlatten, g_fridayFlattenMin), "InpFridayFlatten must be HH:MM", err)) return false;
   if(!Need(g_tradeStartMin < g_tradeEndMin, "InpTradeStart must be before InpTradeEnd", err)) return false;
   if(!Need(g_fridayLastMin < g_fridayFlattenMin, "InpFridayLastEntry must be before InpFridayFlatten", err)) return false;
   if(!Need(InpMondayDelayMin >= 0, "InpMondayDelayMin must be >= 0", err)) return false;
   if(!Need(InpNewsBeforeMin >= 0 && InpNewsAfterMin >= 0, "Check the news window inputs", err)) return false;
   if(!Need(InpDisasterLoss > InpReanchorLoss && InpDisasterLoss > InpCommissionPerLotRT * InpLots, "InpDisasterLoss must be above InpReanchorLoss and the commission", err)) return false;
   if(!Need(InpBasketStop > 0.0 && InpBasketCooldownMin >= 0, "Check InpBasketStop / InpBasketCooldownMin", err)) return false;
   if(!Need(InpDailyLossLimit > 0.0, "InpDailyLossLimit must be > 0", err)) return false;
   if(!Need(InpEquityKillPct > 0.0 && InpEquityKillPct < 100.0, "InpEquityKillPct must be between 0 and 100", err)) return false;
   if(!Need(InpDeviationPts >= 0 && InpMaxRetries >= 0 && InpMaxRetries <= 5, "Check InpDeviationPts / InpMaxRetries", err)) return false;
   if(!Need(InpMaxRequestsPerMin >= 6 && InpMaxRequestsPerMin <= 500, "InpMaxRequestsPerMin must be 6..500", err)) return false;
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
void ResetTr()
  {
   g_tr.kind              = V11_TR_NONE;
   g_tr.seq               = 0;
   g_tr.startMs           = 0;
   g_tr.closeTicket       = 0;
   g_tr.closeState        = V11_ST_DONE;
   g_tr.closeReqId        = 0;
   g_tr.closeAttempts     = 0;
   g_tr.closeFillSwitches = 0;
   g_tr.closeMsc          = 0;
   g_tr.closeNet          = 0.0;
   g_tr.nOpen             = 0;
   g_tr.settledMs         = 0;
   for(int i = 0; i < 3; i++)
     {
      g_tr.open[i].dir          = 0;
      g_tr.open[i].state        = V11_ST_DONE;
      g_tr.open[i].reqId        = 0;
      g_tr.open[i].ticket       = 0;
      g_tr.open[i].attempts     = 0;
      g_tr.open[i].fillSwitches = 0;
      g_tr.open[i].inMsc        = 0;
      g_tr.open[i].holeMsc      = 0;
     }
   g_trBeforeCount = 0;
   g_trWhy         = "";
  }

void ResetAll()
  {
   g_tickSeq = -1;
   ArrayInitialize(g_tickMsc, 0);
   ArrayInitialize(g_tickBid, 0.0);
   ZeroMemory(g_last);
   g_haveTick   = false;
   g_lastTickUs = 0;
   g_wShock.Init((long)InpShockWindowSec * 1000);
   g_wRate.Init(V11_RATE_WINDOW_MS);

   ArrayInitialize(g_spreadRing, 0);
   ArrayInitialize(g_spreadHist, 0);
   g_spreadHead       = -1;
   g_spreadCount      = 0;
   g_lastSpreadSample = 0;
   g_spreadMedian     = 0.0;

   ZeroMemory(g_p);
   g_bias       = 0;
   g_candidate  = 0;
   g_candCount  = 0;
   g_biasSince  = 0;
   g_lastM1Bar  = 0;
   g_dataReason = "waiting for data";

   g_posCount   = 0;
   g_nb         = 0;
   g_ns         = 0;
   g_floating   = 0.0;
   g_knownCount = 0;
   ArrayInitialize(g_known, 0);

   ResetTr();
   g_trSeq = 0;

   g_dayStart         = 0;
   g_dayKey           = 0;
   g_realizedToday    = 0.0;
   g_harvestsToday    = 0;
   g_harvestNetToday  = 0.0;
   g_reanchorsToday   = 0;
   g_reanchorNetToday = 0.0;
   g_closesToday      = 0;
   g_bank             = 0.0;
   g_maxDealSeen      = 0;
   g_lastReanchor     = 0;
   ArrayInitialize(g_holeMsc, 0);
   g_holeCount = 0;
   g_gapCount  = 0;
   g_gapSumMs  = 0.0;
   g_gapMaxMs  = 0.0;
   g_gapLastMs = -1.0;
   for(int i = 0; i < V11_TAGS; i++)
     {
      g_tagTicket[i] = 0;
      g_tagText[i]   = "";
     }
   g_tagNext = 0;

   g_haltDay         = false;
   g_haltDayKey      = 0;
   g_haltReason      = "";
   g_haltKill        = false;
   g_peakEquity      = 0.0;
   g_cooldownUntil   = 0;
   g_execPauseUntil  = 0;
   g_execPauseReason = "";
   g_failStreak      = 0;
   g_shockUntil      = 0;
   g_shockReason     = "";
   g_shockRangePts   = 0.0;
   g_lastFlattenTry  = 0;
   g_flattenMode     = "";
   ArrayInitialize(g_reqTimes, 0);
   g_reqHead  = 0;
   g_reqCount = 0;
   for(int i = 0; i < V11_MAX_POS; i++)
     {
      g_nakedTicket[i]  = 0;
      g_nakedSince[i]   = 0;
      g_nakedLastTry[i] = 0;
      g_nakedTries[i]   = 0;
     }
   g_newsCount  = 0;
   g_newsLoaded = 0;
   g_newsStatus = "";

   g_stateDirty = false;
   g_lastSave   = 0;
   g_csvOk      = false;
   g_lastAction = "-";
   g_nextText   = "-";
   g_gateReason = "";
   g_gateOpen   = false;

   g_lastPanelMs = 0;
   g_panelReady  = false;
   for(int i = 0; i < V11_PANEL_LINES; i++)
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
   if(bin >= V11_SPREAD_BINS)
      bin = V11_SPREAD_BINS - 1;
   int next = (g_spreadHead + 1) % V11_SPREAD_SAMPLES;
   if(g_spreadCount == V11_SPREAD_SAMPLES)
      g_spreadHist[g_spreadRing[next]]--;
   else
      g_spreadCount++;
   g_spreadRing[next] = bin;
   g_spreadHist[bin]++;
   g_spreadHead = next;
   int target = (g_spreadCount + 1) / 2;
   int cum    = 0;
   for(int b = 0; b < V11_SPREAD_BINS; b++)
     {
      cum += g_spreadHist[b];
      if(cum >= target)
        {
         g_spreadMedian = (double)b;
         break;
        }
     }
  }

//--- live only: no quote for over a minute means the market is closed
bool MarketQuiet()
  {
   if(g_isTester || !g_haveTick)
      return false;
   return (((long)GetMicrosecondCount() - g_lastTickUs) / 1000 > 60000);
  }

//+------------------------------------------------------------------+
//| Pulse                                                            |
//+------------------------------------------------------------------+
//--- score of the closed M1 bar at 'shift' (1 = last closed bar)
bool ComputePulse(const int shift, V11Pulse &p)
  {
   ZeroMemory(p);
   p.ready = false;
   datetime bt[];
   ArraySetAsSeries(bt, true);
   if(CopyTime(_Symbol, PERIOD_M1, shift, 1, bt) != 1)
     {
      g_dataReason = "loading M1 bars";
      return false;
     }
   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_hAtrM1, 0, shift, 1, atr) != 1 || atr[0] <= 0.0 || atr[0] == EMPTY_VALUE)
     {
      g_dataReason = "loading M1 ATR";
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
   //--- M5 values from the last M5 bar that was closed when this M1 bar closed
   int s5 = iBarShift(_Symbol, PERIOD_M5, bt[0] + 60, false);
   if(s5 < 0)
     {
      g_dataReason = "loading M5 bars";
      return false;
     }
   s5++;
   int    nEm = InpSlopeBars + 1;
   double em[];
   double a5[];
   ArraySetAsSeries(em, true);
   ArraySetAsSeries(a5, true);
   if(CopyBuffer(g_hEmaM5, 0, s5, nEm, em) != nEm || CopyBuffer(g_hAtrM5, 0, s5, 1, a5) != 1)
     {
      g_dataReason = "loading M5 indicators";
      return false;
     }
   if(a5[0] <= 0.0 || a5[0] == EMPTY_VALUE || em[0] == EMPTY_VALUE || em[InpSlopeBars] == EMPTY_VALUE)
     {
      g_dataReason = "M5 indicators not ready";
      return false;
     }
   double hh[];
   double ll[];
   ArraySetAsSeries(hh, true);
   ArraySetAsSeries(ll, true);
   if(CopyHigh(_Symbol, PERIOD_M1, shift, 3, hh) != 3 || CopyLow(_Symbol, PERIOD_M1, shift, 3, ll) != 3)
     {
      g_dataReason = "loading M1 highs/lows";
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
   double atrPx = atr[0];
   double path  = 0.0;
   for(int k = 0; k < InpErBars; k++)
      path += MathAbs(cl[k] - cl[k + 1]);
   p.barTime = bt[0];
   p.atrPts  = atrPx / g_point;
   p.t       = Clamp((em[0] - em[InpSlopeBars]) / a5[0] / InpSlopeFullATR, -1.0, 1.0);
   p.e       = Clamp((ef[0] - es[0]) / atrPx / 0.5, -1.0, 1.0);
   p.s       = (SignOf(hh[0] - hh[1]) + SignOf(ll[0] - ll[1]) + SignOf(hh[1] - hh[2]) + SignOf(ll[1] - ll[2])) / 4.0;
   p.m       = (path > 0.0 ? (cl[0] - cl[InpErBars]) / path : 0.0);
   p.score   = Clamp(100.0 * (0.35 * p.t + 0.25 * p.e + 0.20 * p.s + 0.20 * p.m), -100.0, 100.0);
   p.ready   = true;
   g_dataReason = "";
   return true;
  }

//--- direction changes need InpPulseConfirmBars bars in a row (confirmation + hysteresis)
void ApplyPulse(const V11Pulse &p, const datetime when, const bool quiet)
  {
   double score = p.score;
   int    zone  = 2;                    // 2 = between the thresholds
   if(score >= InpPulseOn)
      zone = 1;
   else if(score <= -InpPulseOn)
      zone = -1;
   else if(MathAbs(score) < InpPulseOff)
      zone = 0;
   int target = 99;                      // 99 = this bar does not push towards a change
   if(g_bias == 0)
     {
      if(zone == 1 || zone == -1)
         target = zone;
     }
   else if(g_bias > 0)
     {
      if(zone == -1 || zone == 0)
         target = zone;
     }
   else
     {
      if(zone == 1 || zone == 0)
         target = zone;
     }
   if(target == 99)
     {
      g_candCount = 0;
      return;
     }
   if(g_candCount > 0 && g_candidate == target)
      g_candCount++;
   else
     {
      g_candidate = target;
      g_candCount = 1;
     }
   if(g_candCount < InpPulseConfirmBars)
      return;
   int prev    = g_bias;
   g_bias      = target;
   g_candCount = 0;
   g_biasSince = when;
   if(!quiet)
      V11Log(1, StringFormat("PULSE %s -> %s | score %+.0f (trend %+.2f, EMA %+.2f, structure %+.2f, ER %+.2f) | basket %s",
                             BiasName(prev), BiasName(g_bias), score, p.t, p.e, p.s, p.m, BasketText(g_nb, g_ns)));
  }

//--- replay recent closed bars so that a restart knows the direction at once
void SeedPulse()
  {
   for(int s = V11_SEED_BARS; s >= 2; s--)
     {
      V11Pulse ps;
      if(!ComputePulse(s, ps))
         continue;
      ApplyPulse(ps, ps.barTime + 60, true);
     }
  }

void UpdatePulse()
  {
   datetime bar0 = iTime(_Symbol, PERIOD_M1, 0);
   if(bar0 <= 0 || bar0 == g_lastM1Bar)
      return;
   V11Pulse p;
   if(!ComputePulse(1, p))
      return;
   if(g_lastM1Bar == 0)
     {
      SeedPulse();
      V11Log(1, StringFormat("Pulse ready: %s (score %+.0f)", BiasName(g_bias), p.score));
     }
   g_p         = p;
   g_lastM1Bar = bar0;
   ApplyPulse(p, NowServer(), false);
   if(InpLogLevel >= 2)
      V11Log(2, StringFormat("BAR %s | score %+.0f (T %+.2f E %+.2f S %+.2f M %+.2f) | %s | candidate %s %d/%d",
                             TimeToString(p.barTime, TIME_DATE | TIME_MINUTES), p.score, p.t, p.e, p.s, p.m,
                             BiasName(g_bias), BiasName(g_candidate), g_candCount, InpPulseConfirmBars));
  }

//--- shock: a large range in a few seconds pauses new trades
void CheckShock()
  {
   if(!g_haveTick)
      return;
   g_shockRangePts = (g_wShock.HasData() ? (g_wShock.Hi() - g_wShock.Lo()) / g_point : 0.0);
   if(!g_p.ready || g_p.atrPts <= 0.0)
      return;
   double limit = InpShockATR * g_p.atrPts;
   if(g_shockRangePts < limit)
      return;
   datetime until = NowServer() + InpShockPauseSec;
   bool     fresh = (NowServer() >= g_shockUntil);
   if(until > g_shockUntil)
      g_shockUntil = until;
   g_shockReason = StringFormat("%.0f pts in %d s (limit %.0f)", g_shockRangePts, InpShockWindowSec, limit);
   if(fresh)
      V11Log(1, "SHOCK: " + g_shockReason + " - no new trades for " + FormatDuration(InpShockPauseSec));
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
      g_newsStatus = "skipped (no economic calendar in the Strategy Tester)";
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
      for(int i = 0; i < nv && g_newsCount < V11_MAX_NEWS; i++)
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
//| Entry gate                                                       |
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

bool FridayFlattenTime(const datetime now)
  {
   MqlDateTime s;
   TimeToStruct(now, s);
   return (s.day_of_week == 5 && s.hour * 60 + s.min >= g_fridayFlattenMin);
  }

void NoteRequest()
  {
   g_reqTimes[g_reqHead] = NowServer();
   g_reqHead = (g_reqHead + 1) % V11_TIME_RING;
   if(g_reqCount < V11_TIME_RING)
      g_reqCount++;
  }

int RequestsLastMinute()
  {
   datetime now = NowServer();
   int      n   = 0;
   int      idx = g_reqHead;
   for(int k = 0; k < g_reqCount; k++)
     {
      idx = (idx - 1 + V11_TIME_RING) % V11_TIME_RING;
      if((long)(now - g_reqTimes[idx]) >= 60)
         break;
      n++;
     }
   return n;
  }

//--- margin level after opening 'addCount' trades while 'freeCount' trades close
bool MarginOk(const int addCount, const int freeCount, string &why)
  {
   if(addCount <= 0)
      return true;
   double m = 0.0;
   if(!OrderCalcMargin(ORDER_TYPE_BUY, _Symbol, g_lots, g_last.ask, m))
     {
      why = "margin calculation failed";
      return false;
     }
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double used   = AccountInfoDouble(ACCOUNT_MARGIN);
   double free   = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double extra  = m * (addCount - freeCount);
   if(extra > free)
     {
      why = StringFormat("not enough free margin (%s needed, %s free)", FmtMoney(extra), FmtMoney(free));
      return false;
     }
   double after = MathMax(0.0, used + extra);
   double level = (after > 0.0 ? equity / after * 100.0 : 1.0e9);
   if(level < InpMinMarginLevel)
     {
      why = StringFormat("margin level would be %.0f%% (min %.0f%%)", level, InpMinMarginLevel);
      return false;
     }
   return true;
  }

//--- may the EA open 'addCount' new trades now (while 'freeCount' trades close)?
bool EntryGate(const int addCount, const int freeCount, string &why)
  {
   datetime now = NowServer();
   if(!g_tradeEnabled)
     {
      why = "no orders: " + g_tradeBlockMsg;
      return false;
     }
   if(!g_p.ready)
     {
      why = "warming up: " + g_dataReason;
      return false;
     }
   if(g_flattenMode != "")
     {
      why = g_flattenMode;
      return false;
     }
   if(now < g_execPauseUntil)
     {
      why = StringFormat("execution back-off %s: %s", FormatDuration((long)(g_execPauseUntil - now)), g_execPauseReason);
      return false;
     }
   if(RequestsLastMinute() + addCount + freeCount > InpMaxRequestsPerMin)
     {
      why = StringFormat("max %d trade requests per minute reached", InpMaxRequestsPerMin);
      return false;
     }
   if(!g_isTester &&
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
   string sw = "";
   if(!SessionOpen(now, sw))
     {
      why = "session " + sw;
      return false;
     }
   double sp = CurrentSpreadPts();
   if(sp > InpMaxSpreadPts)
     {
      why = StringFormat("spread %.0f > max %d", sp, InpMaxSpreadPts);
      return false;
     }
   if(g_spreadCount >= V11_MIN_SPREAD_SAMPLES && g_spreadMedian > 0.0 && sp > InpSpreadSpikeRatio * g_spreadMedian)
     {
      why = StringFormat("spread spike %.0f > %.1f x median %.0f", sp, InpSpreadSpikeRatio, g_spreadMedian);
      return false;
     }
   if(now < g_shockUntil)
     {
      why = StringFormat("shock pause %s: %s", FormatDuration((long)(g_shockUntil - now)), g_shockReason);
      return false;
     }
   string nw = "";
   if(NewsWindow(now, nw))
     {
      why = "news window: " + nw;
      return false;
     }
   if(!g_isTester && g_haveTick)
     {
      long ageMs = ((long)GetMicrosecondCount() - g_lastTickUs) / 1000;
      if(ageMs > InpMaxTickAgeMs)
        {
         why = StringFormat("quotes stale (%I64d ms)", ageMs);
         return false;
        }
     }
   if(!MarginOk(addCount, freeCount, why))
      return false;
   why = "open";
   return true;
  }

//+------------------------------------------------------------------+
//| Basket rules (spec section 2)                                    |
//+------------------------------------------------------------------+
//--- direction for ONE empty place (first matching row of the rule table), 0 = none
int NextDir(const int nb, const int ns, const int bias)
  {
   if(nb + ns >= 3)
      return 0;
   if(nb == 0)
      return 1;
   if(ns == 0)
      return -1;
   if(nb == 1 && ns == 1)
     {
      if(bias > 0)
         return 1;
      if(bias < 0)
         return -1;
     }
   return 0;
  }

//--- opens for an idle basket: the start pair, or one step of the rule table
void FillPlan(const int nb, const int ns, const int bias, V11Plan &plan)
  {
   plan.n = 0;
   if(nb == 0 && ns == 0)
     {
      plan.dir[0] = 1;
      plan.dir[1] = -1;
      plan.n      = 2;
      return;
     }
   int d = NextDir(nb, ns, bias);
   if(d != 0)
     {
      plan.dir[0] = d;
      plan.n      = 1;
     }
  }

//--- replacement for a swap, decided on the positions that remain after the close
void RefillPlan(const int nbAfter, const int nsAfter, const int bias, V11Plan &plan)
  {
   plan.n = 0;
   int d  = NextDir(nbAfter, nsAfter, bias);
   if(d != 0)
     {
      plan.dir[0] = d;
      plan.n      = 1;
     }
  }

string PlanText(const V11Plan &plan)
  {
   if(plan.n == 0)
      return "no refill";
   string s = "";
   for(int i = 0; i < plan.n; i++)
      s += (i > 0 ? " + " : "") + DirName(plan.dir[i]);
   return s;
  }

//+------------------------------------------------------------------+
//| Gap meter                                                        |
//+------------------------------------------------------------------+
void RecordGap(const double ms)
  {
   double g = MathMax(0.0, ms);
   g_gapCount++;
   g_gapSumMs += g;
   if(g > g_gapMaxMs)
      g_gapMaxMs = g;
   g_gapLastMs = g;
  }

void PushHole(const long startMs)
  {
   if(g_holeCount >= V11_HOLES)
     {
      for(int i = 1; i < V11_HOLES; i++)
         g_holeMsc[i - 1] = g_holeMsc[i];
      g_holeCount = V11_HOLES - 1;
     }
   g_holeMsc[g_holeCount] = startMs;
   g_holeCount++;
  }

long PopHole()
  {
   if(g_holeCount <= 0)
      return 0;
   long v = g_holeMsc[0];
   for(int i = 1; i < g_holeCount; i++)
      g_holeMsc[i - 1] = g_holeMsc[i];
   g_holeCount--;
   return v;
  }

//--- holes beyond the places the rules want to fill are not gaps (e.g. NEUTRAL third slot)
void TrimHoles(const int wanted)
  {
   int keep = (wanted > 0 ? wanted : 0);
   if(g_holeCount > keep)
      g_holeCount = keep;
  }

//+------------------------------------------------------------------+
//| Close reason tags                                                |
//+------------------------------------------------------------------+
void TagClose(const ulong ticket, const string tag)
  {
   for(int i = 0; i < V11_TAGS; i++)
      if(g_tagTicket[i] == ticket)
        {
         g_tagText[i] = tag;
         return;
        }
   g_tagTicket[g_tagNext] = ticket;
   g_tagText[g_tagNext]   = tag;
   g_tagNext = (g_tagNext + 1) % V11_TAGS;
  }

string CloseTag(const ulong ticket)
  {
   for(int i = 0; i < V11_TAGS; i++)
      if(g_tagTicket[i] == ticket)
         return g_tagText[i];
   return "";
  }

string TagName(const string tag)
  {
   if(tag == "HV")
      return "HARVEST";
   if(tag == "RA")
      return "REANCHOR";
   if(tag == "BS")
      return "BASKET_STOP";
   if(tag == "DL")
      return "DAILY_LIMIT";
   if(tag == "FF")
      return "FRIDAY_FLATTEN";
   if(tag == "KS")
      return "KILL_SWITCH";
   if(tag == "NS")
      return "NO_STOP";
   return (tag == "" ? "EA" : tag);
  }

//--- the 2-letter tag at the end of an order/deal comment such as "V11 HV"
string TagFromComment(const string comment)
  {
   int len = StringLen(comment);
   if(len < 2)
      return "";
   string tail = StringSubstr(comment, len - 2, 2);
   if(tail == "HV" || tail == "RA" || tail == "BS" || tail == "DL" || tail == "FF" || tail == "KS" || tail == "NS")
      return tail;
   return "";
  }

//+------------------------------------------------------------------+
//| Basket positions                                                 |
//+------------------------------------------------------------------+
bool TrCloseActive()
  {
   return (g_tr.kind != V11_TR_NONE && g_tr.closeTicket != 0 &&
           g_tr.closeState != V11_ST_DONE && g_tr.closeState != V11_ST_FAILED);
  }

bool InTrBefore(const ulong ticket)
  {
   for(int i = 0; i < g_trBeforeCount; i++)
      if(g_trBefore[i] == ticket)
         return true;
   return false;
  }

int FindPos(const ulong ticket)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].ticket == ticket)
         return i;
   return -1;
  }

double BasketNet()
  {
   double s = 0.0;
   for(int i = 0; i < g_posCount; i++)
      s += g_pos[i].net;
   return s;
  }

double DayNet()
  {
   return g_realizedToday + g_floating;
  }

void ScanPositions()
  {
   ulong prev[V11_MAX_POS];
   int   prevCount = g_knownCount;
   for(int i = 0; i < prevCount; i++)
      prev[i] = g_known[i];
   g_posCount = 0;
   g_nb       = 0;
   g_ns       = 0;
   g_floating = 0.0;
   bool closingTr = TrCloseActive();
   int  total     = PositionsTotal();
   for(int i = total - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(g_posCount >= V11_MAX_POS)
         break;
      int    dir    = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      double vol    = PositionGetDouble(POSITION_VOLUME);
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      g_pos[g_posCount].ticket  = ticket;
      g_pos[g_posCount].dir     = dir;
      g_pos[g_posCount].vol     = vol;
      g_pos[g_posCount].open    = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[g_posCount].sl      = PositionGetDouble(POSITION_SL);
      g_pos[g_posCount].tp      = PositionGetDouble(POSITION_TP);
      g_pos[g_posCount].net     = profit - CommRT(vol);
      g_pos[g_posCount].opened  = (datetime)PositionGetInteger(POSITION_TIME);
      g_pos[g_posCount].closing = (closingTr && ticket == g_tr.closeTicket);
      if(!g_pos[g_posCount].closing)
        {
         if(dir > 0)
            g_nb++;
         else
            g_ns++;
        }
      g_floating += profit - 0.5 * CommRT(vol);
      g_posCount++;
     }
   g_knownCount = g_posCount;
   for(int i = 0; i < g_posCount; i++)
      g_known[i] = g_pos[i].ticket;
   //--- a basket position that vanished without the EA closing it leaves a hole (gap meter)
   if(g_flattenMode != "")
     {
      g_holeCount = 0;
      return;
     }
   for(int k = 0; k < prevCount; k++)
     {
      if(FindPos(prev[k]) >= 0)
         continue;
      if(g_tr.kind != V11_TR_NONE && prev[k] == g_tr.closeTicket)
         continue;
      PushHole(ClockMs());
     }
   V11Plan fill;
   FillPlan(g_nb, g_ns, g_bias, fill);
   TrimHoles((g_nb + g_ns == 0) ? 0 : fill.n);
  }

//--- the trade to harvest: highest net at or above the harvest line
int BestHarvest()
  {
   int    best = -1;
   double bnet = 0.0;
   for(int i = 0; i < g_posCount; i++)
     {
      if(g_pos[i].closing)
         continue;
      if(g_pos[i].net >= InpHarvestNet && (best < 0 || g_pos[i].net > bnet))
        {
         best = i;
         bnet = g_pos[i].net;
        }
     }
   return best;
  }

//--- the stuck trade with the largest loss
int WorstStuck()
  {
   int    worst = -1;
   double wnet  = 0.0;
   for(int i = 0; i < g_posCount; i++)
     {
      if(g_pos[i].closing)
         continue;
      if(g_pos[i].net <= -InpReanchorLoss && (worst < 0 || g_pos[i].net < wnet))
        {
         worst = i;
         wnet  = g_pos[i].net;
        }
     }
   return worst;
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

bool IsDone(const uint rc)
  {
   return (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

bool IsPriceRetry(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE || rc == TRADE_RETCODE_PRICE_CHANGED || rc == TRADE_RETCODE_PRICE_OFF);
  }

bool UseAsync()
  {
   return (InpUseAsync && !g_isTester);
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

//--- back off after a request that failed for good
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
   V11Log(1, StringFormat("BACK-OFF %s: %s", FormatDuration((long)sec), reason));
  }

//--- server stop and target for a new trade opened at 'price'
void StopsFor(const int dir, const double price, double &sl, double &tp)
  {
   double slPts = DisasterPts(g_lots);
   double tpPts = BackupTpPts(g_lots);
   sl = (slPts > 0.0 ? NormPrice(dir > 0 ? price - slPts * g_point : price + slPts * g_point) : 0.0);
   tp = (tpPts > 0.0 ? NormPrice(dir > 0 ? price + tpPts * g_point : price - tpPts * g_point) : 0.0);
  }

bool BuildRequest(const bool isClose, const int dir, const ulong ticket, const string tag,
                  const ENUM_ORDER_TYPE_FILLING filling, MqlTradeRequest &req)
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return false;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.magic        = (ulong)InpMagic;
   req.type_filling = filling;
   req.type_time    = ORDER_TIME_GTC;
   req.comment      = InpComment + " " + tag;
   if(isClose)
     {
      if(!PositionSelectByTicket(ticket))
         return false;
      int pdir = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      req.position  = ticket;
      req.volume    = PositionGetDouble(POSITION_VOLUME);
      req.type      = (pdir > 0 ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
      req.price     = (pdir > 0 ? t.bid : t.ask);
      req.deviation = (ulong)MathMax(InpDeviationPts, 50);
      return true;
     }
   req.volume    = g_lots;
   req.type      = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   req.price     = (dir > 0 ? t.ask : t.bid);
   req.deviation = (ulong)InpDeviationPts;
   if(g_stopsOnOpen)
     {
      double sl = 0.0;
      double tp = 0.0;
      StopsFor(dir, req.price, sl, tp);
      double lvl = (g_stopsLevel + 1) * g_point;
      if(sl > 0.0 && (dir > 0 ? t.bid - sl >= lvl : sl - t.ask >= lvl))
         req.sl = sl;
      if(tp > 0.0 && (dir > 0 ? tp - t.bid >= lvl : t.ask - tp >= lvl))
         req.tp = tp;
     }
   return true;
  }

//--- send one market request. Sync: retried inline. Async: the result arrives in OnTradeTransaction.
int Dispatch(const bool isClose, const int dir, const ulong ticket, const string tag,
             int &fillSwitches, int &attempts, uint &reqId, ulong &outTicket, uint &rc)
  {
   reqId     = 0;
   outTicket = 0;
   rc        = 0;
   while(true)
     {
      MqlTradeRequest req;
      MqlTradeResult  res;
      if(!BuildRequest(isClose, dir, ticket, tag, g_filling, req))
        {
         rc = (isClose ? TRADE_RETCODE_POSITION_CLOSED : TRADE_RETCODE_PRICE_OFF);
         return V11_SEND_FAIL;
        }
      ZeroMemory(res);
      attempts++;
      NoteRequest();
      bool sent = false;
      if(UseAsync())
        {
         sent = OrderSendAsync(req, res);
         if(sent)
           {
            reqId = res.request_id;
            return V11_SEND_PENDING;
           }
        }
      else
         sent = OrderSend(req, res);
      if(!sent && res.retcode == 0)
         res.retcode = TRADE_RETCODE_ERROR;      // refused inside the terminal with no result code
      rc = res.retcode;
      if(IsDone(rc))
        {
         outTicket = (isClose ? ticket : res.order);
         return V11_SEND_DONE;
        }
      if(isClose && rc == TRADE_RETCODE_POSITION_CLOSED)
        {
         outTicket = ticket;
         return V11_SEND_DONE;
        }
      if(rc == TRADE_RETCODE_INVALID_FILL && fillSwitches < 2)
        {
         g_filling = NextFilling(g_filling);
         fillSwitches++;
         V11Log(1, "Filling mode switched to " + FillingName(g_filling));
         continue;
        }
      if(!isClose && rc == TRADE_RETCODE_INVALID_STOPS && g_stopsOnOpen)
        {
         g_stopsOnOpen = false;
         V11Log(0, "Broker rejected stops on the market order - trades now open without them and the stops are attached at once.");
         continue;
        }
      if(IsPriceRetry(rc) && attempts <= InpMaxRetries)
        {
         RefreshTick();
         continue;
        }
      return V11_SEND_FAIL;
     }
   return V11_SEND_FAIL;
  }

//--- set stop and target on an open position
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
   req.magic    = (ulong)InpMagic;
   NoteRequest();
   bool sent = OrderSend(req, res);
   if(IsDone(res.retcode) || res.retcode == TRADE_RETCODE_NO_CHANGES)
      return true;
   V11Log(0, StringFormat("Set stop/target on #%I64u failed: %s (sent %s, sl %s, tp %s)",
                          ticket, RetcodeText(res.retcode), (sent ? "yes" : "no"), FmtPrice(sl), FmtPrice(tp)));
   return false;
  }

//--- close one basket position at market, synchronously (protection closes)
bool ClosePositionNow(const ulong ticket, const string tag)
  {
   if(!g_tradeEnabled)
      return false;
   if(!PositionSelectByTicket(ticket))
      return true;
   TagClose(ticket, tag);
   int fillSwitches = 0;
   int priceRetries = 0;
   while(true)
     {
      MqlTradeRequest req;
      MqlTradeResult  res;
      if(!BuildRequest(true, 0, ticket, tag, g_filling, req))
         return !PositionSelectByTicket(ticket);
      ZeroMemory(res);
      NoteRequest();
      bool sent = OrderSend(req, res);
      uint rc   = res.retcode;
      if(IsDone(rc) || rc == TRADE_RETCODE_POSITION_CLOSED)
         return true;
      if(rc == TRADE_RETCODE_INVALID_FILL && fillSwitches < 2)
        {
         g_filling = NextFilling(g_filling);
         fillSwitches++;
         continue;
        }
      if(IsPriceRetry(rc) && priceRetries < InpMaxRetries + 1)
        {
         priceRetries++;
         continue;
        }
      V11Log(0, StringFormat("Close #%I64u (%s) failed: %s (sent %s)", ticket, TagName(tag), RetcodeText(rc), (sent ? "yes" : "no")));
      return false;
     }
   return false;
  }

//--- close every basket position (protection). Returns the number of failed closes.
int FlattenAll(const string tag)
  {
   if(!g_tradeEnabled || g_posCount == 0 || MarketQuiet())
      return 0;
   datetime now = NowServer();
   if(g_lastFlattenTry == now)
      return g_posCount;                 // at most one attempt per second
   g_lastFlattenTry = now;
   int n      = g_posCount;
   int failed = 0;
   for(int i = 0; i < n; i++)
      if(!ClosePositionNow(g_pos[i].ticket, tag))
         failed++;
   V11Log(1, StringFormat("FLATTEN (%s): %d position(s), %d failed", TagName(tag), n, failed));
   g_lastAction = StringFormat("FLATTEN %s (%d positions)", TagName(tag), n);
   ScanPositions();
   return failed;
  }

//+------------------------------------------------------------------+
//| Stop guard: every basket position carries the disaster stop      |
//+------------------------------------------------------------------+
int NakedSlot(const ulong ticket, const bool create)
  {
   for(int i = 0; i < V11_MAX_POS; i++)
      if(g_nakedTicket[i] == ticket)
         return i;
   if(!create)
      return -1;
   for(int i = 0; i < V11_MAX_POS; i++)
      if(g_nakedTicket[i] == 0)
        {
         g_nakedTicket[i]  = ticket;
         g_nakedSince[i]   = NowServer();
         g_nakedLastTry[i] = 0;
         g_nakedTries[i]   = 0;
         return i;
        }
   return -1;
  }

void ProtectPositions()
  {
   if(!g_tradeEnabled || MarketQuiet())
      return;
   //--- forget tickets that are gone or protected
   for(int k = 0; k < V11_MAX_POS; k++)
     {
      if(g_nakedTicket[k] == 0)
         continue;
      int p = FindPos(g_nakedTicket[k]);
      if(p < 0 || g_pos[p].sl > 0.0)
         g_nakedTicket[k] = 0;
     }
   datetime now     = NowServer();
   bool     changed = false;
   double   lvl     = (g_stopsLevel + 1) * g_point;
   for(int i = 0; i < g_posCount; i++)
     {
      bool needSl = (g_pos[i].sl <= 0.0);
      bool needTp = (g_pos[i].tp <= 0.0);
      if(!needSl && !needTp)
         continue;
      double sl  = 0.0;
      double tp  = 0.0;
      StopsFor(g_pos[i].dir, g_pos[i].open, sl, tp);
      int    dir = g_pos[i].dir;
      bool   slOk = (sl > 0.0 && (dir > 0 ? g_last.bid - sl >= lvl : sl - g_last.ask >= lvl));
      bool   tpOk = (tp > 0.0 && (dir > 0 ? tp - g_last.bid >= lvl : g_last.ask - tp >= lvl));
      if(!needSl)
        {
         //--- only the backup TP is missing: try every 5 s, never close for it
         int k = NakedSlot(g_pos[i].ticket, true);
         if(k < 0 || !tpOk || (long)(now - g_nakedLastTry[k]) < 5)
            continue;
         g_nakedLastTry[k] = now;
         if(SendSLTP(g_pos[i].ticket, g_pos[i].sl, tp))
            changed = true;
         continue;
        }
      int k = NakedSlot(g_pos[i].ticket, true);
      if(k < 0 || g_nakedLastTry[k] == now)
         continue;
      if(!slOk || g_nakedTries[k] >= 3 || (long)(now - g_nakedSince[k]) >= 10)
        {
         V11Log(0, StringFormat("Position #%I64u has no stop loss and it cannot be set - closing it", g_pos[i].ticket));
         ClosePositionNow(g_pos[i].ticket, "NS");
         g_nakedTicket[k] = 0;
         ExecPause(1800, "a position had to be closed because its stop loss could not be set");
         changed = true;
         continue;
        }
      g_nakedTries[k]++;
      g_nakedLastTry[k] = now;
      double useTp = (g_pos[i].tp > 0.0 ? g_pos[i].tp : (tpOk ? tp : 0.0));
      if(SendSLTP(g_pos[i].ticket, sl, useTp))
        {
         V11Log(1, StringFormat("Stops attached to #%I64u: sl %s tp %s", g_pos[i].ticket, FmtPrice(sl), FmtPrice(useTp)));
         changed = true;
        }
     }
   if(changed)
      ScanPositions();
  }

//+------------------------------------------------------------------+
//| Transition engine: one swap at a time                            |
//+------------------------------------------------------------------+
string TrKindName(const int kind)
  {
   if(kind == V11_TR_FILL)
      return "FILL";
   if(kind == V11_TR_HARVEST)
      return "HARVEST";
   if(kind == V11_TR_REANCHOR)
      return "REANCHOR";
   return "-";
  }

//--- order comment tag of a new trade
string OpenTag(const int kind)
  {
   if(kind == V11_TR_HARVEST)
      return "HR";                       // refill after a harvest
   if(kind == V11_TR_REANCHOR)
      return "RR";                       // refill after a re-anchor
   return "FL";                          // start pair, third slot, waiting slot
  }

void ForgetKnown(const ulong ticket)
  {
   for(int i = 0; i < g_knownCount; i++)
      if(g_known[i] == ticket)
        {
         for(int j = i + 1; j < g_knownCount; j++)
            g_known[j - 1] = g_known[j];
         g_knownCount--;
         return;
        }
  }

void FailOpen(const int i, const string why)
  {
   g_tr.open[i].state = V11_ST_FAILED;
   if(g_tr.open[i].holeMsc != 0)
     {
      PushHole(g_tr.open[i].holeMsc);    // the place is still empty
      g_tr.open[i].holeMsc = 0;
     }
   V11Log(0, StringFormat("%s #%d: open %s failed - %s", TrKindName(g_tr.kind), g_tr.seq, DirName(g_tr.open[i].dir), why));
  }

void SendTrClose()
  {
   string tag   = (g_tr.kind == V11_TR_REANCHOR ? "RA" : "HV");
   uint   reqId = 0;
   ulong  out   = 0;
   uint   rc    = 0;
   int    r     = Dispatch(true, 0, g_tr.closeTicket, tag, g_tr.closeFillSwitches, g_tr.closeAttempts, reqId, out, rc);
   if(r == V11_SEND_PENDING)
     {
      g_tr.closeState = V11_ST_SENT;
      g_tr.closeReqId = reqId;
      return;
     }
   if(r == V11_SEND_DONE)
     {
      g_tr.closeState = V11_ST_ACCEPTED;
      g_failStreak    = 0;
      return;
     }
   g_tr.closeState = V11_ST_FAILED;
   V11Log(0, StringFormat("%s #%d: close #%I64u failed - %s", TrKindName(g_tr.kind), g_tr.seq, g_tr.closeTicket, RetcodeText(rc)));
   BackOff(rc);
  }

void SendTrOpen(const int i)
  {
   uint  reqId = 0;
   ulong out   = 0;
   uint  rc    = 0;
   int   r     = Dispatch(false, g_tr.open[i].dir, 0, OpenTag(g_tr.kind), g_tr.open[i].fillSwitches,
                          g_tr.open[i].attempts, reqId, out, rc);
   if(r == V11_SEND_PENDING)
     {
      g_tr.open[i].state = V11_ST_SENT;
      g_tr.open[i].reqId = reqId;
      return;
     }
   if(r == V11_SEND_DONE)
     {
      g_tr.open[i].state  = V11_ST_ACCEPTED;
      g_tr.open[i].ticket = out;
      g_failStreak        = 0;
      return;
     }
   FailOpen(i, RetcodeText(rc));
   BackOff(rc);
  }

//--- confirm executed requests from the position list
void CheckTrList()
  {
   long now = ClockMs();
   if(g_tr.closeTicket != 0 && (g_tr.closeState == V11_ST_SENT || g_tr.closeState == V11_ST_ACCEPTED) &&
      !PositionSelectByTicket(g_tr.closeTicket))
     {
      g_tr.closeState = V11_ST_DONE;
      g_tr.closeMsc   = now;
      ForgetKnown(g_tr.closeTicket);
     }
   for(int i = 0; i < g_tr.nOpen; i++)
      if(g_tr.open[i].state == V11_ST_ACCEPTED && g_tr.open[i].ticket != 0 && PositionSelectByTicket(g_tr.open[i].ticket))
        {
         g_tr.open[i].state = V11_ST_DONE;
         g_tr.open[i].inMsc = now;
        }
  }

bool TrComplete()
  {
   if(g_tr.closeTicket != 0 && g_tr.closeState != V11_ST_DONE && g_tr.closeState != V11_ST_FAILED)
      return false;
   for(int i = 0; i < g_tr.nOpen; i++)
      if(g_tr.open[i].state != V11_ST_DONE && g_tr.open[i].state != V11_ST_FAILED)
         return false;
   return true;
  }

void FinishTransition()
  {
   long   dur      = ClockMs() - g_tr.startMs;
   int    kind     = g_tr.kind;
   int    seq      = g_tr.seq;
   bool   closed   = (g_tr.closeTicket != 0 && g_tr.closeState == V11_ST_DONE);
   long   closeMsc = g_tr.closeMsc;
   int    opened   = 0;
   int    failed   = 0;
   string gapText  = "";
   for(int i = 0; i < g_tr.nOpen; i++)
     {
      if(g_tr.open[i].state == V11_ST_DONE)
        {
         opened++;
         double gap = -1.0;
         if(kind == V11_TR_FILL && g_tr.open[i].holeMsc != 0)
            gap = (double)(g_tr.open[i].inMsc - g_tr.open[i].holeMsc);
         else if(kind != V11_TR_FILL && closed)
            gap = (double)(g_tr.open[i].inMsc - closeMsc);
         if(gap >= -0.5)
           {
            RecordGap(gap);
            gapText = StringFormat(" | gap %.0f ms", MathMax(0.0, gap));
           }
        }
      else
         failed++;
     }
   if(g_tr.closeTicket != 0 && !closed)
      failed++;
   bool needHole = (kind != V11_TR_FILL && closed && opened == 0);
   if(g_tr.closeTicket != 0)
      ForgetKnown(g_tr.closeTicket);
   ResetTr();
   ScanPositions();
   if(needHole && g_nb + g_ns > 0)
     {
      V11Plan fill;
      FillPlan(g_nb, g_ns, g_bias, fill);
      if(fill.n > g_holeCount)
         PushHole(closeMsc);
     }
   if(kind == V11_TR_REANCHOR && closed)
      g_lastReanchor = NowServer();
   g_stateDirty = true;
   V11Log(1, StringFormat("%s #%d done in %I64d ms: %s%d opened, %d failed%s | basket %s",
                          TrKindName(kind), seq, dur, (closed ? "closed 1, " : ""), opened, failed, gapText,
                          BasketText(g_nb, g_ns)));
  }

//--- no confirmation in time: decide from the actual positions
void ReconcileTimeout()
  {
   V11Log(0, StringFormat("%s #%d: no confirmation after %d s - checking the positions",
                          TrKindName(g_tr.kind), g_tr.seq, V11_TR_TIMEOUT_MS / 1000));
   long now = ClockMs();
   if(g_tr.closeTicket != 0 && g_tr.closeState != V11_ST_DONE && g_tr.closeState != V11_ST_FAILED)
     {
      if(!PositionSelectByTicket(g_tr.closeTicket))
        {
         g_tr.closeState = V11_ST_DONE;
         g_tr.closeMsc   = now;
        }
      else
        {
         g_tr.closeState = V11_ST_FAILED;
         BackOff(TRADE_RETCODE_TIMEOUT);
        }
     }
   ScanPositions();
   for(int i = 0; i < g_tr.nOpen; i++)
     {
      int st = g_tr.open[i].state;
      if(st == V11_ST_DONE || st == V11_ST_FAILED)
         continue;
      if(st == V11_ST_ACCEPTED && g_tr.open[i].ticket != 0 && PositionSelectByTicket(g_tr.open[i].ticket))
        {
         g_tr.open[i].state = V11_ST_DONE;
         g_tr.open[i].inMsc = now;
         continue;
        }
      if(st == V11_ST_SENT)
        {
         //--- adopt a new basket position of that direction that no other open has taken
         for(int p = 0; p < g_posCount; p++)
           {
            if(g_pos[p].dir != g_tr.open[i].dir || InTrBefore(g_pos[p].ticket))
               continue;
            bool taken = false;
            for(int j = 0; j < g_tr.nOpen; j++)
               if(j != i && g_tr.open[j].ticket == g_pos[p].ticket)
                  taken = true;
            if(taken)
               continue;
            g_tr.open[i].ticket = g_pos[p].ticket;
            g_tr.open[i].state  = V11_ST_DONE;
            g_tr.open[i].inMsc  = now;
            break;
           }
         if(g_tr.open[i].state == V11_ST_DONE)
            continue;
        }
      FailOpen(i, "no confirmation from the server");
     }
   FinishTransition();
  }

//--- drop the transition when the basket must go flat
void AbortTransition(const string why)
  {
   if(g_tr.kind == V11_TR_NONE)
      return;
   V11Log(1, StringFormat("%s #%d aborted: %s", TrKindName(g_tr.kind), g_tr.seq, why));
   if(g_tr.closeTicket != 0)
      ForgetKnown(g_tr.closeTicket);
   ResetTr();
  }

//--- send what is due and check what has been confirmed
void ServiceTransition()
  {
   if(g_tr.kind == V11_TR_NONE)
      return;
   bool async = UseAsync();
   if(g_tr.closeTicket != 0 && g_tr.closeState == V11_ST_TODO)
      SendTrClose();
   bool closeOk     = (g_tr.closeTicket == 0 || g_tr.closeState == V11_ST_ACCEPTED || g_tr.closeState == V11_ST_DONE);
   bool closeFailed = (g_tr.closeTicket != 0 && g_tr.closeState == V11_ST_FAILED);
   for(int i = 0; i < g_tr.nOpen; i++)
     {
      if(g_tr.open[i].state != V11_ST_TODO)
         continue;
      if(closeFailed)
        {
         FailOpen(i, "its close failed");
         continue;
        }
      if(!async && !closeOk)
         continue;
      SendTrOpen(i);
     }
   CheckTrList();
   if(TrComplete())
     {
      FinishTransition();
      return;
     }
   if(ClockMs() - g_tr.startMs > V11_TR_TIMEOUT_MS)
      ReconcileTimeout();
  }

//--- async request results (TRADE_TRANSACTION_REQUEST)
void HandleRequestResult(const uint reqId, const uint rc, const ulong order)
  {
   if(g_tr.kind == V11_TR_NONE || reqId == 0)
      return;
   if(g_tr.closeTicket != 0 && g_tr.closeState == V11_ST_SENT && g_tr.closeReqId == reqId)
     {
      if(IsDone(rc) || rc == TRADE_RETCODE_POSITION_CLOSED)
        {
         g_tr.closeState = V11_ST_ACCEPTED;
         g_failStreak    = 0;
        }
      else if(rc == TRADE_RETCODE_INVALID_FILL && g_tr.closeFillSwitches < 2)
        {
         g_filling = NextFilling(g_filling);
         g_tr.closeFillSwitches++;
         g_tr.closeState = V11_ST_TODO;
        }
      else if(IsPriceRetry(rc) && g_tr.closeAttempts <= InpMaxRetries + 1)
         g_tr.closeState = V11_ST_TODO;
      else
        {
         g_tr.closeState = V11_ST_FAILED;
         V11Log(0, StringFormat("%s #%d: close #%I64u failed - %s", TrKindName(g_tr.kind), g_tr.seq, g_tr.closeTicket, RetcodeText(rc)));
         BackOff(rc);
        }
      return;
     }
   for(int i = 0; i < g_tr.nOpen; i++)
     {
      if(g_tr.open[i].state != V11_ST_SENT || g_tr.open[i].reqId != reqId)
         continue;
      if(IsDone(rc))
        {
         g_tr.open[i].state  = V11_ST_ACCEPTED;
         g_tr.open[i].ticket = order;
         g_failStreak        = 0;
        }
      else if(rc == TRADE_RETCODE_INVALID_FILL && g_tr.open[i].fillSwitches < 2)
        {
         g_filling = NextFilling(g_filling);
         g_tr.open[i].fillSwitches++;
         g_tr.open[i].state = V11_ST_TODO;
        }
      else if(rc == TRADE_RETCODE_INVALID_STOPS && g_stopsOnOpen)
        {
         g_stopsOnOpen = false;
         V11Log(0, "Broker rejected stops on the market order - trades now open without them and the stops are attached at once.");
         g_tr.open[i].state = V11_ST_TODO;
        }
      else if(IsPriceRetry(rc) && g_tr.open[i].attempts <= InpMaxRetries)
         g_tr.open[i].state = V11_ST_TODO;
      else
        {
         FailOpen(i, RetcodeText(rc));
         BackOff(rc);
        }
      return;
     }
  }

void StartTransition(const int kind, const ulong closeTicket, const double closeNet, const V11Plan &plan, const string why)
  {
   ResetTr();
   g_trSeq++;
   g_tr.kind        = kind;
   g_tr.seq         = g_trSeq;
   g_tr.startMs     = ClockMs();
   g_tr.closeTicket = closeTicket;
   g_tr.closeState  = (closeTicket != 0 ? V11_ST_TODO : V11_ST_DONE);
   g_tr.closeNet    = closeNet;
   g_tr.nOpen       = (plan.n < 3 ? plan.n : 3);
   for(int i = 0; i < g_tr.nOpen; i++)
     {
      g_tr.open[i].dir   = plan.dir[i];
      g_tr.open[i].state = V11_ST_TODO;
      if(kind == V11_TR_FILL)
         g_tr.open[i].holeMsc = PopHole();
     }
   g_trWhy         = why;
   g_trBeforeCount = g_posCount;
   for(int i = 0; i < g_posCount; i++)
      g_trBefore[i] = g_pos[i].ticket;
   if(closeTicket != 0)
     {
      TagClose(closeTicket, (kind == V11_TR_REANCHOR ? "RA" : "HV"));
      int p = FindPos(closeTicket);
      if(p >= 0 && !g_pos[p].closing)
        {
         g_pos[p].closing = true;
         if(g_pos[p].dir > 0)
            g_nb--;
         else
            g_ns--;
        }
     }
   g_lastAction = TrKindName(kind) + ": " + why;
   V11Log(1, StringFormat("%s #%d: %s", TrKindName(kind), g_tr.seq, why));
   ServiceTransition();
  }

//+------------------------------------------------------------------+
//| Planner: what the basket does next (spec sections 2, 5, 6)       |
//+------------------------------------------------------------------+
void PlanNext()
  {
   if(g_tr.kind != V11_TR_NONE)
     {
      g_nextText = "busy: " + g_trWhy;
      return;
     }
   string why = "";
   g_gateOpen   = EntryGate(1, 0, why);
   g_gateReason = why;
   if(!g_tradeEnabled)
     {
      g_nextText = "no orders: " + g_tradeBlockMsg;
      return;
     }
   if(g_flattenMode != "")
     {
      g_nextText = "keep the basket flat: " + g_flattenMode;
      return;
     }
   datetime now = NowServer();
   if(now < g_execPauseUntil)
     {
      g_nextText = StringFormat("wait %s (back-off: %s)", FormatDuration((long)(g_execPauseUntil - now)), g_execPauseReason);
      return;
     }
   if(MarketQuiet())
     {
      g_nextText = "market closed (no quotes)";
      return;
     }
   //--- 1. fill: the start pair, a waiting place, or the third trade of the direction
   V11Plan fill;
   FillPlan(g_nb, g_ns, g_bias, fill);
   if(fill.n > 0)
     {
      if(EntryGate(fill.n, 0, why))
        {
         string what = (g_nb + g_ns == 0 ? "start pair BUY + SELL" : "fill " + DirName(fill.dir[0]));
         StartTransition(V11_TR_FILL, 0, 0.0, fill, StringFormat("%s | basket %s -> target %s (%s)", what,
                         BasketText(g_nb, g_ns), TargetText(g_bias), BiasName(g_bias)));
         return;
        }
     }
   bool waiting = (fill.n > 0 && g_nb + g_ns > 0);
   //--- 2. harvest: the trade with the highest net at or above the harvest line
   int h = BestHarvest();
   if(h >= 0)
     {
      int     dir    = g_pos[h].dir;
      int     nbA    = g_nb - (dir > 0 ? 1 : 0);
      int     nsA    = g_ns - (dir < 0 ? 1 : 0);
      ulong   ticket = g_pos[h].ticket;
      double  net    = g_pos[h].net;
      V11Plan refill;
      RefillPlan(nbA, nsA, g_bias, refill);
      string desc = StringFormat("%s #%I64u net %s -> %s | %s", DirName(dir), ticket, FmtSigned(net), PlanText(refill), BiasName(g_bias));
      if(refill.n == 0 || EntryGate(refill.n, (UseAsync() ? 0 : 1), why))
        {
         StartTransition(V11_TR_HARVEST, ticket, net, refill, desc);
         return;
        }
      if(!waiting)
        {
         V11Plan none;
         none.n = 0;
         StartTransition(V11_TR_HARVEST, ticket, net, none, StringFormat("%s #%I64u net %s, refill later (%s)",
                         DirName(dir), ticket, FmtSigned(net), why));
         return;
        }
      g_nextText = "harvest waits until the empty place is filled (" + why + "); the backup TP stays on the server";
      return;
     }
   //--- 3. re-anchor: pay for the most stuck trade from the bank and reopen at the current price
   if(InpUseReanchor && !waiting)
     {
      int w = WorstStuck();
      if(w >= 0)
        {
         double need = -g_pos[w].net + InpBankKeep;
         if(g_bank + 1e-9 < need)
           {
            g_nextText = StringFormat("%s #%I64u stuck at %s - re-anchor when the bank reaches %s (now %s)",
                                      DirName(g_pos[w].dir), g_pos[w].ticket, FmtSigned(g_pos[w].net), FmtMoney(need), FmtMoney(g_bank));
            return;
           }
         if((long)(now - g_lastReanchor) < V11_REANCHOR_GAP_SEC)
           {
            g_nextText = "re-anchor pause";
            return;
           }
         int     dir = g_pos[w].dir;
         V11Plan refill;
         RefillPlan(g_nb - (dir > 0 ? 1 : 0), g_ns - (dir < 0 ? 1 : 0), g_bias, refill);
         if(EntryGate(refill.n, (UseAsync() ? 0 : 1), why))
           {
            StartTransition(V11_TR_REANCHOR, g_pos[w].ticket, g_pos[w].net, refill,
                            StringFormat("%s #%I64u net %s paid from the bank %s -> %s | %s", DirName(dir), g_pos[w].ticket,
                                         FmtSigned(g_pos[w].net), FmtMoney(g_bank), PlanText(refill), BiasName(g_bias)));
            return;
           }
         g_nextText = "re-anchor waits: " + why;
         return;
        }
     }
   if(waiting)
      g_nextText = "waiting to fill " + DirName(fill.dir[0]) + ": " + g_gateReason;
   else
      g_nextText = StringFormat("harvest each trade at net %s", FmtMoney(InpHarvestNet));
  }

//+------------------------------------------------------------------+
//| Event CSV (Common\Files)                                         |
//+------------------------------------------------------------------+
void CsvInit()
  {
   g_csvOk = false;
   if(!InpWriteCsv || g_isOptim)
      return;
   g_csvName = StringFormat("V11_%I64d_%s_events%s.csv", AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, (g_isTester ? "_tester" : ""));
   int flags = FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_WRITE | FILE_SHARE_READ;
   if(!g_isTester)
      flags |= FILE_READ;                // live: keep the old lines and append
   int h = FileOpen(g_csvName, flags, ',');
   if(h == INVALID_HANDLE)
     {
      V11Log(0, "CSV could not be opened: " + g_csvName);
      return;
     }
   if(FileSize(h) == 0)
      FileWrite(h, "time", "event", "ticket", "dir", "net", "reason", "bank_after", "pulse", "basket", "day_net");
   FileClose(h);
   g_csvOk = true;
  }

void CsvEvent(const string ev, const ulong ticket, const int dir, const double net, const string reason)
  {
   if(!g_csvOk)
      return;
   int h = FileOpen(g_csvName, FILE_CSV | FILE_ANSI | FILE_COMMON | FILE_READ | FILE_WRITE | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, TimeToString(NowServer(), TIME_DATE | TIME_SECONDS), ev, IntegerToString((long)ticket),
             (dir == 0 ? "-" : DirName(dir)), DoubleToString(net, 2), CsvSafe(reason), DoubleToString(g_bank, 2),
             BiasName(g_bias), BasketText(g_nb, g_ns), DoubleToString(DayNet(), 2));
   FileClose(h);
  }

//+------------------------------------------------------------------+
//| Persistence (GlobalVariables, live only)                         |
//+------------------------------------------------------------------+
string GvName(const string key)
  {
   return g_gvPrefix + key;
  }

void GvSet(const string key, const double value)
  {
   GlobalVariableSet(GvName(key), value);
  }

bool GvGet(const string key, double &value)
  {
   string name = GvName(key);
   if(!GlobalVariableCheck(name))
      return false;
   value = GlobalVariableGet(name);
   return true;
  }

void SaveState(const bool force)
  {
   if(g_isTester || g_gvPrefix == "")
      return;
   datetime now = NowServer();
   if(!force && (!g_stateDirty || now == g_lastSave))
      return;
   GvSet("ver", 1.0);
   GvSet("bank", g_bank);
   GvSet("deal_hi", (double)(g_maxDealSeen >> 32));
   GvSet("deal_lo", (double)(g_maxDealSeen & 0xFFFFFFFF));
   GvSet("peak", g_peakEquity);
   GvSet("kill", (g_haltKill ? 1.0 : 0.0));
   GvSet("haltday", (g_haltDay ? (double)g_haltDayKey : 0.0));
   GvSet("cool", (double)g_cooldownUntil);
   g_stateDirty = false;
   g_lastSave   = now;
  }

bool LoadState(ulong &lastDeal)
  {
   lastDeal = 0;
   double v = 0.0;
   if(!GvGet("ver", v))
      return false;
   if(GvGet("bank", v))
      g_bank = MathMax(0.0, v);
   double hi = 0.0;
   double lo = 0.0;
   GvGet("deal_hi", hi);
   GvGet("deal_lo", lo);
   lastDeal = (((ulong)hi) << 32) | (ulong)lo;
   if(GvGet("peak", v) && v > 0.0)
      g_peakEquity = v;
   if(GvGet("kill", v))
      g_haltKill = (v > 0.5);
   if(GvGet("haltday", v) && v > 0.5)
     {
      g_haltDay    = true;
      g_haltDayKey = (int)v;
      g_haltReason = "daily loss limit (hit before the restart)";
     }
   if(GvGet("cool", v))
      g_cooldownUntil = (datetime)(long)v;
   return true;
  }

//+------------------------------------------------------------------+
//| Protection: kill switch, daily limit, basket stop, Friday        |
//+------------------------------------------------------------------+
void CheckProtection()
  {
   datetime now    = NowServer();
   double   equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_peakEquity)
     {
      g_peakEquity = equity;
      g_stateDirty = true;
     }
   if(!g_haltKill && g_peakEquity > 0.0 && equity <= g_peakEquity * (1.0 - InpEquityKillPct / 100.0))
     {
      g_haltKill   = true;
      g_stateDirty = true;
      V11Log(0, StringFormat("EQUITY KILL SWITCH: equity %s is %.1f%% below its peak %s. v11 closes the basket and stops. Set InpResetKillSwitch = true to restart.",
                             FmtMoney(equity), 100.0 * (1.0 - equity / g_peakEquity), FmtMoney(g_peakEquity)));
      CsvEvent("KILL_SWITCH", 0, 0, equity - g_peakEquity, "equity below its peak");
     }
   double dayNet = DayNet();
   if(!(g_haltDay && g_haltDayKey == g_dayKey) && dayNet <= -InpDailyLossLimit)
     {
      g_haltDay    = true;
      g_haltDayKey = g_dayKey;
      g_haltReason = StringFormat("day %s (closed %s, open %s)", FmtMoney(dayNet), FmtMoney(g_realizedToday), FmtMoney(g_floating));
      g_stateDirty = true;
      V11Log(1, "DAILY LOSS LIMIT: " + g_haltReason + " - basket closed, no trading until the next server day");
      CsvEvent("DAILY_LIMIT", 0, 0, dayNet, g_haltReason);
     }
   double basket = BasketNet();
   if(g_posCount > 0 && now >= g_cooldownUntil && basket <= -InpBasketStop)
     {
      g_cooldownUntil = now + InpBasketCooldownMin * 60;
      g_stateDirty    = true;
      V11Log(1, StringFormat("BASKET STOP: open trades together at %s (limit -%s) - closing all, new cycle after %d min",
                             FmtMoney(basket), FmtMoney(InpBasketStop), InpBasketCooldownMin));
      CsvEvent("BASKET_STOP", 0, 0, basket, "open trades reached the basket stop");
     }
   string mode = "";
   string tag  = "";
   if(g_haltKill)
     {
      mode = "equity kill switch (set InpResetKillSwitch = true to restart)";
      tag  = "KS";
     }
   else if(g_haltDay && g_haltDayKey == g_dayKey)
     {
      mode = "daily loss limit: " + g_haltReason;
      tag  = "DL";
     }
   else if(now < g_cooldownUntil)
     {
      mode = "basket stop cooldown " + FormatDuration((long)(g_cooldownUntil - now));
      tag  = "BS";
     }
   else if(FridayFlattenTime(now))
     {
      mode = "Friday flatten (weekend)";
      tag  = "FF";
     }
   if(mode != "" && g_flattenMode == "")
      AbortTransition(mode);
   g_flattenMode = mode;
   if(mode != "" && g_posCount > 0)
      FlattenAll(tag);
  }

//+------------------------------------------------------------------+
//| Deal accounting                                                  |
//+------------------------------------------------------------------+
double DealMoney(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_FEE);
  }

//--- everything about a position from its deals
void PositionHistory(const ulong posId, double &net, double &comm, double &volIn, double &volOut, int &dir, bool &ours,
                     ENUM_DEAL_REASON &lastReason, string &lastComment)
  {
   net         = 0.0;
   comm        = 0.0;
   volIn       = 0.0;
   volOut      = 0.0;
   dir         = 0;
   ours        = false;
   lastReason  = DEAL_REASON_CLIENT;
   lastComment = "";
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
         dir    = ((ENUM_DEAL_TYPE)HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY ? 1 : -1);
         if(HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic && HistoryDealGetString(deal, DEAL_SYMBOL) == _Symbol)
            ours = true;
        }
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
        {
         volOut     += HistoryDealGetDouble(deal, DEAL_VOLUME);
         lastReason  = (ENUM_DEAL_REASON)HistoryDealGetInteger(deal, DEAL_REASON);
         lastComment = HistoryDealGetString(deal, DEAL_COMMENT);
        }
     }
  }

string CloseReasonName(const ENUM_DEAL_REASON reason, const string comment, const ulong posId)
  {
   if(reason == DEAL_REASON_TP)
      return "TP";                       // backup TP on the server: a harvest
   if(reason == DEAL_REASON_SL)
      return "DISASTER_SL";
   if(reason == DEAL_REASON_SO)
      return "STOP_OUT";
   if(reason == DEAL_REASON_EXPERT)
     {
      string tag = CloseTag(posId);
      if(tag == "")
         tag = TagFromComment(comment);
      return TagName(tag);
     }
   if(reason == DEAL_REASON_CLIENT || reason == DEAL_REASON_MOBILE || reason == DEAL_REASON_WEB)
      return "MANUAL";
   return "OTHER";
  }

//--- a basket trade is fully closed: bank, day counters, log, CSV
void OnPositionClosed(const ulong posId, const int dir, const double net, const double comm, const double volIn,
                      const string reasonName, const bool today, const bool replay)
  {
   bool   harvest  = (reasonName == "HARVEST" || reasonName == "TP");
   bool   reanchor = (reasonName == "REANCHOR");
   double before   = g_bank;
   g_bank       = MathMax(0.0, g_bank + net);
   g_stateDirty = true;
   if(today)
     {
      g_closesToday++;
      if(harvest)
        {
         g_harvestsToday++;
         g_harvestNetToday += net;
        }
      else if(reanchor)
        {
         g_reanchorsToday++;
         g_reanchorNetToday += net;
        }
     }
   if(volIn > 0.0)
     {
      double perLot = -comm / volIn;
      if(perLot > g_commPerLotRT + 0.01)
        {
         V11Log(1, StringFormat("Commission from real deals is %s per lot round trip (was %s) - using the higher value.",
                                FmtMoney(perLot), FmtMoney(g_commPerLotRT)));
         g_commPerLotRT = perLot;
        }
     }
   string ev = (harvest ? "HARVEST" : (reanchor ? "REANCHOR" : "CLOSE"));
   if(!replay)
      g_lastAction = StringFormat("%s %s #%I64u net %s (%s)", ev, DirName(dir), posId, FmtSigned(net), reasonName);
   V11Log(1, StringFormat("%s%s %s #%I64u net %s (%s) | bank %s -> %s | today: %d harvests %s, %d re-anchors %s",
                          (replay ? "[while offline] " : ""), ev, DirName(dir), posId, FmtSigned(net), reasonName,
                          FmtMoney(before), FmtMoney(g_bank), g_harvestsToday, FmtSigned(g_harvestNetToday),
                          g_reanchorsToday, FmtSigned(g_reanchorNetToday)));
   CsvEvent(ev, posId, dir, net, reasonName);
   if(g_tr.kind != V11_TR_NONE && posId == g_tr.closeTicket &&
      (g_tr.closeState == V11_ST_SENT || g_tr.closeState == V11_ST_ACCEPTED))
     {
      g_tr.closeState = V11_ST_DONE;
      g_tr.closeMsc   = ClockMs();
      ForgetKnown(posId);
     }
  }

//--- start-up: today's figures from history, and closes that happened while v11 was not running
void StartHistory(const datetime now, const bool haveState, const ulong lastDeal)
  {
   g_dayStart = DayStartOf(now);
   g_dayKey   = DayKey(now);
   datetime from = (haveState ? now - 7 * 86400 : g_dayStart);
   if(!HistorySelect(from, now + 3600))
      return;
   int n = HistoryDealsTotal();
   ulong    dTicket[];
   ulong    dPos[];
   int      dEntry[];
   long     dMagic[];
   double   dMoney[];
   datetime dTime[];
   ArrayResize(dTicket, n);
   ArrayResize(dPos, n);
   ArrayResize(dEntry, n);
   ArrayResize(dMagic, n);
   ArrayResize(dMoney, n);
   ArrayResize(dTime, n);
   int   m       = 0;
   ulong maxSeen = lastDeal;
   for(int i = 0; i < n; i++)
     {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(deal > maxSeen)
         maxSeen = deal;
      if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      dTicket[m] = deal;
      dPos[m]    = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      dEntry[m]  = (int)HistoryDealGetInteger(deal, DEAL_ENTRY);
      dMagic[m]  = HistoryDealGetInteger(deal, DEAL_MAGIC);
      dMoney[m]  = DealMoney(deal);
      dTime[m]   = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
      m++;
     }
   //--- a position is v11's when one of its deals carries the v11 magic
   ulong ourPos[];
   int   nOur = 0;
   for(int i = 0; i < m; i++)
     {
      if(dMagic[i] != InpMagic)
         continue;
      bool dup = false;
      for(int q = 0; q < nOur; q++)
         if(ourPos[q] == dPos[i])
           {
            dup = true;
            break;
           }
      if(dup)
         continue;
      ArrayResize(ourPos, nOur + 1);
      ourPos[nOur] = dPos[i];
      nOur++;
     }
   for(int i = 0; i < m; i++)
     {
      if(dTime[i] < g_dayStart)
         continue;
      for(int q = 0; q < nOur; q++)
         if(ourPos[q] == dPos[i])
           {
            g_realizedToday += dMoney[i];
            break;
           }
     }
   //--- closed v11 positions: today's counters and the offline catch-up of the bank
   for(int q = 0; q < nOur; q++)
     {
      ulong    pos       = ourPos[q];
      ulong    lastExit  = 0;
      datetime closeTime = 0;
      for(int i = 0; i < m; i++)
         if(dPos[i] == pos && (dEntry[i] == (int)DEAL_ENTRY_OUT || dEntry[i] == (int)DEAL_ENTRY_OUT_BY) && dTicket[i] > lastExit)
           {
            lastExit  = dTicket[i];
            closeTime = dTime[i];
           }
      if(lastExit == 0 || PositionSelectByTicket(pos))
         continue;
      double           net    = 0.0;
      double           comm   = 0.0;
      double           volIn  = 0.0;
      double           volOut = 0.0;
      int              dir    = 0;
      bool             ours   = false;
      ENUM_DEAL_REASON rsn    = DEAL_REASON_CLIENT;
      string           cmt    = "";
      PositionHistory(pos, net, comm, volIn, volOut, dir, ours, rsn, cmt);
      string why      = CloseReasonName(rsn, cmt, pos);
      bool   today    = (closeTime >= g_dayStart);
      bool   catchUp  = (haveState && lastExit > lastDeal);
      if(catchUp)
         OnPositionClosed(pos, dir, net, comm, volIn, why, today, true);
      else if(today)
        {
         g_closesToday++;
         if(why == "HARVEST" || why == "TP")
           {
            g_harvestsToday++;
            g_harvestNetToday += net;
           }
         else if(why == "REANCHOR")
           {
            g_reanchorsToday++;
            g_reanchorNetToday += net;
           }
        }
     }
   g_maxDealSeen = maxSeen;
  }

//+------------------------------------------------------------------+
//| Day change                                                       |
//+------------------------------------------------------------------+
void LogDaySummary()
  {
   if(g_dayKey == 0)
      return;
   double avg = (g_gapCount > 0 ? g_gapSumMs / g_gapCount : 0.0);
   V11Log(1, StringFormat("DAY %04d.%02d.%02d | harvests %d %s | re-anchors %d %s | closed today %s (%d trades) | gaps avg %.0f ms, max %.0f ms (%d) | bank %s",
                          g_dayKey / 10000, (g_dayKey / 100) % 100, g_dayKey % 100, g_harvestsToday, FmtSigned(g_harvestNetToday),
                          g_reanchorsToday, FmtSigned(g_reanchorNetToday), FmtSigned(g_realizedToday), g_closesToday,
                          avg, g_gapMaxMs, g_gapCount, FmtMoney(g_bank)));
  }

void CheckDayRollover(const datetime now)
  {
   int key = DayKey(now);
   if(key == g_dayKey)
      return;
   LogDaySummary();
   g_dayKey           = key;
   g_dayStart         = DayStartOf(now);
   g_realizedToday    = 0.0;
   g_harvestsToday    = 0;
   g_harvestNetToday  = 0.0;
   g_reanchorsToday   = 0;
   g_reanchorNetToday = 0.0;
   g_closesToday      = 0;
   g_gapCount         = 0;
   g_gapSumMs         = 0.0;
   g_gapMaxMs         = 0.0;
   g_gapLastMs        = -1.0;
   if(g_haltDay && g_haltDayKey != key)
     {
      g_haltDay    = false;
      g_haltReason = "";
      g_stateDirty = true;
      V11Log(1, "New server day: the daily halt is cleared.");
     }
  }

//+------------------------------------------------------------------+
//| Dashboard                                                        |
//+------------------------------------------------------------------+
string PanelName(const int i)
  {
   return V11_PREFIX + "P_" + IntegerToString(i);
  }

void PanelCreate()
  {
   string bg = V11_PREFIX + "P_BG";
   if(ObjectFind(0, bg) < 0 && ObjectCreate(0, bg, OBJ_RECTANGLE_LABEL, 0, 0, 0))
     {
      ObjectSetInteger(0, bg, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, bg, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, bg, OBJPROP_YDISTANCE, 24);
      ObjectSetInteger(0, bg, OBJPROP_XSIZE, 820);
      ObjectSetInteger(0, bg, OBJPROP_YSIZE, V11_PANEL_LINES * 16 + 12);
      ObjectSetInteger(0, bg, OBJPROP_BGCOLOR, C'16,20,28');
      ObjectSetInteger(0, bg, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bg, OBJPROP_COLOR, C'70,80,100');
      ObjectSetInteger(0, bg, OBJPROP_BACK, false);
      ObjectSetInteger(0, bg, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, bg, OBJPROP_HIDDEN, true);
     }
   for(int i = 0; i < V11_PANEL_LINES; i++)
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
   if(i < 0 || i >= V11_PANEL_LINES)
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

color BiasColor(const int bias)
  {
   if(bias > 0)
      return clrLime;
   if(bias < 0)
      return clrTomato;
   return clrSilver;
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
   datetime now = NowServer();

   string mode = (g_tradeEnabled ? StringFormat("TRADE (%s)", (UseAsync() ? "async swaps" : "sync")) : "NO ORDERS - " + g_tradeBlockMsg);
   PanelLine(0, StringFormat("GOLD TRIAD HARVESTER v11.00   build %s   |   %s", V11_BUILD, mode), (g_tradeEnabled ? clrWhite : clrOrange));
   string med = (g_spreadCount >= V11_MIN_SPREAD_SAMPLES ? StringFormat("%.0f", g_spreadMedian) : "collecting");
   PanelLine(1, StringFormat("%s   server %s   |   %.1f ticks/s   |   spread %.0f pts (median %s)   |   filling %s",
                             _Symbol, TimeToString(now, TIME_SECONDS), g_wRate.Count() / 10.0, CurrentSpreadPts(), med,
                             FillingName(g_filling)), clrSilver);

   //--- Pulse
   if(g_p.ready)
     {
      string cand = (g_candCount > 0 ? StringFormat("   |   next: %s %d/%d", BiasName(g_candidate), g_candCount, InpPulseConfirmBars) : "");
      PanelLine(2, StringFormat("PULSE %-7s for %s   |   score %+.0f   [UP >= +%.0f, DOWN <= -%.0f, NEUTRAL within +/-%.0f]%s",
                                BiasName(g_bias), FormatDuration((long)(now - g_biasSince)), g_p.score, InpPulseOn, InpPulseOn,
                                InpPulseOff, cand), BiasColor(g_bias));
      PanelLine(3, StringFormat("      trend %+.2f   EMA %+.2f   structure %+.2f   efficiency %+.2f   |   ATR(M1) %.0f pts",
                                g_p.t, g_p.e, g_p.s, g_p.m, g_p.atrPts), clrSilver);
     }
   else
     {
      PanelLine(2, "PULSE warming up: " + g_dataReason, clrKhaki);
      PanelLine(3, " ", clrSilver);
     }

   //--- basket and its trades
   string busy = (g_tr.kind != V11_TR_NONE ? "   |   " + TrKindName(g_tr.kind) + " in progress" : "");
   PanelLine(4, StringFormat("BASKET %s   |   target %s   |   open net %s%s", BasketText(g_nb, g_ns), TargetText(g_bias),
                             FmtSigned(BasketNet()), busy), clrWhite);
   for(int r = 0; r < 3; r++)
     {
      if(r < g_posCount)
        {
         double toLine = InpHarvestNet - g_pos[r].net;
         string role   = (g_bias == 0 ? "" : (g_pos[r].dir == g_bias ? "   with the trend" : "   against the trend"));
         string extra  = (g_pos[r].closing ? "   [closing]" : "");
         if(g_pos[r].net <= -InpReanchorLoss)
            extra += "   [stuck]";
         PanelLine(5 + r, StringFormat("  %-4s #%I64u @ %s   net %s   %s   age %s%s%s", DirName(g_pos[r].dir), g_pos[r].ticket,
                                       FmtPrice(g_pos[r].open), FmtSigned(g_pos[r].net),
                                       (toLine > 0.0 ? StringFormat("harvest in %s", FmtMoney(toLine)) : "HARVEST"),
                                       FormatDuration((long)(now - g_pos[r].opened)), role, extra),
                   (g_pos[r].net >= 0.0 ? clrLime : clrTomato));
        }
      else
         PanelLine(5 + r, (r == 0 ? "  (no trades)" : "  -"), clrGray);
     }
   if(g_posCount > 3)
      PanelLine(7, StringFormat("  ... %d more trades (extras close at harvest without refill)", g_posCount - 2), clrOrange);

   //--- bank, today, gaps
   int    w        = WorstStuck();
   string stuckTxt = "no stuck trade";
   if(w >= 0)
      stuckTxt = StringFormat("stuck %s %s - needs %s", DirName(g_pos[w].dir), FmtSigned(g_pos[w].net), FmtMoney(-g_pos[w].net + InpBankKeep));
   PanelLine(8, StringFormat("HARVEST BANK %s   |   re-anchor at %s loss, keep %s   |   %s   |   re-anchor %s",
                             FmtMoney(g_bank), FmtMoney(InpReanchorLoss), FmtMoney(InpBankKeep), stuckTxt, (InpUseReanchor ? "on" : "off")),
             clrDeepSkyBlue);
   PanelLine(9, StringFormat("TODAY harvests %d %s   |   re-anchors %d %s   |   closed %s   |   day net %s (limit -%s)",
                             g_harvestsToday, FmtSigned(g_harvestNetToday), g_reanchorsToday, FmtSigned(g_reanchorNetToday),
                             FmtSigned(g_realizedToday), FmtSigned(DayNet()), FmtMoney(InpDailyLossLimit)),
             (DayNet() >= 0.0 ? clrLime : clrTomato));
   double avg = (g_gapCount > 0 ? g_gapSumMs / g_gapCount : 0.0);
   PanelLine(10, StringFormat("GAP (empty place before refill)   last %s   |   average %.0f ms   |   max %.0f ms   |   refills %d",
                              (g_gapLastMs >= 0.0 ? StringFormat("%.0f ms", g_gapLastMs) : "-"), avg, g_gapMaxMs, g_gapCount), clrSilver);

   //--- gate, next step, protection, news, last action, account
   PanelLine(11, (g_gateOpen ? "ENTRY GATE open" : "ENTRY GATE closed - " + g_gateReason), (g_gateOpen ? clrLime : clrOrange));
   PanelLine(12, "NEXT " + g_nextText, clrWhite);
   string prot = StringFormat("PROTECTION basket stop -%s (now %s)   |   disaster stop %s per trade", FmtMoney(InpBasketStop),
                              FmtSigned(BasketNet()), FmtMoney(InpDisasterLoss));
   if(g_flattenMode != "")
      prot = "FLAT: " + g_flattenMode;
   PanelLine(13, prot, (g_flattenMode != "" ? clrOrange : clrSilver));
   string nw = "";
   if(NewsWindow(now, nw))
      PanelLine(14, "NEWS WINDOW: " + nw, clrOrange);
   else
      PanelLine(14, "News: " + g_newsStatus + (g_newsCount > 0 ? "   |   " + NextNewsText(now) : ""), clrSilver);
   PanelLine(15, "LAST " + g_lastAction, clrSilver);
   double ml = AccountInfoDouble(ACCOUNT_MARGIN_LEVEL);
   PanelLine(16, StringFormat("ACCOUNT %s   equity %s (peak %s, kill at -%.0f%%)   |   margin level %s   |   commission %s/lot RT   |   magic %I64d",
                              g_ccy, FmtMoney(AccountInfoDouble(ACCOUNT_EQUITY)), FmtMoney(g_peakEquity), InpEquityKillPct,
                              (ml > 0.0 ? StringFormat("%.0f%%", ml) : "-"), FmtMoney(g_commPerLotRT), InpMagic), clrGray);
   PanelLine(17, StringFormat("Harvest at net %s   |   backup TP %s   |   lot %.2f   |   CSV %s", FmtMoney(InpHarvestNet),
                              FmtMoney(InpBackupTpNet), g_lots, (g_csvOk ? g_csvName : "off")), clrGray);
   ChartRedraw(0);
  }

//+------------------------------------------------------------------+
//| Main cycle (ticks, timer and trade events)                       |
//+------------------------------------------------------------------+
void Drive()
  {
   datetime now = NowServer();
   CheckDayRollover(now);
   SampleSpread();
   UpdatePulse();
   CheckShock();
   RefreshNews(false);
   ScanPositions();
   ProtectPositions();
   CheckProtection();
   ServiceTransition();
   if(g_tr.kind == V11_TR_NONE)
      PlanNext();
   SaveState(false);
   UpdatePanel(false);
  }

void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
  {
   if(trans.type == TRADE_TRANSACTION_REQUEST)
     {
      if(g_tr.kind != V11_TR_NONE)
        {
         HandleRequestResult(result.request_id, result.retcode, result.order);
         Drive();
        }
      return;
     }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   ulong deal = trans.deal;
   if(deal == 0 || deal <= g_maxDealSeen)
      return;
   if(!HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
      return;
   long             magic = HistoryDealGetInteger(deal, DEAL_MAGIC);
   ENUM_DEAL_ENTRY  entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   double           money = DealMoney(deal);
   datetime         dt    = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
   ulong            posId = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   bool             isOut = (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY);
   if(magic != InpMagic && !isOut)
      return;
   double           net    = 0.0;
   double           comm   = 0.0;
   double           volIn  = 0.0;
   double           volOut = 0.0;
   int              dir    = 0;
   bool             ours   = (magic == InpMagic);
   ENUM_DEAL_REASON rsn    = DEAL_REASON_CLIENT;
   string           cmt    = "";
   if(isOut)
     {
      bool entryOurs = false;
      PositionHistory(posId, net, comm, volIn, volOut, dir, entryOurs, rsn, cmt);
      ours = (ours || entryOurs);        // e.g. closed by hand: that deal carries no magic
     }
   if(!ours)
      return;
   g_maxDealSeen = deal;
   g_stateDirty  = true;
   if(dt >= g_dayStart)
      g_realizedToday += money;
   if(isOut && volIn > 0.0 && volOut >= volIn - 1e-9)
      OnPositionClosed(posId, dir, net, comm, volIn, CloseReasonName(rsn, cmt, posId), (dt >= g_dayStart), false);
   Drive();                              // react at once: confirm the swap, refill a place
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_isTester    = (MQLInfoInteger(MQL_TESTER) != 0);
   g_isOptim     = (MQLInfoInteger(MQL_OPTIMIZATION) != 0);
   g_drawObjects = (!g_isTester || MQLInfoInteger(MQL_VISUAL_MODE) != 0);
   g_point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_tickSize    = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   g_ccy         = AccountInfoString(ACCOUNT_CURRENCY);
   if(g_point <= 0.0)
     {
      Print("[V11] ERROR: symbol point size is 0 - cannot run.");
      return INIT_FAILED;
     }
   string err = "";
   if(!ValidateInputs(err))
     {
      Print("[V11] INPUT ERROR: ", err);
      return INIT_PARAMETERS_INCORRECT;
     }
   g_isHedging = ((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
   if(!g_isHedging && InpMode == V11_MODE_TRADE)
     {
      Print("[V11] ERROR: v11 needs a hedging account (it holds BUY and SELL trades together). Use OBSERVE mode on this account.");
      return INIT_FAILED;
     }
   if(StringFind(_Symbol, "XAU") < 0)
      V11Log(0, "WARNING: v11 is built for gold (XAU...). Current symbol: " + _Symbol);

   ResetAll();
   g_lots = NormalizeLotsDown(InpLots);
   if(g_lots <= 0.0)
     {
      Print("[V11] ERROR: InpLots is below the broker's minimum volume.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(MathAbs(g_lots - InpLots) > 1e-9)
      V11Log(0, StringFormat("WARNING: InpLots %.3f rounded down to %.2f (broker volume step).", InpLots, g_lots));
   g_commPerLotRT = InpCommissionPerLotRT;
   g_filling      = DetectFilling();
   g_stopsLevel   = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   g_stopsOnOpen  = true;
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   g_peakEquity   = equity;

   bool isReal = ((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_REAL);
   g_tradeEnabled  = false;
   g_tradeBlockMsg = "";
   if(InpMode == V11_MODE_OBSERVE)
      g_tradeBlockMsg = "OBSERVE mode";
   else if(isReal && !g_isTester && !InpAllowRealAccount)
      g_tradeBlockMsg = "real-money account locked (set InpAllowRealAccount = true)";
   else
      g_tradeEnabled = true;

   if(!CreateHandles())
     {
      Print("[V11] ERROR: could not create indicator handles, error ", GetLastError());
      ReleaseHandles();
      return INIT_FAILED;
     }

   //--- saved state (live only), then history
   g_gvPrefix = StringFormat("V11_%I64d_%s_%I64d_", AccountInfoInteger(ACCOUNT_LOGIN), _Symbol, InpMagic);
   ulong lastDeal  = 0;
   bool  haveState = (!g_isTester && LoadState(lastDeal));
   if(InpResetBank)
     {
      g_bank = 0.0;
      V11Log(1, "Harvest Bank reset to 0 (InpResetBank = true).");
     }
   if(InpResetKillSwitch && g_haltKill)
     {
      g_haltKill = false;
      V11Log(1, "Equity kill switch reset (InpResetKillSwitch = true).");
     }
   if(InpResetKillSwitch || g_peakEquity < equity)
      g_peakEquity = equity;
   StartHistory(NowServer(), haveState, lastDeal);
   g_stateDirty = true;
   CsvInit();

   if(!g_isTester)
     {
      ObjectsDeleteAll(0, V11_PREFIX);
      if(!EventSetMillisecondTimer(250))
         EventSetTimer(1);
     }
   g_biasSince = NowServer();

   V11Log(1, StringFormat("Gold Triad Harvester v11.00 build %s | %s | %s %s account | %s | equity %s | bank %s%s",
                          V11_BUILD, _Symbol, (isReal ? "REAL" : "demo/contest"), (g_isHedging ? "hedging" : "netting"),
                          g_ccy, FmtMoney(equity), FmtMoney(g_bank), (haveState ? " (restored)" : "")));
   if(g_tradeEnabled)
      V11Log(1, StringFormat("TRADING ENABLED (%s). Every trade carries a disaster stop (%s) and a backup TP (net %s) on the server.",
                             (UseAsync() ? "async swaps" : "sync swaps"), FmtMoney(InpDisasterLoss), FmtMoney(InpBackupTpNet)));
   else
      V11Log(1, "NO ORDERS: " + g_tradeBlockMsg + ".");
   V11Log(1, StringFormat("Basket: UP = 2 BUY + 1 SELL, DOWN = 1 BUY + 2 SELL, NEUTRAL = 1 BUY + 1 SELL | harvest at net %s | lot %.2f | re-anchor %s at loss %s (keep %s)",
                          FmtMoney(InpHarvestNet), g_lots, (InpUseReanchor ? "on" : "off"), FmtMoney(InpReanchorLoss), FmtMoney(InpBankKeep)));
   V11Log(1, StringFormat("Protection: basket stop %s (cooldown %d min) | daily limit %s | kill switch -%.0f%% | Friday last entry %s, flatten %s",
                          FmtMoney(InpBasketStop), InpBasketCooldownMin, FmtMoney(InpDailyLossLimit), InpEquityKillPct,
                          MinToHHMM(g_fridayLastMin), MinToHHMM(g_fridayFlattenMin)));
   if(g_isTester)
      V11Log(1, "Strategy Tester: swaps are sent synchronously and the news filter is skipped.");

   RefreshNews(true);
   if(RefreshTick())
      Drive();
   SaveState(true);
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
   SaveState(true);
   ReleaseHandles();
   ObjectsDeleteAll(0, V11_PREFIX);
   ChartRedraw(0);
   if(g_posCount > 0)
      V11Log(1, StringFormat("Stopped with %d open trade(s). They keep their disaster stop and backup TP on the server.", g_posCount));
   V11Log(1, StringFormat("Stopped (deinit reason %d). Bank %s.", reason, FmtMoney(g_bank)));
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
