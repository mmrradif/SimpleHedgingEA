//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
//|                                Copyright 2026, Antigravity AI    |
//|                                             https://www.mql5.com |
//| Description: Independent Buy/Sell Side Profit Exit Dual Grid EA  |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Antigravity AI"
#property link      "https://www.mql5.com"
#property version   "92.00"
#property description "Pure Dual Grid EA: Buy zone closes ONLY when Buy side is profitable, Sell zone closes ONLY when Sell side is profitable (100% Zero Hanging Trades)"

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
input double   InpStartLot            = 0.01;    // Initial Starting Lot (0.01)
input double   InpLotStep             = 0.01;    // Lot Increment Step (0.01)
input int      InpBaseGridStepPoints  = 150;     // Base Grid Step (150 Points = 15 Pips)
input double   InpBuySideTargetUSD    = 1.00;    // Buy Side Profit Target ($1.00 - Close Buys Only)
input double   InpSellSideTargetUSD   = 1.00;    // Sell Side Profit Target ($1.00 - Close Sells Only)

input group "=== Bangladesh Time Schedule (GMT+6) ==="
input bool     InpUseTimeWindow       = true;    // Enable Time Schedule Filter
input int      InpBDStartHour         = 7;       // Start Trading Hour (07:00 AM BD Time)
input int      InpBDEndHour           = 22;      // End Trading Hour (10:00 PM BD Time)
input int      InpBDtoServerDiffHours = 3;       // Hour Difference (BD GMT+6 minus Broker GMT+3 = 3 Hours)
input bool     InpEODProfitOnlyClose  = true;    // Night EOD Close ONLY IF PROFITABLE (Never at a loss)

input group "=== Risk Control & Drawdown Cap ==="
input double   InpMaxAllowedDrawdownUSD = 5000.0; // Maximum Allowed Drawdown ($5000.00)
input double   InpMaxDrawdownPercent    = 90.0;   // Emergency Equity Protection (%)
input bool     InpClosePendingsFriday   = true;   // Weekend Gap Guard (Friday 23:40 Pending Delete)

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

   PrintFormat("[INIT] v92.0 Independent Buy/Sell Side Profit Exit EA. BuyTarget: $%.2f, SellTarget: $%.2f, MaxDD: $%.2f",
               InpBuySideTargetUSD, InpSellSideTargetUSD, InpMaxAllowedDrawdownUSD);
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
   double totalProfitUSD  = buyProfitUSD + sellProfitUSD;

   //--- 4. EOD: Close ONLY if net profitable at 21:55 BD Time
   if(InpEODProfitOnlyClose && IsEODCloseTime())
   {
      if(buyCount > 0 && buyProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD BUY PROFIT EXIT] Buy Profit: $%.2f > $0.00. Closing Buy side...", buyProfitUSD);
         ClosePositionsByType(POSITION_TYPE_BUY);
      }
      if(sellCount > 0 && sellProfitUSD > 0.0)
      {
         PrintFormat(">>> [EOD SELL PROFIT EXIT] Sell Profit: $%.2f > $0.00. Closing Sell side...", sellProfitUSD);
         ClosePositionsByType(POSITION_TYPE_SELL);
      }
      // After EOD closes, clean pendings
      if(buyCount == 0 && sellCount == 0)
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
      // Positions open outside hours: still manage profit exits below
   }

   //--- 6. Clean pending orders state
   if(m_gridState == GRID_STATE_CLEANING_ALL ||
      m_gridState == GRID_STATE_CLEANING_BUY ||
      m_gridState == GRID_STATE_CLEANING_SELL)
   {
      if(totalPendingOrders > 0)
      {
         DeleteOnePendingOrderPaced();
         return;
      }
      // If both sides closed, fully reset
      if(totalOpenPositions == 0)
      {
         ResetStateMachine();
         return;
      }
      // If only one side was cleaned, continue in ACTIVE
      m_gridState = GRID_STATE_ACTIVE;
   }

   //------------------------------------------------------------------
   // 7. CORE LOGIC: INDEPENDENT BUY-SIDE PROFIT EXIT
   //    Buy positions close ONLY when BUY SIDE PROFIT >= BuyTarget
   //------------------------------------------------------------------
   if(buyCount > 0 && buyProfitUSD >= InpBuySideTargetUSD)
   {
      PrintFormat(">>> [BUY SIDE PROFIT EXIT!] Buy Profit $%.2f >= Target $%.2f (%d buys). Closing Buy side IN PROFIT...",
                  buyProfitUSD, InpBuySideTargetUSD, buyCount);
      ClosePositionsByType(POSITION_TYPE_BUY);
      // Delete remaining buy stop pendings
      DeletePendingOrdersByType(ORDER_TYPE_BUY_STOP);
      m_buySideClosed  = true;
      m_buyGridPlacedCount = 0;
      if(sellCount == 0)
         m_gridState = GRID_STATE_CLEANING_ALL;
      else
         m_gridState = GRID_STATE_CLEANING_BUY;
      return;
   }

   //------------------------------------------------------------------
   // 8. CORE LOGIC: INDEPENDENT SELL-SIDE PROFIT EXIT
   //    Sell positions close ONLY when SELL SIDE PROFIT >= SellTarget
   //------------------------------------------------------------------
   if(sellCount > 0 && sellProfitUSD >= InpSellSideTargetUSD)
   {
      PrintFormat(">>> [SELL SIDE PROFIT EXIT!] Sell Profit $%.2f >= Target $%.2f (%d sells). Closing Sell side IN PROFIT...",
                  sellProfitUSD, InpSellSideTargetUSD, sellCount);
      ClosePositionsByType(POSITION_TYPE_SELL);
      // Delete remaining sell stop pendings
      DeletePendingOrdersByType(ORDER_TYPE_SELL_STOP);
      m_sellSideClosed = true;
      m_sellGridPlacedCount = 0;
      if(buyCount == 0)
         m_gridState = GRID_STATE_CLEANING_ALL;
      else
         m_gridState = GRID_STATE_CLEANING_SELL;
      return;
   }

   //--- 9. Restart fresh grid when both sides closed
   if(m_buySideClosed && m_sellSideClosed && totalOpenPositions == 0 && totalPendingOrders == 0)
   {
      ResetStateMachine();
   }

   //--- 10. Start fresh grid placement
   if(totalOpenPositions == 0 && totalPendingOrders == 0 && m_gridState == GRID_STATE_EMPTY)
   {
      if(!InpUseTimeWindow || IsWithinBDTradingHours())
         m_gridState = GRID_STATE_PLACING_INITIAL;
   }

   //--- 11. Place 11 Buy Stops + 11 Sell Stops (1 order per tick)
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
   m_gridState          = GRID_STATE_EMPTY;
   m_buyGridPlacedCount  = 0;
   m_sellGridPlacedCount = 0;
   m_buySideClosed       = false;
   m_sellSideClosed      = false;
}

//+------------------------------------------------------------------+
//| Paced single-order deletion (1 per tick - anti-block)           |
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
//| Delete all pending orders of a specific type                     |
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
//| Setup paced initial dual grid (1 order per tick max)             |
//+------------------------------------------------------------------+
void SetupPacedInitialDualGrid()
{
   double m1High = 0, m1Low = 0;
   FindM1ZoneSafe(30, m1High, m1Low);

   double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopLvl  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   if(ask <= 0 || bid <= 0 || point <= 0) return;

   double buyBase  = MathMax(m1High, ask + (stopLvl + 15) * point);
   double sellBase = MathMin(m1Low,  bid - (stopLvl + 15) * point);

   // Place Buy Stop (1 per tick)
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
      {
         m_buyGridPlacedCount++;
      }
      return;
   }

   // Place Sell Stop (1 per tick)
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
      {
         m_sellGridPlacedCount++;
      }
      return;
   }
}

//+------------------------------------------------------------------+
//| Place pending order with multi-filling fallback                  |
//+------------------------------------------------------------------+
bool PlacePendingOrderSafe(ENUM_ORDER_TYPE orderType, double lot, double price, string comment)
{
   if(orderType == ORDER_TYPE_BUY_STOP)
      if(m_trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;

   if(orderType == ORDER_TYPE_SELL_STOP)
      if(m_trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment)) return true;

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
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| M1 Zone Detection                                                |
//+------------------------------------------------------------------+
void FindM1ZoneSafe(int lookback, double &m1High, double &m1Low)
{
   double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   m1High = ask + 40 * point;
   m1Low  = bid - 40 * point;
   if(lookback <= 0) return;

   double hi[], lo[];
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   int cH = CopyHigh(_Symbol, PERIOD_M1, 1, lookback, hi);
   int cL = CopyLow (_Symbol, PERIOD_M1, 1, lookback, lo);
   if(cH > 0 && cL > 0)
   {
      m1High = hi[0]; m1Low = lo[0];
      for(int i = 1; i < cH; i++) if(hi[i] > m1High) m1High = hi[i];
      for(int i = 1; i < cL; i++) if(lo[i] < m1Low)  m1Low  = lo[i];
   }
}

//+------------------------------------------------------------------+
//| Close positions by type (BUY or SELL)                            |
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
//| Get trade stats: counts, lots, and per-side profit               |
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
         double pft = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);
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
      PrintFormat("[MAX DD CUTOFF] Loss $%.2f >= $%.2f limit! Emergency liquidation...", floatingLossUSD, InpMaxAllowedDrawdownUSD);
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
