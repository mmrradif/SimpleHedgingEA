//+------------------------------------------------------------------+
//|                                                     PincerEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Stationary Pending Grid EA with Buffer Gap          |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "14.00"
#property description "Stationary Ascending Pending Grid EA with Initial Buffer Gap & Profit Close"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid & Lot Settings ==="
input double   InpStartLot            = 0.10;     // Initial Starting Lot Size (0.10)
input double   InpLotStep             = 0.10;     // Lot Increase Step (0.10)
input double   InpMaxLotLimit         = 1.00;     // Max Lot Limit (1.00)
input int      InpBufferGapPoints     = 200;      // Initial Buffer Gap from Current Price (Points = 20 Pips)
input int      InpGridStepPoints      = 150;      // Distance Between Pending Levels (Points = 15 Pips)
input int      InpTakeProfitPoints    = 150;      // Individual Take Profit per Trade (Points)
input double   InpTargetProfitUSD     = 3.00;     // Target Average Profit per Basket ($3.00 Close All)
input bool     InpCancelOppositeStops = true;     // Auto-Cancel Opposite Pendings on Entry (Prevents Lock)
input double   InpMaxDrawdownPercent  = 30.0;     // Emergency Equity Protection (%)

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 999888;   // Magic Number
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

   PrintFormat("[INIT] Stationary Grid EA v14.0 Initialized. Buffer Gap: %d pts, Target: $%.2f", 
               InpBufferGapPoints, InpTargetProfitUSD);
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
   // 1. Emergency Equity Drawdown Protection Check
   if(CheckEquityProtection())
   {
      return;
   }

   // 2. Scan Trade Stats & Floating Profit
   int buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalProfitUSD = GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   // 3. AUTO OPPOSITE PENDING CANCELLATION (Prevents Lock Trap)
   if(InpCancelOppositeStops && totalOpenPositions > 0)
   {
      if(buyCount > 0 && sellStopCount > 0)
      {
         Print("[BUY TRIGGERED] Cancelling opposite SELL STOP pendings to allow clean profit run...");
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      }
      else if(sellCount > 0 && buyStopCount > 0)
      {
         Print("[SELL TRIGGERED] Cancelling opposite BUY STOP pendings to allow clean profit run...");
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      }
   }

   // 4. TARGET PROFIT CHECK -> CLOSE ALL POSITIONS & DELETE ALL PENDINGS -> RE-ARM
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [PROFIT TARGET REACHED] Total Profit: $%.2f >= $%.2f. Closing all & resetting...", 
                  totalProfitUSD, InpTargetProfitUSD);

      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      
      // Place fresh pending grid around new market price
      PlaceStationaryPendingStops();
      return;
   }

   // 5. PLACE INITIAL PENDING GRID (When NO positions and NO pendings exist)
   if(totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      Print("[GRID SETUP] Placing stationary Buy Stop & Sell Stop grid with buffer gap...");
      PlaceStationaryPendingStops();
   }
}

//+------------------------------------------------------------------+
//| Place Stationary 0.10 -> 1.00 Buy Stop & Sell Stop Grid          |
//+------------------------------------------------------------------+
void PlaceStationaryPendingStops()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   int bufferGap = InpBufferGapPoints;
   if(bufferGap < (int)stopLevel + 20)
   {
      bufferGap = (int)stopLevel + 20;
   }

   int stepCount = (int)MathRound((InpMaxLotLimit - InpStartLot) / InpLotStep) + 1;
   if(stepCount < 1) stepCount = 10;

   // 1. Place BUY STOP Grid with Buffer Gap (0.10, 0.20, 0.30 ... 1.00)
   for(int i = 1; i <= stepCount; i++)
   {
      double lot = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double price = NormalizeDouble(ask + (bufferGap * point) + ((i - 1) * InpGridStepPoints * point), _Digits);
      double tpPrice = (InpTakeProfitPoints > 0) ? NormalizeDouble(price + (InpTakeProfitPoints * point), _Digits) : 0;

      m_trade.BuyStop(lot, price, _Symbol, 0, tpPrice, ORDER_TIME_GTC, 0, "BuyStop Grid");
   }

   // 2. Place SELL STOP Grid with Buffer Gap (0.10, 0.20, 0.30 ... 1.00)
   for(int i = 1; i <= stepCount; i++)
   {
      double lot = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double price = NormalizeDouble(bid - (bufferGap * point) - ((i - 1) * InpGridStepPoints * point), _Digits);
      double tpPrice = (InpTakeProfitPoints > 0) ? NormalizeDouble(price - (InpTakeProfitPoints * point), _Digits) : 0;

      m_trade.SellStop(lot, price, _Symbol, 0, tpPrice, ORDER_TIME_GTC, 0, "SellStop Grid");
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
//| Bulletproof Guaranteed Position Close with Retry                 |
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
//| Bulletproof Guaranteed Pending Order Deletion with Retry         |
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
//| Get Open Trade Stats & Floating Profit                           |
//+------------------------------------------------------------------+
double GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount)
{
   buyCount = 0;
   sellCount = 0;
   buyStopCount = 0;
   sellStopCount = 0;
   double totalProfit = 0.0;

   // 1. Scan Open Positions
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0)
      {
         if(PositionGetString(POSITION_SYMBOL) == _Symbol && 
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         {
            totalProfit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            
            ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
            if(type == POSITION_TYPE_BUY) buyCount++;
            else if(type == POSITION_TYPE_SELL) sellCount++;
         }
      }
   }

   // 2. Scan Pending Orders
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0)
      {
         if(OrderGetString(ORDER_SYMBOL) == _Symbol && 
            OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
         {
            ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
            if(type == ORDER_TYPE_BUY_STOP) buyStopCount++;
            else if(type == ORDER_TYPE_SELL_STOP) sellStopCount++;
         }
      }
   }

   return totalProfit;
}

//+------------------------------------------------------------------+
//| Emergency Equity Protection Check                                |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(balance > 0)
   {
      double drawdownPercent = ((balance - equity) / balance) * 100.0;
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
