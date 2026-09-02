//+------------------------------------------------------------------+
//|                                           GoldQuantumHedger.mq5 |
//|                                  Copyright 2026, Quantum Hedger |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Quantum Hedger"
#property link      "https://www.mql5.com"
#property version   "1.00"
#property description "GoldQuantumHedger: Ultra High-Profit Autonomous Breakout & Dynamic Asymmetric Recovery EA for XAUUSD."

#include <Trade\Trade.mqh>

//--- Profit Settings ------------------------------------------------
input group "=== Quantum Profit Engine ==="
input double   InpCloseProfitUSD      = 5.00;   // Target Profit ($5.00 USD Scalp)
input bool     InpUseBasketTP         = true;   // Global Shared Basket TP
input bool     InpScaleTPWithLegs     = true;   // Dynamic TP Scaling with Recovery Depth
input double   InpTPScaleFactor       = 0.50;   // TP Boost Factor Per Leg

//--- Trend Riding / Runner Lock -------------------------------------
input group "=== Runner Acceleration ==="
input bool     InpTrendRide           = true;   // Runner Riding Mode
input double   InpTrendMinPeak        = 3.00;   // Trailing Start Trigger ($ USD)
input double   InpTrendTrailRatio     = 0.25;   // Trailing Profit Lock Ratio (25%)

//--- Initial Grid Settings ------------------------------------------
input group "=== Initial Entry Settings ==="
input double   InpStartLot            = 0.01;   // Base Initial Lot (0.01)
input int      InpMaxGridLevels       = 1;      // Standing Grid Stops (1 BuyStop + 1 SellStop)
input double   InpGridStepUSD         = 3.80;   // Grid Step Distance ($3.80 Gold Move)
input bool     InpUseATR              = true;   // Dynamic ATR Volatility Expansion
input int      InpAtrPeriod           = 14;     // ATR Period
input double   InpAtrMult             = 1.2;    // ATR Volatility Multiplier

//--- Asymmetric Recovery Engine -------------------------------------
input group "=== Quantum Asymmetric Recovery ==="
input double   InpFirstTriggerUSD     = 4.00;   // 1st Leg Recovery Trigger ($4.00)
input double   InpReverseTriggerUSD   = 6.00;   // 2nd+ Leg Recovery Trigger ($6.00)
input int      InpReverseAfterSec     = 300;    // Time Trigger Backup (Sec)
input double   InpReverseDistUSD      = 4.00;   // Recovery Stop Distance ($4.00)
input double   InpRecoverMoveUSD      = 3.50;   // Fast Recovery Distance Target ($3.50)
input bool     InpBeyondAllEntries    = true;   // Wide Range Multi-Leg Spacing
input double   InpMaxLot              = 0.35;   // Maximum Dominant Lot Cap (0.35)
input int      InpMaxRecoveryLegs     = 10;     // Maximum Recovery Layers

//--- Protection & Rapid Escape --------------------------------------
input group "=== Safety & Rapid Escape ==="
input bool     InpOneTradePerTick     = true;   // One Trade Per Tick Protection
input int      InpCooldownSec         = 5;      // Cooldown After Basket Close (Sec)
input bool     InpUseTrailingNet      = true;   // Basket Trailing Net Lock
input double   InpTrailingNetRatio    = 0.35;   // Basket Trailing Lock Ratio
input bool     InpHedgeFastExit       = true;   // Rapid Hedged Escape (Instant $0.50-$1.00 exit)
input double   InpSpreadPad           = 2.5;    // Spread Padding Factor
input double   InpWideSpreadPrice     = 1.00;   // Wide Spread News Shield ($1.00 USD)
input double   InpGapUSD              = 15.0;   // Gap Protection Trigger ($ USD)
input ulong    InpMagicNumber         = 777888; // Unique Quantum Magic Number
input ulong    InpSlippage            = 50;     // Execution Slippage Tolerance
input bool     InpShowVisual          = true;   // Interactive Chart Dashboard

#define VIS_PREFIX "QuantumVis_"

//--- System State Variables -----------------------------------------
CTrade   m_trade;
int      m_atrHandle;
string   m_state;
string   m_phase;
double   m_basketTP;
double   m_prevTotalLots;
int      m_prevPosCount;
double   m_trendPeakNet;
datetime m_closedBarTime;
datetime m_cooldownUntil;
datetime m_armRetryUntil;
bool     m_gapMode;
bool     m_closingInProgress;
bool     m_placeAfterClose;
double   m_recoverTrailPeak;
datetime m_recoveryArmedAt;

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

   ResetCycleState();
   m_closingInProgress = false;
   m_placeAfterClose   = false;
   m_cooldownUntil     = 0;
   m_closedBarTime     = 0;
   m_gapMode           = false;
   m_armRetryUntil     = 0;
   m_prevPosCount      = CountPos();

   PrintFormat("[QUANTUM INIT] v1.00 Magic=%u | BasketTP=$%.2f | FirstTrigger=$%.2f | MaxLot=%.2f",
               InpMagicNumber, InpCloseProfitUSD, InpFirstTriggerUSD, InpMaxLot);

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
//| Reset cycle state                                                |
//+------------------------------------------------------------------+
void ResetCycleState()
{
   m_phase            = "IDLE";
   m_state            = "IDLE";
   m_basketTP         = 0.0;
   m_prevTotalLots    = 0.0;
   m_trendPeakNet     = -1e9;
   m_recoverTrailPeak = -1e9;
   m_recoveryArmedAt  = 0;
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
      ProcessClose();
      DrawVisual();
      return;
   }

   // Detect Gap
   CheckGapCondition();

   //=== PHASE 0: FLAT (NO POSITIONS) ==================================
   if(pos == 0)
   {
      if(m_placeAfterClose)
      {
         DeletePendings();
         m_placeAfterClose = false;
         m_prevPosCount = 0;
         Print("[QUANTUM CYCLE CLOSED] Basket TP Hit! Leftovers cleaned.");
         DrawVisual();
         return;
      }

      if(TimeCurrent() < m_cooldownUntil)
      {
         m_state = "COOLDOWN";
         DrawVisual();
         return;
      }

      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(m_closedBarTime != 0 && currentBarTime == m_closedBarTime)
      {
         m_state = "WAITING FOR NEXT CANDLE";
         DrawVisual();
         return;
      }

      ResetCycleState();

      int wanted = MathMax(InpMaxGridLevels, 1) * 2;
      if(buyPend + sellPend == 0)
      {
         if(TimeCurrent() < m_armRetryUntil)
         {
            m_state = "ARM RETRY BACKOFF";
            DrawVisual();
            return;
         }
         if(WideSpread() || m_gapMode)
         {
            m_state = m_gapMode ? "GAP — not arming" : "WIDE SPREAD — not arming";
            DrawVisual();
            return;
         }
         PrintFormat("[QUANTUM ARM] 1 BuyStop + 1 SellStop standing @ %.2f (step %.*f)",
                     InpStartLot, _Digits, GridStep());
         int placed = PlaceGrid(ORDER_TYPE_BUY_STOP) + PlaceGrid(ORDER_TYPE_SELL_STOP);
         if(placed < wanted)
         {
            m_armRetryUntil = TimeCurrent() + 5;
            PrintFormat("[QUANTUM PARTIAL] only %d/%d placed — retrying in 5s", placed, wanted);
         }
      }

      m_state = "QUANTUM ARMED — 1 BuyStop + 1 SellStop Standing";
      DrawVisual();
      return;
   }

   //=== PHASE DETECTION ===============================================
   if(buys > 0 && sells > 0)
   {
      m_phase = "RECOVERY";
   }
   else if(pos > 0)
   {
      m_phase = "TRENDING";
      ENUM_ORDER_TYPE oppType = (buys > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
      int oppCount = (buys > 0) ? sellPend : buyPend;
      if(oppCount > 0 && !WantRecovery(net, buys, sells, buyPft, sellPft))
      {
         DeletePendingsByType(oppType);
         if(buys > 0) sellPend = 0; else buyPend = 0;
      }
   }

   // Fast Same-Tick Lock
   EnforceOnePerTick();

   //=== BASKET TARGET EXIT ============================================
   double target = CloseTarget();
   if(net >= target)
   {
      PrintFormat(">>> [QUANTUM TARGET CLOSE] net $%.2f >= target $%.2f — PROFIT LOCKED", net, target);
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      m_closedBarTime     = iTime(_Symbol, _Period, 0);
      ProcessClose();
      DrawVisual();
      return;
   }

   // Trailing Profit Lock for Recovery Hedged Baskets
   if(CheckTrailingNet(net, buys, sells))
   {
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      m_closedBarTime     = iTime(_Symbol, _Period, 0);
      ProcessClose();
      DrawVisual();
      return;
   }

   // Trailing Runner Lock for Single Direction
   if(InpTrendRide && pos > 0 && (buys == 0 || sells == 0))
   {
      if(net > m_trendPeakNet) m_trendPeakNet = net;
      if(m_trendPeakNet >= InpTrendMinPeak)
      {
         double giveback = (m_trendPeakNet - InpCloseProfitUSD) * InpTrendTrailRatio;
         double stopNet  = m_trendPeakNet - giveback;
         if(stopNet < InpCloseProfitUSD) stopNet = InpCloseProfitUSD;
         if(net <= stopNet && net > 0)
         {
            PrintFormat(">>> [QUANTUM TRAIL RUNNER LOCK] peak=$%.2f  stop=$%.2f  now=$%.2f — CLOSED",
                        m_trendPeakNet, stopNet, net);
            m_closingInProgress = true;
            m_placeAfterClose   = true;
            m_closedBarTime     = iTime(_Symbol, _Period, 0);
            ProcessClose();
            DrawVisual();
            return;
         }
      }
   }

   //=== RECOVERY OR ACCELERATION DISPATCH ==============================
   if(WantRecovery(net, buys, sells, buyPft, sellPft))
   {
      if(buys >= sells)
         SyncSinglePending(ORDER_TYPE_SELL_STOP, net, buys, sells, buyLot, sellLot, buyPft, sellPft);
      else
         SyncSinglePending(ORDER_TYPE_BUY_STOP, net, buys, sells, buyLot, sellLot, buyPft, sellPft);
   }

   // Dynamic Basket TP
   SetBasketTP(buys, sells, buyLot, sellLot);

   m_state = StringFormat("%s: %d pos (%.2f L) | net $%.2f / $%.2f",
                          m_phase, pos, buyLot + sellLot, net, target);
   DrawVisual();
}

//+------------------------------------------------------------------+
//| Scan active positions and pending orders                         |
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
      if(type == ORDER_TYPE_BUY_STOP  || type == ORDER_TYPE_BUY_LIMIT)  buyPend++;
      else if(type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT) sellPend++;
   }
   return net;
}

//+------------------------------------------------------------------+
//| Verify our magic position                                        |
//+------------------------------------------------------------------+
bool OursPos(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   if((ulong)PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) return false;
   return true;
}

//+------------------------------------------------------------------+
//| Close Target Calculator                                          |
//+------------------------------------------------------------------+
double CloseTarget()
{
   int buys = 0, sells = 0, bp = 0, sp = 0;
   double bl = 0, sl = 0, bpft = 0, spft = 0;
   Scan(buys, sells, bp, sp, bl, sl, bpft, spft);
   int legs = buys + sells;

   double t = InpCloseProfitUSD;
   if(buys > 0 && sells > 0)
   {
      t = 1.50;
      if(legs >= 4) t = 0.50;
      else if(legs >= 2) t = 1.00;
   }
   else if(InpScaleTPWithLegs && m_phase == "RECOVERY")
   {
      t = InpCloseProfitUSD + (legs - 1) * InpTPScaleFactor;
   }
   return t;
}

//+------------------------------------------------------------------+
//| Check trailing net on hedged basket                              |
//+------------------------------------------------------------------+
bool CheckTrailingNet(double net, int buys, int sells)
{
   if(!InpUseTrailingNet) return false;
   if(m_phase != "RECOVERY") return false;
   if(buys == 0 || sells == 0) return false;

   double target = CloseTarget();
   double thresh = MathMax(target * MathMax(InpTrailingNetRatio, 0.10), 1.00);

   if(net > m_recoverTrailPeak) m_recoverTrailPeak = net;

   if(m_recoverTrailPeak >= thresh && net < m_recoverTrailPeak * 0.50 && net >= 0.50)
   {
      PrintFormat(">>> [QUANTUM RECOVERY TRAIL LOCK] peak=$%.2f  now=$%.2f — PROFIT LOCKED", m_recoverTrailPeak, net);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Check if recovery is needed                                      |
//+------------------------------------------------------------------+
bool WantRecovery(double net, int buys, int sells, double buyPft, double sellPft)
{
   int pos = buys + sells;
   if(pos == 0) return false;
   if(pos == 1) return (net <= -InpFirstTriggerUSD);
   return (net <= -InpReverseTriggerUSD);
}

//+------------------------------------------------------------------+
//| Dynamic Grid Step                                                |
//+------------------------------------------------------------------+
double GridStep()
{
   double step = InpGridStepUSD;
   if(InpUseATR && m_atrHandle != INVALID_HANDLE)
   {
      double atr[];
      ArraySetAsSeries(atr, true);
      if(CopyBuffer(m_atrHandle, 0, 0, 1, atr) > 0)
      {
         double dynamicStep = atr[0] * InpAtrMult;
         if(dynamicStep > step) step = dynamicStep;
      }
   }
   return step;
}

//+------------------------------------------------------------------+
//| Place Initial Grid Orders                                        |
//+------------------------------------------------------------------+
int PlaceGrid(ENUM_ORDER_TYPE type)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 0;

   double minDist = MinDist();
   double step    = GridStep();
   int    n       = MathMax(InpMaxGridLevels, 1);
   int    placed  = 0;

   for(int i = 0; i < n; i++)
   {
      double lot = NormalizeLot(InpStartLot);
      double price;
      if(type == ORDER_TYPE_BUY_STOP)
      {
         price = ask + step * (i + 1);
         if(price < ask + minDist) price = ask + minDist;
         price = NormalizeDouble(price, _Digits);
         if(price <= ask) continue;
      }
      else
      {
         price = bid - step * (i + 1);
         if(price > bid - minDist) price = bid - minDist;
         price = NormalizeDouble(price, _Digits);
         if(price >= bid) continue;
      }
      if(SendPendingSafe(type, lot, price, StringFormat("%s #%d",
                         (type == ORDER_TYPE_BUY_STOP ? "BuyStop" : "SellStop"), i + 1)))
         placed++;
   }
   return placed;
}

//+------------------------------------------------------------------+
//| Synchronize Recovery Pending Stop                                |
//+------------------------------------------------------------------+
void SyncSinglePending(ENUM_ORDER_TYPE type, double net,
                       int buys, int sells,
                       double buyLot, double sellLot,
                       double buyPft, double sellPft)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   double target = CloseTarget();
   double revDist = InpReverseDistUSD;
   int legs = buys + sells;
   if(legs >= 5)      revDist *= 2.0;
   else if(legs >= 3) revDist *= 1.5;

   double price = 0.0;
   double minDist = MinDist();

   if(type == ORDER_TYPE_BUY_STOP)
   {
      price = ask + revDist;
      if(InpBeyondAllEntries)
      {
         double highest = HighestEntryAll();
         if(highest > 0 && price < highest + minDist) price = highest + minDist;
      }
      if(price < ask + minDist) price = ask + minDist;
      price = NormalizeDouble(price, _Digits);
      if(price <= ask) return;
   }
   else
   {
      price = bid - revDist;
      if(InpBeyondAllEntries)
      {
         double lowest = LowestEntryAll();
         if(lowest > 0 && price > lowest - minDist) price = lowest - minDist;
      }
      if(price > bid - minDist) price = bid - minDist;
      price = NormalizeDouble(price, _Digits);
      if(price >= bid) return;
   }

   double targetPft = (legs >= 4) ? 0.50 : ((legs >= 2) ? 1.00 : target);
   double lot = CalcDominantRecoveryLot(type, price, targetPft, buys, sells, buyLot, sellLot);
   lot = NormalizeLot(lot);
   if(lot <= 0) return;

   ulong bt[], st[]; double bp[], sp[];
   CollectPendings(ORDER_TYPE_BUY_STOP, bt, bp);
   CollectPendings(ORDER_TYPE_SELL_STOP, st, sp);

   if(type == ORDER_TYPE_BUY_STOP)
   {
      DeleteAllStops(st);
      if(ArraySize(bt) == 0)
      {
         SendPendingSafe(ORDER_TYPE_BUY_STOP, lot, price, "QuantumRecovery BuyStop");
         m_recoveryArmedAt = TimeCurrent();
      }
      else
      {
         if(!OrderSelect(bt[0])) return;
         double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         double curLot   = OrderGetDouble(ORDER_VOLUME_CURRENT);
         double step = GridStep();
         if(MathAbs(price - curPrice) > step * 0.3 || lot > curLot + 0.009)
            ReplacePending(bt[0], ORDER_TYPE_BUY_STOP, lot, price);
      }
   }
   else
   {
      DeleteAllStops(bt);
      if(ArraySize(st) == 0)
      {
         SendPendingSafe(ORDER_TYPE_SELL_STOP, lot, price, "QuantumRecovery SellStop");
         m_recoveryArmedAt = TimeCurrent();
      }
      else
      {
         if(!OrderSelect(st[0])) return;
         double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
         double curLot   = OrderGetDouble(ORDER_VOLUME_CURRENT);
         double step = GridStep();
         if(MathAbs(price - curPrice) > step * 0.3 || lot > curLot + 0.009)
            ReplacePending(st[0], ORDER_TYPE_SELL_STOP, lot, price);
      }
   }
}

//+------------------------------------------------------------------+
//| Calculate Dominant Recovery Lot                                  |
//+------------------------------------------------------------------+
double CalcDominantRecoveryLot(ENUM_ORDER_TYPE type, double stopPrice, double targetPft,
                               int buys, int sells, double buyLot, double sellLot)
{
   double movePrice = InpRecoverMoveUSD;
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return InpStartLot;

   double targetExitPrice = (type == ORDER_TYPE_BUY_STOP) ? (stopPrice + movePrice) : (stopPrice - movePrice);
   double existingPnl = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!OursPos(ticket)) continue;
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      double pts   = (pType == POSITION_TYPE_BUY) ? (targetExitPrice - openP) : (openP - targetExitPrice);
      existingPnl += (pts / ts) * tv * vol;
   }

   double neededFromNew = targetPft - existingPnl;
   if(neededFromNew <= 0) neededFromNew = 1.00;

   double perLotNew = (movePrice / ts) * tv;
   if(perLotNew <= 0) return InpStartLot;

   double lot = neededFromNew / perLotNew;

   // Minimum Asymmetric Progression:
   int legs = buys + sells;
   double minLot = InpStartLot;
   if(legs == 1)      minLot = InpStartLot * 4.0;  // 0.04 - 0.05
   else if(legs == 2) minLot = InpStartLot * 8.0;  // 0.08 - 0.10
   else if(legs == 3) minLot = InpStartLot * 15.0; // 0.15 - 0.18
   else if(legs >= 4) minLot = InpStartLot * 30.0; // 0.30 - 0.35

   if(lot < minLot) lot = minLot;
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;

   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Dynamic Basket TP Setter                                         |
//+------------------------------------------------------------------+
void SetBasketTP(int buys, int sells, double buyLot, double sellLot)
{
   if(!InpUseBasketTP) return;
   double netLots = buyLot - sellLot;
   if(MathAbs(netLots) < 0.001) return;

   double target = CloseTarget();
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return;

   double sumWeighted = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double vol   = PositionGetDouble(POSITION_VOLUME);
      double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      if(pType == POSITION_TYPE_BUY)  sumWeighted += openP * vol;
      else                            sumWeighted -= openP * vol;
   }

   double breakeven = sumWeighted / netLots;
   double pts = (target / (MathAbs(netLots) * tv)) * ts;
   double tp  = (netLots > 0) ? (breakeven + pts) : (breakeven - pts);
   tp = NormalizeDouble(tp, _Digits);

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double minGap = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 30;

   if(netLots > 0 && tp <= ask + minGap) tp = ask + minGap;
   if(netLots < 0 && tp >= bid - minGap) tp = bid - minGap;
   tp = NormalizeDouble(tp, _Digits);

   if(MathAbs(m_basketTP - tp) > SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10)
   {
      m_basketTP = tp;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!OursPos(t)) continue;
         m_trade.PositionModify(t, 0.0, m_basketTP);
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers: Order Management                                        |
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

void ReplacePending(ulong ticket, ENUM_ORDER_TYPE type, double lot, double price)
{
   m_trade.OrderDelete(ticket);
   SendPendingSafe(type, lot, price, "Quantum Replace");
}

void DeletePendings()
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

void DeleteAllStops(ulong &tickets[])
{
   for(int i = 0; i < ArraySize(tickets); i++)
      m_trade.OrderDelete(tickets[i]);
}

void CollectPendings(ENUM_ORDER_TYPE type, ulong &tickets[], double &prices[])
{
   ArrayResize(tickets, 0); ArrayResize(prices, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
      {
         int sz = ArraySize(tickets);
         ArrayResize(tickets, sz + 1); ArrayResize(prices, sz + 1);
         tickets[sz] = t; prices[sz] = OrderGetDouble(ORDER_PRICE_OPEN);
      }
   }
}

void ProcessClose()
{
   DeletePendings();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(OursPos(t)) m_trade.PositionClose(t);
   }
   if(CountPos() == 0)
   {
      DeletePendings();
      m_closingInProgress = false;
      m_cooldownUntil     = TimeCurrent() + InpCooldownSec;
   }
}

void EnforceOnePerTick()
{
   if(!InpOneTradePerTick) return;
   int now = CountPos();
   if(now > m_prevPosCount + 1 && m_prevPosCount >= 0)
   {
      ulong newestTicket = 0; datetime newestTime = 0;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!OursPos(t)) continue;
         datetime ot = (datetime)PositionGetInteger(POSITION_TIME);
         if(ot > newestTime) { newestTime = ot; newestTicket = t; }
      }
      if(newestTicket > 0) m_trade.PositionClose(newestTicket);
   }
   m_prevPosCount = CountPos();
}

int CountPos()
{
   int c = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(OursPos(t)) c++;
   }
   return c;
}

double HighestEntryAll()
{
   double h = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      if(p > h) h = p;
   }
   return h;
}

double LowestEntryAll()
{
   double l = 1e9;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double p = PositionGetDouble(POSITION_PRICE_OPEN);
      if(p < l) l = p;
   }
   return (l == 1e9) ? 0.0 : l;
}

double MinDist()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(stops + 10, 30) * point;
}

bool WideSpread()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   return ((ask - bid) > InpWideSpreadPrice);
}

void CheckGapCondition()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double lastClose = iClose(_Symbol, _Period, 1);
   if(lastClose > 0 && MathAbs(ask - lastClose) >= InpGapUSD) m_gapMode = true;
   else m_gapMode = false;
}

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
//| Draw Interactive Visual Dashboard                               |
//+------------------------------------------------------------------+
void DrawVisual()
{
   if(!InpShowVisual) return;
   int    buys = 0, sells = 0, bp = 0, sp = 0;
   double bl = 0, sl = 0, bpft = 0, spft = 0;
   double net = Scan(buys, sells, bp, sp, bl, sl, bpft, spft);

   string text = StringFormat(
      "\n  ══════════════════════════════════════════" +
      "\n   ⚡ GOLD QUANTUM HEDGER v1.00 (EXNESS GOLD)" +
      "\n  ══════════════════════════════════════════" +
      "\n   Status: %s" +
      "\n   Phase:  %s" +
      "\n   Positions: %d (Buy: %.2f L | Sell: %.2f L)" +
      "\n   Floating Net PnL: $%.2f USD" +
      "\n   Target Profit:    $%.2f USD" +
      "\n   Basket TP Level:  %.*f" +
      "\n  ══════════════════════════════════════════",
      m_state, m_phase, buys + sells, bl, sl, net, CloseTarget(), _Digits, m_basketTP);

   Comment(text);
}
//+------------------------------------------------------------------+
