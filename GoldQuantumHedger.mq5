//+------------------------------------------------------------------+
//|                                           GoldQuantumHedger.mq5 |
//|          Copyright 2026, Dual 10+10 Dynamic Recovery Grid        |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Dual 10+10 Dynamic Recovery Grid"
#property link      "https://www.mql5.com"
#property version   "5.00-TURBO"
#property description "GoldQuantumHedger v5.0: 10+10 Pre-Armed Grid with Dynamic Reverse Recalculation & Rapid $15-$20 Basket TP Reset."

#include <Trade\Trade.mqh>

//--- Profit Settings ------------------------------------------------
input group "=== Quantum Profit Engine ==="
input double   InpBasketProfitUSD     = 15.00;  // Target Basket Take Profit ($15.00 USD)
input bool     InpUseTrailingNet      = true;   // Trailing Profit Lock for Mega Runners
input double   InpTrailPeakMinUSD     = 12.00;  // Trailing Start Trigger ($12.00 USD)
input double   InpTrailDropRatio      = 0.20;   // Trailing Lock Ratio (Locks 80% of Peak Gain)

//--- Grid Architecture ----------------------------------------------
input group "=== 10+10 Grid Settings ==="
input int      InpGridLevelsPerSide   = 10;     // Grid Levels Per Side (10 BuyStops + 10 SellStops)
input double   InpBaseLot             = 0.05;   // Base Lot Size (0.05 for High Daily Profits)
input double   InpGridStepUSD         = 2.50;   // Grid Step Spacing ($2.50 Gold Move Per Step)
input double   InpRecoveryMultiplier  = 2.00;   // Reverse Recovery Lot Multiplier (2.0x Squeeze)
input double   InpMaxLotPerOrder      = 0.50;   // Hard Lot Cap Per Single Order (0.50)
input bool     InpUseATR              = true;   // ATR Volatility Adaptive Spacing
input int      InpAtrPeriod           = 14;     // ATR Period
input double   InpAtrMult             = 1.0;    // ATR Step Multiplier

//--- Protection & Speed ---------------------------------------------
input group "=== Protection & System Controls ==="
input int      InpCooldownSec         = 2;      // Cooldown After Basket Exit (Sec)
input double   InpWideSpreadPrice     = 1.00;   // Wide Spread News Shield ($1.00 USD)
input ulong    InpMagicNumber         = 777888; // Unique Quantum Magic Number
input ulong    InpSlippage            = 50;     // Execution Slippage Tolerance
input bool     InpShowVisual          = true;   // Interactive Dashboard

#define VIS_PREFIX "QuantumTurboGrid_"

//--- System State Variables -----------------------------------------
CTrade   m_trade;
int      m_atrHandle;
string   m_state;
double   m_peakNet;
datetime m_cooldownUntil;
datetime m_closedBarTime;
bool     m_closingInProgress;
int      m_lastOpenBuys;
int      m_lastOpenSells;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   m_trade.LogLevel(LOG_LEVEL_ERRORS);

   m_atrHandle = iATR(_Symbol, PERIOD_M1, MathMax(InpAtrPeriod, 2));

   ResetState();
   m_closingInProgress = false;
   m_cooldownUntil     = 0;
   m_closedBarTime     = 0;
   m_lastOpenBuys      = 0;
   m_lastOpenSells     = 0;

   PrintFormat("[QUANTUM TURBO INIT] Magic=%u | BasketTP=$%.2f | BaseLot=%.2f | Levels=%d+%d | Step=$%.2f",
               InpMagicNumber, InpBasketProfitUSD, InpBaseLot, InpGridLevelsPerSide, InpGridLevelsPerSide, InpGridStepUSD);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(m_atrHandle != INVALID_HANDLE)
      IndicatorRelease(m_atrHandle);
   ObjectsDeleteAll(0, VIS_PREFIX);
   Comment("");
}

//+------------------------------------------------------------------+
//| Reset system state                                               |
//+------------------------------------------------------------------+
void ResetState()
{
   m_state         = "IDLE";
   m_peakNet       = -1e9;
   m_lastOpenBuys  = 0;
   m_lastOpenSells = 0;
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
   int    buys = 0, sells = 0, buyPend = 0, sellPend = 0;
   double buyLot = 0, sellLot = 0, buyPft = 0, sellPft = 0;
   double net = Scan(buys, sells, buyPend, sellPend, buyLot, sellLot, buyPft, sellPft);
   int    pos = buys + sells;

   // Closing in progress
   if(m_closingInProgress)
   {
      ProcessCloseAll();
      DrawDashboard();
      return;
   }

   //=== PHASE 0: FLAT (NO OPEN POSITIONS) =============================
   if(pos == 0)
   {
      if(TimeCurrent() < m_cooldownUntil)
      {
         m_state = "COOLDOWN PAUSE";
         DrawDashboard();
         return;
      }

      int totalWanted = InpGridLevelsPerSide * 2;
      if(buyPend + sellPend == 0)
      {
         if(WideSpread())
         {
            m_state = "WIDE SPREAD NEWS PAUSE";
            DrawDashboard();
            return;
         }

         ResetState();
         PrintFormat("[QUANTUM TURBO ARM] Placing Initial %d BuyStops (%.2f L) + %d SellStops (%.2f L)",
                     InpGridLevelsPerSide, InpBaseLot, InpGridLevelsPerSide, InpBaseLot);

         ArmInitialGrid();
         m_state = StringFormat("ARMED: %d BuyStops + %d SellStops Standing @ %.2f Lot", 
                                InpGridLevelsPerSide, InpGridLevelsPerSide, InpBaseLot);
         DrawDashboard();
         return;
      }

      m_state = StringFormat("ARMED: %d BuyStops + %d SellStops Standing", buyPend, sellPend);
      DrawDashboard();
      return;
   }

   //=== PHASE 1: PROFIT TARGET CHECK & GLOBAL CLOSE ===================
   double target = InpBasketProfitUSD;
   if(buys > 0 && sells > 0)
   {
      int totalLegs = buys + sells;
      if(totalLegs >= 6)      target = 3.00;
      else if(totalLegs >= 3) target = 8.00;
   }

   // Profit Reached -> GLOBAL CLOSE & RE-ARM
   if(net >= target)
   {
      PrintFormat(">>> [QUANTUM TURBO TP HIT] Net $%.2f >= Target $%.2f — CLOSING ALL & RE-ARMING FRESH 10+10!", net, target);
      m_closingInProgress = true;
      m_closedBarTime     = iTime(_Symbol, _Period, 0);
      ProcessCloseAll();
      DrawDashboard();
      return;
   }

   // Trailing Runner Lock
   if(InpUseTrailingNet && net > 0)
   {
      if(net > m_peakNet) m_peakNet = net;
      if(m_peakNet >= InpTrailPeakMinUSD)
      {
         double giveback = (m_peakNet - target * 0.50) * InpTrailDropRatio;
         double stopNet  = m_peakNet - giveback;
         if(stopNet < target * 0.50) stopNet = target * 0.50;
         if(net <= stopNet)
         {
            PrintFormat(">>> [QUANTUM TURBO TRAIL LOCK] Peak $%.2f -> Locked at $%.2f (Now $%.2f) — CLOSING ALL",
                        m_peakNet, stopNet, net);
            m_closingInProgress = true;
            m_closedBarTime     = iTime(_Symbol, _Period, 0);
            ProcessCloseAll();
            DrawDashboard();
            return;
         }
      }
   }

   //=== PHASE 2: DYNAMIC REVERSE GRID RE-ARMING =======================
   // When a new Buy order triggers (and no Sells yet):
   if(buys > 0 && sells == 0 && buys != m_lastOpenBuys)
   {
      m_lastOpenBuys = buys;
      double recLot = CalcReverseLot(buyLot);
      double lowBuy = LowestEntry(POSITION_TYPE_BUY);
      double anchorPrice = lowBuy - DynamicStep();

      PrintFormat("[REVERSE RECALCULATE] %d Buys Open (%.2f L) -> Rebuilding 10 SellStops @ %.2f Lot each below %.3f",
                  buys, buyLot, recLot, anchorPrice);

      RebuildReverseGrid(ORDER_TYPE_SELL_STOP, recLot, anchorPrice);
   }
   // When a new Sell order triggers (and no Buys yet):
   else if(sells > 0 && buys == 0 && sells != m_lastOpenSells)
   {
      m_lastOpenSells = sells;
      double recLot = CalcReverseLot(sellLot);
      double highSell = HighestEntry(POSITION_TYPE_SELL);
      double anchorPrice = highSell + DynamicStep();

      PrintFormat("[REVERSE RECALCULATE] %d Sells Open (%.2f L) -> Rebuilding 10 BuyStops @ %.2f Lot each above %.3f",
                  sells, sellLot, recLot, anchorPrice);

      RebuildReverseGrid(ORDER_TYPE_BUY_STOP, recLot, anchorPrice);
   }

   m_state = StringFormat("TURBO GRID ACTIVE: %d pos (Buy: %.2f L | Sell: %.2f L) | Net $%.2f / Target $%.2f",
                          pos, buyLot, sellLot, net, target);
   DrawDashboard();
}

//+------------------------------------------------------------------+
//| Calculate Dynamic Reverse Recovery Lot Size                      |
//+------------------------------------------------------------------+
double CalcReverseLot(double activeSideVolume)
{
   double lot = activeSideVolume * InpRecoveryMultiplier / InpGridLevelsPerSide;
   if(lot < InpBaseLot * 1.5) lot = InpBaseLot * 1.5;
   if(InpMaxLotPerOrder > 0 && lot > InpMaxLotPerOrder)
      lot = InpMaxLotPerOrder;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Arm Initial 10 BuyStop + 10 SellStop Grid (Same Base Lot)        |
//+------------------------------------------------------------------+
void ArmInitialGrid()
{
   DeleteAllPendings();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   double step = DynamicStep();
   double minDist = MinDistance();

   // Place 10 BuyStops
   for(int i = 0; i < InpGridLevelsPerSide; i++)
   {
      double price = ask + step * (i + 1);
      if(price < ask + minDist) price = ask + minDist + (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      price = NormalizeDouble(price, _Digits);

      double lot = NormalizeLot(InpBaseLot);
      SendPendingSafe(ORDER_TYPE_BUY_STOP, lot, price, StringFormat("BuyStop #%d", i + 1));
   }

   // Place 10 SellStops
   for(int i = 0; i < InpGridLevelsPerSide; i++)
   {
      double price = bid - step * (i + 1);
      if(price > bid - minDist) price = bid - minDist - (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      price = NormalizeDouble(price, _Digits);

      double lot = NormalizeLot(InpBaseLot);
      SendPendingSafe(ORDER_TYPE_SELL_STOP, lot, price, StringFormat("SellStop #%d", i + 1));
   }
}

//+------------------------------------------------------------------+
//| Rebuild Reverse Grid with New Calculated Recovery Lot            |
//+------------------------------------------------------------------+
void RebuildReverseGrid(ENUM_ORDER_TYPE reverseType, double recLot, double startAnchorPrice)
{
   DeletePendingsByType(reverseType);

   double step    = DynamicStep();
   double minDist = MinDistance();
   double ask     = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid     = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   for(int i = 0; i < InpGridLevelsPerSide; i++)
   {
      double price = 0.0;
      if(reverseType == ORDER_TYPE_SELL_STOP)
      {
         price = startAnchorPrice - step * i;
         if(price > bid - minDist) price = bid - minDist - (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      }
      else
      {
         price = startAnchorPrice + step * i;
         if(price < ask + minDist) price = ask + minDist + (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      }
      price = NormalizeDouble(price, _Digits);

      SendPendingSafe(reverseType, recLot, price, StringFormat("Recovery #%d", i + 1));
   }
}

//+------------------------------------------------------------------+
//| Scan Active Positions & Orders                                   |
//+------------------------------------------------------------------+
double Scan(int &buys, int &sells, int &buyPend, int &sellPend,
            double &buyLot, double &sellLot, double &buyPft, double &sellPft)
{
   buys = 0; sells = 0; buyPend = 0; sellPend = 0;
   buyLot = 0.0; sellLot = 0.0; buyPft = 0.0; sellPft = 0.0;
   double net = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double prof = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      net += prof;
      if(type == POSITION_TYPE_BUY)  { buys++;  buyLot  += vol; buyPft  += prof; }
      else                           { sells++; sellLot += vol; sellPft += prof; }
   }

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(type == ORDER_TYPE_BUY_STOP)   buyPend++;
      else if(type == ORDER_TYPE_SELL_STOP) sellPend++;
   }
   return net;
}

//+------------------------------------------------------------------+
//| Check if position belongs to this EA                             |
//+------------------------------------------------------------------+
bool OursPos(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Safe Pending Order Dispatch                                      |
//+------------------------------------------------------------------+
bool SendPendingSafe(ENUM_ORDER_TYPE type, double lot, double price, string comment)
{
   MqlTradeRequest req; MqlTradeResult res;
   ZeroMemory(req); ZeroMemory(res);

   req.action       = TRADE_ACTION_PENDING;
   req.symbol       = _Symbol;
   req.volume       = lot;
   req.type         = type;
   req.price        = price;
   req.magic        = InpMagicNumber;
   req.deviation    = InpSlippage;
   req.type_filling = ORDER_FILLING_RETURN;
   req.comment      = comment;

   if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
      return true;

   return false;
}

//+------------------------------------------------------------------+
//| Delete all pending stop orders                                   |
//+------------------------------------------------------------------+
void DeleteAllPendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      m_trade.OrderDelete(t);
   }
}

void DeletePendingsByType(ENUM_ORDER_TYPE type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
         m_trade.OrderDelete(t);
   }
}

//+------------------------------------------------------------------+
//| Process Global Close & Chart Cleanup                             |
//+------------------------------------------------------------------+
void ProcessCloseAll()
{
   DeleteAllPendings();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(OursPos(t)) m_trade.PositionClose(t);
   }

   int remaining = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(OursPos(t)) remaining++;
   }

   if(remaining == 0)
   {
      DeleteAllPendings();
      m_closingInProgress = false;
      m_cooldownUntil     = TimeCurrent() + InpCooldownSec;
      ResetState();
   }
}

//+------------------------------------------------------------------+
//| Helper Extremes                                                  |
//+------------------------------------------------------------------+
double LowestEntry(ENUM_POSITION_TYPE type)
{
   double l = 1e9;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
      {
         double p = PositionGetDouble(POSITION_PRICE_OPEN);
         if(p < l) l = p;
      }
   }
   return (l == 1e9) ? 0.0 : l;
}

double HighestEntry(ENUM_POSITION_TYPE type)
{
   double h = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
      {
         double p = PositionGetDouble(POSITION_PRICE_OPEN);
         if(p > h) h = p;
      }
   }
   return h;
}

//+------------------------------------------------------------------+
//| Dynamic Step Size (ATR-Adaptive)                                 |
//+------------------------------------------------------------------+
double DynamicStep()
{
   double step = InpGridStepUSD;
   if(InpUseATR && m_atrHandle != INVALID_HANDLE)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_atrHandle, 0, 0, 1, atr) > 0)
      {
         double dynamicVal = atr[0] * InpAtrMult;
         if(dynamicVal > step) step = dynamicVal;
      }
   }
   return step;
}

//+------------------------------------------------------------------+
//| Minimum broker distance                                          |
//+------------------------------------------------------------------+
double MinDistance()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(stops + 10, 30) * point;
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
   if(minLot <= 0) minLot = 0.01;
   lot = MathRound((lot - minLot) / lotStep) * lotStep + minLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
//| Wide spread check                                                |
//+------------------------------------------------------------------+
bool WideSpread()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return ((ask - bid) > InpWideSpreadPrice);
}

//+------------------------------------------------------------------+
//| Interactive Dashboard                                            |
//+------------------------------------------------------------------+
void DrawDashboard()
{
   if(!InpShowVisual) return;
   int    buys = 0, sells = 0, bp = 0, sp = 0;
   double bl = 0, sl = 0, bpft = 0, spft = 0;
   double net = Scan(buys, sells, bp, sp, bl, sl, bpft, spft);

   string text = StringFormat(
      "\n  ═════════════════════════════════════════════════════════" +
      "\n   🚀 GOLD QUANTUM HEDGER v5.0 (DUAL 10+10 TURBO GRID)" +
      "\n  ═════════════════════════════════════════════════════════" +
      "\n   Status:     %s" +
      "\n   Positions:  %d Active (Buy: %.2f L | Sell: %.2f L)" +
      "\n   Pendings:   %d Orders (BuyStops: %d | SellStops: %d)" +
      "\n   Net PnL:    $%.2f USD" +
      "\n   Target TP:  $%.2f USD" +
      "\n   Base Lot:   %.2f Lot" +
      "\n  ═════════════════════════════════════════════════════════",
      m_state, buys + sells, bl, sl, bp + sp, bp, sp, net, InpBasketProfitUSD, InpBaseLot);

   Comment(text);
}

//+------------------------------------------------------------------+
//| Tester result function                                           |
//+------------------------------------------------------------------+
double OnTester()
{
   double profit = TesterStatistics(STAT_PROFIT);
   double grossProfit = TesterStatistics(STAT_GROSS_PROFIT);
   double grossLoss = TesterStatistics(STAT_GROSS_LOSS);
   double profitFactor = (grossLoss != 0.0) ? (grossProfit / MathAbs(grossLoss)) : 0.0;
   int trades = (int)TesterStatistics(STAT_TRADES);
   int won = (int)TesterStatistics(STAT_PROFIT_TRADES);
   int lost = (int)TesterStatistics(STAT_LOSS_TRADES);
   double winRate = (trades > 0) ? ((double)won / (double)trades * 100.0) : 0.0;
   double initialDeposit = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double equityDD = TesterStatistics(STAT_EQUITY_DD);
   double equityDDPct = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double balanceDD = TesterStatistics(STAT_BALANCE_DD);
   double balanceDDPct = TesterStatistics(STAT_BALANCEDD_PERCENT);
   double minMarginLevel = TesterStatistics(STAT_MIN_MARGINLEVEL);

   Print("========== QUANTUM TURBO GRID SUMMARY ==========");
   PrintFormat("[STAT] deposit=%.2f  final=%.2f  netProfit=%.2f  (%.2f%%)",
               initialDeposit, initialDeposit + profit, profit, (initialDeposit > 0 ? profit / initialDeposit * 100.0 : 0));
   PrintFormat("[STAT] grossProfit=%.2f  grossLoss=%.2f  profitFactor=%.2f",
               grossProfit, grossLoss, profitFactor);
   PrintFormat("[STAT] trades=%d  won=%d  lost=%d  winRate=%.1f%%",
               trades, won, lost, winRate);
   PrintFormat("[STAT] equityDD=%.2f (%.2f%%)  balanceDD=%.2f (%.2f%%)",
               equityDD, equityDDPct, balanceDD, balanceDDPct);
   PrintFormat("[STAT] minMarginLevel=%.1f%%", minMarginLevel);
   Print("================================================");

   return profit;
}
//+------------------------------------------------------------------+
