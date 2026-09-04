//+------------------------------------------------------------------+
//|                                              GoldQuantumHedger.mq5 |
//|  v360 — Tri-Core Dynamic Mega Profit Hedger & Recovery System     |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "16.00"
#property description "GoldQuantumHedger v16.0: 20-Order Signal Grid + Dynamic Single Reversal & Alternating Recovery Hedger."

#include <Trade\Trade.mqh>

//--- Auto-Compounding & Smart Lot Ceiling ----------------------------
input group "=== Smart Auto-Compounding & Safety Ceiling ==="
input bool     InpAutoCompounding     = false;  // Dynamic Auto-Compounding (Set true for aggressive growth)
input double   InpRiskDepositPer001   = 5000.0; // Equity Needed Per 0.01 Base Lot ($5,000 USD)
input double   InpMaxBaseLot          = 0.03;   // Smart Max Base Lot Ceiling (0.03 Lot)

//--- Flash-Crash & Spread Protection --------------------------------
input group "=== Flash-Crash & News Protection ==="
input bool     InpUseFlashCrashShield = false;  // Flash-Crash & Extreme Spike Shield
input double   InpMaxCandleRangeUSD   = 8.00;   // Extreme News Candle Range ($8.00 USD)
input int      InpNewsPauseSec        = 180;    // Pause Duration After Extreme Spike (180 Sec / 3 Min)
input double   InpWideSpreadPrice     = 1.00;   // Wide Spread News Shield ($1.00 USD)

//--- Profit ---------------------------------------------------------
input group "=== Profit Settings ==="
input double   InpCloseProfitUSD      = 30.00;  // Master Overall Basket Take Profit Target ($30.00 USD)
input bool     InpUseBasketTP         = false;  // Shared Basket TP (False = Dynamic OnTick Net Close)
input bool     InpScaleTPWithLegs     = false;  // Fixed $30 Master Target
input double   InpTPScaleFactor       = 0.00;   // TP Scale Factor

//--- Trend Riding ---------------------------------------------------
input group "=== Mega-Wave Trend Riding ==="
input bool     InpTrendRide           = false;  // Strict $30 Target (False = No early micro exit)
input double   InpTrendMinPeak        = 30.00;  // Trailing Start Peak ($30.00 USD)
input double   InpTrendTrailRatio     = 0.20;   // Lock 80% of Peak Runaway Profit (20% Trail)

//--- PMax (Profit Maximizer by KivancOzbilgic) ----------------------
input group "=== PMax (Profit Maximizer) Trend Signal ==="
input bool     InpUsePMax             = true;   // Enable KivancOzbilgic PMax Trend Filter
input int      InpPMaxAtrPeriod       = 10;     // PMax ATR Length (10)
input double   InpPMaxMultiplier      = 3.0;    // PMax ATR Multiplier (3.0)
input int      InpPMaxMALength        = 10;     // PMax Moving Average Length (10 EMA)
input ENUM_TIMEFRAMES InpPMaxTF       = PERIOD_CURRENT; // PMax Timeframe

//--- Entry Grid -----------------------------------------------------
input group "=== Initial Entry Settings ==="
input double   InpStartLot            = 0.01;   // 0.01 Lot Base (All 20 Grid Orders @ 0.01)
input int      InpMaxGridLevels       = 20;     // Exactly 20 Standing Stop Orders in Signal Direction!
input double   InpGridStepUSD         = 3.00;   // Grid Step Spacing ($3.00 chart move per level)
input bool     InpUseATR              = true;   // Dynamic ATR Step Padding
input int      InpAtrPeriod           = 14;     // ATR Period
input double   InpAtrMult             = 1.0;    // ATR Multiplier

//--- Reversal / recovery --------------------------------------------
input group "=== Dynamic Calculated Reversal Engine ==="
input double   InpFirstTriggerUSD     = 0.00;   // Immediate Reversal Stop on 1st Hit ($0.00)
input double   InpReverseTriggerUSD   = 0.00;   // Immediate Calculated Reversal on All Legs ($0.00)
input int      InpReverseAfterSec     = 0;      // Immediate Arming (0 Sec)
input double   InpReverseDistUSD      = 3.50;   // Recovery Stop Distance ($3.50)
input double   InpRecoverMoveUSD      = 3.00;   // Dominant Recovery Move Target ($3.00 / 30 pips)
input bool     InpBeyondAllEntries    = true;   // Place Stop Beyond All Entries
input double   InpMaxLot              = 1.00;   // Hard Max Lot Cap (1.00)
input double   InpMaxBasketLots       = 0.0;    // Basket Max Lots (0 = Uncapped for Mathematical Precision)
input int      InpMaxRecoveryLegs     = 10;     // Max Recovery Legs
input int      InpRecoveryAccelMin    = 0;      // Acceleration Delay (Min)
input double   InpAccelDistRatio      = 0.65;   // Acceleration Distance Ratio
input bool     InpBreakoutRecovery    = false;  // Breakout Recovery Mode

//--- Trend Filter ---------------------------------------------------
input group "=== Trend Filter ==="
input bool     InpUseTrendFilter      = false;  // Pure Signal Direction Hedging
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_M5;  // Trend Filter Timeframe
input int      InpTrendFastEMA        = 9;      // Fast EMA Period
input int      InpTrendSlowEMA        = 21;     // Slow EMA Period

//--- Anti-churn / protection ----------------------------------------
input group "=== Exit & Protection ==="
input bool     InpOneTradePerTick     = true;   // One Trade Per Tick Lock
input int      InpCooldownSec         = 5;      // Cooldown Seconds after Exit
input int      InpBreakEvenAfterMin   = 0;      // Break-Even Exit Timer (0 = Disabled for Full TP Hits)
input int      InpForceCloseAfterMin  = 0;      // Hard Time Stop (0 = Off)
input bool     InpUseTrailingNet      = false;  // Basket Trailing Net Lock (False = Full $30 TP)
input double   InpTrailingNetRatio    = 0.35;   // Basket Trailing Ratio
input bool     InpHedgeFastExit       = false;  // Fast Hedged Exit (False = Full $30 TP)
input double   InpHedgeExitRatio      = 0.20;   // Fast Hedged Exit Ratio
input double   InpSpreadPad           = 2.5;    // Spread Multiplier Padding
input double   InpGapUSD              = 15.0;   // Gap Protection Threshold ($ USD)
input double   InpMaxCycleLossUSD     = 0.0;    // Single Basket Circuit Breaker (0 = Pure Zone Recovery)
input double   InpMaxAllowedDrawdownUSD = 0.0;  // Max Account Drawdown ($ USD, 0 = Pure Mathematical Recovery)
input double   InpMaxDrawdownPercent  = 0.0;    // Max Account Drawdown (% - 0 = Pure Mathematical Recovery)
input bool     InpCloseFridayNight    = false;  // Friday Night Close
input ulong    InpMagicNumber = 777888; // Magic Number
input ulong    InpSlippage            = 50;     // Slippage Tolerance
input bool     InpShowVisual          = true;   // Show Chart Dashboard

#define VIS_PREFIX "QuantumVis_"

CTrade   m_trade;
int      m_atrHandle;
int      m_emaFast;
int      m_emaSlow;
bool     m_closingInProgress;
bool     m_placeAfterClose;
double   m_lastMid;
bool     m_gapMode;

int      m_prevPosCount;      // positions seen on the previous tick
double   m_recoverNet;        // net the live recovery lot was sized for
int      m_recoverDir;        // side the live recovery stop points to
datetime m_redSince;          // first moment the basket went negative this cycle
datetime m_cooldownUntil;     // do not re-arm before this
datetime m_closedBarTime;     // bar time when cycle closed (wait for new bar before re-arming)
datetime m_armRetryUntil;     // back off after a failed arm
double   m_basketTP;          // shared TP price currently written on positions
string   m_state;

//--- Phase tracking ------------------------------------------------
string   m_phase;             // "IDLE" | "TRENDING" | "RECOVERY"
int      m_trendDir;          // +1 = BUY trending, -1 = SELL trending
double   m_trendPeakNet;      // Best net seen
bool     m_trailActive;       // Has trailing been activated?
double   m_recoverTrailPeak;  // Best net seen during RECOVERY
datetime m_recoveryArmedAt;   // When the recovery stop was last armed

bool SendPending(ENUM_ORDER_TYPE type, double lot, double price, string comment);
bool SendPendingSafe(ENUM_ORDER_TYPE type, double lot, double price, string comment);

//+------------------------------------------------------------------+
int OnInit()
{
   m_trade.SetExpertMagicNumber(InpMagicNumber);
   m_trade.SetDeviationInPoints(InpSlippage);
   m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   m_trade.LogLevel(LOG_LEVEL_ERRORS);

   m_atrHandle = iATR(_Symbol, PERIOD_M1, MathMax(InpAtrPeriod, 2));
   m_emaFast   = iMA(_Symbol, InpTrendTF, MathMax(InpTrendFastEMA, 2), 0, MODE_EMA, PRICE_CLOSE);
   m_emaSlow   = iMA(_Symbol, InpTrendTF, MathMax(InpTrendSlowEMA, 3), 0, MODE_EMA, PRICE_CLOSE);

   ResetCycleState();
   m_closingInProgress = false;
   m_placeAfterClose   = false;
   m_cooldownUntil     = 0;
   m_closedBarTime     = 0;
   m_gapMode           = false;
   m_armRetryUntil     = 0;
   m_prevPosCount      = CountPos();

   PrintFormat("[INIT] GoldQuantumHedger v16.0 | Basket Target $%.2f | Grid Levels %d @ %.2f | Tester=%s",
               InpCloseProfitUSD, InpMaxGridLevels, InpStartLot,
               MQLInfoInteger(MQL_TESTER) ? "YES" : "NO");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tester summary                                                   |
//+------------------------------------------------------------------+
double OnTester()
{
   double dep   = TesterStatistics(STAT_INITIAL_DEPOSIT);
   double net   = TesterStatistics(STAT_PROFIT);
   double gp    = TesterStatistics(STAT_GROSS_PROFIT);
   double gl    = TesterStatistics(STAT_GROSS_LOSS);
   double eqdd  = TesterStatistics(STAT_EQUITY_DD);
   double eqddp = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double baldd = TesterStatistics(STAT_BALANCE_DD);
   double balddp= TesterStatistics(STAT_BALANCEDD_PERCENT);
   double trades= TesterStatistics(STAT_TRADES);
   double won   = TesterStatistics(STAT_PROFIT_TRADES);
   double lost  = TesterStatistics(STAT_LOSS_TRADES);
   double pf    = TesterStatistics(STAT_PROFIT_FACTOR);

   Print("========== TESTER SUMMARY ==========");
   PrintFormat("[STAT] deposit=%.2f  final=%.2f  netProfit=%.2f  (%.2f%%)",
               dep, dep + net, net, (dep > 0 ? net / dep * 100.0 : 0));
   PrintFormat("[STAT] grossProfit=%.2f  grossLoss=%.2f  profitFactor=%.2f", gp, gl, pf);
   PrintFormat("[STAT] trades=%.0f  won=%.0f  lost=%.0f  winRate=%.1f%%",
               trades, won, lost, (trades > 0 ? won / trades * 100.0 : 0));
   PrintFormat("[STAT] equityDD=%.2f (%.2f%%)  balanceDD=%.2f (%.2f%%)",
               eqdd, eqddp, baldd, balddp);

   ExportTradesToCSV();
   Print("====================================");
   return net;
}

//+------------------------------------------------------------------+
void ExportTradesToCSV()
{
   int file = FileOpen("GoldQuantumHedger_Trades.csv", FILE_WRITE|FILE_CSV|FILE_COMMON, ",");
   if(file == INVALID_HANDLE)
      file = FileOpen("GoldQuantumHedger_Trades.csv", FILE_WRITE|FILE_CSV, ",");
   
   if(file != INVALID_HANDLE)
   {
      FileWrite(file, "DealTicket", "OrderTicket", "Time", "Type", "Entry", "Volume", "Price", "ProfitUSD", "BalanceUSD");
      HistorySelect(0, TimeCurrent());
      int totalDeals = HistoryDealsTotal();
      double balance = 5000.0;
      for(int i = 0; i < totalDeals; i++)
      {
         ulong dealTicket = HistoryDealGetTicket(i);
         if(dealTicket == 0) continue;
         
         datetime dTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
         long dType     = HistoryDealGetInteger(dealTicket, DEAL_TYPE);
         long dEntry    = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
         double dVol    = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
         double dPrice  = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
         double dProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
         double dComm   = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         double dSwap   = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
         ulong dOrder   = (ulong)HistoryDealGetInteger(dealTicket, DEAL_ORDER);
         
         balance += (dProfit + dComm + dSwap);
         
         string strType = (dType == DEAL_TYPE_BUY) ? "BUY" : ((dType == DEAL_TYPE_SELL) ? "SELL" : "BALANCE");
         string strEntry = (dEntry == DEAL_ENTRY_IN) ? "IN (Open)" : ((dEntry == DEAL_ENTRY_OUT) ? "OUT (Close)" : "IN/OUT");
         
         FileWrite(file, (string)dealTicket, (string)dOrder, TimeToString(dTime, TIME_DATE|TIME_SECONDS),
                   strType, strEntry, DoubleToString(dVol, 2), DoubleToString(dPrice, _Digits),
                   DoubleToString(dProfit, 2), DoubleToString(balance, 2));
      }
      FileClose(file);
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(m_atrHandle != INVALID_HANDLE)
      IndicatorRelease(m_atrHandle);
   Comment("");
   ObjectsDeleteAll(0, VIS_PREFIX);
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void ResetCycleState()
{
   m_recoverNet         = 0;
   m_recoverDir         = 0;
   m_redSince           = 0;
   m_basketTP           = 0;
   m_state              = "IDLE";
   m_phase              = "IDLE";
   m_trendDir           = 0;
   m_trendPeakNet       = -1e9;
   m_trailActive        = false;
   m_recoverTrailPeak   = -1e9;
   m_recoveryArmedAt    = 0;
}

//+------------------------------------------------------------------+
void OnTick()
{
   DetectGap();

   if(m_closingInProgress)
   {
      ProcessClose();
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   if(EquityTrip())
   {
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   // Guard: never let more than one position open on one tick
   EnforceOnePerTick();

   int    buys = 0, sells = 0, buyPend = 0, sellPend = 0;
   double buyLot = 0, sellLot = 0, buyPft = 0, sellPft = 0;
   double net = Scan(buys, sells, buyPend, sellPend, buyLot, sellLot, buyPft, sellPft);
   int    pos = buys + sells;

   //=== FLAT STATE ====================================================
   if(pos == 0)
   {
      ResetCycleState();

      // If positions just closed (TP target reached), delete any leftover pendings immediately
      if(m_prevPosCount > 0)
      {
         DeletePendings();
         m_cooldownUntil = TimeCurrent() + InpCooldownSec;
         m_closedBarTime = iTime(_Symbol, _Period, 0);
         m_prevPosCount = 0;
         DrawVisual();
         return;
      }

      if(TimeCurrent() < m_cooldownUntil)
      {
         m_state = "COOLDOWN";
         DrawVisual();
         return;
      }

      // Fresh candle entry filter
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(m_closedBarTime != 0 && currentBarTime == m_closedBarTime)
      {
         m_state = "WAITING FOR NEXT CANDLE";
         DrawVisual();
         return;
      }

      // Arm exactly 20 orders in signal direction
      if(buyPend + sellPend == 0)
      {
         if(TimeCurrent() < m_armRetryUntil)
         {
            m_state = "ARM RETRY BACKOFF";
            DrawVisual();
            return;
         }
         if(WideSpread() || m_gapMode || FlashCrashActive())
         {
            m_state = FlashCrashActive() ? "FLASH CRASH SPIKE PAUSE" : (m_gapMode ? "GAP — not arming" : "WIDE SPREAD — not arming");
            DrawVisual();
            return;
         }
         int tDir = TrendDir();
         int placed = 0;
         if(tDir >= 0)
            placed = PlaceGrid(ORDER_TYPE_BUY_STOP);
         else
            placed = PlaceGrid(ORDER_TYPE_SELL_STOP);

         if(placed < InpMaxGridLevels)
         {
            m_armRetryUntil = TimeCurrent() + 5;
            PrintFormat("[ARM PARTIAL] %d of %d placed — retrying in 5s", placed, InpMaxGridLevels);
         }
         else
         {
            PrintFormat("[ARM SUCCESS] Exactly %d %s orders armed @ %.2f",
                        placed, (tDir >= 0 ? "BuyStop" : "SellStop"), InpStartLot);
         }
      }

      m_state = StringFormat("ARMED — %d %s standing", InpMaxGridLevels, (TrendDir() >= 0 ? "BuyStop" : "SellStop"));
      DrawVisual();
      return;
   }

   //=== PHASE MANAGEMENT ==============================================
   if(buys > 0 && sells > 0)
   {
      m_phase = "RECOVERY";
   }
   else if(m_phase == "IDLE")
   {
      m_trendDir = (buys >= sells) ? 1 : -1;
      m_phase    = "TRENDING";
      // Cancel initial opposite pending if any
      DeleteAllOfType(m_trendDir > 0 ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
      PrintFormat("[PHASE->%s] dir=%s, initial %d grid orders active",
                  m_phase, m_trendDir > 0 ? "BUY" : "SELL", InpMaxGridLevels);
   }

   //=== GLOBAL BASKET TARGET CHECK ====================================
   double target = CloseTarget();
   if(net >= target)
   {
      DeletePendings();
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      ProcessClose();
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   // Log new fill
   if(pos > m_prevPosCount)
   {
      PrintFormat("[GRID FILL] fill #%d | net=$%.2f | buyLot=%.2f | sellLot=%.2f | phase=%s",
                  pos, net, buyLot, sellLot, m_phase);
   }

   // Maintain Dynamic Calculated Reversal / Recovery Loop
   SyncSinglePending(buys, sells, buyLot, sellLot, net);

   m_prevPosCount = pos;
   DrawVisual();
}

//+------------------------------------------------------------------+
//| Dynamic Single Reversal & Alternating Recovery Synchronization   |
//+------------------------------------------------------------------+
void SyncSinglePending(int buys, int sells, double buyLot, double sellLot, double net)
{
   if(buys == 0 && sells == 0)
   {
      DeletePendings();
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   int pos = buys + sells;

   // 1. Determine dominant direction and required recovery pending direction
   // If Buy volume is dominant -> we need ONE SellStop (-1) below
   // If Sell volume is dominant -> we need ONE BuyStop (+1) above
   int recDir = (buyLot >= sellLot) ? -1 : 1;
   ENUM_ORDER_TYPE recType = (recDir > 0) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   ENUM_ORDER_TYPE oppType = (recDir > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;

   // 2. REVERSAL HIT TRANSITION:
   // When both buys and sells are open (Recovery phase), IMMEDIATELY DELETE all un-triggered orders of oppType!
   if(buys > 0 && sells > 0)
   {
      DeleteAllOfType(oppType);
   }

   // 3. Collect and manage the single recovery stop
   ulong  t[];
   double p[];
   CollectPendings(recType, t, p);
   SortPendings(recType, t, p);
   int have = ArraySize(t);

   // In Recovery phase or when opposite side, only keep ONE recovery order
   if(buys > 0 && sells > 0)
   {
      for(int i = 1; i < have; i++)
         m_trade.OrderDelete(t[i]);
      if(have > 1) have = 1;
   }
   else
   {
      // In Trending phase (e.g. only Buys open): keep only ONE SellStop below
      // (while the 20 BuyStops above remain intact)
      if(recType == ORDER_TYPE_SELL_STOP)
      {
         for(int i = 1; i < have; i++)
            m_trade.OrderDelete(t[i]);
         if(have > 1) have = 1;
      }
      else if(recType == ORDER_TYPE_BUY_STOP)
      {
         for(int i = 1; i < have; i++)
            m_trade.OrderDelete(t[i]);
         if(have > 1) have = 1;
      }
   }

   double minDist = MinDist();
   double revDist = ReverseMinDist();

   double price;
   if(recDir > 0)
   {
      price = ask + revDist;
      if(InpBeyondAllEntries)
      {
         double hiAll = HighestEntryAll();
         if(hiAll > 0 && price < hiAll + minDist) price = hiAll + minDist;
      }
      if(price < ask + minDist) price = ask + minDist;
   }
   else
   {
      price = bid - revDist;
      if(InpBeyondAllEntries)
      {
         double loAll = LowestEntryAll();
         if(loAll > 0 && price > loAll - minDist) price = loAll - minDist;
      }
      if(price > bid - minDist) price = bid - minDist;
   }
   price = NormalizeDouble(price, _Digits);

   // Calculate exact mathematically required recovery lot
   double lot = RecoveryLot(recDir, net, price, buyLot, sellLot, buyLot + sellLot);
   if(lot < InpStartLot) return;

   bool   snap    = (m_recoverDir != recDir);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;

   if(have >= 1)
   {
      if(!OrderSelect(t[0])) return;
      double had    = OrderGetDouble(ORDER_PRICE_OPEN);
      double hadLot = OrderGetDouble(ORDER_VOLUME_CURRENT);
      bool   valid  = (recDir > 0) ? (had >= ask + minDist) : (had <= bid - minDist);

      if(!snap)
      {
         // Ratchet: recovery lot only ever GROWS inside one leg
         if(lot < hadLot + lotStep - 0.0000001)
            lot = hadLot;
         if(valid && MathAbs(lot - hadLot) < 0.0005)
         {
            m_recoverNet = net;
            m_recoverDir = recDir;
            return;
         }
         if(valid)
            price = had; // keep the anchor price, only grow the lot size!
      }
      ReplacePending(t[0], recType, lot, price);
   }
   else
   {
      if(recDir > 0 && price <= ask) return;
      if(recDir < 0 && price >= bid) return;
      SendPendingSafe(recType, lot, price, "Recovery");
      m_recoveryArmedAt = TimeCurrent();
   }

   if(snap) m_recoveryArmedAt = TimeCurrent();

   m_recoverNet = net;
   m_recoverDir = recDir;
   m_state = StringFormat("%s LIVE — %s recovery (%.2f lot) armed @ %.*f",
                          (buyLot >= sellLot ? "BUY" : "SELL"),
                          (recDir > 0 ? "BUY" : "SELL"), lot, _Digits, price);
}

//+------------------------------------------------------------------+
//| Exact Mathematical Recovery Lot Calculation                      |
//| Sized so that a 30-pip ($3.00) move from 'stopPrice' produces    |
//| the exact master basket net profit target ($30.00 USD).          |
//+------------------------------------------------------------------+
double RecoveryLot(int recDir, double net, double stopPrice,
                   double buyLot, double sellLot, double totalLots)
{
   double vpp  = ValuePerPrice();
   double move = RecoverMovePrice(); // $3.00 price move = 30 pips
   if(move < 0.20) move = 0.20;

   // Target exit price after the 30-pip recovery move
   double targetPrice = (recDir > 0) ? (stopPrice + move) : (stopPrice - move);

   // Calculate what the floating profit/loss of all existing positions will be at targetPrice
   double existingProfitAtTarget = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double openPx = PositionGetDouble(POSITION_PRICE_OPEN);
      ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      
      if(pType == POSITION_TYPE_BUY)
         existingProfitAtTarget += vol * (targetPrice - openPx) * vpp;
      else
         existingProfitAtTarget += vol * (openPx - targetPrice) * vpp;
   }

   // Master profit target ($30) + spread allowance
   double target = InpCloseProfitUSD;
   if(target < 0.02) target = 0.02;
   target += SpreadCostUSD(totalLots + InpStartLot);

   // Required profit from the new recovery position alone
   double neededFromNew = target - existingProfitAtTarget;
   if(neededFromNew <= 0)
      neededFromNew = target;

   double denom = move * vpp;
   if(denom < 0.01) denom = 0.01;

   double lot = neededFromNew / denom;

   // Guarantee dominant volume
   double oppVol = (recDir > 0) ? sellLot : buyLot;
   double myVol  = (recDir > 0) ? buyLot  : sellLot;
   double minDominantLot = (oppVol > 0) ? (oppVol * 1.5 + InpStartLot - myVol) : (InpStartLot * 2.0);
   if(lot < minDominantLot) lot = minDominantLot;

   // Hard max ceiling
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;
   if(InpMaxBasketLots > 0 && (totalLots + lot) > InpMaxBasketLots)
   {
      lot = InpMaxBasketLots - totalLots;
      if(lot < InpStartLot) return 0.0;
   }

   if(lot < InpStartLot) lot = InpStartLot;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
//| Guard: enforce at most one position open per tick                |
//+------------------------------------------------------------------+
void EnforceOnePerTick()
{
   if(!InpOneTradePerTick) return;

   int now    = CountPos();
   int opened = now - m_prevPosCount;
   if(opened <= 1) return;

   ulong tk[];
   ArrayResize(tk, 0);
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      int n = ArraySize(tk);
      ArrayResize(tk, n + 1);
      tk[n] = t;
   }
   int n = ArraySize(tk);
   for(int i = 0; i < n; i++)
      for(int j = i + 1; j < n; j++)
         if(tk[j] > tk[i])
         {
            ulong tmp = tk[i]; tk[i] = tk[j]; tk[j] = tmp;
         }

   int kill = opened - 1;
   PrintFormat("[TICK GUARD] %d positions opened on one tick -> closing %d newest", opened, kill);
   for(int i = 0; i < kill && i < n; i++)
   {
      if(!m_trade.PositionClose(tk[i]))
         CloseManual(tk[i]);
   }
   m_prevPosCount = CountPos();
}

//+------------------------------------------------------------------+
//| Place exactly 20 grid orders with guaranteed execution           |
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

   double point   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double spread  = (ask > bid) ? (ask - bid) : 0;
   double minSafetyGap = MathMax(spread * 2.0, point * 30);
   if(step < minSafetyGap) step = minSafetyGap;

   double baseLot = DynamicStartLot();
   double startOffset = MathMax(minDist + point * 20, step);
   double basePrice = (type == ORDER_TYPE_BUY_STOP) ? (ask + startOffset) : (bid - startOffset);

   for(int i = 0; i < n; i++)
   {
      double lot = NormalizeLot(baseLot);

      double price;
      if(type == ORDER_TYPE_BUY_STOP)
      {
         price = basePrice + step * i;
         price = NormalizeDouble(price, _Digits);
         if(price <= ask + minDist) price = NormalizeDouble(ask + minDist + point * 10 + step * i, _Digits);
      }
      else
      {
         price = basePrice - step * i;
         price = NormalizeDouble(price, _Digits);
         if(price >= bid - minDist) price = NormalizeDouble(bid - minDist - point * 10 - step * i, _Digits);
      }
      if(SendPendingSafe(type, lot, price, StringFormat("%s #%d",
                         (type == ORDER_TYPE_BUY_STOP ? "BuyStop" : "SellStop"), i + 1)))
         placed++;
   }
   return placed;
}

//+------------------------------------------------------------------+
//| Cycle tracking helpers                                           |
//+------------------------------------------------------------------+
datetime CycleStart()
{
   datetime first = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(first == 0 || tm < first) first = tm;
   }
   return first;
}

//+------------------------------------------------------------------+
int CycleAgeMin()
{
   datetime s = CycleStart();
   if(s == 0) return 0;
   return (int)((TimeCurrent() - s) / 60);
}

//+------------------------------------------------------------------+
double DynamicStartLot()
{
   if(!InpAutoCompounding) return InpStartLot;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq <= 0) eq = AccountInfoDouble(ACCOUNT_BALANCE);
   if(eq <= 0) eq = InpRiskDepositPer001;
   double mult = eq / InpRiskDepositPer001;
   double lot = InpStartLot * mult;
   if(lot < 0.01) lot = 0.01;
   if(InpMaxBaseLot > 0 && lot > InpMaxBaseLot) lot = InpMaxBaseLot;
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;
   return NormalizeLot(lot);
}

//+------------------------------------------------------------------+
bool FlashCrashActive()
{
   if(!InpUseFlashCrashShield) return false;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, PERIOD_M1, 0, 2, rates) >= 2)
   {
      double range0 = rates[0].high - rates[0].low;
      double range1 = rates[1].high - rates[1].low;
      if(range0 >= InpMaxCandleRangeUSD || range1 >= InpMaxCandleRangeUSD)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double CloseTarget()
{
   int age = CycleAgeMin();
   if(InpForceCloseAfterMin > 0 && age >= InpForceCloseAfterMin)
      return -1e9;
   if(InpBreakEvenAfterMin > 0 && age >= InpBreakEvenAfterMin)
      return 0.0;

   double baseLot = DynamicStartLot();
   double scale = (InpStartLot > 0) ? (baseLot / InpStartLot) : 1.0;
   double t = InpCloseProfitUSD * scale;

   if(t < 0.02) t = 0.02;
   return t;
}

//+------------------------------------------------------------------+
int CalculatePMaxDirection(int bars = 100)
{
   if(bars < 30) bars = 100;
   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   ENUM_TIMEFRAMES tf = (InpPMaxTF == PERIOD_CURRENT) ? _Period : InpPMaxTF;
   int copied = CopyRates(_Symbol, tf, 0, bars, rates);
   if(copied < 30) return 0;
   
   int atrPeriod = InpPMaxAtrPeriod;
   double multiplier = InpPMaxMultiplier;
   int emaLength = InpPMaxMALength;
   
   double hl2[];
   double trVal[];
   ArrayResize(hl2, copied);
   ArrayResize(trVal, copied);
   
   for(int i = copied - 1; i >= 0; i--)
   {
      hl2[i] = (rates[i].high + rates[i].low) * 0.5;
      if(i == copied - 1)
         trVal[i] = rates[i].high - rates[i].low;
      else
         trVal[i] = MathMax(rates[i].high - rates[i].low,
                    MathMax(MathAbs(rates[i].high - rates[i+1].close),
                            MathAbs(rates[i].low - rates[i+1].close)));
   }
   
   double mavg[];
   ArrayResize(mavg, copied);
   double alpha = 2.0 / (emaLength + 1.0);
   mavg[copied - 1] = hl2[copied - 1];
   for(int i = copied - 2; i >= 0; i--)
      mavg[i] = alpha * hl2[i] + (1.0 - alpha) * mavg[i+1];
      
   double atrArr[];
   ArrayResize(atrArr, copied);
   atrArr[copied - 1] = trVal[copied - 1];
   for(int i = copied - 2; i >= 0; i--)
      atrArr[i] = (atrArr[i+1] * (atrPeriod - 1) + trVal[i]) / atrPeriod;
      
   double longStop = 0, shortStop = 0;
   double longStopPrev = 0, shortStopPrev = 0;
   int dir = 1;
   
   for(int i = copied - 15; i >= 0; i--)
   {
      double curAtr = atrArr[i];
      double curMA  = mavg[i];
      
      longStop = curMA - multiplier * curAtr;
      if(i < copied - 15 && curMA > longStopPrev)
         longStop = MathMax(longStop, longStopPrev);
         
      shortStop = curMA + multiplier * curAtr;
      if(i < copied - 15 && curMA < shortStopPrev)
         shortStop = MathMin(shortStop, shortStopPrev);
         
      if(dir == -1 && curMA > shortStopPrev)
         dir = 1;
      else if(dir == 1 && curMA < longStopPrev)
         dir = -1;
         
      longStopPrev  = longStop;
      shortStopPrev = shortStop;
   }
   
   return dir;
}

//+------------------------------------------------------------------+
int TrendDir()
{
   if(InpUsePMax)
      return CalculatePMaxDirection();
      
   if(!InpUseTrendFilter) return 0;
   if(m_emaFast == INVALID_HANDLE || m_emaSlow == INVALID_HANDLE) return 0;
   double f[], s[];
   ArraySetAsSeries(f, true);
   ArraySetAsSeries(s, true);
   if(CopyBuffer(m_emaFast, 0, 0, 2, f) < 1) return 0;
   if(CopyBuffer(m_emaSlow, 0, 0, 2, s) < 1) return 0;
   if(f[0] > s[0]) return  1;
   if(f[0] < s[0]) return -1;
   return 0;
}

//+------------------------------------------------------------------+
double HighestEntryAll()
{
   double best = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double px = PositionGetDouble(POSITION_PRICE_OPEN);
      if(px > best) best = px;
   }
   return best;
}

//+------------------------------------------------------------------+
double LowestEntryAll()
{
   double best = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double px = PositionGetDouble(POSITION_PRICE_OPEN);
      if(best == 0 || px < best) best = px;
   }
   return best;
}

//+------------------------------------------------------------------+
void DetectGap()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0 || ask <= bid) return;
   double mid = (ask + bid) * 0.5;
   if(m_lastMid > 0 && MathAbs(mid - m_lastMid) >= InpGapUSD)
      m_gapMode = true;
   else if(m_gapMode && !WideSpread() && MathAbs(mid - m_lastMid) < InpGapUSD * 0.2)
      m_gapMode = false;
   m_lastMid = mid;
}

//+------------------------------------------------------------------+
bool WideSpread()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= bid) return true;
   return ((ask - bid) >= InpWideSpreadPrice);
}

//+------------------------------------------------------------------+
double SpreadCostUSD(double lots)
{
   if(lots <= 0) lots = InpStartLot;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tv  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ask <= bid || tv <= 0 || ts <= 0) return 0.10;
   return (ask - bid) * (tv / ts) * lots;
}

//+------------------------------------------------------------------+
double ValuePerPrice()
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0) return 100.0;
   return tv / ts;
}

//+------------------------------------------------------------------+
double AtrPrice()
{
   if(!InpUseATR || m_atrHandle == INVALID_HANDLE) return 0;
   double a[];
   ArraySetAsSeries(a, true);
   if(CopyBuffer(m_atrHandle, 0, 0, 2, a) < 1) return 0;
   if(a[0] <= 0) return 0;
   return a[0] * MathMax(InpAtrMult, 0.1);
}

//+------------------------------------------------------------------+
double GridStep()
{
   double minDist = MinDist();
   double step    = MoneyToPrice(MathMax(InpGridStepUSD, 0.10), InpStartLot);
   double atr     = AtrPrice();
   if(atr > step) step = atr;
   double spr = SpreadPadDist();
   if(spr > step)     step = spr;
   if(step < minDist) step = minDist;
   return step;
}

//+------------------------------------------------------------------+
double ReverseMinDist()
{
   double d   = MoneyToPrice(MathMax(InpReverseDistUSD, 0.20), InpStartLot);
   double atr = AtrPrice();
   if(atr > d) d = atr;
   double md  = MinDist();
   double sp  = SpreadPadDist();
   if(d < md) d = md;
   if(d < sp) d = sp;
   return d;
}

//+------------------------------------------------------------------+
double RecoverMovePrice()
{
   double d = MoneyToPrice(MathMax(InpRecoverMoveUSD, 0.20), InpStartLot);
   double s = GridStep();
   if(d < s) d = s;
   return d;
}

//+------------------------------------------------------------------+
double SpreadPadDist()
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= bid) return MinDist();
   return (ask - bid) * MathMax(InpSpreadPad, 1.0);
}
void StretchPendingsFarther()
{
   // No-op: Standing stops remain stationary until spread normalizes
}

//+------------------------------------------------------------------+
void CollectPendings(ENUM_ORDER_TYPE type, ulong &tickets[], double &prices[])
{
   ArrayResize(tickets, 0);
   ArrayResize(prices, 0);
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != type) continue;
      int n = ArraySize(tickets);
      ArrayResize(tickets, n + 1);
      ArrayResize(prices,  n + 1);
      tickets[n] = t;
      prices[n]  = OrderGetDouble(ORDER_PRICE_OPEN);
   }
}

//+------------------------------------------------------------------+
void SortPendings(ENUM_ORDER_TYPE type, ulong &tickets[], double &prices[])
{
   int n = ArraySize(tickets);
   for(int i = 0; i < n; i++)
   {
      for(int j = i + 1; j < n; j++)
      {
         bool swap = (type == ORDER_TYPE_BUY_STOP) ? (prices[j] < prices[i])
                                                   : (prices[j] > prices[i]);
         if(swap)
         {
            double tp = prices[i];  prices[i]  = prices[j];  prices[j]  = tp;
            ulong  tt = tickets[i]; tickets[i] = tickets[j]; tickets[j] = tt;
         }
      }
   }
}

//+------------------------------------------------------------------+
void DeleteAllOfType(ENUM_ORDER_TYPE type)
{
   ulong  t[];
   double p[];
   CollectPendings(type, t, p);
   for(int i = 0; i < ArraySize(t); i++)
      m_trade.OrderDelete(t[i]);
}

//+------------------------------------------------------------------+
void ReplacePending(ulong ticket, ENUM_ORDER_TYPE type, double lot, double price)
{
   if(!OrderSelect(ticket))
   {
      SendPendingSafe(type, lot, price, (type == ORDER_TYPE_BUY_STOP) ? "BuyStop" : "SellStop");
      return;
   }
   double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
   double curVol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
   if(MathAbs(curVol - lot) < 0.001 && MathAbs(curPrice - price) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10)
      return;

   if(SendPendingSafe(type, lot, price, (type == ORDER_TYPE_BUY_STOP) ? "BuyStop" : "SellStop"))
   {
      m_trade.OrderDelete(ticket);
   }
}

//+------------------------------------------------------------------+
bool SendPendingSafe(ENUM_ORDER_TYPE type, double lot, double price, string comment)
{
   if(type == ORDER_TYPE_BUY_STOP)
   {
      if(m_trade.BuyStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
         return true;
   }
   else
   {
      if(m_trade.SellStop(lot, price, _Symbol, 0, 0, ORDER_TIME_GTC, 0, comment))
         return true;
   }
   return SendPending(type, lot, price, comment);
}

//+------------------------------------------------------------------+
bool SendPending(ENUM_ORDER_TYPE type, double lot, double price, string comment)
{
   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_RETURN, ORDER_FILLING_IOC, ORDER_FILLING_FOK};
   uint   last    = 0;
   string lastMsg = "";
   for(int f = 0; f < 3; f++)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_PENDING;
      req.symbol       = _Symbol;
      req.volume       = lot;
      req.price        = price;
      req.type         = type;
      req.type_filling = fillings[f];
      req.type_time    = ORDER_TIME_GTC;
      req.deviation    = InpSlippage;
      req.magic        = InpMagicNumber;
      req.comment      = comment;
      if(OrderSend(req, res) && (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
         return true;
      last = res.retcode;
      lastMsg = res.comment;
   }
   if(last == 10018 || last == 10017 || last == 10014) // Market Closed / Trade Disabled
      m_armRetryUntil = TimeCurrent() + 60;

   PrintFormat("[PENDING FAIL] %s lot=%.2f price=%.*f retcode=%u err=%d %s",
               comment, lot, _Digits, price, last, GetLastError(), lastMsg);
   return false;
}

//+------------------------------------------------------------------+
double MoneyToPrice(double usd, double lot)
{
   double tv = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tv <= 0 || ts <= 0 || lot <= 0) return 0.60;
   double perPrice = (tv / ts) * lot;
   if(perPrice <= 0) return 0.60;
   double dist = usd / perPrice;
   if(dist < ts * 10) dist = ts * 10;
   return dist;
}

//+------------------------------------------------------------------+
double MinDist()
{
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long   freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   long   extra  = MathMax(stops, freeze) + 10;
   if(extra < 10) extra = 10;
   return extra * point;
}

//+------------------------------------------------------------------+
void ProcessClose()
{
   DeletePendings();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(!OursPos(ticket)) continue;
      if(!m_trade.PositionClose(ticket))
         CloseManual(ticket);
   }
   if(CountPos() > 0) return;
   DeletePendings();
   if(CountPend() > 0) return;

   Print("[CLOSE DONE]");
   m_closingInProgress = false;
   m_gapMode           = false;
   ResetCycleState();
   m_closedBarTime     = iTime(_Symbol, _Period, 0); // Remember closed candle
   m_cooldownUntil     = MathMax(m_cooldownUntil, TimeCurrent() + MathMax(InpCooldownSec, 0));
   m_placeAfterClose   = false;
}

//+------------------------------------------------------------------+
void CloseManual(ulong ticket)
{
   if(!PositionSelectByTicket(ticket)) return;
   double vol = PositionGetDouble(POSITION_VOLUME);
   ENUM_POSITION_TYPE pType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
   ENUM_ORDER_TYPE oType = (pType == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   ENUM_ORDER_TYPE_FILLING fillings[] = {ORDER_FILLING_IOC, ORDER_FILLING_FOK, ORDER_FILLING_RETURN};
   for(int f = 0; f < 3; f++)
   {
      MqlTradeRequest req = {};
      MqlTradeResult  res = {};
      req.action       = TRADE_ACTION_DEAL;
      req.position     = ticket;
      req.symbol       = _Symbol;
      req.volume       = vol;
      req.type         = oType;
      req.price        = (oType == ORDER_TYPE_SELL)
                         ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                         : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      req.deviation    = InpSlippage * 5;
      req.magic        = InpMagicNumber;
      req.type_filling = fillings[f];
      if(OrderSend(req, res) && res.retcode == TRADE_RETCODE_DONE)
         return;
   }
}

//+------------------------------------------------------------------+
bool OursPos(ulong ticket)
{
   if(ticket == 0) return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol) return false;
   return ((ulong)PositionGetInteger(POSITION_MAGIC) == InpMagicNumber);
}

//+------------------------------------------------------------------+
int CountPos()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(OursPos(PositionGetTicket(i))) n++;
   return n;
}

//+------------------------------------------------------------------+
int CountPend()
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
      n++;
   }
   return n;
}

//+------------------------------------------------------------------+
void DeletePendings()
{
   for(int r = 0; r < 5; r++)
   {
      if(CountPend() == 0) return;
      for(int i = OrdersTotal() - 1; i >= 0; i--)
      {
         ulong t = OrderGetTicket(i);
         if(t == 0) continue;
         if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
         if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
         m_trade.OrderDelete(t);
      }
   }
}

//+------------------------------------------------------------------+
double Scan(int &buys, int &sells, int &buyPend, int &sellPend,
            double &buyLot, double &sellLot, double &buyPft, double &sellPft)
{
   buys = 0; sells = 0; buyPend = 0; sellPend = 0;
   buyLot = 0; sellLot = 0; buyPft = 0; sellPft = 0;
   double net = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      net += p;
      double vol = PositionGetDouble(POSITION_VOLUME);
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
      { buys++;  buyLot  += vol; buyPft  += p; }
      else
      { sells++; sellLot += vol; sellPft += p; }
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
bool EquityTrip()
{
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   if(balance <= 0) return false;
   double loss = balance - equity;
   double pct  = (loss / balance) * 100.0;

   // 1. Overall Account Drawdown check
   bool accountTrip = (InpMaxAllowedDrawdownUSD > 0 && loss >= InpMaxAllowedDrawdownUSD) ||
                      (InpMaxDrawdownPercent > 0 && pct >= InpMaxDrawdownPercent);

   // 2. Cycle Circuit Breaker: check current basket net loss
   int b = 0, s = 0, bp = 0, sp = 0;
   double bl = 0, sl = 0, bpft = 0, spft = 0;
   double net = Scan(b, s, bp, sp, bl, sl, bpft, spft);
   bool cycleTrip = (InpMaxCycleLossUSD > 0 && (b + s) > 0 && net <= -InpMaxCycleLossUSD);

   // 3. Friday Night Weekend Gap Protection
   bool fridayTrip = false;
   if(InpCloseFridayNight)
   {
      MqlDateTime dt;
      TimeCurrent(dt);
      if(dt.day_of_week == 5 && dt.hour >= 21) // Friday after 21:00 GMT
         fridayTrip = (b + s > 0 || bp + sp > 0);
   }

   if(accountTrip || cycleTrip || fridayTrip)
   {
      string reason = accountTrip ? "ACCOUNT MAX DRAWDOWN" : (cycleTrip ? "CYCLE CIRCUIT BREAKER" : "FRIDAY NIGHT CLOSE");
      PrintFormat("[EMERGENCY CLOSE: %s] net $%.2f | loss $%.2f (%.1f%%)", reason, net, loss, pct);
      m_closingInProgress = true;
      m_placeAfterClose   = false;
      if(cycleTrip)
         m_cooldownUntil  = TimeCurrent() + 3600; // 60 minutes cool-off after circuit breaker!
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(OursPos(t)) m_trade.PositionClose(t);
      }
      DeletePendings();
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lotStep <= 0) lotStep = 0.01;
   if(minLot  <= 0) minLot  = 0.01;
   lot = MathRound((lot - minLot) / lotStep) * lotStep + minLot;
   if(lot < minLot) lot = minLot;
   if(lot > maxLot) lot = maxLot;
   return NormalizeDouble(lot, 2);
}

//+------------------------------------------------------------------+
void DrawVisual()
{
   if(!InpShowVisual) return;

   int    buys = 0, sells = 0, buyPend = 0, sellPend = 0;
   double buyLot = 0, sellLot = 0, buyPft = 0, sellPft = 0;
   double net = Scan(buys, sells, buyPend, sellPend, buyLot, sellLot, buyPft, sellPft);

   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double step = GridStep();
   int    age  = CycleAgeMin();

   // Clean previous visual lines
   ObjectsDeleteAll(0, VIS_PREFIX + "Line_");

   // Draw each active pending order line dynamically on the visual chart
   int bCount = 0, sCount = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(OrderGetString(ORDER_SYMBOL) != _Symbol) continue;
      if((ulong)OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;

      ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      double price = OrderGetDouble(ORDER_PRICE_OPEN);
      double vol   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      string comment = OrderGetString(ORDER_COMMENT);

      bool isRecovery = (StringFind(comment, "Recovery") >= 0);

      if(type == ORDER_TYPE_BUY_STOP)
      {
         bCount++;
         string name = StringFormat("%sLine_Buy_%I64u", VIS_PREFIX, ticket);
         color clr = isRecovery ? clrGold : clrDodgerBlue;
         string label = StringFormat("[BUY STOP %s (%.2f @ %.*f)]", (isRecovery ? "REVERSAL" : StringFormat("#%d", bCount)), vol, _Digits, price);
         HLine(name, price, clr, label);
      }
      else if(type == ORDER_TYPE_SELL_STOP)
      {
         sCount++;
         string name = StringFormat("%sLine_Sell_%I64u", VIS_PREFIX, ticket);
         color clr = isRecovery ? clrGold : clrOrangeRed;
         string label = StringFormat("[SELL STOP %s (%.2f @ %.*f)]", (isRecovery ? "REVERSAL" : StringFormat("#%d", sCount)), vol, _Digits, price);
         HLine(name, price, clr, label);
      }
   }

   if(m_basketTP > 0) HLine(VIS_PREFIX + "TP", m_basketTP, clrLime, StringFormat(">>> BASKET TP (Target $%.2f)", CloseTarget()));
   else               ObjectDelete(0, VIS_PREFIX + "TP");

   string st = m_state;
   if(m_closingInProgress) st = "CLOSING ALL";
   else if(m_gapMode)      st = "GAP MODE";

   double peakDisplay = (m_trendPeakNet > -1e8) ? m_trendPeakNet : 0.0;

   Comment(
      "\n  =======================================================",
      "\n  ⚡ GoldQuantumHedger — 20-Order Signal Ladder System",
      "\n  =======================================================",
      "\n  PHASE: ", m_phase,
      "   |   Target Profit: $", DoubleToString(CloseTarget(), 2),
      "   |   Peak Net: $", DoubleToString(peakDisplay, 2),
      "\n  Basket TP: ", (m_basketTP > 0 ? DoubleToString(m_basketTP, _Digits) : "-"),
      "   |   Grid Step: $", DoubleToString(step, 2),
      "   |   Spread: $", DoubleToString(ask - bid, 2),
      "\n  -------------------------------------------------------",
      "\n  STATUS: ", st,
      "\n  -------------------------------------------------------",
      "\n  🟢 BUY Positions:  ", buys,  "   Lots: ", DoubleToString(buyLot, 2),  "   Profit: $", DoubleToString(buyPft, 2),  "   (Pending: ", buyPend, ")",
      "\n  🔴 SELL Positions: ", sells, "   Lots: ", DoubleToString(sellLot, 2), "   Profit: $", DoubleToString(sellPft, 2), "   (Pending: ", sellPend, ")",
      "\n  💰 CURRENT NET PROFIT: $", DoubleToString(net, 2),
      "\n  =======================================================\n"
   );
   ChartRedraw(0);
}

//+------------------------------------------------------------------+
void HLine(string name, double price, color clr, string text)
{
   if(price <= 0) return;
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
      ObjectSetInteger(0, name, OBJPROP_COLOR, clr);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_SOLID);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, false);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   }
   else
   {
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   }
}
//+------------------------------------------------------------------+

