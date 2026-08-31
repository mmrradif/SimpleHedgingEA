//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Fibonacci Expanding Grid Spacing Dual Grid EA       |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "138.00"
#property description "Fibonacci Expanding Grid EA: Uses Fibonacci sequence (1, 1, 2, 3, 5, 8, 13...) for grid level spacing to expand gaps during spikes, keeping drawdown ultra-low ($0.50/0.01 lot target, $5000 Max DD)"

#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_GRID_STATE
{
   GRID_STATE_EMPTY,
   GRID_STATE_PLACING_INITIAL,
   GRID_STATE_ACTIVE,
   GRID_STATE_CLEANING_ALL
};

//--- Input Parameters
input group "=== Basket Profit Target Settings ==="
input double   InpProfitPerMicroLot   = 0.50;     // Profit Target per 0.01 Lot ($0.50 USD = 5 Pips Fast Exit)
input double   InpMinBasketTargetUSD  = 0.50;     // Minimum Target Profit for Single 0.01 Trade ($0.50)
input double   InpMaxBasketTargetUSD  = 5.00;     // Maximum Cap Target Profit ($5.00)

input group "=== Trend & Direction Filter ==="
input bool     InpUseTrendFilter      = true;     // Enable 9/21 EMA Trend Direction Bias
input int      InpFastEMAPeriod       = 9;        // Fast EMA Period (9)
input int      InpSlowEMAPeriod       = 21;       // Slow EMA Period (21)

input group "=== Fibonacci Expanding Grid & Lot Settings ==="
input int      InpZoneLookback        = 30;       // M1 Support/Resistance Lookback (30 M1 Candles)
input int      InpMaxGridLevels       = 11;       // Max Allowed Grid Levels (11 Levels)
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input int      InpBaseFiboStepPoints  = 300;      // Base Fibo Step (300 Points = 30 Pips Base Gap)
input int      InpReversalOffsetPoints = 300;     // Reversal Pending Offset (300 Points = 30 Pips Offset)
input double   InpMaxTotalVolumeCapLot = 3.96;    // Hard Total Volume Cap (3.96 Lots = 6 Full Cycles Cap)

input group "=== Total Max Drawdown Protection ==="
input double   InpMaxAllowedDrawdownUSD = 5000.0; // Total Account Maximum USD Drawdown ($5000.00)
input double   InpMaxDrawdownPercent    = 90.0;   // Emergency Equity Protection (%)

input group "=== BD Time Schedule & EOD Liquidation ==="
input bool     InpUseTimeWindow       = true;     // Enable Time Schedule Filter (True for BD Time Window)
input int      InpBDStartHour         = 8;        // Start Trading Hour (08:00 AM BD Time)
input int      InpBDEndHour           = 20;       // End Trading Hour (08:00 PM BD Time / 20:00 BD Time)
input int      InpBDtoServerDiffHours = 3;        // Hour Difference (BD GMT+6 minus Broker GMT+3 = 3 Hours)
input bool     InpEODProfitOnlyClose  = true;     // Night EOD Close AT 08:00 PM ONLY IF PROFITABLE / BREAKEVEN

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;   // Magic Number
input ulong    InpSlippage            = 30;       // Max Slippage (Points)

//--- Global Variables
CTrade           m_trade;
ENUM_GRID_STATE  m_gridState;
int              m_fastEmaHandle;
int              m_slowEmaHandle;

//--- Fibonacci Multiplier Table (1, 1, 2, 3, 5, 8, 13, 21, 34, 55, 89)
const double g_fiboSeq[] = {1.0, 1.0, 2.0, 3.0, 5.0, 8.0, 13.0, 21.0, 34.0, 55.0, 89.0};

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
   
   // Initialize EMA Indicators
   m_fastEmaHandle = iMA(_Symbol, PERIOD_M1, InpFastEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
   m_slowEmaHandle = iMA(_Symbol, PERIOD_M1, InpSlowEMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

   ResetStateMachine();

   PrintFormat("[INIT] Fibonacci Expanding Grid EA v138.0 Initialized. Base Step: %d Points, Max DD: $%.2f", 
               InpBaseFiboStepPoints, InpMaxAllowedDrawdownUSD);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(m_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(m_fastEmaHandle);
   if(m_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(m_slowEmaHandle);
   PrintFormat("[DEINIT] EA Deinitialized. Reason code: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. Strict Emergency Drawdown Check ($5000.00 Total DD Cap)
   if(CheckEquityProtection())
   {
      return;
   }

   // 2. Scan Account Trade Stats
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0;
   double buyProfitUSD = 0, sellProfitUSD = 0;
   double totalProfitUSD = GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount, totalBuyLot, totalSellLot, buyProfitUSD, sellProfitUSD);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   // 3. DYNAMIC PROPORTIONAL PROFIT SCALING ($0.50 PER 0.01 LOT COMBINED)
   double totalLot = totalBuyLot + totalSellLot;
   double dynamicTargetUSD = InpMinBasketTargetUSD;
   if(totalLot > 0)
   {
      dynamicTargetUSD = NormalizeDouble((totalLot / 0.01) * InpProfitPerMicroLot, 2);
      if(dynamicTargetUSD < InpMinBasketTargetUSD) dynamicTargetUSD = InpMinBasketTargetUSD;
      if(dynamicTargetUSD > InpMaxBasketTargetUSD) dynamicTargetUSD = InpMaxBasketTargetUSD;
   }

   // 4. COMBINED NET BASKET PROFIT EXIT (ALL BUY & SELL TRADES CLOSED TOGETHER IN PROFIT)
   if(totalOpenPositions > 0 && totalProfitUSD >= dynamicTargetUSD)
   {
      PrintFormat(">>> [TOTAL COMBINED NET BASKET EXIT!] Net Combined Profit $%.2f >= Dynamic Target $%.2f (Total Lot: %.2f). Liquidating all positions IN PROFIT...", 
                  totalProfitUSD, dynamicTargetUSD, totalLot);
      CloseAllPositionsGuaranteed();      // CLOSE ALL BUY AND SELL POSITIONS TOGETHER!
      DeleteAllPendingOrdersGuaranteed(); // DELETE ALL PENDING ORDERS!
      ResetStateMachine();
      return;
   }

   // 5. BANGLADESH TIME NIGHT EOD CLEAN CLOSE AT 08:00 PM (20:00 BD Time)
   if(InpUseTimeWindow && IsEODCloseTime())
   {
      if(totalOpenPositions > 0 && totalProfitUSD >= 0.0) // ONLY IF PROFITABLE OR BREAKEVEN
      {
         PrintFormat(">>> [EOD NIGHT CLOSE 08:00 PM BD TIME] Net Profit $%.2f. Closing all positions & pendings clean...", totalProfitUSD);
         CloseAllPositionsGuaranteed();
         DeleteAllPendingOrdersGuaranteed();
         ResetStateMachine();
         return;
      }
      else if(totalOpenPositions == 0 && totalPendingOrders > 0)
      {
         DeleteAllPendingOrdersGuaranteed();
         return;
      }
   }

   // 6. CONTINUOUS FIBONACCI REFILL CONTROLLED WITHIN BD TRADING HOURS (08:00 AM - 08:00 PM BD TIME)
   if((!InpUseTimeWindow || IsWithinBDTradingHours()) && totalLot < InpMaxTotalVolumeCapLot)
   {
      RefillMissingPendingStopsPaced(buyStopCount, sellStopCount, totalLot);
   }
   else if(InpUseTimeWindow && !IsWithinBDTradingHours() && totalOpenPositions == 0 && totalPendingOrders > 0)
   {
      // Delete all pendings outside BD trading hours so no pending hangs overnight
      DeleteAllPendingOrdersGuaranteed();
   }
}

//+------------------------------------------------------------------+
//| Get Cumulative Fibonacci Offset Points for Level N (1-Indexed)   |
//+------------------------------------------------------------------+
double GetFiboCumulativeOffsetPoints(int levelIndex)
{
   if(levelIndex <= 1) return 0;
   double cumulativeFiboUnits = 0.0;
   for(int k = 0; k < levelIndex - 1; k++)
   {
      int seqIdx = (k < 11) ? k : 10;
      cumulativeFiboUnits += g_fiboSeq[seqIdx];
   }
   return cumulativeFiboUnits * InpBaseFiboStepPoints;
}

//+------------------------------------------------------------------+
//| Check if current BD time is EOD Liquidation Time (20:00 BD Time) |
//+------------------------------------------------------------------+
bool IsEODCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   return (bdHour >= 20 && dt.min >= 0);
}

//+------------------------------------------------------------------+
//| Convert Broker Time to BD Time & Check Hours (08:00 AM - 20:00 PM)|
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
//| Get Trend Direction via 9/21 EMA Alignment                       |
//| Returns: +1 for Bullish Uptrend, -1 for Bearish Downtrend, 0 Any |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   if(!InpUseTrendFilter) return 0;

   double fastEma[], slowEma[];
   ArraySetAsSeries(fastEma, true);
   ArraySetAsSeries(slowEma, true);

   if(CopyBuffer(m_fastEmaHandle, 0, 0, 2, fastEma) > 0 &&
      CopyBuffer(m_slowEmaHandle, 0, 0, 2, slowEma) > 0)
   {
      if(fastEma[0] > slowEma[0]) return 1;  // Bullish Uptrend
      if(fastEma[0] < slowEma[0]) return -1; // Bearish Downtrend
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Refill Missing Pending Stops with FIBONACCI Expanding Spacing   |
//+------------------------------------------------------------------+
void RefillMissingPendingStopsPaced(int activeBuyStops, int activeSellStops, double currentTotalLot)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   int trendDir = GetTrendDirection();

   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(InpZoneLookback, m1High, m1Low); // 30 M1 Candles High & Low

   double buyBasePrice = (trendDir >= 0) ? MathMax(m1High, ask + (stopLevel + 15) * point) : MathMax(ask + (stopLevel + 15) * point, bid + (InpReversalOffsetPoints + 15) * point);
   double sellBasePrice = (trendDir >= 0) ? MathMin(buyBasePrice - InpReversalOffsetPoints * point, bid - (stopLevel + 15) * point) : MathMin(m1Low, bid - (stopLevel + 15) * point);

   // Refill BuyStops with FIBONACCI Expanding Spacing (Inverted lot order 0.11 -> 0.01)
   if(activeBuyStops < InpMaxGridLevels && currentTotalLot < InpMaxTotalVolumeCapLot)
   {
      int levelIndex = activeBuyStops + 1;
      double lot = NormalizeLot(InpStartLot + (InpMaxGridLevels - levelIndex) * InpLotStep);
      double cumulativeOffsetPoints = GetFiboCumulativeOffsetPoints(levelIndex); // Fibonacci Expanding Gap!
      double price = NormalizeDouble(buyBasePrice + cumulativeOffsetPoints * point, _Digits);

      if(price > ask + stopLevel * point)
      {
         PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, lot, price, StringFormat("BuyFiboRefill #%d", levelIndex));
      }
      return; // 1 Order per tick!
   }

   // Refill SellStops with FIBONACCI Expanding Spacing (Inverted lot order 0.11 -> 0.01)
   if(activeSellStops < InpMaxGridLevels && currentTotalLot < InpMaxTotalVolumeCapLot)
   {
      int levelIndex = activeSellStops + 1;
      double lot = NormalizeLot(InpStartLot + (InpMaxGridLevels - levelIndex) * InpLotStep);
      double cumulativeOffsetPoints = GetFiboCumulativeOffsetPoints(levelIndex); // Fibonacci Expanding Gap!
      double price = NormalizeDouble(sellBasePrice - cumulativeOffsetPoints * point, _Digits);

      if(price < bid - stopLevel * point)
      {
         PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, lot, price, StringFormat("SellFiboRefill #%d", levelIndex));
      }
      return; // 1 Order per tick!
   }
}

//+------------------------------------------------------------------+
//| Reset State Machine Counters                                     |
//+------------------------------------------------------------------+
void ResetStateMachine()
{
   m_gridState = GRID_STATE_EMPTY;
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
//| Close All Open Positions Guaranteed                              |
//+------------------------------------------------------------------+
void CloseAllPositionsGuaranteed()
{
   ClosePositionsByType(POSITION_TYPE_BUY);
   ClosePositionsByType(POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Delete All Pending Orders Guaranteed                             |
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
//| TOTAL MAXIMUM ALLOWED USD DRAWDOWN CAP CHECK ($5000.00 LIMIT)    |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance > 0)
   {
      double floatingLossUSD = balance - equity;
      double drawdownPercent = (floatingLossUSD / balance) * 100.0;

      // 1. Total Account Max USD Drawdown Cap ($5000.00)
      if(InpMaxAllowedDrawdownUSD > 0 && floatingLossUSD >= InpMaxAllowedDrawdownUSD)
      {
         PrintFormat("[MAX DRAWDOWN CUTOFF] Floating Loss $%.2f >= Limit $%.2f! Instant liquidation...", 
                     floatingLossUSD, InpMaxAllowedDrawdownUSD);
         CloseAllPositionsGuaranteed();    // CLOSE OPEN POSITIONS FIRST IN MILLISECONDS!
         DeleteAllPendingOrdersGuaranteed(); // THEN DELETE PENDINGS
         ResetStateMachine();
         return true;
      }

      // 2. Hard Equity Percent Protection (90%)
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
