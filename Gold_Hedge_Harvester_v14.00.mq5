//+------------------------------------------------------------------+
//|                                  Gold_Hedge_Harvester_v14.00.mq5 |
//|  v14 Hedge Harvester - build 1.1                                 |
//|  Design: docs/V14_PLAN.md rev 3 (defaults + P1 + P2 + news P3)   |
//+------------------------------------------------------------------+
//  Direction, read at each new entry bar (InpEntryTF) from closed bars:
//    trend   : EMA InpEmaFast above EMA InpEmaSlow on InpTrendTF -> buys
//              only; below -> sells only
//    movement: ADX(InpAdxPeriod) on InpTrendTF at least InpAdxMin, so the
//              bot pauses in flat markets (InpAdxMin 0 = off)
//    RSI     : on InpEntryTF, no new buy while RSI >= InpRsiMax, no new
//              sell while RSI <= 100 - InpRsiMax (InpRsiMax 100 = off)
//  Trade 1 (InpLots), one basket at a time:
//    mode 1, limit : while the last entry bar closed above (below) the entry
//                    EMA, a BUY (SELL) LIMIT waits at that EMA. It moves to
//                    the new EMA value at each new bar.
//    mode 2, market: after a bar has closed below (above) the entry EMA, the
//                    first bar that closes back above (below) it with RSI
//                    above (below) 50 opens trade 1 at market.
//    After a basket ends, the next trade 1 needs the signal of a new bar.
//  Winning path: trade 1 alone closes at InpHarvestNet net (harvest).
//  Losing path : gold InpHedgeDistance against trade 1 -> the hedge opens
//                the other way (InpLots x InpHedgeMult). With InpMaxTrades 3:
//                gold back at trade 1's price -> trade 3 opens the same way
//                as trade 1 (InpLots x InpTrade3Mult). After the hedge, all
//                trades close together at InpBasketTarget net.
//  Hard stop   : the open trades together at -InpHardStop -> close all.
//  P1 margin   : trade 1 only if free margin covers the whole basket x 1.5
//                (broker's hedge rule). A hedge or trade 3 that fails 3 times
//                closes the basket.
//  P2 spread   : no new trade 1 while the spread is above InpMaxSpread.
//  P3 news     : InpNewsFilter on -> no new trade 1 from InpNewsStart to
//                InpNewsEnd (server time), Monday to Friday. A waiting limit
//                order is deleted. Open baskets carry on as normal.
//
//  Order of checks on every tick:
//    1. update the trades and the limit order
//    2. closing all trades: keep closing; when all are closed, the basket's
//       result goes to the journal
//    3. hard stop   4. harvest (before the hedge) / basket target (after)
//    5. hedge   6. trade 3
//    7. new entry bar: read the signal
//    8. no basket: place, move or delete the limit (mode 1), or open trade 1
//       at market (mode 2). In the news window (P3): no trade 1, and a
//       waiting limit is deleted.
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "14.00"
#property description "v14 Hedge Harvester: trade 1 on a pullback in the trend. It harvests, or a 2x hedge opens the other way."
#property description "After the hedge all trades close together at the basket target. Hard stop on the whole basket."
#property description "Margin check for the whole basket (P1), spread limit (P2) and news window (P3) for trade 1. No other features."

#define V14_BUILD          "1.1"
#define V14_MAX_POS        8
#define V14_EPS            0.000000001
#define V14_DEVIATION      20
#define V14_OPEN_RETRY_MS  5000
#define V14_ADD_RETRY_MS   1000
#define V14_ADD_MAX_FAILS  3
#define V14_CLOSE_RETRY_MS 1000
#define V14_MISSING_MS     60000
#define V14_MARGIN_SAFETY  1.5
#define V14_ROLE_EXTRA     0
#define V14_ROLE_T1        1
#define V14_ROLE_HEDGE     2
#define V14_ROLE_T3        3

enum V14_ENTRY
  {
   V14_ENTRY_LIMIT  = 1,    // 1: limit order at the entry EMA (pullback)
   V14_ENTRY_MARKET = 2     // 2: market, when RSI confirms after a pullback
  };

//--- inputs: this is the complete list (docs/V14_PLAN.md, section 8)
input double          InpLots          = 0.01;            // Trade 1 lot size
input int             InpMaxTrades     = 2;               // Most trades in a basket (1 = no hedge, 2 = + hedge, 3 = + trade 3)
input double          InpHarvestNet    = 4.00;            // Harvest: trade 1 alone closes at this net (after costs)
input double          InpHedgeDistance = 8.00;            // Hedge: opens when gold is this many $ against trade 1
input double          InpHedgeMult     = 2.0;             // Hedge lot = InpLots x this
input double          InpTrade3Mult    = 3.0;             // Trade 3 lot = InpLots x this (InpMaxTrades 3 only)
input double          InpBasketTarget  = 1.00;            // After the hedge: all trades close together at this net
input double          InpHardStop      = 30.00;           // Hard stop: loss of the open trades together
input V14_ENTRY       InpEntryMode     = V14_ENTRY_LIMIT; // Trade 1 entry
input ENUM_TIMEFRAMES InpTrendTF       = PERIOD_M15;      // Trend timeframe (EMAs and ADX)
input int             InpEmaFast       = 20;              // Trend: fast EMA
input int             InpEmaSlow       = 50;              // Trend: slow EMA
input int             InpAdxPeriod     = 14;              // Movement: ADX period
input double          InpAdxMin        = 15.0;            // Movement: no new basket while ADX is below this (0 = off)
input ENUM_TIMEFRAMES InpEntryTF       = PERIOD_M5;       // Entry timeframe (entry EMA and RSI)
input int             InpPullEma       = 20;              // Entry: pullback EMA
input int             InpRsiPeriod     = 14;              // Entry: RSI period
input double          InpRsiMax        = 70.0;            // Entry: no buy at RSI >= this, no sell at RSI <= 100 - this (100 = off)
input double          InpMaxSpread     = 1.00;            // No new trade 1 while the spread is above this many $ (0 = off)
input bool            InpNewsFilter    = true;            // News filter: no new trade 1 from start to end, Mon-Fri (open trades carry on)
input string          InpNewsStart     = "15:00";         // News filter start, server time HH:MM (Pepperstone 15:30 = 8:30 New York)
input string          InpNewsEnd       = "15:45";         // News filter end, server time HH:MM (trade 1 allowed again from this minute)
input long            InpMagic         = 140001;          // Magic number

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
struct V14Pos
  {
   ulong  ticket;       // position ticket (to select and close it)
   ulong  id;           // position identifier (its deals in the history)
   int    role;         // V14_ROLE_T1 / _HEDGE / _T3, or _EXTRA (not opened by this basket)
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

V14Pos   g_pos[V14_MAX_POS];
int      g_posCount     = 0;

//--- the basket: trade 1, then maybe the hedge and trade 3
bool     g_basket       = false;
int      g_bNo          = 0;
int      g_bDir         = 0;       // trade 1 direction
datetime g_bStart       = 0;
double   g_bNet         = 0.0;     // closed trades of this basket
int      g_bTrades      = 0;       // trades opened in this basket
int      g_bMaxOpen     = 0;       // most trades open at once
bool     g_hedged       = false;   // the hedge has opened: the basket target is the exit now
bool     g_t3Done       = false;   // trade 3 has opened (only once per basket)
int      g_addFails     = 0;       // failed tries of the hedge / trade 3
string   g_endTag       = "";      // how the basket ends: HV, BT, HS, HF
double   g_hsValue      = 0.0;     // the open trades together when all were closed (journal)

//--- closing all trades
bool     g_closing      = false;
string   g_closeTag     = "";      // closing comment: BT, HS, HF, RS

//--- the trade 1 limit order (never more than one)
ulong    g_limitTicket  = 0;
int      g_limitDir     = 0;
double   g_limitPrice   = 0.0;
long     g_limitGoneMsc = 0;       // when it was first missing from the order list (0 = seen)

//--- a market trade whose position number was not known when it opened
int      g_expectRole   = 0;
int      g_expectDir    = 0;
long     g_expectMsc    = 0;

//--- signal of the current entry bar
datetime g_lastBar      = 0;
int      g_sigDir       = 0;       // +1 buy side, -1 sell side, 0 none
double   g_sigPrice     = 0.0;     // mode 1: limit price (entry EMA of the last closed bar)
bool     g_sigArmed     = false;   // mode 2: the market signal can still be used in this bar
bool     g_pullBuy      = false;   // mode 2: a bar closed below the entry EMA since the last reclaim
bool     g_pullSell     = false;   // mode 2: a bar closed above the entry EMA since the last reclaim
int      g_marginState  = 0;       // P1 for the next trade 1: 0 not checked yet, 1 enough, -1 not enough
bool     g_marginLow    = false;   // the last check found too little margin (journal once)
bool     g_inNews       = false;   // P3: the news window is on now (no new trade 1)
int      g_newsStart    = 0;       // P3: window start, minutes after midnight (server time)
int      g_newsEnd      = 0;       // P3: window end (this minute is outside the window)

//--- summary (journal at the end)
int      g_sumBaskets   = 0;
int      g_sumHV        = 0;
int      g_sumBT2       = 0;
int      g_sumBT3       = 0;
int      g_sumHS        = 0;
int      g_sumHF        = 0;
int      g_sumOther     = 0;
double   g_sumNet       = 0.0;

//--- indicators
int      g_hFast        = INVALID_HANDLE;
int      g_hSlow        = INVALID_HANDLE;
int      g_hAdx         = INVALID_HANDLE;
int      g_hPull        = INVALID_HANDLE;
int      g_hRsi         = INVALID_HANDLE;

MqlTick  g_tick;
long     g_nowMsc       = 0;
long     g_openNextTry  = 0;       // trade 1 at market: not before this time (after a failure)
long     g_orderNextTry = 0;       // limit order place / move / delete: not before this time
long     g_addNextTry   = 0;       // hedge / trade 3: not before this time
long     g_closeNextTry = 0;       // closes: not before this time
ENUM_ORDER_TYPE_FILLING g_filling   = ORDER_FILLING_FOK;
ENUM_ORDER_TYPE_TIME    g_orderTime = ORDER_TIME_GTC;
double   g_tickSize     = 0.01;
double   g_priceEps     = 0.005;
double   g_lotHedge     = 0.02;
double   g_lotT3        = 0.03;
bool     g_isTester     = false;
bool     g_needAdopt    = true;
bool     g_adopting     = false;
string   g_ccy          = "";

//+------------------------------------------------------------------+
//| Text                                                             |
//+------------------------------------------------------------------+
void V14Log(const string text)
  {
   Print("v14 ", text);
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
   if(role == V14_ROLE_T1)
      return "trade 1";
   if(role == V14_ROLE_HEDGE)
      return "hedge";
   if(role == V14_ROLE_T3)
      return "trade 3";
   return "extra trade";
  }

string RoleComment(const int role)
  {
   if(role == V14_ROLE_HEDGE)
      return "V14 H";
   if(role == V14_ROLE_T3)
      return "V14 3";
   return "V14 1";
  }

double NormalizePrice(const double p)
  {
   return NormalizeDouble(MathRound(p / g_tickSize) * g_tickSize, _Digits);
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
void ClearLimit()
  {
   g_limitTicket  = 0;
   g_limitDir     = 0;
   g_limitPrice   = 0.0;
   g_limitGoneMsc = 0;
  }

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

int AddPos(const ulong ticket, const ulong id, const int role, const int dir)
  {
   if(g_posCount >= V14_MAX_POS)
     {
      V14Log(StringFormat("too many v14 trades - #%I64u is not tracked", ticket));
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

void StartBasket(const int dir)
  {
   g_basket     = true;
   g_bNo++;
   g_bDir       = dir;
   g_bStart     = TimeCurrent();
   g_bNet       = 0.0;
   g_bTrades    = 1;
   g_bMaxOpen   = 1;
   g_hedged     = false;
   g_t3Done     = false;
   g_addFails   = 0;
   g_addNextTry = 0;
   g_endTag     = "";
   g_hsValue    = 0.0;
  }

//--- role of a trade found in the terminal that the bot does not track yet
int RoleForNew(const ulong id, const int dir)
  {
   if(g_limitTicket != 0 && id == g_limitTicket)
     {
      ClearLimit();                       // the limit order has filled: this is trade 1
      if(!g_basket)
        {
         StartBasket(dir);
         return V14_ROLE_T1;
        }
     }
   else if(g_expectRole != 0 && dir == g_expectDir)
     {
      int role     = g_expectRole;        // a market trade whose number was not known when it opened
      g_expectRole = 0;
      g_expectDir  = 0;
      return role;
     }
   else if(g_adopting)
      return V14_ROLE_EXTRA;              // restart: Adopt() gives the roles
   else if(!g_basket)
     {
      V14Log(StringFormat("found open trade #%I64u %s -> trade 1 of a new basket", id, DirName(dir)));
      StartBasket(dir);
      return V14_ROLE_T1;
     }
   V14Log(StringFormat("found an extra open trade #%I64u %s - it closes with the basket", id, DirName(dir)));
   return V14_ROLE_EXTRA;
  }

//--- step 1: read the open trades; a filled limit order shows up here as trade 1
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
   if(g_basket && open > g_bMaxOpen)
      g_bMaxOpen = open;
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
         if(g_basket)
            g_bNet += net;
         RemovePos(i);
         continue;
        }
      //--- not open and not closed in the history yet: wait for the terminal to catch up
      if(g_pos[i].missingMsc == 0)
         g_pos[i].missingMsc = g_nowMsc;
      else if(g_nowMsc - g_pos[i].missingMsc > V14_MISSING_MS)
        {
         V14Log(StringFormat("trade #%I64u is neither open nor in the history after 60 s - no longer tracked", g_pos[i].ticket));
         RemovePos(i);
        }
     }
  }

//--- the trade's own net result if it closed now: profit + swap - both commissions (closing = opening)
double TradeNet(const int i)
  {
   return FloorCent(g_pos[i].profit) + g_pos[i].swapNow + 2.0 * g_pos[i].entryMoney;
  }

//--- the open trades together (basket target and hard stop)
double BasketNet()
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
//| Orders (one at a time; the bot waits for each result)            |
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
   V14Log(StringFormat("%s failed: retcode %u %s", what, res.retcode, res.comment));
   return false;
  }

//--- a trade at market: trade 1 (mode 2), the hedge or trade 3
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
   req.deviation    = V14_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = RoleComment(role);
   req.type_filling = g_filling;
   if(!SendRequest(req, res, StringFormat("open %s %s lots (%s)", DirName(dir), LotsText(lots), RoleName(role))))
      return false;
   if(role == V14_ROLE_T1)
      StartBasket(dir);
   else
      g_bTrades++;
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

//--- mode 1: the trade 1 limit order
bool PlaceLimit(const int dir, const double price)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = InpLots;
   req.type         = (dir > 0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   req.price        = price;
   req.magic        = (ulong)InpMagic;
   req.comment      = RoleComment(V14_ROLE_T1);
   req.type_filling = g_filling;
   req.type_time    = g_orderTime;
   if(!SendRequest(req, res, StringFormat("place %s LIMIT at %s", DirName(dir), PriceText(price))))
      return false;
   if(res.order == 0)
     {
      g_orderNextTry = g_nowMsc + V14_OPEN_RETRY_MS;   // unknown ticket: found later as an extra order and deleted
      return true;
     }
   g_limitTicket  = res.order;
   g_limitDir     = dir;
   g_limitPrice   = price;
   g_limitGoneMsc = 0;
   return true;
  }

bool ModifyLimit(const double price)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action    = TRADE_ACTION_MODIFY;
   req.order     = g_limitTicket;
   req.symbol    = _Symbol;
   req.price     = price;
   req.type_time = g_orderTime;
   if(!SendRequest(req, res, StringFormat("move the %s LIMIT to %s", DirName(g_limitDir), PriceText(price))))
      return false;
   g_limitPrice = price;
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
   req.deviation    = V14_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = "V14 " + tag;
   req.type_filling = g_filling;
   return SendRequest(req, res, StringFormat("close #%I64u %s (%s)", ticket, RoleName(g_pos[i].role), tag));
  }

//+------------------------------------------------------------------+
//| The limit order                                                  |
//+------------------------------------------------------------------+
//--- step 1: is the limit order still waiting? (when it fills, Sync finds its trade)
void SyncLimit()
  {
   if(g_limitTicket == 0)
      return;
   if(OrderSelect(g_limitTicket))
     {
      g_limitPrice   = OrderGetDouble(ORDER_PRICE_OPEN);
      g_limitGoneMsc = 0;
      return;
     }
   if(HistoryOrderSelect(g_limitTicket))
     {
      ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(g_limitTicket, ORDER_STATE);
      if(state == ORDER_STATE_CANCELED || state == ORDER_STATE_EXPIRED || state == ORDER_STATE_REJECTED)
        {
         ClearLimit();                    // removed by the server (e.g. a day order at the end of the day)
         return;
        }
     }
   //--- filled but its trade is not shown yet, or the order itself is not shown yet: wait (at most 60 s)
   if(g_limitGoneMsc == 0)
      g_limitGoneMsc = g_nowMsc;
   else if(g_nowMsc - g_limitGoneMsc > V14_MISSING_MS)
     {
      V14Log(StringFormat("limit order #%I64u is neither waiting nor confirmed after 60 s - no longer tracked", g_limitTicket));
      ClearLimit();
     }
  }

bool DeleteLimit()
  {
   if(g_limitTicket == 0)
      return true;
   if(g_nowMsc < g_orderNextTry)
      return false;
   if(DeleteOrder(g_limitTicket))
     {
      ClearLimit();
      return true;
     }
   g_orderNextTry = g_nowMsc + V14_CLOSE_RETRY_MS;
   return false;
  }

//--- the bot's pending orders other than its limit order (e.g. after a restart) are deleted.
//--- Returns true while there are any.
bool DeleteStrays()
  {
   bool found = false;
   for(int k = OrdersTotal() - 1; k >= 0; k--)
     {
      ulong ticket = OrderGetTicket(k);
      if(ticket == 0 || ticket == g_limitTicket)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY || type == ORDER_TYPE_SELL)
         continue;                        // a market order on its way, not a pending order
      found = true;
      if(g_nowMsc >= g_orderNextTry && !DeleteOrder(ticket))
         g_orderNextTry = g_nowMsc + V14_CLOSE_RETRY_MS;
     }
   return found;
  }

//--- a BUY LIMIT must be below the ask, a SELL LIMIT above the bid (and the broker's minimum distance away)
bool LimitPriceValid(const int dir, const double price)
  {
   if(price <= 0.0)
      return false;
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if(dir > 0)
      return (price <= g_tick.ask - minDist - g_priceEps);
   return (price >= g_tick.bid + minDist + g_priceEps);
  }

//+------------------------------------------------------------------+
//| P1: margin for the whole basket, by the broker's hedge rule      |
//+------------------------------------------------------------------+
//--- margin of one order in the account currency (negative = cannot be calculated)
double MarginOf(const int dir, const double lots, const double price)
  {
   if(lots <= V14_EPS)
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

//--- the most margin a basket of trade 1 in 'dir' can need with 'maxTrades' trades (negative = unknown)
double BasketMargin(const int dir, const int maxTrades)
  {
   double pd   = (dir > 0 ? g_tick.ask : g_tick.bid);   // trade 1 and trade 3
   double po   = (dir > 0 ? g_tick.bid : g_tick.ask);   // the hedge
   double legD = InpLots + (maxTrades >= 3 ? g_lotT3 : 0.0);
   double legO = (maxTrades >= 2 ? g_lotHedge : 0.0);
   if(legO <= V14_EPS)
      return MarginOf(dir, legD, pd);
   if(SymbolInfoInteger(_Symbol, SYMBOL_MARGIN_HEDGED_USE_LEG) != 0)
     {
      double mD = MarginOf(dir, legD, pd);
      double mO = MarginOf(-dir, legO, po);
      if(mD < 0.0 || mO < 0.0)
         return -1.0;
      return MathMax(mD, mO);             // the bigger side only
     }
   //--- uncovered volume at the normal rate + covered volume at the broker's hedged rate
   bool   bigD = (legD >= legO);
   double unc  = MathAbs(legD - legO);
   double cov  = MathMin(legD, legO);
   double mUnc = (bigD ? MarginOf(dir, unc, pd) : MarginOf(-dir, unc, po));
   double mCov = MarginOf(dir, cov, pd);
   if(mUnc < 0.0 || mCov < 0.0)
      return -1.0;
   return mUnc + HedgedShare() * mCov;
  }

//--- P1: free margin must cover the whole basket x 1.5 before trade 1
bool MarginOk(const int dir)
  {
   double need  = BasketMargin(dir, InpMaxTrades);
   double freeM = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   bool   ok    = (need >= 0.0 && freeM >= need * V14_MARGIN_SAFETY);
   if(!ok && !g_marginLow)
     {
      if(need < 0.0)
         V14Log("the margin for the basket cannot be calculated now - no new basket until it can");
      else
         V14Log(StringFormat("not enough free margin for the whole basket: it needs %s x %.1f = %s, free margin is %s - no new basket until there is enough",
                             Amount(need), V14_MARGIN_SAFETY, Amount(need * V14_MARGIN_SAFETY), Amount(freeM)));
     }
   if(ok && g_marginLow)
      V14Log(StringFormat("free margin is enough again: %s free for %s x %.1f", Amount(freeM), Amount(need), V14_MARGIN_SAFETY));
   g_marginLow = !ok;
   return ok;
  }

void PrintMarginInfo()
  {
   string rule = (SymbolInfoInteger(_Symbol, SYMBOL_MARGIN_HEDGED_USE_LEG) != 0 ? "bigger side only" :
                  StringFormat("covered volume at %.0f%% of the normal margin", HedgedShare() * 100.0));
   V14Log(StringFormat("margin for a whole basket now: 1 trade %s | 2 trades %s | 3 trades %s | broker hedge rule: %s | free margin %s | trade 1 needs free margin of the basket x %.1f",
                       Amount(BasketMargin(1, 1)), Amount(BasketMargin(1, 2)), Amount(BasketMargin(1, 3)), rule,
                       Amount(AccountInfoDouble(ACCOUNT_MARGIN_FREE)), V14_MARGIN_SAFETY));
  }

//--- P2: no new trade 1 while the spread is above InpMaxSpread
bool SpreadOk()
  {
   return (InpMaxSpread <= 0.0 || g_tick.ask - g_tick.bid <= InpMaxSpread + g_priceEps);
  }

//+------------------------------------------------------------------+
//| P3: news window (no new trade 1; open baskets carry on)          |
//+------------------------------------------------------------------+
//--- "HH:MM" -> minutes after midnight (-1 = not a valid time)
int MinutesOf(const string text)
  {
   string s = text;
   StringTrimLeft(s);
   StringTrimRight(s);
   string parts[];
   if(StringSplit(s, StringGetCharacter(":", 0), parts) != 2)
      return -1;
   int v[2] = {0, 0};
   for(int k = 0; k < 2; k++)
     {
      int n = StringLen(parts[k]);
      if(n < 1 || n > 2)
         return -1;
      for(int c = 0; c < n; c++)
        {
         ushort ch = StringGetCharacter(parts[k], c);
         if(ch < '0' || ch > '9')
            return -1;
        }
      v[k] = (int)StringToInteger(parts[k]);
     }
   if(v[0] > 23 || v[1] > 59)
      return -1;
   return v[0] * 60 + v[1];
  }

string ClockText(const int minutes)
  {
   return StringFormat("%02d:%02d", minutes / 60, minutes % 60);
  }

//--- is this tick inside the window? (server time of the tick, Monday to Friday)
bool NewsWindowNow()
  {
   if(!InpNewsFilter)
      return false;
   MqlDateTime dt;
   TimeToStruct((datetime)(g_nowMsc / 1000), dt);
   if(dt.day_of_week < 1 || dt.day_of_week > 5)
      return false;
   int m = dt.hour * 60 + dt.min;
   return (m >= g_newsStart && m < g_newsEnd);
  }

//--- every tick; one journal line when a window starts. A limit order that the very first tick of the
//--- window fills, before the bot sees that tick, is a normal trade 1 (the tester fills orders first).
void UpdateNewsWindow()
  {
   bool now = NewsWindowNow();
   if(now && !g_inNews)
      V14Log(StringFormat("news window %s-%s: no new trade 1 until %s%s", ClockText(g_newsStart), ClockText(g_newsEnd), ClockText(g_newsEnd),
                          (g_basket ? " (the open basket carries on)" : (g_limitTicket != 0 ? " (the waiting limit order is deleted)" : ""))));
   g_inNews = now;
  }

//+------------------------------------------------------------------+
//| Signal (closed bars only)                                        |
//+------------------------------------------------------------------+
double Buf(const int handle, const int buffer, const int shift)
  {
   double b[];
   if(CopyBuffer(handle, buffer, shift, 1, b) != 1)
      return EMPTY_VALUE;
   return b[0];
  }

double CloseAt(const ENUM_TIMEFRAMES tf, const int shift)
  {
   double c[];
   if(CopyClose(_Symbol, tf, shift, 1, c) != 1)
      return EMPTY_VALUE;
   return c[0];
  }

//--- step 7: read the signal once per new entry bar. False = the data is not ready (tried again next tick).
bool ReadSignal()
  {
   double fast  = Buf(g_hFast, 0, 1);
   double slow  = Buf(g_hSlow, 0, 1);
   double adx   = Buf(g_hAdx, 0, 1);      // buffer 0 = ADX main line
   double ema   = Buf(g_hPull, 0, 1);
   double lastC = CloseAt(InpEntryTF, 1);
   double rsi   = Buf(g_hRsi, 0, 1);
   if(fast == EMPTY_VALUE || slow == EMPTY_VALUE || adx == EMPTY_VALUE || ema == EMPTY_VALUE ||
      lastC == EMPTY_VALUE || rsi == EMPTY_VALUE)
      return false;
   int  trend  = (fast > slow ? 1 : (fast < slow ? -1 : 0));
   bool moving = (InpAdxMin <= 0.0 || adx >= InpAdxMin);
   bool rsiBuy = (rsi < InpRsiMax);              // not exhausted for a buy
   bool rsiSel = (rsi > 100.0 - InpRsiMax);      // not exhausted for a sell
   g_sigDir      = 0;
   g_sigPrice    = 0.0;
   g_sigArmed    = false;
   g_marginState = 0;                     // P1 is checked again before the next trade 1
   if(InpEntryMode == V14_ENTRY_LIMIT)
     {
      //--- mode 1: the limit waits at the entry EMA while the last bar closed on the trend's side of it
      if(moving && ((trend > 0 && lastC > ema && rsiBuy) || (trend < 0 && lastC < ema && rsiSel)))
        {
         g_sigDir   = trend;
         g_sigPrice = NormalizePrice(ema);
        }
      return true;
     }
   //--- mode 2: the first bar that closes back beyond the entry EMA after a pullback, with RSI on the trend's side of 50
   if(g_pullBuy && lastC > ema && rsi > 50.0)
     {
      g_pullBuy = false;
      if(moving && trend > 0 && rsiBuy)
         g_sigDir = 1;
     }
   else if(g_pullSell && lastC < ema && rsi < 50.0)
     {
      g_pullSell = false;
      if(moving && trend < 0 && rsiSel)
         g_sigDir = -1;
     }
   if(lastC < ema)
      g_pullBuy = true;
   if(lastC > ema)
      g_pullSell = true;
   g_sigArmed = (g_sigDir != 0);
   return true;
  }

//+------------------------------------------------------------------+
//| Baskets                                                          |
//+------------------------------------------------------------------+
void FinishBasket()
  {
   string how = "";
   if(g_endTag == "HV")
     {
      how = "trade 1 harvested";
      g_sumHV++;
     }
   else if(g_endTag == "BT")
     {
      how = (g_t3Done ? "basket target with trade 3" : "basket target with the hedge");
      if(g_t3Done)
         g_sumBT3++;
      else
         g_sumBT2++;
     }
   else if(g_endTag == "HS")
     {
      how = StringFormat("hard stop at %s", Money(g_hsValue));
      g_sumHS++;
     }
   else if(g_endTag == "HF")
     {
      how = "the hedge or trade 3 could not open";
      g_sumHF++;
     }
   else
     {
      how = "closed outside the bot";
      g_sumOther++;
     }
   g_sumBaskets++;
   g_sumNet += g_bNet;
   V14Log(StringFormat("BASKET #%d %s: %s | result %s | %d trades opened, at most %d open at once | %s -> %s",
                       g_bNo, DirName(g_bDir), how, Money(g_bNet), g_bTrades, g_bMaxOpen, TimeText(g_bStart), TimeText(TimeCurrent())));
   g_basket      = false;
   g_bDir        = 0;
   g_bNet        = 0.0;
   g_hedged      = false;
   g_t3Done      = false;
   g_addFails    = 0;
   g_endTag      = "";
   g_hsValue     = 0.0;
   g_marginState = 0;                     // the account has changed: P1 is checked again before the next trade 1
   g_sigDir      = 0;                     // the next trade 1 needs the signal of a new bar
   g_sigPrice    = 0.0;
   g_sigArmed    = false;
  }

void CheckBasketEnd()
  {
   if(g_basket && !g_closing && g_posCount == 0 && g_expectRole == 0)
      FinishBasket();
  }

//--- step 2: close every trade and delete the limit order; when all is gone, the basket ends
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
      if(g_limitTicket != 0)
        {
         if(DeleteOrder(g_limitTicket))
            ClearLimit();
         else
            failed = true;
        }
      if(failed)
         g_closeNextTry = g_nowMsc + V14_CLOSE_RETRY_MS;
      Sync();
      SyncLimit();
     }
   if(DeleteStrays() || g_posCount > 0 || g_limitTicket != 0)
      return;                             // not all gone yet
   g_closing = false;
   if(g_basket)
      FinishBasket();
   g_closeTag = "";
  }

void BeginCloseAll(const string tag)
  {
   g_closing      = true;
   g_closeTag     = tag;
   g_closeNextTry = 0;
   if(g_basket)
     {
      g_endTag  = tag;
      g_hsValue = BasketNet();
     }
   ServiceClosing();
  }

//+------------------------------------------------------------------+
//| Steps 3-6: the open basket                                       |
//+------------------------------------------------------------------+
//--- step 4a: trade 1 alone closes at InpHarvestNet net
void Harvest()
  {
   if(g_endTag != "" || g_nowMsc < g_closeNextTry || OpenCount() != 1)
      return;
   int i = FindRole(V14_ROLE_T1);
   if(i < 0 || !g_pos[i].entryKnown || TradeNet(i) < InpHarvestNet - V14_EPS)
      return;
   if(!ClosePosition(i, "HV"))
     {
      g_closeNextTry = g_nowMsc + V14_CLOSE_RETRY_MS;
      return;
     }
   g_endTag = "HV";
   Sync();
   CheckBasketEnd();
  }

//--- steps 3-4: hard stop, then harvest (before the hedge) or basket target (after it).
//--- True when all trades are being closed.
bool CheckExits()
  {
   if(OpenCount() == 0)
      return false;
   double net = BasketNet();
   if(net <= -InpHardStop + V14_EPS)
     {
      BeginCloseAll("HS");
      return true;
     }
   if(!g_hedged)
     {
      Harvest();
      return false;
     }
   if(AllEntriesKnown() && net >= InpBasketTarget - V14_EPS)
     {
      BeginCloseAll("BT");
      return true;
     }
   return false;
  }

//--- P1: a hedge or trade 3 that fails 3 times closes the basket (a losing trade is never left without its hedge)
void AddFailed(const string what)
  {
   g_addFails++;
   if(g_addFails >= V14_ADD_MAX_FAILS)
     {
      V14Log(StringFormat("the %s could not open %d times - all trades of basket #%d are closed", what, g_addFails, g_bNo));
      BeginCloseAll("HF");
      return;
     }
   g_addNextTry = g_nowMsc + V14_ADD_RETRY_MS;
  }

//--- step 5: gold InpHedgeDistance against trade 1 -> the hedge opens the other way
void Hedge()
  {
   if(!g_basket || g_hedged || g_endTag != "" || InpMaxTrades < 2 || g_nowMsc < g_addNextTry)
      return;
   int i = FindRole(V14_ROLE_T1);
   if(i < 0)
      return;
   double t1Price = g_pos[i].openPrice;
   int    dir     = g_pos[i].dir;
   bool   hit     = (dir > 0 ? g_tick.bid <= t1Price - InpHedgeDistance + g_priceEps
                             : g_tick.ask >= t1Price + InpHedgeDistance - g_priceEps);
   if(!hit)
      return;
   if(OpenTrade(-dir, g_lotHedge, V14_ROLE_HEDGE))
     {
      g_hedged   = true;
      g_addFails = 0;
      return;
     }
   AddFailed("hedge");
  }

//--- step 6: after the hedge, gold back at trade 1's price -> trade 3 opens the same way as trade 1 (once)
void Trade3()
  {
   if(!g_basket || !g_hedged || g_t3Done || g_endTag != "" || InpMaxTrades < 3 || g_nowMsc < g_addNextTry)
      return;
   int i = FindRole(V14_ROLE_T1);
   if(i < 0 || FindRole(V14_ROLE_HEDGE) < 0)
      return;
   double t1Price = g_pos[i].openPrice;
   int    dir     = g_pos[i].dir;
   bool   hit     = (dir > 0 ? g_tick.ask >= t1Price - g_priceEps : g_tick.bid <= t1Price + g_priceEps);
   if(!hit)
      return;
   if(OpenTrade(dir, g_lotT3, V14_ROLE_T3))
     {
      g_t3Done   = true;
      g_addFails = 0;
      return;
     }
   AddFailed("trade 3");
  }

//+------------------------------------------------------------------+
//| Step 8: trade 1                                                  |
//+------------------------------------------------------------------+
void ManageEntry()
  {
   if(g_closing)
      return;
   if(DeleteStrays())
      return;                             // the bot's other pending orders are deleted first
   if(g_basket)
     {
      if(g_limitTicket != 0)
         DeleteLimit();                   // never a limit order while a basket is open
      return;
     }
   int  dir  = g_sigDir;
   bool want = (dir != 0);
   if(want && g_inNews)
      want = false;                       // P3: no new trade 1 in the news window; a waiting limit is deleted below
   if(want && !SpreadOk())
     {
      want = false;                       // P2: market mode waits; the limit is deleted until the next bar
      if(InpEntryMode == V14_ENTRY_LIMIT)
         g_sigDir = 0;
     }
   if(want && g_marginState == 0)
      g_marginState = (MarginOk(dir) ? 1 : -1);
   if(g_marginState < 0)
      want = false;
   //--- mode 2: trade 1 at market, once per signal
   if(InpEntryMode == V14_ENTRY_MARKET)
     {
      if(g_limitTicket != 0)
         DeleteLimit();
      if(!want || !g_sigArmed || g_nowMsc < g_openNextTry)
         return;
      if(OpenTrade(dir, InpLots, V14_ROLE_T1))
         g_sigArmed = false;
      else
         g_openNextTry = g_nowMsc + V14_OPEN_RETRY_MS;
      return;
     }
   //--- mode 1: one limit order at the entry EMA
   double price = g_sigPrice;
   if(g_limitTicket != 0)
     {
      if(!want || g_limitDir != dir)
        {
         DeleteLimit();
         return;
        }
      if(MathAbs(g_limitPrice - price) <= g_priceEps || g_nowMsc < g_orderNextTry)
         return;                          // the right limit order is waiting
      if(!LimitPriceValid(dir, price))
        {
         DeleteLimit();                   // gold is at or through the new price: placed again when it is allowed
         return;
        }
      if(!ModifyLimit(price))
         g_orderNextTry = g_nowMsc + V14_OPEN_RETRY_MS;
      return;
     }
   if(!want || g_nowMsc < g_orderNextTry || !LimitPriceValid(dir, price))
      return;
   if(!PlaceLimit(dir, price))
      g_orderNextTry = g_nowMsc + V14_OPEN_RETRY_MS;
  }

//+------------------------------------------------------------------+
//| Restart (live only; nothing to do in the Strategy Tester)        |
//+------------------------------------------------------------------+
//--- first tick: carry on with the bot's own open trades if they form a basket, else close them
void Adopt()
  {
   g_adopting = true;
   Sync();
   g_adopting = false;
   int n = g_posCount;
   if(n == 0)
      return;
   //--- in opening order: trade 1, the hedge, trade 3
   for(int a = 0; a < n - 1; a++)
      for(int b = a + 1; b < n; b++)
         if(g_pos[b].openMsc < g_pos[a].openMsc)
           {
            V14Pos t = g_pos[a];
            g_pos[a] = g_pos[b];
            g_pos[b] = t;
           }
   int  dir = g_pos[0].dir;
   bool ok  = (n <= 3 && n <= InpMaxTrades && OpenCount() == n);
   if(ok && n >= 2 && g_pos[1].dir != -dir)
      ok = false;
   if(ok && n == 3 && g_pos[2].dir != dir)
      ok = false;
   if(!ok)
     {
      V14Log(StringFormat("RESTART: %d open v14 trades do not form a basket - all are closed", n));
      g_closing      = true;
      g_closeTag     = "RS";
      g_closeNextTry = 0;
      return;
     }
   g_pos[0].role = V14_ROLE_T1;
   if(n >= 2)
      g_pos[1].role = V14_ROLE_HEDGE;
   if(n == 3)
      g_pos[2].role = V14_ROLE_T3;
   StartBasket(dir);
   g_bTrades  = n;
   g_bMaxOpen = n;
   g_hedged   = (n >= 2);
   g_t3Done   = (n == 3);
   V14Log(StringFormat("RESTART: carrying on with basket #%d: %d open trades, trade 1 %s at %s%s",
                       g_bNo, n, DirName(dir), PriceText(g_pos[0].openPrice), (g_hedged ? ", hedged" : "")));
  }

//+------------------------------------------------------------------+
//| Expert                                                           |
//+------------------------------------------------------------------+
void ResetState()
  {
   g_posCount     = 0;
   g_basket       = false;
   g_bNo          = 0;
   g_bDir         = 0;
   g_bStart       = 0;
   g_bNet         = 0.0;
   g_bTrades      = 0;
   g_bMaxOpen     = 0;
   g_hedged       = false;
   g_t3Done       = false;
   g_addFails     = 0;
   g_endTag       = "";
   g_hsValue      = 0.0;
   g_closing      = false;
   g_closeTag     = "";
   ClearLimit();
   g_expectRole   = 0;
   g_expectDir    = 0;
   g_expectMsc    = 0;
   g_lastBar      = 0;
   g_sigDir       = 0;
   g_sigPrice     = 0.0;
   g_sigArmed     = false;
   g_pullBuy      = false;
   g_pullSell     = false;
   g_marginState  = 0;
   g_marginLow    = false;
   g_inNews       = false;
   g_sumBaskets   = 0;
   g_sumHV        = 0;
   g_sumBT2       = 0;
   g_sumBT3       = 0;
   g_sumHS        = 0;
   g_sumHF        = 0;
   g_sumOther     = 0;
   g_sumNet       = 0.0;
   g_nowMsc       = 0;
   g_openNextTry  = 0;
   g_orderNextTry = 0;
   g_addNextTry   = 0;
   g_closeNextTry = 0;
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
   if(lots < vmin - V14_EPS || lots > vmax + V14_EPS)
      err = StringFormat("%s %.3f is outside the broker's range %.2f - %.2f", name, lots, vmin, vmax);
   else if(vstp > 0.0 && MathAbs(lots / vstp - MathRound(lots / vstp)) > 0.000001)
      err = StringFormat("%s %.3f is not a multiple of the volume step %.2f", name, lots, vstp);
  }

bool InputsOk()
  {
   string err = "";
   CheckLot("InpLots", InpLots, err);
   if(err == "" && (InpMaxTrades < 1 || InpMaxTrades > 3))
      err = "InpMaxTrades must be 1, 2 or 3";
   if(InpMaxTrades >= 2)
      CheckLot("the hedge lot (InpLots x InpHedgeMult)", InpLots * InpHedgeMult, err);
   if(InpMaxTrades >= 3)
      CheckLot("the trade 3 lot (InpLots x InpTrade3Mult)", InpLots * InpTrade3Mult, err);
   if(err == "" && InpHarvestNet <= 0.0)
      err = "InpHarvestNet must be above 0";
   if(err == "" && InpHedgeDistance <= 0.0)
      err = "InpHedgeDistance must be above 0";
   if(err == "" && InpHardStop <= 0.0)
      err = "InpHardStop must be above 0";
   if(err == "" && InpBasketTarget <= -InpHardStop)
      err = "InpBasketTarget must be above -InpHardStop";
   if(err == "" && InpEntryMode != V14_ENTRY_LIMIT && InpEntryMode != V14_ENTRY_MARKET)
      err = "InpEntryMode must be 1 (limit) or 2 (market)";
   if(err == "" && (InpEmaFast < 1 || InpEmaSlow <= InpEmaFast))
      err = "InpEmaFast must be at least 1 and InpEmaSlow above it";
   if(err == "" && (InpAdxPeriod < 1 || InpAdxMin < 0.0))
      err = "InpAdxPeriod must be at least 1 and InpAdxMin 0 or more";
   if(err == "" && InpPullEma < 1)
      err = "InpPullEma must be at least 1";
   if(err == "" && (InpRsiPeriod < 1 || InpRsiMax <= 50.0 || InpRsiMax > 100.0))
      err = "InpRsiPeriod must be at least 1, and InpRsiMax above 50 and at most 100";
   if(err == "" && InpMaxSpread < 0.0)
      err = "InpMaxSpread must be 0 or more";
   if(err == "" && InpNewsFilter)
     {
      g_newsStart = MinutesOf(InpNewsStart);
      g_newsEnd   = MinutesOf(InpNewsEnd);
      if(g_newsStart < 0 || g_newsEnd < 0)
         err = "InpNewsStart and InpNewsEnd must be server times like 15:00 (HH:MM)";
      else if(g_newsEnd <= g_newsStart)
         err = "InpNewsEnd must be later than InpNewsStart on the same day";
     }
   if(err == "" && InpMagic <= 0)
      err = "InpMagic must be above 0";
   if(err == "")
      return true;
   V14Log("input error: " + err);
   return false;
  }

void PrintSummary()
  {
   if(g_sumBaskets == 0 && !g_basket)
      return;
   double avg = (g_sumBaskets > 0 ? g_sumNet / g_sumBaskets : 0.0);
   double pct = (g_sumBaskets > 0 ? 100.0 * g_sumHV / g_sumBaskets : 0.0);
   V14Log(StringFormat("SUMMARY: %d baskets | trade 1 harvested alone %d (%.1f%%) | basket target with the hedge %d | with trade 3 %d | hard stops %d | hedge or trade 3 failed %d | other %d | total %s | average per basket %s%s",
                       g_sumBaskets, g_sumHV, pct, g_sumBT2, g_sumBT3, g_sumHS, g_sumHF, g_sumOther, Money(g_sumNet), Money(avg),
                       (g_basket ? " | 1 basket still open" : "")));
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
      V14Log("needs a hedging account (BUY and SELL trades open at the same time) - not started");
      return INIT_FAILED;
     }
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   g_priceEps  = g_tickSize * 0.5;
   g_filling   = DetectFilling();
   long expiry = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   g_orderTime = ((expiry & SYMBOL_EXPIRATION_GTC) == SYMBOL_EXPIRATION_GTC ? ORDER_TIME_GTC : ORDER_TIME_DAY);
   g_lotHedge  = NormalizeLots(InpLots * InpHedgeMult);
   g_lotT3     = NormalizeLots(InpLots * InpTrade3Mult);
   g_hFast     = iMA(_Symbol, InpTrendTF, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow     = iMA(_Symbol, InpTrendTF, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hAdx      = iADX(_Symbol, InpTrendTF, InpAdxPeriod);
   g_hPull     = iMA(_Symbol, InpEntryTF, InpPullEma, 0, MODE_EMA, PRICE_CLOSE);
   g_hRsi      = iRSI(_Symbol, InpEntryTF, InpRsiPeriod, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE || g_hAdx == INVALID_HANDLE ||
      g_hPull == INVALID_HANDLE || g_hRsi == INVALID_HANDLE)
     {
      V14Log("an indicator could not be created - not started");
      return INIT_FAILED;
     }
   string entry = (InpEntryMode == V14_ENTRY_LIMIT ?
                   StringFormat("limit order at the %s EMA %d", EnumToString(InpEntryTF), InpPullEma) :
                   StringFormat("market after a pullback to the %s EMA %d, RSI(%d) limits %.0f/%.0f",
                                EnumToString(InpEntryTF), InpPullEma, InpRsiPeriod, 100.0 - InpRsiMax, InpRsiMax));
   string adx   = (InpAdxMin > 0.0 ? StringFormat("ADX(%d) at least %.1f", InpAdxPeriod, InpAdxMin) : "ADX off");
   string hedge = (InpMaxTrades >= 2 ? StringFormat("hedge %s lots when gold is %.2f $ against trade 1", LotsText(g_lotHedge), InpHedgeDistance) : "no hedge");
   string t3    = (InpMaxTrades >= 3 ? StringFormat("trade 3 %s lots back at trade 1's price", LotsText(g_lotT3)) : "no trade 3");
   string spr   = (InpMaxSpread > 0.0 ? StringFormat("%.2f $", InpMaxSpread) : "off");
   string news  = (InpNewsFilter ? StringFormat("no new trade 1 %s-%s server time, Mon-Fri", ClockText(g_newsStart), ClockText(g_newsEnd)) : "off");
   V14Log(StringFormat("build %s on %s | trade 1 %s lots, %s | trend %s EMA %d/%d, %s | harvest %s | %s | %s | basket target %s | hard stop %s | max spread %s | news filter %s | magic %I64d%s",
                       V14_BUILD, _Symbol, LotsText(InpLots), entry, EnumToString(InpTrendTF), InpEmaFast, InpEmaSlow, adx,
                       Amount(InpHarvestNet), hedge, t3, Money(InpBasketTarget), Money(-InpHardStop), spr, news, InpMagic,
                       (g_isTester ? " | Strategy Tester" : "")));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintSummary();
   if(g_hFast != INVALID_HANDLE)
      IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE)
      IndicatorRelease(g_hSlow);
   if(g_hAdx != INVALID_HANDLE)
      IndicatorRelease(g_hAdx);
   if(g_hPull != INVALID_HANDLE)
      IndicatorRelease(g_hPull);
   if(g_hRsi != INVALID_HANDLE)
      IndicatorRelease(g_hRsi);
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
   if(g_expectRole != 0 && g_nowMsc - g_expectMsc > V14_MISSING_MS)
     {
      V14Log(StringFormat("the %s is not shown in the open trades after 60 s - no longer waited for", RoleName(g_expectRole)));
      g_expectRole = 0;
      g_expectDir  = 0;
     }
   //--- P3: is the news window on? (used in step 8)
   UpdateNewsWindow();
   //--- 1. update the trades and the limit order
   Sync();
   SyncLimit();
   CheckBasketEnd();
   //--- 2. closing all trades: keep closing; when all are closed, the basket ends
   if(g_closing)
     {
      ServiceClosing();
      if(g_closing)
         return;
     }
   //--- 3-6. the open basket: hard stop, harvest / basket target, hedge, trade 3
   if(g_basket && !CheckExits())
     {
      Hedge();
      Trade3();
     }
   if(g_closing)
      return;
   //--- 7. new entry bar: read the signal from the closed bars
   datetime bar = iTime(_Symbol, InpEntryTF, 0);
   if(bar > 0 && bar != g_lastBar && ReadSignal())
      g_lastBar = bar;
   //--- 8. no basket: trade 1
   ManageEntry();
  }
//+------------------------------------------------------------------+
