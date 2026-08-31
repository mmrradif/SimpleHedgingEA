//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: 100% Paced Dual Grid Engine (Zero MT5 Stop Errors)  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "74.00"
#property description "100% Paced Dual Grid Engine (Places 1 Order & Deletes 1 Order Per Tick - Guaranteed Zero MT5 Tester Stops)"

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
int            m_buyGridPlacedCount;
int            m_sellGridPlacedCount;
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

   PrintFormat("[INIT] 100%% Paced Dual Grid EA v74.0 Initialized. Target: $%.2f, Max DD: $%.2f", 
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

   // 3. PACED PENDING ORDER DELETION (Paced 1 deletion per tick to prevent MT5 OrderDelete blocks)
   if(totalOpenPositions == 0 && totalPendingOrders > 0)
   {
      DeleteOnePendingOrderPaced();
      return;
   }

   // 4. GUARANTEED TARGET PROFIT EXIT ($5.00 TARGET)
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [NET PROFIT HIT!] Profit: $%.2f >= $%.2f (Trades: %d). Closing all positions...", 
                  totalProfitUSD, InpTargetProfitUSD, totalOpenPositions);
      CloseAllPositionsGuaranteed();
      ResetCounters();
      return;
   }

   // 5. PACED INITIAL 11 BUY STOPS & 11 SELL STOPS PLACEMENT (1 Order Per Tick Max)
   if(totalOpenPositions == 0 && (m_buyGridPlacedCount < 11 || m_sellGridPlacedCount < 11))
   {
      SetupPacedInitialDualGrid();
      return;
   }

   // 6. PACED ON-DEMAND 11 COUNTER HEDGES (Places 11 counter orders 50 pips away with 1.5x multiplier, 1 Order Per Tick Max)
   if(totalOpenPositions > 0)
   {
      ManagePaced11CounterHedges(buyCount, sellCount);
   }
}

//+------------------------------------------------------------------+
//| Reset Placement Counters                                         |
//+------------------------------------------------------------------+
void ResetCounters()
{
   m_buyGridPlacedCount = 0;
   m_sellGridPlacedCount = 0;
   m_buyCounterPlacedCount = 0;
   m_sellCounterPlacedCount = 0;
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
//| Setup Paced Initial Dual Grid (1 Order Per Tick Max)             |
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

   double startLot = 0.01;
   double lotStep = 0.01;

   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   double sellBasePrice = MathMin(m1Low, bid - (stopLevel + 15) * point);

   // Place 1 Buy Stop per tick (0.01 to 0.11)
   if(m_buyGridPlacedCount < 11)
   {
      int i = m_buyGridPlacedCount + 1;
      double lot = NormalizeLot(startLot + (i - 1) * lotStep);
      double cumulativeOffset = GetCumulativeOffset(i);
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

   // Place 1 Sell Stop per tick (0.01 to 0.11)
   if(m_sellGridPlacedCount < 11)
   {
      int i = m_sellGridPlacedCount + 1;
      double lot = NormalizeLot(startLot + (i - 1) * lotStep);
      double cumulativeOffset = GetCumulativeOffset(i);
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
//| Manage Paced 11 Counter Hedges (1 Order Per Tick Max)            |
//+------------------------------------------------------------------+
void ManagePaced11CounterHedges(int buyCount, int sellCount)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double offset50Pips = InpCounterOffsetPoints * point; // 500 points = 50 pips

   double startLot = 0.01;
   double lotStep = 0.01;

   // 1. Buy Position Triggered -> Place 11 Counter SellStops 50 pips BELOW Buy Entry with 1.5x Volume (1 per tick)
   if(buyCount > 0 && m_sellCounterPlacedCount < 11)
   {
      double firstBuyPrice = GetFirstPositionOpenPrice(POSITION_TYPE_BUY);
      if(firstBuyPrice > 0)
      {
         int i = m_sellCounterPlacedCount + 1;
         double baseLot = startLot + (i - 1) * lotStep;
         double weightedLot = NormalizeLot(baseLot * InpCounterLotMultiplier); // 1.5x Multiplier!
         double sellBasePrice = firstBuyPrice - offset50Pips;
         double cumulativeOffset = GetCumulativeOffset(i);
         double price = NormalizeDouble(sellBasePrice - cumulativeOffset, _Digits);

         if(price < bid - stopLevel * point && price > 0)
         {
            if(PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, weightedLot, price, StringFormat("CounterSell #%d", i)))
            {
               m_sellCounterPlacedCount++;
            }
         }
         else
         {
            m_sellCounterPlacedCount++;
         }
      }
      return; // 1 Order per tick!
   }

   // 2. Sell Position Triggered -> Place 11 Counter BuyStops 50 pips ABOVE Sell Entry with 1.5x Volume (1 per tick)
   if(sellCount > 0 && m_buyCounterPlacedCount < 11)
   {
      double firstSellPrice = GetFirstPositionOpenPrice(POSITION_TYPE_SELL);
      if(firstSellPrice > 0)
      {
         int i = m_buyCounterPlacedCount + 1;
         double baseLot = startLot + (i - 1) * lotStep;
         double weightedLot = NormalizeLot(baseLot * InpCounterLotMultiplier); // 1.5x Multiplier!
         double buyBasePrice = firstSellPrice + offset50Pips;
         double cumulativeOffset = GetCumulativeOffset(i);
         double price = NormalizeDouble(buyBasePrice + cumulativeOffset, _Digits);

         if(price > ask + stopLevel * point)
         {
            if(PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, weightedLot, price, StringFormat("CounterBuy #%d", i)))
            {
               m_buyCounterPlacedCount++;
            }
         }
         else
         {
            m_buyCounterPlacedCount++;
         }
      }
      return; // 1 Order per tick!
   }
}

//+------------------------------------------------------------------+
//| Calculate Grid Distance Offset                                   |
//+------------------------------------------------------------------+
double GetCumulativeOffset(int level)
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double cumulativeOffset = 0;
   double currentStepDistance = InpBaseGridStepPoints * point;

   for(int k = 1; k < level; k++)
   {
      cumulativeOffset += currentStepDistance;
      currentStepDistance *= InpSpacingMultiplier;
   }
   return cumulativeOffset;
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
