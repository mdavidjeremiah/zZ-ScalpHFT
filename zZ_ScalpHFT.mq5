//+------------------------------------------------------------------+
//| ZZ_ScalpHFT.mq5                                                  |
//| Tick-driven ZigZag swing-retrace scalper (HFT-style execution)   |
//|                                                                  |
//| Idea                                                             |
//|  - Once per closed bar, map the last two ZigZag swing points.    |
//|  - The last leg defines a trigger level (its origin, or a        |
//|    fraction of it).  After a down-leg we look to BUY the retrace, |
//|    after an up-leg we look to SELL it.                            |
//|  - On every tick: cross of the trigger + spread/session/momentum |
//|    gates -> market order (or a short-lived Buy/Sell Stop).       |
//|  - Everything on the tick path is O(1); the swing map is rebuilt |
//|    only when a new bar closes.                                   |
//|                                                                  |
//| All distances are raw broker points.  Defaults are PLACEHOLDERS  |
//| sized for a 2-digit XAUUSD symbol (100 points = 1.00 in price).  |
//| They are not optimized values.  Test on real ticks.              |
//+------------------------------------------------------------------+
#property copyright "LitmusTech Solutions"
#property version   "1.00"
#property strict
#property description "Tick-driven ZigZag swing-retrace scalper"

#include <Trade\Trade.mqh>

//--- enums --------------------------------------------------------------
enum ENUM_ENTRY_MODE
  {
   ENTRY_MARKET_ON_TRIGGER = 0,   // Market order when the trigger is crossed
   ENTRY_PENDING_STOP      = 1    // Short-lived Buy/Sell Stop at the trigger
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0,          // Fixed lots
   LOT_RISK_PERCENT = 1           // Percent of equity risked at the stop loss
  };

//--- inputs -------------------------------------------------------------
input group "Signal: ZigZag swing map"
input ENUM_TIMEFRAMES InpSignalTF        = PERIOD_M1;  // Swing timeframe
input int    InpZZDepth                  = 6;          // ZigZag depth (bars)
input int    InpZZDeviationPts           = 10;         // ZigZag deviation (points)
input int    InpZZBackstep               = 3;          // ZigZag backstep (bars)
input int    InpBarsToScan               = 150;        // Closed bars used for the swing map
input int    InpMinLegPts                = 200;        // Ignore legs smaller than this
input int    InpMaxLegPts                = 2000;       // Ignore legs larger than this
input int    InpMaxSwingAgeBars          = 15;         // Latest swing must be at most this many bars old
input double InpLegFraction              = 1.00;       // Trigger at this fraction of the leg (1.0 = leg origin)
input int    InpTriggerLeadPts           = 20;         // Fire this many points BEFORE the level

input group "Entry"
input ENUM_ENTRY_MODE InpEntryMode       = ENTRY_MARKET_ON_TRIGGER;
input int    InpMaxChasePts              = 40;         // Market mode: skip if price is already this far past the trigger
input int    InpPendingMaxDistPts        = 120;        // Pending mode: only place when price is this close to the trigger
input int    InpPendingTTLSec            = 20;         // Pending mode: delete the order after this many seconds
input bool   InpUseMomentum              = true;       // Require tick momentum toward the trade direction
input int    InpMomentumWindowMs         = 1500;       // Momentum window (ms)
input int    InpMomentumPts              = 30;         // Net mid-price move needed inside the window (points)
input int    InpMomentumMinTicks         = 4;          // Minimum ticks inside the window
input int    InpMaxSpreadPts             = 35;         // Max spread, 0 = off
input int    InpMaxOpenPositions         = 1;          // Positions + pendings, 0 = unlimited
input int    InpMinSecBetweenEntries     = 5;          // Cooldown between entries (seconds)
input int    InpEvalIntervalMs           = 0;          // Throttle entry evaluation, 0 = every tick
input int    InpDeviationPts             = 20;         // Max slippage on market orders (points)

input group "Exits"
input int    InpSLPts                    = 120;        // Stop loss (points, must be > 0)
input int    InpTPPts                    = 180;        // Take profit (points, 0 = none)
input int    InpBEStartPts               = 70;         // Break-even trigger (points profit, 0 = off)
input int    InpBELockPts                = 10;         // Points locked at break-even
input int    InpTrailStartPts            = 100;        // Trailing starts at this profit (0 = off)
input int    InpTrailDistPts             = 45;         // Trailing distance
input int    InpTrailStepPts             = 10;         // Minimum SL improvement per modification
input int    InpMaxHoldSec               = 180;        // Time stop in seconds (0 = off)

input group "Risk"
input ENUM_LOT_MODE InpLotMode           = LOT_FIXED;
input double InpFixedLots                = 0.01;
input double InpRiskPercent              = 0.25;       // % of equity at SL (risk mode)
input double InpDailyLossPercent         = 3.0;        // Stop for the day at this % loss vs day-start balance (0 = off)
input double InpDailyProfitPercent       = 0.0;        // Stop for the day at this % gain (0 = off)
input bool   InpCloseOnDailyStop         = true;       // Flatten when a daily stop triggers
input int    InpMaxConsecLosses          = 4;          // Pause after this many losses in a row (0 = off)
input int    InpLossPauseMin             = 30;         // Pause length (minutes)

input group "Session (server time)"
input bool   InpUseSession               = true;
input int    InpSessionStartHour         = 7;
input int    InpSessionEndHour           = 21;
input bool   InpFridayEarlyStop          = true;
input int    InpFridayStopHour           = 20;

input group "Misc"
input long   InpMagic                    = 424242;
input string InpComment                  = "ZZScalpHFT";
input bool   InpVerbose                  = false;

//--- constants ------------------------------------------------------------
#define TICK_BUF   256
#define MOD_MIN_MS 150

//--- state ----------------------------------------------------------------
struct SwingSetup
  {
   bool     valid;
   int      dir;        // +1 = long, -1 = short
   double   trigger;    // price level that arms / fires the trade
   datetime key;        // open time of the latest swing bar (identifies the setup)
   double   legPts;
  };

CTrade     g_trade;
double     g_point            = 0.0;
int        g_digits           = 0;

SwingSetup g_setup;
datetime   g_lastBarTime      = 0;
datetime   g_lastSetupKey     = 0;
int        g_lastSetupDir     = 0;
double     g_lastSetupTrigger = 0.0;
bool       g_armed            = false;   // price has been seen on the pre-trigger side
bool       g_consumed         = false;   // this setup already produced an entry attempt

long       g_tkMsc[TICK_BUF];
double     g_tkMid[TICK_BUF];
int        g_tkHead           = 0;
int        g_tkCount          = 0;

long       g_lastEvalMsc      = 0;
long       g_blockUntilMsc    = 0;       // back-off after a failed send
long       g_lastModMsc       = 0;
long       g_lastDelMsc       = 0;
datetime   g_lastEntryTime    = 0;

datetime   g_dayAnchor        = 0;
double     g_dayStartBalance  = 0.0;
bool       g_dayStopped       = false;
int        g_consecLosses     = 0;
datetime   g_lastLossTime     = 0;

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
void DebugLog(const string s)
  {
   if(InpVerbose)
      Print("ZZScalp | ", s);
  }

double NormPrice(const double p)
  {
   return NormalizeDouble(p, g_digits);
  }

datetime DayAnchor(const datetime t)
  {
   const long v = (long)t;
   return (datetime)(v - (v % 86400));
  }

bool SessionOpen(const datetime now)
  {
   MqlDateTime tm;
   TimeToStruct(now, tm);

   if(InpFridayEarlyStop && tm.day_of_week == 5 && tm.hour >= InpFridayStopHour)
      return false;
   if(!InpUseSession || InpSessionStartHour == InpSessionEndHour)
      return true;
   if(InpSessionStartHour < InpSessionEndHour)
      return (tm.hour >= InpSessionStartHour && tm.hour < InpSessionEndHour);
   return (tm.hour >= InpSessionStartHour || tm.hour < InpSessionEndHour);   // wraps midnight
  }

// Call right after PositionGetTicket(i)
bool IsOurPosition()
  {
   return (PositionGetString(POSITION_SYMBOL) == _Symbol &&
           PositionGetInteger(POSITION_MAGIC) == InpMagic);
  }

// Call right after OrderGetTicket(i)
bool IsOurOrder()
  {
   return (OrderGetString(ORDER_SYMBOL) == _Symbol &&
           OrderGetInteger(ORDER_MAGIC) == InpMagic);
  }

int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetTicket(i) == 0)
         continue;
      if(IsOurPosition())
         n++;
     }
   return n;
  }

// dir: 0 = any stop order, +1 = Buy Stops only, -1 = Sell Stops only
int CountPendings(const int dir = 0)
  {
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(OrderGetTicket(i) == 0 || !IsOurOrder())
         continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP)
         continue;
      if(dir > 0 && ot != ORDER_TYPE_BUY_STOP)
         continue;
      if(dir < 0 && ot != ORDER_TYPE_SELL_STOP)
         continue;
      n++;
     }
   return n;
  }

//+------------------------------------------------------------------+
//| Tick ring buffer + momentum                                      |
//+------------------------------------------------------------------+
void PushTick(const MqlTick &t)
  {
   g_tkMsc[g_tkHead] = t.time_msc;
   g_tkMid[g_tkHead] = (t.bid + t.ask) * 0.5;
   g_tkHead = (g_tkHead + 1) % TICK_BUF;
   if(g_tkCount < TICK_BUF)
      g_tkCount++;
  }

// Net mid-price move over the last windowMs and the number of ticks inside it.
bool TickMomentum(const long nowMsc, const int windowMs, double &netMove, int &ticks)
  {
   netMove = 0.0;
   ticks   = 0;
   if(g_tkCount < 2)
      return false;

   const int    newestIdx = (g_tkHead - 1 + TICK_BUF) % TICK_BUF;
   const double newest    = g_tkMid[newestIdx];
   double       oldest    = newest;

   for(int n = 0; n < g_tkCount; n++)
     {
      const int idx = (g_tkHead - 1 - n + TICK_BUF) % TICK_BUF;
      if(nowMsc - g_tkMsc[idx] > windowMs)
         break;
      oldest = g_tkMid[idx];
      ticks++;
     }
   netMove = newest - oldest;
   return (ticks >= 2);
  }

bool MomentumOK(const int dir, const long nowMsc)
  {
   if(!InpUseMomentum)
      return true;

   double net = 0.0;
   int    n   = 0;
   if(!TickMomentum(nowMsc, InpMomentumWindowMs, net, n))
      return false;
   if(n < InpMomentumMinTicks)
      return false;

   const double need = InpMomentumPts * g_point;
   return (dir > 0 ? net >= need : net <= -need);
  }

//+------------------------------------------------------------------+
//| Stops, volume, margin                                            |
//+------------------------------------------------------------------+
double MinStopDistance()
  {
   const long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax((double)stops, (double)freeze) * g_point;
  }

ENUM_ORDER_TYPE_FILLING MarketFilling()
  {
   const long modes = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

// SL/TP are clamped so they never sit inside the broker's minimum distance (+ spread).
void BuildSLTP(const int dir, const double entry, const double spreadPrice,
               double &sl, double &tp)
  {
   const double minD = MinStopDistance() + spreadPrice + 2.0 * g_point;
   const double slD  = (InpSLPts > 0 ? MathMax(InpSLPts * g_point, minD) : 0.0);
   const double tpD  = (InpTPPts > 0 ? MathMax(InpTPPts * g_point, minD) : 0.0);

   sl = 0.0;
   tp = 0.0;
   if(dir > 0)
     {
      if(slD > 0.0)
         sl = NormPrice(entry - slD);
      if(tpD > 0.0)
         tp = NormPrice(entry + tpD);
     }
   else
     {
      if(slD > 0.0)
         sl = NormPrice(entry + slD);
      if(tpD > 0.0)
         tp = NormPrice(entry - tpD);
     }
  }

// Returns whichever stop is more protective; a current SL of 0 means "none".
double BetterStop(const bool isBuy, const double current, const double candidate)
  {
   if(current <= 0.0)
      return candidate;
   if(isBuy)
      return (candidate > current ? candidate : current);
   return (candidate < current ? candidate : current);
  }

double NormalizeLots(double lots)
  {
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(lots <= 0.0 || vmin <= 0.0 || vmax <= 0.0 || step <= 0.0)
      return 0.0;

   lots = MathMin(lots, vmax);
   lots = MathFloor(lots / step + 1.0e-9) * step;
   if(lots < vmin - 1.0e-9)
      return 0.0;                       // below minimum: do not clamp up

   int vd = 0;
   while(vd < 8 && MathAbs(step * MathPow(10.0, vd) - MathRound(step * MathPow(10.0, vd))) > 1.0e-8)
      vd++;
   return NormalizeDouble(lots, vd);
  }

double ComputeLots(const int dir, const double entry, const double sl)
  {
   if(InpLotMode == LOT_FIXED || InpRiskPercent <= 0.0 || sl <= 0.0)
      return NormalizeLots(InpFixedLots);

   double lossPerLot = 0.0;
   const ENUM_ORDER_TYPE ot = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(ot, _Symbol, 1.0, entry, sl, lossPerLot) || lossPerLot >= 0.0)
      return NormalizeLots(InpFixedLots);

   const double riskMoney = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPercent / 100.0;
   return NormalizeLots(riskMoney / (-lossPerLot));
  }

bool MarginOK(const int dir, const double lots, const double price)
  {
   double margin = 0.0;
   const ENUM_ORDER_TYPE ot = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcMargin(ot, _Symbol, lots, price, margin))
      return false;
   return (margin <= AccountInfoDouble(ACCOUNT_MARGIN_FREE));
  }

//+------------------------------------------------------------------+
//| ZigZag swing map (standard depth/deviation/backstep algorithm)   |
//| Index 0 = newest bar in the copied array.                        |
//+------------------------------------------------------------------+
int LowestIndex(const MqlRates &r[], const int start, const int count, const int bars)
  {
   const int end = MathMin(start + count, bars);
   int    res = start;
   double v   = r[start].low;
   for(int i = start + 1; i < end; i++)
     {
      if(r[i].low < v)
        {
         v   = r[i].low;
         res = i;
        }
     }
   return res;
  }

int HighestIndex(const MqlRates &r[], const int start, const int count, const int bars)
  {
   const int end = MathMin(start + count, bars);
   int    res = start;
   double v   = r[start].high;
   for(int i = start + 1; i < end; i++)
     {
      if(r[i].high > v)
        {
         v   = r[i].high;
         res = i;
        }
     }
   return res;
  }

bool BuildZigZag(const MqlRates &r[], const int bars, const int depth, const double dev,
                 const int backstep, double &hi[], double &lo[], double &zz[])
  {
   if(depth < 2 || bars < depth + 2)
      return false;

   ArrayResize(hi, bars);
   ArrayResize(lo, bars);
   ArrayResize(zz, bars);
   ArrayInitialize(hi, 0.0);
   ArrayInitialize(lo, 0.0);
   ArrayInitialize(zz, 0.0);

   double lastLow  = 0.0;
   double lastHigh = 0.0;
   const int oldest = bars - depth;

   // pass 1: candidate lows / highs, oldest -> newest
   for(int s = oldest; s >= 0; s--)
     {
      // low candidate
      const int li = LowestIndex(r, s, depth, bars);
      double lv = r[li].low;
      if(lv == lastLow)
         lv = 0.0;
      else
        {
         lastLow = lv;
         if(r[s].low - lv > dev)
            lv = 0.0;
         else
           {
            for(int b = 1; b <= backstep; b++)
              {
               const int o = s + b;
               if(o >= bars)
                  break;
               if(lo[o] != 0.0 && lo[o] > lv)
                  lo[o] = 0.0;
              }
           }
        }
      if(lv != 0.0 && r[s].low == lv)
         lo[s] = lv;

      // high candidate
      const int hiIdx = HighestIndex(r, s, depth, bars);
      double hv = r[hiIdx].high;
      if(hv == lastHigh)
         hv = 0.0;
      else
        {
         lastHigh = hv;
         if(hv - r[s].high > dev)
            hv = 0.0;
         else
           {
            for(int b = 1; b <= backstep; b++)
              {
               const int o = s + b;
               if(o >= bars)
                  break;
               if(hi[o] != 0.0 && hi[o] < hv)
                  hi[o] = 0.0;
              }
           }
        }
      if(hv != 0.0 && r[s].high == hv)
         hi[s] = hv;
     }

   // pass 2: force alternating extrema
   int    what    = 0;        // 0 = none yet, 1 = last point is a low, -1 = last point is a high
   int    posLow  = -1;
   int    posHigh = -1;
   double lowV    = 0.0;
   double highV   = 0.0;

   for(int s = oldest; s >= 0; s--)
     {
      const double h = hi[s];
      const double l = lo[s];

      if(what == 0)
        {
         if(h != 0.0)
           {
            highV = h;
            posHigh = s;
            zz[s] = h;
            what = -1;
           }
         if(l != 0.0)
           {
            lowV = l;
            posLow = s;
            zz[s] = l;
            what = 1;
           }
         continue;
        }

      if(what == 1)
        {
         if(l != 0.0 && l < lowV && h == 0.0)
           {
            if(posLow >= 0)
               zz[posLow] = 0.0;
            lowV = l;
            posLow = s;
            zz[s] = l;
           }
         if(h != 0.0 && l == 0.0)
           {
            highV = h;
            posHigh = s;
            zz[s] = h;
            what = -1;
           }
         continue;
        }

      // what == -1
      if(h != 0.0 && h > highV && l == 0.0)
        {
         if(posHigh >= 0)
            zz[posHigh] = 0.0;
         highV = h;
         posHigh = s;
         zz[s] = h;
        }
      if(l != 0.0 && h == 0.0)
        {
         lowV = l;
         posLow = s;
         zz[s] = l;
         what = 1;
        }
     }
   return true;
  }

// Rebuilds g_setup from the last two swing points.
// Returns false only when market data was not available (caller retries).
bool RefreshSetup()
  {
   g_setup.valid = false;

   MqlRates r[];
   ArraySetAsSeries(r, true);
   const int got = CopyRates(_Symbol, InpSignalTF, 1, InpBarsToScan, r);   // start at 1: forming bar excluded
   if(got < InpZZDepth + 10)
      return false;

   double hi[], lo[], zz[];
   if(!BuildZigZag(r, got, InpZZDepth, InpZZDeviationPts * g_point, InpZZBackstep, hi, lo, zz))
      return false;

   int i1 = -1;
   int i2 = -1;
   for(int i = 0; i < got; i++)
     {
      if(zz[i] == 0.0)
         continue;
      if(i1 < 0)
         i1 = i;
      else
        {
         i2 = i;
         break;
        }
     }
   if(i1 < 0 || i2 < 0 || i1 > InpMaxSwingAgeBars)
      return true;

   const double pLatest = zz[i1];
   const double pPrev   = zz[i2];
   const double legPts  = MathAbs(pPrev - pLatest) / g_point;
   if(legPts < InpMinLegPts || legPts > InpMaxLegPts)
      return true;

   int dir = 0;
   if(pPrev > pLatest)
      dir = 1;                 // last leg was down -> look to buy the retrace
   else if(pLatest > pPrev)
      dir = -1;                // last leg was up   -> look to sell the retrace
   else
      return true;

   const double level   = pLatest + (pPrev - pLatest) * InpLegFraction;
   const double trigger = NormPrice(dir > 0 ? level - InpTriggerLeadPts * g_point
                                            : level + InpTriggerLeadPts * g_point);

   g_setup.valid   = true;
   g_setup.dir     = dir;
   g_setup.trigger = trigger;
   g_setup.key     = r[i1].time;
   g_setup.legPts  = legPts;

   const bool same = (g_lastSetupKey == g_setup.key && g_lastSetupDir == dir &&
                      MathAbs(g_lastSetupTrigger - trigger) < g_point * 0.5);
   if(!same)
     {
      g_armed            = false;
      g_consumed         = false;
      g_lastSetupKey     = g_setup.key;
      g_lastSetupDir     = dir;
      g_lastSetupTrigger = trigger;
      DebugLog(StringFormat("New setup dir=%d trigger=%s leg=%.0f pts",
                            dir, DoubleToString(trigger, g_digits), legPts));
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Day state / guards (no history scans on the tick path)           |
//+------------------------------------------------------------------+
void OnClosedDeal(const ulong deal)
  {
   const ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
      return;

   const double net = HistoryDealGetDouble(deal, DEAL_PROFIT) + HistoryDealGetDouble(deal, DEAL_SWAP)
                    + HistoryDealGetDouble(deal, DEAL_COMMISSION) + HistoryDealGetDouble(deal, DEAL_FEE);
   if(net < 0.0)
     {
      g_consecLosses++;
      g_lastLossTime = (datetime)HistoryDealGetInteger(deal, DEAL_TIME);
     }
   else
      g_consecLosses = 0;
  }

// Restart-safe: day-start balance = current balance - realized trading P/L today.
void RebuildDayState(const datetime now)
  {
   g_dayAnchor    = DayAnchor(now);
   g_dayStopped   = false;
   g_consecLosses = 0;
   g_lastLossTime = 0;

   double realized = 0.0;
   if(HistorySelect(g_dayAnchor, now + 60))
     {
      const int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         const ulong tk = HistoryDealGetTicket(i);
         if(tk == 0)
            continue;
         const ENUM_DEAL_TYPE type = (ENUM_DEAL_TYPE)HistoryDealGetInteger(tk, DEAL_TYPE);
         if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
            continue;

         realized += HistoryDealGetDouble(tk, DEAL_PROFIT) + HistoryDealGetDouble(tk, DEAL_SWAP)
                   + HistoryDealGetDouble(tk, DEAL_COMMISSION) + HistoryDealGetDouble(tk, DEAL_FEE);

         if(HistoryDealGetString(tk, DEAL_SYMBOL) == _Symbol &&
            HistoryDealGetInteger(tk, DEAL_MAGIC) == InpMagic)
            OnClosedDeal(tk);
        }
     }
   g_dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - realized;
  }

void FlattenAll()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsOurPosition())
         continue;
      g_trade.PositionClose(tk);
     }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong tk = OrderGetTicket(i);
      if(tk == 0 || !IsOurOrder())
         continue;
      g_trade.OrderDelete(tk);
     }
  }

void UpdateDailyLatch(const datetime now)
  {
   if(DayAnchor(now) != g_dayAnchor)
      RebuildDayState(now);
   if(g_dayStopped || g_dayStartBalance <= 0.0)
      return;

   const double pnl = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartBalance;
   string reason = "";
   if(InpDailyLossPercent > 0.0 && pnl <= -g_dayStartBalance * InpDailyLossPercent / 100.0)
      reason = "daily loss limit";
   else if(InpDailyProfitPercent > 0.0 && pnl >= g_dayStartBalance * InpDailyProfitPercent / 100.0)
      reason = "daily profit target";
   if(reason == "")
      return;

   g_dayStopped = true;
   Print("ZZScalp | ", reason, " reached (day P/L ", DoubleToString(pnl, 2), "): entries disabled until next server day");
   if(InpCloseOnDailyStop)
      FlattenAll();
  }

//+------------------------------------------------------------------+
//| Order placement                                                  |
//+------------------------------------------------------------------+
bool OpenMarket(const int dir, const MqlTick &t)
  {
   const double entry = (dir > 0 ? t.ask : t.bid);
   double sl = 0.0;
   double tp = 0.0;
   BuildSLTP(dir, entry, t.ask - t.bid, sl, tp);

   const double lots = ComputeLots(dir, entry, sl);
   if(lots <= 0.0)
     {
      DebugLog("Volume below minimum - entry skipped");
      return false;
     }
   if(!MarginOK(dir, lots, entry))
     {
      DebugLog("Not enough free margin - entry skipped");
      return false;
     }

   const bool ok = (dir > 0 ? g_trade.Buy(lots, _Symbol, 0.0, sl, tp, InpComment)
                            : g_trade.Sell(lots, _Symbol, 0.0, sl, tp, InpComment));
   if(!ok)
      DebugLog(StringFormat("Market %s failed: retcode=%u (%s)", (dir > 0 ? "BUY" : "SELL"),
                            g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   return ok;
  }

bool PlacePending(const int dir, const double level, const MqlTick &t)
  {
   const double price = NormPrice(level);
   const double minD  = MinStopDistance() + 2.0 * g_point;
   if(dir > 0 && price < t.ask + minD)
      return false;                       // Buy Stop too close to Ask
   if(dir < 0 && price > t.bid - minD)
      return false;                       // Sell Stop too close to Bid

   double sl = 0.0;
   double tp = 0.0;
   BuildSLTP(dir, price, t.ask - t.bid, sl, tp);

   const double lots = ComputeLots(dir, price, sl);
   if(lots <= 0.0)
     {
      DebugLog("Volume below minimum - pending skipped");
      return false;
     }
   if(!MarginOK(dir, lots, price))
     {
      DebugLog("Not enough free margin - pending skipped");
      return false;
     }

   g_trade.SetTypeFilling(ORDER_FILLING_RETURN);
   const bool ok = (dir > 0 ? g_trade.BuyStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment)
                            : g_trade.SellStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment));
   g_trade.SetTypeFilling(MarketFilling());

   if(!ok)
      DebugLog(StringFormat("Pending %s failed: retcode=%u (%s)", (dir > 0 ? "BUY STOP" : "SELL STOP"),
                            g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   return ok;
  }

// Deletes our pendings that no longer match the current setup or exceeded their TTL.
void ManagePendings(const long nowMsc, const datetime now)
  {
   if(nowMsc - g_lastDelMsc < 1000)
      return;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong tk = OrderGetTicket(i);
      if(tk == 0 || !IsOurOrder())
         continue;
      const ENUM_ORDER_TYPE ot = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      if(ot != ORDER_TYPE_BUY_STOP && ot != ORDER_TYPE_SELL_STOP)
         continue;

      const int      odir  = (ot == ORDER_TYPE_BUY_STOP ? 1 : -1);
      const double   price = OrderGetDouble(ORDER_PRICE_OPEN);
      const datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);

      const bool keep = (g_setup.valid && g_setup.dir == odir &&
                         MathAbs(price - g_setup.trigger) < g_point * 1.5 &&
                         now - setup <= InpPendingTTLSec);
      if(keep)
         continue;

      g_lastDelMsc = nowMsc;
      if(!g_trade.OrderDelete(tk))
         DebugLog(StringFormat("Pending delete failed: retcode=%u (%s)",
                               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }
  }

// Break-even, trailing and time stop.  Runs on every tick.
void ManagePositions(const MqlTick &t, const datetime now)
  {
   const double stopD   = MinStopDistance() + 2.0 * g_point;
   const double freezeD = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL) * g_point;
   const double minStep = MathMax(g_point * 0.5, InpTrailStepPts * g_point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong tk = PositionGetTicket(i);
      if(tk == 0 || !IsOurPosition())
         continue;

      const bool     isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      const double   open   = PositionGetDouble(POSITION_PRICE_OPEN);
      const double   sl     = PositionGetDouble(POSITION_SL);
      const double   tp     = PositionGetDouble(POSITION_TP);
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      if(InpMaxHoldSec > 0 && now - opened >= InpMaxHoldSec)
        {
         g_trade.PositionClose(tk);
         continue;
        }

      const double ref       = (isBuy ? t.bid : t.ask);                // stops are measured against this side
      const double profitPts = (isBuy ? (t.bid - open) : (open - t.ask)) / g_point;

      double cand = sl;
      if(InpBEStartPts > 0 && profitPts >= InpBEStartPts)
         cand = BetterStop(isBuy, cand,
                           NormPrice(isBuy ? open + InpBELockPts * g_point
                                           : open - InpBELockPts * g_point));
      if(InpTrailStartPts > 0 && InpTrailDistPts > 0 && profitPts >= InpTrailStartPts)
         cand = BetterStop(isBuy, cand,
                           NormPrice(isBuy ? t.bid - InpTrailDistPts * g_point
                                           : t.ask + InpTrailDistPts * g_point));

      if(cand <= 0.0)
         continue;                                                     // no protection to apply yet
      if(sl > 0.0 && MathAbs(cand - sl) < minStep)
         continue;                                                     // unchanged or below step
      if(isBuy && cand > ref - stopD)
         continue;                                                     // too close to market
      if(!isBuy && cand < ref + stopD)
         continue;
      if(freezeD > 0.0 && ((sl > 0.0 && MathAbs(ref - sl) <= freezeD) ||
                           (tp > 0.0 && MathAbs(tp - ref) <= freezeD)))
         continue;                                                     // inside the freeze level
      if(t.time_msc - g_lastModMsc < MOD_MIN_MS)
         continue;

      g_lastModMsc = t.time_msc;
      if(!g_trade.PositionModify(tk, cand, tp))
         DebugLog(StringFormat("Modify failed: retcode=%u (%s)",
                               g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
     }
  }

//+------------------------------------------------------------------+
//| Entry gating and evaluation                                      |
//+------------------------------------------------------------------+
bool EntriesAllowed(const MqlTick &t, const datetime now)
  {
   if(g_dayStopped)
      return false;
   if(!SessionOpen(now))
      return false;
   if(InpMaxSpreadPts > 0 && (t.ask - t.bid) > InpMaxSpreadPts * g_point)
      return false;
   if(InpMaxOpenPositions > 0 && CountPositions() + CountPendings() >= InpMaxOpenPositions)
      return false;
   if(InpMinSecBetweenEntries > 0 && g_lastEntryTime > 0 &&
      now - g_lastEntryTime < InpMinSecBetweenEntries)
      return false;
   if(InpMaxConsecLosses > 0 && g_consecLosses >= InpMaxConsecLosses)
     {
      if(now - g_lastLossTime < InpLossPauseMin * 60)
         return false;
      g_consecLosses = 0;                                              // pause served
     }
   return true;
  }

void EvaluateEntry(const MqlTick &t, const datetime now)
  {
   if(!g_setup.valid)
      return;

   const int    dir    = g_setup.dir;
   const double px     = (dir > 0 ? t.ask : t.bid);                   // the side that has to cross the trigger
   const bool   before = (dir > 0 ? px < g_setup.trigger : px > g_setup.trigger);
   if(before)
      g_armed = true;

   if(g_consumed || t.time_msc < g_blockUntilMsc)
      return;
   if(!EntriesAllowed(t, now))
      return;

   if(InpEntryMode == ENTRY_MARKET_ON_TRIGGER)
     {
      if(!g_armed || before)
         return;                                                       // not crossed yet
      if(MathAbs(px - g_setup.trigger) > InpMaxChasePts * g_point)
        {
         g_consumed = true;                                            // gapped through the level: stale setup
         return;
        }
      if(!MomentumOK(dir, t.time_msc))
         return;

      g_consumed = true;                                               // one attempt per setup
      if(OpenMarket(dir, t))
         g_lastEntryTime = now;
      else
         g_blockUntilMsc = t.time_msc + 1000;
      return;
     }

   // pending-stop mode
   if(!before)
      return;
   if(MathAbs(g_setup.trigger - px) > InpPendingMaxDistPts * g_point)
      return;
   if(CountPendings(dir) > 0)
      return;
   if(!MomentumOK(dir, t.time_msc))
      return;

   if(PlacePending(dir, g_setup.trigger, t))
     {
      g_consumed      = true;
      g_lastEntryTime = now;
     }
   else
      g_blockUntilMsc = t.time_msc + 1000;
  }

//+------------------------------------------------------------------+
//| Expert events                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   if(g_point <= 0.0)
     {
      Print("ZZScalp | invalid symbol point size");
      return INIT_FAILED;
     }
   if(InpSLPts <= 0)
     {
      Print("ZZScalp | InpSLPts must be > 0");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpZZDepth < 2 || InpBarsToScan < InpZZDepth + 20)
     {
      Print("ZZScalp | ZigZag depth / bars to scan are inconsistent");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpLegFraction <= 0.0 || InpLegFraction > 1.5)
     {
      Print("ZZScalp | InpLegFraction must be in (0, 1.5]");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)InpDeviationPts);
   g_trade.SetTypeFilling(MarketFilling());

   ZeroMemory(g_setup);
   g_lastBarTime      = 0;
   g_lastSetupKey     = 0;
   g_lastSetupDir     = 0;
   g_lastSetupTrigger = 0.0;
   g_armed            = false;
   g_consumed         = false;
   g_tkHead           = 0;
   g_tkCount          = 0;
   g_lastEvalMsc      = 0;
   g_blockUntilMsc    = 0;
   g_lastModMsc       = 0;
   g_lastDelMsc       = 0;
   g_lastEntryTime    = 0;

   RebuildDayState(TimeCurrent());

   PrintFormat("ZZScalpHFT init | %s %s depth=%d mode=%s SL=%d TP=%d",
               _Symbol, EnumToString(InpSignalTF), InpZZDepth,
               EnumToString(InpEntryMode), InpSLPts, InpTPPts);
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   PrintFormat("ZZScalpHFT stopped | reason=%d", reason);
  }

void OnTick()
  {
   MqlTick t;
   if(!SymbolInfoTick(_Symbol, t))
      return;
   PushTick(t);
   const datetime now = t.time;

   // swing map: rebuilt once per newly closed bar
   const datetime barTime = iTime(_Symbol, InpSignalTF, 0);
   if(barTime != 0 && barTime != g_lastBarTime)
     {
      if(RefreshSetup())
         g_lastBarTime = barTime;
     }

   UpdateDailyLatch(now);
   ManagePositions(t, now);

   if(InpEvalIntervalMs > 0 && t.time_msc - g_lastEvalMsc < InpEvalIntervalMs)
      return;
   g_lastEvalMsc = t.time_msc;

   ManagePendings(t.time_msc, now);
   EvaluateEntry(t, now);
  }

// Keeps the loss streak current without scanning history on every tick.
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != _Symbol)
      return;
   if(!HistoryDealSelect(trans.deal))
      return;
   if(HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != InpMagic)
      return;
   OnClosedDeal(trans.deal);
  }
//+------------------------------------------------------------------+
