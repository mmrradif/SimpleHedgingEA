//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Original Dual Zone Grid EA (Target $5, Loss $500)  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "98.00"
#property description "Original Dual Zone EA: 11 BuyStops in Buy Zone & 11 SellStops in Sell Zone (Target $5.00, Max Loss $500.00)"

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
input group "=== Grid & Lot Settings ==="
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;      // Base Grid Step (150 Points = 15 Pips)
input double   InpSpacingMultiplier   = 1.15;     // Distance Multiplier

input group "=== Profit & Loss Settings ==="
input double   InpTargetProfitUSD     = 5.00;     // Target Net Profit ($5.00 Close All)
input double   InpBuySideTargetUSD    = 5.00;     // Buy Side Profit Target ($5.00 Close Buys Only)
input double   InpSellSideTargetUSD   = 5.00;     // Sell Side Profit Target ($5.00 Close Sells Only)
input double   InpMaxSideLossUSD      = 500.0;    // Per-Side Max Loss Cap ($500.00 Force Close Side)

input group "=== Bangladesh Time Schedule (GMT+6) ==="
input bool     InpUseTimeWindow       = true;     // Enable Time Schedule Filter
input int      InpBDStartHour         = 7;        // Start Trading Hour (07:00 AM BD Time)
input int      InpBDEndHour           = 22;       // End Trading Hour (10:00 PM BD Time)
input int      InpBDtoServerDiffHours = 3;        // Hour Difference (BD GMT+6 minus Broker GMT+3 = 3 Hours)
input bool     InpEODProfitOnlyClose  = true;     // Night EOD Close ONLY IF PROFITABLE (Never at a loss)

input group "=== Risk Control & Drawdown Cap ==="
input double   InpMaxAllowedDrawdownUSD = 500.0;  // Maximum Allowed Drawdown ($500.00 Max USD Loss)
input double   InpMaxDrawdownPercent    = 90.0;   // Emergency Equity Protection (%)
input bool     InpClosePendingsFriday   = true;   // Weekend Gap Guard (Friday 23:40 Pending Delete)

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;   // Magic Number
input ulong    InpSlippage            = 30;       // Max Slippage (Points)

//--- Global Variables
CTrade           m_trade;
ENUM_GRID_STATE  m_gridState;
int              m_buyGridPlacedCount;
int              m_sellGridPlacedCount;
bool             m_buySideClosed;
bool             m_sellSideClosed;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
   {
      Print("WARNING: Account margin mode is not Retail Hedging! EA requires a Hedging account.");
   }

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   
   ResetStateMachine();

   PrintFormat("[INIT] Original Dual Zone EA v98.0 Initialized (11 BuyStops & 11 SellStops). Target: $%.2f, Max Loss: $%.2f", 
               InpTargetProfitUSD, InpMaxAllowedDrawdownUSD);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("[DEINIT] EA Deinitialized. Reason code: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Strict Emergency Drawdown Check (POSITIONS CLOSED FIRST IN MILLISECONDS!)
   if(CheckEquityProtection())
   {
      return;
   }

   // 2. Friday Weekend Gap Protection (Deletes Pendings at Friday 23:40)
   if(InpClosePendingsFriday && IsFridayNightClose())
   {
      if(OrdersTotal() > 0)
      {
         DeleteOnePendingOrderPaced();
      }
      return;
   }

   // 3. Scan Account Trade Stats
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0;
   double buyProfitUSD = 0, sellProfitUSD = 0;
   double totalProfitUSD = GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount, totalBuyLot, totalSellLot, buyProfitUSD, sellProfitUSD);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   // 4. EOD NIGHT CLOSE ONLY IF NET PROFITABLE (At 21:55 BD Time, close ONLY if side profit > $0.00)
   if(InpEODProfitOnlyClose && IsEODCloseTime())
   {
      if(buyCount > 0 && buyProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD BUY PROFIT EXIT] Closing Buy positions IN PROFIT at 21:55 BD Time (Profit: $%.2f)", buyProfitUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      }
      if(sellCount > 0 && sellProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD SELL PROFIT EXIT] Closing Sell positions IN PROFIT at 21:55 BD Time (Profit: $%.2f)", sellProfitUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      }
      if(buyCount == 0 && sellCount == 0)
      {
         m_gridState = GRID_STATE_CLEANING_ALL;
      }
      return;
   }

   // 5. BANGLADESH TIME SCHEDULE FILTER (07:00 AM BD to 10:00 PM BD)
   if(InpUseTimeWindow && !IsWithinBDTradingHours())
   {
      // Outside BD trading hours: if no open positions exist, clean up pendings and pause!
      if(totalOpenPositions == 0 && totalPendingOrders > 0)
      {
         DeleteOnePendingOrderPaced();
         return;
      }
      if(totalOpenPositions == 0)
      {
         ResetStateMachine();
         return;
      }
   }

   // 6. STATE: CLEANING UP PENDINGS AFTER PROFIT EXIT
   if(m_gridState == GRID_STATE_CLEANING_ALL ||
      m_gridState == GRID_STATE_CLEANING_BUY ||
      m_gridState == GRID_STATE_CLEANING_SELL)
   {
      if(totalPendingOrders > 0)
      {
         DeleteOnePendingOrderPaced();
         return;
      }
      if(totalOpenPositions == 0)
      {
         ResetStateMachine();
         return;
      }
      m_gridState = GRID_STATE_ACTIVE;
   }

   // 7. PER-SIDE MAX LOSS CAP (Force close side if loss exceeds $500)
   if(InpMaxSideLossUSD > 0)
   {
      if(buyCount > 0 && buyProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [BUY SIDE MAX LOSS CUT] Buy Loss $%.2f >= $%.2f Limit. Force closing Buy side...", buyProfitUSD, -InpMaxSideLossUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
         m_buySideClosed = true;
         m_buyGridPlacedCount = 0;
         m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
         return;
      }
      if(sellCount > 0 && sellProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [SELL SIDE MAX LOSS CUT] Sell Loss $%.2f >= $%.2f Limit. Force closing Sell side...", sellProfitUSD, -InpMaxSideLossUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
         m_sellSideClosed = true;
         m_sellGridPlacedCount = 0;
         m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
         return;
      }
   }

   // 8. TOTAL BASKET PROFIT EXIT ($5.00 TARGET)
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [TOTAL BASKET PROFIT EXIT!] Net Profit $%.2f >= $%.2f. Closing all positions IN PROFIT...", totalProfitUSD, InpTargetProfitUSD);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      ResetStateMachine();
      return;
   }

   // 9. INDEPENDENT BUY-SIDE PROFIT EXIT ($5.00 TARGET)
   if(buyCount > 0 && buyProfitUSD >= InpBuySideTargetUSD)
   {
      PrintFormat(">>> [BUY SIDE PROFIT EXIT!] Buy Profit $%.2f >= $%.2f. Closing Buy side IN PROFIT...", buyProfitUSD, InpBuySideTargetUSD);
      ClosePositionsByType(POSITION_TYPE_BUY);
      DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      m_buySideClosed = true;
      m_buyGridPlacedCount = 0;
      m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
      return;
   }

   // 10. INDEPENDENT SELL-SIDE PROFIT EXIT ($5.00 TARGET)
   if(sellCount > 0 && sellProfitUSD >= InpSellSideTargetUSD)
   {
      PrintFormat(">>> [SELL SIDE PROFIT EXIT!] Sell Profit $%.2f >= $%.2f. Closing Sell side IN PROFIT...", sellProfitUSD, InpSellSideTargetUSD);
      ClosePositionsByType(POSITION_TYPE_SELL);
      DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      m_sellSideClosed = true;
      m_sellGridPlacedCount = 0;
      m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
      return;
   }

   // 11. RESTART FRESH GRID WHEN BOTH SIDES CLOSED
   if(m_buySideClosed && m_sellSideClosed && totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetStateMachine();
   }

   // 12. STATE: EMPTY STATE -> START PLACEMENT (During allowed BD trading hours)
   if(totalOpenPositions == 0 && totalPendingOrders == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      if(!InpUseTimeWindow || IsWithinBDTradingHours())
      {
         m_gridState = GRID_STATE_PLACING_INITIAL;
      }
   }

   // 13. STATE: PACED PLACEMENT OF INITIAL 11 BUY STOPS & 11 SELL STOPS (1 Order Per Tick)
   if(m_gridState == GRID_STATE_PLACING_INITIAL)
   {
      if(m_buyGridPlacedCount < 11 || m_sellGridPlacedCount < 11)
      {
         SetupPacedInitialDualGrid();
         return;
      }
      else
      {
         m_gridState = GRID_STATE_ACTIVE;
      }
   }
}

//+------------------------------------------------------------------+
//| Check if current BD time is EOD Liquidation Time (21:55 BD Time) |
//+------------------------------------------------------------------+
bool IsEODCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   return (bdHour == 21 && dt.min >= 55);
}

//+------------------------------------------------------------------+
//| Convert Broker Time to BD Time & Check Hours                     |
//+------------------------------------------------------------------+
bool IsWithinBDTradingHours()
{
   MqlDateTime dt;
   TimeCurrent(dt);

   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;

   if(InpBDStartHour <= InpBDEndHour)
   {
      return (bdHour >= InpBDStartHour && bdHour < InpBDEndHour);
   }
   else
   {
      return (bdHour >= InpBDStartHour || bdHour < InpBDEndHour);
   }
}

//+------------------------------------------------------------------+
//| Check if current time is Friday night near market close          |
//+------------------------------------------------------------------+
bool IsFridayNightClose()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.day_of_week == 5 && dt.hour >= 23 && dt.min >= 40);
}

//+------------------------------------------------------------------+
//| Reset State Machine Counters                                     |
//+------------------------------------------------------------------+
void ResetStateMachine()
{
   m_gridState           = GRID_STATE_EMPTY;
   m_buyGridPlacedCount  = 0;
   m_sellGridPlacedCount = 0;
   m_buySideClosed       = false;
   m_sellSideClosed      = false;
}

//+------------------------------------------------------------------+
//| Paced Anti-Spam Single Order Deletion (1 Order Delete Per Tick)  |
//+------------------------------------------------------------------+
void DeleteOnePendingOrderPaced()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         m_trade.OrderDelete(ticket);
         return; // 1 Deletion per tick!
      }
   }
}

//+------------------------------------------------------------------+
//| Delete pending orders by type (BUY_STOP or SELL_STOP)            |
//+------------------------------------------------------------------+
void DeletePendingOrdersByType(ENUM_ORDER_TYPE targetType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == targetType)
         {
            m_trade.OrderDelete(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Setup Paced Initial Dual Grid (Original Buy Zone & Sell Zone)    |
//+------------------------------------------------------------------+
void SetupPacedInitialDualGrid()
{
   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(30, m1High, m1Low);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   double sellBasePrice = MathMin(m1Low, bid - (stopLevel + 15) * point);

   // Place 1 Buy Stop per tick in Buy Zone (0.01 to 0.11 Lot)
   if(m_buyGridPlacedCount < 11)
   {
      int i = m_buyGridPlacedCount + 1;
      double lot = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double cumulativeOffset = (i - 1) * InpBaseGridStepPoints * point;
      double price = NormalizeDouble(buyBasePrice + cumulativeOffset, _Digits);

      if(price > ask + stopLevel * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, lot, price, StringFormat("BuyZone #%d", i)))
         {
            m_buyGridPlacedCount++;
         }
      }
      else
      {
         m_buyGridPlacedCount++;
      }
      return; // 1 Order per tick!
   }

   // Place 1 Sell Stop per tick in Sell Zone (0.01 to 0.11 Lot)
   if(m_sellGridPlacedCount < 11)
   {
      int i = m_sellGridPlacedCount + 1;
      double lot = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double cumulativeOffset = (i - 1) * InpBaseGridStepPoints * point;
      double price = NormalizeDouble(sellBasePrice - cumulativeOffset, _Digits);

      if(price < bid - stopLevel * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, lot, price, StringFormat("SellZone #%d", i)))
         {
            m_sellGridPlacedCount++;
         }
      }
      else
      {
         m_sellGridPlacedCount++;
      }
      return; // 1 Order per tick!
   }
}

//+------------------------------------------------------------------+
//| Guaranteed Multi-Filling Pending Order Placer                    |
//+------------------------------------------------------------------+
bool PlacePendingOrderSafe(ENUM_ORDER_TYPE orderType, double lot, double price, string comment)
{
   if(orderType == ORDER_TYPE_BUY_STOP)
   {
      if(m_trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;
   }
   else if(orderType == ORDER_TYPE_SELL_STOP)
   {
      if(m_trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;
   }

   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   for(int f = 0; f < 3; f++)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};

      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = _Symbol;
      req.volume       = lot;
      req.price        = price;
      req.type         = orderType;
      req.type_filling = fillings[f];
      req.type_time    = ORDER_TIME_GTC;
      req.deviation    = InpSlippage;
      req.magic        = InpMagicNumber;
      req.comment      = comment;

      if(OrderSend(req, res))
      {
         if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
         {
            return true;
         }
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Find M1 Support and Resistance Zone                              |
//+------------------------------------------------------------------+
void FindM1ZoneSafe(int lookback, double &m1High, double &m1Low)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   m1High = ask + (40 * point);
   m1Low = bid - (40 * point);

   if(lookback <= 0) return;

   double highArray[];
   double lowArray[];
   ArraySetAsSeries(highArray, true);
   ArraySetAsSeries(lowArray, true);

   int copiedHigh = CopyHigh(_Symbol, PERIOD_M1, 1, lookback, highArray);
   int copiedLow = CopyLow(_Symbol, PERIOD_M1, 1, lookback, lowArray);

   if(copiedHigh > 0 && copiedLow > 0)
   {
      m1High = highArray[0];
      m1Low = lowArray[0];

      for(int i = 1; i < copiedHigh; i++)
      {
         if(highArray[i] > m1High) m1High = highArray[i];
      }
      for(int i = 1; i < copiedLow; i++)
      {
         if(lowArray[i] < m1Low) m1Low = lowArray[i];
      }
   }
}

//+------------------------------------------------------------------+
//| Close Positions by Specific Type (POSITION_TYPE_BUY or SELL)     |
//+------------------------------------------------------------------+
void ClosePositionsByType(ENUM_POSITION_TYPE posType)
{
   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};

   for(int retry = 0; retry < 5; retry++)
   {
      ulong tickets[];
      int count = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
            {
               ArrayResize(tickets, count + 1);
               tickets[count] = ticket;
               count++;
            }
         }
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
               MqlTradeRequest req = {};
               MqlTradeResult  res = {};

               req.action       = TRADE_ACTION_DEAL;
               req.position     = tickets[k];
               req.symbol       = _Symbol;
               req.volume       = volume;
               req.type         = (posType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
               req.price        = (posType == POSITION_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
               req.deviation    = InpSlippage;
               req.magic        = InpMagicNumber;
               req.type_filling = fillings[f];

               if(OrderSend(req, res))
               {
                  if(res.retcode == TRADE_RETCODE_DONE) break;
               }
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close All Open Positions                                         |
//+------------------------------------------------------------------+
void CloseAllPositionsGuaranteed()
{
   ClosePositionsByType(POSITION_TYPE_BUY);
   ClosePositionsByType(POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Delete All Pending Orders                                        |
//+------------------------------------------------------------------+
void DeleteAllPendingOrdersGuaranteed()
{
   for(int retry = 0; retry < 5; retry++)
   {
      ulong tickets[];
      int count = 0;

      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong ticket = OrderGetTicket(i);
         if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            ArrayResize(tickets, count + 1);
            tickets[count] = ticket;
            count++;
         }
      }

      if(count == 0) return;

      for(int k = 0; k < count; k++)
      {
         m_trade.OrderDelete(tickets[k]);
      }
   }
}

//+------------------------------------------------------------------+
//| Get Open Trade Stats & Per-Side Floating Profits                 |
//+------------------------------------------------------------------+
void GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount,
                   double &totalBuyLot, double &totalSellLot,
                   double &buyProfitUSD, double &sellProfitUSD)
{
   buyCount = 0; sellCount = 0; buyStopCount = 0; sellStopCount = 0;
   totalBuyLot = 0; totalSellLot = 0; buyProfitUSD = 0.0; sellProfitUSD = 0.0;
   double totalProfit = 0.0;

   // Scan Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double pft = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         totalProfit += pft;
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);

         if(type == POSITION_TYPE_BUY)
         {
            buyCount++;
            totalBuyLot += vol;
            buyProfitUSD += pft;
         }
         else if(type == POSITION_TYPE_SELL)
         {
            sellCount++;
            totalSellLot += vol;
            sellProfitUSD += pft;
         }
      }
   }

   // Scan Pendings
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
         if(type == ORDER_TYPE_BUY_STOP) buyStopCount++;
         else if(type == ORDER_TYPE_SELL_STOP) sellStopCount++;
      }
   }

   return totalProfit;
}

//+------------------------------------------------------------------+
//| Emergency Equity Protection Check (POSITIONS CLOSED FIRST!)      |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance > 0)
   {
      double floatingLossUSD = balance - equity;
      double drawdownPercent = (floatingLossUSD / balance) * 100.0;

      // 1. Hard Max USD Drawdown Cap ($500.00)
      if(InpMaxAllowedDrawdownUSD > 0 && floatingLossUSD >= InpMaxAllowedDrawdownUSD)
      {
         PrintFormat("[MAX DRAWDOWN CUTOFF] Floating Loss $%.2f >= Limit $%.2f! Instant liquidation...", 
                     floatingLossUSD, InpMaxAllowedDrawdownUSD);
         CloseAllPositionsGuaranteed();    // CLOSE OPEN POSITIONS FIRST IN MILLISECONDS!
         DeleteAllPendingOrdersGuaranteed(); // THEN DELETE PENDINGS
         ResetStateMachine();
         return true;
      }

      // 2. Hard Equity Percent Protection
      if(drawdownPercent >= InpMaxDrawdownPercent)
      {
         PrintFormat("[EMERGENCY STOP] Max Drawdown %.2f%% reached! Instant liquidation...", drawdownPercent);
         CloseAllPositionsGuaranteed();    // CLOSE OPEN POSITIONS FIRST IN MILLISECONDS!
         DeleteAllPendingOrdersGuaranteed(); // THEN DELETE PENDINGS
         ResetStateMachine();
         return true;
      }
   }
   return false;
}

//+------------------------------------------------------------------+
//| Normalize Lot Size according to Symbol Volume Step               |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep <= 0) lotStep = 0.01;

   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;

   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
