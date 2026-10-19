//+------------------------------------------------------------------+
//|                                 Gold_DualGrid_Scalper_v15.00.mq5 |
//|  v15 Dual-Direction Grid-Scalp with Smart Hedging Recovery       |
//|  build 1.0 - design: docs/V15_PLAN.md rev 1                      |
//+------------------------------------------------------------------+
//  One cycle at a time:
//  Pair    : a BUY and a SELL of InpBaseLots open together at market.
//            The pair is neutral: it gains nothing and loses nothing
//            while gold moves (only costs).
//  Step    : when one leg reaches InpHarvestTarget net, and the trend
//            check agrees with trade 3 (InpTrendCheck), trade 3 opens
//            (InpBaseLots):
//            mode 1, harvest: the winning leg closes (its money is banked)
//                    and trade 3 opens on the pullback side (the same way
//                    as the losing leg). The cycle leans 2 x InpBaseLots
//                    the pullback way.
//            mode 2, keep   : both legs stay open and trade 3 opens with
//                    the move (2 SELL + 1 BUY after a fall). The cycle
//                    leans 1 x InpBaseLots with the move.
//            (Trade 3 with the move in mode 1 would make a BUY + SELL
//            pair again: the cycle could never reach its target.)
//  Trend   : EMA InpEmaFast above (below) EMA InpEmaSlow on InpTrendTF,
//            last closed bar -> trade 3 may only be a BUY (SELL).
//  Target  : the cycle (banked money + open trades) at InpBasketTarget
//            net -> all trades close (BT).
//  Hedge   : gold InpHedgeDistance against trade 3 -> the emergency hedge
//            opens the other way: InpHedgeMult x the cycle's net lots.
//            After it, all trades close at InpEmergencyTarget cycle net
//            (ET).
//  Hard stop: the open trades together at -InpHardStop -> close all (HS).
//  P1 margin: a new pair only if free margin covers the whole cycle, with
//            the hedge, x 1.5 (broker's hedge rule). A trade of the cycle
//            that fails 3 times closes the cycle (HF).
//  P2 spread: no new pair and no step while the spread is above
//            InpMaxSpread. The hedge and the exits always work.
//  P3 news  : InpNewsFilter on -> no new pair and no step from
//            InpNewsStart to InpNewsEnd (server time, Mon-Fri), and from
//            InpRateStart to InpRateEnd on the US rate decision days in
//            InpRateDays. Open cycles keep their hedge and exits.
//  After a cycle ends, the next pair opens at once (zero gap).
//
//  Order of checks on every tick:
//    1. update the trades   2. closing all trades: keep closing
//    3. new trend bar: read the trend
//    4. hard stop, then the basket target (before the hedge) or the
//       emergency target (after it)
//    5. the pair's second leg / trade 3 if they still have to open
//    6. the step   7. the emergency hedge
//    8. no cycle: open a new pair (P1, P2, P3)
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "15.00"
#property description "v15 Dual Grid Scalper: a neutral BUY + SELL pair. When a leg reaches the harvest target, trade 3 opens (mode 1: the winner is banked and"
#property description "trade 3 goes on the pullback side; mode 2: both stay and trade 3 goes with the move). Basket target, v14 emergency hedge + target, hard stop."
#property description "Margin check (P1), spread limit (P2) and news windows (P3). No other features."

#define V15_BUILD          "1.0"
#define V15_MAX_POS        8
#define V15_MAX_RATE_DAYS  40
#define V15_EPS            0.000000001
#define V15_DEVIATION      20
#define V15_OPEN_RETRY_MS  5000
#define V15_ADD_RETRY_MS   1000
#define V15_ADD_MAX_FAILS  3
#define V15_CLOSE_RETRY_MS 1000
#define V15_MISSING_MS     60000
#define V15_MARGIN_SAFETY  1.5
#define V15_ROLE_EXTRA     0
#define V15_ROLE_BUY       1
#define V15_ROLE_SELL      2
#define V15_ROLE_T3        3
#define V15_ROLE_HEDGE     4

enum V15_MODE
  {
   V15_MODE_HARVEST = 1,   // 1: bank the winning leg, trade 3 on the pullback side
   V15_MODE_KEEP    = 2    // 2: keep both legs, trade 3 with the move (2 SELL + 1 BUY)
  };

//--- inputs: this is the complete list (docs/V15_PLAN.md, section 5)
input double          InpBaseLots        = 0.01;            // Lot of each pair leg and of trade 3
input V15_MODE        InpMode            = V15_MODE_HARVEST; // Step mode (1 = harvest the winner, 2 = keep all 3)
input double          InpHarvestTarget   = 1.00;            // Step: a pair leg reaches this net (after costs)
input double          InpBasketTarget    = 2.00;            // The cycle (banked + open trades) closes at this net
input int             InpMaxOpenTrades   = 3;               // Most normal trades open at once (2-3; mode 2 needs 3). The emergency hedge is +1
input double          InpHedgeDistance   = 8.00;            // Emergency hedge: gold this many $ against trade 3
input double          InpHedgeMult       = 2.0;             // Emergency hedge lot = the cycle's net lots x this
input double          InpEmergencyTarget = 1.00;            // After the hedge: the cycle closes at this net
input double          InpHardStop        = 30.00;           // Hard stop: loss of the open trades together
input bool            InpTrendCheck      = true;            // Trend check: trade 3 only the way of the EMA trend (false = at once)
input ENUM_TIMEFRAMES InpTrendTF         = PERIOD_M5;       // Trend timeframe (closed bars)
input int             InpEmaFast         = 9;               // Trend: fast EMA
input int             InpEmaSlow         = 21;              // Trend: slow EMA
input double          InpMaxSpread       = 1.00;            // No new pair and no step while the spread is above this many $ (0 = off)
input bool            InpNewsFilter      = true;            // News filter: no new pair and no step in the windows (open trades carry on)
input string          InpNewsStart       = "15:00";         // Daily news window start, server time HH:MM, Mon-Fri (15:30 = 8:30 New York: CPI, NFP)
input string          InpNewsEnd         = "15:45";         // Daily news window end (new pairs allowed again from this minute)
input string          InpRateDays        = "2026.06.17,2026.07.29,2026.09.16,2026.10.28,2026.12.09,2027.01.27,2027.03.17,2027.04.28,2027.06.09,2027.07.28,2027.09.15,2027.10.27,2027.12.08"; // US rate decision days YYYY.MM.DD, comma separated (empty = none)
input string          InpRateStart       = "20:30";         // Rate decision window start, server time (21:00 = 14:00 New York)
input string          InpRateEnd         = "22:00";         // Rate decision window end
input long            InpMagic           = 150001;          // Magic number

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
struct V15Pos
  {
   ulong  ticket;       // position ticket (to select and close it)
   ulong  id;           // position identifier (its deals in the history)
   int    role;         // V15_ROLE_BUY / _SELL (the pair), _T3, _HEDGE, or _EXTRA
   int    dir;          // +1 BUY, -1 SELL
   double lots;
   double openPrice;
   long   openMsc;      // opening time (restart: puts the trades in order)
   double entryMoney;   // money of the opening deal: commission + fee (negative)
   bool   entryKnown;   // entryMoney has been read from the history
   bool   isOpen;       // seen among the open positions on this tick
   double profit;       // floating profit (account currency)
   double swapNow;      // swap so far
   long   missingMsc;   // when it was first missing from the open positions (0 = seen)
  };

V15Pos   g_pos[V15_MAX_POS];
int      g_posCount     = 0;

//--- the cycle
bool     g_cycle        = false;
int      g_cNo          = 0;
datetime g_cStart       = 0;
double   g_cBank        = 0.0;     // closed trades of this cycle (the harvested leg)
int      g_cTrades      = 0;       // trades opened in this cycle
int      g_cMaxOpen     = 0;       // most trades open at once
bool     g_sellPending  = false;   // the pair's SELL leg still has to open
bool     g_stepDone     = false;   // the step has happened (trade 3 decided)
bool     g_t3Pending    = false;   // trade 3 still has to open
bool     g_t3Done       = false;   // trade 3 has opened
bool     g_hedged       = false;   // the emergency hedge has opened: the emergency target is the exit now
int      g_moveDir      = 0;       // the move at the step: the winning leg's direction
int      g_t3Dir        = 0;       // trade 3's direction
double   g_harvestNet   = 0.0;     // mode 1: the winning leg's net when it was banked (journal)
double   g_hedgeLots    = 0.0;
int      g_hedgeDir     = 0;
int      g_addFails     = 0;       // failed tries of the SELL leg / trade 3 / hedge
string   g_endTag       = "";      // how the cycle ends: BT, ET, HS, HF, RS
double   g_endFloat     = 0.0;     // the open trades together when all were closed (journal)

//--- closing all trades
bool     g_closing      = false;
string   g_closeTag     = "";

//--- a market trade whose position number was not known when it opened
int      g_expectRole   = 0;
int      g_expectDir    = 0;
long     g_expectMsc    = 0;

//--- trend
datetime g_lastBar      = 0;
int      g_trend        = 0;       // +1 fast EMA above slow, -1 below, 0 unknown / equal

//--- P1 and P3
bool     g_marginLow    = false;   // the last check found too little margin (journal once)
int      g_inNews       = 0;       // P3 now: 0 no window, 1 daily news window, 2 rate decision window
int      g_newsStart    = 0;       // minutes after midnight, server time
int      g_newsEnd      = 0;
int      g_rateStart    = 0;
int      g_rateEnd      = 0;
int      g_rateDays[V15_MAX_RATE_DAYS];
int      g_rateCount    = 0;

//--- summary (journal at the end)
int      g_sumCycles    = 0;
int      g_sumBT        = 0;
int      g_sumET        = 0;
int      g_sumHS        = 0;
int      g_sumHF        = 0;
int      g_sumOther     = 0;
int      g_sumSteps     = 0;
int      g_sumHedges    = 0;
double   g_sumNet       = 0.0;

//--- indicators
int      g_hFast        = INVALID_HANDLE;
int      g_hSlow        = INVALID_HANDLE;

MqlTick  g_tick;
long     g_nowMsc       = 0;
long     g_openNextTry  = 0;       // new pair: not before this time (after a failure or low margin)
long     g_addNextTry   = 0;       // SELL leg / trade 3 / hedge: not before this time
long     g_closeNextTry = 0;       // closes: not before this time
long     g_orderNextTry = 0;       // deleting stray pending orders: not before this time
ENUM_ORDER_TYPE_FILLING g_filling = ORDER_FILLING_FOK;
double   g_tickSize     = 0.01;
double   g_priceEps     = 0.005;
double   g_lotHedge     = 0.02;    // the normal emergency hedge lot for this mode (P1 and journal)
bool     g_isTester     = false;
bool     g_needAdopt    = true;
bool     g_adopting     = false;
string   g_ccy          = "";
string   g_gvBank       = "";      // terminal global variables: the banked money of the open cycle (restart)
string   g_gvLeg        = "";

//+------------------------------------------------------------------+
//| Text                                                             |
//+------------------------------------------------------------------+
void V15Log(const string text)
  {
   Print("v15 ", text);
  }

string Money(const double v)
  {
   return StringFormat("%+.2f %s", v, g_ccy);
  }

string Amount(const double v)
  {
   return StringFormat("%.2f %s", v, g_ccy);
  }

string DirName(const int dir)
  {
   return (dir > 0 ? "BUY" : "SELL");
  }

string PriceText(const double p)
  {
   return DoubleToString(p, _Digits);
  }

string LotsText(const double v)
  {
   return DoubleToString(v, 2);
  }

string TimeText(const datetime t)
  {
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
  }

string RoleName(const int role)
  {
   if(role == V15_ROLE_BUY)
      return "pair BUY";
   if(role == V15_ROLE_SELL)
      return "pair SELL";
   if(role == V15_ROLE_T3)
      return "trade 3";
   if(role == V15_ROLE_HEDGE)
      return "emergency hedge";
   return "extra trade";
  }

string RoleComment(const int role)
  {
   if(role == V15_ROLE_BUY)
      return "V15 B";
   if(role == V15_ROLE_SELL)
      return "V15 S";
   if(role == V15_ROLE_T3)
      return "V15 3";
   return "V15 EH";
  }

string ModeText()
  {
   return (InpMode == V15_MODE_HARVEST ? "mode 1 harvest" : "mode 2 keep");
  }

double NormalizeLots(const double v)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0)
      return NormalizeDouble(v, 2);
   return NormalizeDouble(MathRound(v / step) * step, 8);
  }

//+------------------------------------------------------------------+
//| Money                                                            |
//+------------------------------------------------------------------+
double DealMoney(const ulong deal)
  {
   return HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_COMMISSION) +
          HistoryDealGetDouble(deal, DEAL_SWAP) + HistoryDealGetDouble(deal, DEAL_FEE);
  }

//--- floating profit rounded down to the cent: the closing deal is never worth less than this
double FloorCent(const double v)
  {
   return MathFloor(v * 100.0 + 0.0000001) / 100.0;
  }

//+------------------------------------------------------------------+
//| The bot's trades                                                 |
//+------------------------------------------------------------------+
int FindPos(const ulong id)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].id == id)
         return i;
   return -1;
  }

//--- the open trade with this role (-1 = none)
int FindRole(const int role)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen && g_pos[i].role == role)
         return i;
   return -1;
  }

int OpenCount()
  {
   int n = 0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         n++;
   return n;
  }

//--- open pair legs and trade 3 (not the hedge, not extra trades)
int NormalOpen()
  {
   int n = 0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen && (g_pos[i].role == V15_ROLE_BUY || g_pos[i].role == V15_ROLE_SELL || g_pos[i].role == V15_ROLE_T3))
         n++;
   return n;
  }

//--- the open trades' lots: BUY lots minus SELL lots
double NetLots()
  {
   double v = 0.0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         v += g_pos[i].dir * g_pos[i].lots;
   return v;
  }

int AddPos(const ulong ticket, const ulong id, const int role, const int dir)
  {
   if(g_posCount >= V15_MAX_POS)
     {
      V15Log(StringFormat("too many v15 trades - #%I64u is not tracked", ticket));
      return -1;
     }
   int i = g_posCount;
   g_pos[i].ticket     = ticket;
   g_pos[i].id         = id;
   g_pos[i].role       = role;
   g_pos[i].dir        = dir;
   g_pos[i].lots       = 0.0;
   g_pos[i].openPrice  = 0.0;
   g_pos[i].openMsc    = 0;
   g_pos[i].entryMoney = 0.0;
   g_pos[i].entryKnown = false;
   g_pos[i].isOpen     = false;
   g_pos[i].profit     = 0.0;
   g_pos[i].swapNow    = 0.0;
   g_pos[i].missingMsc = 0;
   g_posCount++;
   return i;
  }

void RemovePos(const int i)
  {
   for(int k = i; k < g_posCount - 1; k++)
      g_pos[k] = g_pos[k + 1];
   g_posCount--;
  }

//--- money of the opening deal of trade i (its commission)
void ReadEntry(const int i)
  {
   if(!HistorySelectByPosition((long)g_pos[i].id))
      return;
   double money = 0.0;
   bool   found = false;
   int    n     = HistoryDealsTotal();
   for(int k = 0; k < n; k++)
     {
      ulong deal = HistoryDealGetTicket(k);
      if(deal == 0 || (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      money += DealMoney(deal);
      found  = true;
     }
   if(!found)
      return;
   g_pos[i].entryMoney = money;
   g_pos[i].entryKnown = true;
  }

//--- true when the position is fully closed in the history; 'net' = the money of all its deals
bool ClosedResult(const ulong id, double &net)
  {
   net = 0.0;
   if(!HistorySelectByPosition((long)id))
      return false;
   double volIn  = 0.0;
   double volOut = 0.0;
   int    n      = HistoryDealsTotal();
   for(int k = 0; k < n; k++)
     {
      ulong deal = HistoryDealGetTicket(k);
      if(deal == 0)
         continue;
      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      double          vol   = HistoryDealGetDouble(deal, DEAL_VOLUME);
      if(entry == DEAL_ENTRY_IN)
         volIn += vol;
      else if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
         volOut += vol;
      net += DealMoney(deal);
     }
   return (volIn > 0.0 && volOut >= volIn - 0.00000001);
  }

//+------------------------------------------------------------------+
//| Restart memory: the banked money of the open cycle (live only)   |
//+------------------------------------------------------------------+
//--- the pair leg that stays open after the harvest (mode 1), or 0
ulong LegId()
  {
   int i = FindRole(V15_ROLE_BUY);
   if(i < 0)
      i = FindRole(V15_ROLE_SELL);
   return (i >= 0 ? g_pos[i].id : 0);
  }

void SaveBank()
  {
   if(g_isTester)
      return;
   ulong leg = LegId();
   if(leg == 0)
      return;
   GlobalVariableSet(g_gvBank, g_cBank);
   GlobalVariableSet(g_gvLeg, (double)leg);
   GlobalVariablesFlush();
  }

void ClearBank()
  {
   if(g_isTester)
      return;
   if(GlobalVariableCheck(g_gvBank))
      GlobalVariableDel(g_gvBank);
   if(GlobalVariableCheck(g_gvLeg))
      GlobalVariableDel(g_gvLeg);
  }

//--- the banked money saved for this pair leg (false = not known)
bool LoadBank(const ulong leg, double &bank)
  {
   bank = 0.0;
   if(!GlobalVariableCheck(g_gvBank) || !GlobalVariableCheck(g_gvLeg))
      return false;
   if((ulong)MathRound(GlobalVariableGet(g_gvLeg)) != leg)
      return false;
   bank = GlobalVariableGet(g_gvBank);
   return true;
  }

//+------------------------------------------------------------------+
//| Cycle start                                                      |
//+------------------------------------------------------------------+
void StartCycle()
  {
   g_cycle       = true;
   g_cNo++;
   g_cStart      = TimeCurrent();
   g_cBank       = 0.0;
   g_cTrades     = 1;
   g_cMaxOpen    = 1;
   g_sellPending = false;
   g_stepDone    = false;
   g_t3Pending   = false;
   g_t3Done      = false;
   g_hedged      = false;
   g_moveDir     = 0;
   g_t3Dir       = 0;
   g_harvestNet  = 0.0;
   g_hedgeLots   = 0.0;
   g_hedgeDir    = 0;
   g_addFails    = 0;
   g_addNextTry  = 0;
   g_endTag      = "";
   g_endFloat    = 0.0;
  }

//--- role of a trade found in the terminal that the bot does not track yet
int RoleForNew(const ulong id, const int dir)
  {
   if(g_expectRole != 0 && dir == g_expectDir)
     {
      int role     = g_expectRole;        // a market trade whose number was not known when it opened
      g_expectRole = 0;
      g_expectDir  = 0;
      return role;
     }
   if(!g_adopting)
      V15Log(StringFormat("found an extra open trade #%I64u %s - it closes with the cycle", id, DirName(dir)));
   return V15_ROLE_EXTRA;                 // restart: Adopt() gives the roles
  }

//--- step 1: read the open trades
void Sync()
  {
   for(int i = 0; i < g_posCount; i++)
      g_pos[i].isOpen = false;
   int total = PositionsTotal();
   for(int k = 0; k < total; k++)
     {
      ulong ticket = PositionGetTicket(k);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      ulong id  = (ulong)PositionGetInteger(POSITION_IDENTIFIER);
      int   dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      int   i   = FindPos(id);
      if(i < 0)
        {
         int role = RoleForNew(id, dir);
         i = AddPos(ticket, id, role, dir);
         if(i < 0)
            continue;
        }
      g_pos[i].ticket     = ticket;
      g_pos[i].isOpen     = true;
      g_pos[i].dir        = dir;
      g_pos[i].lots       = PositionGetDouble(POSITION_VOLUME);
      g_pos[i].openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[i].openMsc    = PositionGetInteger(POSITION_TIME_MSC);
      g_pos[i].profit     = PositionGetDouble(POSITION_PROFIT);
      g_pos[i].swapNow    = PositionGetDouble(POSITION_SWAP);
      g_pos[i].missingMsc = 0;
     }
   int open = OpenCount();
   if(g_cycle && open > g_cMaxOpen)
      g_cMaxOpen = open;
   bool banked = false;
   for(int i = g_posCount - 1; i >= 0; i--)
     {
      if(g_pos[i].isOpen)
        {
         if(!g_pos[i].entryKnown)
            ReadEntry(i);
         continue;
        }
      double net = 0.0;
      if(ClosedResult(g_pos[i].id, net))
        {
         if(g_cycle)
           {
            g_cBank += net;
            banked   = true;
           }
         RemovePos(i);
         continue;
        }
      //--- not open and not closed in the history yet: wait for the terminal to catch up
      if(g_pos[i].missingMsc == 0)
         g_pos[i].missingMsc = g_nowMsc;
      else if(g_nowMsc - g_pos[i].missingMsc > V15_MISSING_MS)
        {
         V15Log(StringFormat("trade #%I64u is neither open nor in the history after 60 s - no longer tracked", g_pos[i].ticket));
         RemovePos(i);
        }
     }
   if(banked && g_cycle && !g_closing && g_posCount > 0)
      SaveBank();
  }

//--- the trade's own net result if it closed now: profit + swap - both commissions (closing = opening)
double TradeNet(const int i)
  {
   return FloorCent(g_pos[i].profit) + g_pos[i].swapNow + 2.0 * g_pos[i].entryMoney;
  }

//--- the open trades together (hard stop)
double FloatNet()
  {
   double v = 0.0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         v += TradeNet(i);
   return v;
  }

bool AllEntriesKnown()
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen && !g_pos[i].entryKnown)
         return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Orders (market only; the bot waits for each result)              |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING DetectFilling()
  {
   long fm = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((fm & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((fm & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

bool SendRequest(MqlTradeRequest &req, MqlTradeResult &res, const string what)
  {
   ZeroMemory(res);
   bool sent = OrderSend(req, res);
   if(sent && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL ||
               res.retcode == TRADE_RETCODE_PLACED))
      return true;
   if(res.retcode == TRADE_RETCODE_INVALID_FILL)
     {
      //--- the broker refused this filling type: use the next one from the next attempt on
      g_filling = (g_filling == ORDER_FILLING_FOK ? ORDER_FILLING_IOC :
                   (g_filling == ORDER_FILLING_IOC ? ORDER_FILLING_RETURN : ORDER_FILLING_FOK));
     }
   V15Log(StringFormat("%s failed: retcode %u %s", what, res.retcode, res.comment));
   return false;
  }

//--- a trade at market: a pair leg, trade 3 or the emergency hedge
bool OpenTrade(const int dir, const double lots, const int role)
  {
   if(!SymbolInfoTick(_Symbol, g_tick))
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = lots;
   req.type         = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   req.price        = (dir > 0 ? g_tick.ask : g_tick.bid);
   req.deviation    = V15_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = RoleComment(role);
   req.type_filling = g_filling;
   if(!SendRequest(req, res, StringFormat("open %s %s lots (%s)", DirName(dir), LotsText(lots), RoleName(role))))
      return false;
   if(role == V15_ROLE_BUY)
      StartCycle();
   else
      g_cTrades++;
   ulong id = 0;
   if(res.deal > 0 && HistoryDealSelect(res.deal))
      id = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
   if(id == 0)
      id = res.order;
   if(id > 0)
     {
      if(FindPos(id) < 0)
        {
         int i = AddPos(id, id, role, dir);
         if(i >= 0)
           {
            g_pos[i].openPrice = (res.price > 0.0 ? res.price : req.price);
            g_pos[i].lots      = lots;
            ReadEntry(i);
           }
        }
     }
   else
     {
      g_expectRole = role;                // the trade shows up in the list later: Sync gives it this role
      g_expectDir  = dir;
      g_expectMsc  = g_nowMsc;
     }
   Sync();
   return true;
  }

bool DeleteOrder(const ulong ticket)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_REMOVE;
   req.order  = ticket;
   return SendRequest(req, res, StringFormat("delete order #%I64u", ticket));
  }

bool ClosePosition(const int i, const string tag)
  {
   ulong ticket = g_pos[i].ticket;
   if(!PositionSelectByTicket(ticket))
      return true;                        // already closed
   if(!SymbolInfoTick(_Symbol, g_tick))
      return false;
   bool            isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.position     = ticket;
   req.symbol       = _Symbol;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.type         = (isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
   req.price        = (isBuy ? g_tick.bid : g_tick.ask);
   req.deviation    = V15_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = "V15 " + tag;
   req.type_filling = g_filling;
   return SendRequest(req, res, StringFormat("close #%I64u %s (%s)", ticket, RoleName(g_pos[i].role), tag));
  }

//--- the bot uses no pending orders: any of its pending orders (e.g. placed by hand) is deleted.
//--- Returns true while there are any.
bool DeleteStrays()
  {
   bool found = false;
   for(int k = OrdersTotal() - 1; k >= 0; k--)
     {
      ulong ticket = OrderGetTicket(k);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY || type == ORDER_TYPE_SELL)
         continue;                        // a market order on its way, not a pending order
      found = true;
      if(g_nowMsc >= g_orderNextTry && !DeleteOrder(ticket))
         g_orderNextTry = g_nowMsc + V15_CLOSE_RETRY_MS;
     }
   return found;
  }

//+------------------------------------------------------------------+
//| P1: margin for the whole cycle, by the broker's hedge rule       |
//+------------------------------------------------------------------+
//--- margin of one order in the account currency (negative = cannot be calculated)
double MarginOf(const int dir, const double lots, const double price)
  {
   if(lots <= V15_EPS)
      return 0.0;
   double m = 0.0;
   if(!OrderCalcMargin((dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL), _Symbol, lots, price, m))
      return -1.0;
   return m;
  }

//--- share of the normal margin the broker charges on covered (hedged) volume
double HedgedShare()
  {
   double cs = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   double hm = SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_HEDGED);
   if(SymbolInfoDouble(_Symbol, SYMBOL_MARGIN_INITIAL) > 0.0 || cs <= 0.0)
      return 1.0;                         // fixed margin: covered volume is counted like normal volume (careful side)
   return MathMax(hm, 0.0) / cs;
  }

//--- margin of 'lotsA' lots in 'dirA' plus 'lotsB' lots the other way (negative = unknown)
double SidesMargin(const int dirA, const double lotsA, const double lotsB)
  {
   double pa = (dirA > 0 ? g_tick.ask : g_tick.bid);
   double pb = (dirA > 0 ? g_tick.bid : g_tick.ask);
   if(lotsB <= V15_EPS)
      return MarginOf(dirA, lotsA, pa);
   if(lotsA <= V15_EPS)
      return MarginOf(-dirA, lotsB, pb);
   if(SymbolInfoInteger(_Symbol, SYMBOL_MARGIN_HEDGED_USE_LEG) != 0)
     {
      double mA = MarginOf(dirA, lotsA, pa);
      double mB = MarginOf(-dirA, lotsB, pb);
      if(mA < 0.0 || mB < 0.0)
         return -1.0;
      return MathMax(mA, mB);             // the bigger side only
     }
   //--- uncovered volume at the normal rate + covered volume at the broker's hedged rate
   bool   bigA = (lotsA >= lotsB);
   double unc  = MathAbs(lotsA - lotsB);
   double cov  = MathMin(lotsA, lotsB);
   double mUnc = (bigA ? MarginOf(dirA, unc, pa) : MarginOf(-dirA, unc, pb));
   double mCov = MarginOf(dirA, cov, pa);
   if(mUnc < 0.0 || mCov < 0.0)
      return -1.0;
   return mUnc + HedgedShare() * mCov;
  }

//--- the most margin of a cycle at stage 1 (pair), 2 (+ trade 3) or 3 (+ emergency hedge), either way
double CycleMargin(const int stage)
  {
   double worst = 0.0;
   for(int d = -1; d <= 1; d += 2)
     {
      double a = InpBaseLots;             // lots in direction d
      double b = InpBaseLots;             // lots the other way
      if(stage >= 2)
        {
         if(InpMode == V15_MODE_HARVEST)
           {
            a = 2.0 * InpBaseLots;        // the losing leg + trade 3 (the winning leg is closed)
            b = 0.0;
           }
         else
            a = 2.0 * InpBaseLots;        // the winning leg + trade 3, the losing leg the other way
        }
      if(stage >= 3)
         b += g_lotHedge;
      double m = SidesMargin(d, a, b);
      if(m < 0.0)
         return -1.0;
      worst = MathMax(worst, m);
     }
   return worst;
  }

//--- P1: free margin must cover the whole cycle with the hedge x 1.5 before a new pair
bool MarginOk()
  {
   double need  = CycleMargin(3);
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   bool   ok    = (need >= 0.0 && freeM >= need * V15_MARGIN_SAFETY);
   if(!ok && !g_marginLow)
     {
      if(need < 0.0)
         V15Log("the margin for the cycle cannot be calculated now - no new pair until it can");
      else
         V15Log(StringFormat("not enough free margin for the whole cycle: it needs %s x %.1f = %s, free margin is %s - no new pair until there is enough",
                             Amount(need), V15_MARGIN_SAFETY, Amount(need * V15_MARGIN_SAFETY), Amount(freeM)));
     }
   if(ok && g_marginLow)
      V15Log(StringFormat("free margin is enough again: %s free for %s x %.1f", Amount(freeM), Amount(need), V15_MARGIN_SAFETY));
   g_marginLow = !ok;
   return ok;
  }

void PrintMarginInfo()
  {
   string rule = (SymbolInfoInteger(_Symbol, SYMBOL_MARGIN_HEDGED_USE_LEG) != 0 ? "bigger side only" :
                  StringFormat("covered volume at %.0f%% of the normal margin", HedgedShare() * 100.0));
   V15Log(StringFormat("margin for a whole cycle now: pair %s | with trade 3 %s | with the emergency hedge %s | broker hedge rule: %s | free margin %s | a new pair needs free margin of the whole cycle x %.1f",
                       Amount(CycleMargin(1)), Amount(CycleMargin(2)), Amount(CycleMargin(3)), rule,
                       Amount(AccountInfoDouble(ACCOUNT_MARGIN_FREE)), V15_MARGIN_SAFETY));
  }

//--- P2: no new pair and no step while the spread is above InpMaxSpread
bool SpreadOk()
  {
   return (InpMaxSpread <= 0.0 || g_tick.ask - g_tick.bid <= InpMaxSpread + g_priceEps);
  }

//+------------------------------------------------------------------+
//| P3: news windows (no new pair, no step; open cycles carry on)    |
//+------------------------------------------------------------------+
//--- characters the optimizer may wrap a string input in: quotes, spaces, tabs, line ends, no-break space
bool IsWrapChar(const ushort ch)
  {
   return (ch == '"' || ch == '\'' || ch == ' ' || ch == '\t' || ch == '\r' || ch == '\n' || ch == 0xA0 || ch == 0);
  }

//--- the text without wrap characters at either end (v14 build 1.1.1: the optimizer passed "15:00" with quotes)
string CleanText(const string text)
  {
   int n = StringLen(text);
   int a = 0;
   int b = n - 1;
   while(a <= b && IsWrapChar(StringGetCharacter(text, a)))
      a++;
   while(b >= a && IsWrapChar(StringGetCharacter(text, b)))
      b--;
   if(a > b)
      return "";
   return StringSubstr(text, a, b - a + 1);
  }

//--- the raw input with character codes, for the journal when an input is not valid
string RawText(const string text)
  {
   string codes = "";
   int n = StringLen(text);
   for(int c = 0; c < n; c++)
      codes += (c > 0 ? " " : "") + IntegerToString(StringGetCharacter(text, c));
   return StringFormat("[%s] (%d chars: %s)", text, n, codes);
  }

//--- the text is only digits 0-9
bool AllDigits(const string text)
  {
   int n = StringLen(text);
   if(n < 1)
      return false;
   for(int c = 0; c < n; c++)
     {
      ushort ch = StringGetCharacter(text, c);
      if(ch < '0' || ch > '9')
         return false;
     }
   return true;
  }

//--- "HH:MM" -> minutes after midnight (-1 = not a valid time). Quotes and spaces around it are ignored.
int MinutesOf(const string text)
  {
   string s = CleanText(text);
   string parts[];
   if(StringSplit(s, StringGetCharacter(":", 0), parts) != 2)
      return -1;
   int v[2] = {0, 0};
   for(int k = 0; k < 2; k++)
     {
      int n = StringLen(parts[k]);
      if(n < 1 || n > 2 || !AllDigits(parts[k]))
         return -1;
      v[k] = (int)StringToInteger(parts[k]);
     }
   if(v[0] > 23 || v[1] > 59)
      return -1;
   return v[0] * 60 + v[1];
  }

//--- "YYYY.MM.DD" -> YYYYMMDD (-1 = not a valid date)
int DateOf(const string text)
  {
   string s = CleanText(text);
   if(StringLen(s) != 10 || StringGetCharacter(s, 4) != '.' || StringGetCharacter(s, 7) != '.')
      return -1;
   string ys = StringSubstr(s, 0, 4);
   string ms = StringSubstr(s, 5, 2);
   string ds = StringSubstr(s, 8, 2);
   if(!AllDigits(ys) || !AllDigits(ms) || !AllDigits(ds))
      return -1;
   int y = (int)StringToInteger(ys);
   int m = (int)StringToInteger(ms);
   int d = (int)StringToInteger(ds);
   if(y < 2000 || y > 2100 || m < 1 || m > 12 || d < 1 || d > 31)
      return -1;
   return y * 10000 + m * 100 + d;
  }

//--- InpRateDays -> g_rateDays. Returns "" or the error text.
string ParseRateDays(const string text)
  {
   g_rateCount = 0;
   string s = CleanText(text);
   if(s == "")
      return "";
   string parts[];
   int n = StringSplit(s, StringGetCharacter(",", 0), parts);
   for(int k = 0; k < n; k++)
     {
      if(CleanText(parts[k]) == "")
         continue;
      int v = DateOf(parts[k]);
      if(v < 0)
         return "InpRateDays: " + RawText(parts[k]) + " is not a date like 2026.10.28 (YYYY.MM.DD)";
      if(g_rateCount >= V15_MAX_RATE_DAYS)
         return StringFormat("InpRateDays: at most %d dates", V15_MAX_RATE_DAYS);
      g_rateDays[g_rateCount] = v;
      g_rateCount++;
     }
   return "";
  }

string ClockText(const int minutes)
  {
   return StringFormat("%02d:%02d", minutes / 60, minutes % 60);
  }

//--- the window of this tick (server time): 0 none, 1 the daily news window (Mon-Fri), 2 a rate decision window
int NewsWindowNow()
  {
   if(!InpNewsFilter)
      return 0;
   MqlDateTime dt;
   TimeToStruct((datetime)(g_nowMsc / 1000), dt);
   if(dt.day_of_week < 1 || dt.day_of_week > 5)
      return 0;
   int m = dt.hour * 60 + dt.min;
   if(m >= g_newsStart && m < g_newsEnd)
      return 1;
   if(g_rateCount > 0 && m >= g_rateStart && m < g_rateEnd)
     {
      int day = dt.year * 10000 + dt.mon * 100 + dt.day;
      for(int k = 0; k < g_rateCount; k++)
         if(g_rateDays[k] == day)
            return 2;
     }
   return 0;
  }

//--- every tick; one journal line when a window starts
void UpdateNewsWindow()
  {
   int now = NewsWindowNow();
   if(now != 0 && now != g_inNews)
     {
      if(now == 1)
         V15Log(StringFormat("news window %s-%s: no new pair and no step until %s%s", ClockText(g_newsStart), ClockText(g_newsEnd),
                             ClockText(g_newsEnd), (g_cycle ? " (the open cycle keeps its hedge and exits)" : "")));
      else
         V15Log(StringFormat("rate decision window %s-%s: no new pair and no step until %s%s", ClockText(g_rateStart), ClockText(g_rateEnd),
                             ClockText(g_rateEnd), (g_cycle ? " (the open cycle keeps its hedge and exits)" : "")));
     }
   g_inNews = now;
  }

//+------------------------------------------------------------------+
//| Trend (closed bars only)                                         |
//+------------------------------------------------------------------+
double Buf(const int handle, const int buffer, const int shift)
  {
   double b[];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1)
      return EMPTY_VALUE;
   return b[0];
  }

//--- step 3: once per new trend bar. False = the data is not ready (tried again next tick).
bool ReadTrend()
  {
   double fast = Buf(g_hFast, 0, 1);
   double slow = Buf(g_hSlow, 0, 1);
   if(fast == EMPTY_VALUE || slow == EMPTY_VALUE)
      return false;
   g_trend = (fast > slow ? 1 : (fast < slow ? -1 : 0));
   return true;
  }

//+------------------------------------------------------------------+
//| Cycle end                                                        |
//+------------------------------------------------------------------+
void FinishCycle()
  {
   string how = "";
   if(g_endTag == "BT")
     {
      how = "basket target";
      g_sumBT++;
     }
   else if(g_endTag == "ET")
     {
      how = "emergency target after the hedge";
      g_sumET++;
     }
   else if(g_endTag == "HS")
     {
      how = StringFormat("hard stop, open trades at %s", Money(g_endFloat));
      g_sumHS++;
     }
   else if(g_endTag == "HF")
     {
      how = "a trade of the cycle could not open";
      g_sumHF++;
     }
   else
     {
      how = (g_endTag == "RS" ? "restart: the trades did not form a cycle" : "closed outside the bot");
      g_sumOther++;
     }
   string step = "no step";
   if(g_stepDone)
     {
      g_sumSteps++;
      if(InpMode == V15_MODE_HARVEST)
         step = StringFormat("harvested the %s leg at %s, trade 3 %s", DirName(g_moveDir), Money(g_harvestNet), DirName(g_t3Dir));
      else
         step = StringFormat("kept both legs, trade 3 %s", DirName(g_t3Dir));
     }
   string hedge = "no hedge";
   if(g_hedged)
     {
      g_sumHedges++;
      hedge = StringFormat("emergency hedge %s %s", DirName(g_hedgeDir), LotsText(g_hedgeLots));
     }
   g_sumCycles++;
   g_sumNet += g_cBank;
   V15Log(StringFormat("CYCLE #%d: %s | result %s | %s | %s | %d trades opened, at most %d open at once | %s -> %s",
                       g_cNo, how, Money(g_cBank), step, hedge, g_cTrades, g_cMaxOpen, TimeText(g_cStart), TimeText(TimeCurrent())));
   ClearBank();
   g_cycle       = false;
   g_cBank       = 0.0;
   g_sellPending = false;
   g_stepDone    = false;
   g_t3Pending   = false;
   g_t3Done      = false;
   g_hedged      = false;
   g_moveDir     = 0;
   g_t3Dir       = 0;
   g_addFails    = 0;
   g_endTag      = "";
   g_endFloat    = 0.0;
  }

void CheckCycleEnd()
  {
   if(g_cycle && !g_closing && g_posCount == 0 && g_expectRole == 0)
      FinishCycle();
  }

//--- step 2: close every trade; when all are gone, the cycle ends
void ServiceClosing()
  {
   if(g_nowMsc >= g_closeNextTry)
     {
      bool failed = false;
      for(int i = 0; i < g_posCount; i++)
        {
         if(g_pos[i].isOpen && !ClosePosition(i, g_closeTag))
            failed = true;
        }
      if(failed)
         g_closeNextTry = g_nowMsc + V15_CLOSE_RETRY_MS;
      Sync();
     }
   if(DeleteStrays() || g_posCount > 0)
      return;                             // not all gone yet
   g_closing = false;
   if(g_cycle)
      FinishCycle();
   g_closeTag = "";
  }

void BeginCloseAll(const string tag)
  {
   g_closing      = true;
   g_closeTag     = tag;
   g_closeNextTry = 0;
   if(g_cycle)
     {
      g_endTag   = tag;
      g_endFloat = FloatNet();
     }
   ServiceClosing();
  }

//+------------------------------------------------------------------+
//| Steps 4-7: the open cycle                                        |
//+------------------------------------------------------------------+
//--- step 4: hard stop, then the basket target (before the hedge) or the emergency target (after it).
//--- True when all trades are being closed.
bool CheckExits()
  {
   if(OpenCount() == 0)
      return false;
   double fl = FloatNet();
   if(fl <= -InpHardStop + V15_EPS)
     {
      BeginCloseAll("HS");
      return true;
     }
   if(!AllEntriesKnown())
      return false;
   double target = (g_hedged ? InpEmergencyTarget : InpBasketTarget);
   if(g_cBank + fl >= target - V15_EPS)
     {
      BeginCloseAll(g_hedged ? "ET" : "BT");
      return true;
     }
   return false;
  }

//--- a pair leg, trade 3 or the hedge that fails 3 times closes the cycle
void AddFailed(const string what)
  {
   g_addFails++;
   if(g_addFails >= V15_ADD_MAX_FAILS)
     {
      V15Log(StringFormat("the %s could not open %d times - all trades of cycle #%d are closed", what, g_addFails, g_cNo));
      BeginCloseAll("HF");
      return;
     }
   g_addNextTry = g_nowMsc + V15_ADD_RETRY_MS;
  }

//--- step 5a: the pair's SELL leg (right after the BUY leg, or again after a failure)
void PairSell()
  {
   if(!g_cycle || !g_sellPending || g_closing || g_endTag != "" || g_nowMsc < g_addNextTry)
      return;
   if(OpenTrade(-1, InpBaseLots, V15_ROLE_SELL))
     {
      g_sellPending = false;
      g_addFails    = 0;
      return;
     }
   AddFailed("pair SELL");
  }

//--- step 5b: trade 3 (right after the step, or again after a failure)
void Trade3()
  {
   if(!g_cycle || !g_t3Pending || g_closing || g_endTag != "" || g_nowMsc < g_addNextTry)
      return;
   if(OpenTrade(g_t3Dir, InpBaseLots, V15_ROLE_T3))
     {
      g_t3Pending = false;
      g_t3Done    = true;
      g_addFails  = 0;
      return;
     }
   AddFailed("trade 3");
  }

//--- step 6: a pair leg at InpHarvestTarget -> mode 1: bank it, trade 3 on the pullback side;
//--- mode 2: keep it, trade 3 with the move. Only with the trend check, P2 and P3 passed.
void Step()
  {
   if(!g_cycle || g_stepDone || g_sellPending || g_closing || g_endTag != "")
      return;
   if(g_nowMsc < g_closeNextTry || g_nowMsc < g_addNextTry)
      return;
   int b = FindRole(V15_ROLE_BUY);
   int s = FindRole(V15_ROLE_SELL);
   if(b < 0 || s < 0 || !g_pos[b].entryKnown || !g_pos[s].entryKnown)
      return;
   int w = -1;
   if(TradeNet(b) >= InpHarvestTarget - V15_EPS)
      w = b;
   else if(TradeNet(s) >= InpHarvestTarget - V15_EPS)
      w = s;
   if(w < 0)
      return;
   int moveDir = g_pos[w].dir;
   int t3Dir   = (InpMode == V15_MODE_HARVEST ? -moveDir : moveDir);
   if(g_inNews != 0 || !SpreadOk())
      return;                             // P3 / P2: the step waits
   if(InpTrendCheck && g_trend != t3Dir)
      return;                             // the trend does not agree with trade 3 yet
   int after = NormalOpen() - (InpMode == V15_MODE_HARVEST ? 1 : 0) + 1;
   if(after > InpMaxOpenTrades)
      return;
   if(InpMode == V15_MODE_HARVEST)
     {
      double net = TradeNet(w);
      if(!ClosePosition(w, "HV"))
        {
         g_closeNextTry = g_nowMsc + V15_CLOSE_RETRY_MS;
         return;
        }
      g_harvestNet = net;
     }
   g_moveDir   = moveDir;
   g_t3Dir     = t3Dir;
   g_stepDone  = true;
   g_t3Pending = true;
   g_addFails  = 0;
   Sync();
   Trade3();
  }

//--- step 7: gold InpHedgeDistance against trade 3 -> the emergency hedge: InpHedgeMult x the net lots, the other way
void Hedge()
  {
   if(!g_cycle || !g_t3Done || g_hedged || g_closing || g_endTag != "" || g_nowMsc < g_addNextTry)
      return;
   int t = FindRole(V15_ROLE_T3);
   if(t < 0)
      return;
   double p3  = g_pos[t].openPrice;
   int    d3  = g_pos[t].dir;
   bool   hit = (d3 > 0 ? g_tick.bid <= p3 - InpHedgeDistance + g_priceEps
                        : g_tick.ask >= p3 + InpHedgeDistance - g_priceEps);
   if(!hit)
      return;
   double net    = NetLots();
   int    netDir = (net > V15_EPS ? 1 : (net < -V15_EPS ? -1 : 0));
   if(netDir == 0)
      return;                             // nothing leans one way: nothing to hedge
   double lots = NormalizeLots(InpHedgeMult * MathAbs(net));
   if(lots <= V15_EPS)
      return;
   if(OpenTrade(-netDir, lots, V15_ROLE_HEDGE))
     {
      g_hedged    = true;
      g_hedgeLots = lots;
      g_hedgeDir  = -netDir;
      g_addFails  = 0;
      return;
     }
   AddFailed("emergency hedge");
  }

//+------------------------------------------------------------------+
//| Step 8: a new pair                                               |
//+------------------------------------------------------------------+
void ManageEntry()
  {
   if(g_closing || g_cycle)
      return;
   if(DeleteStrays())
      return;                             // the bot's pending orders are deleted first
   if(g_posCount > 0)
     {
      V15Log(StringFormat("%d v15 trades are open outside a cycle - they are closed", g_posCount));
      BeginCloseAll("RS");
      return;
     }
   if(g_expectRole != 0 || g_inNews != 0 || !SpreadOk() || g_nowMsc < g_openNextTry)
      return;                             // P3 / P2: no new pair
   if(!MarginOk())
     {
      g_openNextTry = g_nowMsc + V15_OPEN_RETRY_MS;
      return;
     }
   if(!OpenTrade(1, InpBaseLots, V15_ROLE_BUY))
     {
      g_openNextTry = g_nowMsc + V15_OPEN_RETRY_MS;
      return;
     }
   g_sellPending = true;                  // the SELL leg opens at once, on the same tick
   g_addFails    = 0;
   PairSell();
  }

//+------------------------------------------------------------------+
//| Restart (live only; nothing to do in the Strategy Tester)        |
//+------------------------------------------------------------------+
//--- first tick: carry on with the bot's own open trades if they form a cycle, else close them
void Adopt()
  {
   g_adopting = true;
   Sync();
   g_adopting = false;
   int n = g_posCount;
   if(n == 0)
      return;
   //--- in opening order
   for(int a = 0; a < n - 1; a++)
      for(int c = a + 1; c < n; c++)
         if(g_pos[c].openMsc < g_pos[a].openMsc)
           {
            V15Pos t = g_pos[a];
            g_pos[a] = g_pos[c];
            g_pos[c] = t;
           }
   bool harvest = (InpMode == V15_MODE_HARVEST);
   int  stage   = 0;                      // 1 pair, 2 after the step, 3 with the hedge
   if(OpenCount() == n)
     {
      if(n == 2 && g_pos[0].dir != g_pos[1].dir)
         stage = 1;
      else if(harvest && n == 2 && g_pos[0].dir == g_pos[1].dir)
         stage = 2;
      else if(harvest && n == 3 && g_pos[0].dir == g_pos[1].dir && g_pos[2].dir != g_pos[0].dir)
         stage = 3;
      else if(!harvest && n == 3 && g_pos[0].dir != g_pos[1].dir)
         stage = 2;
      else if(!harvest && n == 4 && g_pos[0].dir != g_pos[1].dir && g_pos[3].dir != g_pos[2].dir)
         stage = 3;
     }
   if(stage == 0)
     {
      V15Log(StringFormat("RESTART: %d open v15 trades do not form a cycle (%s) - all are closed", n, ModeText()));
      g_closing      = true;
      g_closeTag     = "RS";
      g_closeNextTry = 0;
      return;
     }
   int legs = (stage == 1 || !harvest ? 2 : 1);   // pair legs still open
   for(int i = 0; i < legs; i++)
      g_pos[i].role = (g_pos[i].dir > 0 ? V15_ROLE_BUY : V15_ROLE_SELL);
   if(stage >= 2)
      g_pos[legs].role = V15_ROLE_T3;
   if(stage == 3)
      g_pos[legs + 1].role = V15_ROLE_HEDGE;
   StartCycle();
   g_cStart   = (datetime)(g_pos[0].openMsc / 1000);
   g_cTrades  = n + (stage >= 2 && harvest ? 1 : 0);
   g_cMaxOpen = n;
   string bankText = "";
   if(stage >= 2)
     {
      g_stepDone = true;
      g_t3Done   = true;
      g_t3Dir    = g_pos[legs].dir;
      g_moveDir  = (harvest ? -g_t3Dir : g_t3Dir);
      if(harvest)
        {
         double bank = 0.0;
         if(LoadBank(g_pos[0].id, bank))
           {
            g_cBank      = bank;
            g_harvestNet = bank;
            bankText     = StringFormat(", banked %s", Money(bank));
           }
         else
            bankText = ", the banked money is not known: the targets count the open trades only";
        }
     }
   if(stage == 3)
     {
      g_hedged    = true;
      g_hedgeDir  = g_pos[legs + 1].dir;
      g_hedgeLots = g_pos[legs + 1].lots;
     }
   V15Log(StringFormat("RESTART: carrying on with cycle #%d (%s): %d open trades%s%s", g_cNo, ModeText(), n,
                       (stage == 1 ? ", the pair" : (stage == 2 ? ", after the step" : ", with the emergency hedge")), bankText));
  }

//+------------------------------------------------------------------+
//| Expert                                                           |
//+------------------------------------------------------------------+
void ResetState()
  {
   g_posCount     = 0;
   g_cycle        = false;
   g_cNo          = 0;
   g_cStart       = 0;
   g_cBank        = 0.0;
   g_cTrades      = 0;
   g_cMaxOpen     = 0;
   g_sellPending  = false;
   g_stepDone     = false;
   g_t3Pending    = false;
   g_t3Done       = false;
   g_hedged       = false;
   g_moveDir      = 0;
   g_t3Dir        = 0;
   g_harvestNet   = 0.0;
   g_hedgeLots    = 0.0;
   g_hedgeDir     = 0;
   g_addFails     = 0;
   g_endTag       = "";
   g_endFloat     = 0.0;
   g_closing      = false;
   g_closeTag     = "";
   g_expectRole   = 0;
   g_expectDir    = 0;
   g_expectMsc    = 0;
   g_lastBar      = 0;
   g_trend        = 0;
   g_marginLow    = false;
   g_inNews       = 0;
   g_rateCount    = 0;
   g_sumCycles    = 0;
   g_sumBT        = 0;
   g_sumET        = 0;
   g_sumHS        = 0;
   g_sumHF        = 0;
   g_sumOther     = 0;
   g_sumSteps     = 0;
   g_sumHedges    = 0;
   g_sumNet       = 0.0;
   g_nowMsc       = 0;
   g_openNextTry  = 0;
   g_addNextTry   = 0;
   g_closeNextTry = 0;
   g_orderNextTry = 0;
   g_needAdopt    = true;
   g_adopting     = false;
   ZeroMemory(g_tick);
  }

void CheckLot(const string name, const double lots, string &err)
  {
   if(err != "")
      return;
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstp = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lots < vmin - V15_EPS || lots > vmax + V15_EPS)
      err = StringFormat("%s %.3f is outside the broker's range %.2f - %.2f", name, lots, vmin, vmax);
   else if(vstp > 0.0 && MathAbs(lots / vstp - MathRound(lots / vstp)) > 0.000001)
      err = StringFormat("%s %.3f is not a multiple of the volume step %.2f", name, lots, vstp);
  }

bool InputsOk()
  {
   string err = "";
   CheckLot("InpBaseLots", InpBaseLots, err);
   if(err == "" && InpMode != V15_MODE_HARVEST && InpMode != V15_MODE_KEEP)
      err = "InpMode must be 1 (harvest) or 2 (keep all 3)";
   double hedgeBase = (InpMode == V15_MODE_HARVEST ? 2.0 : 1.0) * InpBaseLots;   // the net lots when the hedge opens
   if(err == "" && InpHedgeMult <= 0.0)
      err = "InpHedgeMult must be above 0";
   CheckLot("the emergency hedge lot (net lots x InpHedgeMult)", hedgeBase * InpHedgeMult, err);
   if(err == "" && InpHarvestTarget <= 0.0)
      err = "InpHarvestTarget must be above 0";
   if(err == "" && InpHardStop <= 0.0)
      err = "InpHardStop must be above 0";
   if(err == "" && (InpBasketTarget <= -InpHardStop || InpEmergencyTarget <= -InpHardStop))
      err = "InpBasketTarget and InpEmergencyTarget must be above -InpHardStop";
   if(err == "" && (InpMaxOpenTrades < 2 || InpMaxOpenTrades > 3))
      err = "InpMaxOpenTrades must be 2 or 3";
   if(err == "" && InpMode == V15_MODE_KEEP && InpMaxOpenTrades < 3)
      err = "InpMode 2 keeps 3 trades open: InpMaxOpenTrades must be 3";
   if(err == "" && InpHedgeDistance <= 0.0)
      err = "InpHedgeDistance must be above 0";
   if(err == "" && InpTrendCheck && (InpEmaFast < 1 || InpEmaSlow <= InpEmaFast))
      err = "InpEmaFast must be at least 1 and InpEmaSlow above it";
   if(err == "" && InpMaxSpread < 0.0)
      err = "InpMaxSpread must be 0 or more";
   if(err == "" && InpNewsFilter)
     {
      g_newsStart = MinutesOf(InpNewsStart);
      g_newsEnd   = MinutesOf(InpNewsEnd);
      if(g_newsStart < 0 || g_newsEnd < 0)
         err = "InpNewsStart and InpNewsEnd must be server times like 15:00 (HH:MM); got InpNewsStart " +
               RawText(InpNewsStart) + ", InpNewsEnd " + RawText(InpNewsEnd);
      else if(g_newsEnd <= g_newsStart)
         err = "InpNewsEnd must be later than InpNewsStart on the same day";
      if(err == "")
         err = ParseRateDays(InpRateDays);
      if(err == "" && g_rateCount > 0)
        {
         g_rateStart = MinutesOf(InpRateStart);
         g_rateEnd   = MinutesOf(InpRateEnd);
         if(g_rateStart < 0 || g_rateEnd < 0)
            err = "InpRateStart and InpRateEnd must be server times like 20:30 (HH:MM); got InpRateStart " +
                  RawText(InpRateStart) + ", InpRateEnd " + RawText(InpRateEnd);
         else if(g_rateEnd <= g_rateStart)
            err = "InpRateEnd must be later than InpRateStart on the same day";
        }
     }
   if(err == "" && InpMagic <= 0)
      err = "InpMagic must be above 0";
   if(err == "")
      return true;
   V15Log("input error: " + err);
   return false;
  }

void PrintSummary()
  {
   if(g_sumCycles == 0 && !g_cycle)
      return;
   double avg = (g_sumCycles > 0 ? g_sumNet / g_sumCycles : 0.0);
   V15Log(StringFormat("SUMMARY: %d cycles | basket target %d | emergency target %d | hard stops %d | failed %d | other %d | trade 3 in %d | emergency hedges %d | total %s | average per cycle %s%s",
                       g_sumCycles, g_sumBT, g_sumET, g_sumHS, g_sumHF, g_sumOther, g_sumSteps, g_sumHedges, Money(g_sumNet), Money(avg),
                       (g_cycle ? " | 1 cycle still open" : "")));
  }

int OnInit()
  {
   ResetState();
   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_ccy      = AccountInfoString(ACCOUNT_CURRENCY);
   if(!InputsOk())
      return INIT_PARAMETERS_INCORRECT;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      V15Log("needs a hedging account (BUY and SELL trades open at the same time) - not started");
      return INIT_FAILED;
     }
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   g_priceEps = g_tickSize * 0.5;
   g_filling  = DetectFilling();
   g_lotHedge = NormalizeLots((InpMode == V15_MODE_HARVEST ? 2.0 : 1.0) * InpBaseLots * InpHedgeMult);
   g_gvBank   = StringFormat("V15_%I64d_%s_bank", InpMagic, _Symbol);
   g_gvLeg    = StringFormat("V15_%I64d_%s_leg", InpMagic, _Symbol);
   if(InpTrendCheck)
     {
      g_hFast = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
      g_hSlow = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
      if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE)
        {
         V15Log("an indicator could not be created - not started");
         return INIT_FAILED;
        }
     }
   string mode  = (InpMode == V15_MODE_HARVEST ? "mode 1: bank the winning leg, trade 3 on the pullback side" :
                   "mode 2: keep both legs, trade 3 with the move");
   string trend = (InpTrendCheck ? StringFormat("trend check %s EMA %d/%d", EnumToString(InpTrendTF), InpEmaFast, InpEmaSlow) : "trend check off");
   string spr   = (InpMaxSpread > 0.0 ? StringFormat("%.2f $", InpMaxSpread) : "off");
   string news  = "off";
   if(InpNewsFilter)
      news = StringFormat("%s-%s Mon-Fri%s", ClockText(g_newsStart), ClockText(g_newsEnd),
                          (g_rateCount > 0 ? StringFormat(" + %s-%s on %d rate decision days", ClockText(g_rateStart), ClockText(g_rateEnd), g_rateCount) : ""));
   V15Log(StringFormat("build %s on %s | %s | pair + trade 3 %s lots, step at %s on a leg | %s | basket target %s | emergency hedge %s lots %.2f $ against trade 3, then target %s | hard stop %s | max open %d + hedge | max spread %s | news filter %s | magic %I64d%s",
                       V15_BUILD, _Symbol, mode, LotsText(InpBaseLots), Amount(InpHarvestTarget), trend, Money(InpBasketTarget),
                       LotsText(g_lotHedge), InpHedgeDistance, Money(InpEmergencyTarget), Money(-InpHardStop), InpMaxOpenTrades,
                       spr, news, InpMagic, (g_isTester ? " | Strategy Tester" : "")));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintSummary();
   if(g_hFast != INVALID_HANDLE)
      IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE)
      IndicatorRelease(g_hSlow);
  }

//--- the order of checks on every tick (see the top of the file)
void OnTick()
  {
   if(!SymbolInfoTick(_Symbol, g_tick) || g_tick.bid <= 0.0 || g_tick.ask <= 0.0)
      return;
   g_nowMsc = (g_tick.time_msc > 0 ? g_tick.time_msc : (long)TimeCurrent() * 1000);
   if(g_needAdopt)
     {
      g_needAdopt = false;
      Adopt();
      PrintMarginInfo();
     }
   if(g_expectRole != 0 && g_nowMsc - g_expectMsc > V15_MISSING_MS)
     {
      V15Log(StringFormat("the %s is not shown in the open trades after 60 s - no longer waited for", RoleName(g_expectRole)));
      g_expectRole = 0;
      g_expectDir  = 0;
     }
   //--- P3: is a news window on? (used in steps 6 and 8)
   UpdateNewsWindow();
   //--- 1. update the trades
   Sync();
   CheckCycleEnd();
   //--- 2. closing all trades: keep closing; when all are closed, the cycle ends
   if(g_closing)
     {
      ServiceClosing();
      if(g_closing)
         return;
     }
   //--- 3. new trend bar: read the trend from the closed bars
   if(InpTrendCheck)
     {
      datetime bar = iTime(_Symbol, InpTrendTF, 0);
      if(bar > 0 && bar != g_lastBar && ReadTrend())
         g_lastBar = bar;
     }
   //--- 4-7. the open cycle: exits, the SELL leg / trade 3 still to open, the step, the emergency hedge
   if(g_cycle && !CheckExits())
     {
      PairSell();
      Trade3();
      Step();
      Hedge();
     }
   if(g_closing)
      return;
   //--- 8. no cycle: a new pair
   ManageEntry();
  }
//+------------------------------------------------------------------+
