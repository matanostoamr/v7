# v14 Hedge Harvester: plan rev 2 (approved, build 1.0 written)

**Status:** you said OK to the defaults + P1 + P2. Build 1.0 is written: `Gold_Hedge_Harvester_v14.00.mq5` (notes in section 12). v13 stays as it is (PR #5, stopped).
**New bot:** `Gold_Hedge_Harvester_v14.00.mq5`, magic `140001`, on its own branch `feat/v14-hedge-harvester`.
**Numbers in this plan:**
- gold at $4,000; 0.01 lot = $1 per $1 move ≈ £0.75 (GBP/USD 1.33);
- spread $0.36 and commission £0.02 per 0.01 lot per side, as in your v13 reports.

## 1. Your idea
- Indicators find the real market direction and momentum.
- Trade 1 enters on a pullback with a limit order, or at market when momentum confirms.
- **Winning path:** trade 1 harvests a quick profit.
- **Losing path:** if trade 1's floating loss reaches a set level, the bot opens an opposite hedge with double the lot (0.01 BUY → 0.02 SELL). The trades then close together at breakeven or a small profit.
- At most 1–3 trades: trade 1, the hedge and an optional 3rd trade. Margin must stay safe at UK 1:20.
- A hard basket stop is the last safety net.

## 2. What the hedge really does (maths with your numbers)
**Example:** trade 1 BUY 0.01 at 4000. Gold falls to 3992 ($8 against), and the hedge SELL 0.02 opens. Costs are left out of this small table.

| Gold after the hedge | Trade 1 (BUY 0.01) | Hedge (SELL 0.02) | Basket |
|---|---:|---:|---:|
| falls to 3984 | −$16 | +$16 | $0 |
| stays at 3992 | −$8 | $0 | −$8 |
| comes back to 4000 | $0 | −$16 | −$16 |

1. **After the hedge opens, the basket moves like one 0.01 SELL opened at 3984.** The hedge gains $2 per $1 and trade 1 loses $1 per $1, so the basket recovers at the speed of one 0.01 trade.
2. **The $8 loss is not removed.** Gold has to fall **another $8** (to 3984) just to break even, and about $10 (to 3981.79) for the basket to reach +£1 after costs. If gold comes back up instead, the basket loses.
3. **The result is the same as closing trade 1 at −$8 and opening a 0.01 SELL.** The hedge just costs more: spread and commission on 0.03 lots instead of 0.02, and overnight swap on every open trade.
4. **Trade 3** (BUY 0.03 at 4000, if gold comes back up) turns the basket again; it then moves like a 0.02 BUY.
   - It reaches +£1 at about 4009.
   - But the −£30 hard stop is then at 3988.57, only about $3.40 below the hedge price.
   - With 0.04 instead of 0.03, the hard stop would be at 3992.40, right on the hedge price. That's why trade 3 is 0.03.
5. **So the hedge wins when gold keeps going after trade 1 fails, and loses when gold swings back.**
   - Your October week (rough check in the v13 plan): after an $8 move, gold went another $8 the same way 56% of the time. Good for the hedge.
   - September (Sep 1–10): 54% of v13's moves turned back before even one harvest. Bad for the hedge.

**On a market with no direction** (the next $1 is as likely up as down), with the defaults in section 3:

| Max trades | Trade 1 harvests (+£4) | Hedge recovers (+£1) | Trade 3 recovers (+£1) | Hard stop (−£30) | Average per basket |
|---|---:|---:|---:|---:|---:|
| 1 (no hedge: trade 1 waits for its harvest or the hard stop) | 87% | – | – | 13% | −£0.31 |
| 2 | 57% | 32% | – | 11% | −£0.58 |
| 3 | 57% | 18% | 13% | 11% | −£0.81 |

- **About 1 basket in 9 hits the hard stop with every choice.** The hedge doesn't make hard stops rarer. It changes how the loss comes, and it costs a little more.
- **So the profit has to come from the entry.** v14 makes money only if trade 1 harvests on its own, before any hedge, in about **2 of every 3 baskets**. That needs 60–64% (depending on max trades); a coin flip gives 57%.
- Hard stops can lose more than £30 when the price jumps. v13 lost £51.62 at the Sep 4 news.

This doesn't mean v14 can't work. It means the indicator entry is the part that must be good, and the tests in section 10 measure exactly that.

## 3. The design
**Direction and momentum,** checked once per new M5 bar, on closed bars:
1. **Trend (M15):** EMA 20 above EMA 50 → buys only. EMA 20 below EMA 50 → sells only.
2. **Movement (M15):** ADX(14) must be 20 or more. Below 20 the market is flat or choppy, so no new basket starts.
3. **Not exhausted (M5):** no new buy while RSI(14) is 70 or more, no new sell while it is 30 or less.

**Trade 1 (0.01).** Only one basket is open at a time.
- **Mode 1, limit (default):** while the conditions hold and the last M5 close is above the M5 EMA 20, a **BUY LIMIT** waits at that EMA. It moves to the new EMA value at every new M5 bar, and is deleted when the conditions stop. Sells mirror this: a SELL LIMIT at the EMA while the close is below it.
- **Mode 2, market:** first an M5 bar closes below the M5 EMA 20 (the pullback). Then the first M5 bar that closes back above it with RSI above 50 opens a BUY at market. Sells mirror this.

**Winning path:** trade 1 closes at **+£4.00 net** (harvest), and the basket is done.

**Losing path:**
1. **Hedge:** when gold is **$8** against trade 1 (about −£6.70 with costs), a **0.02** trade opens the other way at market.
2. **Trade 3** (only if max trades = 3): after the hedge, if gold comes back to trade 1's price, a **0.03** trade opens in trade 1's direction at market.
3. **Basket target:** after the hedge, all open trades close together at **+£1.00 net**.
4. **Hard stop:** at any time, all open trades close together at **−£30.00 net**.

After a basket closes, the next one needs a fresh signal on a new M5 bar. While a basket is open, no new basket starts.

## 4. Example: three ways a BUY basket can end (defaults, max trades 3)
| Gold (bid) | What happens | Basket (net) |
|---|---|---:|
| 3999.64 | Trade 1 BUY 0.01 fills at 4000.00 (ask) on the pullback | −£0.31 |
| **A.** 4005.37 | Trade 1 harvests | **+£4.00** |
| **B.** 3992.00 | $8 against: the hedge SELL 0.02 opens | −£6.68 |
| 3981.79 | The basket reaches +£1, so both trades close | **+£1.00** |
| **C.** 3992.00 → 3999.64 | The hedge opens, then gold comes back: trade 3 BUY 0.03 opens at 4000.00 (ask) | −£13.35 |
| 4009.18 | The basket reaches +£1, so all 3 trades close | **+£1.00** |
| or 3988.57 | The basket reaches −£30: hard stop, all 3 trades close | **−£30.00** |

With max trades 2 there is no trade 3. After the hedge, the basket closes at 3981.79 (+£1) or at 4023.02 (−£30).

## 5. Margin (UK 1:20 = 5%: about £160 per 0.01 lot at $4,200)
MT5 charges the uncovered volume at the normal rate, and the covered (hedged) volume **once**, at the broker's hedged rate (0–100% of normal). Some brokers charge only the bigger side.

| Open trades | Lots | Margin |
|---|---|---:|
| 1 | 0.01 | £160 |
| 2 (with the hedge) | 0.01 + 0.02 | £160 – £320 |
| 3 | 0.01 + 0.02 + 0.03 | £320 – £640 |

- Build 1.0 reads the broker's hedge rule and prints the margin for 1, 2 and 3 trades in the journal on the first tick.
- With P1 (× 1.5), max 2 trades needs up to £480 free margin, so it fits £1,000 easily. Max 3 needs up to £960, so on £1,000 a basket starts only while almost all the money is free. **Use £1,500 or more to test max 3.**

## 6. Improvements I suggest (each needs your OK, otherwise it is not built)
**P1. Margin safety (recommended)**
- **What:** trade 1 opens only if free margin covers the whole basket plus 50%, using the broker's hedge rule. A failed hedge or trade 3 is retried every second. After 3 failed tries, all trades close, so a losing trade is never left without its hedge.
- **Why:** in September v13 ran out of margin, and about 45,000 orders were refused. In v14, a missing hedge would leave the loss open.
- **Side effect:** no basket starts when the account is too small, for example 3 trades on £1,000 if the broker counts both sides.

**P2. Spread limit for trade 1 (recommended)**
- **What:** no new basket while the spread is above $1.00. The hedge and trade 3 always open, whatever the spread.
- **Why:** v13 spreads were $0.08–$1.50 (middle $0.36). In all three v13 tests (Sep 1–10, Oct week ×2), trades opened from 23:00 to 02:59 server time lost money: −£88, −£38, −£30. These are the daily close and open hours, when spreads are usually widest.
- **Side effect:** fewer baskets around the daily open and in news spikes.

**P3. Quiet times (optional)**
- **What:** no new basket from 15:00 to 15:45 server time (US news is at 15:30), and none on Friday after 21:00.
- **Why:** both v13 hard stops came at 15:30 news: Sep 4 −£51.62 and Sep 11 about −£45. A v13 move lasted 14 minutes in the middle case, so most baskets started before 15:00 are closed by 15:30.
- **Side effect:** misses the big news moves, which can also be profits. Baskets already open keep running.

**P4. Daily loss limit (optional)**
- **What:** after the day's closed trades reach −£60 (two hard stops), no new basket until the next day.
- **Why:** a zig-zag day can hit the hard stop again and again.
- **Side effect:** misses the rest of that day, including good moves.

## 7. Questions (defaults in [ ])
1. **Indicators:** [M15 EMA 20/50 + M15 ADX at least 20 + M5 RSI limits 70/30]. In v13 we dropped EMA 9/21 because it reacted late. Here the EMAs only choose the side; the entry itself waits for an M5 pullback. If you prefer other indicators, tell me.
2. **Entry:** [mode 1: limit at the M5 EMA 20], or mode 2: market after the pullback, when RSI confirms.
3. **Hedge distance:** [$8 against trade 1, about −£6.70 floating]. A price distance keeps the hedge price fixed on the chart, and it doesn't change with GBP/USD.
4. **Harvest / basket target / hard stop:** [£4 / £1 / £30].
5. **Max trades:** [2], or 3.
6. **Lots:** [0.01 / 0.02 / 0.03].
7. **Improvements:** [P1 + P2], plus P3 and/or P4 if you want them.

## 8. The complete list of inputs (build 1.0)
- `InpLots` 0.01: trade 1
- `InpMaxTrades` 2 (1 = no hedge, 2 = + hedge, 3 = + trade 3)
- `InpHarvestNet` 4.00 (£): trade 1 alone closes at this net
- `InpHedgeDistance` 8.00 ($): the hedge opens when gold is this far against trade 1
- `InpHedgeMult` 2.0: hedge lot = InpLots × 2.0 = 0.02
- `InpTrade3Mult` 3.0: trade 3 lot = InpLots × 3.0 = 0.03
- `InpBasketTarget` 1.00 (£): after the hedge, all trades close together at this net
- `InpHardStop` 30.00 (£)
- `InpEntryMode` 1 (1 = limit, 2 = market)
- `InpTrendTF` M15, `InpEmaFast` 20, `InpEmaSlow` 50, `InpAdxPeriod` 14, `InpAdxMin` **15** (0 = off)
- `InpEntryTF` M5, `InpPullEma` 20, `InpRsiPeriod` 14, `InpRsiMax` 70 (sells use 100 − 70 = 30; 100 = off)
- `InpMaxSpread` 1.00 $ (P2; 0 = off)
- `InpMagic` 140001

## 9. Necessary basics (no effect on trading decisions)
- **Account:** needs a hedging account, so BUY and SELL trades can be open together. This is checked at the start.
- **Own trades only:** magic 140001, this symbol.
- **Orders:** there is at most one pending order (the trade 1 limit). The hedge and trade 3 open at market.
- **Timing:** signals use closed bars, checked at the first tick of each new M5 bar. Money and prices are checked on every tick.
- **Order of checks on every tick:**
  1. Update the trades.
  2. If all trades are being closed, keep closing.
  3. Hard stop.
  4. Harvest (before the hedge) or basket target (after it).
  5. Hedge.
  6. Trade 3.
  7. On a new M5 bar: check the signal, then place, move or delete the limit (mode 1), or open at market (mode 2).
- **Limit price:** if gold has already dipped through the EMA, no limit is placed on that bar. The broker's minimum distance is respected.
- **Retries:** a failed close is retried after 1 s and a failed trade 1 after 5 s. The hedge and trade 3 follow P1, or are retried every 1 s without P1.
- **Net:** profit + swap − commission on both sides, as in v13.
- **Comments:**
  - opening comments: `V14 1`, `V14 H` (hedge), `V14 3`;
  - closing comments: `V14 HV` harvest, `V14 BT` basket target, `V14 HS` hard stop.
- **Journal:**
  - one line per basket: how it ended, the result, the trades used, start and end time;
  - a summary at the end of a test: baskets, % harvested by trade 1 alone (the key number from section 2), hedge recoveries, trade 3 recoveries, hard stops, average per basket.
- **Restart (live only):** the bot carries on with its own open trades if they form a basket. If they don't, it closes them.

## 10. Tests after the build
1. **Step 1, one test:** August, 2026.08.01 → 2026.09.01 (the tester stops at the start of the end date). Use XAUUSD M5, every tick based on real ticks, £1,000, 1:30 and the default inputs. Attach the HTML report, or paste it. I'll check the rules trade by trade, the margin numbers and the trade 1 harvest rate.
2. **Step 2, optimizer on August only:** `InpMaxTrades` 1 → 3, `InpHedgeDistance` 6 → 14 step 2, `InpEntryMode` 1 → 2. That's 30 passes with "Slow complete algorithm". Paste the XML. Use £2,000 if step 1 shows that 3 trades need more than about £650 margin.
3. **Step 3, check on new months:** take the best August setting, unchanged, and run it on July (07.01 → 08.01), September (09.01 → 10.01) and October (10.01 → 10.15). v14 passes only if it makes money in all three and the biggest drop stays below £250.

Choosing on one month and checking on others avoids the luck problem we saw in v13, where the best InpTurn was different in every month.

## 11. Later (not in build 1.0)
- Distances that follow the market's speed (ATR) instead of fixed $. v13's best InpTurn was different in every month.
- Broker-side safety stops, so the hard stop also works when MT5 is off. This is needed before a live account.
- More news times, for example 21:00 for US rate decisions.

## 12. Build 1.0 notes
- **Built:** the defaults + P1 + P2. P3 (quiet times) and P4 (daily loss limit) are not built.
- **Input names as you asked:** `InpHarvestNet`, `InpHedgeDistance`, `InpBasketTarget`. The hedge and trade 3 sizes are inputs too (`InpHedgeMult`, `InpTrade3Mult`), and so is the entry timeframe (`InpEntryTF`).
- **More active, as you asked:**
  - `InpAdxMin` default is 15 instead of 20. Set 20 for the plan's value, or 0 to switch the flat-market pause off.
  - `InpRsiMax` 100 switches the RSI limit off; `InpMaxSpread` 0 switches P2 off.
  - `InpTrendTF` M5 makes the trend change faster.
  - The EMA trend always gives a side, so the bot is never waiting for a big move. The longest quiet time comes from a hedged basket: while it waits for +£1 or the hard stop, no new basket starts (your 1–3 trades rule).
- **P2 with a limit order:** when the spread goes above $1, the waiting limit is deleted and placed again on the next M5 bar. In mode 2 the bot waits until the spread is back to normal.
- **Two more closing comments:** `V14 HF` (P1: the hedge or trade 3 failed 3 times, so all trades closed) and `V14 RS` (restart: open trades that don't form a basket).
- **Journal:**
  - the settings at the start;
  - the broker's hedge rule and the margin for 1, 2 and 3 trades on the first tick;
  - one `BASKET #n` line per basket: how it ended, the result, trades used, start and end time;
  - a `SUMMARY` line at the end: baskets, % harvested by trade 1 alone, recoveries with the hedge and with trade 3, hard stops, total, average.
- **Checked here:** a syntax and type check with my offline checker (0 errors, 0 warnings). That is not MetaEditor, so please compile it. No backtest was run, as you asked.
