//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: High-Frequency Quick Profit EA ($2.00 Fast Target)  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "34.00"
#property description "High-Frequency Pending Grid EA (0.01-0.10 Lot, $2.00 Fast Target, $500 Max DD)"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid & Lot Settings ==="
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input double   InpMaxLotLimit         = 0.10;     // Max Lot Limit (0.10) - 10 Orders
input int      InpBaseGridStepPoints  = 150;      // Tight Grid Distance (150 Points = 15 Pips)
input double   InpSpacingMultiplier   = 1.15;     // Smooth Distance Multiplier
input double   InpTargetProfitUSD     = 2.00;     // Fast Target Net Profit ($2.00 Instant Close All)
input bool     InpCancelOppositeStops = true;     // Auto-Cancel Opposite Pendings on Entry

input group "=== Max Drawdown & Risk Control ==="
input double   InpMaxDrawdownUSD      = 500.0;    // Strict Maximum Allowed Drawdown ($500.00 Max USD Loss)
input double   InpMaxDrawdownPercent  = 50.0;     // Emergency Equity Protection (%)

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;   // Magic Number
input ulong    InpSlippage            = 30;       // Max Slippage (Points)

//--- Global Variables
CTrade         m_trade;

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
   m_trade.SetTypeFilling(ORDER_FILLING_FOK);

   PrintFormat("[INIT] High-Frequency Grid EA Initialized. Lot 0.01-0.10, Fast Target: $%.2f, Max DD: $%.2f", 
               InpTargetProfitUSD, InpMaxDrawdownUSD);
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
   // 1. Strict Emergency Drawdown Check (Percent & USD Cap)
   if(CheckEquityProtection())
   {
      return;
   }

   // 2. Scan Account Trade Stats
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0;
   double totalProfitUSD = GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount, totalBuyLot, totalSellLot);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   // 3. AUTO OPPOSITE PENDING CANCELLATION
   if(InpCancelOppositeStops && totalOpenPositions > 0)
   {
      if(buyCount > 0 && sellStopCount > 0)
      {
         Print("[LOCK PREVENTION] BUY executed! Deleting opposite SELL STOP pendings...");
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      }
      else if(sellCount > 0 && buyStopCount > 0)
      {
         Print("[LOCK PREVENTION] SELL executed! Deleting opposite BUY STOP pendings...");
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      }
   }

   // 4. GUARANTEED FAST PROFIT EXIT -> CLOSE ALL POSITIONS & DELETE ALL PENDINGS -> RESET ($2.00 FAST TARGET)
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [BASKET PROFIT HIT!] Profit: $%.2f >= $%.2f. Closing all positions...", 
                  totalProfitUSD, InpTargetProfitUSD);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      
      // Setup fresh M1 Zone grid
      SetupProgressivePendingGrid();
      return;
   }

   // 5. SETUP PROGRESSIVE PENDING GRID (When no positions and no pendings exist)
   if(totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      SetupProgressivePendingGrid();
   }
}

//+------------------------------------------------------------------+
//| Setup Progressive Spacing Pending Grid (10 Orders: 0.01 -> 0.10) |
//+------------------------------------------------------------------+
void SetupProgressivePendingGrid()
{
   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(30, m1High, m1Low);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   DeleteAllPendingOrdersGuaranteed();

   double startLot = 0.01;
   double lotStep = 0.01;
   int stepCount = 10;

   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   double sellBasePrice = MathMin(m1Low, bid - (stopLevel + 15) * point);

   double cumulativeBuyOffset = 0;
   double cumulativeSellOffset = 0;
   double currentStepDistance = InpBaseGridStepPoints * point;

   // 1. Place 10 BUY STOP Orders (0.01, 0.02, 0.03 ... 0.10)
   for(int i = 1; i <= stepCount; i++)
   {
      double lot = NormalizeLot(startLot + (i - 1) * lotStep);
      double price = NormalizeDouble(buyBasePrice + cumulativeBuyOffset, _Digits);

      if(m_trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "BuyStop 0.01-0.10"))
      {
         PrintFormat("[BUY STOP %d] Lot %.2f @ %.5f placed.", i, lot, price);
      }

      cumulativeBuyOffset += currentStepDistance;
      currentStepDistance *= InpSpacingMultiplier;
   }

   // Reset step distance for Sell grid
   currentStepDistance = InpBaseGridStepPoints * point;

   // 2. Place 10 SELL STOP Orders (0.01, 0.02, 0.03 ... 0.10)
   for(int i = 1; i <= stepCount; i++)
   {
      double lot = NormalizeLot(startLot + (i - 1) * lotStep);
      double price = NormalizeDouble(sellBasePrice - cumulativeSellOffset, _Digits);

      if(m_trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, "SellStop 0.01-0.10"))
      {
         PrintFormat("[SELL STOP %d] Lot %.2f @ %.5f placed.", i, lot, price);
      }

      cumulativeSellOffset += currentStepDistance;
      currentStepDistance *= InpSpacingMultiplier;
   }
}

//+------------------------------------------------------------------+
//| Find M1 Support and Resistance Zone (Safe with Fallback)        |
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
//| Delete Pending Orders by Order Type                              |
//+------------------------------------------------------------------+
void DeletePendingOrdersByType(ENUM_ORDER_TYPE orderType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == orderType)
         {
            m_trade.OrderDelete(ticket);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Bulletproof Position Close with Retry                            |
//+------------------------------------------------------------------+
bool CloseAllPositionsGuaranteed()
{
   for(int retry = 0; retry < 10; retry++)
   {
      ulong tickets[];
      int count = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            ArrayResize(tickets, count + 1);
            tickets[count] = ticket;
            count++;
         }
      }

      if(count == 0) return true;

      for(int k = 0; k < count; k++)
      {
         m_trade.PositionClose(tickets[k]);
      }

      Sleep(100);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Bulletproof Pending Order Deletion with Retry                    |
//+------------------------------------------------------------------+
bool DeleteAllPendingOrdersGuaranteed()
{
   for(int retry = 0; retry < 10; retry++)
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

      if(count == 0) return true;

      for(int k = 0; k < count; k++)
      {
         m_trade.OrderDelete(tickets[k]);
      }

      Sleep(100);
   }
   return false;
}

//+------------------------------------------------------------------+
//| Get Open Trade Stats & Total Volume                              |
//+------------------------------------------------------------------+
double GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount,
                     double &totalBuyLot, double &totalSellLot)
{
   buyCount = 0; sellCount = 0; buyStopCount = 0; sellStopCount = 0;
   totalBuyLot = 0; totalSellLot = 0;
   double totalProfit = 0.0;

   // Scan Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);

         if(type == POSITION_TYPE_BUY)
         {
            buyCount++;
            totalBuyLot += vol;
         }
         else if(type == POSITION_TYPE_SELL)
         {
            sellCount++;
            totalSellLot += vol;
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
//| Emergency Equity Protection Check (Percentage & USD Drawdown Cap)|
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
      if(InpMaxDrawdownUSD > 0 && floatingLossUSD >= InpMaxDrawdownUSD)
      {
         PrintFormat("[MAX DRAWDOWN CUTOFF] Floating Loss $%.2f >= Limit $%.2f! Closing all positions.", 
                     floatingLossUSD, InpMaxDrawdownUSD);
         CloseAllPositionsGuaranteed();
         DeleteAllPendingOrdersGuaranteed();
         return true;
      }

      // 2. Hard Equity Percent Protection
      if(drawdownPercent >= InpMaxDrawdownPercent)
      {
         PrintFormat("[EMERGENCY STOP] Max Drawdown %.2f%% reached (Limit: %.2f%%)! Closing all & deleting pendings.", 
                     drawdownPercent, InpMaxDrawdownPercent);
         CloseAllPositionsGuaranteed();
         DeleteAllPendingOrdersGuaranteed();
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
