# v13 Market Harvester: plan (waiting for your OK)

**Status:** plan only, no code yet. Say **OK** to accept all the defaults in section 7, or tell me what to change.
**New bot:** `Gold_Market_Harvester_v13.00.mq5`, magic `130001`, on its own branch. v12 stays as it is (build 1.1) so you can compare.

## 1. What I understood from your message

| Your words | How I read them |
|---|---|
| "3 trades that harvest" | 3 trades of 0.01. Each closes at its own profit target (harvest) and is opened again. |
| "according to market" | All 3 trades always go the way gold is going: all BUY when it goes up, all SELL when it goes down. There is no fixed BUY or SELL any more. |
| "gaps will not be created that much" | No trade is left far behind the price. A "gap" is how far the price is from a losing trade's entry, which is the same as its loss. |

Tell me if any line is wrong. For example, "gap" could mean weekend or news price jumps, or "according to market" could also mean the harvest size should change with the market.

## 2. What your tests teach (your reports, not the internet)

1. **Fixed BUY + SELL only pay costs.** In v12 build 1.0 they made −£96.55 from 678 trades. That is almost exactly their spread + commission.
2. **The big losses were gaps.** In all 9 hard stops, gold went $33–42 against trades that were never closed.
3. **Build 1.1: fewer trades helped; following the EMA hardly changed anything.**
   - With your default inputs: balance 796 (build 1.0: 794).
   - With `InpRecoveryHarvestNet` = 2.00: balance 817. A bigger harvest means fewer harvests, so fewer trades.
4. **A harvest + reopen in the same direction gives the same money as keeping the trade, minus about £0.15 per harvest.** Example: a BUY opens when gold (bid) is at 4100.00. Gold goes up to 4110.00, then comes back to 4105.00.

| | Result |
|---|---:|
| Keep the BUY open | **+£3.64** |
| Harvest every £0.50 and reopen: 11 harvests bank +£5.50, but the last BUY (opened at about 4109.50) is about −£3.40 | **about +£2.10** |

   The difference, about £1.55, is the cost of the 11 extra trades.

**So, three things decide the result:**
- **Profit** comes only from being on the right side of the market.
- **Gaps** come only from trades on the wrong side.
- **Every trade costs about £0.15.**

v13 is planned around these three.

## 3. The design

1. **Market direction (price turn).** The bot follows the last $5.00 move of gold (bid price, as on the chart).
   - **Going up (BUY):** it remembers the highest price since the up-move began. If gold falls $5.00 below that high, the market has turned down and the direction becomes SELL.
   - **Going down (SELL):** it remembers the lowest price. If gold rises $5.00 above that low, the direction becomes BUY.
   - **At start:** it waits for the first $5.00 move, up or down.
2. **Three trades, always in the market direction:** 3 × 0.01, all BUY or all SELL. They open together and harvest together, so they work like one 0.03 trade split in three. (Spreading them out is in section 9.)
3. **Harvest:** a trade closes when its own net result (after its commission and swap) reaches **£2.00**. It is opened again at once, in the market direction.
4. **Turn:** when the market turns:
   - close all 3 trades, whatever their result;
   - when MT5 confirms they are closed, open 3 new trades in the new direction;
   - the loss stays in the cycle. Nothing is reset.
5. **Cycle (the same £5 idea as v12):**
   - when the cycle total (banked + open, after all costs) reaches **+£5.00**, close all and start a new cycle with 3 new trades in the market direction;
   - **hard stop:** at **−£30.00**, close all and start a new cycle.

**Biggest gap:** a trade is closed at most about $5 behind the best price. So it loses at most **about £3.90, and all three at most about £11.80**. Only a price jump (news, Monday open) can make it bigger.

**Why a price turn instead of the EMA:** in a V-shaped turn, EMA 9/21 on M5 turns about 12 bars (1 hour) after the top, so the gap grows with the speed of the move:

| Gold moves (per M5 bar) | EMA 9/21 turns after | 3 trades opened at the top lose about |
|---|---:|---:|
| $0.50 | $6 | £14 |
| $1.00 | $12 | £28, almost the whole hard stop |
| $2.00 | $24 | £55, hard stop |
| **Price turn (any speed)** | **$5** | **£11.80** |

## 4. Accounting (the same as v12)

| Figure | Meaning |
|---|---|
| **R** (banked) | Sum of this cycle's closed trades, plus the opening commission of the open trades. It is £0 when a cycle starts. |
| **C** (close-all value) | For each open trade: floating profit + swap − closing commission. |
| **Cycle total** | R + C |

| Decision | Rule |
|---|---|
| Cycle target | R + C ≥ +£5.00 → close all, new cycle |
| Hard stop | R + C ≤ −£30.00 → close all, new cycle (checked first, never delayed) |

**Order of checks on every tick**
1. Update R and C, and the market direction (the high or low, and the turn).
2. If trades are being closed, keep closing. When they are all closed:
   - cycle end: write the journal line and start a new cycle;
   - turn: open the 3 new trades.
3. Hard stop.
4. Cycle target.
5. Turn: if the open trades are against the market direction, close them all.
6. Harvest, then check the cycle target again.
7. Open any missing trades in the market direction.

A new cycle always opens in the market direction of that moment.

## 5. Example: a turn, then the cycle wins it back

| Gold (bid) | What the bot does | Cycle total (about) |
|---|---|---:|
| 4120.00 | 3 BUYs are open, all opened at the high (the worst case) | £0 |
| 4115.00 | $5 below the high, so the market has turned. The 3 BUYs close at about −£3.90 each and 3 SELLs open. | −£11.80 |
| 4112.17 | The 3 SELLs harvest +£2.00 each and reopen | −£5.80 |
| 4109.34 | 3 more harvests, and they reopen | +£0.20 |
| about 4107.05 | The cycle total reaches +£5, so everything closes and a new cycle starts | **+£5.00** |

After a turn, gold must move about **$8** the new way to win back the gap and the £5.

**The bad case is a choppy market.** In the example, if gold goes back up to 4120.00 instead, that is another turn. The 3 SELLs close at about −£3.90 each, the cycle is at about −£23.50, and 3 BUYs open. If gold then falls about $3, the cycle reaches −£30 and the hard stop closes it.

## 6. Honest limits

- **v13 wins in moves bigger than about $8 and loses in back-and-forth moves of about $5–8.** Each turn costs up to about £11.80.
- **Harvesting does not add money by itself.** It banks profit and keeps the trades close to the price, and each harvest costs about £0.15 (section 2, point 4). That is why I propose £2.00 rather than £0.50.
- **No rule can promise a cycle without a loss.** The −£30 hard stop stays.
- **Price jumps** (news, Monday open) can fill a turn or a hard stop beyond $5 or −£30.

## 7. Questions (my default in brackets; say "OK" to accept all of them)

1. **New bot:** [v13 as a separate bot; v12 stays as it is]
2. **Market direction rule:** [price turn of $5.00] or EMA 9/21 on M5 (as in v12)
3. **Harvest per trade:** [£2.00 net]. With £0.50 there are about 3 times more harvests, and each one costs about £0.15.
4. **Cycle:** [+£5.00 target, −£30.00 hard stop, and a new cycle at once after either]
5. **Lots:** [0.01 for each of the 3 trades]

## 8. Necessary basics (no effect on trading decisions)

- **Orders:** sent one at a time. A failed close is retried after 1 s, and a failed open after 5 s.
- **Account:** it needs a hedging account, so the 3 trades stay separate. It counts only magic-130001 trades on this symbol.
- **Restart safety (live only):** it saves the cycle, the direction and the high/low in the terminal.
- **Comments and journal:**
  - opening comments: `V13 1`, `V13 2`, `V13 3`;
  - closing comments: `V13 HV` harvest, `V13 TN` turn, `V13 CT` cycle target, `V13 HS` hard stop;
  - journal: one `v13 TURN` line per turn and one `v13 CYCLE #n END` line per cycle.

## 9. Not included (only with your OK)

| Feature | Purpose | Possible side effect |
|---|---|---|
| Start with 1 trade and add up to 3 as the market pays | Fewer trades open while a new direction is not proven | Less profit in strong moves |
| Harvest size that follows the market speed | Bigger harvests when gold moves fast | More inputs, harder to test |
| Server stop-loss, spread limit, trading hours / news / Friday close, daily loss limit | Extra protection | Closes or blocks trades outside the rules above |

## 10. Tests after your OK

1. I write the bot and run the strict compile check (0 errors, 0 warnings). These will be all of its inputs:
   - `InpLots` 0.01
   - `InpHarvestNet` 2.00
   - `InpTurnDistance` 5.00 ($ of gold price)
   - `InpCycleTarget` 5.00
   - `InpHardStop` 30.00
   - `InpMagic` 130001
2. You test with the same settings: XAUUSD M5, Oct 1–7, every tick based on real ticks, £1,000, 1:30.
   - **Test 1:** default inputs.
   - **Test 2:** `InpTurnDistance` = 10.00 (bigger gaps, fewer turns).
3. I analyse both reports turn by turn and cycle by cycle.
