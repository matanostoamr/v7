# v15 Dual Grid Scalper: plan rev 1 (build 1.0)

**Status:** build 1.0 written from your v15 spec, checked offline (not a MetaEditor compile), not backtested.
**Bot:** `Gold_DualGrid_Scalper_v15.00.mq5`, magic `150001`, branch `feat/v15-dual-grid-scalper`. v14 is unchanged (PR #6).
**Numbers below:** £0.74 per $1 per 0.01 lot, spread $0.20, commission £0.02 per 0.01 lot per side.

## 1. Your idea
1. Open BUY 0.01 + SELL 0.01 together (neutral, no gap).
2. When one leg reaches +£1.00 net, check trend/momentum. If it agrees: bank the winner and add trade 3 (0.01). Alternative mode: keep all 3 open and close all at +£2.00.
3. The rest closes together at the combined target. Then a new pair opens at once.
4. v14 safety: at $8 an emergency hedge of 2x the net lots, close all at +£1.00; hard stop −£30 on the floating loss; news filter; spread limit $1.00.

## 2. The key maths: trade 3 decides everything
A BUY 0.01 and a SELL 0.01 together gain **nothing** when gold moves:

| Gold moves | BUY 0.01 | SELL 0.01 | Pair |
|---|---:|---:|---:|
| +$1.61 | +£1.00 | −£1.38 | −£0.38 (costs) |
| +$5.00 | +£3.50 | −£3.88 | −£0.38 |

- The £1 you bank is the same money the other leg has lost. A cycle only makes money from the way it **leans** after trade 3.
- **Mode 1 (bank the winner):** if trade 3 went *with* the move, the cycle would be a BUY + SELL pair again. It could then never reach +£2 and never hit the hedge or the hard stop. So in mode 1, trade 3 goes on the **pullback side** (the same way as the losing leg). When gold comes back to the pair's price, the cycle is at about +£2, which matches your rule "the losing trade retraces to break-even → close at the combined target".
- **Mode 2 (keep all 3):** trade 3 goes **with the move** (2 SELL + 1 BUY after a fall, as you wrote).

## 3. The design (as built)
- **Pair:** BUY + SELL `InpBaseLots` at market on the same tick. One cycle at a time.
- **Step:** a leg reaches `InpHarvestTarget` +£1.00 net (profit + swap + both commissions).
  - **Trend check:** M5 EMA 9 above EMA 21 (last closed bar) → trade 3 may only be a BUY; below → only a SELL. If it doesn't agree, the bot waits (the pair stays neutral). `InpTrendCheck` false = step at once.
  - **Mode 1 (default):** close the winner ("V15 HV", money banked), then trade 3 on the pullback side. The cycle leans 0.02.
  - **Mode 2:** keep both legs, trade 3 with the move. The cycle leans 0.01.
- **Basket target:** cycle net (banked + open trades) ≥ `InpBasketTarget` +£2.00 → close all ("V15 BT").
- **Emergency hedge:** gold `InpHedgeDistance` $8 against trade 3 → `InpHedgeMult` 2 × the net lots, the other way ("V15 EH": 0.04 in mode 1, 0.02 in mode 2). Then cycle net ≥ `InpEmergencyTarget` +£1.00 → close all ("V15 ET").
- **Hard stop:** open trades together ≤ −`InpHardStop` £30 → close all ("V15 HS").
- **Zero gap:** after a cycle closes, the next pair opens on the same tick (if P1–P3 allow).

## 4. What each mode means (coin-flip market, no edge)
| | Mode 1 harvest | Mode 2 keep |
|---|---|---|
| Cycle right after trade 3 | −£0.57, leans 0.02 pullback side | −£0.57, leans 0.01 with the move |
| +£2 basket target | gold ~$1.7 back toward the pair price | gold ~$3.5 further |
| Emergency hedge | 0.04, cycle about −£13 | 0.02, cycle about −£7 |
| After the hedge: +£1 / hard stop | $9.6 further / $10.7 back | $10.6 further / $31 back |
| Basket target / emergency target / hard stop | 82% / 10% / 8% | 70% / 23% / 8% |
| Average per cycle with trade 3 | **−£0.70** | **−£0.69** |

- On a market with no direction both modes lose about the costs. **One hard stop (−£29 to −£30) wipes out about 15 basket targets (+£2).** So the trend check must pick trade 3's side much better than a coin flip. Only your tests can show if it does.
- Hard stops can be worse than −£30 on news jumps (v14: worst −£34.16).

## 5. The complete list of inputs
- `InpBaseLots` 0.01: each pair leg and trade 3
- `InpMode` 1 (1 = bank the winner, trade 3 pullback side; 2 = keep all 3, trade 3 with the move)
- `InpHarvestTarget` 1.00 (£), `InpBasketTarget` 2.00 (£)
- `InpMaxOpenTrades` 3 (normal trades open at once, 2–3; mode 2 needs 3; the hedge is +1)
- `InpHedgeDistance` 8.00 ($ against trade 3), `InpHedgeMult` 2.0, `InpEmergencyTarget` 1.00 (£)
- `InpHardStop` 30.00 (£, floating)
- `InpTrendCheck` true, `InpTrendTF` M5, `InpEmaFast` 9, `InpEmaSlow` 21
- `InpMaxSpread` 1.00 ($; 0 = off)
- `InpNewsFilter` true, `InpNewsStart` "15:00", `InpNewsEnd` "15:45" (daily Mon–Fri: CPI, NFP at 15:30 server = 8:30 New York)
- `InpRateDays` = the US rate decision days (FOMC, from federalreserve.gov) 2026.06.17 → 2027.12.08, `InpRateStart` "20:30", `InpRateEnd` "22:00" (decision 21:00 server, press conference 21:30)
- `InpMagic` 150001

## 6. Safety and basics (inherited from v14)
- **P1 margin:** a new pair only if free margin ≥ 1.5 × the whole cycle's margin with the hedge (broker's hedge rule). About £164 per 0.01 lot: mode 1's worst side is 0.04 ≈ £656, so P1 needs ≈ £984 free; mode 2's is 0.03 ≈ £492, needs ≈ £738. **Mode 1 on £1,000 stops after the first small loss: test it with £2,000.** The real numbers are in the journal on the first tick.
- **HF:** a pair leg, trade 3 or the hedge that fails 3 times closes the cycle.
- **P2 spread:** no new pair and no step above $1.00. The hedge and all exits always work.
- **P3 news:** no new pair and no step inside the windows. An open cycle keeps its hedge, targets and hard stop. No Friday rule, no other quiet time.
- **Restart (live):** carries on if the open trades form a cycle, else closes them ("V15 RS"). Mode 1's banked money is kept in a terminal global variable.
- **Journal:** settings, margin, each window, one `CYCLE #n` line (how it ended, result, step, hedge, trades), and a `SUMMARY` line.
- Hedging account needed. Market orders only.

## 7. Tests (you run them)
XAUUSD M5, every tick based on real ticks, 1:30, build 1.0 defaults unless written.
1. **Test A, mode 2:** £1,000, 2026.08.01 → 2026.10.18.
2. **Test B, mode 1:** £2,000, same dates (`InpMode=1`, the default).
3. Compare with v14 Test C (Aug–Oct: +£178.15, worst monthly drop £157.69). Then I check every cycle against the rules.

## 8. Build 1.0 notes
- Built exactly the spec above. Choices I had to make (tell me to change any): trade 3's side per mode (section 2), M5 EMA 9/21 for the trend check, the hedge distance measured from trade 3's price, targets on the whole cycle (banked + open), hard stop on the floating loss (your words), news and spread also pause the step, rate decision dates as an input.
- Added inputs beyond your list: `InpMode`, `InpEmergencyTarget`, the trend inputs, `InpMaxSpread`, the news times and dates, `InpMagic`.
- **Checked here:** offline syntax and type check, 0 errors and 0 warnings. Not a MetaEditor compile. No backtest.
