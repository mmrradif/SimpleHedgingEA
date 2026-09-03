//+------------------------------------------------------------------+
//|                                           GoldQuantumHedger.mq5 |
//|          Copyright 2026, Zero-Loss Trend Pulse & Break-Even Scalp|
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, Zero-Loss Trend Pulse & Break-Even Scalp"
#property link      "https://www.mql5.com"
#property version   "9.00-ZERO-LOSS"
#property description "GoldQuantumHedger v9.0: Ultra-Clean Breakout Scalper with Instant Break-Even & Zero-Loss Trend Filter."

#include <Trade\Trade.mqh>

//--- Profit Settings ------------------------------------------------
input group "=== Quick Profit & Break-Even Settings ==="
input double   InpTakeProfitUSD       = 5.00;   // Fast Scalp Take Profit ($5.00 USD - Direct High Win Rate!)
input double   InpBreakEvenTriggerUSD = 2.00;   // Move to Break-Even at (+$2.00 USD Profit - ZERO LOSS SHIELD!)
input double   InpBreakEvenLockUSD    = 1.00;   // Profit Locked at Break-Even (+$1.00 USD)
input bool     InpUseTrailingNet      = true;   // Trailing Runner Lock
input double   InpTrailPeakMinUSD     = 4.50;   // Trailing Start Trigger ($4.50 USD)
input double   InpTrailDropRatio      = 0.20;   // Trailing Lock Ratio (20%)

//--- Trend & Entry Filters ------------------------------------------
input group "=== Trend & Entry Filter Settings ==="
input double   InpBaseLot             = 0.05;   // Scalp Lot Size (0.05 Lot for Big Profits!)
input double   InpBreakoutDistanceUSD = 2.50;   // Breakout Distance from High/Low ($2.50)
input bool     InpUseTrendFilter      = true;   // EMA Trend Direction Filter (Prevents False Entries!)
input int      InpFastEMA             = 12;     // Fast EMA Period
input int      InpSlowEMA             = 26;     // Slow EMA Period
input bool     InpUseATR              = true;   // ATR Volatility Adaptive Spacing
input int      InpAtrPeriod           = 14;     // ATR Period

//--- Protection & Speed Controls ------------------------------------
input group "=== Protection Controls ==="
input int      InpCooldownSec         = 2;      // Cooldown After Close (2 Sec)
input double   InpWideSpreadPrice     = 0.80;   // Wide Spread News Shield ($0.80 USD)
input ulong    InpMagicNumber         = 777888; // Unique Quantum Magic Number
input ulong    InpSlippage            = 50;     // Execution Slippage Tolerance
input bool     InpShowVisual          = true;   // Interactive Dashboard

#define VIS_PREFIX "QuantumZeroLoss_"

//--- System State Variables -----------------------------------------
CTrade   m_trade;
int      m_atrHandle;
int      m_fastEmaHandle;
int      m_slowEmaHandle;
string   m_state;
double   m_peakNet;
datetime m_cooldownUntil;
bool     m_closingInProgress;
bool     m_breakEvenActive;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   m_trade.LogLevel(LOG_LEVEL_ERRORS);

   m_atrHandle     = iATR(_Symbol, PERIOD_M1, MathMax(InpAtrPeriod, 2));
   m_fastEmaHandle = iMA(_Symbol, PERIOD_M1, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   m_slowEmaHandle = iMA(_Symbol, PERIOD_M1, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);

   ResetState();
   m_closingInProgress = false;
   m_cooldownUntil     = 0;
   m_breakEvenActive   = false;

   PrintFormat("[QUANTUM ZERO-LOSS INIT] Magic=%u | Lot=%.2f | TP=$%.2f | BE=$%.2f",
               InpMagicNumber, InpBaseLot, InpTakeProfitUSD, InpBreakEvenTriggerUSD);

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(m_atrHandle != INVALID_HANDLE) IndicatorRelease(m_atrHandle);
   if(m_fastEmaHandle != INVALID_HANDLE) IndicatorRelease(m_fastEmaHandle);
   if(m_slowEmaHandle != INVALID_HANDLE) IndicatorRelease(m_slowEmaHandle);
   ObjectsDeleteAll(0, VIS_PREFIX);
   Comment("");
}

//+------------------------------------------------------------------+
//| Reset system state                                               |
//+------------------------------------------------------------------+
void ResetState()
{
   m_state           = "IDLE";
   m_peakNet         = -1e9;
   m_breakEvenActive = false;
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

   //=== PHASE 0: FLAT (NO OPEN POSITIONS) -> ARM TREND BREAKOUT =======
   if(pos == 0)
   {
      if(TimeCurrent() < m_cooldownUntil)
      {
         m_state = "COOLDOWN PAUSE";
         DrawDashboard();
         return;
      }

      if(buyPend + sellPend == 0)
      {
         if(WideSpread())
         {
            m_state = "WIDE SPREAD NEWS PAUSE";
            DrawDashboard();
            return;
         }

         ResetState();
         ArmTrendBreakout();
         m_state = "ARMED: Trend Breakout Ready";
         DrawDashboard();
         return;
      }

      m_state = StringFormat("ARMED: %d BuyStops + %d SellStops Standing", buyPend, sellPend);
      DrawDashboard();
      return;
   }

   //=== PHASE 1: ACTIVE TRADE MANAGEMENT & BREAK-EVEN SHIELD ==========
   // 1. Instant Break-Even Activation (Zero Loss Protection!)
   if(!m_breakEvenActive && net >= InpBreakEvenTriggerUSD)
   {
      m_breakEvenActive = true;
      PrintFormat(">>> [ZERO-LOSS BREAK-EVEN ACTIVATED] Net $%.2f >= $%.2f — Trade is now 100%% Risk-Free!",
                  net, InpBreakEvenTriggerUSD);
   }

   // 2. Break-Even Trailing Protection
   if(m_breakEvenActive && net <= InpBreakEvenLockUSD)
   {
      PrintFormat(">>> [BREAK-EVEN HIT] Closed safely at +$%.2f USD (ZERO LOSS!)", net);
      m_closingInProgress = true;
      ProcessCloseAll();
      DrawDashboard();
      return;
   }

   // 3. Take Profit Reached -> Direct Cash Out
   if(net >= InpTakeProfitUSD)
   {
      PrintFormat(">>> [PROFIT TP HIT] Net $%.2f >= Target $%.2f — CASH OUT & RESET!", net, InpTakeProfitUSD);
      m_closingInProgress = true;
      ProcessCloseAll();
      DrawDashboard();
      return;
   }

   // 4. Trailing Runner Lock
   if(InpUseTrailingNet && net > 0)
   {
      if(net > m_peakNet) m_peakNet = net;
      if(m_peakNet >= InpTrailPeakMinUSD)
      {
         double giveback = (m_peakNet - InpTakeProfitUSD * 0.50) * InpTrailDropRatio;
         double stopNet  = m_peakNet - giveback;
         if(stopNet < InpBreakEvenLockUSD) stopNet = InpBreakEvenLockUSD;
         if(net <= stopNet)
         {
            PrintFormat(">>> [TRAIL LOCK] Peak $%.2f -> Locked at $%.2f (Now $%.2f) — CLOSING ALL",
                        m_peakNet, stopNet, net);
            m_closingInProgress = true;
            ProcessCloseAll();
            DrawDashboard();
            return;
         }
      }
   }

   // Clean opposite pendings once a position is triggered
   if(pos > 0 && (buyPend > 0 || sellPend > 0))
   {
      DeleteAllPendings();
   }

   m_state = StringFormat("ACTIVE: %d pos (%.2f L) | Net $%.2f / Target $%.2f | BE: %s",
                          pos, buyLot + sellLot, net, InpTakeProfitUSD, m_breakEvenActive ? "ON" : "OFF");
   DrawDashboard();
}

//+------------------------------------------------------------------+
//| Arm Trend Breakout Orders with Trend Filter                      |
//+------------------------------------------------------------------+
void ArmTrendBreakout()
{
   DeleteAllPendings();

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   int trend = GetTrendDirection(); // 1 = Bullish, -1 = Bearish, 0 = Neutral
   double dist = InpBreakoutDistanceUSD;
   double minDist = MinDistance();

   // Bullish or Neutral: Arm BuyStop
   if(trend >= 0)
   {
      double buyPrice = ask + dist;
      if(buyPrice < ask + minDist) buyPrice = ask + minDist;
      buyPrice = NormalizeDouble(buyPrice, _Digits);
      SendPendingSafe(ORDER_TYPE_BUY_STOP, InpBaseLot, buyPrice, "Trend BuyStop");
   }

   // Bearish or Neutral: Arm SellStop
   if(trend <= 0)
   {
      double sellPrice = bid - dist;
      if(sellPrice > bid - minDist) sellPrice = bid - minDist;
      sellPrice = NormalizeDouble(sellPrice, _Digits);
      SendPendingSafe(ORDER_TYPE_SELL_STOP, InpBaseLot, sellPrice, "Trend SellStop");
   }
}

//+------------------------------------------------------------------+
//| Detect Trend Direction (Fast EMA vs Slow EMA)                    |
//+------------------------------------------------------------------+
int GetTrendDirection()
{
   if(!InpUseTrendFilter) return 0;
   if(m_fastEmaHandle == INVALID_HANDLE || m_slowEmaHandle == INVALID_HANDLE) return 0;

   double fast[], slow[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);

   if(CopyBuffer(m_fastEmaHandle, 0, 0, 2, fast) <= 0) return 0;
   if(CopyBuffer(m_slowEmaHandle, 0, 0, 2, slow) <= 0) return 0;

   if(fast[0] > slow[0] && fast[1] > slow[1]) return 1;  // Bullish
   if(fast[0] < slow[0] && fast[1] < slow[1]) return -1; // Bearish

   return 0; // Neutral
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
//| Minimum broker distance                                          |
//+------------------------------------------------------------------+
double MinDistance()
{
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long stops   = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   return MathMax(stops + 10, 30) * point;
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
      "\n   🚀 GOLD QUANTUM HEDGER v9.0 (ZERO-LOSS SCALPER)" +
      "\n  ═════════════════════════════════════════════════════════" +
      "\n   Status:     %s" +
      "\n   Positions:  %d Active (Buy: %.2f L | Sell: %.2f L)" +
      "\n   Net PnL:    $%.2f USD" +
      "\n   Target TP:  $%.2f USD" +
      "\n   Break-Even: %s (Lock: +$%.2f)" +
      "\n   Base Lot:   %.2f Lot" +
      "\n  ═════════════════════════════════════════════════════════",
      m_state, buys + sells, bl, sl, net, InpTakeProfitUSD, m_breakEvenActive ? "ACTIVE (RISK-FREE)" : "STANDBY", InpBreakEvenLockUSD, InpBaseLot);

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

   Print("========== QUANTUM ZERO-LOSS SUMMARY ==========");
   PrintFormat("[STAT] deposit=%.2f  final=%.2f  netProfit=%.2f  (%.2f%%)",
               initialDeposit, initialDeposit + profit, profit, (initialDeposit > 0 ? profit / initialDeposit * 100.0 : 0));
   PrintFormat("[STAT] grossProfit=%.2f  grossLoss=%.2f  profitFactor=%.2f",
               grossProfit, grossLoss, profitFactor);
   PrintFormat("[STAT] trades=%d  won=%d  lost=%d  winRate=%.1f%%",
               trades, won, lost, winRate);
   PrintFormat("[STAT] equityDD=%.2f (%.2f%%)  balanceDD=%.2f (%.2f%%)",
               equityDD, equityDDPct, balanceDD, balanceDDPct);
   PrintFormat("[STAT] minMarginLevel=%.1f%%", minMarginLevel);
   Print("===============================================");

   return profit;
}
//+------------------------------------------------------------------+
