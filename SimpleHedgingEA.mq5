//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Smart Zone Dual Grid EA (30-pip min offset from     |
//|              current price, Independent Side Exits, No False SL) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "96.00"
#property description "Smart Dual Grid: 30-pip min zone offset prevents false breakouts, Independent Buy/Sell exits, No SL needed"

#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_GRID_STATE
{
   GRID_STATE_EMPTY,
   GRID_STATE_PLACING_INITIAL,
   GRID_STATE_ACTIVE,
   GRID_STATE_CLEANING_BUY,
   GRID_STATE_CLEANING_SELL,
   GRID_STATE_CLEANING_ALL
};

//--- Input Parameters
input group "=== Grid & Zone Settings ==="
input double   InpStartLot            = 0.01;    // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;    // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;     // Grid Step Between Levels (150 pts = 15 pips)
input int      InpMinZoneOffsetPoints = 300;     // Min Zone Offset from Current Price (300 pts = 30 pips - avoids false breakouts)
input int      InpZoneLookbackBars    = 50;      // Zone High/Low Lookback (50 M1 bars)

input group "=== Profit & Loss ==="
input double   InpBuySideTargetUSD    = 1.00;    // Buy Side Profit Target ($1.00)
input double   InpSellSideTargetUSD   = 1.00;    // Sell Side Profit Target ($1.00)
input double   InpMaxSideLossUSD      = 50.0;    // Per-Side Max Loss Cap ($50)

input group "=== Bangladesh Time Schedule (GMT+6) ==="
input bool     InpUseTimeWindow       = true;    // Enable Time Schedule Filter
input int      InpBDStartHour         = 7;       // Start Trading Hour (07:00 AM BD Time)
input int      InpBDEndHour           = 22;      // End Trading Hour (10:00 PM BD Time)
input int      InpBDtoServerDiffHours = 3;       // BD GMT+6 minus Broker GMT+3 = 3 Hours
input bool     InpEODProfitOnlyClose  = true;    // Night EOD Close ONLY IF PROFITABLE

input group "=== Risk Control ==="
input double   InpMaxAllowedDrawdownUSD = 5000.0;
input double   InpMaxDrawdownPercent    = 90.0;
input bool     InpClosePendingsFriday   = true;

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;
input ulong    InpSlippage            = 30;

//--- Global Variables
CTrade           m_trade;
ENUM_GRID_STATE  m_gridState;
int              m_buyGridPlacedCount;
int              m_sellGridPlacedCount;
bool             m_buySideClosed;
bool             m_sellSideClosed;

//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: Account is not Retail Hedging mode!");

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   ResetStateMachine();

   PrintFormat("[INIT] v96.0 Smart Zone Grid. MinOffset: %d pts (%d pips), BuyTgt: $%.2f, SellTgt: $%.2f, MaxSideLoss: $%.2f",
               InpMinZoneOffsetPoints, InpMinZoneOffsetPoints/10, InpBuySideTargetUSD, InpSellSideTargetUSD, InpMaxSideLossUSD);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { PrintFormat("[DEINIT] Reason: %d", reason); }

//+------------------------------------------------------------------+
void OnTick()
{
   if(CheckEquityProtection()) return;

   if(InpClosePendingsFriday && IsFridayNightClose())
   {
      DeleteOnePendingOrderPaced();
      return;
   }

   // Stats
   int    buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0, buyProfitUSD = 0, sellProfitUSD = 0;
   GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount, totalBuyLot, totalSellLot, buyProfitUSD, sellProfitUSD);
   int totalPos     = buyCount + sellCount;
   int totalPending = buyStopCount + sellStopCount;

   // EOD: close only if profitable
   if(InpEODProfitOnlyClose && IsEODCloseTime())
   {
      if(buyCount > 0 && buyProfitUSD > 0.0)  { ClosePositionsByType(POSITION_TYPE_BUY);  DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);  }
      if(sellCount > 0 && sellProfitUSD > 0.0) { ClosePositionsByType(POSITION_TYPE_SELL); DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP); }
      if(totalPos == 0) m_gridState = GRID_STATE_CLEANING_ALL;
      return;
   }

   // BD time filter
   if(InpUseTimeWindow && !IsWithinBDTradingHours())
   {
      if(totalPos == 0 && totalPending > 0) { DeleteOnePendingOrderPaced(); return; }
      if(totalPos == 0) { ResetStateMachine(); return; }
   }

   // Cleaning state
   if(m_gridState == GRID_STATE_CLEANING_ALL ||
      m_gridState == GRID_STATE_CLEANING_BUY  ||
      m_gridState == GRID_STATE_CLEANING_SELL)
   {
      if(totalPending > 0) { DeleteOnePendingOrderPaced(); return; }
      if(totalPos == 0)    { ResetStateMachine(); return; }
      m_gridState = GRID_STATE_ACTIVE;
   }

   // Per-side max loss cap
   if(InpMaxSideLossUSD > 0)
   {
      if(buyCount > 0 && buyProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [BUY MAX LOSS CUT] $%.2f loss. Closing Buy side...", buyProfitUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
         m_buySideClosed = true; m_buyGridPlacedCount = 0;
         m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
         return;
      }
      if(sellCount > 0 && sellProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [SELL MAX LOSS CUT] $%.2f loss. Closing Sell side...", sellProfitUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
         m_sellSideClosed = true; m_sellGridPlacedCount = 0;
         m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
         return;
      }
   }

   // Independent buy-side profit exit
   if(buyCount > 0 && buyProfitUSD >= InpBuySideTargetUSD)
   {
      PrintFormat(">>> [BUY PROFIT EXIT] $%.2f profit. Closing Buy side...", buyProfitUSD);
      ClosePositionsByType(POSITION_TYPE_BUY);
      DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      m_buySideClosed = true; m_buyGridPlacedCount = 0;
      m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
      return;
   }

   // Independent sell-side profit exit
   if(sellCount > 0 && sellProfitUSD >= InpSellSideTargetUSD)
   {
      PrintFormat(">>> [SELL PROFIT EXIT] $%.2f profit. Closing Sell side...", sellProfitUSD);
      ClosePositionsByType(POSITION_TYPE_SELL);
      DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      m_sellSideClosed = true; m_sellGridPlacedCount = 0;
      m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
      return;
   }

   // Reset when both sides done
   if(m_buySideClosed && m_sellSideClosed && totalPos == 0 && totalPending == 0)
      ResetStateMachine();

   // Start fresh grid placement
   if(totalPos == 0 && totalPending == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      if(!InpUseTimeWindow || IsWithinBDTradingHours())
         m_gridState = GRID_STATE_PLACING_INITIAL;
   }

   // Place grid orders (1 per tick)
   if(m_gridState == GRID_STATE_PLACING_INITIAL)
   {
      if(m_buyGridPlacedCount < 11 || m_sellGridPlacedCount < 11)
         PlaceGridOrdersPaced();
      else
         m_gridState = GRID_STATE_ACTIVE;
   }
}

//+------------------------------------------------------------------+
//| Place grid orders using safe zone with 30-pip minimum offset     |
//+------------------------------------------------------------------+
void PlaceGridOrdersPaced()
{
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(ask <= 0 || bid <= 0 || point <= 0) return;

   // --- Find recent zone high/low from M1 lookback
   double zoneHigh = 0, zoneLow = DBL_MAX;
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   int cH = CopyHigh(_Symbol, PERIOD_M1, 1, InpZoneLookbackBars, hi);
   int cL = CopyLow (_Symbol, PERIOD_M1, 1, InpZoneLookbackBars, lo);
   if(cH > 0) for(int i = 0; i < cH; i++) if(hi[i] > zoneHigh) zoneHigh = hi[i];
   if(cL > 0) for(int i = 0; i < cL; i++) if(lo[i] < zoneLow)  zoneLow  = lo[i];

   // --- BUY ZONE: must be at least 30 pips above current ask
   //     Take whichever is higher: zone high OR ask + 30 pips
   double minBuyOffset = ask + InpMinZoneOffsetPoints * point;
   double buyBase      = MathMax(zoneHigh, minBuyOffset);
   buyBase             = MathMax(buyBase, ask + stopLvl * point + point); // never less than stop level

   // --- SELL ZONE: must be at least 30 pips below current bid
   //     Take whichever is lower: zone low OR bid - 30 pips
   double minSellOffset = bid - InpMinZoneOffsetPoints * point;
   double sellBase      = MathMin(zoneLow, minSellOffset);
   sellBase             = MathMin(sellBase, bid - stopLvl * point - point);

   // Place 1 Buy Stop per tick
   if(m_buyGridPlacedCount < 11)
   {
      int    i      = m_buyGridPlacedCount + 1;
      double lot    = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double offset = (i - 1) * InpBaseGridStepPoints * point;
      double price  = NormalizeDouble(buyBase + offset, _Digits);

      if(price > ask + stopLvl * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, lot, price, StringFormat("BuyZone #%d", i)))
            m_buyGridPlacedCount++;
      }
      else
         m_buyGridPlacedCount++;
      return;
   }

   // Place 1 Sell Stop per tick
   if(m_sellGridPlacedCount < 11)
   {
      int    i      = m_sellGridPlacedCount + 1;
      double lot    = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double offset = (i - 1) * InpBaseGridStepPoints * point;
      double price  = NormalizeDouble(sellBase - offset, _Digits);

      if(price < bid - stopLvl * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, lot, price, StringFormat("SellZone #%d", i)))
            m_sellGridPlacedCount++;
      }
      else
         m_sellGridPlacedCount++;
      return;
   }
}

//+------------------------------------------------------------------+
bool IsEODCloseTime()
{
   MqlDateTime dt; TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   return (bdHour == 21 && dt.min >= 55);
}

bool IsWithinBDTradingHours()
{
   MqlDateTime dt; TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   if(InpBDStartHour <= InpBDEndHour)
      return (bdHour >= InpBDStartHour && bdHour < InpBDEndHour);
   else
      return (bdHour >= InpBDStartHour || bdHour < InpBDEndHour);
}

bool IsFridayNightClose()
{
   MqlDateTime dt; TimeCurrent(dt);
   return (dt.day_of_week == 5 && dt.hour >= 23 && dt.min >= 40);
}

void ResetStateMachine()
{
   m_gridState           = GRID_STATE_EMPTY;
   m_buyGridPlacedCount  = 0;
   m_sellGridPlacedCount = 0;
   m_buySideClosed       = false;
   m_sellSideClosed      = false;
}

void DeleteOnePendingOrderPaced()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         m_trade.OrderDelete(ticket);
         return;
      }
   }
}

void DeletePendingOrdersByType(ENUM_ORDER_TYPE targetType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == targetType)
            m_trade.OrderDelete(ticket);
   }
}

bool PlacePendingOrderSafe(ENUM_ORDER_TYPE orderType, double lot, double price, string comment)
{
   if(orderType == ORDER_TYPE_BUY_STOP)
      if(m_trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;
   if(orderType == ORDER_TYPE_SELL_STOP)
      if(m_trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;

   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   for(int f = 0; f < 3; f++)
   {
      MqlTradeRequest req = {}; MqlTradeResult res = {};
      req.action = TRADE_ACTION_PENDING; req.symbol = _Symbol; req.volume = lot;
      req.price = price; req.type = orderType; req.type_filling = fillings[f];
      req.type_time = ORDER_TIME_GTC; req.deviation = InpSlippage;
      req.magic = InpMagicNumber; req.comment = comment;
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return true;
   }
   return false;
}

void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   for(int retry = 0; retry < 5; retry++)
   {
      ulong tickets[]; int count = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         { ArrayResize(tickets, count+1); tickets[count++] = ticket; }
      }
      if(count == 0) return;
      for(int k = 0; k < count; k++)
      {
         if(!m_trade.PositionClose(tickets[k]))
         {
            PositionSelectByTicket(tickets[k]);
            double volume = PositionGetDouble(POSITION_VOLUME);
            for(int f = 0; f < 3; f++)
            {
               MqlTradeRequest req = {}; MqlTradeResult res = {};
               req.action = TRADE_ACTION_DEAL; req.position = tickets[k];
               req.symbol = _Symbol; req.volume = volume;
               req.type = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               req.price = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               req.deviation = InpSlippage; req.magic = InpMagicNumber; req.type_filling = fillings[f];
               if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) break;
            }
         }
      }
   }
}

void CloseAllPositionsGuaranteed()
{
   ClosePositionsByType(POSITION_TYPE_BUY);
   ClosePositionsByType(POSITION_TYPE_SELL);
}

void DeleteAllPendingOrdersGuaranteed()
{
   for(int retry = 0; retry < 5; retry++)
   {
      ulong tickets[]; int count = 0;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         { ArrayResize(tickets, count+1); tickets[count++] = ticket; }
      }
      if(count == 0) return;
      for(int k = 0; k < count; k++) m_trade.OrderDelete(tickets[k]);
   }
}

void GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount,
                   double &totalBuyLot, double &totalSellLot,
                   double &buyProfitUSD, double &sellProfitUSD)
{
   buyCount=0; sellCount=0; buyStopCount=0; sellStopCount=0;
   totalBuyLot=0; totalSellLot=0; buyProfitUSD=0; sellProfitUSD=0;
   for(int i = PositionsTotal()-1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double pft = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);
         if(type == POSITION_TYPE_BUY)  { buyCount++;  totalBuyLot  += vol; buyProfitUSD  += pft; }
         else                           { sellCount++; totalSellLot += vol; sellProfitUSD += pft; }
      }
   }
   for(int i = OrdersTotal()-1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP)  buyStopCount++;
         else if(type == ORDER_TYPE_SELL_STOP) sellStopCount++;
      }
   }
}

bool CheckEquityProtection()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   double loss = balance - equity;
   double pct  = (loss / balance) * 100.0;
   if(InpMaxAllowedDrawdownUSD > 0 && loss >= InpMaxAllowedDrawdownUSD)
   {
      PrintFormat("[MAX DD] Loss $%.2f >= $%.2f! Liquidating...", loss, InpMaxAllowedDrawdownUSD);
      CloseAllPositionsGuaranteed(); DeleteAllPendingOrdersGuaranteed(); ResetStateMachine();
      return true;
   }
   if(pct >= InpMaxDrawdownPercent)
   {
      PrintFormat("[EMERGENCY] DD %.2f%% reached! Liquidating...", pct);
      CloseAllPositionsGuaranteed(); DeleteAllPendingOrdersGuaranteed(); ResetStateMachine();
      return true;
   }
   return false;
}

double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   lot = MathFloor(lot / step) * step;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
