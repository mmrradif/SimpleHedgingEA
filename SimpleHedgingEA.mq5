//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: 9/21 EMA Trend-Filtered 20-Pip Offset Dual Grid EA  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "121.00"
#property description "EMA Trend-Filtered 20-Pip Offset Dual Grid EA: Combines 9/21 EMA Trend Filter with 20-Pip Offset Dual Grid ($5.00 Target, $5000 Max DD)"

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
input group "=== Trend & Direction Filter ==="
input bool     InpUseTrendFilter      = true;     // Enable 9/21 EMA Trend Filter (Trades ONLY in Trend Direction)
input int      InpFastEMAPeriod       = 9;        // Fast EMA Period (9)
input int      InpSlowEMAPeriod       = 21;       // Slow EMA Period (21)

input group "=== Grid & Lot Settings ==="
input int      InpZoneLookback        = 30;       // M1 Support/Resistance Lookback (30 M1 Candles)
input int      InpMaxGridLevels       = 11;       // Max Allowed Grid Levels (11 Levels)
input double   InpStartLot            = 0.01;     // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;     // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;      // Base Grid Step (150 Points = 15 Pips)
input int      InpSellOffsetFromBuy   = 200;      // Sell Grid Offset Below Buy Grid (200 Points = 20 Pips Below BuyStops)

input group "=== Profit Target Settings ==="
input double   InpTargetProfitUSD     = 5.00;     // Full Grid Basket Target Profit ($5.00)
input double   InpBuySideTargetUSD    = 5.00;     // Buy Side Target Profit ($5.00)
input double   InpSellSideTargetUSD   = 5.00;     // Sell Side Target Profit ($5.00)

input group "=== Total Max Drawdown Protection ==="
input double   InpMaxAllowedDrawdownUSD = 5000.0; // Total Account Maximum USD Drawdown ($5000.00)
input double   InpMaxDrawdownPercent    = 90.0;   // Emergency Equity Protection (%)

input group "=== Trading Schedule & Filters ==="
input bool     InpUseTimeWindow       = false;    // Enable Time Schedule Filter (Set false for 24/7 execution)
input int      InpBDStartHour         = 7;        // Start Trading Hour (07:00 AM BD Time)
input int      InpBDEndHour           = 22;       // End Trading Hour (10:00 PM BD Time)
input int      InpBDtoServerDiffHours = 3;        // Hour Difference (BD GMT+6 minus Broker GMT+3 = 3 Hours)
input bool     InpEODProfitOnlyClose  = false;    // Night EOD Close ONLY IF PROFITABLE
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
int              m_fastEmaHandle;
int              m_slowEmaHandle;

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

   PrintFormat("[INIT] EMA Trend-Filtered 20-Pip Offset Dual Grid EA v121.0 Initialized. Target: $%.2f, EMA Filter: %s", 
               InpTargetProfitUSD, InpUseTrendFilter ? "ENABLED (9/21 EMA)" : "DISABLED");
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

   // 3. TOTAL BASKET PROFIT EXIT ($5.00 TARGET)
   if(totalOpenPositions > 0 && totalProfitUSD >= InpTargetProfitUSD)
   {
      PrintFormat(">>> [TOTAL BASKET PROFIT EXIT!] Net Profit $%.2f >= Target $%.2f. Closing all positions IN PROFIT...", 
                  totalProfitUSD, InpTargetProfitUSD);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      ResetStateMachine();
      return;
   }

   // 4. INDEPENDENT BUY-SIDE PROFIT EXIT ($5.00 TARGET)
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

   // 5. INDEPENDENT SELL-SIDE PROFIT EXIT ($5.00 TARGET)
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

   // 6. RESTART FRESH GRID WHEN BOTH SIDES CLOSED
   if(m_buySideClosed && m_sellSideClosed && totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetStateMachine();
   }

   // 7. STATE: EMPTY STATE -> START PLACEMENT IMMEDIATELY
   if(totalOpenPositions == 0 && totalPendingOrders == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      if(!InpUseTimeWindow || IsWithinBDTradingHours())
      {
         m_gridState = GRID_STATE_PLACING_INITIAL;
      }
   }

   // 8. STATE: PACED PLACEMENT OF INITIAL DUAL GRID
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
//| Get Trend Direction via 9/21 EMA Alignment                       |
//| Returns: +1 for Bullish Uptrend, -1 for Bearish Downtrend, 0 Any |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   if(!InpUseTrendFilter) return 0; // Both directions allowed

   double fastEma[], slowEma[];
   ArraySetAsSeries(fastEma, true);
   ArraySetAsSeries(slowEma, true);

   if(CopyBuffer(m_fastEmaHandle, 0, 0, 2, fastEma) > 0 &&
      CopyBuffer(m_slowEmaHandle, 0, 0, 2, slowEma) > 0)
   {
      if(fastEma[0] > slowEma[0]) return 1;  // Bullish Uptrend -> BUY STOPS ONLY
      if(fastEma[0] < slowEma[0]) return -1; // Bearish Downtrend -> SELL STOPS ONLY
   }

   return 0;
}

//+------------------------------------------------------------------+
//| Setup EMA Trend-Filtered 20-Pip Offset Dual Grid                 |
//| BuyStops start AT M1 High                                       |
//| SellStops start EXACTLY 20 PIPS BELOW BuyStops                  |
//+------------------------------------------------------------------+
void SetupPacedInitialDualGrid()
{
   int trendDir = GetTrendDirection();

   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(InpZoneLookback, m1High, m1Low); // 30 M1 Candles High & Low

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stopLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   // Buy Base starts AT M1 High
   double buyBasePrice = MathMax(m1High, ask + (stopLevel + 15) * point);
   // Sell Base starts EXACTLY 20 Pips (200 Points) BELOW buyBasePrice
   double sellBasePrice = MathMin(buyBasePrice - InpSellOffsetFromBuy * point, bid - (stopLevel + 15) * point);

   // Place Buy Stops ONLY IF Trend is Bullish (+1) or Filter is OFF (0)
   if((trendDir >= 0) && m_buyGridPlacedCount < InpMaxGridLevels)
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
   else if(trendDir < 0 && m_buyGridPlacedCount < InpMaxGridLevels)
   {
      m_buyGridPlacedCount = InpMaxGridLevels; // Skip BuyStops in Downtrend
   }

   // Place Sell Stops ONLY IF Trend is Bearish (-1) or Filter is OFF (0)
   if((trendDir <= 0) && m_sellGridPlacedCount < InpMaxGridLevels)
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
   else if(trendDir > 0 && m_sellGridPlacedCount < InpMaxGridLevels)
   {
      m_sellGridPlacedCount = InpMaxGridLevels; // Skip SellStops in Uptrend
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
