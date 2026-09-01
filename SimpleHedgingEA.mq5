//+------------------------------------------------------------------+
//|                                              SimpleHedgingEA.mq5 |
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
//|   1. Flat  -> arm 10 BuyStop + 10 SellStop, 0.05 each (XAUUSD default).          |
//|   2. First fill wins -> opposite-side pendings DELETED.          |
//|      Same-dir pendings KEPT -> PHASE 1: TRENDING.               |
//|   3. TRENDING: more same-dir fills (one/tick), peak tracked,     |
//|      trailing net protects. Trail fires -> profit locked.        |
//|   4. TRENDING -> RECOVERY: net <= -FirstTrigger.                 |
//|      Remaining same-dir pending cancelled. ONE opposite stop.   |
//|   5. RECOVERY: basket TP / trailing / hedge fast-exit.           |
//|      If price escapes entry range -> PHASE 2B: BREAKOUT.         |
//|   6. BREAKOUT: opposite recovery stop deleted. BuyStop beyond    |
//|      entry_high armed. Trail net -> profit locked.               |
//|   7. Close -> cooldown -> re-arm.                                |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026"
#property link      "https://www.mql5.com"
#property version   "360.00"
#property description "v360: Three-Phase Trend Riding + Recovery + Breakout. Dynamic TP scaling. Tight trailing."

#include <Trade\Trade.mqh>

//--- Profit ---------------------------------------------------------
input group "=== Profit ==="
input double   InpCloseProfitUSD      = 15.00;  // Basket TP target ($ net) — $15.00 for XAUUSD 0.05 lot ($3 gold move)
input bool     InpUseBasketTP         = true;   // Write a shared TP price on every position
input bool     InpScaleTPWithLegs     = true;   // Scale TP up with recovery depth
input double   InpTPScaleFactor       = 0.50;   // Per recovery leg TP increase (0.50 = +50% per leg)

//--- Trend Riding ---------------------------------------------------
input group "=== Trend Riding ==="
input bool     InpTrendRide           = true;   // Phase 1: allow same-dir fills while trending
input double   InpTrendMinPeak        = 8.00;   // Minimum peak ($) before trailing activates — $8.00 on 0.05 lot
input double   InpTrendTrailRatio     = 0.25;   // Close if net drops this fraction from peak — 25% (gives room to ride trend)

//--- Entry grid -----------------------------------------------------
input group "=== Entry Grid (only while flat) ==="
input int      InpMaxGridLevels       = 1;      // BuyStops and SellStops (1 BuyStop + 1 SellStop — zero overstacking risk!)
input double   InpStartLot            = 0.05;   // Every grid pending starts here — 0.05 for XAUUSD
input double   InpGridStepUSD         = 5.00;   // Minimum gap between levels — $5 = $1.00 chart gap for 0.05 lot
input bool     InpUseATR              = true;   // Widen the step with real M1 volatility
input int      InpAtrPeriod           = 14;     // ATR period (M1)
input double   InpAtrMult             = 1.0;    // Step = ATR * this — 1.0 for XAUUSD

//--- Reversal / recovery --------------------------------------------
input group "=== Reversal / Recovery ==="
input double   InpFirstTriggerUSD     = 8.00;   // Recovery trigger 1st leg ($) — $8.00 = $1.60 chart adverse move
input double   InpReverseTriggerUSD   = 12.00;  // Recovery trigger 2nd+ legs ($) — $12.00 = $2.40 chart
input int      InpReverseAfterSec     = 300;    // ...or after this long in the red (0 = off)
input double   InpReverseDistUSD      = 10.00;  // Reversal stop distance — $10 = $2.00 chart gap
input double   InpRecoverMoveUSD      = 15.00;  // Recovery move target — $15 = $3.00 chart
input bool     InpBeyondAllEntries    = true;   // Reversal must sit beyond EVERY existing entry
input double   InpMaxLot              = 0.50;   // Hard cap on single recovery lot (full sizing freedom)
input double   InpMaxBasketLots       = 1.00;   // Hard cap on total buyLot+sellLot (ample room for recovery math)
input int      InpMaxRecoveryLegs     = 4;      // Max recovery legs — 4 legs
input int      InpRecoveryAccelMin    = 3;      // Minutes unfilled -> bring stop closer (0 = off)
input double   InpAccelDistRatio      = 0.65;   // Recovery acceleration distance ratio (65%)
input bool     InpBreakoutRecovery    = false;  // Breakout Recovery OFF (prevents chop zone whipsaws)

input group "=== Trend Filter (recover only WITH the trend) ==="
input bool     InpUseTrendFilter      = true;   // Block recovery legs that fight the higher-TF trend
input ENUM_TIMEFRAMES InpTrendTF      = PERIOD_M15;
input int      InpTrendFastEMA        = 20;
input int      InpTrendSlowEMA        = 50;

//--- Anti-churn / no hanging trades ---------------------------------
input group "=== Anti-Churn / No Hanging Trades ==="
input bool     InpOneTradePerTick     = true;   // Close extras if >1 position opens on one tick
input int      InpCooldownSec         = 5;      // Wait 5s after a close before re-arming (fast cycle restart)
input int      InpBreakEvenAfterMin   = 30;     // After 30m in hedge/red, exit at Break-Even ($0) to avoid chop
input int      InpForceCloseAfterMin  = 0;      // Hard time stop (0 = off)
input bool     InpUseTrailingNet      = true;   // Recovery phase: trailing net lock on hedged basket
input double   InpTrailingNetRatio    = 0.50;   // Trailing starts early when recovery peak >= target * 50%
input bool     InpHedgeFastExit       = true;   // Hedged basket (both sides open): close at reduced target
input double   InpHedgeExitRatio      = 0.60;   // Hedged basket target = scaled TP * 60% (fast exit)

//--- Spread / gap ---------------------------------------------------
input group "=== Spread / Gap Filter ==="
input double   InpSpreadPad           = 2.0;    // Pending gap must be >= spread * this
input double   InpWideSpreadPrice     = 1.50;   // Price spread above this = do not arm — $1.50 for XAUUSD
input double   InpGapUSD              = 20.0;   // Mid-price jump this big = gap mode — $20 for XAUUSD

//--- Protection -----------------------------------------------------
input group "=== Protection ==="
input double   InpMaxCycleLossUSD       = 0.0;     // Cycle Circuit Breaker (0 = OFF)
input double   InpMaxAllowedDrawdownUSD = 5000.0;  // Max DD USD ($5000)
input double   InpMaxDrawdownPercent    = 50.0;    // Max 50% Drawdown
input bool     InpCloseFridayNight      = true;    // Close open trades Friday 21:00 GMT to avoid weekend gap

//--- Expert ---------------------------------------------------------
input group "=== Expert ==="
input ulong    InpMagicNumber         = 888111;
input ulong    InpSlippage            = 50;    // Higher slippage tolerance for XAUUSD
input bool     InpShowVisual          = true;

#define VIS_PREFIX "PincerVis_"

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
   Print("====================================");
   return net;
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
      m_prevPosCount = 0;

      if(TimeCurrent() < m_cooldownUntil)
      {
         if(buyPend + sellPend > 0)
            DeletePendings();
         m_state = StringFormat("COOLDOWN %ds", (int)(m_cooldownUntil - TimeCurrent()));
         DrawVisual();
         return;
      }

      // Check New Candle filter: never re-arm on the same candle where a trade closed!
      datetime curBar = iTime(_Symbol, _Period, 0);
      if(m_closedBarTime > 0 && curBar == m_closedBarTime)
      {
         if(buyPend + sellPend > 0)
            DeletePendings();
         m_state = "WAITING NEW CANDLE (same bar close)";
         DrawVisual();
         return;
      }

      if(buyPend + sellPend == 0)
      {
         if(TimeCurrent() < m_armRetryUntil)
         {
            m_state = "ARM BACKOFF (last arm was rejected)";
            DrawVisual();
            return;
         }
         if(WideSpread() || m_gapMode)
         {
            m_state = m_gapMode ? "GAP — not arming" : "WIDE SPREAD — not arming";
            DrawVisual();
            return;
         }
         PrintFormat("[ARM] %d BuyStop + %d SellStop @ %.2f (step %.*f)",
                     InpMaxGridLevels, InpMaxGridLevels, InpStartLot, _Digits, GridStep());
         int placed = PlaceGrid(ORDER_TYPE_BUY_STOP) + PlaceGrid(ORDER_TYPE_SELL_STOP);
         int wanted = MathMax(InpMaxGridLevels, 1) * 2;
         if(placed < wanted)
         {
            m_armRetryUntil = TimeCurrent() + 30;
            PrintFormat("[ARM PARTIAL] only %d/%d placed — backing off 30s", placed, wanted);
         }
      }
      else if(WideSpread() || m_gapMode)
         StretchPendingsFarther();

      m_state = "ARMED — first fill wins, opposite side cancelled";
      DrawVisual();
      return;
   }

   //=== PHASE DETECTION (first position seen this cycle) ==============
   if(m_phase == "IDLE")
   {
      m_trendDir = (buys >= sells) ? 1 : -1;
      m_phase    = InpTrendRide ? "TRENDING" : "RECOVERY";
      // Delete opposite-side pendings immediately; keep same-dir
      DeleteAllOfType(m_trendDir > 0 ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
      ClearAllTP(); // Clear any broker-side TP so position isn't prematurely killed
      PrintFormat("[PHASE->%s] dir=%s, opposite pendings deleted, same-dir pendings KEPT",
                  m_phase, m_trendDir > 0 ? "BUY" : "SELL");
   }

   //=== PHASE 1: TRENDING =============================================
   if(m_phase == "TRENDING")
   {
      if(HandleTrendingPhase(buys, sells, buyLot, sellLot, net, pos))
      {
         m_prevPosCount = CountPos();
         DrawVisual();
         return;
      }
      // false -> transitioned to RECOVERY, fall through
   }

   //=== PHASE 2B: BREAKOUT RECOVERY ===================================
   if(m_phase == "BREAKOUT")
   {
      if(net < 0) { if(m_redSince == 0) m_redSince = TimeCurrent(); }
      else m_redSince = 0;

      double btarget = CloseTarget();
      if(net >= btarget)
      {
         PrintFormat(">>> [BREAKOUT CLOSE] net $%.2f >= target $%.2f", net, btarget);
         DeletePendings();
         m_closingInProgress = true;
         m_placeAfterClose   = true;
         ProcessClose();
         m_prevPosCount = CountPos();
         DrawVisual();
         return;
      }
      HandleBreakoutRecovery(buys, sells, buyLot, sellLot, net, pos);
      m_prevPosCount = pos;
      DrawVisual();
      return;
   }

   //=== PHASE 2: RECOVERY =============================================
   if(net < 0)
   {
      if(m_redSince == 0) m_redSince = TimeCurrent();
   }
   else
      m_redSince = 0;

   double target = CloseTarget();

   // Check for range breakout -> BREAKOUT phase transition
   if(InpBreakoutRecovery && buys > 0 && sells > 0)
      CheckRangeBreakout(buyLot, sellLot, net);

   if(m_phase == "BREAKOUT")
   {
      m_prevPosCount = pos;
      DrawVisual();
      return;
   }

   // Hedge Fast-Exit: if both sides open and near target, exit early
   if(InpHedgeFastExit && buys > 0 && sells > 0)
   {
      double hedgeTarget = target * MathMax(InpHedgeExitRatio, 0.10);
      if(hedgeTarget < 0.01) hedgeTarget = 0.01;
      if(net >= hedgeTarget)
      {
         PrintFormat(">>> [HEDGE EXIT] net $%.2f >= hedge target $%.2f", net, hedgeTarget);
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

   //=== GUARD 2: while live, AT MOST ONE pending exists on the chart ==
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
      // Safety: purge any opposite-side positions/pendings that slipped in
      DeleteAllOfType(m_trendDir > 0 ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP);
      PrintFormat("[TREND LEG %d] fill #%d  net=$%.2f  totalLot=%.2f",
                  sameDirPos, sameDirPos, net, buyLot + sellLot);
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
      // HARD GUARANTEE: Never close on trail below a minimum positive profit floor!
      double minFloor = MathMax(InpTrendMinPeak * 0.50, 3.00); // At least $3.00 or 50% of MinPeak
      if(floor < minFloor) floor = minFloor;

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
      PrintFormat("[PHASE->RECOVERY] net=$%.2f  trigger=$%.2f (spread $%.2f) — switching to Recovery",
                  net, -trigger, spreadCost);
      // Cancel remaining same-dir pendings only when truly reversing
      DeleteAllOfType(m_trendDir > 0 ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP);
      m_phase = "RECOVERY";
      if(m_redSince == 0) m_redSince = TimeCurrent();
      return false; // fall through to RECOVERY
   }

   return true; // still trending — SAME DIRECTION PENDINGS STAY ACTIVE!
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
//| Returns true -> trigger close.                                   |
//+------------------------------------------------------------------+
bool CheckTrailingNet(double net, int buys, int sells)
{
   if(!InpUseTrailingNet) return false;
   if(m_phase != "RECOVERY") return false;
   if(buys == 0 || sells == 0) return false; // only for hedged (both sides open)

   double target = CloseTarget();
   double thresh  = target * MathMax(InpTrailingNetRatio, 0.10);

   if(net > m_recoverTrailPeak)
      m_recoverTrailPeak = net;

   // Once peak reaches threshold, close if net drops below 50% of peak
   if(m_recoverTrailPeak >= thresh && net < m_recoverTrailPeak * 0.50)
   {
      PrintFormat("[RECOVERY TRAIL] peak=$%.2f  now=$%.2f — close", m_recoverTrailPeak, net);
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
//| GUARD 2 — exactly zero or one pending while a position is open.  |
//| The only pending allowed is the recovery leg on the opposite side.|
//+------------------------------------------------------------------+
void SyncSinglePending(int activeDir, int buys, int sells,
                       double buyLot, double sellLot, double net)
{
   if(activeDir == 0)
   {
      DeletePendings();
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;

   int pos = buys + sells;
   int recDir = -activeDir;
   ENUM_ORDER_TYPE recType  = (recDir > 0) ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   ENUM_ORDER_TYPE deadType = (recDir > 0) ? ORDER_TYPE_SELL_STOP : ORDER_TYPE_BUY_STOP;

   // anything pointing the wrong way dies right now
   DeleteAllOfType(deadType);

   if(!WantRecovery(pos, net, recDir, buyLot + sellLot))
   {
      DeleteAllOfType(recType);
      m_recoverDir = 0;
      int td = TrendDir();
      string why = "riding to TP";
      if(InpMaxBasketLots > 0 && buyLot + sellLot >= InpMaxBasketLots - 0.0005)
         why = "BASKET LOT CAP reached — holding, no new leg";
      else if(InpUseTrendFilter && td != 0 && recDir != td)
         why = StringFormat("recovery would fight the %s trend — holding",
                            td > 0 ? "UP" : "DOWN");
      m_state = StringFormat("%s LIVE — %s, 0 pendings",
                             activeDir > 0 ? "BUY" : "SELL", why);
      return;
   }

   ulong  t[];
   double p[];
   CollectPendings(recType, t, p);
   SortPendings(recType, t, p);
   int have = ArraySize(t);
   for(int i = 1; i < have; i++)      // only ONE may live
      m_trade.OrderDelete(t[i]);

   double minDist = MinDist();
   double revDist = ReverseMinDist();

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

   // Smart Ping-Pong & Time-Decay Exit:
   if(buys > 0 && sells > 0)
   {
      if(age >= 20)
         t = MathMax(t * 0.25, 2.00); // 20m+ chop: drop target to $2-$3 for instant exit
      else if(age >= 10)
         t = MathMax(t * 0.50, 4.00); // 10m+ chop: drop target to $4-$7
      else if(legs >= 3)
         t = MathMax(t * 0.50, 5.00); // 3 legs open: quick escape target
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
   if(pos <= 0)                  return false;
   if(pos >= InpMaxRecoveryLegs) return false;

   if(InpMaxBasketLots > 0 && totalLots >= InpMaxBasketLots - 0.0005)
      return false;

   if(InpUseTrendFilter)
   {
      int td = TrendDir();
      if(td != 0 && recDir != td)
         return false;
   }

   double spreadCost = SpreadCostUSD(totalLots);
   // Tiered trigger with spread cost accounted for
   double trigger = (pos == 1)
                    ? MathMax(InpFirstTriggerUSD,   0.01)
                    : MathMax(InpReverseTriggerUSD,  0.01);
   if(net <= -(trigger + spreadCost)) return true;

   if(InpReverseAfterSec > 0 && m_redSince > 0 && net < 0 &&
      (TimeCurrent() - m_redSince) >= InpReverseAfterSec)
      return true;
   return false;
}

//+------------------------------------------------------------------+
//| R >= (target - L)/(move*vpp) - dir*signedVol                     |
//+------------------------------------------------------------------+
double RecoveryLot(int dir, double net, double distToHit,
                   double buyLot, double sellLot, double totalLots)
{
   double vpp       = ValuePerPrice();
   double signedVol = buyLot - sellLot;
   if(distToHit < 0) distToHit = 0;

   double lossAtFill = net + signedVol * (dir * distToHit) * vpp;

   double target = InpCloseProfitUSD;
   if(target < 0.02) target = 0.02;
   target += SpreadCostUSD(totalLots + InpStartLot);

   double move  = RecoverMovePrice();
   double denom = move * vpp;
   if(denom < 0.01) denom = 0.01;

   double lot = (target - lossAtFill) / denom - dir * signedVol;

   double minFlip = -dir * signedVol + InpStartLot;
   if(lot < minFlip)      lot = minFlip;
   if(lot < InpStartLot)  lot = InpStartLot;
   if(InpMaxLot > 0 && lot > InpMaxLot) lot = InpMaxLot;

   if(InpMaxBasketLots > 0 && totalLots + lot > InpMaxBasketLots)
      lot = InpMaxBasketLots - totalLots;
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
   m_trade.OrderDelete(ticket);
   SendPendingSafe(type, lot, price, (type == ORDER_TYPE_BUY_STOP) ? "BuyStop" : "SellStop");
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
   double d  = MoneyToPrice(MathMax(InpReverseDistUSD, 0.20), InpStartLot);
   double md = MinDist();
   double sp = SpreadPadDist();
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
int PlaceGrid(ENUM_ORDER_TYPE type)
{
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return 0;

   double minDist = MinDist();
   double step    = GridStep();
   int    n       = MathMax(InpMaxGridLevels, 1);
   double lot     = NormalizeLot(InpStartLot);
   int    placed  = 0;

   for(int i = 0; i < n; i++)
   {
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
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(ask <= 0 || bid <= 0) return;
   double step    = GridStep();
   double minDist = MinDist();
   double tol     = step * 0.25;

   ulong  bt[], st[];
   double bp[], sp[];
   CollectPendings(ORDER_TYPE_BUY_STOP,  bt, bp);
   CollectPendings(ORDER_TYPE_SELL_STOP, st, sp);
   SortPendings(ORDER_TYPE_BUY_STOP,  bt, bp);
   SortPendings(ORDER_TYPE_SELL_STOP, st, sp);

   for(int i = 0; i < ArraySize(bt); i++)
   {
      double want = ask + step * (i + 1);
      if(want < ask + minDist) want = ask + minDist;
      want = NormalizeDouble(want, _Digits);
      if(!OrderSelect(bt[i])) continue;
      if(want <= OrderGetDouble(ORDER_PRICE_OPEN) + tol) continue;
      m_trade.OrderModify(bt[i], want, 0, 0, ORDER_TIME_GTC, 0);
   }
   for(int i = 0; i < ArraySize(st); i++)
   {
      double want = bid - step * (i + 1);
      if(want > bid - minDist) want = bid - minDist;
      want = NormalizeDouble(want, _Digits);
      if(!OrderSelect(st[i])) continue;
      if(want >= OrderGetDouble(ORDER_PRICE_OPEN) - tol) continue;
      m_trade.OrderModify(st[i], want, 0, 0, ORDER_TIME_GTC, 0);
   }
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
   m_cooldownUntil     = TimeCurrent() + MathMax(InpCooldownSec, 0);
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
                      (pct >= InpMaxDrawdownPercent);

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
