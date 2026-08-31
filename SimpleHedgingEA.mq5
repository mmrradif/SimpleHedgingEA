//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Strict Spread Filter Dual Grid EA                   |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "116.00"
#property description "Strict Spread Protection EA (200 Points / 20 Pips Max Limit for Gold & FX) with Tiered DD ($50-$500)"

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
input int      InpZoneLookback        = 30;       // M1 Support/Resistance Lookback (30 M1 Candles)
input int      InpMaxGridLevels       = 11;       // Max Allowed Grid Levels (11 Levels)
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;      // Base Grid Step (150 Points = 15 Pips)

input group "=== Profit Target Settings ==="
input double   InpTargetProfitUSD     = 5.00;     // Full Grid Basket Target Profit ($5.00)
input double   InpMinProfit3TradesUSD = 0.50;     // Fast Profit Exit for 3+ Trades ($0.50 USD = Instant Close)

input group "=== Tiered Drawdown Cutoffs ==="
input double   InpDDLimit1to2Trades   = 50.0;     // Max Loss for 1-2 Trades ($50.00)
input double   InpDDLimit3to4Trades   = 200.0;    // Max Loss for 3-4 Trades ($200.00)
input double   InpDDLimit5to6Trades   = 300.0;    // Max Loss for 5-6 Trades ($300.00)
input double   InpDDLimit7to8Trades   = 400.0;    // Max Loss for 7-8 Trades ($400.00)
input double   InpDDLimit9PlusTrades  = 500.0;    // Max Loss for 9+ Trades ($500.00)

input group "=== Strict Ask-Bid Spread Protection ==="
input bool     InpUseSpreadGuard      = true;     // Enable Strict Spread Filter
input int      InpMaxSpreadPoints     = 200;      // Max Allowed Ask-Bid Spread (200 Points = 20 Pips Max Limit for Gold/FX)

input group "=== Trading Schedule & Filters ==="
input bool     InpUseTimeWindow       = false;    // Enable Time Schedule Filter (Set false for 24/7 execution)
input int      InpBDStartHour         = 7;        // Start Trading Hour (07:00 AM BD Time)
input int      InpBDEndHour           = 22;       // End Trading Hour (10:00 PM BD Time)
input int      InpBDtoServerDiffHours = 3;        // Hour Difference (BD GMT+6 minus Broker GMT+3 = 3 Hours)
input bool     InpEODProfitOnlyClose  = false;    // Night EOD Close ONLY IF PROFITABLE
input double   InpMaxDrawdownPercent    = 90.0;   // Maximum Allowed Equity Drawdown (%)
input bool     InpClosePendingsFriday   = false;  // Weekend Gap Guard

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
double           m_buyMaxProfitUSD;
double           m_sellMaxProfitUSD;

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

   PrintFormat("[INIT] Strict Spread Filter EA v115.0 Initialized. Max Spread: %d Points (%s)", 
               InpMaxSpreadPoints, InpUseSpreadGuard ? "ENABLED" : "DISABLED");
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
   // 1. Scan Account Trade Stats
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0;
   double buyProfitUSD = 0, sellProfitUSD = 0;
   double totalProfitUSD = GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount, totalBuyLot, totalSellLot, buyProfitUSD, sellProfitUSD);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   // 2. TIERED DYNAMIC DRAWDOWN CUTOFF CHECK (POSITIONS CLOSED FIRST IN MILLISECONDS!)
   if(CheckTieredEquityProtection(totalOpenPositions))
   {
      return;
   }

   // 3. Friday Weekend Gap Protection
   if(InpClosePendingsFriday && IsFridayNightClose())
   {
      if(OrdersTotal() > 0)
      {
         DeleteOnePendingOrderPaced();
      }
      return;
   }

   // 4. Single Direction Isolation (Delete opposing pendings when position opens)
   if(buyCount > 0 && sellStopCount > 0)
   {
      DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      return;
   }
   if(sellCount > 0 && buyStopCount > 0)
   {
      DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      return;
   }

   // 5. EOD NIGHT CLOSE ONLY IF NET PROFITABLE
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

   // 6. BANGLADESH TIME SCHEDULE FILTER
   if(InpUseTimeWindow && !IsWithinBDTradingHours())
   {
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

   // 7. STATE: CLEANING UP PENDINGS AFTER PROFIT EXIT
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

   // 8. GUARANTEED FAST PROFIT & BREAKEVEN LOCK FOR 3+ TRADES
   if(buyCount > 0)
   {
      if(buyProfitUSD > m_buyMaxProfitUSD) m_buyMaxProfitUSD = buyProfitUSD;

      double buyTarget = (buyCount >= 3) ? InpMinProfit3TradesUSD : 0.50;
      if(buyCount >= 8) buyTarget = InpTargetProfitUSD;

      // 1. Direct Target Profit Exit
      if(buyProfitUSD >= buyTarget)
      {
         PrintFormat(">>> [FAST BUY PROFIT EXIT!] Buy Profit $%.2f >= Target $%.2f (%d buys). Closing Buy side IN PROFIT...", 
                     buyProfitUSD, buyTarget, buyCount);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
         m_buySideClosed = true;
         m_buyGridPlacedCount = 0;
         m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
         return;
      }

      // 2. Breakeven Profit Lock
      if(m_buyMaxProfitUSD >= 0.50 && buyProfitUSD <= 0.10 && buyCount >= 3)
      {
         PrintFormat(">>> [BUY BREAKEVEN LOCK!] Max Profit $%.2f pulled back to $%.2f (%d buys). Closing IN PROFIT at Breakeven...", 
                     m_buyMaxProfitUSD, buyProfitUSD, buyCount);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
         m_buySideClosed = true;
         m_buyGridPlacedCount = 0;
         m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
         return;
      }
   }

   if(sellCount > 0)
   {
      if(sellProfitUSD > m_sellMaxProfitUSD) m_sellMaxProfitUSD = sellProfitUSD;

      double sellTarget = (sellCount >= 3) ? InpMinProfit3TradesUSD : 0.50;
      if(sellCount >= 8) sellTarget = InpTargetProfitUSD;

      // 1. Direct Target Profit Exit
      if(sellProfitUSD >= sellTarget)
      {
         PrintFormat(">>> [FAST SELL PROFIT EXIT!] Sell Profit $%.2f >= Target $%.2f (%d sells). Closing Sell side IN PROFIT...", 
                     sellProfitUSD, sellTarget, sellCount);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
         m_sellSideClosed = true;
         m_sellGridPlacedCount = 0;
         m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
         return;
      }

      // 2. Breakeven Profit Lock
      if(m_sellMaxProfitUSD >= 0.50 && sellProfitUSD <= 0.10 && sellCount >= 3)
      {
         PrintFormat(">>> [SELL BREAKEVEN LOCK!] Max Profit $%.2f pulled back to $%.2f (%d sells). Closing IN PROFIT at Breakeven...", 
                     m_sellMaxProfitUSD, sellProfitUSD, sellCount);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
         m_sellSideClosed = true;
         m_sellGridPlacedCount = 0;
         m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
         return;
      }
   }

   // 9. RESTART FRESH GRID WHEN BOTH SIDES CLOSED
   if(m_buySideClosed && m_sellSideClosed && totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetStateMachine();
   }

   // 10. STATE: EMPTY STATE -> CHECK SPREAD GUARD & START PLACEMENT
   if(totalOpenPositions == 0 && totalPendingOrders == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      // STRICT ASK-BID SPREAD GUARD CHECK
      if(InpUseSpreadGuard)
      {
         long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
         if(currentSpread > InpMaxSpreadPoints)
         {
            // Spread is too high! Pause trade placement completely!
            return;
         }
      }

      if(!InpUseTimeWindow || IsWithinBDTradingHours())
      {
         m_gridState = GRID_STATE_PLACING_INITIAL;
      }
   }

   // 11. STATE: PACED PLACEMENT OF INITIAL GRID
   if(m_gridState == GRID_STATE_PLACING_INITIAL)
   {
      if(m_buyGridPlacedCount < InpMaxGridLevels || m_sellGridPlacedCount < InpMaxGridLevels)
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
   m_buyMaxProfitUSD     = 0.0;
   m_sellMaxProfitUSD    = 0.0;
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
//| Setup Exact M1 Zone Dual Grid (With Strict Spread Verification)  |
//+------------------------------------------------------------------+
void SetupPacedInitialDualGrid()
{
   // Double check Spread before placing each order
   if(InpUseSpreadGuard)
   {
      long currentSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
      if(currentSpread > InpMaxSpreadPoints)
      {
         return; // Pause order placement if spread spikes!
      }
   }

   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(InpZoneLookback, m1High, m1Low); // 30 M1 Candles High & Low

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   // Buy Base starts EXACTLY at M1 High
   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   // Sell Base starts EXACTLY at M1 Low
   double sellBasePrice = MathMin(m1Low, bid - (stopLevel + 15) * point);

   // Place Buy Stops up to InpMaxGridLevels
   if(m_buyGridPlacedCount < InpMaxGridLevels)
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

   // Place Sell Stops up to InpMaxGridLevels
   if(m_sellGridPlacedCount < InpMaxGridLevels)
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
//| Find STRICT M1 Timeframe Support and Resistance Zone             |
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

   // STRICTLY COPY PERIOD_M1 CANDLE DATA ONLY
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
double GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount,
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
//| TIERED DYNAMIC DRAWDOWN CUTOFF CHECK                             |
//+------------------------------------------------------------------+
bool CheckTieredEquityProtection(int totalOpenPositions)
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance > 0)
   {
      double floatingLossUSD = balance - equity;
      double drawdownPercent = (floatingLossUSD / balance) * 100.0;

      // Determine Dynamic Tiered Max USD Loss Cutoff based on open trade count
      double currentMaxAllowedLossUSD = InpDDLimit1to2Trades; // Default $50 for 1-2 trades
      if(totalOpenPositions >= 9)       currentMaxAllowedLossUSD = InpDDLimit9PlusTrades; // $500
      else if(totalOpenPositions >= 7)  currentMaxAllowedLossUSD = InpDDLimit7to8Trades;  // $400
      else if(totalOpenPositions >= 5)  currentMaxAllowedLossUSD = InpDDLimit5to6Trades;  // $300
      else if(totalOpenPositions >= 3)  currentMaxAllowedLossUSD = InpDDLimit3to4Trades;  // $200
      else if(totalOpenPositions >= 1)  currentMaxAllowedLossUSD = InpDDLimit1to2Trades;  // $50

      // 1. Hard Dynamic Tiered USD Drawdown Cap ($50 to $500)
      if(currentMaxAllowedLossUSD > 0 && floatingLossUSD >= currentMaxAllowedLossUSD)
      {
         PrintFormat("[TIERED DD CUTOFF] Floating Loss $%.2f >= Dynamic Limit $%.2f (%d open trades)! Instant liquidation...", 
                     floatingLossUSD, currentMaxAllowedLossUSD, totalOpenPositions);
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
