//+------------------------------------------------------------------+
//|                           Gold_Bidirectional_Harvester_v8.00.mq5 |
//|      Harvest-first XAUUSD EA with a ledger-based recovery cycle  |
//+------------------------------------------------------------------+
//| Design summary (see docs/V8_SPEC.md):                            |
//|  * Income comes from harvesting: one BUY slot + one SELL slot,   |
//|    each closed at a NET target (commission included).            |
//|  * Re-entry uses a pullback limit order (timeout + reprice).     |
//|  * A runner may extend a harvest while continuation is clear,    |
//|    protected by a server-side profit lock that only tightens.    |
//|  * Early scratch: a small loss is cut only when the entry reason |
//|    is broken AND holding raises basket risk.                     |
//|  * Every realised loss (scratch, trap, hedge, forced close) goes |
//|    into the cycle ledger and stays there until repaid by harvest |
//|    credits or the frozen hard stop ends the cycle.               |
//|  * Hedge is a capped backup (count + loss budget + re-arm rule). |
//|  * Hard stop is frozen at cycle start and can only be tightened. |
//|  * All state persists in terminal GlobalVariables; realised      |
//|    numbers are rebuilt from broker deal history.                 |
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "8.00"
#property description "Gold Bidirectional Harvester v8.00"
#property description "Net harvesting + pullback re-entry + early scratch + capped backup hedge"
#property description "Every realised loss stays in the cycle ledger until repaid or the frozen hard stop fires."

#include <Trade\Trade.mqh>

#define GBH8_BUILD      "8.00"
#define MAX_MEMBERS     16
#define MAX_UNACC       8
#define MAX_EXTRA       8
#define CC_CACHE        64
#define ROLE_BASE       1
#define ROLE_HEDGE      2
#define REASON_NONE     0
#define REASON_TARGET   1
#define REASON_HARDSTOP 2
#define REASON_REPAID   3

enum ENUM_GBH8_ENTRY
{
   ENTRY_LIMIT_PULLBACK = 0,   // Pullback limit order (recommended)
   ENTRY_MARKET         = 1    // Market order (instant)
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "=== 1. HARVEST (main income) ==="
input double InpBaseLots             = 0.01;   // Base lot (fixed)
input double InpHarvestNetTarget     = 0.50;   // Harvest target, NET after commission (account ccy)
input double InpCommissionPerLotSide = 2.00;   // Commission per lot PER SIDE (account ccy) - used for exit-cost estimate
input bool   InpRunnerEnable         = true;   // Let a harvest run while continuation is clear
input double InpRunnerLockRatio      = 0.80;   // Runner: minimum locked net = target x ratio
input double InpRunnerTrailNet       = 0.30;   // Runner: trailing give-back (account ccy)
input double InpRunnerMaxNet         = 0.00;   // Runner: close at this net (0 = no cap)

input group "=== 2. ENTRY QUALITY ==="
input ENUM_GBH8_ENTRY InpEntryMode   = ENTRY_LIMIT_PULLBACK; // Entry mode
input double InpLimitOffsetAtr       = 0.30;   // Limit distance from price, x ATR(M1)
input int    InpLimitMinOffsetPts    = 20;     // Minimum limit distance (points)
input int    InpLimitTimeoutSec      = 120;    // Cancel + re-place an unfilled limit after (sec)
input double InpLimitRepriceAtr      = 0.50;   // Re-place when price runs away by offset + x ATR(M1)
input int    InpMaxSpreadPts         = 35;     // Max spread for entries and hedges (points)
input bool   InpBlockCounterTrend    = true;   // No new counter-trend entries in a strong M15 trend
input double InpTrendGapAtr          = 1.00;   // Strong trend: |EMA50-EMA200| on M15 >= x ATR(M15)
input double InpShockAtrMult         = 3.00;   // Shock: M1 bar range >= x ATR(M1)
input int    InpShockPauseSec        = 300;    // Pause new entries after a shock (sec)
input bool   InpUseNewsFilter        = true;   // Block entries around high-impact USD news (live only)
input int    InpNewsMinutes          = 15;     // News window, minutes either side
input int    InpRolloverBeforeMin    = 20;     // No entries N minutes before server midnight
input int    InpRolloverAfterMin     = 70;     // No entries N minutes after server midnight

input group "=== 3. EARLY SCRATCH (conditional) ==="
input bool   InpScratchEnable        = true;   // Enable conditional early scratch
input int    InpScratchMinAgeSec     = 180;    // Minimum trade age before a scratch (sec)
input double InpScratchBreakAtr      = 1.00;   // Thesis broken: M5 close beyond entry by x ATR(M5)
input double InpScratchMinCostMult   = 2.00;   // Loss must be >= x * round-trip cost (no noise exits)
input double InpScratchMaxLoss       = 3.00;   // Above this loss it is hedge territory, not scratch

input group "=== 4. RECOVERY CYCLE LEDGER ==="
input double InpTrapTrigger          = 8.00;   // Base net loss that starts recovery (positive number)
input double InpCycleTarget          = 1.00;   // Close cycle when ledger net >= this (with open members)
input double InpAmortizePortion      = 0.50;   // Share of each harvest credited while recovering
input double InpDeficitRepayPortion  = 1.00;   // Share of each harvest credited to a deficit-only cycle
input double InpExitReserve          = 0.10;   // Slippage reserve subtracted while members are open

input group "=== 5. HEDGE (backup only) ==="
input double InpHedgeLots            = 0.02;   // Hedge lot
input double InpHedgeSLMoney         = 4.00;   // Hedge stop, money incl. commission
input double InpHedgeLockAt          = 1.50;   // Lock hedge to break-even at this net profit
input double InpHedgeTrailMoney      = 2.00;   // Hedge trailing distance (money)
input int    InpMaxHedgesPerCycle    = 3;      // Max hedges per cycle
input double InpHedgeLossBudget      = 8.00;   // Max realised hedge loss per cycle
input double InpHedgeRearmAtr        = 0.50;   // After a hedge closes, re-hedge only after x ATR(M15) continuation
input int    InpHedgeCooldownSec     = 300;    // ...and at least this many seconds

input group "=== 6. CAPITAL SHIELD ==="
input double InpCycleHardStop        = 25.00;  // Cycle hard stop (frozen at cycle start, tighten-only)
input int    InpCycleStopCooldownMin = 60;     // No new entries after a hard stop (min)
input double InpDailyLossLimit       = 50.00;  // Daily loss incl. floating: flatten + halt for the server day
input double InpBaseDisasterSLMoney  = 20.00;  // Broker-side disaster SL on base trades (0 = off)
input bool   InpWeekendFlatten       = true;   // Flatten everything before the weekend
input int    InpFridayNoEntryHour    = 21;     // Friday: no new entries from this server hour
input int    InpFridayFlattenHour    = 23;     // Friday: flatten from this server hour...
input int    InpFridayFlattenMinute  = 15;     // ...and minute
input double InpMinMarginLevel       = 300.0;  // Minimum projected margin level (%) for new risk

input group "=== 7. EXECUTION & IDENTIFICATION ==="
input ulong  InpSlippagePts          = 30;     // Max deviation (points)
input ulong  InpMagicBuy             = 80001;  // Magic - base BUY
input ulong  InpMagicSell            = 80002;  // Magic - base SELL
input ulong  InpMagicHedge           = 80003;  // Magic - hedge
input bool   InpWriteCsv             = true;   // Write per-cycle CSV to Common\Files

//+------------------------------------------------------------------+
//| TYPES                                                            |
//+------------------------------------------------------------------+
struct Pos
{
   bool     exists;
   ulong    ticket;
   ulong    id;
   ulong    magic;
   int      dir;          // +1 buy, -1 sell
   double   lots;
   double   open;
   double   sl;
   double   tp;
   datetime time;
   double   net;          // profit + swap + entry commission - estimated exit commission
   double   daily_raw;    // profit + swap - estimated exit commission (entry commission is in today's deals)
};

struct Book
{
   Pos      buy;                         // non-member base BUY slot
   Pos      sell;                        // non-member base SELL slot
   Pos      hedge;                       // first open hedge member
   int      n_open_members;
   ulong    member_ticket[MAX_MEMBERS];
   int      member_idx[MAX_MEMBERS];
   int      n_open_base_members;         // base members not marked for closing
   double   member_signed_lots;
   bool     member_buy_open;
   bool     member_sell_open;
   double   members_floating;
   double   ea_floating_daily;
   ulong    buy_order;
   double   buy_order_price;
   datetime buy_order_time;
   ulong    sell_order;
   double   sell_order_price;
   datetime sell_order_time;
   int      n_extra_orders;
   ulong    extra_order[MAX_EXTRA];
   int      n_extra_pos;
   ulong    extra_pos_id[MAX_EXTRA];
};

struct Market
{
   bool     quotes_ok;
   bool     ind_ok;
   double   bid;
   double   ask;
   double   spread_pts;
   double   atr1;
   double   atr5;
   double   atr15;
   double   ema9_1;
   double   ema9_2;
   double   ema21_1;
   double   ema50_1;
   double   ema50_3;
   double   ema200_1;
   double   m5_close1;
   double   m1_range0;
   double   m1_range1;
   int      regime;       // +1 strong up, -1 strong down, 0 range/normal
};

struct CycleState
{
   bool     active;
   bool     closing;
   int      close_reason;
   long     id;
   datetime start_time;
   double   frozen_stop;
   double   realized;          // realised net of closed members + losses booked from base closes
   double   credit;            // harvest credits
   double   hedge_realized;    // realised net of closed hedges (subset of realized)
   int      hedges_used;
   int      harvests;
   int      scratches;
   double   min_net;
   double   last_hedge_close_price;
   datetime last_hedge_close_time;
   int      n_members;
   ulong    member_id[MAX_MEMBERS];
   int      member_role[MAX_MEMBERS];
   bool     member_done[MAX_MEMBERS];
   bool     member_close_req[MAX_MEMBERS];
   datetime member_added[MAX_MEMBERS];
};

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                     |
//+------------------------------------------------------------------+
CTrade      trade;
Market      M;
CycleState  C;
string      g_prefix = "";

int h_atr1   = INVALID_HANDLE;
int h_atr5   = INVALID_HANDLE;
int h_atr15  = INVALID_HANDLE;
int h_ema9   = INVALID_HANDLE;
int h_ema21  = INVALID_HANDLE;
int h_ema50  = INVALID_HANDLE;
int h_ema200 = INVALID_HANDLE;

// persisted
ulong    g_known_buy_id    = 0;
ulong    g_known_sell_id   = 0;
ulong    g_unacc[MAX_UNACC];
int      g_n_unacc         = 0;
datetime g_halt_day        = 0;
datetime g_cooldown_until  = 0;
long     g_cycle_seq       = 0;
int      g_life_harvests   = 0;
double   g_life_harvest_net= 0.0;
int      g_life_cycles_ok  = 0;
int      g_life_cycles_stop= 0;
double   g_life_cycle_net  = 0.0;
int      g_life_scratches  = 0;

// in-memory only
datetime g_backoff_until   = 0;
datetime g_modify_next     = 0;
datetime g_shock_until     = 0;
datetime g_next_place[2];
ulong    g_runner_id[2];
double   g_runner_floor[2];
ulong    g_cc_id[CC_CACHE];
double   g_cc_val[CC_CACHE];
int      g_cc_n            = 0;
double   g_closed_today    = 0.0;
datetime g_closed_calc     = 0;
bool     g_hist_dirty      = true;
bool     g_in_drive        = false;
string   g_status          = "";
string   g_entry_status    = "";
string   g_side_status[2];
string   g_hedge_status    = "";
double   g_cycle_net_view  = 0.0;
double   g_day_net_view    = 0.0;

//+------------------------------------------------------------------+
//| SMALL HELPERS                                                    |
//+------------------------------------------------------------------+
datetime ServerNow()
{
   datetime t = TimeTradeServer();
   if(t <= 0) t = TimeCurrent();
   return t;
}

datetime ServerDayStart()
{
   datetime n = ServerNow();
   return n - (n % 86400);
}

bool IsOurMagic(const ulong mg)
{
   return (mg == InpMagicBuy || mg == InpMagicSell || mg == InpMagicHedge);
}

double NP(const double price)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double p  = price;
   if(ts > 0.0) p = MathRound(p / ts) * ts;
   return NormalizeDouble(p, _Digits);
}

double NL(const double v)
{
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;
   double r = MathFloor(v / step + 1e-9) * step;
   if(r < vmin) r = vmin;
   if(vmax > 0.0 && r > vmax) r = vmax;
   return NormalizeDouble(r, 2);
}

double StopsMinDist()
{
   double lv = MathMax((double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
                       (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   return lv * _Point + 2.0 * _Point;
}

// Account-currency value of a 1.0 price move for `lots`.
double ValuePerPrice(const double lots)
{
   double p = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double prof = 0.0;
   if(p > 0.0 && OrderCalcProfit(ORDER_TYPE_BUY, _Symbol, lots, p, p + 1.0, prof) && prof > 0.0)
      return prof;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv > 0.0 && ts > 0.0) return lots * tv / ts;
   return 0.0;
}

double RoundTripCost(const double lots)
{
   double spread_cost = (M.ask - M.bid) * ValuePerPrice(lots);
   return 2.0 * InpCommissionPerLotSide * lots + MathMax(0.0, spread_cost);
}

bool TradeOK(const bool sent, const string ctx)
{
   uint rc = trade.ResultRetcode();
   if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
      return true;
   PrintFormat("[GBH8] %s failed: retcode=%u (%s)", ctx, rc, trade.ResultRetcodeDescription());
   g_backoff_until = TimeCurrent() + 3;
   return false;
}

//+------------------------------------------------------------------+
//| PERSISTENCE (terminal GlobalVariables)                           |
//+------------------------------------------------------------------+
string GVName(const string key)               { return g_prefix + key; }
void   GVPut(const string key, const double v) { GlobalVariableSet(GVName(key), v); }

double GVRead(const string key, const double def)
{
   string n = GVName(key);
   if(GlobalVariableCheck(n)) return GlobalVariableGet(n);
   return def;
}

// ulong split into two exact doubles
void GVPutU(const string key, const ulong v)
{
   ulong base = 4294967296;
   GVPut(key + "h", (double)(v / base));
   GVPut(key + "l", (double)(v % base));
}

ulong GVReadU(const string key)
{
   ulong base = 4294967296;
   ulong h = (ulong)GVRead(key + "h", 0.0);
   ulong l = (ulong)GVRead(key + "l", 0.0);
   return h * base + l;
}

void SaveState()
{
   GVPut("ver",   8);
   GVPut("c_act", C.active ? 1 : 0);
   GVPut("c_cls", C.closing ? 1 : 0);
   GVPut("c_rsn", C.close_reason);
   GVPut("c_id",  (double)C.id);
   GVPut("c_st",  (double)C.start_time);
   GVPut("c_fs",  C.frozen_stop);
   GVPut("c_rz",  C.realized);
   GVPut("c_cr",  C.credit);
   GVPut("c_hr",  C.hedge_realized);
   GVPut("c_hu",  C.hedges_used);
   GVPut("c_hv",  C.harvests);
   GVPut("c_sc",  C.scratches);
   GVPut("c_mn",  C.min_net);
   GVPut("c_hp",  C.last_hedge_close_price);
   GVPut("c_ht",  (double)C.last_hedge_close_time);
   GVPut("c_nm",  C.n_members);
   for(int i = 0; i < MAX_MEMBERS; i++)
   {
      string s = IntegerToString(i);
      bool used = (i < C.n_members);
      GVPutU("m" + s, used ? C.member_id[i] : 0);
      GVPut("r" + s, used ? C.member_role[i] : 0);
      GVPut("d" + s, (used && C.member_done[i]) ? 1 : 0);
      GVPut("q" + s, (used && C.member_close_req[i]) ? 1 : 0);
      GVPut("a" + s, used ? (double)C.member_added[i] : 0.0);
   }
   GVPutU("kb", g_known_buy_id);
   GVPutU("ks", g_known_sell_id);
   GVPut("nu", g_n_unacc);
   for(int k = 0; k < MAX_UNACC; k++)
      GVPutU("u" + IntegerToString(k), k < g_n_unacc ? g_unacc[k] : 0);
   GVPut("halt", (double)g_halt_day);
   GVPut("cool", (double)g_cooldown_until);
   GVPut("seq",  (double)g_cycle_seq);
   GVPut("l_hv", g_life_harvests);
   GVPut("l_hn", g_life_harvest_net);
   GVPut("l_ok", g_life_cycles_ok);
   GVPut("l_st", g_life_cycles_stop);
   GVPut("l_cn", g_life_cycle_net);
   GVPut("l_sc", g_life_scratches);
   GlobalVariablesFlush();
}

void LoadState()
{
   ZeroMemory(C);
   if(GVRead("ver", 0.0) < 8.0)
   {
      Print("[GBH8] No saved state found - starting fresh.");
      return;
   }
   C.active                 = (GVRead("c_act", 0) > 0.5);
   C.closing                = (GVRead("c_cls", 0) > 0.5);
   C.close_reason           = (int)GVRead("c_rsn", 0);
   C.id                     = (long)GVRead("c_id", 0);
   C.start_time             = (datetime)(long)GVRead("c_st", 0);
   C.frozen_stop            = GVRead("c_fs", 0);
   C.realized               = GVRead("c_rz", 0);
   C.credit                 = GVRead("c_cr", 0);
   C.hedge_realized         = GVRead("c_hr", 0);
   C.hedges_used            = (int)GVRead("c_hu", 0);
   C.harvests               = (int)GVRead("c_hv", 0);
   C.scratches              = (int)GVRead("c_sc", 0);
   C.min_net                = GVRead("c_mn", 0);
   C.last_hedge_close_price = GVRead("c_hp", 0);
   C.last_hedge_close_time  = (datetime)(long)GVRead("c_ht", 0);
   C.n_members              = (int)MathMin((double)MAX_MEMBERS, GVRead("c_nm", 0.0));
   for(int i = 0; i < C.n_members; i++)
   {
      string s = IntegerToString(i);
      C.member_id[i]        = GVReadU("m" + s);
      C.member_role[i]      = (int)GVRead("r" + s, ROLE_BASE);
      C.member_done[i]      = (GVRead("d" + s, 0) > 0.5);
      C.member_close_req[i] = (GVRead("q" + s, 0) > 0.5);
      C.member_added[i]     = (datetime)(long)GVRead("a" + s, 0);
   }
   g_known_buy_id  = GVReadU("kb");
   g_known_sell_id = GVReadU("ks");
   g_n_unacc       = (int)MathMin((double)MAX_UNACC, GVRead("nu", 0.0));
   for(int k = 0; k < g_n_unacc; k++)
      g_unacc[k] = GVReadU("u" + IntegerToString(k));
   g_halt_day         = (datetime)(long)GVRead("halt", 0);
   g_cooldown_until   = (datetime)(long)GVRead("cool", 0);
   g_cycle_seq        = (long)GVRead("seq", 0);
   g_life_harvests    = (int)GVRead("l_hv", 0);
   g_life_harvest_net = GVRead("l_hn", 0);
   g_life_cycles_ok   = (int)GVRead("l_ok", 0);
   g_life_cycles_stop = (int)GVRead("l_st", 0);
   g_life_cycle_net   = GVRead("l_cn", 0);
   g_life_scratches   = (int)GVRead("l_sc", 0);

   if(C.active)
   {
      // The hard stop can only be tightened, never widened, during a running cycle.
      double fs = (C.frozen_stop > 0.0) ? C.frozen_stop : InpCycleHardStop;
      C.frozen_stop = MathMin(fs, InpCycleHardStop);
      PrintFormat("[GBH8] Restored cycle #%I64d: realised %.2f, credit %.2f, members %d, hard stop -%.2f",
                  C.id, C.realized, C.credit, C.n_members, C.frozen_stop);
   }
}

//+------------------------------------------------------------------+
//| HISTORY HELPERS                                                  |
//+------------------------------------------------------------------+
// Entry-side commission + fee for a position (negative number). Cached.
double EntryCommission(const ulong id, const double lots)
{
   for(int i = 0; i < g_cc_n; i++)
      if(g_cc_id[i] == id) return g_cc_val[i];

   double c = 0.0;
   bool found = false;
   if(HistorySelectByPosition(id))
   {
      int n = HistoryDealsTotal();
      for(int k = 0; k < n; k++)
      {
         ulong d = HistoryDealGetTicket(k);
         if(d == 0) continue;
         if(HistoryDealGetInteger(d, DEAL_ENTRY) == DEAL_ENTRY_IN)
         {
            c += HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
            found = true;
         }
      }
   }
   if(!found) return -InpCommissionPerLotSide * lots;   // estimate until the deal is visible
   if(g_cc_n >= CC_CACHE) g_cc_n = 0;                    // simple wrap-around cache
   g_cc_id[g_cc_n]  = id;
   g_cc_val[g_cc_n] = c;
   g_cc_n++;
   return c;
}

// 1 = closed and summed, 0 = not closed / history not ready, -1 = no deals at all.
int ClosedPositionNet(const ulong id, double &net, double &last_price)
{
   net = 0.0;
   last_price = 0.0;
   if(!HistorySelectByPosition(id)) return 0;
   int n = HistoryDealsTotal();
   if(n <= 0) return -1;
   bool has_out = false;
   for(int i = 0; i < n; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      net += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
           + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
      long e = HistoryDealGetInteger(d, DEAL_ENTRY);
      if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY || e == DEAL_ENTRY_INOUT)
      {
         has_out = true;
         last_price = HistoryDealGetDouble(d, DEAL_PRICE);
      }
   }
   return has_out ? 1 : 0;
}

void RefreshClosedToday()
{
   datetime now = ServerNow();
   if(!g_hist_dirty && now - g_closed_calc < 10) return;
   datetime ds = ServerDayStart();
   if(!HistorySelect(ds, now + 60)) return;
   g_hist_dirty  = false;
   g_closed_calc = now;
   double s = 0.0;
   int n = HistoryDealsTotal();
   for(int i = 0; i < n; i++)
   {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      if(HistoryDealGetString(d, DEAL_SYMBOL) != _Symbol) continue;
      if(!IsOurMagic((ulong)HistoryDealGetInteger(d, DEAL_MAGIC))) continue;
      s += HistoryDealGetDouble(d, DEAL_PROFIT) + HistoryDealGetDouble(d, DEAL_SWAP)
         + HistoryDealGetDouble(d, DEAL_COMMISSION) + HistoryDealGetDouble(d, DEAL_FEE);
   }
   g_closed_today = s;
}

//+------------------------------------------------------------------+
//| CYCLE LEDGER                                                     |
//+------------------------------------------------------------------+
int MemberIndex(const ulong id)
{
   for(int i = 0; i < C.n_members; i++)
      if(C.member_id[i] == id) return i;
   return -1;
}

void CompactMembers()
{
   int k = 0;
   for(int i = 0; i < C.n_members; i++)
   {
      if(C.member_done[i]) continue;
      C.member_id[k]        = C.member_id[i];
      C.member_role[k]      = C.member_role[i];
      C.member_done[k]      = false;
      C.member_close_req[k] = C.member_close_req[i];
      C.member_added[k]     = C.member_added[i];
      k++;
   }
   C.n_members = k;
}

int AddMember(const ulong id, const int role, const bool close_req)
{
   int idx = MemberIndex(id);
   if(idx >= 0)
   {
      if(close_req) C.member_close_req[idx] = true;
      return idx;
   }
   // Compaction happens only at the start of Drive() so book indices stay valid during a pass.
   if(C.n_members >= MAX_MEMBERS)
   {
      Print("[GBH8] WARNING: cycle member list full");
      return -1;
   }
   idx = C.n_members++;
   C.member_id[idx]        = id;
   C.member_role[idx]      = role;
   C.member_done[idx]      = false;
   C.member_close_req[idx] = close_req;
   C.member_added[idx]     = TimeCurrent();
   return idx;
}

bool AllMembersDone()
{
   for(int i = 0; i < C.n_members; i++)
      if(!C.member_done[i]) return false;
   return true;
}

void StartCycle(const string why)
{
   ZeroMemory(C);
   C.active      = true;
   C.id          = ++g_cycle_seq;
   C.start_time  = TimeCurrent();
   C.frozen_stop = InpCycleHardStop;
   PrintFormat("[GBH8] Cycle #%I64d STARTED (%s). Hard stop frozen at -%.2f", C.id, why, C.frozen_stop);
}

// Move a base position into the cycle ledger (trap / scratch / forced close).
void MakeMember(const Pos &p, const string why, const bool close_req)
{
   if(!C.active) StartCycle(why);
   AddMember(p.id, ROLE_BASE, close_req);
   if(g_known_buy_id  == p.id) g_known_buy_id  = 0;
   if(g_known_sell_id == p.id) g_known_sell_id = 0;
   PrintFormat("[GBH8] %s: position %I64u (%s, net %.2f) added to cycle #%I64d ledger",
               why, p.id, p.dir > 0 ? "BUY" : "SELL", p.net, C.id);
   SaveState();
}

double CycleNet(const Book &b)
{
   double reserve = (b.n_open_members > 0) ? InpExitReserve : 0.0;
   return C.realized + C.credit + b.members_floating - reserve;
}

string ReasonText(const int r)
{
   if(r == REASON_TARGET)   return "TARGET";
   if(r == REASON_HARDSTOP) return "HARD_STOP";
   if(r == REASON_REPAID)   return "DEFICIT_REPAID";
   return "NONE";
}

void WriteCycleCsv(const string reason, const double final_net)
{
   if(!InpWriteCsv) return;
   string fn = "GBH8_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol + "_cycles.csv";
   int h = FileOpen(fn, FILE_READ | FILE_WRITE | FILE_CSV | FILE_SHARE_READ | FILE_COMMON | FILE_ANSI, ',');
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
      FileWrite(h, "cycle_id", "start", "end", "reason", "realized", "credit", "final_net", "min_net",
                "hedges", "hedge_realized", "harvests", "scratches", "frozen_stop");
   FileSeek(h, 0, SEEK_END);
   FileWrite(h, IntegerToString(C.id), TimeToString(C.start_time, TIME_DATE | TIME_SECONDS),
             TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS), reason,
             DoubleToString(C.realized, 2), DoubleToString(C.credit, 2), DoubleToString(final_net, 2),
             DoubleToString(C.min_net, 2), IntegerToString(C.hedges_used), DoubleToString(C.hedge_realized, 2),
             IntegerToString(C.harvests), IntegerToString(C.scratches), DoubleToString(C.frozen_stop, 2));
   FileClose(h);
}

void FinalizeCycle()
{
   double final_net = C.realized + C.credit;
   string reason = ReasonText(C.close_reason);
   if(C.close_reason == REASON_HARDSTOP) g_life_cycles_stop++;
   else                                  g_life_cycles_ok++;
   g_life_cycle_net += final_net;
   PrintFormat("[GBH8] Cycle #%I64d FINISHED [%s] realised %.2f + credit %.2f = NET %.2f | hedges %d (%.2f) | harvests %d | scratches %d | worst %.2f",
               C.id, reason, C.realized, C.credit, final_net, C.hedges_used, C.hedge_realized,
               C.harvests, C.scratches, C.min_net);
   WriteCycleCsv(reason, final_net);
   ZeroMemory(C);
   SaveState();
}

//+------------------------------------------------------------------+
//| MARKET SNAPSHOT                                                  |
//+------------------------------------------------------------------+
bool RefreshMarket()
{
   M.quotes_ok = false;
   M.ind_ok    = false;
   MqlTick tk;
   if(!SymbolInfoTick(_Symbol, tk) || tk.bid <= 0.0 || tk.ask <= 0.0) return false;
   M.bid        = tk.bid;
   M.ask        = tk.ask;
   M.spread_pts = (tk.ask - tk.bid) / _Point;
   M.quotes_ok  = true;

   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(h_atr1, 0, 0, 2, a) < 2)   return true; M.atr1 = a[1];
   if(CopyBuffer(h_atr5, 0, 0, 2, a) < 2)   return true; M.atr5 = a[1];
   if(CopyBuffer(h_atr15, 0, 0, 2, a) < 2)  return true; M.atr15 = a[1];
   if(CopyBuffer(h_ema9, 0, 0, 3, a) < 3)   return true; M.ema9_1 = a[1]; M.ema9_2 = a[2];
   if(CopyBuffer(h_ema21, 0, 0, 2, a) < 2)  return true; M.ema21_1 = a[1];
   if(CopyBuffer(h_ema50, 0, 0, 4, a) < 4)  return true; M.ema50_1 = a[1]; M.ema50_3 = a[3];
   if(CopyBuffer(h_ema200, 0, 0, 2, a) < 2) return true; M.ema200_1 = a[1];

   M.m5_close1 = iClose(_Symbol, PERIOD_M5, 1);
   double h0 = iHigh(_Symbol, PERIOD_M1, 0), l0 = iLow(_Symbol, PERIOD_M1, 0);
   double h1 = iHigh(_Symbol, PERIOD_M1, 1), l1 = iLow(_Symbol, PERIOD_M1, 1);
   if(M.m5_close1 <= 0.0 || h0 <= 0.0 || h1 <= 0.0) return true;
   M.m1_range0 = h0 - l0;
   M.m1_range1 = h1 - l1;

   M.regime = 0;
   double gap = M.ema50_1 - M.ema200_1;
   if(M.atr15 > 0.0)
   {
      if(gap >= InpTrendGapAtr * M.atr15 && M.ema50_1 > M.ema50_3)        M.regime = 1;
      else if(-gap >= InpTrendGapAtr * M.atr15 && M.ema50_1 < M.ema50_3)  M.regime = -1;
   }
   M.ind_ok = (M.atr1 > 0.0 && M.atr5 > 0.0 && M.atr15 > 0.0);
   return true;
}

bool Continuation(const int dir)
{
   if(!M.ind_ok) return false;
   if(dir > 0) return (M.ema9_1 > M.ema21_1 && M.ema9_1 > M.ema9_2 && M.bid > M.ema9_1);
   return (M.ema9_1 < M.ema21_1 && M.ema9_1 < M.ema9_2 && M.ask < M.ema9_1);
}

bool MomentumAgainst(const int dir)
{
   if(!M.ind_ok) return false;
   return (dir > 0) ? (M.ema9_1 < M.ema21_1) : (M.ema9_1 > M.ema21_1);
}

void UpdateShock(const datetime now)
{
   if(!M.ind_ok || M.atr1 <= 0.0) return;
   double lim = InpShockAtrMult * M.atr1;
   if(M.m1_range0 >= lim || M.m1_range1 >= lim)
   {
      if(now >= g_shock_until)
         PrintFormat("[GBH8] Shock detected (M1 range %.2f >= %.2f). Entries paused %d s.",
                     MathMax(M.m1_range0, M.m1_range1), lim, InpShockPauseSec);
      g_shock_until = now + InpShockPauseSec;
   }
}

//+------------------------------------------------------------------+
//| BOOK SCAN                                                        |
//+------------------------------------------------------------------+
void FillPos(Pos &p, const ulong ticket)
{
   ZeroMemory(p);
   if(!PositionSelectByTicket(ticket)) return;
   p.exists = true;
   p.ticket = ticket;
   p.id     = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
   p.magic  = (ulong)PositionGetInteger(POSITION_MAGIC);
   p.dir    = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
   p.lots   = PositionGetDouble(POSITION_VOLUME);
   p.open   = PositionGetDouble(POSITION_PRICE_OPEN);
   p.sl     = PositionGetDouble(POSITION_SL);
   p.tp     = PositionGetDouble(POSITION_TP);
   p.time   = (datetime)PositionGetInteger(POSITION_TIME);
   double raw      = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   double exit_est = InpCommissionPerLotSide * p.lots;
   p.daily_raw = raw - exit_est;
   p.net       = raw + EntryCommission(p.id, p.lots) - exit_est;
}

void ScanBook(Book &b)
{
   ZeroMemory(b);
   bool changed = false;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)PositionGetInteger(POSITION_MAGIC);
      if(!IsOurMagic(mg)) continue;

      Pos p;
      FillPos(p, t);
      if(!p.exists) continue;
      b.ea_floating_daily += p.daily_raw;

      int mi = MemberIndex(p.id);
      if(mi < 0 && mg == InpMagicHedge)
      {
         // A hedge always belongs to a cycle. Adopt it so its result can never be hidden.
         if(!C.active) StartCycle("adopted hedge");
         mi = AddMember(p.id, ROLE_HEDGE, false);
         changed = true;
      }

      if(mi < 0)
      {
         bool is_buy = (mg == InpMagicBuy);
         if(is_buy && !b.buy.exists)        b.buy = p;
         else if(!is_buy && !b.sell.exists) b.sell = p;
         else if(b.n_extra_pos < MAX_EXTRA) b.extra_pos_id[b.n_extra_pos++] = p.id;
         continue;
      }

      if(b.n_open_members < MAX_MEMBERS)
      {
         b.member_ticket[b.n_open_members] = t;
         b.member_idx[b.n_open_members]    = mi;
         b.n_open_members++;
      }
      b.members_floating += p.net;

      if(C.member_role[mi] == ROLE_HEDGE)
      {
         if(!b.hedge.exists) b.hedge = p;
      }
      else if(!C.member_close_req[mi])
      {
         b.n_open_base_members++;
         b.member_signed_lots += p.dir * p.lots;
         if(p.dir > 0) b.member_buy_open = true;
         else          b.member_sell_open = true;
      }
   }
   if(changed) SaveState();

   for(int j = OrdersTotal() - 1; j >= 0; j--)
   {
      ulong ot = OrderGetTicket(j);
      if(ot == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      ulong mg = (ulong)OrderGetInteger(ORDER_MAGIC);
      if(!IsOurMagic(mg)) continue;
      ENUM_ORDER_TYPE typ = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(mg == InpMagicBuy && typ == ORDER_TYPE_BUY_LIMIT && b.buy_order == 0)
      {
         b.buy_order       = ot;
         b.buy_order_price = OrderGetDouble(ORDER_PRICE_OPEN);
         b.buy_order_time  = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      }
      else if(mg == InpMagicSell && typ == ORDER_TYPE_SELL_LIMIT && b.sell_order == 0)
      {
         b.sell_order       = ot;
         b.sell_order_price = OrderGetDouble(ORDER_PRICE_OPEN);
         b.sell_order_time  = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      }
      else if(b.n_extra_orders < MAX_EXTRA)
         b.extra_order[b.n_extra_orders++] = ot;
   }
}

//+------------------------------------------------------------------+
//| ACCOUNTING OF CLOSED POSITIONS                                   |
//+------------------------------------------------------------------+
bool MemberIsOpen(const Book &b, const int mi)
{
   for(int k = 0; k < b.n_open_members; k++)
      if(b.member_idx[k] == mi) return true;
   return false;
}

void AddUnacc(const ulong id)
{
   for(int i = 0; i < g_n_unacc; i++)
      if(g_unacc[i] == id) return;
   if(g_n_unacc < MAX_UNACC) g_unacc[g_n_unacc++] = id;
   else Print("[GBH8] WARNING: unaccounted list full");
}

void RemoveUnacc(const int k)
{
   for(int i = k; i < g_n_unacc - 1; i++) g_unacc[i] = g_unacc[i + 1];
   if(g_n_unacc > 0) g_n_unacc--;
}

bool TrackKnown(ulong &known, const Pos &slot)
{
   bool changed = false;
   if(known != 0 && (!slot.exists || slot.id != known))
   {
      if(MemberIndex(known) < 0) AddUnacc(known);
      known = 0;
      changed = true;
   }
   if(slot.exists && known == 0)
   {
      known = slot.id;
      changed = true;
   }
   return changed;
}

// A non-member base position closed (EA harvest, broker SL, manual close...).
void AccountClosedBase(const ulong id, const double net, const Book &b)
{
   if(net >= 0.0)
   {
      g_life_harvests++;
      g_life_harvest_net += net;
      if(C.active && !C.closing)
      {
         bool recovering = (b.n_open_base_members > 0 || b.hedge.exists);
         double portion  = recovering ? InpAmortizePortion : InpDeficitRepayPortion;
         double chunk    = net * portion;
         C.credit += chunk;
         C.harvests++;
         PrintFormat("[GBH8] Harvest %I64u +%.2f net | %.0f%% credited to cycle #%I64d (+%.2f, credit now %.2f)",
                     id, net, portion * 100.0, C.id, chunk, C.credit);
      }
      else
         PrintFormat("[GBH8] Harvest %I64u +%.2f net", id, net);
   }
   else
   {
      // Never hide a realised loss: it always lands in a cycle ledger.
      if(!C.active) StartCycle("realised base loss");
      C.realized += net;
      PrintFormat("[GBH8] Base position %I64u closed at %.2f outside harvest rules -> booked into cycle #%I64d",
                  id, net, C.id);
   }
}

void ProcessAccounting(const Book &b)
{
   bool changed = false;

   if(C.active)
   {
      for(int i = 0; i < C.n_members; i++)
      {
         if(C.member_done[i]) continue;
         if(MemberIsOpen(b, i)) continue;
         double net = 0.0, px = 0.0;
         int r = ClosedPositionNet(C.member_id[i], net, px);
         if(r == 1)
         {
            C.realized += net;
            C.member_done[i] = true;
            changed = true;
            if(C.member_role[i] == ROLE_HEDGE)
            {
               C.hedge_realized         += net;
               C.last_hedge_close_price  = px;
               C.last_hedge_close_time   = TimeCurrent();
            }
            PrintFormat("[GBH8] Cycle #%I64d member %I64u (%s) closed: %.2f | ledger realised %.2f",
                        C.id, C.member_id[i], C.member_role[i] == ROLE_HEDGE ? "HEDGE" : "BASE", net, C.realized);
         }
         else if(r == -1 && TimeCurrent() - C.member_added[i] > 120)
         {
            C.member_done[i] = true;
            changed = true;
            PrintFormat("[GBH8] WARNING: member %I64u has no history; marked done with 0.00", C.member_id[i]);
         }
      }
   }

   if(TrackKnown(g_known_buy_id, b.buy))   changed = true;
   if(TrackKnown(g_known_sell_id, b.sell)) changed = true;

   for(int k = g_n_unacc - 1; k >= 0; k--)
   {
      ulong id = g_unacc[k];
      if(PositionSelectByTicket(id)) { RemoveUnacc(k); changed = true; continue; }
      double net = 0.0, px = 0.0;
      int r = ClosedPositionNet(id, net, px);
      if(r == 1)       { AccountClosedBase(id, net, b); RemoveUnacc(k); changed = true; }
      else if(r == -1) { RemoveUnacc(k); changed = true; }
   }

   if(changed) SaveState();
}

//+------------------------------------------------------------------+
//| TRADE ACTIONS                                                    |
//+------------------------------------------------------------------+
bool ClosePos(const ulong ticket, const string why)
{
   if(!PositionSelectByTicket(ticket)) return false;
   trade.SetExpertMagicNumber((ulong)PositionGetInteger(POSITION_MAGIC));
   double net_hint = PositionGetDouble(POSITION_PROFIT);
   if(TradeOK(trade.PositionClose(ticket, InpSlippagePts), "close " + why))
      PrintFormat("[GBH8] Closed %I64u [%s] (gross %.2f)", ticket, why, net_hint);
   g_hist_dirty = true;
   return true;
}

bool DeleteOrder(const ulong ticket, const string why)
{
   if(TradeOK(trade.OrderDelete(ticket), "delete order " + why))
      PrintFormat("[GBH8] Pending %I64u removed [%s]", ticket, why);
   return true;
}

bool DeleteAllPendings(const Book &b)
{
   bool acted = false;
   if(b.buy_order  != 0) { DeleteOrder(b.buy_order,  "flatten"); acted = true; }
   if(b.sell_order != 0) { DeleteOrder(b.sell_order, "flatten"); acted = true; }
   for(int k = 0; k < b.n_extra_orders; k++) { DeleteOrder(b.extra_order[k], "flatten"); acted = true; }
   return acted;
}

bool ModifySLIfBetter(const Pos &p, const double want_raw)
{
   if(TimeCurrent() < g_modify_next) return false;
   double want = NP(want_raw);
   double md   = StopsMinDist();
   if(p.dir > 0)
   {
      if(want > M.bid - md) return false;
      if(p.sl > 0.0 && want <= p.sl + 2.0 * _Point) return false;
   }
   else
   {
      if(want < M.ask + md) return false;
      if(p.sl > 0.0 && want >= p.sl - 2.0 * _Point) return false;
   }
   trade.SetExpertMagicNumber(p.magic);
   bool sent = trade.PositionModify(p.ticket, want, p.tp);
   uint rc = trade.ResultRetcode();
   if(!sent || (rc != TRADE_RETCODE_DONE && rc != TRADE_RETCODE_NO_CHANGES))
   {
      PrintFormat("[GBH8] SL modify %I64u failed: retcode=%u (%s)", p.ticket, rc, trade.ResultRetcodeDescription());
      g_modify_next = TimeCurrent() + 5;
      return false;
   }
   g_modify_next = TimeCurrent() + 1;
   return true;
}

bool MarginOK(const int dir, const double lots)
{
   double price = (dir > 0) ? M.ask : M.bid;
   double m = 0.0;
   if(!OrderCalcMargin(dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, m)) return false;
   double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(m >= free) return false;
   double eq   = AccountInfoDouble(ACCOUNT_EQUITY);
   double used = AccountInfoDouble(ACCOUNT_MARGIN);
   if(used + m <= 0.0) return true;
   return (eq / (used + m) * 100.0 >= InpMinMarginLevel);
}

double DisasterSL(const int dir, const double entry, const double lots)
{
   if(InpBaseDisasterSLMoney <= 0.0) return 0.0;
   double vpp = ValuePerPrice(lots);
   if(vpp <= 0.0) return 0.0;
   double dist = (InpBaseDisasterSLMoney - 2.0 * InpCommissionPerLotSide * lots) / vpp;
   if(dist <= StopsMinDist()) return 0.0;
   return NP(dir > 0 ? entry - dist : entry + dist);
}

// Close everything (daily limit / weekend). Losing base trades enter the ledger first.
bool FlattenAll(Book &b, const string why)
{
   bool acted = false;
   Pos slots[2];
   slots[0] = b.buy;
   slots[1] = b.sell;
   for(int s = 0; s < 2; s++)
   {
      if(!slots[s].exists) continue;
      if(slots[s].net < 0.0) MakeMember(slots[s], why, true);
      ClosePos(slots[s].ticket, why);
      acted = true;
   }
   for(int k = 0; k < b.n_open_members; k++)
   {
      C.member_close_req[b.member_idx[k]] = true;
      ClosePos(b.member_ticket[k], why);
      acted = true;
   }
   if(acted) SaveState();
   if(DeleteAllPendings(b)) acted = true;
   return acted;
}

bool ProcessCloseRequests(const Book &b)
{
   bool acted = false;
   for(int k = 0; k < b.n_open_members; k++)
   {
      if(!C.member_close_req[b.member_idx[k]]) continue;
      ClosePos(b.member_ticket[k], "ledger close request");
      acted = true;
   }
   return acted;
}

bool AdoptExtras(const Book &b)
{
   if(b.n_extra_pos <= 0) return false;
   if(!C.active) StartCycle("unexpected extra position");
   for(int k = 0; k < b.n_extra_pos; k++)
   {
      AddMember(b.extra_pos_id[k], ROLE_BASE, true);
      PrintFormat("[GBH8] Extra base position %I64u adopted into cycle #%I64d and will be closed", b.extra_pos_id[k], C.id);
   }
   SaveState();
   return true;
}

//+------------------------------------------------------------------+
//| CAPITAL SHIELD                                                   |
//+------------------------------------------------------------------+
bool IsHaltedToday()
{
   return (g_halt_day != 0 && g_halt_day == ServerDayStart());
}

bool CheckDailyLimit(const Book &b)
{
   RefreshClosedToday();
   g_day_net_view = g_closed_today + b.ea_floating_daily;
   if(IsHaltedToday()) return true;
   if(g_day_net_view <= -InpDailyLossLimit)
   {
      g_halt_day = ServerDayStart();
      SaveState();
      PrintFormat("[GBH8] DAILY LOSS LIMIT hit (%.2f incl. floating). Flattening and halting until next server day.",
                  g_day_net_view);
      return true;
   }
   return false;
}

bool WeekendNoEntry()
{
   MqlDateTime t;
   TimeToStruct(ServerNow(), t);
   if(t.day_of_week == 0 || t.day_of_week == 6) return true;
   return (t.day_of_week == 5 && t.hour >= InpFridayNoEntryHour);
}

bool WeekendFlattenDue()
{
   if(!InpWeekendFlatten) return false;
   MqlDateTime t;
   TimeToStruct(ServerNow(), t);
   return (t.day_of_week == 5 && t.hour * 60 + t.min >= InpFridayFlattenHour * 60 + InpFridayFlattenMinute);
}

bool RolloverWindow()
{
   MqlDateTime t;
   TimeToStruct(ServerNow(), t);
   int m = t.hour * 60 + t.min;
   return (m >= 1440 - InpRolloverBeforeMin || m < InpRolloverAfterMin);
}

bool NewsBlocked()
{
   if(!InpUseNewsFilter || MQLInfoInteger(MQL_TESTER)) return false;
   static datetime last_check = 0;
   static bool     last_value = false;
   datetime now = ServerNow();
   if(now - last_check < 30) return last_value;
   last_check = now;
   last_value = false;
   MqlCalendarValue v[];
   int n = CalendarValueHistory(v, now - InpNewsMinutes * 60, now + InpNewsMinutes * 60, NULL, "USD");
   if(n < 0) return false;   // calendar unavailable: fail open (logged by dashboard status only)
   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(CalendarEventById(v[i].event_id, ev) && ev.importance == CALENDAR_IMPORTANCE_HIGH)
      {
         last_value = true;
         break;
      }
   }
   return last_value;
}

//+------------------------------------------------------------------+
//| CYCLE EVALUATION                                                 |
//+------------------------------------------------------------------+
// Returns true when it acted or the cycle is closing (caller stops this pass).
bool EvaluateCycle(Book &b, const datetime now)
{
   double net = CycleNet(b);
   g_cycle_net_view = net;
   if(net < C.min_net) C.min_net = net;

   if(!C.closing)
   {
      bool members_open = (b.n_open_members > 0);
      if(net <= -C.frozen_stop)
      {
         C.closing      = true;
         C.close_reason = REASON_HARDSTOP;
         g_cooldown_until = now + InpCycleStopCooldownMin * 60;
         SaveState();
         PrintFormat("[GBH8] Cycle #%I64d HARD STOP: ledger net %.2f <= -%.2f. Closing all members, cooldown %d min.",
                     C.id, net, C.frozen_stop, InpCycleStopCooldownMin);
      }
      else if(members_open && net >= InpCycleTarget)
      {
         C.closing      = true;
         C.close_reason = REASON_TARGET;
         SaveState();
         PrintFormat("[GBH8] Cycle #%I64d TARGET: realised %.2f + credit %.2f + floating %.2f = %.2f >= %.2f",
                     C.id, C.realized, C.credit, b.members_floating, net, InpCycleTarget);
      }
      else if(!members_open && AllMembersDone() && net >= 0.0)
      {
         C.close_reason = REASON_REPAID;
         FinalizeCycle();
         return false;
      }
   }

   if(C.closing)
   {
      if(b.n_open_members > 0)
      {
         for(int k = 0; k < b.n_open_members; k++)
            ClosePos(b.member_ticket[k], "cycle " + ReasonText(C.close_reason));
         return true;
      }
      if(!AllMembersDone()) return true;   // waiting for history
      FinalizeCycle();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| HEDGE (backup only)                                              |
//+------------------------------------------------------------------+
void TrailHedge(const Pos &h)
{
   if(h.net < InpHedgeLockAt) return;
   double vpp = ValuePerPrice(h.lots);
   if(vpp <= 0.0) return;
   double cost  = 2.0 * InpCommissionPerLotSide * h.lots / vpp;
   double be    = (h.dir > 0) ? h.open + cost : h.open - cost;
   double trail = InpHedgeTrailMoney / vpp;
   double want  = (h.dir > 0) ? MathMax(be, M.bid - trail) : MathMin(be, M.ask + trail);
   ModifySLIfBetter(h, want);   // only ever tightens
}

bool ManageHedge(Book &b, const datetime now)
{
   g_hedge_status = "";
   if(b.hedge.exists)
   {
      TrailHedge(b.hedge);
      g_hedge_status = "hedge open";
      return false;
   }
   if(!C.active || C.closing) return false;
   if(b.n_open_base_members == 0 || MathAbs(b.member_signed_lots) < 1e-8) return false;

   int hdir = (b.member_signed_lots > 0.0) ? -1 : 1;

   if(C.hedges_used >= InpMaxHedgesPerCycle) { g_hedge_status = "hedge count cap reached"; return false; }
   double budget_left = InpHedgeLossBudget + C.hedge_realized;
   double sl_money    = MathMin(InpHedgeSLMoney, budget_left);
   if(sl_money < 0.50) { g_hedge_status = "hedge loss budget exhausted"; return false; }

   if(C.hedges_used > 0)
   {
      if(now - C.last_hedge_close_time < InpHedgeCooldownSec) { g_hedge_status = "hedge cooldown"; return false; }
      if(C.last_hedge_close_price > 0.0)
      {
         double d = InpHedgeRearmAtr * M.atr15;
         if(hdir < 0 && M.bid > C.last_hedge_close_price - d) { g_hedge_status = "waiting re-arm (continuation)"; return false; }
         if(hdir > 0 && M.ask < C.last_hedge_close_price + d) { g_hedge_status = "waiting re-arm (continuation)"; return false; }
      }
   }
   if(M.spread_pts > InpMaxSpreadPts) { g_hedge_status = "spread too wide for hedge"; return false; }
   if(now < g_shock_until)            { g_hedge_status = "shock pause"; return false; }

   double lots = NL(InpHedgeLots);
   if(!MarginOK(hdir, lots)) { g_hedge_status = "margin check failed"; return false; }
   double vpp = ValuePerPrice(lots);
   if(vpp <= 0.0) return false;
   double dist = (sl_money - 2.0 * InpCommissionPerLotSide * lots) / vpp;
   if(dist < StopsMinDist() + (M.ask - M.bid)) { g_hedge_status = "hedge stop too tight for broker"; return false; }

   trade.SetExpertMagicNumber(InpMagicHedge);
   string cmt = "GBH8 H" + IntegerToString(C.id);
   bool   sent = false;
   double sl   = 0.0;
   if(hdir < 0) { sl = NP(M.bid + dist); sent = trade.Sell(lots, _Symbol, M.bid, sl, 0.0, cmt); }
   else         { sl = NP(M.ask - dist); sent = trade.Buy(lots, _Symbol, M.ask, sl, 0.0, cmt); }

   if(TradeOK(sent, "hedge open"))
   {
      ulong id = trade.ResultOrder();
      if(id > 0) AddMember(id, ROLE_HEDGE, false);
      C.hedges_used++;
      SaveState();
      PrintFormat("[GBH8] Cycle #%I64d HEDGE %d/%d %s %.2f lot, SL %.2f (risk %.2f, budget left %.2f)",
                  C.id, C.hedges_used, InpMaxHedgesPerCycle, hdir > 0 ? "BUY" : "SELL", lots, sl, sl_money, budget_left);
   }
   return true;
}

//+------------------------------------------------------------------+
//| BASE MANAGEMENT: trap -> harvest/runner -> conditional scratch   |
//+------------------------------------------------------------------+
bool ScratchDue(const Pos &p, const Book &b, const datetime now)
{
   if(now - p.time < InpScratchMinAgeSec) return false;
   double loss = -p.net;
   if(loss <= 0.0) return false;
   // C: a real loss, but still below hedge territory
   if(loss < InpScratchMinCostMult * RoundTripCost(p.lots)) return false;
   if(loss > InpScratchMaxLoss) return false;
   // A: entry reason broken (structure AND momentum)
   bool struct_break = (p.dir > 0) ? (M.m5_close1 < p.open - InpScratchBreakAtr * M.atr5)
                                   : (M.m5_close1 > p.open + InpScratchBreakAtr * M.atr5);
   bool thesis_broken = struct_break && MomentumAgainst(p.dir);
   if(!thesis_broken) return false;
   // B: holding raises basket risk
   bool regime_against = (p.dir > 0 && M.regime < 0) || (p.dir < 0 && M.regime > 0);
   bool cycle_running  = (C.active && b.n_open_base_members > 0);
   return (regime_against || cycle_running);
}

bool ManageBase(Pos &p, Book &b, const datetime now)
{
   if(!p.exists) return false;
   int s = (p.magic == InpMagicBuy) ? 0 : 1;
   if(g_runner_id[s] != 0 && g_runner_id[s] != p.id) { g_runner_id[s] = 0; g_runner_floor[s] = 0.0; }

   // 1. Trap -> recovery cycle
   if(p.net <= -InpTrapTrigger)
   {
      MakeMember(p, "TRAP", false);
      return true;
   }

   // 2. Runner floor (client-side backup of the server-side lock)
   if(g_runner_id[s] == p.id && p.net <= g_runner_floor[s])
      return ClosePos(p.ticket, "RUNNER_FLOOR");

   // 3. Harvest or run
   if(p.net >= InpHarvestNetTarget)
   {
      bool cont = InpRunnerEnable && Continuation(p.dir) && (InpRunnerMaxNet <= 0.0 || p.net < InpRunnerMaxNet);
      if(!cont) return ClosePos(p.ticket, "HARVEST");

      double floor_net = MathMax(InpHarvestNetTarget * InpRunnerLockRatio, p.net - InpRunnerTrailNet);
      if(g_runner_id[s] != p.id || floor_net > g_runner_floor[s])
      {
         if(g_runner_id[s] != p.id)
            PrintFormat("[GBH8] Runner ON for %I64u at net %.2f (floor %.2f)", p.id, p.net, floor_net);
         g_runner_id[s]    = p.id;
         g_runner_floor[s] = floor_net;
      }
      double vpp = ValuePerPrice(p.lots);
      if(vpp > 0.0)
      {
         double dist = (p.net - g_runner_floor[s]) / vpp;
         ModifySLIfBetter(p, (p.dir > 0) ? M.bid - dist : M.ask + dist);
      }
      return false;
   }

   bool runner_sl = (p.dir > 0) ? (p.sl > p.open) : (p.sl > 0.0 && p.sl < p.open);
   if((runner_sl || g_runner_id[s] == p.id) && p.net > 0.0 && !Continuation(p.dir))
      return ClosePos(p.ticket, "RUNNER_BANK");

   // 4. Conditional early scratch
   if(InpScratchEnable && M.ind_ok && ScratchDue(p, b, now))
   {
      MakeMember(p, "SCRATCH", true);
      C.scratches++;
      g_life_scratches++;
      SaveState();
      ClosePos(p.ticket, "SCRATCH");
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| ENTRIES                                                          |
//+------------------------------------------------------------------+
bool EntriesAllowed(const datetime now, string &why)
{
   if(!M.quotes_ok || !M.ind_ok) { why = "market data not ready"; return false; }
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) != SYMBOL_TRADE_MODE_FULL)
   { why = "symbol not fully tradable"; return false; }
   if(IsHaltedToday())          { why = "daily loss limit - halted"; return false; }
   if(C.active && C.closing)    { why = "cycle closing"; return false; }
   if(now < g_cooldown_until)   { why = "cooldown after hard stop"; return false; }
   if(WeekendNoEntry())         { why = "Friday close / weekend window"; return false; }
   if(RolloverWindow())         { why = "rollover window"; return false; }
   if(M.spread_pts > InpMaxSpreadPts)
   { why = "spread " + DoubleToString(M.spread_pts, 0) + " > " + IntegerToString(InpMaxSpreadPts); return false; }
   if(now < g_shock_until)      { why = "shock pause"; return false; }
   if(NewsBlocked())            { why = "high-impact USD news"; return false; }
   why = "ready";
   return true;
}

bool SideAllowed(const int side, const Book &b, string &why)
{
   if(side > 0 && b.member_buy_open)  { why = "BUY trapped in cycle"; return false; }
   if(side < 0 && b.member_sell_open) { why = "SELL trapped in cycle"; return false; }
   if(InpBlockCounterTrend && side > 0 && M.regime < 0) { why = "strong M15 downtrend"; return false; }
   if(InpBlockCounterTrend && side < 0 && M.regime > 0) { why = "strong M15 uptrend"; return false; }
   if(!MarginOK(side, NL(InpBaseLots))) { why = "margin check"; return false; }
   why = "ok";
   return true;
}

double LimitOffset()
{
   double off = MathMax(InpLimitMinOffsetPts * _Point, InpLimitOffsetAtr * M.atr1);
   return MathMax(off, StopsMinDist());
}

void PlaceEntry(const int side, const int s)
{
   double lots = NL(InpBaseLots);
   trade.SetExpertMagicNumber(side > 0 ? InpMagicBuy : InpMagicSell);
   bool sent = false;
   if(InpEntryMode == ENTRY_MARKET)
   {
      double px = (side > 0) ? M.ask : M.bid;
      double sl = DisasterSL(side, px, lots);
      sent = (side > 0) ? trade.Buy(lots, _Symbol, px, sl, 0.0, "GBH8 BUY")
                        : trade.Sell(lots, _Symbol, px, sl, 0.0, "GBH8 SELL");
      if(TradeOK(sent, "market entry"))
         PrintFormat("[GBH8] Base %s market @ %.2f", side > 0 ? "BUY" : "SELL", px);
   }
   else
   {
      double off   = LimitOffset();
      double price = (side > 0) ? NP(M.ask - off) : NP(M.bid + off);
      double sl    = DisasterSL(side, price, lots);
      trade.SetTypeFilling(ORDER_FILLING_RETURN);
      sent = (side > 0) ? trade.BuyLimit(lots, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "GBH8 BUY L")
                        : trade.SellLimit(lots, price, _Symbol, sl, 0.0, ORDER_TIME_GTC, 0, "GBH8 SELL L");
      trade.SetTypeFillingBySymbol(_Symbol);
      if(TradeOK(sent, "limit entry"))
         PrintFormat("[GBH8] Base %s LIMIT @ %.2f (offset %.2f)", side > 0 ? "BUY" : "SELL", price, off);
   }
   g_next_place[s] = TimeCurrent() + 2;
}

void ManageEntries(Book &b, const datetime now)
{
   for(int k = 0; k < b.n_extra_orders; k++) DeleteOrder(b.extra_order[k], "stray");

   string why = "";
   bool allow = EntriesAllowed(now, why);
   g_entry_status = why;

   for(int s = 0; s < 2; s++)
   {
      int side = (s == 0) ? 1 : -1;
      bool     has_pos   = (s == 0) ? b.buy.exists      : b.sell.exists;
      ulong    ord       = (s == 0) ? b.buy_order       : b.sell_order;
      double   ord_price = (s == 0) ? b.buy_order_price : b.sell_order_price;
      datetime ord_time  = (s == 0) ? b.buy_order_time  : b.sell_order_time;

      string swhy = why;
      bool ok = allow && !has_pos;
      if(ok) ok = SideAllowed(side, b, swhy);
      if(has_pos) swhy = "position open";
      g_side_status[s] = swhy;

      if(!ok)
      {
         if(ord != 0) DeleteOrder(ord, "entry blocked: " + swhy);
         continue;
      }

      if(InpEntryMode == ENTRY_MARKET)
      {
         if(ord != 0) { DeleteOrder(ord, "market mode"); continue; }
         if(now >= g_next_place[s]) PlaceEntry(side, s);
         continue;
      }

      if(ord != 0)
      {
         double off    = LimitOffset();
         bool   stale  = (now - ord_time) >= InpLimitTimeoutSec;
         double drift  = (side > 0) ? (M.ask - ord_price) : (ord_price - M.bid);
         bool   runaway = drift > off + InpLimitRepriceAtr * M.atr1;
         if(stale || runaway)
         {
            DeleteOrder(ord, stale ? "timeout" : "reprice");
            g_next_place[s] = now + 2;
         }
         g_side_status[s] = "limit @ " + DoubleToString(ord_price, _Digits);
         continue;
      }
      if(now < g_next_place[s]) continue;
      PlaceEntry(side, s);
   }
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
string SlotLine(const string name, const Pos &p, const int s)
{
   if(p.exists)
   {
      string r = "open @ " + DoubleToString(p.open, _Digits) + " | net " + DoubleToString(p.net, 2);
      if(g_runner_id[s] == p.id) r += " | RUNNER floor " + DoubleToString(g_runner_floor[s], 2);
      return name + r;
   }
   return name + g_side_status[s];
}

void RenderDashboard(const Book &b)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   string reg = (M.regime > 0) ? "STRONG UP" : ((M.regime < 0) ? "STRONG DOWN" : "RANGE/NORMAL");
   string s = "================ GOLD HARVESTER v" + GBH8_BUILD + " ================\n";
   s += "Status   : " + g_status + "\n";
   s += "Balance  : " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + ccy
      + "   Equity: " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + "\n";
   s += "Spread   : " + DoubleToString(M.spread_pts, 0) + " pts (max " + IntegerToString(InpMaxSpreadPts) + ")"
      + "   Regime M15: " + reg + "   ATR M1: " + DoubleToString(M.atr1, 2) + "\n";
   s += "Day net  : " + DoubleToString(g_day_net_view, 2) + " (limit -" + DoubleToString(InpDailyLossLimit, 2) + ")"
      + (IsHaltedToday() ? "  << HALTED >>" : "") + "\n";
   s += "Entries  : " + g_entry_status + "\n";
   s += "-----------------------------------------------------\n";
   s += SlotLine("BUY  : ", b.buy, 0) + "\n";
   s += SlotLine("SELL : ", b.sell, 1) + "\n";
   s += "-----------------------------------------------------\n";
   if(C.active)
   {
      s += "CYCLE #" + IntegerToString(C.id) + (C.closing ? " [CLOSING " + ReasonText(C.close_reason) + "]" : "") + "\n";
      s += "  realised " + DoubleToString(C.realized, 2) + " | credit +" + DoubleToString(C.credit, 2)
         + " | floating " + DoubleToString(b.members_floating, 2) + "\n";
      s += "  LEDGER NET " + DoubleToString(g_cycle_net_view, 2) + "  (target +" + DoubleToString(InpCycleTarget, 2)
         + " / hard stop -" + DoubleToString(C.frozen_stop, 2) + ")\n";
      s += "  hedges " + IntegerToString(C.hedges_used) + "/" + IntegerToString(InpMaxHedgesPerCycle)
         + " realised " + DoubleToString(C.hedge_realized, 2)
         + " | budget left " + DoubleToString(InpHedgeLossBudget + C.hedge_realized, 2)
         + (g_hedge_status != "" ? " | " + g_hedge_status : "") + "\n";
      s += "  harvests credited " + IntegerToString(C.harvests) + " | scratches " + IntegerToString(C.scratches) + "\n";
   }
   else
      s += "CYCLE    : none - normal harvesting\n";
   s += "-----------------------------------------------------\n";
   s += "Lifetime : harvests " + IntegerToString(g_life_harvests) + " (+" + DoubleToString(g_life_harvest_net, 2) + ")"
      + " | cycles ok " + IntegerToString(g_life_cycles_ok) + " / stopped " + IntegerToString(g_life_cycles_stop)
      + " (net " + DoubleToString(g_life_cycle_net, 2) + ") | scratches " + IntegerToString(g_life_scratches) + "\n";
   Comment(s);
}

//+------------------------------------------------------------------+
//| MAIN LOOP                                                        |
//+------------------------------------------------------------------+
void Logic(Book &b, const bool market_ok)
{
   datetime now = TimeCurrent();
   if(!market_ok) { g_status = "waiting for quotes"; return; }
   UpdateShock(now);

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
   { g_status = "Algo Trading disabled"; return; }

   bool halted = CheckDailyLimit(b);
   datetime last_quote = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(ServerNow() - last_quote > 120) { g_status = "market closed / no fresh quotes"; return; }
   if(now < g_backoff_until) { g_status = "backoff after a failed request"; return; }

   if(C.active && EvaluateCycle(b, now)) { g_status = "cycle closing"; return; }
   if(AdoptExtras(b)) return;
   if(ProcessCloseRequests(b)) return;

   if(halted)
   {
      g_status = "DAILY LIMIT - flat until next server day";
      FlattenAll(b, "DAILY_LIMIT");
      return;
   }
   if(WeekendFlattenDue())
   {
      g_status = "weekend flatten";
      FlattenAll(b, "WEEKEND");
      return;
   }

   if(ManageHedge(b, now)) return;
   if(ManageBase(b.buy, b, now)) return;
   if(ManageBase(b.sell, b, now)) return;

   ManageEntries(b, now);
   g_status = C.active ? "harvesting + cycle recovery" : "harvesting";
}

void Drive()
{
   if(g_in_drive) return;
   g_in_drive = true;
   if(C.active && C.n_members >= MAX_MEMBERS - 2)
   {
      CompactMembers();
      SaveState();
   }
   Book b;
   bool mk = RefreshMarket();
   ScanBook(b);
   ProcessAccounting(b);
   Logic(b, mk);
   RenderDashboard(b);
   g_in_drive = false;
}

//+------------------------------------------------------------------+
//| INIT VALIDATION                                                  |
//+------------------------------------------------------------------+
bool ValidateInputs()
{
   string e = "";
   if(InpBaseLots <= 0.0 || InpHedgeLots <= 0.0)               e += "lots must be > 0; ";
   if(InpHarvestNetTarget <= 0.0)                              e += "harvest target must be > 0; ";
   if(InpCommissionPerLotSide < 0.0)                           e += "commission must be >= 0; ";
   if(InpRunnerLockRatio <= 0.0 || InpRunnerLockRatio > 1.0)   e += "runner lock ratio must be in (0,1]; ";
   if(InpRunnerTrailNet <= 0.0)                                e += "runner trail must be > 0; ";
   if(InpTrapTrigger <= 0.0)                                   e += "trap trigger must be > 0 (positive number); ";
   if(InpScratchMaxLoss >= InpTrapTrigger)                     e += "scratch max loss must be below trap trigger; ";
   if(InpCycleHardStop <= InpTrapTrigger + InpHedgeLossBudget) e += "hard stop must exceed trap trigger + hedge loss budget; ";
   if(InpBaseDisasterSLMoney > 0.0 && InpBaseDisasterSLMoney <= InpTrapTrigger)
                                                               e += "base disaster SL must be beyond trap trigger; ";
   if(InpAmortizePortion < 0.0 || InpAmortizePortion > 1.0)    e += "amortize portion must be 0..1; ";
   if(InpDeficitRepayPortion < 0.0 || InpDeficitRepayPortion > 1.0) e += "deficit repay portion must be 0..1; ";
   if(InpCycleTarget < 0.0)                                    e += "cycle target must be >= 0; ";
   if(InpDailyLossLimit <= 0.0)                                e += "daily loss limit must be > 0; ";
   if(InpHedgeSLMoney <= 0.0 || InpHedgeLockAt <= 0.0 || InpHedgeTrailMoney <= 0.0) e += "hedge money inputs must be > 0; ";
   if(InpMaxHedgesPerCycle < 0)                                e += "max hedges must be >= 0; ";
   if(InpFridayNoEntryHour > InpFridayFlattenHour)             e += "Friday no-entry hour must be <= flatten hour; ";
   if(InpMagicBuy == InpMagicSell || InpMagicBuy == InpMagicHedge || InpMagicSell == InpMagicHedge)
                                                               e += "magic numbers must differ; ";
   if(e != "")
   {
      Print("[GBH8] INIT FAILED - invalid inputs: ", e);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| EVENT HANDLERS                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(!ValidateInputs()) return INIT_PARAMETERS_INCORRECT;

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("[GBH8] INIT FAILED - a hedging account is required.");
      return INIT_FAILED;
   }
   if(MathAbs(NL(InpBaseLots) - InpBaseLots) > 1e-9 || MathAbs(NL(InpHedgeLots) - InpHedgeLots) > 1e-9)
      Print("[GBH8] WARNING: lot sizes adjusted to broker volume step/min.");

   h_atr1   = iATR(_Symbol, PERIOD_M1, 14);
   h_atr5   = iATR(_Symbol, PERIOD_M5, 14);
   h_atr15  = iATR(_Symbol, PERIOD_M15, 14);
   h_ema9   = iMA(_Symbol, PERIOD_M1, 9, 0, MODE_EMA, PRICE_CLOSE);
   h_ema21  = iMA(_Symbol, PERIOD_M1, 21, 0, MODE_EMA, PRICE_CLOSE);
   h_ema50  = iMA(_Symbol, PERIOD_M15, 50, 0, MODE_EMA, PRICE_CLOSE);
   h_ema200 = iMA(_Symbol, PERIOD_M15, 200, 0, MODE_EMA, PRICE_CLOSE);
   if(h_atr1 == INVALID_HANDLE || h_atr5 == INVALID_HANDLE || h_atr15 == INVALID_HANDLE ||
      h_ema9 == INVALID_HANDLE || h_ema21 == INVALID_HANDLE || h_ema50 == INVALID_HANDLE || h_ema200 == INVALID_HANDLE)
   {
      Print("[GBH8] INIT FAILED - indicator handles, error ", GetLastError());
      return INIT_FAILED;
   }

   g_prefix = "GBH8_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + "_" + _Symbol + "_"
            + IntegerToString((long)InpMagicBuy) + "_";
   if(MQLInfoInteger(MQL_TESTER)) GlobalVariablesDeleteAll(g_prefix);   // isolate tester runs
   LoadState();

   g_next_place[0] = 0;  g_next_place[1] = 0;
   g_runner_id[0]  = 0;  g_runner_id[1]  = 0;
   g_runner_floor[0] = 0.0; g_runner_floor[1] = 0.0;
   g_side_status[0] = ""; g_side_status[1] = "";

   trade.SetDeviationInPoints(InpSlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);
   EventSetTimer(1);

   Print("==================================================================");
   PrintFormat("[GBH8] Gold Bidirectional Harvester v%s on %s (%s account)", GBH8_BUILD, _Symbol,
               AccountInfoString(ACCOUNT_CURRENCY));
   PrintFormat("[GBH8] Harvest net %.2f | runner %s | entry %s | trap -%.2f | cycle target +%.2f | hard stop -%.2f",
               InpHarvestNetTarget, InpRunnerEnable ? "ON" : "OFF",
               InpEntryMode == ENTRY_LIMIT_PULLBACK ? "pullback limit" : "market",
               InpTrapTrigger, InpCycleTarget, InpCycleHardStop);
   PrintFormat("[GBH8] Hedge %.2f lot, SL %.2f, max %d, loss budget %.2f | daily limit -%.2f",
               InpHedgeLots, InpHedgeSLMoney, InpMaxHedgesPerCycle, InpHedgeLossBudget, InpDailyLossLimit);
   Print("==================================================================");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   EventKillTimer();
   SaveState();
   if(h_atr1   != INVALID_HANDLE) IndicatorRelease(h_atr1);
   if(h_atr5   != INVALID_HANDLE) IndicatorRelease(h_atr5);
   if(h_atr15  != INVALID_HANDLE) IndicatorRelease(h_atr15);
   if(h_ema9   != INVALID_HANDLE) IndicatorRelease(h_ema9);
   if(h_ema21  != INVALID_HANDLE) IndicatorRelease(h_ema21);
   if(h_ema50  != INVALID_HANDLE) IndicatorRelease(h_ema50);
   if(h_ema200 != INVALID_HANDLE) IndicatorRelease(h_ema200);
   Comment("");
}

void OnTick()  { Drive(); }
void OnTimer() { Drive(); }

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   g_hist_dirty = true;
}
//+------------------------------------------------------------------+
