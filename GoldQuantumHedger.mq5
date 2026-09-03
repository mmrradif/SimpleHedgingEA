//+------------------------------------------------------------------+
//|                                           GoldQuantumHedger.mq5 |
//|                     Copyright 2026, 10+10 Multi-Ladder Hedging   |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Multi-Ladder Hedging"
#property link      "https://www.mql5.com"
#property version   "3.00-LADDER"
#property description "GoldQuantumHedger v3.0: 10 BuyStop + 10 SellStop Pre-Armed Ladder Grid with Global Basket TP & Instant Re-Arming."

#include <Trade\Trade.mqh>

//--- Profit Settings ------------------------------------------------
input group "=== Quantum Ladder Profit Engine ==="
input double   InpBasketProfitUSD     = 10.00;  // Global Basket Take Profit ($10.00 USD)
input bool     InpUseTrailingNet      = true;   // Trailing Profit Lock for Runners
input double   InpTrailPeakMinUSD     = 8.00;   // Trailing Start Trigger ($8.00 USD)
input double   InpTrailDropRatio      = 0.25;   // Trailing Profit Lock Ratio (25%)

//--- 10+10 Ladder Grid Settings -------------------------------------
input group "=== 10+10 Pre-Armed Ladder Settings ==="
input int      InpGridLevelsPerSide   = 10;     // Grid Levels Per Side (10 BuyStop + 10 SellStop = 20 Orders)
input double   InpBaseStartLot        = 0.01;   // Base Starting Lot Size (0.01)
input double   InpGridStepUSD         = 2.50;   // Grid Step Distance ($2.50 Gold Move Per Level)
input double   InpLotProgression      = 1.15;   // Lot Multiplier Per Level (1.15x Progression)
input double   InpMaxLotPerOrder      = 0.20;   // Hard Lot Cap Per Single Order (0.20)
input bool     InpUseATR              = true;   // Dynamic ATR Step Padding
input int      InpAtrPeriod           = 14;     // ATR Period
input double   InpAtrMult             = 1.0;    // ATR Step Multiplier

//--- Protection & Control -------------------------------------------
input group "=== Protection & System Settings ==="
input int      InpCooldownSec         = 5;      // Cooldown After Basket Exit (Sec)
input double   InpWideSpreadPrice     = 1.00;   // Wide Spread News Shield ($1.00 USD)
input ulong    InpMagicNumber         = 777888; // Unique Quantum Magic Number
input ulong    InpSlippage            = 50;     // Execution Slippage Tolerance
input bool     InpShowVisual          = true;   // Interactive Chart Dashboard

#define VIS_PREFIX "QuantumLadder_"

//--- System State Variables -----------------------------------------
CTrade   m_trade;
int      m_atrHandle;
string   m_state;
double   m_peakNet;
datetime m_cooldownUntil;
datetime m_closedBarTime;
bool     m_closingInProgress;

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

   PrintFormat("[QUANTUM LADDER INIT] Magic=%u | BasketTP=$%.2f | Levels=%d+%d | Step=$%.2f",
               InpMagicNumber, InpBasketProfitUSD, InpGridLevelsPerSide, InpGridLevelsPerSide, InpGridStepUSD);

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
   m_state   = "IDLE";
   m_peakNet = -1e9;
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

      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(m_closedBarTime != 0 && currentBarTime == m_closedBarTime)
      {
         m_state = "WAITING FOR NEXT CANDLE";
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
         PrintFormat("[QUANTUM LADDER ARM] Placing %d BuyStops + %d SellStops (Total %d Orders)",
                     InpGridLevelsPerSide, InpGridLevelsPerSide, totalWanted);

         ArmLadderGrid();
         m_state = StringFormat("ARMED: %d BuyStops + %d SellStops Standing", InpGridLevelsPerSide, InpGridLevelsPerSide);
         DrawDashboard();
         return;
      }

      m_state = StringFormat("ARMED: %d BuyStops + %d SellStops Standing", buyPend, sellPend);
      DrawDashboard();
      return;
   }

   //=== PHASE 1: ACTIVE BASKET (POSITIONS TRIGGERED) ==================
   double target = InpBasketProfitUSD;
   if(buys > 0 && sells > 0)
   {
      int totalLegs = buys + sells;
      if(totalLegs >= 6)      target = 1.00;
      else if(totalLegs >= 3) target = 3.00;
      else                    target = 5.00;
   }

   // Target Profit Reached -> GLOBAL BASKET CLOSE
   if(net >= target)
   {
      PrintFormat(">>> [QUANTUM BASKET TP HIT] Net $%.2f >= Target $%.2f — CLOSING ALL & RE-ARMING!", net, target);
      m_closingInProgress = true;
      m_closedBarTime     = iTime(_Symbol, _Period, 0);
      ProcessCloseAll();
      DrawDashboard();
      return;
   }

   // If one side has triggered, make sure opposite ladder stays positioned for optimal recovery
   if(pos > 0 && (buys == 0 || sells == 0))
   {
      // Clean opposite pendings if we are already in profit
      if(net >= target * 0.50)
      {
         ENUM_ORDER_TYPE oppType = (buys > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;
         DeletePendingsByType(oppType);
      }
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
            PrintFormat(">>> [QUANTUM TRAILING LOCK] Peak $%.2f -> Locked at $%.2f (Now $%.2f) — CLOSING ALL",
                        m_peakNet, stopNet, net);
            m_closingInProgress = true;
            m_closedBarTime     = iTime(_Symbol, _Period, 0);
            ProcessCloseAll();
            DrawDashboard();
            return;
         }
      }
   }

   m_state = StringFormat("LADDER ACTIVE: %d pos (Buy: %.2f L | Sell: %.2f L) | Net $%.2f / Target $%.2f",
                          pos, buyLot, sellLot, net, target);
   DrawDashboard();
}

//+------------------------------------------------------------------+
//| Arm Full 10 BuyStop + 10 SellStop Grid                           |
//+------------------------------------------------------------------+
void ArmLadderGrid()
{
   DeleteAllPendings();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   double step = DynamicStep();
   double minDist = MinDistance();

   // Place BuyStops Ladder
   for(int i = 0; i < InpGridLevelsPerSide; i++)
   {
      double price = ask + step * (i + 1);
      if(price < ask + minDist) price = ask + minDist + (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      price = NormalizeDouble(price, _Digits);

      double lot = CalcLadderLot(i);
      SendPendingSafe(ORDER_TYPE_BUY_STOP, lot, price, StringFormat("BuyStop #%d", i + 1));
   }

   // Place SellStops Ladder
   for(int i = 0; i < InpGridLevelsPerSide; i++)
   {
      double price = bid - step * (i + 1);
      if(price > bid - minDist) price = bid - minDist - (i * SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10);
      price = NormalizeDouble(price, _Digits);

      double lot = CalcLadderLot(i);
      SendPendingSafe(ORDER_TYPE_SELL_STOP, lot, price, StringFormat("SellStop #%d", i + 1));
   }
}

//+------------------------------------------------------------------+
//| Calculate Lot Size For Each Ladder Step                          |
//+------------------------------------------------------------------+
double CalcLadderLot(int levelIndex)
{
   double lot = InpBaseStartLot * MathPow(InpLotProgression, levelIndex);
   if(InpMaxLotPerOrder > 0 && lot > InpMaxLotPerOrder)
      lot = InpMaxLotPerOrder;
   return NormalizeLot(lot);
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
      "\n   🚀 GOLD QUANTUM HEDGER v3.0 (10+10 MULTI-LADDER GRID)" +
      "\n  ═════════════════════════════════════════════════════════" +
      "\n   Status:     %s" +
      "\n   Positions:  %d Active (Buy: %.2f L | Sell: %.2f L)" +
      "\n   Pendings:   %d Orders (BuyStops: %d | SellStops: %d)" +
      "\n   Net PnL:    $%.2f USD" +
      "\n   Target TP:  $%.2f USD" +
      "\n   Grid Step:  $%.2f USD" +
      "\n  ═════════════════════════════════════════════════════════",
      m_state, buys + sells, bl, sl, bp + sp, bp, sp, net, InpBasketProfitUSD, DynamicStep());

   Comment(text);
}
//+------------------------------------------------------------------+
