//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Confirmed Breakout Dual Grid EA (No SL, Zone-Based) |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "95.00"
#property description "Zone-Based Dual Grid: M15 Swing High/Low Zone Detection + ATR Breakout Confirmation (No SL, No False Breakouts)"

#include <Trade\Trade.mqh>

//--- Enums
enum ENUM_GRID_STATE
{
   GRID_STATE_EMPTY,
   GRID_STATE_WAITING_BUY_CONFIRM,
   GRID_STATE_WAITING_SELL_CONFIRM,
   GRID_STATE_PLACING_INITIAL,
   GRID_STATE_ACTIVE,
   GRID_STATE_CLEANING_BUY,
   GRID_STATE_CLEANING_SELL,
   GRID_STATE_CLEANING_ALL
};

//--- Input Parameters
input group "=== Zone Detection (M15 Swing) ==="
input int      InpSwingLookback       = 20;      // Swing High/Low Lookback (20 M15 Bars)
input double   InpATRMultiplier       = 0.50;    // Breakout Strength (Candle Body >= 0.5 x ATR14)
input int      InpATRPeriod           = 14;      // ATR Period

input group "=== Grid & Lot Settings ==="
input double   InpStartLot            = 0.01;    // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;    // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;     // Base Grid Step (150 Points = 15 Pips)
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
input double   InpMaxAllowedDrawdownUSD = 5000.0; // Max Allowed Drawdown ($5000.00)
input double   InpMaxDrawdownPercent    = 90.0;   // Emergency Equity Protection (%)
input bool     InpClosePendingsFriday   = true;   // Weekend Gap Guard

input group "=== Expert Settings ==="
input ulong    InpMagicNumber         = 888111;  // Magic Number
input ulong    InpSlippage            = 30;      // Max Slippage (Points)

//--- Global Variables
CTrade           m_trade;
ENUM_GRID_STATE  m_gridState;
int              m_buyGridPlacedCount;
int              m_sellGridPlacedCount;
bool             m_buySideClosed;
bool             m_sellSideClosed;
double           m_buyZonePrice;    // Detected resistance zone (confirmed breakout level)
double           m_sellZonePrice;   // Detected support zone (confirmed breakout level)
datetime         m_lastZoneScanTime;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("WARNING: Account is not Retail Hedging mode!");

   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   ResetStateMachine();

   PrintFormat("[INIT] v95.0 Confirmed Breakout Dual Grid EA. ATR Multiplier: %.1fx, Lookback: %d M15 bars",
               InpATRMultiplier, InpSwingLookback);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PrintFormat("[DEINIT] EA stopped. Reason: %d", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   //--- 1. Emergency drawdown check first
   if(CheckEquityProtection()) return;

   //--- 2. Friday weekend gap guard
   if(InpClosePendingsFriday && IsFridayNightClose())
   {
      DeleteOnePendingOrderPaced();
      return;
   }

   //--- 3. Collect stats
   int    buyCount = 0, sellCount = 0, buyStopCount = 0, sellStopCount = 0;
   double totalBuyLot = 0, totalSellLot = 0;
   double buyProfitUSD = 0, sellProfitUSD = 0;
   GetTradeStats(buyCount, sellCount, buyStopCount, sellStopCount,
                 totalBuyLot, totalSellLot, buyProfitUSD, sellProfitUSD);
   int totalOpenPositions = buyCount + sellCount;
   int totalPendingOrders = buyStopCount + sellStopCount;

   //--- 4. EOD: Close only if profitable at 21:55 BD Time
   if(InpEODProfitOnlyClose && IsEODCloseTime())
   {
      if(buyCount > 0 && buyProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD BUY PROFIT EXIT] Buy Profit: $%.2f", buyProfitUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      }
      if(sellCount > 0 && sellProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD SELL PROFIT EXIT] Sell Profit: $%.2f", sellProfitUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      }
      if(totalOpenPositions == 0)
         m_gridState = GRID_STATE_CLEANING_ALL;
      return;
   }

   //--- 5. BD Time schedule filter
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

   //--- 6. Clean pending orders states
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

   //--- 7. Per-side max loss cap (prevents accumulated loss beyond $50)
   if(InpMaxSideLossUSD > 0)
   {
      if(buyCount > 0 && buyProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [BUY SIDE MAX LOSS CUT] Buy Loss $%.2f >= $%.2f limit. Closing Buy side...", buyProfitUSD, -InpMaxSideLossUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
         DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
         m_buySideClosed = true;
         m_buyGridPlacedCount = 0;
         m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
         return;
      }
      if(sellCount > 0 && sellProfitUSD <= -InpMaxSideLossUSD)
      {
         PrintFormat(">>> [SELL SIDE MAX LOSS CUT] Sell Loss $%.2f >= $%.2f limit. Closing Sell side...", sellProfitUSD, -InpMaxSideLossUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
         DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
         m_sellSideClosed = true;
         m_sellGridPlacedCount = 0;
         m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
         return;
      }
   }

   //--- 8. Independent Buy-side profit exit
   if(buyCount > 0 && buyProfitUSD >= InpBuySideTargetUSD)
   {
      PrintFormat(">>> [BUY PROFIT EXIT] Buy Profit $%.2f >= $%.2f (%d buys). Closing Buy side...", buyProfitUSD, InpBuySideTargetUSD, buyCount);
      ClosePositionsByType(POSITION_TYPE_BUY);
      DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      m_buySideClosed = true;
      m_buyGridPlacedCount = 0;
      m_gridState = (sellCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_BUY;
      return;
   }

   //--- 9. Independent Sell-side profit exit
   if(sellCount > 0 && sellProfitUSD >= InpSellSideTargetUSD)
   {
      PrintFormat(">>> [SELL PROFIT EXIT] Sell Profit $%.2f >= $%.2f (%d sells). Closing Sell side...", sellProfitUSD, InpSellSideTargetUSD, sellCount);
      ClosePositionsByType(POSITION_TYPE_SELL);
      DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      m_sellSideClosed = true;
      m_sellGridPlacedCount = 0;
      m_gridState = (buyCount == 0) ? GRID_STATE_CLEANING_ALL : GRID_STATE_CLEANING_SELL;
      return;
   }

   //--- 10. Reset if both sides done
   if(m_buySideClosed && m_sellSideClosed && totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetStateMachine();
   }

   //--- 11. Only look for new setup when completely flat
   if(totalOpenPositions == 0 && totalPendingOrders == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      if(!InpUseTimeWindow || IsWithinBDTradingHours())
      {
         // Scan for confirmed breakout zones
         ScanAndConfirmZones();
      }
      return;
   }

   //--- 12. Place grid orders after zone confirmation (1 per tick)
   if(m_gridState == GRID_STATE_PLACING_INITIAL)
   {
      if(m_buyGridPlacedCount < 11 || m_sellGridPlacedCount < 11)
      {
         PlaceGridOrdersPaced();
         return;
      }
      else
      {
         m_gridState = GRID_STATE_ACTIVE;
      }
   }
}

//+------------------------------------------------------------------+
//| CORE: Scan M15 Swing Zones + Confirm Breakout Before Placing     |
//+------------------------------------------------------------------+
void ScanAndConfirmZones()
{
   // Don't scan too often - once per M15 bar close
   datetime currentBarTime = iTime(_Symbol, PERIOD_M15, 0);
   if(m_lastZoneScanTime == currentBarTime) return;
   m_lastZoneScanTime = currentBarTime;

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   //--- Get M15 swing high/low (last InpSwingLookback bars, skip current forming bar)
   double swingHigh = 0, swingLow = DBL_MAX;
   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);

   int copied = CopyHigh(_Symbol, PERIOD_M15, 1, InpSwingLookback, hi);
   int copiedL = CopyLow(_Symbol, PERIOD_M15, 1, InpSwingLookback, lo);

   if(copied <= 0 || copiedL <= 0) return;

   for(int i = 0; i < copied; i++) if(hi[i] > swingHigh) swingHigh = hi[i];
   for(int i = 0; i < copiedL; i++) if(lo[i] < swingLow)  swingLow  = lo[i];

   //--- Get ATR(14) on M15 to measure breakout strength
   double atrBuffer[];
   ArraySetAsSeries(atrBuffer, true);
   int atrHandle = iATR(_Symbol, PERIOD_M15, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE) return;
   if(CopyBuffer(atrHandle, 0, 1, 3, atrBuffer) <= 0)
   {
      IndicatorRelease(atrHandle);
      return;
   }
   double atr = atrBuffer[0]; // Last completed M15 bar ATR
   IndicatorRelease(atrHandle);

   if(atr <= 0) return;

   //--- Get last completed M15 candle body
   double closeArr[], openArr[];
   ArraySetAsSeries(closeArr, true);
   ArraySetAsSeries(openArr, true);
   CopyClose(_Symbol, PERIOD_M15, 1, 2, closeArr);
   CopyOpen(_Symbol, PERIOD_M15, 1, 2, openArr);

   double lastClose = closeArr[0];
   double lastOpen  = openArr[0];
   double lastBody  = MathAbs(lastClose - lastOpen); // Last completed M15 candle body size

   //--- CONFIRMED BUY BREAKOUT:
   //    Last M15 candle CLOSED ABOVE swing high AND body >= 0.5 * ATR
   //    This means genuine upside momentum, not just a wick touch
   if(lastClose > swingHigh && lastBody >= InpATRMultiplier * atr)
   {
      m_buyZonePrice = lastClose; // Place buy grid starting from confirmed breakout level
      m_sellZonePrice = 0;
      PrintFormat(">>> [BUY ZONE CONFIRMED] M15 Candle closed above swing high %.5f. Body: %.1f pips, ATR: %.1f pips. Placing 11 BuyStops...",
                  swingHigh, lastBody / point / 10, atr / point / 10);
      m_gridState = GRID_STATE_PLACING_INITIAL;
      return;
   }

   //--- CONFIRMED SELL BREAKOUT:
   //    Last M15 candle CLOSED BELOW swing low AND body >= 0.5 * ATR
   //    This means genuine downside momentum, not just a wick touch
   if(lastClose < swingLow && lastBody >= InpATRMultiplier * atr)
   {
      m_sellZonePrice = lastClose; // Place sell grid starting from confirmed breakdown level
      m_buyZonePrice = 0;
      PrintFormat(">>> [SELL ZONE CONFIRMED] M15 Candle closed below swing low %.5f. Body: %.1f pips, ATR: %.1f pips. Placing 11 SellStops...",
                  swingLow, lastBody / point / 10, atr / point / 10);
      m_gridState = GRID_STATE_PLACING_INITIAL;
      return;
   }

   // No confirmed breakout yet - wait
}

//+------------------------------------------------------------------+
//| Place grid orders (1 per tick, uses confirmed zone price)        |
//+------------------------------------------------------------------+
void PlaceGridOrdersPaced()
{
   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);

   if(ask <= 0 || bid <= 0 || point <= 0) return;

   // --- BUY GRID: Place 11 BuyStops above confirmed breakout zone
   if(m_buyZonePrice > 0 && m_buyGridPlacedCount < 11)
   {
      int    i      = m_buyGridPlacedCount + 1;
      double lot    = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double offset = (i - 1) * InpBaseGridStepPoints * point;
      double price  = NormalizeDouble(m_buyZonePrice + offset, _Digits);

      if(price > ask + stopLvl * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_BUY_STOP, lot, price, 0, 0, StringFormat("BuyZone #%d", i)))
            m_buyGridPlacedCount++;
      }
      else
      {
         // Price already past this level, skip
         m_buyGridPlacedCount++;
      }
      return;
   }

   // --- SELL GRID: Place 11 SellStops below confirmed breakdown zone
   if(m_sellZonePrice > 0 && m_sellGridPlacedCount < 11)
   {
      int    i      = m_sellGridPlacedCount + 1;
      double lot    = NormalizeLot(InpStartLot + (i - 1) * InpLotStep);
      double offset = (i - 1) * InpBaseGridStepPoints * point;
      double price  = NormalizeDouble(m_sellZonePrice - offset, _Digits);

      if(price < bid - stopLvl * point)
      {
         if(PlacePendingOrderSafe(ORDER_TYPE_SELL_STOP, lot, price, 0, 0, StringFormat("SellZone #%d", i)))
            m_sellGridPlacedCount++;
      }
      else
      {
         m_sellGridPlacedCount++;
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| EOD Close Time (21:55 BD Time)                                   |
//+------------------------------------------------------------------+
bool IsEODCloseTime()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   return (bdHour == 21 && dt.min >= 55);
}

//+------------------------------------------------------------------+
//| BD Time filter                                                   |
//+------------------------------------------------------------------+
bool IsWithinBDTradingHours()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   int bdHour = (dt.hour + InpBDtoServerDiffHours) % 24;
   if(InpBDStartHour <= InpBDEndHour)
      return (bdHour >= InpBDStartHour && bdHour < InpBDEndHour);
   else
      return (bdHour >= InpBDStartHour || bdHour < InpBDEndHour);
}

//+------------------------------------------------------------------+
//| Friday Night Close Check                                         |
//+------------------------------------------------------------------+
bool IsFridayNightClose()
{
   MqlDateTime dt;
   TimeCurrent(dt);
   return (dt.day_of_week == 5 && dt.hour >= 23 && dt.min >= 40);
}

//+------------------------------------------------------------------+
//| Reset State Machine                                              |
//+------------------------------------------------------------------+
void ResetStateMachine()
{
   m_gridState           = GRID_STATE_EMPTY;
   m_buyGridPlacedCount  = 0;
   m_sellGridPlacedCount = 0;
   m_buySideClosed       = false;
   m_sellSideClosed      = false;
   m_buyZonePrice        = 0;
   m_sellZonePrice       = 0;
   m_lastZoneScanTime    = 0;
}

//+------------------------------------------------------------------+
//| Paced single-order deletion                                      |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Delete pending orders by type                                    |
//+------------------------------------------------------------------+
void DeletePendingOrdersByType(ENUM_ORDER_TYPE targetType)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket > 0 && OrderGetString(ORDER_SYMBOL) == _Symbol && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber)
      {
         if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == targetType)
            m_trade.OrderDelete(ticket);
      }
   }
}

//+------------------------------------------------------------------+
//| Place pending order with multi-filling fallback                  |
//+------------------------------------------------------------------+
bool PlacePendingOrderSafe(ENUM_ORDER_TYPE orderType, double lot, double price, double sl, double tp, string comment)
{
   if(orderType == ORDER_TYPE_BUY_STOP)
      if(m_trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment)) return true;

   if(orderType == ORDER_TYPE_SELL_STOP)
      if(m_trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, comment)) return true;

   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_FOK, ORDER_FILLING_IOC, ORDER_FILLING_RETURN};
   for(int f = 0; f < 3; f++)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = _Symbol;
      req.volume       = lot;
      req.price        = price;
      req.sl           = sl;
      req.tp           = tp;
      req.type         = orderType;
      req.type_filling = fillings[f];
      req.type_time    = ORDER_TIME_GTC;
      req.deviation    = InpSlippage;
      req.magic        = InpMagicNumber;
      req.comment      = comment;
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close positions by type                                          |
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
         if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
            (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
         {
            ArrayResize(tickets, count + 1);
            tickets[count++] = ticket;
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
               if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE) break;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Close all positions                                              |
//+------------------------------------------------------------------+
void CloseAllPositionsGuaranteed()
{
   ClosePositionsByType(POSITION_TYPE_BUY);
   ClosePositionsByType(POSITION_TYPE_SELL);
}

//+------------------------------------------------------------------+
//| Delete all pending orders                                        |
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
            tickets[count++] = ticket;
         }
      }
      if(count == 0) return;
      for(int k = 0; k < count; k++) m_trade.OrderDelete(tickets[k]);
   }
}

//+------------------------------------------------------------------+
//| Get trade stats                                                  |
//+------------------------------------------------------------------+
void GetTradeStats(int &buyCount, int &sellCount, int &buyStopCount, int &sellStopCount,
                   double &totalBuyLot, double &totalSellLot,
                   double &buyProfitUSD, double &sellProfitUSD)
{
   buyCount = 0; sellCount = 0; buyStopCount = 0; sellStopCount = 0;
   totalBuyLot = 0; totalSellLot = 0; buyProfitUSD = 0; sellProfitUSD = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&
         PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      {
         double pft  = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol  = PositionGetDouble(POSITION_VOLUME);
         if(type == POSITION_TYPE_BUY)  { buyCount++;  totalBuyLot  += vol; buyProfitUSD  += pft; }
         else                           { sellCount++; totalSellLot += vol; sellProfitUSD += pft; }
      }
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
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

//+------------------------------------------------------------------+
//| Emergency equity protection                                      |
//+------------------------------------------------------------------+
bool CheckEquityProtection()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;

   double floatingLossUSD = balance - equity;
   double drawdownPct     = (floatingLossUSD / balance) * 100.0;

   if(InpMaxAllowedDrawdownUSD > 0 && floatingLossUSD >= InpMaxAllowedDrawdownUSD)
   {
      PrintFormat("[MAX DD CUTOFF] Loss $%.2f >= $%.2f! Emergency liquidation...", floatingLossUSD, InpMaxAllowedDrawdownUSD);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      ResetStateMachine();
      return true;
   }
   if(drawdownPct >= InpMaxDrawdownPercent)
   {
      PrintFormat("[EMERGENCY STOP] DD %.2f%% reached! Emergency liquidation...", drawdownPct);
      CloseAllPositionsGuaranteed();
      DeleteAllPendingOrdersGuaranteed();
      ResetStateMachine();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Normalize lot size                                               |
//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   lot = MathFloor(lot / lotStep) * lotStep;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}
//+------------------------------------------------------------------+
