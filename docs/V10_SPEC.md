# Gold Regime Scalper v10 — Specification

**Status:** Round 1 of 3 delivered: `Gold_Regime_Scalper_v10.00.mq5`, build R1, observe only, no order code. All defaults confirmed (see §10).

| | |
|---|---|
| EA file | `Gold_Regime_Scalper_v10.00.mq5` |
| Symbol / chart | XAUUSD, attached to M1 |
| Account | Pepperstone, hedging, GBP |
| Magic numbers | 100001 Trend Pullback · 100002 Trend Breakout · 100003 Range Fade |
| Log prefix | `[V10]` |
| Origin | Written from scratch. Nothing is reused from v7 or v8. |

---

## 1. Core idea

v10 reads the market every minute and watches every tick. It labels the market with one of six states and trades only the states it has a playbook for. When a state allows it, v10 enters on the tick its trigger fires, takes a small profit quickly, and re-enters seconds later if the state still holds.

"Aggressive" here describes trade frequency and speed, not risk per trade. Every trade's loss is capped in £ before the order is sent.

**What "tight stop" means here.** The stop is about 1× the current M1 ATR, not a fixed number of points. At 0.01 lot, a $1 move in gold is about £0.75. A stop tighter than normal noise gets hit by random wiggles. If the noise is so large that this stop would cost more than the £ cap, the trade is skipped. The stop is never widened, and never squeezed inside the noise.

## 2. Speed

- Entries trigger on live ticks, without waiting for a candle to close.
- Orders are sent at market with SL and TP attached in the same request. The TP is held on the broker's server, so it fills without a round trip to the terminal.
- After a win, v10 can re-enter 3 s later if the state still holds. In a trend it can stack up to 3 trades per direction.
- Work per tick is kept light. Indicators are read once per M1 bar, and recent ticks are kept in a ring buffer.
- The biggest speed factor in practice is the network, not the code. Run on a VPS close to Pepperstone's trade server; MT5's built-in VPS picks the lowest-ping location automatically.

## 3. Architecture

```
OnTick ─► MarketData.Update()            tick buffer, spread median, new-bar check
          ├─ new M1 bar? ─► StateEngine.Update()
          ├─ ShockMonitor / SpreadMonitor ─► instant VOLATILE override
          ├─ PositionManager.Manage()     exits always run first
          └─ Gatekeeper.Allow()? ─► Playbooks.Evaluate() ─► Risk.Approve() ─► Executor.Open()

OnTradeTransaction ─► Ledger.Record()      fills, slippage, closes, streaks, playbook stats
OnTimer (250 ms)   ─► day reset, news cache, dashboard, save state, manage when no ticks
```

| # | Module | Job |
|---|---|---|
| 1 | MarketData | Current tick; tick ring buffer (speed, recent micro highs/lows); spread median; indicator handles read once per M1 bar |
| 2 | StateEngine | Turns market features into one of 6 states. Normal state changes need confirmation; safety overrides apply instantly |
| 3 | Gatekeeper | Every "may we enter now?" rule in one place: session, news, spread, limits, cooldowns, pauses. The dashboard shows which rule is blocking |
| 4 | Playbooks | Trend Pullback, Trend Breakout, Range Fade. Each returns a signal (direction, stop, target) or nothing |
| 5 | RiskManager | Converts stop and target into exact £ using `OrderCalcProfit` plus commission. Applies the £ caps, the open-risk cap and lot sizing |
| 6 | Executor | Order sending, filling-mode detection, stop/freeze-level checks, retries, rate limit, slippage measurement, protection for positions left without a stop |
| 7 | PositionManager | Breakeven lock, runner trail, time stop, state-change exit, throttled stop modifications |
| 8 | Ledger | Real P&L including commission and swap; daily totals; streaks; per-playbook stats; persistence; CSV log |
| 9 | Dashboard | State and its features, blocking reason, today's stats, per-playbook results |

## 4. Market-state engine

The state is re-evaluated on each new M1 bar. The safety overrides in step 1 are checked on every tick. The checks run in this order:

1. **VOLATILE** (instant). A shock move, a spread spike, or ATR ÷ baseline ≥ 2.2. The state lasts until the market has been calm for 120 s.
2. **DEAD.** ATR(M1) < 4 × spread. Costs are too large relative to how much price moves.
3. **TREND_UP / TREND_DOWN.** All three conditions must hold:
   - The M5 EMA50 slope is at least 0.20 ATR in the trend direction.
   - M1 EMA9 is on the correct side of EMA21.
   - Efficiency Ratio(20) ≥ 0.30.
4. **RANGE.** Efficiency Ratio ≤ 0.22 and a flat M5 slope.
5. **UNCLEAR.** Anything else.

New entries are allowed only in TREND_UP, TREND_DOWN and RANGE. In every other state, v10 still manages open trades but opens no new ones.

**WARMUP** is an extra internal state, used until enough M1/M5 history has loaded. It is a no-trade state.

**State-switching rules** (as built in R1):
- VOLATILE and DEAD take effect immediately.
- Bars that close while the VOLATILE latch is active never count toward confirming a state. When the latch ends, the state becomes UNCLEAR, so every trade state has to be confirmed again.
- A trade state that is contradicted by a different trade state (for example TREND_UP against TREND_DOWN or RANGE) drops to UNCLEAR at once. The new state still needs confirmation.
- Moving into a trade state needs `InpConfirmBars` consecutive bars. So does dropping from a trade state to UNCLEAR, which means a single weak bar does not end a trend.
- Moving between two no-trade states (for example DEAD to UNCLEAR) happens immediately.
- On start-up, the previous closed bars are replayed, so a restart doesn't have to wait `InpConfirmBars` minutes.

## 5. Playbooks

| Playbook | Trades in | Entry trigger (live ticks) | Stop | Target |
|---|---|---|---|---|
| Trend Pullback | TREND_UP (mirrored for down) | Price dips 0.35–1.5 ATR from its recent high, then breaks the high of the last 8 s → buy | 1.0 ATR (min 60 pts) | 0.8 ATR, runner possible |
| Trend Breakout | TREND_UP / DOWN | Price breaks the 10-bar M1 high with speed ≥ 0.35 ATR in 10 s, and is no more than 0.4 ATR past the level | 1.0 ATR | 0.8 ATR, runner possible |
| Range Fade | RANGE | Price pokes outside the Bollinger band (20, 2) and returns inside by 0.15 ATR, without moving too fast → sell at the top, buy at the bottom | Beyond the poke extreme, capped at 1.0 ATR | Middle band, clamped to £0.30–£1.50 net |

At most one entry is opened per tick.

## 6. Exits

- **Server-side TP and SL** are set on every trade.
- **Breakeven lock.** Once price is 50% of the way to the target, the stop moves to breakeven plus costs, locking £0.05 net.
- **Runner.** In a strong trend (Efficiency Ratio ≥ 0.45), the fixed target is removed as price nears it. The stop then trails 0.5 ATR behind price and always keeps at least 80% of the original target.
- **Time stop.** A trade that hasn't reached the breakeven lock within 180 s is closed.
- **State exit.** A trade is closed if the market state turns against it.
- **Forced closes.** The daily loss limit, the news window, the rollover flatten and the Friday flatten all close open trades.

## 7. Hard rules (built in, not inputs)

1. Every position has a server-side stop. If the broker rejects the stop on the order, it is attached immediately afterwards. If that fails too, the position is closed.
2. Stops only move in the trade's favour.
3. No martingale, no averaging down, no hedge recovery. Extra positions are opened only when the existing ones are locked at breakeven or better.
4. Exits are processed before entries on every tick.
5. Every loss counts toward the daily limit and the loss streak, including forced closes.
6. Protections survive a restart. State is saved in GlobalVariables, and today's P&L is rebuilt from deal history.
7. v10 refuses to run on a netting account, because stacking requires hedging.
8. Indicator values come from closed bars only, so nothing repaints. Only the entry triggers use live ticks.

## 8. Input parameters

### 8.1 General
| Input | Default | Meaning |
|---|---|---|
| InpMode | TRADE | TRADE, or OBSERVE (shows states and signals, places no orders) |
| InpMagicBase | 100000 | +1 Pullback, +2 Breakout, +3 Fade |
| InpComment | "V10" | Order comment |
| InpLogLevel | 1 | 0 errors only, 1 trades, 2 debug |

### 8.2 Position size
| Input | Default | Meaning |
|---|---|---|
| InpLotMode | FIXED | FIXED, or RISK (lot size from % of equity) |
| InpFixedLots | 0.01 | |
| InpRiskPct | 0.20 | RISK mode only; replaces InpMaxLossPerTrade |
| InpMaxLots | 0.05 | Safety cap per trade |

### 8.3 Costs and spread
| Input | Default | Meaning |
|---|---|---|
| InpCommissionPerLotRT | 4.00 | £ per 1.00 lot round trip (£0.04 per 0.01). Raised automatically if real deals show more |
| InpMaxSpreadPts | 30 | No entries above this |
| InpSpreadSpikeRatio | 1.8 | No entries while spread > 1.8 × its 5-minute median |

### 8.4 Market-state engine
| Input | Default | Meaning |
|---|---|---|
| InpAtrPeriod | 14 | ATR on M1 |
| InpAtrBaseBars | 120 | Baseline for "normal" volatility (M1 bars) |
| InpEmaFast / InpEmaSlow | 9 / 21 | M1 EMAs |
| InpEmaTrendM5 / InpSlopeBars | 50 / 3 | M5 trend EMA and the bars used to measure its slope |
| InpSlopeMinATR | 0.20 | Minimum M5 slope for a trend |
| InpErBars | 20 | Efficiency Ratio window (M1 bars) |
| InpErTrend / InpErRange | 0.30 / 0.22 | ≥ trend threshold → trend; ≤ range threshold → range |
| InpVolSpikeRatio | 2.2 | ATR ÷ baseline above this → VOLATILE |
| InpShockATR / InpShockWindowSec | 2.5 / 20 | A 2.5 ATR move within 20 s → VOLATILE |
| InpVolatileCoolSec | 120 | Calm time needed to leave VOLATILE |
| InpDeadAtrSpread | 4.0 | ATR below 4 × spread → DEAD |
| InpConfirmBars | 2 | M1 bars a new TREND or RANGE state must hold before it can be traded |

### 8.5 Trend playbooks
| Input | Default | Meaning |
|---|---|---|
| InpUsePullback | true | |
| InpSwingWindowSec | 180 | Window used to find the recent micro high/low |
| InpPullbackMinATR / MaxATR | 0.35 / 1.50 | Pullback depth that qualifies |
| InpTriggerWindowSec / BufferPts | 8 / 3 | Price must re-break the high (or low) of the last 8 s by this buffer |
| InpUseBreakout | true | |
| InpBreakoutBars / BufferPts | 10 / 5 | M1 micro-range to break |
| InpBreakoutVelATR / InpVelWindowSec | 0.35 / 10 | Required speed |
| InpBreakoutMaxChaseATR | 0.40 | Don't chase if price is already this far past the level |

### 8.6 Range playbook
| Input | Default | Meaning |
|---|---|---|
| InpUseFade | true | |
| InpBandPeriod / InpBandDev | 20 / 2.0 | M1 Bollinger bands |
| InpFadeRejectATR | 0.15 | How far price must come back inside the band |
| InpFadeMaxVelATR | 0.60 | A push faster than this counts as a breakout, so no fade |

### 8.7 Targets and stops
| Input | Default | Meaning |
|---|---|---|
| InpTpATR / InpSlATR | 0.80 / 1.00 | Target and stop distance |
| InpMinSlPts | 60 | The stop is never tighter than this |
| InpMinNetTP / InpMaxNetTP | 0.30 / 1.50 | Skip if the target would net under £0.30; cap the target at £1.50 net |
| InpMaxLossPerTrade | 2.00 | Hard £ cap; the trade is skipped if the stop doesn't fit under it |
| InpMinRR | 0.60 | Minimum net reward ÷ net risk; filters out trades dominated by costs |

### 8.8 Exit management
| Input | Default | Meaning |
|---|---|---|
| InpBeTriggerFrac / InpBeLockNet | 0.50 / 0.05 | Breakeven lock point, and £ locked |
| InpUseRunner | true | Strong trends trail instead of taking the fixed target |
| InpRunnerMinER / LockFrac / TrailATR | 0.45 / 0.80 / 0.50 | Runner settings |
| InpTimeStopSec | 180 | |
| InpStateExit | true | Close when the state turns against the trade |
| InpModifyMinMs / InpModifyMinStepPts | 500 / 5 | Limits how often stops are modified |

### 8.9 Aggression and pacing
| Input | Default | Meaning |
|---|---|---|
| InpMaxPositions / InpMaxPerDirection | 4 / 3 | |
| InpStackNeedsBE | true | Add trades only when the existing ones are locked at breakeven |
| InpMinSpacingPts | 40 | Minimum gap between stacked entries |
| InpCooldownWinSec / LossSec | 3 / 45 | Re-entry delay after a win / after a loss |
| InpMaxTradesPerHour | 40 | Runaway guard |
| InpMaxRequestsPerMin | 20 | Broker request limiter |

### 8.10 Capital protection
| Input | Default | Meaning |
|---|---|---|
| InpMaxOpenRisk | 6.00 | £ total risk of all open stops. Trades locked at breakeven count as zero |
| InpStreakPause / PauseMin | 3 / 10 | 3 losses in a row → 10-minute pause |
| InpStreakHalt | 7 | 7 losses in a row → stop for the day |
| InpDailyLossLimit | 30.00 | £, closed + floating. Close everything and stop for the day |
| InpDailyProfitLock | 0 | £, 0 = off. Above this, no new entries today |
| InpEquityKillPct | 8.0 | Equity 8% below its peak → stop until manually reset |
| InpGuardTrades / MinAvg / PauseMin | 12 / 0.00 / 30 | If a playbook's last 12 trades average below £0, pause it for 30 minutes |
| InpMaxAvgSlipPts | 25 | Average slippage of the last 10 fills above this → 15-minute pause |
| InpMinMarginLevel | 500 | % |

### 8.11 Sessions and news (server time)
| Input | Default | Meaning |
|---|---|---|
| InpTradeStart / InpTradeEnd | 01:30 / 23:00 | New entries only inside this window |
| InpDailyFlatten | 23:30 | Close everything before spreads widen at rollover |
| InpMondayDelayMin | 60 | Skip the first hour of the week |
| InpFridayLastEntry / Flatten | 21:00 / 22:45 | |
| InpUseNews / InpNewsCurrencies | true / "USD" | High-impact events from the MT5 economic calendar |
| InpNewsBeforeMin / AfterMin | 10 / 15 | No entries inside this window |
| InpNewsFlatten | true | Close open trades when a news window starts |

### 8.12 Execution and display
| Input | Default | Meaning |
|---|---|---|
| InpDeviationPts | 20 | Only used if the symbol is on Instant execution |
| InpMaxRetries / InpMaxTickAgeMs | 2 / 2000 | Retries; skip entries if the last quote is older than this |
| InpShowDashboard / InpDrawStates | true / true | Dashboard, and coloured chart marks at each state change |
| InpWriteCsv | true | Per-trade CSV in `Common\Files`, including the state at entry |

## 9. Build plan

| Round | Contents | Result |
|---|---|---|
| 1 | Skeleton, all inputs, MarketData, StateEngine, Dashboard, chart marks | OBSERVE mode only. Check that the state labels match the chart, and that live ATR in £ fits the £ caps |
| 2 | Gatekeeper, RiskManager, Executor, the three playbooks | The EA starts trading |
| 3 | PositionManager, Ledger, persistence, CSV | Complete EA, ready for a real-tick backtest and a demo forward test |

There is no MQL5 compiler in the development sandbox. After each round the code is pushed here; the user compiles it in MetaEditor and reports any errors.

Limits of the Strategy Tester:
- The economic calendar isn't available, so the news filter is skipped in backtests.
- Real latency and slippage aren't reproduced, so a demo forward test is required before going live.

## 10. Decisions (confirmed: user replied "go")

1. £ limits: £2.00 max loss per trade, £6.00 total open risk, £30 daily loss limit.
2. Lot size: fixed 0.01, up to 3 stacked trades per direction (0.03 maximum).
3. Symbol: XAUUSD.
4. Location: branch `feat/v10-regime-scalper` in `matanostoamr/v7`, draft PR #2.

## 11. Round 1 (build R1): what is in the file

| Part | Status |
|---|---|
| All inputs (§8), validated in OnInit | ✅ Group names show which round makes each input active |
| MarketData: tick ring buffer, sliding windows (O(1) high/low), 5-minute spread median | ✅ |
| StateEngine: all states, confirmation rules, VOLATILE latch (ATR ratio, shock, spread spike) | ✅ |
| Trade-plan preview: stop and target in £ for the current ATR, checked against the £ caps | ✅ Shows FITS or SKIP with the reason |
| Entry readiness preview: state, session, spread, stale quotes, plan | ✅ What the Round 2 gate will start from |
| Dashboard, chart marks (TU/TD/RG/UN/DE/VO), Experts-log lines `[V10] STATE ...`, daily `[V10] DAY ...` summary | ✅ |
| Orders, playbooks, gatekeeper (news, limits), position manager, ledger, CSV | ⏳ Rounds 2 and 3 |

R1 never sends, modifies or closes orders, even when `InpMode = TRADE`.
