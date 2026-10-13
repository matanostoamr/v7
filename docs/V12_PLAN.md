# v12 Two-Mode Harvester: plan (approved)

**Status:** approved. You said OK, so all the defaults in section 5 are accepted. Build 1.0 is written: `Gold_TwoMode_Harvester_v12.00.mq5`.
**Build 1.0 tested** (Oct 1–7): −£205.94, with 12 cycles closed at +£5 or more and 9 hard stops. **Build 1.1: section 9, approved (you said OK to all defaults in 9.5) and written.**
**Fresh bot:** a new file `Gold_TwoMode_Harvester_v12.00.mq5` with magic `120001`, on its own branch. Nothing is taken from v7, v8, v10 or v11.

## 1. Your design, as I will build it

There are always three places (slots):

| Slot | Direction | Comment on the trade |
|---|---|---|
| BUY slot | always BUY | `V12 B` |
| SELL slot | always SELL | `V12 S` |
| Third slot | the market direction when it opens | `V12 T` |

1. **Cycle start:** when the basket is empty, open the BUY, SELL and third trades together.
2. **Harvest (all three slots, in both modes):** a trade closes when its own net result reaches **£0.50**, meaning profit + swap − its opening and closing commission. Its slot is refilled at once. A losing trade is never closed on its own.
3. **Harvest Mode:** runs until the cycle has **banked £5.00**.
4. **Recovery Mode:** the banked £5 is locked. A Recovery Fund starts at £0. Harvesting and refilling carry on, and losing trades stay open.
5. **Recovery close:** as soon as the fund covers the cost of closing every open trade:
   - stop refills;
   - close all trades, winners too;
   - check that the basket is empty;
   - start a new cycle.
6. **Hard stop:** if the whole cycle (banked + open, after costs) reaches **−£30**, close all, in either mode. It is checked before anything else on every tick, and nothing can delay it.

The third trade is never closed or reversed because the direction changed. It keeps its direction until it is harvested, and its refill takes the direction at that moment. *(Build 1.1 changes this for Recovery Mode; see section 9.)*

Tell me if any line here is not what you meant.

## 2. Accounting

The bot counts only its own trades (magic 120001). All figures are in GBP and come from the real deals in the account history. The one estimate is the closing commission of trades that are still open (see C).

| Figure | Meaning | How it is calculated |
|---|---|---|
| **R** (banked) | everything this cycle has realised | Sum of this cycle's deals: harvest profits, any losses, every opening and closing commission, and swaps. It is £0 when the cycle starts. |
| **P** (protected) | the first £5, locked | P = R at the moment Harvest Mode ends (£5.00 or a little more). It never changes after that. |
| **F** (Recovery Fund) | money earned after the switch | F = R − P. It starts at £0. Harvests add to it; opening commissions and any losses take from it. |
| **C** (close-all value) | what closing every open trade now would give | Sum over open trades of floating profit + swap − closing commission. It is usually negative, i.e. a cost to close. |
| **Cycle result now** | the whole cycle if it closed now | R + C. In Recovery Mode this is P + F + C. |

- The opening commission is charged when a trade opens, so it goes into R at once.
- The closing commission is not charged yet. The bot estimates it as equal to that trade's opening commission (Pepperstone charges £0.02 in and £0.02 out per 0.01 lot).
- Floating profit is already worked out at the closing price (bid for a BUY, ask for a SELL), so the spread is already inside C.

**The three decisions**

| Decision | Rule |
|---|---|
| Harvest Mode → Recovery Mode | R ≥ £5.00 |
| Recovery close | F + C ≥ £0, i.e. the fund covers the close-all cost (the same as cycle result now ≥ P) |
| Hard stop | R + C ≤ −£30.00 |

A recovery close happens only when P + F + C ≥ P. So a finished cycle ends at **P or more: at least +£5 after all costs.** £5 banked while trades are still losing does not finish a cycle.

If nothing is losing when Harvest Mode ends (C ≥ 0), the fund at £0 already covers it. The basket then closes at once, and the cycle ends at £5 or more.

**Order of checks on every tick**
1. Update R and C.
2. If the basket is being closed, keep closing. When it is empty, write the cycle result to the journal and start a new cycle. Do nothing else on this tick.
3. Hard stop: if R + C ≤ −£30, close all.
4. In Recovery Mode: if F + C ≥ £0, close all.
5. Harvest every trade whose net is £0.50 or more (build 1.1: `InpRecoveryHarvestNet` in Recovery Mode, default £0.50).
   - 5b (build 1.1, Recovery Mode only): if the EMA signal is against the third trade, close only the third trade, then run checks 3 and 4 again.
6. In Harvest Mode: if R ≥ £5, switch to Recovery Mode (P = R, F = £0) and run check 4 again at once.
7. Refill any empty slots.

Checks 3 and 4 run before any refill, so no money is spent on a refill that would be closed straight away.

## 3. Examples

**Your example:** Harvest Mode banks £5.00, so P = £5.00 and F = £0. Closing the open trades would cost £4.00 (C = −£4.00). F + C = −£4.00, so the bot carries on. Later F = £4.10 and C = −£4.05. Now F + C = +£0.05, so it closes everything. Cycle result = 5.00 + 4.10 − 4.05 = **+£5.05**.

**Hard stop:** P = £5.20, F = £1.00 and C = −£36.30. R + C = 6.20 − 36.30 = −£30.10, so it closes everything. The −£30 counts the whole cycle, including the £5, as you wrote.

If the price jumps (news, Monday open), the hard stop fills at the next price, so the loss can be more than £30. In your NFP test, a −£25 stop filled at −£35.

## 4. What the accounting will show (from your own tests, not the internet)

A BUY and a SELL of the same size always add up to about £0 before costs, however often they are harvested. Every £0.50 the winner banks, the loser loses in floating. Your three tests show this: the BUY + SELL pair made −£2.88, −£3.07 and −£3.26 before costs.

So in v12:
- When Harvest Mode reaches £5, the open trades will usually be at about −£5 (minus costs, plus whatever the third trade has made).
- In Recovery Mode the fund grows, but the close-all cost grows by about the same amount.
- A cycle finishes at +£5 only when the **third trade** has earned about £5 plus all the cycle's costs. Each trade opened costs about £0.13 in spread and commission.

I'm telling you this so the results don't surprise you. I'll still build your design exactly as written.

## 5. Questions (my default in brackets; say "OK" to accept all of them)

1. **Harvest target per trade:** [£0.50 net, as in v11]
2. **Market direction for the third trade:** [EMA 9 above EMA 21 on closed M5 bars → BUY, otherwise SELL]. You can give your own rule instead, e.g. price above or below EMA 50, or the colour of the last M5 candle. The rule is read only when a third trade opens, so a noisy rule does not add trades.
3. **After a hard stop:** [a) start a new cycle at once], or b) stop the bot until you restart it. With a), several hard stops can happen in a row on a strong trend day. With b), the backtest stops trading after the first hard stop.
4. **Protected amount:** [a) everything banked when Harvest Mode ends, e.g. £5.32, with the fund starting at £0, as you wrote], or b) exactly £5.00, with anything above it (£0.32) starting the fund. The difference only matters after a big win. With a), a news jump that banks +£19 at once means the cycle must earn about £19 more before it can close. With b), the cycle closes sooner and still ends at +£5 or more.
5. **Lot size:** [0.01 for all three trades]

## 6. Necessary basics (no effect on trading decisions)

- **Orders:** sent one at a time, and the bot waits for each result. A failed close is retried on the next tick (at most once a second). A failed open is retried after 5 seconds.
- **Own trades only:** it touches and counts only magic-120001 trades on this symbol. It needs a hedging account (BUY and SELL open together) and will not start on a netting account.
- **Restart safety (live only):** it saves the cycle start, the mode and P in the terminal. After a restart it carries on with the same cycle instead of opening a second basket. This is not used in the Strategy Tester.
- **Comments and journal:** each trade carries its slot (`V12 B/S/T`) and its close reason (`V12 HV` harvest, `V12 RC` recovery close, `V12 HS` hard stop, and from build 1.1 `V12 TF` third-trade flip). The journal gets one line per mode switch, one per third-trade flip (build 1.1) and one per cycle end. This is how I can check your backtest report exactly.

## 7. Not included (only with your OK)

I don't think any of these is needed for the first backtest.

| Feature | Purpose | Possible side effect |
|---|---|---|
| Server stop-loss on each trade | Protects a trade if MT5 is offline | Closes one trade on its own, which breaks the three-slot structure and books a loss inside the cycle. Can fill late in news. |
| Spread limit for new trades | No opening at a very wide spread (news, market open) | A slot can stay empty, leaving the basket one-sided for a while. New cycles can start late. |
| Trading hours / news / Friday close | Avoids risky times and the weekend gap | A forced close books the losses, so the cycle can end below +£5. |
| Daily or total loss limit | Stops after repeated hard stops | Fewer cycles. The bot stays off until the next day or until you restart it. |
| Safety margin for the final close (live) | The price can move while 3 trades close, so a cycle could end at £4.95 | Each cycle closes a little later. Almost no effect in the tester. |
| Real-account lock | No trading on a real account by mistake | No effect on trading. You must switch it off to go live. |
| Chart status text | Shows the mode and the £ figures in the visual tester | None; display only. |

## 8. After your OK

1. I write `Gold_TwoMode_Harvester_v12.00.mq5` on this branch. These are all its inputs: lots, harvest target £0.50, cycle target £5.00, hard stop £30.00, EMA fast 9 and slow 21 (if you accept question 2), and magic 120001.
2. I run a strict compile check (0 errors, 0 warnings) before I push.
3. You compile it in MetaEditor and run the same test as before: XAUUSD M5, Oct 1–7, £1,000, real ticks.
4. I analyse the report cycle by cycle: how many cycles finished at +£5 or more, how many hard stops, and the costs.

## 9. Build 1.1 (approved)

### 9.1 What your build 1.0 test showed
Section 4 predicted this, and your report confirms it:

| | Result for the week |
|---|---|
| BUY + SELL slots together | **−£96.55** from 678 trades. That is almost exactly their spread + commission (about £0.145 per trade = −£98.42). In every one of the 22 cycles they were negative (−£1.81 to −£9.20). |
| Third trade, in the 12 winning cycles | **+£7.70 to +£13.28** per cycle |
| Third trade, in the 9 hard stops | **−£20.92 to −£25.36** per cycle |

So BUY + SELL never pay back a loss; they only pay costs. **Every cycle was won or lost by the third trade.**

Why BUY + SELL can't recover anything. Example: gold goes up $10, then comes back.

| | Fund | BUY open | SELL open | Cycle total |
|---|---:|---:|---:|---:|
| Start | £0 | £0 | £0 | £0 |
| Gold +$10 (BUY harvested about 11 times) | +£5.50 | about £0 | −£7.60 | about −£2 |
| Gold back to start | +£5.50 | −£7.60 (opened near the top) | about £0 | about −£2 |

The −£2 is just spread and commission. Every harvest + refill moves £0.50 from "open" into the fund, and the refill costs about £0.15. So fund + close value (F + C) goes **down** about £0.15 each time.

### 9.2 Your rule (rule 3): the third trade follows the EMA in Recovery Mode
I agree with it. The third trade is the only trade that can bring a cycle back, and this rule keeps it on the side gold is moving.

1. **When:** Recovery Mode only, on every tick, after the hard-stop and recovery-close checks.
2. **Signal:** the existing one: EMA 9 above EMA 21 on the last closed M5 bar means BUY, otherwise SELL. It uses the closed bar, so it changes at most once every 5 minutes. That means at most one flip per bar.
3. **If the signal is against the open third trade:**
   - close only the third trade (comment `V12 TF`);
   - wait until MT5 confirms it is closed;
   - then open a new third trade, 0.01 lot, in the signal direction (`V12 T`).
4. If the hard stop or the recovery close is due at that moment, it goes first, and no new third trade is opened.
5. **Accounting:** the closed trade's result goes into R at once, so the fund (F = R − P) drops by its loss. P does not change and nothing is reset. This is already how build 1.0 counts. For live trading, build 1.1 also keeps a trade that has just closed in C, at its last value, until MT5 shows its real result in the history. So a loss is never missing from R + C, not even for one tick. This makes no difference in the tester, where a close shows in the history at once.
6. The BUY and SELL slots are not touched by this rule.
7. **Journal:** one line per flip, e.g. `v12 CYCLE #7 T FLIP BUY->SELL net -12.34`, so you can count flips.

Rules 1, 2, 4 and 5 in your message (the £5 protection, BUY/SELL harvesting, the loss coming out of the fund, the close at F + C ≥ £0, and the −£30 hard stop) are already how build 1.0 works. Only rule 3 is new code.

### 9.3 My proposal: pay less cost while waiting in Recovery Mode
| | |
|---|---|
| **What** | A new input, `InpRecoveryHarvestNet`: the harvest target for all three trades in Recovery Mode. **Default £0.50, the same as now, so your rule 2 is unchanged** unless you set another value in the tester. Harvest Mode stays at `InpHarvestNet` (£0.50). |
| **Why** | In Recovery Mode, each harvest + refill costs about £0.15 and does not bring the close any nearer (9.1). This week there were 652 harvests in Recovery Mode (501 BUY/SELL, 151 third trade), about **£95** of cost. |
| **Example** | At £2.00, a trade must move about $2.85 instead of $0.85 before it harvests. That gives roughly 3 times fewer harvests and refills, so roughly 3 times less cost. |
| **Side effects** | Fewer harvest trades. The fund grows in bigger steps. Each trade swings more before it harvests. The recovery-close rule, the hard stop and the £5 protection do not change. |

### 9.4 Honest limits
- No rule can promise that every cycle closes without a loss. If gold keeps moving against the basket, the −£30 hard stop is still the last guard.
- Rule 3 should help most in one-way moves. In all 9 hard stops this week, gold had moved $33–42 against the third trade.
- Rule 3 can hurt in choppy markets, where EMA 9 and EMA 21 cross back and forth. Each wrong flip books a small loss (a few £) plus about £0.15 cost. The journal's `T FLIP` lines will show how often that happens.

### 9.5 Questions (all accepted: you said OK)
1. Does rule 3 apply in Recovery Mode only? [yes; Harvest Mode is unchanged]
2. Should the third trade flip even when it is in a small profit (below the £0.50 harvest)? [yes; the rule is about direction]
3. Signal: [existing EMA 9 vs EMA 21 on the last closed M5 bar]
4. Should I add my input `InpRecoveryHarvestNet`? [yes, with default £0.50, so nothing changes unless you set it]

### 9.6 Tests I need after build 1.1
Use the same settings as before: XAUUSD M5, Oct 1–7, every tick based on real ticks, £1,000, 1:30.
1. **Test 1:** default inputs. This is your rule exactly, and I'll compare it with build 1.0 (−£205.94, 12 wins, 9 hard stops).
2. **Test 2** (only if you accept question 4): `InpRecoveryHarvestNet = 2.00`, everything else default.

Send both HTML reports. If you can, also send the Journal lines that start with `v12 CYCLE`.
