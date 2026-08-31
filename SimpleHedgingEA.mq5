//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: 1.5x Weighted 11-Counter Hedging Grid EA           |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "73.00"
#property description "1.5x Weighted 11-Counter Hedging Grid EA (Places 11 Counter Pendings 50 Pips Away with 1.5x Lot Multiplier When Position Opens)"

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== Grid & Lot Settings ==="
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input double   InpCounterLotMultiplier= 1.50;     // Counter Hedge Lot Multiplier (1.5x)
input int      InpBaseGridStepPoints  = 250;      // Base Grid Distance Between Levels (250 Points = 25 Pips)
input double   InpSpacingMultiplier   = 1.18;     // Distance Multiplier
input int      InpCounterOffsetPoints = 500;      // Counter Hedge Offset (500 Points = 50 Pips Below/Above Entry)
input double   InpTargetProfitUSD     = 5.00;     // Target Net Basket Profit ($5.00 Close All)

input group "=== Risk Control & Drawdown Cap ==="
input double   InpMaxDrawdownUSD      = 500.0;    // Strict Maximum Allowed Drawdown ($500.00 Max USD Loss)
input double   InpMaxDrawdownPercent  = 50.0;     // Emergency Equity Protection (%)

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;   // Magic Number
input ulong    InpSlippage            = 30;       // Max Slippage (Points)

//--- Global Variables
CTrade         m_trade;
int            m_buyCounterPlacedCount;
int            m_sellCounterPlacedCount;

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
   
   ResetCounters();

   PrintFormat("[INIT] 1.5x Weighted 11-Counter Grid EA v73.0 Initialized. Target: $%.2f, Max DD: $%.2f", 
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
   // 1. Strict Emergency Drawdown Check (POSITIONS CLOSED FIRST IN MILLISECONDS!)
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

   // Reset tracking counters when no positions and no pendings exist
   if(totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetCounters();
   }

   // 3. GUARANTEED TARGET PROFIT EXIT ($5.00 TARGET)
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [NET PROFIT HIT!] Profit: $%.2f >= $%.2f (Trades: %d). Closing all positions...", 
                  totalProfitUSD, InpTargetProfitUSD, totalOpenPositions);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      ResetCounters();
      return;
   }

   // 4. SETUP INITIAL 11 BUY STOPS & 11 SELL STOPS (When no positions & pendings exist)
   if(totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      SetupInitialDualGrid();
   }

   // 5. ON-DEMAND 11 COUNTER HEDGES (Places 11 counter orders 50 pips away with 1.5x multiplier)
   if(totalOpenPositions > 0)
   {
      Manage11CounterHedges(buyCount, sellCount);
   }
}

//+------------------------------------------------------------------+
//| Reset Placement Counters                                         |
//+------------------------------------------------------------------+
void ResetCounters()
{
   m_buyCounterPlacedCount = 0;
   m_sellCounterPlacedCount = 0;
}

//+------------------------------------------------------------------+
//| Setup Initial Dual Grid (11 BuyStops & 11 SellStops)             |
//+------------------------------------------------------------------+
void SetupInitialDualGrid()
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
   int stepCount = 11;

   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   double sellBasePrice = MathMin(m1Low, bid - (stopLevel + 15) * point);

   double cumulativeBuyOffset = 0;
   double cumulativeSellOffset = 0;
   double currentStepDistance = InpBaseGridStepPoints * point;

   for(int i = 1; i <= stepCount; i++)
   {
      double lot = NormalizeLot(startLot + (i - 1) * lotStep);

      // --- Buy Stop Grid (Going Up: 0.01 -> 0.11) ---
      double mainBuyPrice = NormalizeDouble(buyBasePrice + cumulativeBuyOffset, _Digits);
      if(mainBuyPrice > ask + stopLevel * point)
      {
         PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, lot, mainBuyPrice, StringFormat("BuyZone #%d", i));
      }

      // --- Sell Stop Grid (Going Down: 0.01 -> 0.11) ---
      double mainSellPrice = NormalizeDouble(sellBasePrice - cumulativeSellOffset, _Digits);
      if(mainSellPrice < bid - stopLevel * point)
      {
         PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, lot, mainSellPrice, StringFormat("SellZone #%d", i));
      }

      cumulativeBuyOffset += currentStepDistance;
      cumulativeSellOffset += currentStepDistance;
      currentStepDistance *= InpSpacingMultiplier;
   }
}

//+------------------------------------------------------------------+
//| Manage 11 Counter Hedges (50 Pips Away, 1.5x Volume Multiplier)  |
//+------------------------------------------------------------------+
void Manage11CounterHedges(int buyCount, int sellCount)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double offset50Pips = InpCounterOffsetPoints * point; // 500 points = 50 pips

   double startLot = 0.01;
   double lotStep = 0.01;
   int stepCount = 11;

   // 1. Buy Position Triggered -> Place 11 Counter SellStops 50 pips BELOW Buy Entry with 1.5x Volume
   if(buyCount > 0 && m_sellCounterPlacedCount < stepCount)
   {
      double firstBuyPrice = GetFirstPositionOpenPrice(POSITION_TYPE_BUY);
      if(firstBuyPrice > 0)
      {
         double sellBasePrice = firstBuyPrice - offset50Pips;
         double cumulativeOffset = 0;
         double currentStepDistance = InpBaseGridStepPoints * point;

         for(int i = 1; i <= stepCount; i++)
         {
            double baseLot = startLot + (i - 1) * lotStep;
            double weightedLot = NormalizeLot(baseLot * InpCounterLotMultiplier); // 1.5x Multiplier!
            double price = NormalizeDouble(sellBasePrice - cumulativeOffset, _Digits);

            if(price < bid - stopLevel * point && price > 0)
            {
               PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, weightedLot, price, StringFormat("CounterSell #%d", i));
            }
            cumulativeOffset += currentStepDistance;
            currentStepDistance *= InpSpacingMultiplier;
         }
         m_sellCounterPlacedCount = stepCount;
      }
   }

   // 2. Sell Position Triggered -> Place 11 Counter BuyStops 50 pips ABOVE Sell Entry with 1.5x Volume
   if(sellCount > 0 && m_buyCounterPlacedCount < stepCount)
   {
      double firstSellPrice = GetFirstPositionOpenPrice(POSITION_TYPE_SELL);
      if(firstSellPrice > 0)
      {
         double buyBasePrice = firstSellPrice + offset50Pips;
         double cumulativeOffset = 0;
         double currentStepDistance = InpBaseGridStepPoints * point;

         for(int i = 1; i <= stepCount; i++)
         {
            double baseLot = startLot + (i - 1) * lotStep;
            double weightedLot = NormalizeLot(baseLot * InpCounterLotMultiplier); // 1.5x Multiplier!
            double price = NormalizeDouble(buyBasePrice + cumulativeOffset, _Digits);

            if(price > ask + stopLevel * point)
            {
               PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, weightedLot, price, StringFormat("CounterBuy #%d", i));
            }
            cumulativeOffset += currentStepDistance;
            currentStepDistance *= InpSpacingMultiplier;
         }
         m_buyCounterPlacedCount = stepCount;
      }
   }
}

//+------------------------------------------------------------------+
//| Get First Open Position Price by Type                            |
//+------------------------------------------------------------------+
double GetFirstPositionOpenPrice(ENUM_POSITION_TYPE posType)
{
   for(int i = 0; i < PositionsTotal(); i++)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         {
            return PositionGetDouble(POSITION_PRICE_OPEN);
         }
      }
   }
   return 0.0;
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
//| Bulletproof Position Close (NO SLEEP LOOPS!)                     |
//+------------------------------------------------------------------+
bool CloseAllPositionsGuaranteed()
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
            ArrayResize(tickets, count + 1);
            tickets[count] = ticket;
            count++;
         }
      }

      if(count == 0) return true;

      for(int k = 0; k < count; k++)
      {
         if(!m_trade.PositionClose(tickets[k]))
         {
            PositionSelectByTicket(tickets[k]);
            ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
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
   return false;
}

//+------------------------------------------------------------------+
//| Bulletproof Pending Order Deletion (NO SLEEP LOOPS!)             |
//+------------------------------------------------------------------+
bool DeleteAllPendingOrdersGuaranteed()
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

      if(count == 0) return true;

      for(int k = 0; k < count; k++)
      {
         m_trade.OrderDelete(tickets[k]);
      }
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
      if(InpMaxDrawdownUSD > 0 && floatingLossUSD >= InpMaxDrawdownUSD)
      {
         PrintFormat("[MAX DRAWDOWN CUTOFF] Floating Loss $%.2f >= Limit $%.2f! Instant liquidation...", 
                     floatingLossUSD, InpMaxDrawdownUSD);
         CloseAllPositionsGuaranteed();    // CLOSE OPEN POSITIONS FIRST IN MILLISECONDS!
         DeleteAllPendingOrdersGuaranteed(); // THEN DELETE PENDINGS
         ResetCounters();
         return true;
      }

      // 2. Hard Equity Percent Protection
      if(drawdownPercent >= InpMaxDrawdownPercent)
      {
         PrintFormat("[EMERGENCY STOP] Max Drawdown %.2f%% reached! Instant liquidation...", drawdownPercent);
         CloseAllPositionsGuaranteed();    // CLOSE OPEN POSITIONS FIRST IN MILLISECONDS!
         DeleteAllPendingOrdersGuaranteed(); // THEN DELETE PENDINGS
         ResetCounters();
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
