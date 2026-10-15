//+------------------------------------------------------------------+
//|                                 Gold_Market_Harvester_v13.00.mq5 |
//|  v13 Market Harvester - build 1.0                                |
//|  Design: docs/V13_PLAN.md rev 2 (approved: plan B, all defaults) |
//+------------------------------------------------------------------+
//  Market direction: a price turn of InpTurn on the bid price.
//    Going up  : the bot remembers the highest bid. A fall of InpTurn
//                below it means the market has turned down.
//    Going down: the bot remembers the lowest bid. A rise of InpTurn
//                above it means the market has turned up.
//    At the start it waits for the first move of InpTurn, up or down.
//  Trade 1   : opens at market in the market direction whenever no
//              trade is open.
//  Trades 2-4: one stop order, InpStep beyond the furthest trade
//              (BUY STOP above the highest BUY, SELL STOP below the
//              lowest SELL), while fewer than InpMaxTrades are open.
//  Harvest   : every trade closes on its own at InpHarvestNet net
//              (after its commission and swap). When none is left,
//              trade 1 opens again.
//  Turn      : the market direction changes -> close all trades and
//              delete the stop order; then trade 1 opens the new way.
//  Hard stop : the open trades together at -InpHardStop -> close all.
//
//  Order of checks on every tick:
//    1. update the trades, the stop order and the market direction
//    2. closing all trades (turn / hard stop): keep closing; when all
//       are closed, the move's result goes to the journal
//    3. hard stop   4. turn   5. harvest
//    6. no trade open -> trade 1 at market
//    7. the stop order for the next trade
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "13.00"
#property description "v13 Market Harvester: up to 4 trades, always in the market direction (price turn)."
#property description "Trade 1 at market, the next trades by one stop order further on; each trade harvests."
#property description "A turn closes all trades. Hard stop: the open trades together at -30.00. No other features."

#define V13_BUILD          "1.0"
#define V13_SLOTS          4
#define V13_MAX_POS        16
#define V13_EPS            0.000000001
#define V13_DEVIATION      20
#define V13_OPEN_RETRY_MS  5000
#define V13_CLOSE_RETRY_MS 1000
#define V13_MISSING_MS     60000
#define V13_CLOSE_NONE     0
#define V13_CLOSE_HARVEST  1
#define V13_CLOSE_ALL      2

//--- inputs: this is the complete list (docs/V13_PLAN.md, section 7)
input double InpLots       = 0.01;     // Lot size of every trade
input int    InpMaxTrades  = 4;        // Most trades open at once (1-4)
input double InpTurn       = 5.00;     // Market turn: gold moves this many $ back from its high or low
input double InpStep       = 3.00;     // Next trade: stop order this many $ beyond the furthest trade
input double InpHarvestNet = 4.00;     // Harvest a trade at this net (after its commission and swap)
input double InpHardStop   = 30.00;    // Hard stop: loss of the open trades together
input long   InpMagic      = 130001;   // Magic number

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
struct V13Pos
  {
   ulong  ticket;       // position ticket (to select and close it)
   ulong  id;           // position identifier (its deals in the history)
   int    slot;         // trade number 1-4 shown in the comment (0 = none)
   int    dir;          // +1 BUY, -1 SELL
   double openPrice;    // entry price
   double entryMoney;   // money of the opening deal: commission + fee (negative)
   bool   entryKnown;   // entryMoney has been read from the history
   bool   isOpen;       // seen among the open positions on this tick
   double profit;       // floating profit (account currency)
   double swapNow;      // swap so far
   int    closeWhy;     // why the bot closed it: V13_CLOSE_NONE / _HARVEST / _ALL
   long   missingMsc;   // when it was first missing from the open positions (0 = seen)
  };

V13Pos   g_pos[V13_MAX_POS];
int      g_posCount     = 0;

//--- market direction (price turn)
int      g_dir          = 0;       // +1 up (BUY), -1 down (SELL), 0 = waiting for the first move
double   g_ext          = 0.0;     // highest bid of the up-move / lowest bid of the down-move
double   g_lo           = 0.0;     // before the first move: lowest bid since the start
double   g_hi           = 0.0;     // before the first move: highest bid since the start
bool     g_priceSeen    = false;
double   g_turnExt      = 0.0;     // high / low where the last move ended (journal)
double   g_turnBid      = 0.0;     // bid at the last turn (journal)

//--- the current move: from trade 1 (start or after a turn) to the next turn
int      g_moveDir      = 0;       // direction of the bot's trades, 0 = no move yet
int      g_moveNo       = 0;
datetime g_moveStart    = 0;
double   g_moveNet      = 0.0;     // net of the move's closed trades
int      g_hvCount      = 0;       // harvests
double   g_hvNet        = 0.0;
int      g_caCount      = 0;       // trades closed by the turn or the hard stop
double   g_caNet        = 0.0;
int      g_opened       = 0;       // trades opened
int      g_maxOpen      = 0;       // most trades open at once

//--- closing all trades (turn or hard stop)
bool     g_closing      = false;
string   g_closeTag     = "";      // "TN" turn, "HS" hard stop
double   g_hsValue      = 0.0;     // the open trades together when the hard stop fired (journal)

//--- the stop order for the next trade (never more than one)
ulong    g_stopTicket   = 0;
int      g_stopSlot     = 0;
int      g_stopDir      = 0;
double   g_stopPrice    = 0.0;
long     g_stopGoneMsc  = 0;       // when it was first missing from the order list (0 = seen)

MqlTick  g_tick;
long     g_nowMsc       = 0;
long     g_openNextTry  = 0;       // no open / stop order before this time (after a failure)
long     g_closeNextTry = 0;       // no close / delete before this time (after a failure)
ENUM_ORDER_TYPE_FILLING g_filling   = ORDER_FILLING_FOK;
ENUM_ORDER_TYPE_TIME    g_orderTime = ORDER_TIME_GTC;
double   g_tickSize     = 0.01;
double   g_priceEps     = 0.005;
bool     g_isTester     = false;
bool     g_needAdopt    = true;
string   g_ccy          = "";

//+------------------------------------------------------------------+
//| Text                                                             |
//+------------------------------------------------------------------+
void V13Log(const string text)
  {
   Print("v13 ", text);
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

string TimeText(const datetime t)
  {
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
  }

string SlotComment(const int slot)
  {
   return StringFormat("V13 %d", slot);
  }

double NormalizePrice(const double p)
  {
   return NormalizeDouble(MathRound(p / g_tickSize) * g_tickSize, _Digits);
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
void ClearStop()
  {
   g_stopTicket  = 0;
   g_stopSlot    = 0;
   g_stopDir     = 0;
   g_stopPrice   = 0.0;
   g_stopGoneMsc = 0;
  }

int FindPos(const ulong id)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].id == id)
         return i;
   return -1;
  }

//--- a trade number is used by a tracked trade or by the waiting stop order
bool SlotUsed(const int slot)
  {
   if(g_stopTicket != 0 && g_stopSlot == slot)
      return true;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].slot == slot)
         return true;
   return false;
  }

//--- the lowest free trade number 1-4 (0 = none free)
int FreeSlot()
  {
   for(int s = 1; s <= V13_SLOTS; s++)
      if(!SlotUsed(s))
         return s;
   return 0;
  }

int OpenCount()
  {
   int n = 0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         n++;
   return n;
  }

int AddPos(const ulong ticket, const ulong id, const int slot, const int dir)
  {
   if(g_posCount >= V13_MAX_POS)
     {
      V13Log(StringFormat("too many v13 trades - #%I64u is not tracked", ticket));
      return -1;
     }
   int i = g_posCount;
   g_pos[i].ticket     = ticket;
   g_pos[i].id         = id;
   g_pos[i].slot       = slot;
   g_pos[i].dir        = dir;
   g_pos[i].openPrice  = 0.0;
   g_pos[i].entryMoney = 0.0;
   g_pos[i].entryKnown = false;
   g_pos[i].isOpen     = false;
   g_pos[i].profit     = 0.0;
   g_pos[i].swapNow    = 0.0;
   g_pos[i].closeWhy   = V13_CLOSE_NONE;
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

//--- trade number of a trade found in the terminal: from its comment "V13 n", else the first free one
int SlotFromComment(const string comment)
  {
   if(StringLen(comment) == 5 && StringSubstr(comment, 0, 4) == "V13 ")
     {
      int s = (int)StringToInteger(StringSubstr(comment, 4, 1));
      if(s >= 1 && s <= V13_SLOTS && !SlotUsed(s))
         return s;
     }
   return FreeSlot();
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

//--- a closed trade's result goes into the current move's figures (journal only)
void Book(const int i, const double net)
  {
   g_moveNet += net;
   if(g_pos[i].closeWhy == V13_CLOSE_HARVEST)
     {
      g_hvCount++;
      g_hvNet += net;
     }
   else if(g_pos[i].closeWhy == V13_CLOSE_ALL)
     {
      g_caCount++;
      g_caNet += net;
     }
  }

//--- step 1: read the open trades; a filled stop order shows up here as a new trade
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
         int slot = 0;
         if(g_stopTicket != 0 && id == g_stopTicket)
           {
            slot = g_stopSlot;            // the stop order has filled: this is its trade
            ClearStop();
            g_opened++;
           }
         else
           {
            slot = SlotFromComment(PositionGetString(POSITION_COMMENT));
            V13Log(StringFormat("found open trade #%I64u %s -> trade %d", ticket, DirName(dir), slot));
           }
         i = AddPos(ticket, id, slot, dir);
         if(i < 0)
            continue;
        }
      g_pos[i].ticket     = ticket;
      g_pos[i].isOpen     = true;
      g_pos[i].dir        = dir;
      g_pos[i].openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos[i].profit     = PositionGetDouble(POSITION_PROFIT);
      g_pos[i].swapNow    = PositionGetDouble(POSITION_SWAP);
      g_pos[i].missingMsc = 0;
     }
   int open = OpenCount();
   if(open > g_maxOpen)
      g_maxOpen = open;
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
         Book(i, net);
         RemovePos(i);
         continue;
        }
      //--- not open and not closed in the history yet: wait for the terminal to catch up
      if(g_pos[i].missingMsc == 0)
         g_pos[i].missingMsc = g_nowMsc;
      else if(g_nowMsc - g_pos[i].missingMsc > V13_MISSING_MS)
        {
         V13Log(StringFormat("trade #%I64u is neither open nor in the history after 60 s - no longer tracked", g_pos[i].ticket));
         RemovePos(i);
        }
     }
  }

//--- the trade's own net result if it closed now: profit + swap - both commissions (closing = opening)
double TradeNet(const int i)
  {
   return FloorCent(g_pos[i].profit) + g_pos[i].swapNow + 2.0 * g_pos[i].entryMoney;
  }

//--- the open trades together (for the hard stop)
double OpenTradesNet()
  {
   double v = 0.0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         v += TradeNet(i);
   return v;
  }

//+------------------------------------------------------------------+
//| Market direction: price turn of InpTurn (bid)                    |
//+------------------------------------------------------------------+
void UpdateDirection(const double bid)
  {
   if(g_dir == 0)
     {
      if(!g_priceSeen)
        {
         g_lo        = bid;
         g_hi        = bid;
         g_priceSeen = true;
        }
      if(bid < g_lo)
         g_lo = bid;
      if(bid > g_hi)
         g_hi = bid;
      if(bid >= g_lo + InpTurn - g_priceEps)
        {
         g_dir = 1;
         g_ext = bid;
         V13Log(StringFormat("FIRST MOVE: gold rose %.2f from its low %s -> the market direction is BUY", bid - g_lo, PriceText(g_lo)));
        }
      else if(bid <= g_hi - InpTurn + g_priceEps)
        {
         g_dir = -1;
         g_ext = bid;
         V13Log(StringFormat("FIRST MOVE: gold fell %.2f from its high %s -> the market direction is SELL", g_hi - bid, PriceText(g_hi)));
        }
      return;
     }
   if(g_dir > 0)
     {
      if(bid > g_ext)
         g_ext = bid;
      else if(bid <= g_ext - InpTurn + g_priceEps)
        {
         g_turnExt = g_ext;
         g_turnBid = bid;
         g_dir     = -1;
         g_ext     = bid;
        }
      return;
     }
   if(bid < g_ext)
      g_ext = bid;
   else if(bid >= g_ext + InpTurn - g_priceEps)
     {
      g_turnExt = g_ext;
      g_turnBid = bid;
      g_dir     = 1;
      g_ext     = bid;
     }
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
   V13Log(StringFormat("%s failed: retcode %u %s", what, res.retcode, res.comment));
   return false;
  }

//--- a trade at market (trade 1, or the next trade when gold is already beyond its stop level)
bool OpenTrade(const int dir, const int slot)
  {
   if(!SymbolInfoTick(_Symbol, g_tick))
      return false;
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = _Symbol;
   req.volume       = InpLots;
   req.type         = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   req.price        = (dir > 0 ? g_tick.ask : g_tick.bid);
   req.deviation    = V13_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = SlotComment(slot);
   req.type_filling = g_filling;
   if(!SendRequest(req, res, StringFormat("open %s (trade %d)", DirName(dir), slot)))
      return false;
   ulong id = 0;
   if(res.deal > 0 && HistoryDealSelect(res.deal))
      id = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
   if(id == 0)
      id = res.order;
   if(id > 0 && FindPos(id) < 0)
     {
      int i = AddPos(id, id, slot, dir);
      if(i >= 0)
        {
         g_pos[i].openPrice = (res.price > 0.0 ? res.price : req.price);
         ReadEntry(i);
        }
     }
   if(id == 0)
      g_openNextTry = g_nowMsc + V13_OPEN_RETRY_MS;   // unknown trade: let the terminal show it first
   g_opened++;
   Sync();
   return true;
  }

//--- the stop order for the next trade
bool PlaceStop(const int dir, const int slot, const double price)
  {
   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = InpLots;
   req.type         = (dir > 0 ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
   req.price        = price;
   req.magic        = (ulong)InpMagic;
   req.comment      = SlotComment(slot);
   req.type_filling = g_filling;
   req.type_time    = g_orderTime;
   if(!SendRequest(req, res, StringFormat("place %s STOP at %s (trade %d)", DirName(dir), PriceText(price), slot)))
      return false;
   if(res.order == 0)
     {
      g_openNextTry = g_nowMsc + V13_OPEN_RETRY_MS;   // unknown ticket: found later as an extra order and deleted
      return true;
     }
   g_stopTicket  = res.order;
   g_stopSlot    = slot;
   g_stopDir     = dir;
   g_stopPrice   = price;
   g_stopGoneMsc = 0;
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
   req.deviation    = V13_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = "V13 " + tag;
   req.type_filling = g_filling;
   return SendRequest(req, res, StringFormat("close #%I64u (%s)", ticket, tag));
  }

//+------------------------------------------------------------------+
//| The stop order                                                   |
//+------------------------------------------------------------------+
//--- step 1: is the stop order still waiting? (when it fills, Sync finds its trade)
void SyncStop()
  {
   if(g_stopTicket == 0)
      return;
   if(OrderSelect(g_stopTicket))
     {
      g_stopPrice   = OrderGetDouble(ORDER_PRICE_OPEN);
      g_stopGoneMsc = 0;
      return;
     }
   if(HistoryOrderSelect(g_stopTicket))
     {
      ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(g_stopTicket, ORDER_STATE);
      if(state == ORDER_STATE_CANCELED || state == ORDER_STATE_EXPIRED || state == ORDER_STATE_REJECTED)
        {
         ClearStop();                     // removed by the server (e.g. a day order at the end of the day)
         return;
        }
     }
   //--- filled but its trade is not shown yet, or the order itself is not shown yet: wait (at most 60 s)
   if(g_stopGoneMsc == 0)
      g_stopGoneMsc = g_nowMsc;
   else if(g_nowMsc - g_stopGoneMsc > V13_MISSING_MS)
     {
      V13Log(StringFormat("stop order #%I64u is neither waiting nor confirmed after 60 s - no longer tracked", g_stopTicket));
      ClearStop();
     }
  }

bool DeleteStop()
  {
   if(g_stopTicket == 0)
      return true;
   if(g_nowMsc < g_closeNextTry)
      return false;
   if(DeleteOrder(g_stopTicket))
     {
      ClearStop();
      return true;
     }
   g_closeNextTry = g_nowMsc + V13_CLOSE_RETRY_MS;
   return false;
  }

//--- the bot's pending orders other than its stop order (e.g. after a restart) are deleted.
//--- Returns true while there are any.
bool DeleteStrays()
  {
   bool found = false;
   for(int k = OrdersTotal() - 1; k >= 0; k--)
     {
      ulong ticket = OrderGetTicket(k);
      if(ticket == 0 || ticket == g_stopTicket)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol || OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      found = true;
      if(g_nowMsc >= g_closeNextTry && !DeleteOrder(ticket))
         g_closeNextTry = g_nowMsc + V13_CLOSE_RETRY_MS;
     }
   return found;
  }

//--- price of the next trade: InpStep beyond the furthest open trade of this move
bool NextLevel(double &level)
  {
   bool   any = false;
   double far = 0.0;
   for(int i = 0; i < g_posCount; i++)
     {
      if(!g_pos[i].isOpen || g_pos[i].dir != g_moveDir)
         continue;
      if(!any || (g_moveDir > 0 ? g_pos[i].openPrice > far : g_pos[i].openPrice < far))
         far = g_pos[i].openPrice;
      any = true;
     }
   if(!any)
      return false;
   level = NormalizePrice(far + InpStep * g_moveDir);
   return true;
  }

//+------------------------------------------------------------------+
//| Moves                                                            |
//+------------------------------------------------------------------+
void StartMove()
  {
   g_moveNo++;
   g_moveDir   = g_dir;
   g_moveStart = TimeCurrent();
   g_moveNet   = 0.0;
   g_hvCount   = 0;
   g_hvNet     = 0.0;
   g_caCount   = 0;
   g_caNet     = 0.0;
   g_opened    = 0;
   g_maxOpen   = 0;
  }

//--- all trades are closed after a turn or a hard stop: the move's result goes to the journal
void FinishMove()
  {
   if(g_moveNo == 0)
      V13Log("RESTART: the old trades are closed - waiting for the first move");
   else
     {
      bool   hs   = (g_closeTag == "HS");
      string head = "";
      if(hs)
         head = StringFormat("HARD STOP #%d: the open %s trades together reached %s", g_moveNo, DirName(g_moveDir), Money(g_hsValue));
      else
         head = StringFormat("TURN #%d: %s -> %s (%s %s, turn at %s)", g_moveNo, DirName(g_moveDir), DirName(g_dir),
                             (g_moveDir > 0 ? "high" : "low"), PriceText(g_turnExt), PriceText(g_turnBid));
      V13Log(StringFormat("%s | move result %s = %d harvests %s + %d closed at the %s %s | %d trades opened, at most %d open at once | %s -> %s",
                          head, Money(g_moveNet), g_hvCount, Money(g_hvNet), g_caCount, (hs ? "hard stop" : "turn"), Money(g_caNet),
                          g_opened, g_maxOpen, TimeText(g_moveStart), TimeText(TimeCurrent())));
     }
   g_closing  = false;
   g_closeTag = "";
   g_moveDir  = 0;
  }

//--- step 2: close every trade and delete the stop order; when all is gone, the move ends
void ServiceClosing()
  {
   if(g_nowMsc >= g_closeNextTry)
     {
      bool failed = false;
      for(int i = 0; i < g_posCount; i++)
        {
         if(!g_pos[i].isOpen)
            continue;
         if(ClosePosition(i, g_closeTag))
           {
            if(g_pos[i].closeWhy == V13_CLOSE_NONE)
               g_pos[i].closeWhy = V13_CLOSE_ALL;
           }
         else
            failed = true;
        }
      if(g_stopTicket != 0)
        {
         if(DeleteOrder(g_stopTicket))
            ClearStop();
         else
            failed = true;
        }
      if(failed)
         g_closeNextTry = g_nowMsc + V13_CLOSE_RETRY_MS;
      Sync();
      SyncStop();
     }
   if(DeleteStrays() || g_posCount > 0 || g_stopTicket != 0)
      return;                             // not all gone yet
   FinishMove();
  }

void BeginCloseAll(const string tag)
  {
   g_closing      = true;
   g_closeTag     = tag;
   g_closeNextTry = 0;
   if(tag == "HS")
      g_hsValue = OpenTradesNet();
   ServiceClosing();
  }

//+------------------------------------------------------------------+
//| Steps 5-7                                                        |
//+------------------------------------------------------------------+
//--- step 5: every trade whose own net has reached InpHarvestNet is closed
void Harvest()
  {
   if(g_nowMsc < g_closeNextTry)
      return;
   bool acted  = false;
   bool failed = false;
   for(int i = 0; i < g_posCount; i++)
     {
      if(!g_pos[i].isOpen || !g_pos[i].entryKnown || g_pos[i].closeWhy != V13_CLOSE_NONE)
         continue;
      if(TradeNet(i) < InpHarvestNet - V13_EPS)
         continue;
      acted = true;
      if(ClosePosition(i, "HV"))
         g_pos[i].closeWhy = V13_CLOSE_HARVEST;
      else
         failed = true;
     }
   if(failed)
      g_closeNextTry = g_nowMsc + V13_CLOSE_RETRY_MS;
   if(acted)
      Sync();
  }

//--- step 6: no trade is open -> trade 1 opens at market in the market direction
void OpenFirst()
  {
   if(g_posCount > 0 || g_dir == 0 || g_nowMsc < g_openNextTry)
      return;
   if(g_stopTicket != 0 && !DeleteStop())
      return;                             // a stop order without trades belongs to the old trades
   if(DeleteStrays())
      return;
   if(g_moveDir == 0)
      StartMove();
   if(!OpenTrade(g_moveDir, FreeSlot()))
      g_openNextTry = g_nowMsc + V13_OPEN_RETRY_MS;
  }

//--- step 7: one stop order InpStep beyond the furthest trade while fewer than InpMaxTrades are open
void ManageStop()
  {
   if(DeleteStrays())
      return;                             // the bot's other pending orders are deleted first
   if(g_posCount == 0 || g_posCount != OpenCount())
      return;                             // no trade, or a trade is not confirmed yet: wait
   double level = 0.0;
   bool   want  = (g_moveDir != 0 && g_dir == g_moveDir && g_posCount < InpMaxTrades && NextLevel(level));
   if(g_stopTicket != 0)
     {
      if(want && g_stopDir == g_moveDir && MathAbs(g_stopPrice - level) <= g_priceEps)
         return;                          // the right stop order is waiting
      DeleteStop();                       // wrong price, or no longer wanted
      return;
     }
   if(!want || g_nowMsc < g_openNextTry)
      return;
   int slot = FreeSlot();
   if(slot == 0)
      return;
   //--- gold is already at or beyond the level (a trade number became free late): the trade opens at market
   if((g_moveDir > 0 && g_tick.ask >= level - g_priceEps) || (g_moveDir < 0 && g_tick.bid <= level + g_priceEps))
     {
      if(!OpenTrade(g_moveDir, slot))
         g_openNextTry = g_nowMsc + V13_OPEN_RETRY_MS;
      return;
     }
   //--- closer than the broker allows for a stop order: wait until gold moves away or reaches the level
   double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((g_moveDir > 0 && level - g_tick.ask < minDist - g_priceEps) || (g_moveDir < 0 && g_tick.bid - level < minDist - g_priceEps))
      return;
   if(!PlaceStop(g_moveDir, slot, level))
      g_openNextTry = g_nowMsc + V13_OPEN_RETRY_MS;
  }

//+------------------------------------------------------------------+
//| Restart (live only; nothing to do in the Strategy Tester)        |
//+------------------------------------------------------------------+
//--- first tick: carry on with the bot's own open trades. Their direction is the market direction;
//--- the high (low) starts from the best of their entry prices and the price now.
void Adopt()
  {
   Sync();
   if(g_posCount == 0)
      return;
   int    dir   = g_pos[0].dir;
   double best  = g_pos[0].openPrice;
   bool   mixed = false;
   for(int i = 1; i < g_posCount; i++)
     {
      if(g_pos[i].dir != dir)
         mixed = true;
      else if(dir > 0 ? g_pos[i].openPrice > best : g_pos[i].openPrice < best)
         best = g_pos[i].openPrice;
     }
   if(mixed)
     {
      V13Log(StringFormat("RESTART: %d open trades in both directions - all are closed first", g_posCount));
      g_closing      = true;
      g_closeTag     = "TN";
      g_closeNextTry = 0;
      return;
     }
   g_dir       = dir;
   g_ext       = (dir > 0 ? MathMax(g_tick.bid, best) : MathMin(g_tick.bid, best));
   g_priceSeen = true;
   StartMove();
   V13Log(StringFormat("RESTART: carrying on with %d open %s trades | market direction %s, %s %s",
                       g_posCount, DirName(dir), DirName(dir), (dir > 0 ? "high" : "low"), PriceText(g_ext)));
  }

//+------------------------------------------------------------------+
//| Expert                                                           |
//+------------------------------------------------------------------+
void ResetState()
  {
   g_posCount     = 0;
   g_dir          = 0;
   g_ext          = 0.0;
   g_lo           = 0.0;
   g_hi           = 0.0;
   g_priceSeen    = false;
   g_turnExt      = 0.0;
   g_turnBid      = 0.0;
   g_moveDir      = 0;
   g_moveNo       = 0;
   g_moveStart    = 0;
   g_moveNet      = 0.0;
   g_hvCount      = 0;
   g_hvNet        = 0.0;
   g_caCount      = 0;
   g_caNet        = 0.0;
   g_opened       = 0;
   g_maxOpen      = 0;
   g_closing      = false;
   g_closeTag     = "";
   g_hsValue      = 0.0;
   ClearStop();
   g_nowMsc       = 0;
   g_openNextTry  = 0;
   g_closeNextTry = 0;
   g_needAdopt    = true;
   ZeroMemory(g_tick);
  }

bool InputsOk()
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double vstp = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   string err  = "";
   if(InpLots < vmin - V13_EPS || InpLots > vmax + V13_EPS)
      err = StringFormat("InpLots %.2f is outside the broker's range %.2f - %.2f", InpLots, vmin, vmax);
   else if(vstp > 0.0 && MathAbs(InpLots / vstp - MathRound(InpLots / vstp)) > 0.000001)
      err = StringFormat("InpLots %.2f is not a multiple of the volume step %.2f", InpLots, vstp);
   else if(InpMaxTrades < 1 || InpMaxTrades > V13_SLOTS)
      err = "InpMaxTrades must be 1 to 4";
   else if(InpTurn <= 0.0)
      err = "InpTurn must be above 0";
   else if(InpStep <= 0.0)
      err = "InpStep must be above 0";
   else if(InpHarvestNet <= 0.0)
      err = "InpHarvestNet must be above 0";
   else if(InpHardStop <= 0.0)
      err = "InpHardStop must be above 0";
   else if(InpMagic <= 0)
      err = "InpMagic must be above 0";
   if(err == "")
      return true;
   V13Log("input error: " + err);
   return false;
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
      V13Log("needs a hedging account (every trade stays separate) - not started");
      return INIT_FAILED;
     }
   g_tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_tickSize <= 0.0)
      g_tickSize = _Point;
   g_priceEps  = g_tickSize * 0.5;
   g_filling   = DetectFilling();
   long expiry = SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   g_orderTime = ((expiry & SYMBOL_EXPIRATION_GTC) == SYMBOL_EXPIRATION_GTC ? ORDER_TIME_GTC : ORDER_TIME_DAY);
   V13Log(StringFormat("build %s on %s: lots %.2f | up to %d trades: trade 1 at market, the next one by a stop order %.2f beyond the furthest trade | harvest each trade at %s net | market turn %.2f | hard stop: open trades together at %s | magic %I64d%s",
                       V13_BUILD, _Symbol, InpLots, InpMaxTrades, InpStep, Amount(InpHarvestNet), InpTurn, Money(-InpHardStop),
                       InpMagic, (g_isTester ? " | Strategy Tester" : "")));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
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
     }
   //--- 1. update the trades, the stop order and the market direction
   Sync();
   SyncStop();
   UpdateDirection(g_tick.bid);
   //--- 2. closing all trades (turn or hard stop): keep closing; when all is closed, the move ends
   if(g_closing)
     {
      ServiceClosing();
      if(g_closing)
         return;
     }
   //--- 3. hard stop: the open trades together
   if(OpenCount() > 0 && OpenTradesNet() <= -InpHardStop + V13_EPS)
     {
      BeginCloseAll("HS");
      if(g_closing)
         return;
     }
   //--- 4. turn: the market direction is against the trades of this move
   if(g_moveDir != 0 && g_dir != 0 && g_dir != g_moveDir)
     {
      BeginCloseAll("TN");
      if(g_closing)
         return;
     }
   //--- 5. harvest
   Harvest();
   //--- 6. no trade open: trade 1 at market in the market direction
   OpenFirst();
   //--- 7. the stop order for the next trade
   ManageStop();
  }
//+------------------------------------------------------------------+
