//+------------------------------------------------------------------+
//|                               Gold_Bidirectional_Harvester_v7.00.mq5 |
//|                                  Copyright 2026, Antigravity AI  |
//|               Quantum Amortized Edition (Continuous Harvest Engine) |
//+------------------------------------------------------------------+
#property copyright   "Antigravity AI"
#property link        "https://antigravity.ai"
#property version     "7.00"
#property description "Gold Quantum Bidirectional Harvester v7.00"
#property description "Instant + Continuous 24/5 harvesting + Self-Liquidating Combined Hedge Basket"

#include <Trade\Trade.mqh>

#define GBH7_BUILD "7.00-quantum-amortized"

//+------------------------------------------------------------------+
//| INPUT PARAMETERS                                                 |
//+------------------------------------------------------------------+
input group "=== 1. HARVEST ENGINE (CONTINUOUS 24/5) ==="
input bool   InpInstantEntry          = true;    // Instant Trading (True = Trade Immediately, False = Pullback)
input double InpLotSize               = 0.01;    // Base harvest lot size
input double InpHarvestTarget         = 0.50;    // Harvest profit target per trade (£)
input int    InpPullbackPoints        = 35;      // Pullback spacing when InstantEntry=false (points)
input int    InpMaxSpread             = 50;      // Max spread allowed for entries (points, 50 for XAUGBP/XAUUSD)

input group "=== 2. COMBINED HEDGE RECOVERY ENGINE ==="
input double InpHedgeLotSize          = 0.02;    // Recovery hedge lot size (2x base)
input double InpHedgeTrigger          = -8.00;   // Deficit level to activate hedge (£)
input double InpHedgeSL               = 2.50;    // Hedge stop loss risk cap (£)
input double InpHedgeLockAt           = 1.50;    // Profit level to lock hedge to breakeven (£)
input double InpHedgeTrailDistance    = 2.00;    // Hedge trailing profit distance (£)
input double InpJointTarget           = 1.00;    // Combined basket exit target (£)
input bool   InpContinuousHarvesting  = true;    // NEVER stop harvesting winning side during recovery
input double InpAmortizePortion       = 0.50;    // Portion of harvest profits allocated to basket relief (0.50 = 50%)

input group "=== 3. CAPITAL SHIELD & SAFETY ==="
input double InpMaxDailyLoss          = 50.00;   // Daily Drawdown Limit (DDD) circuit breaker (£)
input double InpDisasterSL            = 0.00;    // Broker-side disaster SL (0 = Off, >0 = Money SL)
input ulong  InpSlippage              = 20;      // Max slippage deviation (points)

input group "=== 4. IDENTIFICATION ==="
input ulong  InpMagicBuy              = 70001;   // Magic Number - Base BUY
input ulong  InpMagicSell             = 70002;   // Magic Number - Base SELL
input ulong  InpMagicHedge            = 70003;   // Magic Number - Recovery HEDGE

//+------------------------------------------------------------------+
//| GLOBAL STATE & OBJECTS                                           |
//+------------------------------------------------------------------+
CTrade trade;

struct Book
{
   int      n_buy, n_sell, n_hedge;
   ulong    buy_ticket, sell_ticket, hedge_ticket;
   double   buy_pl, sell_pl, hedge_pl;
   double   buy_open, sell_open, hedge_open;
   double   buy_lots, sell_lots, hedge_lots;
   ENUM_POSITION_TYPE hedge_type;
   double   total_pl;
};

// Cycle State
bool     g_recovery              = false;
int      g_trapped_dir           = 0;       // +1 for BUY trapped (falling market), -1 for SELL trapped (rising market)
ulong    g_trapped_ticket        = 0;
double   g_cycle_harvest_credit  = 0.0;     // Amortization bank accumulated by continuous harvests
int      g_cycle_harvest_count   = 0;
double   g_hedge_sl_price        = 0.0;
bool     g_hedge_be_locked       = false;

// Pullback Tracker
double   g_last_buy_close_price  = 0.0;
double   g_last_sell_close_price = 0.0;
double   g_extreme_bid_high      = 0.0;
double   g_extreme_ask_low       = 0.0;

// Daily Protection
datetime g_current_day           = 0;
double   g_day_start_balance     = 0.0;
bool     g_daily_halted          = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicBuy);
   trade.SetDeviationInPoints(InpSlippage);
   trade.SetTypeFillingBySymbol(_Symbol);

   g_current_day       = iTime(_Symbol, PERIOD_D1, 0);
   g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_daily_halted      = false;

   Print("==================================================================");
   Print("  Gold Quantum Harvester v7.00 Initialized (Build: ", GBH7_BUILD, ")");
   Print("  Symbol: ", _Symbol, " | Currency: ", AccountInfoString(ACCOUNT_CURRENCY));
   Print("  Instant Trading: ", InpInstantEntry ? "YES (Immediate 1xBUY + 1xSELL)" : "NO (Waiting Pullback)");
   Print("  Daily Drawdown Limit: -£", DoubleToString(InpMaxDailyLoss, 2));
   Print("  Continuous Harvesting Active: ", InpContinuousHarvesting ? "YES (24/5 Non-Stop)" : "NO");
   Print("  Hedge Trigger: £", DoubleToString(InpHedgeTrigger, 2), " | Hedge Lot: ", DoubleToString(InpHedgeLotSize, 2));
   Print("==================================================================");

   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   Comment("");
}

//+------------------------------------------------------------------+
//| Helper: Calculate real net position profit                       |
//+------------------------------------------------------------------+
double PositionRealNetPL(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
}

//+------------------------------------------------------------------+
//| Helper: Scan open positions                                      |
//+------------------------------------------------------------------+
void ScanBook(Book &b)
{
   ZeroMemory(b);
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ulong magic = PositionGetInteger(POSITION_MAGIC);
      double pl   = PositionRealNetPL(ticket);
      double lots = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

      b.total_pl += pl;

      if(magic == InpMagicBuy)
      {
         b.n_buy++;
         b.buy_ticket = ticket;
         b.buy_pl     = pl;
         b.buy_lots   = lots;
         b.buy_open   = open;
      }
      else if(magic == InpMagicSell)
      {
         b.n_sell++;
         b.sell_ticket = ticket;
         b.sell_pl     = pl;
         b.sell_lots   = lots;
         b.sell_open   = open;
      }
      else if(magic == InpMagicHedge)
      {
         b.n_hedge++;
         b.hedge_ticket = ticket;
         b.hedge_pl     = pl;
         b.hedge_lots   = lots;
         b.hedge_open   = open;
         b.hedge_type   = ptype;
      }
   }
}

//+------------------------------------------------------------------+
//| Check Daily Drawdown Circuit Breaker                             |
//+------------------------------------------------------------------+
bool CheckDailyCircuitBreaker()
{
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != g_current_day)
   {
      g_current_day       = today;
      g_day_start_balance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_daily_halted      = false;
   }

   HistorySelect(today, TimeCurrent());
   int total_deals = HistoryDealsTotal();
   double closed_pl_today = 0.0;

   for(int i = 0; i < total_deals; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0) continue;
      long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT)
      {
         closed_pl_today += HistoryDealGetDouble(deal, DEAL_PROFIT) 
                          + HistoryDealGetDouble(deal, DEAL_SWAP)
                          + HistoryDealGetDouble(deal, DEAL_COMMISSION);
      }
   }

   if(closed_pl_today <= -InpMaxDailyLoss)
   {
      g_daily_halted = true;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Disaster Broker-Side Stop Loss Enforcement                       |
//+------------------------------------------------------------------+
void EnforceDisasterStops(const Book &b)
{
   if(InpDisasterSL <= 0.0) return;

   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val <= 0.0 || tick_sz <= 0.0) return;

   // Buy Disaster Stop
   if(b.n_buy > 0 && PositionSelectByTicket(b.buy_ticket))
   {
      if(PositionGetDouble(POSITION_SL) == 0.0)
      {
         double p_dist = (InpDisasterSL / (b.buy_lots * (tick_val / tick_sz))) * tick_sz;
         double sl_price = NormalizeDouble(b.buy_open - p_dist, _Digits);
         trade.SetExpertMagicNumber(InpMagicBuy);
         trade.PositionModify(b.buy_ticket, sl_price, 0.0);
      }
   }

   // Sell Disaster Stop
   if(b.n_sell > 0 && PositionSelectByTicket(b.sell_ticket))
   {
      if(PositionGetDouble(POSITION_SL) == 0.0)
      {
         double p_dist = (InpDisasterSL / (b.sell_lots * (tick_val / tick_sz))) * tick_sz;
         double sl_price = NormalizeDouble(b.sell_open + p_dist, _Digits);
         trade.SetExpertMagicNumber(InpMagicSell);
         trade.PositionModify(b.sell_ticket, sl_price, 0.0);
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Active Hedge (Breakeven Lock & Dynamic Trailing)          |
//+------------------------------------------------------------------+
void ManageActiveHedge(const Book &b)
{
   if(b.n_hedge == 0) return;
   if(!PositionSelectByTicket(b.hedge_ticket)) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val <= 0.0 || tick_sz <= 0.0) return;

   double p_trail = (InpHedgeTrailDistance / (b.hedge_lots * (tick_val / tick_sz))) * tick_sz;

   // 1. Breakeven Lock when hedge reaches InpHedgeLockAt
   if(!g_hedge_be_locked && b.hedge_pl >= InpHedgeLockAt)
   {
      double be_price = (b.hedge_type == POSITION_TYPE_BUY) ? (b.hedge_open + 10 * _Point) : (b.hedge_open - 10 * _Point);
      trade.SetExpertMagicNumber(InpMagicHedge);
      if(trade.PositionModify(b.hedge_ticket, NormalizeDouble(be_price, _Digits), 0.0))
      {
         g_hedge_be_locked = true;
         g_hedge_sl_price  = be_price;
         Print(">>> Hedge LOCKED to Breakeven (+£", DoubleToString(b.hedge_pl, 2), ")");
      }
   }

   // 2. Trailing Stop
   if(g_hedge_be_locked)
   {
      if(b.hedge_type == POSITION_TYPE_BUY)
      {
         double new_sl = NormalizeDouble(bid - p_trail, _Digits);
         if(new_sl > PositionGetDouble(POSITION_SL) + 10 * _Point)
         {
            trade.SetExpertMagicNumber(InpMagicHedge);
            if(trade.PositionModify(b.hedge_ticket, new_sl, 0.0))
               g_hedge_sl_price = new_sl;
         }
      }
      else if(b.hedge_type == POSITION_TYPE_SELL)
      {
         double new_sl = NormalizeDouble(ask + p_trail, _Digits);
         if(new_sl < PositionGetDouble(POSITION_SL) - 10 * _Point || PositionGetDouble(POSITION_SL) == 0.0)
         {
            trade.SetExpertMagicNumber(InpMagicHedge);
            if(trade.PositionModify(b.hedge_ticket, new_sl, 0.0))
               g_hedge_sl_price = new_sl;
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Check Combined Basket Exit (Joint Exit)                          |
//+------------------------------------------------------------------+
bool CheckCombinedBasketExit(const Book &b)
{
   if(!g_recovery) return false;

   double trapped_pl = 0.0;
   bool   trapped_alive = false;

   if(g_trapped_dir > 0 && b.n_buy > 0)
   {
      trapped_pl = b.buy_pl;
      trapped_alive = true;
   }
   else if(g_trapped_dir < 0 && b.n_sell > 0)
   {
      trapped_pl = b.sell_pl;
      trapped_alive = true;
   }

   if(!trapped_alive)
   {
      Print(">>> Trapped position resolved or closed. Resetting recovery state.");
      g_recovery             = false;
      g_trapped_dir          = 0;
      g_trapped_ticket       = 0;
      g_cycle_harvest_credit = 0.0;
      g_cycle_harvest_count  = 0;
      g_hedge_be_locked      = false;
      return true;
   }

   double combined_basket_pl = trapped_pl + b.hedge_pl + g_cycle_harvest_credit;

   if(combined_basket_pl >= InpJointTarget)
   {
      Print("==========================================================");
      Print("🎉 COMBINED JOINT EXIT TRIGGERED!");
      Print("   Trapped P&L: £", DoubleToString(trapped_pl, 2));
      Print("   Hedge P&L: £", DoubleToString(b.hedge_pl, 2));
      Print("   Amortized Harvest Profits: +£", DoubleToString(g_cycle_harvest_credit, 2), " (", g_cycle_harvest_count, " harvests)");
      Print("   Net Combined Profit: +£", DoubleToString(combined_basket_pl, 2));
      Print("==========================================================");

      // Close trapped leg
      if(g_trapped_dir > 0 && b.n_buy > 0)
      {
         trade.SetExpertMagicNumber(InpMagicBuy);
         trade.PositionClose(b.buy_ticket);
      }
      else if(g_trapped_dir < 0 && b.n_sell > 0)
      {
         trade.SetExpertMagicNumber(InpMagicSell);
         trade.PositionClose(b.sell_ticket);
      }

      // Close hedge if open
      if(b.n_hedge > 0)
      {
         trade.SetExpertMagicNumber(InpMagicHedge);
         trade.PositionClose(b.hedge_ticket);
      }

      // Reset cycle state
      g_recovery             = false;
      g_trapped_dir          = 0;
      g_trapped_ticket       = 0;
      g_cycle_harvest_credit = 0.0;
      g_cycle_harvest_count  = 0;
      g_hedge_be_locked      = false;
      return true;
   }

   return false;
}

//+------------------------------------------------------------------+
//| Deploy Protective Trend-Following Hedge                          |
//+------------------------------------------------------------------+
void CheckDeployHedge(const Book &b)
{
   if(!g_recovery)
   {
      if(b.n_buy > 0 && b.buy_pl <= InpHedgeTrigger)
      {
         g_recovery             = true;
         g_trapped_dir          = 1; // BUY trapped, market falling
         g_trapped_ticket       = b.buy_ticket;
         g_cycle_harvest_credit = 0.0;
         g_cycle_harvest_count  = 0;
         g_hedge_be_locked      = false;
         Print("⚠️ Recovery Mode ACTIVATED: BUY trapped at £", DoubleToString(b.buy_pl, 2));
      }
      else if(b.n_sell > 0 && b.sell_pl <= InpHedgeTrigger)
      {
         g_recovery             = true;
         g_trapped_dir          = -1; // SELL trapped, market rising
         g_trapped_ticket       = b.sell_ticket;
         g_cycle_harvest_credit = 0.0;
         g_cycle_harvest_count  = 0;
         g_hedge_be_locked      = false;
         Print("⚠️ Recovery Mode ACTIVATED: SELL trapped at £", DoubleToString(b.sell_pl, 2));
      }
   }

   if(!g_recovery) return;
   if(b.n_hedge > 0) return;

   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   if(spread > InpMaxSpread) return;

   double tick_val = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tick_sz  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick_val <= 0.0 || tick_sz <= 0.0) return;

   double p_risk = (InpHedgeSL / (InpHedgeLotSize * (tick_val / tick_sz))) * tick_sz;

   trade.SetExpertMagicNumber(InpMagicHedge);

   if(g_trapped_dir > 0)
   {
      // BUY trapped (market fell) -> SELL hedge
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double sl  = NormalizeDouble(bid + p_risk, _Digits);
      if(trade.Sell(InpHedgeLotSize, _Symbol, bid, sl, 0.0, "GBH7 Recovery Hedge SELL"))
      {
         g_hedge_be_locked = false;
         g_hedge_sl_price  = sl;
         Print(">>> Deployed 0.02 SELL Hedge @ ", bid, " (SL: ", sl, ")");
      }
   }
   else if(g_trapped_dir < 0)
   {
      // SELL trapped (market rose) -> BUY hedge
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sl  = NormalizeDouble(ask - p_risk, _Digits);
      if(trade.Buy(InpHedgeLotSize, _Symbol, ask, sl, 0.0, "GBH7 Recovery Hedge BUY"))
      {
         g_hedge_be_locked = false;
         g_hedge_sl_price  = sl;
         Print(">>> Deployed 0.02 BUY Hedge @ ", ask, " (SL: ", sl, ")");
      }
   }
}

//+------------------------------------------------------------------+
//| Continuous 24/5 Base Harvesting Engine                           |
//+------------------------------------------------------------------+
void RunContinuousHarvesting(Book &b)
{
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   // Update Extremes
   if(bid > g_extreme_bid_high || g_extreme_bid_high == 0.0) g_extreme_bid_high = bid;
   if(ask < g_extreme_ask_low  || g_extreme_ask_low == 0.0)  g_extreme_ask_low  = ask;

   // 1. HARVEST WINNING BUY
   if(b.n_buy > 0 && b.buy_pl >= InpHarvestTarget)
   {
      trade.SetExpertMagicNumber(InpMagicBuy);
      double profit_captured = b.buy_pl;
      if(trade.PositionClose(b.buy_ticket))
      {
         g_last_buy_close_price = bid;
         g_extreme_bid_high     = bid;
         Print("✅ Harvested BUY net: +£", DoubleToString(profit_captured, 2));

         if(g_recovery && g_trapped_dir < 0)
         {
            double amortized_chunk = profit_captured * InpAmortizePortion;
            g_cycle_harvest_credit += amortized_chunk;
            g_cycle_harvest_count++;
            Print("💰 Amortization Credit Added: +£", DoubleToString(amortized_chunk, 2), 
                  " | Total Relief Bank: +£", DoubleToString(g_cycle_harvest_credit, 2));
         }
         return;
      }
   }

   // 2. HARVEST WINNING SELL
   if(b.n_sell > 0 && b.sell_pl >= InpHarvestTarget)
   {
      trade.SetExpertMagicNumber(InpMagicSell);
      double profit_captured = b.sell_pl;
      if(trade.PositionClose(b.sell_ticket))
      {
         g_last_sell_close_price = ask;
         g_extreme_ask_low       = ask;
         Print("✅ Harvested SELL net: +£", DoubleToString(profit_captured, 2));

         if(g_recovery && g_trapped_dir > 0)
         {
            double amortized_chunk = profit_captured * InpAmortizePortion;
            g_cycle_harvest_credit += amortized_chunk;
            g_cycle_harvest_count++;
            Print("💰 Amortization Credit Added: +£", DoubleToString(amortized_chunk, 2), 
                  " | Total Relief Bank: +£", DoubleToString(g_cycle_harvest_credit, 2));
         }
         return;
      }
   }

   // Spread check before opening new trades
   if(spread > InpMaxSpread) return;

   // 3. RE-ENTRY / NEW BUY
   if(b.n_buy == 0)
   {
      bool allow_buy = true;
      if(g_recovery && g_trapped_dir > 0) allow_buy = false; // Do not buy into falling trap

      if(allow_buy)
      {
         bool trigger_entry = InpInstantEntry;
         if(!trigger_entry)
         {
            if(g_last_buy_close_price == 0.0) trigger_entry = true;
            else if(bid <= g_extreme_bid_high - InpPullbackPoints * _Point)
               trigger_entry = true;
         }

         if(trigger_entry)
         {
            trade.SetExpertMagicNumber(InpMagicBuy);
            if(trade.Buy(InpLotSize, _Symbol, ask, 0.0, 0.0, "GBH7 Base BUY"))
            {
               g_extreme_bid_high = bid;
               Print("🛒 Opened Base BUY @ ", ask);
            }
         }
      }
   }

   // 4. RE-ENTRY / NEW SELL
   if(b.n_sell == 0)
   {
      bool allow_sell = true;
      if(g_recovery && g_trapped_dir < 0) allow_sell = false; // Do not sell into rising trap

      if(allow_sell)
      {
         bool trigger_entry = InpInstantEntry;
         if(!trigger_entry)
         {
            if(g_last_sell_close_price == 0.0) trigger_entry = true;
            else if(ask >= g_extreme_ask_low + InpPullbackPoints * _Point)
               trigger_entry = true;
         }

         if(trigger_entry)
         {
            trade.SetExpertMagicNumber(InpMagicSell);
            if(trade.Sell(InpLotSize, _Symbol, bid, 0.0, 0.0, "GBH7 Base SELL"))
            {
               g_extreme_ask_low = ask;
               Print("🛒 Opened Base SELL @ ", bid);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| On-Screen Real-Time Visual Dashboard                             |
//+------------------------------------------------------------------+
void RenderDashboard(const Book &b)
{
   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   string s = "========================================================\n";
   s += "  🏆 GOLD QUANTUM HARVESTER v7.00 (AMORTIZED ENGINE)\n";
   s += "========================================================\n";
   s += "Account Balance : " + DoubleToString(AccountInfoDouble(ACCOUNT_BALANCE), 2) + " " + ccy + "\n";
   s += "Account Equity  : " + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2) + " " + ccy + "\n";
   s += "Floating P&L    : " + DoubleToString(b.total_pl, 2) + " " + ccy + "\n";
   s += "Current Spread  : " + (string)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) + " pts (Max Allowed: " + (string)InpMaxSpread + ")\n";
   s += "--------------------------------------------------------\n";
   s += "ACTIVE TRADES:\n";
   s += "  BUY (0.01)    : " + (b.n_buy > 0 ? ("Open @ " + DoubleToString(b.buy_open, _Digits) + " | P&L: £" + DoubleToString(b.buy_pl, 2)) : (InpInstantEntry ? "Entering..." : "Waiting Pullback...")) + "\n";
   s += "  SELL (0.01)   : " + (b.n_sell > 0 ? ("Open @ " + DoubleToString(b.sell_open, _Digits) + " | P&L: £" + DoubleToString(b.sell_pl, 2)) : (InpInstantEntry ? "Entering..." : "Waiting Pullback...")) + "\n";
   s += "--------------------------------------------------------\n";

   if(g_recovery)
   {
      double trapped_pl = (g_trapped_dir > 0) ? b.buy_pl : b.sell_pl;
      double combined   = trapped_pl + b.hedge_pl + g_cycle_harvest_credit;

      s += "🚨 RECOVERY STATUS : ACTIVE (Combined Basket Engine)\n";
      s += "  Trapped Leg      : " + (g_trapped_dir > 0 ? "BUY" : "SELL") + " (P&L: £" + DoubleToString(trapped_pl, 2) + ")\n";
      s += "  Recovery Hedge   : " + (b.n_hedge > 0 ? (EnumToString(b.hedge_type) + " 0.02 | P&L: £" + DoubleToString(b.hedge_pl, 2)) : "Pending...") + "\n";
      s += "  Harvest Relief   : +£" + DoubleToString(g_cycle_harvest_credit, 2) + " (" + (string)g_cycle_harvest_count + " harvests amortized)\n";
      s += "  👉 COMBINED BASKET: £" + DoubleToString(combined, 2) + " (Target: +£" + DoubleToString(InpJointTarget, 2) + ")\n";
   }
   else
   {
      s += "🟢 HARVEST STATUS : NORMAL 24/5 HARVESTING\n";
      s += "  Mode             : " + (InpInstantEntry ? "INSTANT TRADING (1xBUY + 1xSELL)" : "Pullback Stalker") + "\n";
   }

   s += "--------------------------------------------------------\n";
   s += "CAPITAL SHIELD:\n";
   s += "  Daily Max Loss   : -£" + DoubleToString(InpMaxDailyLoss, 2) + " (Circuit Breaker)\n";
   s += "  Status           : " + (g_daily_halted ? "⛔ HALTED FOR TODAY (DDD Reached)" : "ACTIVE & PROTECTED ✅") + "\n";
   s += "========================================================";

   Comment(s);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   if(CheckDailyCircuitBreaker())
   {
      Book b_empty;
      ScanBook(b_empty);
      RenderDashboard(b_empty);
      return;
   }

   Book b;
   ScanBook(b);
   RenderDashboard(b);
   EnforceDisasterStops(b);
   ManageActiveHedge(b);

   if(CheckCombinedBasketExit(b)) return;
   CheckDeployHedge(b);
   RunContinuousHarvesting(b);
}
//+------------------------------------------------------------------+
