# v13 Market Harvester: plan rev 2 (waiting for your OK)

**Status:** plan only, no code yet. Say **OK** to accept all the defaults in section 6, or tell me what to change.
**New bot:** `Gold_Market_Harvester_v13.00.mq5`, magic `130001`, on its own branch. v12 stays as it is.
**Rev 2:** the 3-trades-at-once plan (rev 1) is replaced by your new idea.

## 1. Your idea
- Start with 1 trade. Add more only if needed, up to **4 trades** of 0.01.
- Every trade harvests.
- Trades are added with **pending orders** at prices chosen in advance, so the bot controls the price and gaps stay small.
- Main goal: **never a big loss**. Losing trades are closed with a small loss or no loss.

## 2. The math (from your own test week, Oct 1–7, prices rebuilt from your 4 reports)

**Fact 1: this week, gold's moves continued more often than they came back.**

| After gold moved | It moved the same distance again **further** first | It **came back** first |
|---|---:|---:|
| $2 | 62% | 38% |
| $3 | 59% | 41% |
| $5 | 60% | 40% |
| $8 | 56% | 44% |

**Fact 2: a limit order only fills when gold comes back towards it, against the trades already open.** For example, a BUY LIMIT below the price fills only while gold is falling. So adding with limit orders means adding while gold moves against you, and this week gold then went further against you about 59% of the time.

**Fact 3: I checked both ways of adding trades on your week.** Both use the same rules otherwise: up to 4 trades, harvest, −£30 hard stop.

| | **A: add against the move** (limit orders, close all at no loss) | **B: add with the move** (close all when the market turns) |
|---|---|---|
| Result for the week | **−£156 to −£703** (16 settings) | **+£124 to +£620** (12 settings) |
| Wins | many small ones, £2–3 | fewer, bigger ones |
| Losses | **19–40 hard stops at −£30** | small, about £3–8 each at a turn, no hard stops |

This is a rough check, not a backtest. The prices are rebuilt from the deals in your reports, accurate to about $1. Real ticks have more back-and-forth, so B will do worse on real ticks than this check shows. Your MT5 test is the real check.

**So I plan B.** It is still your idea (start small, add up to 4, harvest, small gaps), but trades are added when gold moves **our** way, and losing trades are closed early, while they are still small.

## 3. The design (B)
1. **Market direction: a $5.00 price turn** (bid price, as on the chart).
   - While going up, the bot remembers the highest price. If gold falls $5 below that high, the market has turned down.
   - While going down, it remembers the lowest price. If gold rises $5 above that low, the market has turned up.
2. **Trade 1** opens at market in the market direction whenever no trade is open.
3. **Trades 2–4** are added by **one pending order**, placed $3.00 beyond the furthest trade:
   - going up: a BUY STOP $3 above the highest BUY;
   - going down: a SELL STOP $3 below the lowest SELL.

   So a trade is added only after gold has gone $3 more our way.
4. **Harvest:** each trade closes on its own at **+£4.00 net** (after its commission and swap). When all trades are harvested, trade 1 opens again.
5. **Turn:** when the market turns, close all trades and delete the pending order. Then trade 1 opens in the new direction.
6. **Hard stop:** if the open trades together reach **−£30**, close them all. This is only a safety net for price jumps; normally a turn closes the trades long before that.

**Why gaps stay small:** at a turn, only trades opened in the last $5 before the high can be losing. Trades are at least $3 apart, so at most 2 of them can be losing at once:
- the top trade loses at most about £3.92;
- the next one loses at most about £1.65.

So a turn costs **at most about £5.60** in total, unless the price jumps (news, Monday open).

## 4. Examples (0.01 lot, spread $0.13, commission £0.04 per trade)

**A good move:**

| Gold (bid) | What the bot does | Banked |
|---|---|---:|
| 4100.00 | Market is going up: trade 1 BUY opens. A BUY STOP waits at 4103.00. | £0 |
| 4103.00 | Trade 2 BUY opens (gold went $3 our way). The next BUY STOP waits at 4106.00. | £0 |
| 4105.48 | Trade 1 harvests | +£4.00 |
| 4106.00 | Trade 3 BUY opens | +£4.00 |
| 4108.48 | Trade 2 harvests | +£8.00 |
| 4103.48 | $5 below the high, so the market has turned down. Trade 3 closes at −£2.05. The new direction is SELL, so trade 1 SELL opens. | **+£5.95** |

**The bad case: a choppy market.**
- Trade 1 BUY opens at 4100.00. Gold reaches 4102.00, then falls to 4097.00, a turn. The BUY closes at −£2.41, and a SELL opens.
- Gold rises back to 4102.00, another turn. The SELL closes at −£3.92.

Every back-and-forth like this costs about £2.40–£3.90. In my check on your week, there were 79 losing direction changes (average −£4.45) and 66 winning ones (average +£12.12), for a total of +£465.

## 5. Honest limits
- **B wins only while gold keeps going more than it comes back**, as it did in your test week (59%). In a week where gold mostly comes back, B loses about £2.40–£5.60 at each turn, many times.
- **The real-tick result will be worse than my check.** Real prices wobble more, which means more turns.
- **No rule can promise "never a loss".** B makes the losses small and frequent, instead of rare and −£30.

## 6. Questions (my default in brackets; say "OK" to accept all of them)
1. **How to add trades:** [B: with the move, pending STOP orders], or A: against the move, LIMIT orders, as you first wrote. If you say A, I'll build A exactly; it lost £156–£703 in my check.
2. **Market turn:** [$5.00]
3. **Distance between trades:** [$3.00]
4. **Harvest per trade:** [£4.00 net]
5. **Max trades / lots / hard stop:** [4 / 0.01 / −£30]

## 7. The complete list of inputs
- `InpLots` 0.01
- `InpMaxTrades` 4
- `InpTurn` 5.00 ($)
- `InpStep` 3.00 ($)
- `InpHarvestNet` 4.00 (£)
- `InpHardStop` 30.00 (£)
- `InpMagic` 130001

## 8. Necessary basics (no effect on trading decisions)
- **Orders:** sent one at a time. A failed close is retried after 1 s, and a failed open after 5 s. There is never more than one pending order.
- **Own trades only:** it counts only its own trades (magic 130001) on this symbol. It needs a hedging account, so the trades stay separate.
- **Comments:**
  - opening comments: `V13 1` to `V13 4`;
  - closing comments: `V13 HV` harvest, `V13 TN` turn, `V13 HS` hard stop.
- **Journal:** one `v13 TURN` line per turn, with the result of that move.

## 9. Tests after your OK
Use the same settings as before: XAUUSD M5, Oct 1–7, every tick based on real ticks, £1,000, 1:30.
1. **Test 1:** default inputs.
2. **Test 2:** `InpTurn` = 8.00.
