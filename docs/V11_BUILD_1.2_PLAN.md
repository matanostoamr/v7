# v11 build 1.2: plan (revision 2, waiting for your OK)

> Nothing is built or merged yet. The code on this branch is still **build 1.1**.
> You approved sections 1, 2, 4, 5 and 6 in principle. **Section 3 is rewritten** as you asked, and it has one open point (3b).
> Reply in the chat **"ok A"** or **"ok B"** (see 3b), or change any point. Then I build 1.2 on this branch and show the full diff in PR #3 before any merge.

## What stays the same (as you asked)

- Harvest at **£0.50 net for all trades** (anchors and worker). The backup TP stays at £0.80.
- Worker flip stays **OFF**.
- **No** fixed 30-minute pause.
- The worker's stop stays at **−£3**. It is never widened.

## 1. Worker stop at −£3 net

- The worker (the 3rd trade) closes at **−£3 net**, after commission.
- The −£3 is also placed on the server as the worker's SL.
- If the broker refuses that SL, the bot keeps retrying it, and it still closes the worker itself at −£3.
- Slippage can make the real loss bigger than £3.

## 2. Pause the worker only when it keeps hitting its stop

- **Pause:** the worker hits its −£3 stop **3 times in a row**, with no worker harvest in between. After that, the bot opens no real third trade.
- **During the pause:**
  - The BUY and SELL anchors keep running exactly as now.
  - The bot also runs a **paper worker** in memory. It sends no orders, but uses the same rules on real prices, spread and commission: it opens with the Pulse, harvests at +£0.50 and stops at −£3.
- **Resume:** after **3 paper harvests in a row**, the real worker comes back.
  - That means the market moved about $2.6 one way without a $4 pullback against the paper trade.
  - A paper stop resets the paper count to 0.
- There is no timer. Both "3"s are inputs, and 0 turns the pause off.
- The pause state is saved if MT5 restarts.

## 3. If an anchor hits its £25 disaster SL (revised)

- The bot immediately closes everything else v11 has open on this symbol: the other anchor and the worker.
- The entry filters do not delay these closes, because they only control new trades.
  - Until each close fills, the trades keep their own server SL/TP.
  - If the market is closed (no quotes), the bot retries when quotes come back.
- **No anchor is reopened in this cycle, and the worker is never promoted.** The worker keeps its −£3 stop until it is closed.
- The basket is then empty and the cycle ends.
- A **fresh cycle** (new BUY + SELL anchors) starts only when **all normal entry conditions** pass again: trading hours, spread, shock, news and margin. There is no extra timer.
- If the cycle P&L has reached −£40, the basket stop and its 60-minute cooldown (section 4) also apply. The £50 daily limit still applies.
- The bank pays the losses as now. It cannot go below 0.
- The bot saves this state, so if MT5 restarts during the closing, it carries on.
- The worker's own −£3 server SL is **not** a disaster SL. A worker stop does not close the basket; sections 1–2 apply instead.

### 3a. Trade roles (needed because the worker is never promoted)

- When a trade opens, it is marked as **BUY anchor**, **SELL anchor** or **worker** (in its order comment). It keeps that role until it closes.
- A missing anchor is reopened in its own direction, and only when the normal entry filters allow it.
- The third place follows the worker rules: Pulse UP opens a BUY worker, DOWN opens a SELL worker, NEUTRAL opens none. The pause (section 2) and the same-direction wait (6b) also apply.
- **Small change from 1.1:** in 1.1, when an anchor harvested while the worker was on the same side, the refill sometimes went to the other side, or did not happen, depending on the Pulse. In 1.2 the anchor is always refilled in its own direction. The worker changes side only through its own harvest or its stop (flip OFF).

### 3b. Open point: an anchor can also go missing without a disaster SL

In build 1.1, the entry filters sometimes block a refill: after 23:00, in a news window, during a shock pause, or when the spread is wide. The bot still harvests one trade then and leaves its place empty until the filters open. The server's backup TP (+£0.80) can also close a trade at that time.

If that trade is an anchor, the other anchor runs without its pair, for example overnight until 01:30. Please choose:

- **A. Keep as in 1.1.**
  - The empty anchor place waits for the filters to open.
  - The other trades keep their server SL/TP and their rules.
  - If the lone anchor reaches −£25, rule 3 closes everything.
- **B. Never leave an anchor alone (my recommendation).**
  - The bot does not harvest an anchor while its refill is blocked.
  - If the server's backup TP still closes an anchor at that time, rule 3 applies: the bot closes the rest and starts a fresh cycle when the filters open.
  - The £0.50 target does not change, only the timing of anchor harvests while the filters are closed. The worker harvests as now.
  - On many nights the price moves enough to hit a backup TP, so B may close the basket overnight and restart it at 01:30.

## 4. Basket stop on the cycle P&L at −£40

- **Cycle:** starts when the basket opens from empty and ends when the basket is empty again.
- **Cycle P&L:** everything v11 closed in this cycle (after commission and swap), plus the open trades now (after round-trip commission).
- At **−£40**, the bot closes everything, then waits out the existing 60-minute cooldown.
- **Note:** build 1.1 uses £25, counted on open trades only. I could not find −£40 in the spec or the code, but I will use −£40 as you asked.
- **Note:** profit already closed in a cycle gives the open trades more room. For example, after +£20 closed, the stop fires when the open trades reach −£60. The daily limit (£50) and the kill switch still protect the account.

## 5. Pulse bug fix

**The bug:** when the Pulse is UP, a score between −40 and −15 counts for nothing, and it also resets the count. So in a sharp fall the Pulse often cannot even turn NEUTRAL. The same happens for DOWN, the other way round.

**How build 1.2 counts:** when the Pulse is UP, every bar scoring below +15 counts as "leaving UP". When 2 such bars come in a row:

- if both scored −40 or lower, the Pulse turns DOWN;
- otherwise, it turns NEUTRAL.

Changes from NEUTRAL to UP or DOWN stay exactly as they are now.

Proposed new code (replaces the start of `ApplyPulse` in `Gold_Triad_Harvester_v11.00.mq5`):

```mql5
void ApplyPulse(const V11Pulse &p, const datetime when, const bool quiet)
  {
   double score  = p.score;
   int    target = 99;                      // 99 = this bar does not push towards a change
   if(g_bias == 0)
     {
      if(score >= InpPulseOn)
         target = 1;
      else if(score <= -InpPulseOn)
         target = -1;
     }
   else
     {
      double along = score * g_bias;        // the score seen from the current direction
      if(along < InpPulseOff)               // UP is left below +15, DOWN above -15
         target = (along <= -InpPulseOn ? -g_bias : 0);
     }
   if(target == 99)
     {
      g_candCount  = 0;
      g_candStrong = 0;
      return;
     }
   if(g_bias == 0)
     {
      //--- from NEUTRAL: the same direction N bars in a row (unchanged)
      if(g_candCount > 0 && g_candidate == target)
         g_candCount++;
      else
        {
         g_candidate = target;
         g_candCount = 1;
        }
     }
   else
     {
      //--- from UP or DOWN: N bars in a row against it; reverse only if the last N were all strong
      g_candCount++;
      g_candStrong = (target != 0 ? g_candStrong + 1 : 0);
      g_candidate  = (g_candStrong >= InpPulseConfirmBars ? -g_bias : 0);
     }
   if(g_candCount < InpPulseConfirmBars)
      return;
   g_bias       = g_candidate;
   g_candCount  = 0;
   g_candStrong = 0;
   g_biasSince  = when;
   // ... the log line stays as it is
  }
```

| Pulse is UP, then 2 bars score… | 1.1 (bug) | 1.2 |
|---|---|---|
| −30, −30 | stays UP | NEUTRAL |
| −45, −30 | stays UP (count reset) | NEUTRAL |
| −45, −45 | DOWN | DOWN |
| +10, +10 | NEUTRAL | NEUTRAL |
| +20, +20 | stays UP | stays UP |

## 6. Two rules (approved in principle; both will be inputs)

- **a. Bank re-anchoring is for anchors only.** Otherwise the bank keeps resetting a losing worker, and the −£3 stop is rarely reached.
- **b. After a worker stop, a new worker in the same direction waits until the Pulse has left that direction once.** This stops the bot buying straight back into the same fall. A worker in the other direction still opens as soon as the Pulse confirms it, as normal.

## How to answer

Reply **"ok A"** or **"ok B"** in the chat, or change any point.
