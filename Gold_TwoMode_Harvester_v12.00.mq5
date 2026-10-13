//+------------------------------------------------------------------+
//|                                Gold_TwoMode_Harvester_v12.00.mq5 |
//|  v12 Two-Mode Harvester - build 1.0                              |
//|  Design: docs/V12_PLAN.md (approved with all defaults)           |
//+------------------------------------------------------------------+
//  Three slots, always refilled to the same shape:
//    BUY slot   - always BUY                        comment "V12 B"
//    SELL slot  - always SELL                       comment "V12 S"
//    third slot - the market direction when opened  comment "V12 T"
//  Every trade is closed (harvested) when its own net result reaches
//  InpHarvestNet and its slot is refilled at once. A losing trade is
//  never closed on its own.
//
//  R = banked: all money of this cycle's deals (profits, losses,
//      opening and closing commissions, swaps).
//  C = close-all value: floating profit + swap - closing commission
//      (estimated = the trade's opening commission) of every open trade.
//
//  Harvest Mode : runs until R >= InpCycleTarget.
//  Recovery Mode: P = R at the switch is protected, Fund F = R - P.
//                 When F + C >= 0: close every trade, confirm the basket
//                 is empty, start a new cycle (the cycle ends at >= P).
//  Hard stop    : R + C <= -InpHardStop closes every trade, in either
//                 mode, and is checked before anything else that trades.
//+------------------------------------------------------------------+
#property copyright   "matanostoamr"
#property link        "https://github.com/matanostoamr/v7"
#property version     "12.00"
#property description "v12 Two-Mode Harvester: BUY slot + SELL slot + third slot in the market direction."
#property description "Harvest Mode banks the first 5.00; Recovery Mode earns a fund that pays for closing the rest."
#property description "Hard stop: the whole cycle at -30.00. No other features."

#define V12_BUILD          "1.0"
#define V12_SLOT_BUY       0
#define V12_SLOT_SELL      1
#define V12_SLOT_THIRD     2
#define V12_SLOTS          3
#define V12_MAX_POS        16
#define V12_MODE_HARVEST   0
#define V12_MODE_RECOVERY  1
#define V12_EPS            0.000000001
#define V12_DEVIATION      20
#define V12_OPEN_RETRY_MS  5000
#define V12_CLOSE_RETRY_MS 1000
#define V12_MISSING_MS     60000

//--- inputs: this is the complete list (docs/V12_PLAN.md, section 8)
input double InpLots        = 0.01;     // Lot size (all three trades)
input double InpHarvestNet  = 0.50;     // Harvest a trade at this net (after its commission and swap)
input double InpCycleTarget = 5.00;     // Harvest Mode: bank this much, then Recovery Mode
input double InpHardStop    = 30.00;    // Hard stop: whole-cycle loss (banked + open, after costs)
input int    InpEmaFast     = 9;        // Third-trade direction: fast EMA (closed M5 bars)
input int    InpEmaSlow     = 21;       // Third-trade direction: slow EMA (closed M5 bars)
input long   InpMagic       = 120001;   // Magic number

//+------------------------------------------------------------------+
//| State                                                            |
//+------------------------------------------------------------------+
struct V12Pos
  {
   ulong  ticket;       // position ticket
   int    slot;         // V12_SLOT_BUY / V12_SLOT_SELL / V12_SLOT_THIRD, -1 = v12 trade without a slot
   int    dir;          // +1 BUY, -1 SELL
   double entryMoney;   // money of the opening deal: commission + fee (negative)
   bool   entryKnown;   // entryMoney has been read from the history
   bool   isOpen;       // seen among the open positions on this tick
   double profit;       // floating profit on this tick (account currency)
   double swapNow;      // swap so far
   long   missingMsc;   // when it was first missing from the open positions (0 = seen)
  };

V12Pos   g_pos[V12_MAX_POS];
int      g_posCount       = 0;

bool     g_inCycle        = false;   // a cycle is running
bool     g_closing        = false;   // the whole basket is being closed
string   g_closeTag       = "";      // "RC" recovery close, "HS" hard stop
int      g_mode           = V12_MODE_HARVEST;
double   g_closedNet      = 0.0;     // full net of this cycle's closed trades
double   g_P              = 0.0;     // protected amount (Recovery Mode)
int      g_cycleNo        = 0;
datetime g_cycleStart     = 0;
ulong    g_cycleFirstDeal = 0;       // first deal of this cycle (restart safety)
int      g_harvests       = 0;       // harvests in this cycle
int      g_opened         = 0;       // trades opened in this cycle
double   g_trigR          = 0.0;     // banked at the close-all trigger (journal)
double   g_trigC          = 0.0;     // close-all value at the trigger (journal)

MqlTick  g_tick;
long     g_nowMsc         = 0;
long     g_slotNextTry[V12_SLOTS];   // no open attempt for this slot before this time (after a failure)
long     g_closeNextTry   = 0;       // no close attempt before this time (after a failure)
ENUM_ORDER_TYPE_FILLING g_filling = ORDER_FILLING_FOK;
int      g_hFast          = INVALID_HANDLE;
int      g_hSlow          = INVALID_HANDLE;
bool     g_isTester       = false;
bool     g_needRestore    = false;
bool     g_dirty          = false;   // state changed: save it (live only)
string   g_ccy            = "";
string   g_gvPrefix       = "";

//+------------------------------------------------------------------+
//| Text                                                             |
//+------------------------------------------------------------------+
void V12Log(const string text)
  {
   Print("v12 ", text);
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

string SlotName(const int slot)
  {
   if(slot == V12_SLOT_BUY)
      return "BUY slot";
   if(slot == V12_SLOT_SELL)
      return "SELL slot";
   if(slot == V12_SLOT_THIRD)
      return "third slot";
   return "no slot";
  }

string SlotComment(const int slot)
  {
   if(slot == V12_SLOT_BUY)
      return "V12 B";
   if(slot == V12_SLOT_SELL)
      return "V12 S";
   return "V12 T";
  }

string ModeName(const int mode)
  {
   return (mode == V12_MODE_RECOVERY ? "Recovery Mode" : "Harvest Mode");
  }

string TimeText(const datetime t)
  {
   return TimeToString(t, TIME_DATE | TIME_SECONDS);
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
//| The v12 trades                                                   |
//+------------------------------------------------------------------+
int FindPos(const ulong ticket)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].ticket == ticket)
         return i;
   return -1;
  }

bool SlotTaken(const int slot)
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].slot == slot)
         return true;
   return false;
  }

int OpenCount()
  {
   int n = 0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         n++;
   return n;
  }

bool AllEntriesKnown()
  {
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen && !g_pos[i].entryKnown)
         return false;
   return true;
  }

int AddPos(const ulong ticket, const int slot, const int dir)
  {
   if(g_posCount >= V12_MAX_POS)
     {
      V12Log(StringFormat("too many v12 trades - #%I64u is not tracked", ticket));
      return -1;
     }
   int i = g_posCount;
   g_pos[i].ticket     = ticket;
   g_pos[i].slot       = slot;
   g_pos[i].dir        = dir;
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

//--- slot of a v12 trade found in the terminal (after a restart): from its comment, else from its direction
int SlotForFound(const string comment, const int dir)
  {
   int s = -1;
   if(comment == "V12 B" && dir > 0)
      s = V12_SLOT_BUY;
   else if(comment == "V12 S" && dir < 0)
      s = V12_SLOT_SELL;
   else if(comment == "V12 T")
      s = V12_SLOT_THIRD;
   if(s >= 0 && !SlotTaken(s))
      return s;
   if(dir > 0 && !SlotTaken(V12_SLOT_BUY))
      return V12_SLOT_BUY;
   if(dir < 0 && !SlotTaken(V12_SLOT_SELL))
      return V12_SLOT_SELL;
   if(!SlotTaken(V12_SLOT_THIRD))
      return V12_SLOT_THIRD;
   return -1;
  }

//--- money of the opening deal of trade i (its commission); it also gives the first deal of the cycle
void ReadEntry(const int i)
  {
   if(!HistorySelectByPosition((long)g_pos[i].ticket))
      return;
   double money = 0.0;
   ulong  first = 0;
   int    n     = HistoryDealsTotal();
   for(int k = 0; k < n; k++)
     {
      ulong deal = HistoryDealGetTicket(k);
      if(deal == 0 || (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN)
         continue;
      money += DealMoney(deal);
      if(first == 0 || deal < first)
         first = deal;
     }
   if(first == 0)
      return;
   g_pos[i].entryMoney = money;
   g_pos[i].entryKnown = true;
   if(g_cycleFirstDeal == 0 || first < g_cycleFirstDeal)
     {
      g_cycleFirstDeal = first;
      g_dirty          = true;
     }
  }

//--- true when the position is fully closed in the history; 'net' = the money of all its deals
bool ClosedResult(const ulong ticket, double &net)
  {
   net = 0.0;
   if(!HistorySelectByPosition((long)ticket))
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

//--- step 1 of every tick: read the open v12 trades; trades that have closed go into the banked money
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
      int dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? 1 : -1);
      int i   = FindPos(ticket);
      if(i < 0)
        {
         int slot = SlotForFound(PositionGetString(POSITION_COMMENT), dir);
         i = AddPos(ticket, slot, dir);
         if(i < 0)
            continue;
         V12Log(StringFormat("found open trade #%I64u %s -> %s", ticket, DirName(dir), SlotName(slot)));
        }
      g_pos[i].isOpen     = true;
      g_pos[i].dir        = dir;
      g_pos[i].profit     = PositionGetDouble(POSITION_PROFIT);
      g_pos[i].swapNow    = PositionGetDouble(POSITION_SWAP);
      g_pos[i].missingMsc = 0;
     }
   for(int i = g_posCount - 1; i >= 0; i--)
     {
      if(g_pos[i].isOpen)
        {
         if(!g_pos[i].entryKnown)
            ReadEntry(i);
         continue;
        }
      double net = 0.0;
      if(ClosedResult(g_pos[i].ticket, net))
        {
         g_closedNet += net;
         RemovePos(i);
         g_dirty = true;
         continue;
        }
      //--- not open and not closed in the history yet: wait for the terminal to catch up
      if(g_pos[i].missingMsc == 0)
         g_pos[i].missingMsc = g_nowMsc;
      else if(g_nowMsc - g_pos[i].missingMsc > V12_MISSING_MS)
        {
         V12Log(StringFormat("trade #%I64u is neither open nor in the history after 60 s - no longer tracked", g_pos[i].ticket));
         RemovePos(i);
        }
     }
  }

//--- R: everything this cycle has banked (closed trades in full + opening commission of the open ones)
double Banked()
  {
   double r = g_closedNet;
   for(int i = 0; i < g_posCount; i++)
      r += g_pos[i].entryMoney;
   return r;
  }

//--- what closing trade i now would give: profit + swap - closing commission (= its opening commission)
double CloseValue(const int i)
  {
   return FloorCent(g_pos[i].profit) + g_pos[i].swapNow + g_pos[i].entryMoney;
  }

//--- C: the close-all value of every open trade
double CloseAllValue()
  {
   double c = 0.0;
   for(int i = 0; i < g_posCount; i++)
      if(g_pos[i].isOpen)
         c += CloseValue(i);
   return c;
  }

//--- the trade's own net result if it closed now (both commissions and swap included)
double TradeNet(const int i)
  {
   return CloseValue(i) + g_pos[i].entryMoney;
  }

//+------------------------------------------------------------------+
//| Market direction for the third trade                             |
//+------------------------------------------------------------------+
//--- EMA fast above EMA slow on the last closed M5 bar -> BUY, otherwise SELL; 0 = not ready yet
int MarketDirection()
  {
   double fast[];
   double slow[];
   if(CopyBuffer(g_hFast, 0, 1, 1, fast) != 1 || CopyBuffer(g_hSlow, 0, 1, 1, slow) != 1)
      return 0;
   return (fast[0] > slow[0] ? 1 : -1);
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

bool SendDeal(MqlTradeRequest &req, MqlTradeResult &res, const string what)
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
   V12Log(StringFormat("%s failed: retcode %u %s", what, res.retcode, res.comment));
   return false;
  }

bool OpenSlot(const int slot, const int dir)
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
   req.deviation    = V12_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = SlotComment(slot);
   req.type_filling = g_filling;
   if(!SendDeal(req, res, StringFormat("open %s (%s)", DirName(dir), SlotName(slot))))
      return false;
   ulong posId = 0;
   if(res.deal > 0 && HistoryDealSelect(res.deal))
      posId = (ulong)HistoryDealGetInteger(res.deal, DEAL_POSITION_ID);
   if(posId == 0)
      posId = res.order;
   if(posId > 0 && FindPos(posId) < 0)
     {
      int i = AddPos(posId, slot, dir);
      if(i >= 0)
         ReadEntry(i);
     }
   if(posId == 0)
      g_slotNextTry[slot] = g_nowMsc + V12_OPEN_RETRY_MS;   // unknown ticket: let the terminal show it first
   g_opened++;
   g_dirty = true;
   return true;
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
   req.deviation    = V12_DEVIATION;
   req.magic        = (ulong)InpMagic;
   req.comment      = "V12 " + tag;
   req.type_filling = g_filling;
   return SendDeal(req, res, StringFormat("close #%I64u (%s)", ticket, tag));
  }

//+------------------------------------------------------------------+
//| Cycle                                                            |
//+------------------------------------------------------------------+
//--- step 7: refill every empty slot (BUY slot BUY, SELL slot SELL, third slot in the direction now)
void FillSlots()
  {
   for(int s = 0; s < V12_SLOTS; s++)
     {
      if(SlotTaken(s) || g_nowMsc < g_slotNextTry[s])
         continue;
      int dir = (s == V12_SLOT_BUY ? 1 : (s == V12_SLOT_SELL ? -1 : MarketDirection()));
      if(dir == 0)
         continue;                        // the EMAs are not ready yet
      if(!OpenSlot(s, dir))
         g_slotNextTry[s] = g_nowMsc + V12_OPEN_RETRY_MS;
     }
  }

//--- the basket is empty: open the BUY, SELL and third trades together
void StartCycle()
  {
   if(g_posCount > 0)
     {
      g_inCycle = true;                   // v12 trades are already there: carry on with them
      g_dirty   = true;
      return;
     }
   if(MarketDirection() == 0)
      return;                             // wait until the third trade has a direction
   g_cycleNo++;
   g_inCycle        = true;
   g_closing        = false;
   g_closeTag       = "";
   g_mode           = V12_MODE_HARVEST;
   g_closedNet      = 0.0;
   g_P              = 0.0;
   g_cycleStart     = TimeCurrent();
   g_cycleFirstDeal = 0;
   g_harvests       = 0;
   g_opened         = 0;
   g_trigR          = 0.0;
   g_trigC          = 0.0;
   for(int s = 0; s < V12_SLOTS; s++)
      g_slotNextTry[s] = 0;
   FillSlots();
   g_dirty = true;
  }

//--- step 5: harvest every trade whose own net has reached the target
void Harvest()
  {
   if(g_nowMsc < g_closeNextTry)
      return;
   bool acted  = false;
   bool failed = false;
   for(int i = 0; i < g_posCount; i++)
     {
      if(!g_pos[i].isOpen || !g_pos[i].entryKnown || TradeNet(i) < InpHarvestNet - V12_EPS)
         continue;
      acted = true;
      if(ClosePosition(i, "HV"))
         g_harvests++;
      else
         failed = true;
     }
   if(failed)
      g_closeNextTry = g_nowMsc + V12_CLOSE_RETRY_MS;
   if(acted)
      Sync();
  }

//--- step 6: Harvest Mode has banked its target -> Recovery Mode
void SwitchToRecovery(const double R, const double C)
  {
   g_mode  = V12_MODE_RECOVERY;
   g_P     = R;
   g_dirty = true;
   V12Log(StringFormat("CYCLE #%d RECOVERY MODE: banked %s is protected, the Recovery Fund starts at 0.00 | %d open trades, close-all value %s -> the fund must earn %s",
                       g_cycleNo, Money(R), OpenCount(), Money(C), Amount(MathMax(0.0, -C))));
  }

//--- step 4: the Recovery Fund (F = R - P) covers the close-all value
bool RecoveryFunded(const double R, const double C)
  {
   if(!AllEntriesKnown())
      return false;                       // every closing commission must be known first
   return ((R - g_P) + C >= -V12_EPS);
  }

void FinishCycle()
  {
   double result = g_closedNet;
   string why    = (g_closeTag == "HS" ? "hard stop" : "recovery close");
   string parts  = "";
   if(g_mode == V12_MODE_RECOVERY)
      parts = StringFormat("protected %s, fund %s, close-all value %s at the trigger",
                           Money(g_P), Money(g_trigR - g_P), Money(g_trigC));
   else
      parts = StringFormat("Harvest Mode: banked %s, close-all value %s at the trigger", Money(g_trigR), Money(g_trigC));
   V12Log(StringFormat("CYCLE #%d END - %s: result %s | %s | %d harvests, %d trades opened | %s -> %s",
                       g_cycleNo, why, Money(result), parts, g_harvests, g_opened, TimeText(g_cycleStart), TimeText(TimeCurrent())));
   g_inCycle        = false;
   g_closing        = false;
   g_closeTag       = "";
   g_mode           = V12_MODE_HARVEST;
   g_closedNet      = 0.0;
   g_P              = 0.0;
   g_cycleFirstDeal = 0;
   g_harvests       = 0;
   g_opened         = 0;
   g_dirty          = true;
  }

//--- step 2: no refills; close every trade; when the basket is empty, end the cycle and start a new one
void ServiceClosing()
  {
   if(OpenCount() > 0 && g_nowMsc >= g_closeNextTry)
     {
      bool failed = false;
      for(int i = 0; i < g_posCount; i++)
         if(g_pos[i].isOpen && !ClosePosition(i, g_closeTag))
            failed = true;
      if(failed)
         g_closeNextTry = g_nowMsc + V12_CLOSE_RETRY_MS;
      Sync();
     }
   if(g_posCount > 0)
      return;                             // not empty yet
   FinishCycle();
   StartCycle();
  }

void BeginCloseAll(const string tag, const double R, const double C)
  {
   g_closing      = true;
   g_closeTag     = tag;
   g_trigR        = R;
   g_trigC        = C;
   g_closeNextTry = 0;
   g_dirty        = true;
   ServiceClosing();
  }

//+------------------------------------------------------------------+
//| Restart safety (live only, not used in the Strategy Tester)      |
//+------------------------------------------------------------------+
string GvName(const string key)
  {
   return g_gvPrefix + key;
  }

bool GvGet(const string key, double &value)
  {
   string name = GvName(key);
   if(!GlobalVariableCheck(name))
      return false;
   return GlobalVariableGet(name, value);
  }

void SaveState()
  {
   if(g_isTester)
      return;
   bool ok = true;
   if(GlobalVariableSet(GvName("first"), (g_inCycle ? (double)g_cycleFirstDeal : 0.0)) == 0)
      ok = false;
   if(GlobalVariableSet(GvName("start"), (double)g_cycleStart) == 0)
      ok = false;
   if(GlobalVariableSet(GvName("cycle"), (double)g_cycleNo) == 0)
      ok = false;
   if(GlobalVariableSet(GvName("mode"), (double)g_mode) == 0)
      ok = false;
   if(GlobalVariableSet(GvName("P"), g_P) == 0)
      ok = false;
   if(GlobalVariableSet(GvName("closing"), (g_closing ? (g_closeTag == "HS" ? 2.0 : 1.0) : 0.0)) == 0)
      ok = false;
   GlobalVariablesFlush();
   if(!ok)
      V12Log("could not save the cycle state in the terminal");
  }

void SaveIfDirty()
  {
   if(!g_dirty)
      return;
   g_dirty = false;
   SaveState();
  }

//--- closed money of this cycle from the history: every deal of the cycle's v12 trades,
//--- minus the opening money of the trades that are still open (that part is counted with them)
double ClosedSinceFirstDeal()
  {
   if(g_cycleFirstDeal == 0)
      return 0.0;
   datetime from = 0;
   if(g_cycleStart > 60)
      from = g_cycleStart - 60;
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return 0.0;
   int   n    = HistoryDealsTotal();
   ulong ids[];
   int   nIds = 0;
   for(int k = 0; k < n; k++)
     {
      ulong deal = HistoryDealGetTicket(k);
      if(deal < g_cycleFirstDeal || HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;
      if((ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY) != DEAL_ENTRY_IN || HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
         continue;
      ArrayResize(ids, nIds + 1);
      ids[nIds] = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      nIds++;
     }
   double total = 0.0;
   for(int k = 0; k < n; k++)
     {
      ulong deal = HistoryDealGetTicket(k);
      if(deal < g_cycleFirstDeal)
         continue;
      ulong pos = (ulong)HistoryDealGetInteger(deal, DEAL_POSITION_ID);
      for(int q = 0; q < nIds; q++)
         if(ids[q] == pos)
           {
            total += DealMoney(deal);
            break;
           }
     }
   double openEntry = 0.0;
   for(int i = 0; i < g_posCount; i++)
      openEntry += g_pos[i].entryMoney;
   return total - openEntry;
  }

datetime OldestOpenTime()
  {
   datetime t = 0;
   for(int i = 0; i < g_posCount; i++)
      if(PositionSelectByTicket(g_pos[i].ticket))
        {
         datetime o = (datetime)PositionGetInteger(POSITION_TIME);
         if(t == 0 || o < t)
            t = o;
        }
   return t;
  }

//--- first tick after a (re)start: continue the saved cycle instead of opening a second basket
void Restore()
  {
   double v     = 0.0;
   bool   saved = (GvGet("first", v) && v > 0.5);
   double cyc   = 0.0;
   if(GvGet("cycle", cyc))
      g_cycleNo = (int)cyc;
   if(saved)
     {
      g_cycleFirstDeal = (ulong)v;
      g_cycleStart     = 0;
      if(GvGet("start", v))
         g_cycleStart = (datetime)(long)v;
      g_mode = ((GvGet("mode", v) && v > 0.5) ? V12_MODE_RECOVERY : V12_MODE_HARVEST);
      g_P    = (GvGet("P", v) ? v : 0.0);
      double cl = 0.0;
      if(GvGet("closing", cl) && cl > 0.5)
        {
         g_closing  = true;
         g_closeTag = (cl > 1.5 ? "HS" : "RC");
        }
     }
   Sync();                                // finds the open v12 trades (slots from their comments)
   if(!saved && g_posCount == 0)
      return;                             // nothing to continue: a new cycle starts
   if(!saved)
     {
      g_mode       = V12_MODE_HARVEST;
      g_P          = 0.0;
      g_cycleStart = OldestOpenTime();
      if(g_cycleNo < 1)
         g_cycleNo = 1;
      V12Log("RESTART: v12 trades are open but no saved cycle was found - they are treated as the current cycle, in Harvest Mode");
     }
   g_inCycle   = true;
   g_closedNet = ClosedSinceFirstDeal();
   g_dirty     = true;
   V12Log(StringFormat("RESTART: continuing cycle #%d in %s%s | banked %s%s | %d open trades",
                       g_cycleNo, ModeName(g_mode), (g_closing ? " (closing the basket)" : ""), Money(Banked()),
                       (g_mode == V12_MODE_RECOVERY ? ", protected " + Money(g_P) : ""), OpenCount()));
  }

//+------------------------------------------------------------------+
//| Expert                                                           |
//+------------------------------------------------------------------+
void ResetState()
  {
   g_posCount       = 0;
   g_inCycle        = false;
   g_closing        = false;
   g_closeTag       = "";
   g_mode           = V12_MODE_HARVEST;
   g_closedNet      = 0.0;
   g_P              = 0.0;
   g_cycleNo        = 0;
   g_cycleStart     = 0;
   g_cycleFirstDeal = 0;
   g_harvests       = 0;
   g_opened         = 0;
   g_trigR          = 0.0;
   g_trigC          = 0.0;
   g_nowMsc         = 0;
   g_closeNextTry   = 0;
   for(int s = 0; s < V12_SLOTS; s++)
      g_slotNextTry[s] = 0;
   g_needRestore    = false;
   g_dirty          = false;
   ZeroMemory(g_tick);
  }

bool InputsOk()
  {
   double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   string err  = "";
   if(InpLots < vmin - V12_EPS || InpLots > vmax + V12_EPS)
      err = StringFormat("InpLots %.2f is outside the broker's range %.2f - %.2f", InpLots, vmin, vmax);
   else if(step > 0.0 && MathAbs(InpLots / step - MathRound(InpLots / step)) > 0.000001)
      err = StringFormat("InpLots %.2f is not a multiple of the volume step %.2f", InpLots, step);
   else if(InpHarvestNet <= 0.0)
      err = "InpHarvestNet must be above 0";
   else if(InpCycleTarget <= 0.0)
      err = "InpCycleTarget must be above 0";
   else if(InpHardStop <= 0.0)
      err = "InpHardStop must be above 0";
   else if(InpEmaFast < 1 || InpEmaSlow < 1 || InpEmaFast >= InpEmaSlow)
      err = "InpEmaFast must be at least 1 and below InpEmaSlow";
   else if(InpMagic <= 0)
      err = "InpMagic must be above 0";
   if(err == "")
      return true;
   V12Log("input error: " + err);
   return false;
  }

int OnInit()
  {
   ResetState();
   g_isTester = (MQLInfoInteger(MQL_TESTER) != 0);
   g_ccy      = AccountInfoString(ACCOUNT_CURRENCY);
   g_gvPrefix = StringFormat("V12_%I64d_%s_", InpMagic, _Symbol);
   if(!InputsOk())
      return INIT_PARAMETERS_INCORRECT;
   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
     {
      V12Log("needs a hedging account (BUY and SELL open together) - not started");
      return INIT_FAILED;
     }
   g_hFast = iMA(_Symbol, PERIOD_M5, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hSlow = iMA(_Symbol, PERIOD_M5, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hFast == INVALID_HANDLE || g_hSlow == INVALID_HANDLE)
     {
      V12Log("could not create the EMA indicators - not started");
      return INIT_FAILED;
     }
   g_filling     = DetectFilling();
   g_needRestore = !g_isTester;
   V12Log(StringFormat("build %s on %s: lots %.2f | harvest each trade at %s net | Recovery Mode at %s banked | hard stop at %s | third trade: EMA %d/%d on closed M5 bars | magic %I64d%s",
                       V12_BUILD, _Symbol, InpLots, Amount(InpHarvestNet), Amount(InpCycleTarget), Money(-InpHardStop),
                       InpEmaFast, InpEmaSlow, InpMagic, (g_isTester ? " | Strategy Tester" : "")));
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   SaveState();
   if(g_hFast != INVALID_HANDLE)
      IndicatorRelease(g_hFast);
   if(g_hSlow != INVALID_HANDLE)
      IndicatorRelease(g_hSlow);
   g_hFast = INVALID_HANDLE;
   g_hSlow = INVALID_HANDLE;
  }

//--- the order of checks on every tick (docs/V12_PLAN.md, section 2)
void OnTick()
  {
   if(!SymbolInfoTick(_Symbol, g_tick) || g_tick.bid <= 0.0 || g_tick.ask <= 0.0)
      return;
   g_nowMsc = (g_tick.time_msc > 0 ? g_tick.time_msc : (long)TimeCurrent() * 1000);
   if(g_needRestore)
     {
      g_needRestore = false;
      Restore();
     }
   //--- 1. update R and C
   Sync();
   //--- 2. closing the basket: keep closing; when it is empty, end the cycle and start a new one
   if(g_closing)
     {
      ServiceClosing();
      SaveIfDirty();
      return;
     }
   if(!g_inCycle)
     {
      StartCycle();
      SaveIfDirty();
      return;
     }
   double R = Banked();
   double C = CloseAllValue();
   //--- 3. hard stop: the whole cycle (banked + open, after costs), in either mode
   if(R + C <= -InpHardStop + V12_EPS)
     {
      BeginCloseAll("HS", R, C);
      SaveIfDirty();
      return;
     }
   //--- 4. recovery close: the fund covers the close-all value
   if(g_mode == V12_MODE_RECOVERY && RecoveryFunded(R, C))
     {
      BeginCloseAll("RC", R, C);
      SaveIfDirty();
      return;
     }
   //--- 5. harvest
   Harvest();
   //--- 6. Harvest Mode has banked its target: switch, and check 4 again at once
   if(g_mode == V12_MODE_HARVEST)
     {
      R = Banked();
      if(R >= InpCycleTarget - V12_EPS)
        {
         C = CloseAllValue();
         SwitchToRecovery(R, C);
         if(RecoveryFunded(R, C))
           {
            BeginCloseAll("RC", R, C);
            SaveIfDirty();
            return;
           }
        }
     }
   //--- 7. refill the empty slots
   FillSlots();
   SaveIfDirty();
  }
//+------------------------------------------------------------------+
