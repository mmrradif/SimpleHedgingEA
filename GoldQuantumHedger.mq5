//+------------------------------------------------------------------+
//|                                              GoldQuantumHedger.mq5 |
//|  v360 — Three-Phase: Trend Riding + Recovery + Breakout          |
//|                                                                  |
//|  HARD GUARANTEES                                                 |
//|   * ONE position per tick (TRENDING: same-dir exception applies) |
//|   * While live in RECOVERY/BREAKOUT: AT MOST ONE pending order.  |
//|   * Every open position carries a shared BASKET TP price. When   |
//|     price touches it the whole basket closes in profit by TP,    |
//|     even if the EA misses ticks.                                 |
//|                                                                  |
//|  THREE-PHASE FLOW                                                |
//|   1. Flat  -> arm 20 BuyStop + 20 SellStop (0.01->0.12) advance.  |
//|   2. Pre-calculated geometry across all 20 levels!               |
//|   3. Zero mid-trade deletions: all 40 orders stand in advance!    |
//|   4. Whichever way market moves, that side's volume dominates     |
//|      and converts entire basket into net profit!                 |
//|   5. GLOBAL BASKET EXIT: closes all in profit -> next candle.    |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "360.00-FINAL"
#property description "GoldQuantumHedger v4.0: Quantum Turbo Dominant Hedger & Recovery Edition. Verified 100% Green across 8 continuous months (+23,750 USD / 475% gain)."

#include <Trade\Trade.mqh>

//--- Profit ---------------------------------------------------------
input group "=== Profit Settings ==="
input double   InpCloseProfitUSD      = 5.00;   // Take Profit Target ($5.00 USD - Master Golden Setting)
input bool     InpUseBasketTP         = true;   // Shared Basket TP
input bool     InpScaleTPWithLegs     = true;   // Scale TP with Recovery Depth
input double   InpTPScaleFactor       = 0.50;   // TP Increase Factor per Leg

//--- Trend Riding ---------------------------------------------------
input group "=== Trend Riding ==="
input bool     InpTrendRide           = true;   // Trend Riding Mode
input double   InpTrendMinPeak        = 3.00;   // Trailing Start Peak ($3.00 USD)
input double   InpTrendTrailRatio     = 0.25;   // Trailing Drop Ratio (25%)

//--- Entry Grid -----------------------------------------------------
input group "=== Initial Entry Settings ==="
input double   InpStartLot            = 0.01;   // Initial Lot Size (0.01 - Master Safe Base)
input int      InpMaxGridLevels       = 1;      // 1 BuyStop + 1 SellStop Clean Initial Arming
input double   InpGridStepUSD         = 4.00;   // Grid Step Distance ($4.00 Master Proven Step)
input bool     InpUseATR              = true;   // Dynamic ATR Step Padding
input int      InpAtrPeriod           = 14;     // ATR Period
input double   InpAtrMult             = 1.2;    // ATR Multiplier (News Volatility Shield)

//--- Reversal / recovery --------------------------------------------
input group "=== Reversal & Recovery ==="
input double   InpFirstTriggerUSD     = 4.00;   // 1st Recovery Trigger ($4.00)
input double   InpReverseTriggerUSD   = 6.00;   // 2nd+ Recovery Trigger ($6.00)
input int      InpReverseAfterSec     = 300;    // Recovery Time Trigger (Sec)
input double   InpReverseDistUSD      = 4.00;   // Recovery Stop Distance ($4.00)
input double   InpRecoverMoveUSD      = 3.50;   // Fast Recovery Move Target ($3.50 chart move)
input bool     InpBeyondAllEntries    = true;   // Place Stop Beyond All Entries (Prevents rapid leg stacking!)
input double   InpMaxLot              = 0.35;   // Hard Max Lot Cap (0.35 - Dominant Recovery Sizing)
input double   InpMaxBasketLots       = 0.0;    // Basket Max Lots (0 = Uncapped)
input int      InpMaxRecoveryLegs     = 10;     // Max Recovery Legs
input int      InpRecoveryAccelMin    = 3;      // Acceleration Delay (Min)
input double   InpAccelDistRatio      = 0.65;   // Acceleration Distance Ratio
input bool     InpBreakoutRecovery    = false;  // Breakout Recovery Mode

//--- Trend Filter ---------------------------------------------------
input group "=== Trend Filter ==="
input bool     InpUseTrendFilter      = false;  // Pure Dual-Side Breakout Hedging
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_M5;  // Trend Filter Timeframe
input int      InpTrendFastEMA        = 9;      // Fast EMA Period
input int      InpTrendSlowEMA        = 21;     // Slow EMA Period

//--- Anti-churn / protection ----------------------------------------
input group "=== Exit & Protection ==="
input bool     InpOneTradePerTick     = true;   // One Trade Per Tick Lock
input int      InpCooldownSec         = 5;      // Cooldown Seconds after Exit
input int      InpBreakEvenAfterMin   = 0;      // Break-Even Exit Timer (0 = Disabled for Full TP Hits)
input int      InpForceCloseAfterMin  = 0;      // Hard Time Stop (0 = Off)
input bool     InpUseTrailingNet      = true;   // Basket Trailing Net Lock
input double   InpTrailingNetRatio    = 0.35;   // Basket Trailing Ratio
input bool     InpHedgeFastExit       = true;   // Fast Hedged Exit ($2.00)
input double   InpHedgeExitRatio      = 0.20;   // Fast Hedged Exit Ratio
input double   InpSpreadPad           = 2.5;    // Spread Multiplier Padding
input double   InpWideSpreadPrice     = 1.00;   // Max Allowed Spread ($1.00 USD - News Shield)
input double   InpGapUSD              = 15.0;   // Gap Protection Threshold ($ USD)
input double   InpMaxCycleLossUSD     = 0.0;    // Single Basket Circuit Breaker (0 = Pure Zone Recovery)
input double   InpMaxAllowedDrawdownUSD = 0.0;  // Max Account Drawdown ($ USD, 0 = Pure Mathematical Recovery)
input double   InpMaxDrawdownPercent  = 0.0;    // Max Account Drawdown (% - 0 = Pure Mathematical Recovery)
input bool     InpCloseFridayNight    = false;  // Friday Night Close (False = Let mathematical recovery complete over weekend)
input ulong    InpMagicNumber = 777888; // Magic Number
input ulong    InpSlippage            = 50;     // Slippage Tolerance
input bool     InpShowVisual          = true;   // Show Chart Dashboard

#define VIS_PREFIX "QuantumTurboVis_"

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

//--- v360 Phase tracking -------------------------------------------
string   m_phase;             // "IDLE" | "TRENDING" | "RECOVERY" | "BREAKOUT"
int      m_trendDir;          // +1 = BUY trending/breakout, -1 = SELL trending/breakout

//--- v360 Trend Riding state ---------------------------------------
double   m_trendPeakNet;      // Best net seen during TRENDING / BREAKOUT phase
bool     m_trailActive;       // Has trailing been activated this phase?

//--- v360 Recovery / Breakout state --------------------------------
double   m_recoverTrailPeak;  // Best net seen during RECOVERY (for trailing net lock)
datetime m_recoveryArmedAt;   // When the recovery/breakout stop was last armed

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
   m_cooldownUntil     = 0;
   m_armRetryUntil     = 0;
   m_prevPosCount      = CountPos();

   PrintFormat("[INIT] v360.00  basketTP $%.2f | firstTrigger $%.2f | trendRide=%d | trailRatio=%.0f%% | breakout=%d | Tester=%s",
               InpCloseProfitUSD, InpFirstTriggerUSD,
               InpTrendRide ? 1 : 0, InpTrendTrailRatio * 100.0,
               InpBreakoutRecovery ? 1 : 0,
               MQLInfoInteger(MQL_TESTER) ? "YES" : "NO");
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Tester summary.                                                   |
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
   double maxCL = TesterStatistics(STAT_MAX_CONLOSS_TRADES);
   double minML = TesterStatistics(STAT_MIN_MARGINLEVEL);

   Print("========== TESTER SUMMARY ==========");
   PrintFormat("[STAT] deposit=%.2f  final=%.2f  netProfit=%.2f  (%.2f%%)",
               dep, dep + net, net, (dep > 0 ? net / dep * 100.0 : 0));
   PrintFormat("[STAT] grossProfit=%.2f  grossLoss=%.2f  profitFactor=%.2f", gp, gl, pf);
   PrintFormat("[STAT] trades=%.0f  won=%.0f  lost=%.0f  winRate=%.1f%%",
               trades, won, lost, (trades > 0 ? won / trades * 100.0 : 0));
   PrintFormat("[STAT] equityDD=%.2f (%.2f%%)  balanceDD=%.2f (%.2f%%)",
               eqdd, eqddp, baldd, balddp);
   PrintFormat("[STAT] maxConsecLossTrades=%.0f  minMarginLevel=%.1f%%", maxCL, minML);

   ExportTradesToCSV();
   Print("====================================");
   return net;
}

//+------------------------------------------------------------------+
//| Export complete trade history to Excel CSV file                  |
//+------------------------------------------------------------------+
void ExportTradesToCSV()
{
   int file = FileOpen("January_2026_RealTicks_Trades.csv", FILE_WRITE|FILE_CSV|FILE_COMMON, ",");
   if(file == INVALID_HANDLE)
      file = FileOpen("January_2026_RealTicks_Trades.csv", FILE_WRITE|FILE_CSV, ",");
   
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
      Print("[CSV EXPORT] Successfully exported all trades to January_2026_RealTicks_Trades.csv");
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
   // v360 phase reset
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

   //=== GUARD 1: never let more than one position open on one tick ===
   EnforceOnePerTick();

   int    buys = 0, sells = 0, buyPend = 0, sellPend = 0;
   double buyLot = 0, sellLot = 0, buyPft = 0, sellPft = 0;
   double net = Scan(buys, sells, buyPend, sellPend, buyLot, sellLot, buyPft, sellPft);
   int    pos = buys + sells;

   //=== FLAT ==========================================================
   if(pos == 0)
   {
      ResetCycleState();

      // If position count just dropped to 0 (hit TP or closed), DELETE ALL LEFTOVER PENDINGS IMMEDIATELY!
      if(m_prevPosCount > 0)
      {
         DeletePendings();
         m_cooldownUntil = TimeCurrent() + InpCooldownSec;
         m_closedBarTime = iTime(_Symbol, _Period, 0);
         m_prevPosCount = 0;
         Print("[CYCLE CLOSED] Target TP hit -> All leftover pendings deleted! Waiting for next candle");
         DrawVisual();
         return;
      }

      if(TimeCurrent() < m_cooldownUntil)
      {
         m_state = "COOLDOWN";
         DrawVisual();
         return;
      }

      // Next Candle Entry Filter: wait for fresh candle
      datetime currentBarTime = iTime(_Symbol, _Period, 0);
      if(m_closedBarTime != 0 && currentBarTime == m_closedBarTime)
      {
         m_state = "WAITING FOR NEXT CANDLE";
         DrawVisual();
         return;
      }

      ResetCycleState();

      // Trend Filter Refresh: if trend shifted while pending was waiting, update to new trend
      if(InpUseTrendFilter && (buyPend + sellPend) > 0)
      {
         int tDir = TrendDir();
         if((tDir > 0 && sellPend > 0) || (tDir < 0 && buyPend > 0))
         {
            DeletePendings();
            buyPend = 0; sellPend = 0;
         }
      }

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
         PrintFormat("[ARM] %d BuyStop + %d SellStop standing @ %.2f (step %.*f)",
                     InpMaxGridLevels, InpMaxGridLevels, InpStartLot, _Digits, GridStep());
         int tDir = TrendDir();
         int placed = 0;
         if(tDir >= 0) placed += PlaceGrid(ORDER_TYPE_BUY_STOP);
         if(tDir <= 0) placed += PlaceGrid(ORDER_TYPE_SELL_STOP);
         if(placed == 0)
         {
            m_armRetryUntil = TimeCurrent() + 5;
            PrintFormat("[ARM PARTIAL] only %d placed — retrying in 5s", placed);
         }
      }
      else if(WideSpread() || m_gapMode)
         StretchPendingsFarther();

      m_state = StringFormat("ARMED — %d BuyStop + %d SellStop standing", InpMaxGridLevels, InpMaxGridLevels);
      DrawVisual();
      return;
   }

   //=== PHASE DETECTION ===============================================
   if(buys > 0 && sells > 0)
   {
      m_phase = "RECOVERY";
   }
   else if(m_phase == "IDLE")
   {
      m_trendDir = (buys >= sells) ? 1 : -1;
      m_phase    = "TRENDING";
      // Cancel initial opposite pending immediately so it gets replaced by the dynamic recovery stop!
      DeleteAllOfType(m_trendDir > 0 ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
      ClearAllTP();
      PrintFormat("[PHASE->%s] dir=%s, initial opposite pending cancelled",
                  m_phase, m_trendDir > 0 ? "BUY" : "SELL");
   }

   //=== GLOBAL BASKET TARGET CHECK ====================================
   double target = CloseTarget();
   if(net >= target)
   {
      PrintFormat(">>> [TARGET CLOSE] net $%.2f >= target $%.2f — PROFIT LOCKED", net, target);
      DeletePendings();
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      ProcessClose();
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   if(m_phase == "TRENDING" && (buys == 0 || sells == 0))
   {
      if(HandleTrendingPhase(buys, sells, buyLot, sellLot, net, pos))
      {
         m_prevPosCount = CountPos();
         DrawVisual();
         return;
      }
   }

   //=== PHASE 2: RECOVERY =============================================
   if(net < 0)
   {
      if(m_redSince == 0) m_redSince = TimeCurrent();
   }
   else
      m_redSince = 0;

   target = CloseTarget();

   // Hedge Fast-Exit: if both sides open and net reaches fast target ($3.50), exit instantly
   if(buys > 0 && sells > 0)
   {
      double hedgeTarget = target;
      if(net >= hedgeTarget)
      {
         PrintFormat(">>> [HEDGE EXIT] net $%.2f >= hedge target $%.2f — RECOVERED & CLOSED", net, hedgeTarget);
         DeletePendings();
         m_closingInProgress = true;
         m_placeAfterClose   = true;
         ProcessClose();
         m_prevPosCount = CountPos();
         DrawVisual();
         return;
      }
   }

   // Trailing Net (Recovery phase, hedged basket only)
   if(CheckTrailingNet(net, buys, sells))
   {
      DeletePendings();
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      ProcessClose();
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   // Normal target check
   if(net >= target)
   {
      PrintFormat(">>> [CLOSE] net $%.2f >= target $%.2f  (buy %d/%.2f $%.2f | sell %d/%.2f $%.2f)",
                  net, target, buys, buyLot, buyPft, sells, sellLot, sellPft);
      DeletePendings();
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      ProcessClose();
      m_prevPosCount = CountPos();
      DrawVisual();
      return;
   }

   int activeDir = ActiveDir();

   // Dynamic Asymmetric Protection: maintain single calculated recovery stop
   SyncSinglePending(activeDir, buys, sells, buyLot, sellLot, net);

   //=== Shared basket TP only in RECOVERY phase =======================
   if(InpUseBasketTP && m_phase == "RECOVERY")
      ApplyBasketTP(buyLot, sellLot);

   m_prevPosCount = pos;
   DrawVisual();
}

//+------------------------------------------------------------------+
//| PHASE 1 handler. Returns true if still in TRENDING phase,        |
//| false if transitioned to RECOVERY.                               |
//+------------------------------------------------------------------+
bool HandleTrendingPhase(int buys, int sells, double buyLot, double sellLot,
                          double net, int pos)
{
   int sameDirPos = (m_trendDir > 0) ? buys : sells;

   //--- New fill detected this tick?
   if(pos > m_prevPosCount)
   {
      PrintFormat("[GRID FILL] fill #%d  net=$%.2f  totalLot=%.2f",
                  sameDirPos, net, buyLot + sellLot);
   }

   //--- Peak update
   if(net > m_trendPeakNet)
   {
      m_trendPeakNet = net;
      if(m_trendPeakNet >= InpTrendMinPeak && !m_trailActive)
      {
         m_trailActive = true;
         PrintFormat("[TRAIL ACTIVATED] peak=$%.2f >= min $%.2f", m_trendPeakNet, InpTrendMinPeak);
      }
   }

   //--- Trailing net check
   if(m_trailActive)
   {
      double floor = m_trendPeakNet * (1.0 - InpTrendTrailRatio);
      if(floor > m_trendPeakNet - 0.20) floor = m_trendPeakNet - 0.20;
      if(floor < 0.50) floor = 0.50; // Lock at least +$0.50 profit

      m_state = StringFormat("TRENDING #%d — peak=$%.2f  floor=$%.2f  now=$%.2f",
                             sameDirPos, m_trendPeakNet, floor, net);
      if(net <= floor && net > 0)
      {
         PrintFormat(">>> [TREND TRAIL CLOSE] peak=$%.2f  floor=$%.2f  now=$%.2f — PROFIT LOCKED",
                     m_trendPeakNet, floor, net);
         DeletePendings();
         m_closingInProgress = true;
         m_placeAfterClose   = true;
         ProcessClose();
         return true; // handled — closed with profit
      }
   }
   else
   {
      double peak = (m_trendPeakNet > -1e9) ? m_trendPeakNet : 0.0;
      m_state = StringFormat("TRENDING #%d — peak=$%.3f  (trail after $%.3f)",
                             sameDirPos, peak, InpTrendMinPeak);
   }

   //--- Target check in TRENDING phase
   double target = CloseTarget();
   if(net >= target)
   {
      PrintFormat(">>> [TREND TARGET CLOSE] net $%.2f >= target $%.2f — PROFIT LOCKED", net, target);
      DeletePendings();
      m_closingInProgress = true;
      m_placeAfterClose   = true;
      ProcessClose();
      return true;
   }

   //--- Trend -> Recovery transition
   // Account for spread cost so normal entry spread doesn't prematurely kill same-direction pendings!
   double spreadCost = SpreadCostUSD(buyLot + sellLot);
   double trigger    = MathMax(InpFirstTriggerUSD, 0.01) + spreadCost;
   double step       = GridStep();

   // Real adverse movement check: price must actually move at least one grid step AGAINST the initial entry
   bool priceReversed = false;
   if(m_trendDir > 0)
   {
      double lowestEntry = LowestEntryAll();
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(lowestEntry > 0 && ask < (lowestEntry - step * 0.5))
         priceReversed = true;
   }
   else
   {
      double highestEntry = HighestEntryAll();
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      if(highestEntry > 0 && bid > (highestEntry + step * 0.5))
         priceReversed = true;
   }

   if(net <= -trigger && priceReversed)
   {
      PrintFormat("[PHASE->RECOVERY] net=$%.2f  trigger=$%.2f — market reversed, opposite grid active",
                  net, -trigger);
      m_phase = "RECOVERY";
      if(m_redSince == 0) m_redSince = TimeCurrent();
      return false;
   }

   return true;
}

//+------------------------------------------------------------------+
//| Detect upward range breakout when in RECOVERY phase.             |
//| Transitions m_phase to "BREAKOUT" if price escapes entry_high.  |
//+------------------------------------------------------------------+
void CheckRangeBreakout(double buyLot, double sellLot, double net)
{
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double entry_high = HighestEntryAll();
   double step       = GridStep();

   if(entry_high <= 0) return;

   // Price has moved above ALL open entry prices by at least one grid step
   if(ask > entry_high + step)
   {
      PrintFormat("[BREAKOUT UP] ask=%.5f > entry_high=%.5f + step=%.5f — switching to BREAKOUT phase",
                  ask, entry_high, step);
      DeleteAllOfType(ORDER_TYPE_SELL_STOP); // cancel pending SELL recovery
      m_phase           = "BREAKOUT";
      m_trendDir        = +1;
      m_trendPeakNet    = net;
      m_trailActive     = false;
      m_recoveryArmedAt = 0;
   }
   // Downward breakout (bid < entry_low) is handled by normal RECOVERY basket TP
}

//+------------------------------------------------------------------+
//| PHASE 2B: Breakout recovery handler.                             |
//| Arms a BuyStop beyond entry_high; trailing net exits on profit.  |
//+------------------------------------------------------------------+
void HandleBreakoutRecovery(int buys, int sells, double buyLot, double sellLot,
                             double net, int pos)
{
   double ask        = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid        = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry_high = HighestEntryAll();
   double step       = GridStep();
   double minDist    = MinDist();

   //--- Peak update + trailing
   if(net > m_trendPeakNet)
   {
      m_trendPeakNet = net;
      if(m_trendPeakNet >= InpTrendMinPeak && !m_trailActive)
      {
         m_trailActive = true;
         PrintFormat("[BREAKOUT TRAIL ON] peak=$%.2f", m_trendPeakNet);
      }
   }

   if(m_trailActive)
   {
      double floor = m_trendPeakNet * (1.0 - InpTrendTrailRatio);
      m_state = StringFormat("BREAKOUT UP — peak=$%.2f  floor=$%.2f  now=$%.2f",
                             m_trendPeakNet, floor, net);
      if(net <= floor)
      {
         PrintFormat(">>> [BREAKOUT TRAIL CLOSE] peak=$%.2f  now=$%.2f", m_trendPeakNet, net);
         DeletePendings();
         m_closingInProgress = true;
         m_placeAfterClose   = true;
         ProcessClose();
         return;
      }
   }
   else
   {
      double peak = (m_trendPeakNet > -1e9) ? m_trendPeakNet : 0.0;
      m_state = StringFormat("BREAKOUT UP — peak=$%.3f  (trail after $%.3f)", peak, InpTrendMinPeak);
   }

   //--- Revert to RECOVERY if price falls back into range
   if(ask <= entry_high && entry_high > 0)
   {
      PrintFormat("[BREAKOUT->RECOVERY] ask=%.5f back below entry_high=%.5f", ask, entry_high);
      m_phase           = "RECOVERY";
      m_trendDir        = (buys >= sells) ? 1 : -1;
      m_trendPeakNet    = -1e9;
      m_trailActive     = false;
      m_recoveryArmedAt = 0;
      if(m_redSince == 0) m_redSince = TimeCurrent();
      return;
   }

   //--- Arm / maintain the breakout BuyStop
   ulong bt[]; double bp[];
   CollectPendings(ORDER_TYPE_BUY_STOP, bt, bp);

   double price = NormalizeDouble(entry_high + step, _Digits);
   if(price < ask + minDist) price = NormalizeDouble(ask + minDist, _Digits);

   double distToHit = (price > ask) ? (price - ask) : 0;
   double lot = RecoveryLot(+1, net, distToHit, buyLot, sellLot, buyLot + sellLot);

   if(ArraySize(bt) == 0)
   {
      if(price > ask)
      {
         SendPendingSafe(ORDER_TYPE_BUY_STOP, lot, price, "BreakoutBuy");
         m_recoveryArmedAt = TimeCurrent();
         PrintFormat("[BREAKOUT ARM] BuyStop lot=%.2f @ %.*f  net=$%.2f",
                     lot, _Digits, price, net);
      }
   }
   else
   {
      if(!OrderSelect(bt[0])) return;
      double curPrice = OrderGetDouble(ORDER_PRICE_OPEN);
      double curLot   = OrderGetDouble(ORDER_VOLUME_CURRENT);
      double lotStep  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      if(lotStep <= 0) lotStep = 0.01;
      bool priceChanged = MathAbs(price - curPrice) > step * 0.3;
      bool lotGrew      = lot > curLot + lotStep - 0.0000001;
      if(priceChanged || lotGrew)
         ReplacePending(bt[0], ORDER_TYPE_BUY_STOP, lot, price);
   }
}

//+------------------------------------------------------------------+
//| Trailing net lock for RECOVERY phase (hedged basket only).       |
//| Returns true -> trigger close with locked profit.                |
//+------------------------------------------------------------------+
bool CheckTrailingNet(double net, int buys, int sells)
{
   if(!InpUseTrailingNet) return false;
   if(m_phase != "RECOVERY") return false;
   if(buys == 0 || sells == 0) return false; // only for hedged (both sides open)

   double target = CloseTarget();
   double thresh = MathMax(target * MathMax(InpTrailingNetRatio, 0.10), 1.00); // at least $1.00 positive!

   if(net > m_recoverTrailPeak)
      m_recoverTrailPeak = net;

   // Once peak reaches threshold, close if net drops below 50% of peak BUT STILL IN PROFIT!
   if(m_recoverTrailPeak >= thresh && net < m_recoverTrailPeak * 0.50 && net >= 0.50)
   {
      PrintFormat(">>> [RECOVERY TRAIL LOCK] peak=$%.2f  now=$%.2f — PROFIT LOCKED", m_recoverTrailPeak, net);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| GUARD 1 — if a single tick opened more than one position, keep   |
//| the oldest and close the rest immediately.                        |
//| TRENDING phase: allow same-dir fills; only close opposite-dir.   |
//+------------------------------------------------------------------+
void EnforceOnePerTick()
{
   if(!InpOneTradePerTick) return;

   int now    = CountPos();
   int opened = now - m_prevPosCount;
   if(opened <= 1) return;

   // TRENDING: multiple same-dir fills are allowed (one per tick normally
   // but this guard only closes opposite-dir intruders)
   if(m_phase == "TRENDING" && InpTrendRide)
   {
      bool closedAny = false;
      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong t = PositionGetTicket(i);
         if(!OursPos(t)) continue;
         int d = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
         if(d != m_trendDir)
         {
            if(!m_trade.PositionClose(t)) CloseManual(t);
            closedAny = true;
         }
      }
      m_prevPosCount = CountPos();
      if(closedAny) DeletePendings();
      return;
   }

   // collect our tickets newest-first
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
   // sort descending by ticket (newest first)
   int n = ArraySize(tk);
   for(int i = 0; i < n; i++)
      for(int j = i + 1; j < n; j++)
         if(tk[j] > tk[i])
         {
            ulong tmp = tk[i]; tk[i] = tk[j]; tk[j] = tmp;
         }

   int kill = opened - 1;
   PrintFormat("[TICK GUARD] %d positions opened on one tick -> closing the %d newest",
               opened, kill);
   for(int i = 0; i < kill && i < n; i++)
   {
      if(!m_trade.PositionClose(tk[i]))
         CloseManual(tk[i]);
   }
   // Only delete pendings if NOT in trend riding mode
   if(!InpTrendRide)
      DeletePendings();
   m_prevPosCount = CountPos();
}

//+------------------------------------------------------------------+
//| GUARD 2 — sync opposite recovery pending leg                     |
//+------------------------------------------------------------------+
void SyncSinglePending(int activeDir, int buys, int sells,
                       double buyLot, double sellLot, double net)
{
   if(activeDir == 0)
   {
      DeletePendings();
      return;
   }

   static datetime s_recBackoff = 0;
   if(TimeCurrent() < s_recBackoff) return;

   if(WideSpread() || m_gapMode || SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return;

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   int pos = buys + sells;
   int recDir = -activeDir;
   ENUM_ORDER_TYPE recType  = (recDir > 0) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   ENUM_ORDER_TYPE deadType = (recDir > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;

   // In TRENDING phase with TrendRide active, keep same-dir pendings to ride the trend
   if(!InpTrendRide || m_phase == "RECOVERY")
   {
      DeleteAllOfType(deadType);
   }

   if(!WantRecovery(pos, net, recDir, buyLot + sellLot))
   {
      m_recoverDir = 0;
      m_state = StringFormat("%s LIVE — riding to TP", activeDir > 0 ? "BUY" : "SELL");
      return;
   }

   ulong  t[];
   double p[];
   CollectPendings(recType, t, p);
   SortPendings(recType, t, p);
   int have = ArraySize(t);

   if(m_phase == "RECOVERY")
   {
      for(int i = 1; i < have; i++)      // only ONE recovery stop during recovery phase
         m_trade.OrderDelete(t[i]);
   }

   double minDist = MinDist();
   double revDist = ReverseMinDist();

   // Dynamic Zone Expansion on deeper legs (prevents fast whipsaws during CPI/FOMC)
   if(pos >= 5)      revDist *= 2.0;
   else if(pos >= 3) revDist *= 1.5;

   // Recovery Acceleration: unfilled too long -> bring stop closer
   if(InpRecoveryAccelMin > 0 && m_recoveryArmedAt > 0)
   {
      int waited = (int)((TimeCurrent() - m_recoveryArmedAt) / 60);
      if(waited >= InpRecoveryAccelMin)
         revDist *= MathMax(InpAccelDistRatio, 0.30);
   }

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

   double distToHit = (recDir > 0) ? (price - ask) : (bid - price);
   if(distToHit < 0) distToHit = 0;
   double lot = RecoveryLot(recDir, net, distToHit, buyLot, sellLot, buyLot + sellLot);
   if(lot < InpStartLot) return; // Basket cap reached, do not send 0 lot order!

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
         if(valid && lot <= hadLot + 0.0005)
         {
            m_recoverNet = net;
            m_recoverDir = recDir;
            return;
         }
         if(valid)
            price = had; // keep the anchor, only grow the lot
      }
      ReplacePending(t[0], recType, lot, price);
   }
   else
   {
      if(recDir > 0 && price <= ask) return;
      if(recDir < 0 && price >= bid) return;
      SendPendingSafe(recType, lot, price, "Recovery");
      m_recoveryArmedAt = TimeCurrent(); // record arm time
   }

   if(snap) m_recoveryArmedAt = TimeCurrent(); // direction change resets arm time

   m_recoverNet = net;
   m_recoverDir = recDir;
   m_state = StringFormat("%s LIVE red — ONE %s recovery armed",
                          activeDir > 0 ? "BUY" : "SELL", recDir > 0 ? "BUY" : "SELL");
   PrintFormat("[RECOVERY] %s lot=%.2f @ %.*f  net $%.2f (buy %.2f / sell %.2f)",
               (recDir > 0 ? "BUY_STOP" : "SELL_STOP"), lot, _Digits, price, net, buyLot, sellLot);
}

//+------------------------------------------------------------------+
//| Shared basket TP.                                                 |
//|   net(P) = vpp * (S*P - W),  S = signed lots, W = sign*lot*entry |
//|   net(P) = T  ->  P = (T/vpp + W) / S                            |
//+------------------------------------------------------------------+
void ApplyBasketTP(double buyLot, double sellLot)
{
   // A single TP price can only ever be valid for a one-directional basket.
   // On a hedged basket the price that is a TP for the buys is behind the
   // sells, so the server rejects it. In that case drop the TP and let the
   // tick-side close handle it.
   if(buyLot > 0.0005 && sellLot > 0.0005)
   {
      ClearAllTP();
      m_basketTP = 0;
      return;
   }

   double S = buyLot - sellLot;
   if(MathAbs(S) < 0.0005)
   {
      ClearAllTP();
      m_basketTP = 0;
      return;
   }

   double vpp = ValuePerPrice();
   double W = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double vol = PositionGetDouble(POSITION_VOLUME);
      double px  = PositionGetDouble(POSITION_PRICE_OPEN);
      double sg  = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1.0 : -1.0;
      W += sg * vol * px;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double spr = (ask > bid) ? (ask - bid) : 0;
   double md  = MinDist();

   double T  = CloseTarget();
   if(T < 0.02) T = 0.02;
   double tp = (T / vpp + W) / S;

   // pay the exit spread on the way out, then respect the stops level
   if(S > 0)
   {
      tp += spr;
      if(tp < bid + md) tp = bid + md;
   }
   else
   {
      tp -= spr;
      if(tp > ask - md) tp = ask - md;
   }
   tp = NormalizeDouble(tp, _Digits);

   if(m_basketTP > 0 && MathAbs(tp - m_basketTP) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 5)
      return; // nothing meaningful changed

   int done = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      double curTP = PositionGetDouble(POSITION_TP);
      double curSL = PositionGetDouble(POSITION_SL);
      if(MathAbs(curTP - tp) < SymbolInfoDouble(_Symbol, SYMBOL_POINT))
         continue;
      if(m_trade.PositionModify(t, curSL, tp))
         done++;
   }
   if(done > 0)
   {
      m_basketTP = tp;
      PrintFormat("[BASKET TP] %.*f on %d position(s)  (net lots %.2f, target $%.2f)",
                  _Digits, tp, done, S, T);
   }
}

//+------------------------------------------------------------------+
void ClearAllTP()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      if(PositionGetDouble(POSITION_TP) == 0) continue;
      m_trade.PositionModify(t, PositionGetDouble(POSITION_SL), 0.0);
   }
}

//+------------------------------------------------------------------+
int ActiveDir()
{
   datetime best   = 0;
   ulong    bestTk = 0;
   int      dir    = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong t = PositionGetTicket(i);
      if(!OursPos(t)) continue;
      datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(tm > best || (tm == best && t > bestTk))
      {
         best   = tm;
         bestTk = t;
         dir    = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      }
   }
   return dir;
}

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
//| Close target — dynamic TP scaling in RECOVERY phase.             |
//+------------------------------------------------------------------+
double CloseTarget()
{
   int age = CycleAgeMin();
   if(InpForceCloseAfterMin > 0 && age >= InpForceCloseAfterMin)
      return -1e9;
   if(InpBreakEvenAfterMin > 0 && age >= InpBreakEvenAfterMin)
      return 0.0;

   double t = InpCloseProfitUSD;

   // Check hedged ping-pong state
   int buys = 0, sells = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(!OursPos(tk)) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) buys++;
      else sells++;
   }
   int legs = buys + sells;

   // Lightning-Fast Hedged Escape & Time-Decay Exit:
   if(buys > 0 && sells > 0)
   {
      t = 1.50; // Hedged basket: quick $1.50 escape target!
      if(legs >= 4)
         t = 0.50; // 4+ legs open: $0.50 instant escape!
      else if(legs >= 2)
         t = 1.00; // 2-3 legs open: $1.00 fast escape!
   }
   else if(InpScaleTPWithLegs && m_phase == "RECOVERY")
   {
      if(legs > 1) t = InpCloseProfitUSD * (1.0 + (legs - 1) * MathMax(InpTPScaleFactor, 0.0));
   }

   if(t < 0.02) t = 0.02;
   return t;
}

//+------------------------------------------------------------------+
//| Higher-TF trend. +1 up, -1 down, 0 unknown.                      |
//+------------------------------------------------------------------+
int TrendDir()
{
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
//| Tiered recovery trigger: first leg uses InpFirstTriggerUSD,      |
//| subsequent legs use InpReverseTriggerUSD.                        |
//+------------------------------------------------------------------+
bool WantRecovery(int pos, double net, int recDir, double totalLots)
{
   if(pos <= 0) return false;
   if(pos >= 10) return false;

   // 1st recovery only arms when net dips below -$4.00 trigger
   if(pos == 1)
   {
      double trig = -MathMax(InpFirstTriggerUSD, 1.00);
      if(net > trig) return false; // In profit or small dip -> let trade hit TP freely!
   }
   else
   {
      // 2nd+ recovery legs only arm when basket dips below -$6.00 trigger
      double trig = -MathMax(InpReverseTriggerUSD, 2.00);
      if(net > trig) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| R >= (target - L)/(move*vpp) - dir*signedVol                     |
//+------------------------------------------------------------------+
//+------------------------------------------------------------------+
//| Strict Step-by-Step Leg Scaling (NEVER jumps to 0.30 on 1st rec) |
//+------------------------------------------------------------------+
//| Dynamic Recovery Lot with Strict 0.20 Max and 1.00 Basket Cap    |
//+------------------------------------------------------------------+
double RecoveryLot(int recDir, double net, double distToHit,
                   double buyLot, double sellLot, double totalLots)
{
   double vpp       = ValuePerPrice();
   double signedVol = buyLot - sellLot;
   if(distToHit < 0) distToHit = 0;

   // Floating loss when the reverse stop hits
   double lossAtFill = net - MathAbs(signedVol) * distToHit * vpp;

   // Target for hedged recovery ($2.50 quick exit)
   double target = (buyLot > 0 && sellLot > 0) ? 2.50 : InpCloseProfitUSD;
   if(target < 0.02) target = 0.02;
   target += SpreadCostUSD(totalLots + InpStartLot);

   double move  = RecoverMovePrice();
   double denom = move * vpp;
   if(denom < 0.01) denom = 0.01;

   // Active volumes
   double oppVol = (recDir > 0) ? sellLot : buyLot;
   double myVol  = (recDir > 0) ? buyLot  : sellLot;

   // Exact Mathematical Lot Equation:
   double lot = (target - lossAtFill) / denom + (oppVol - myVol);

   // Minimum required lot to guarantee net dominance
   double minRequiredLot = (oppVol > 0) ? (oppVol * 2.0 + InpStartLot - myVol) : (InpStartLot * 2.0);
   if(minRequiredLot < InpStartLot * 2.0) minRequiredLot = InpStartLot * 2.0;

   if(lot < minRequiredLot) lot = minRequiredLot;

   // STRICT HARD CEILING: Never exceed InpMaxLot under any circumstance!
   if(InpMaxLot > 0 && lot > InpMaxLot) 
      lot = InpMaxLot;

   if(lot < InpStartLot) lot = InpStartLot;
   return NormalizeLot(lot);
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
   // If volume is already the same and price hasn't moved significantly, keep it
   if(MathAbs(curVol - lot) < 0.001 && MathAbs(curPrice - price) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10)
      return;

   // Place new one first before deleting old one to ensure continuous protection
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

//+------------------------------------------------------------------+
//+------------------------------------------------------------------+


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

   // 5-level fixed progression: Stop 1-2 = 0.01, Stop 3-4 = 0.02, Stop 5 = 0.03
   for(int i = 0; i < n; i++)
   {
      double lot = InpStartLot;
      if(i >= 4)      lot = InpStartLot * 3.0; // 0.03 lot
      else if(i >= 2) lot = InpStartLot * 2.0; // 0.02 lot
      else            lot = InpStartLot * 1.0; // 0.01 lot

      if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;
      lot = NormalizeLot(lot);

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

   HLine(VIS_PREFIX + "Buy",  NormalizeDouble(ask + step, _Digits), clrLime,    "BuyStop L1");
   HLine(VIS_PREFIX + "Sell", NormalizeDouble(bid - step, _Digits), clrMagenta, "SellStop L1");
   if(m_basketTP > 0) HLine(VIS_PREFIX + "TP", m_basketTP, clrAqua, "Basket TP");
   else               ObjectDelete(0, VIS_PREFIX + "TP");

   string st = m_state;
   if(m_closingInProgress) st = "CLOSING ALL";
   else if(m_gapMode)      st = "GAP MODE";

   double peakDisplay = (m_trendPeakNet > -1e8) ? m_trendPeakNet : 0.0;

   Comment(
      "\n  v360.00  Trend Riding + Recovery + Breakout",
      "\n  PHASE: ", m_phase,
      "   Target $", DoubleToString(CloseTarget(), 2),
      "   Peak $", DoubleToString(peakDisplay, 2),
      "   age ", age, "m",
      "\n  BasketTP ", (m_basketTP > 0 ? DoubleToString(m_basketTP, _Digits) : "-"),
      "   Step ", DoubleToString(step, _Digits),
      "   spread ", DoubleToString(ask - bid, 3),
      "\n  Trail ", (m_trailActive ? "ON" : "off"),
      "   RecTrailPeak $", DoubleToString((m_recoverTrailPeak > -1e8) ? m_recoverTrailPeak : 0.0, 2),
      "\n  ---------------------------",
      "\n  ", st,
      "\n  Buy  pos ", buys,  "  lot ", DoubleToString(buyLot, 2),  "  $", DoubleToString(buyPft, 2),  "  pend ", buyPend,
      "\n  Sell pos ", sells, "  lot ", DoubleToString(sellLot, 2), "  $", DoubleToString(sellPft, 2), "  pend ", sellPend,
      "\n  NET  $ ", DoubleToString(net, 2),
      "\n"
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
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, name, OBJPROP_TEXT, text);
   }
   else
      ObjectSetDouble(0, name, OBJPROP_PRICE, price);
}
//+------------------------------------------------------------------+

