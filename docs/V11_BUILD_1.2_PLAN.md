# v11 build 1.2: plan (waiting for your OK)

> Nothing is built or merged yet. The code on this branch is still **build 1.1**.
> Reply **"ok"** in the chat, or change any point. Then I build 1.2 on this branch and show the full diff in PR #3. I will not merge.

## What stays the same (as you asked)

- Harvest at **£0.50 net for all trades** (anchors and worker). The backup TP stays at £0.80.
- Worker flip stays **OFF**.
- **No** fixed 30-minute pause.

## 1. Worker stop at −£3 net

- The worker (the 3rd trade) closes at **−£3 net**, after commission.
- The −£3 is also placed on the server as the worker's SL. If the broker rejects it, the bot still closes the worker itself at −£3.
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

## 3. If an anchor hits its £25 disaster SL

**What build 1.1 does today:**

- The server closes the anchor at about −£25, or more with slippage.
- The bank pays as much of that loss as it holds.
- The bot reopens the missing anchor at once. The other anchor keeps its own harvest, backup TP and £25 SL.

**A gap I found:** that reopen goes through the normal entry gate. So the missing anchor is **not** reopened:

- outside 01:30–23:00 (for example overnight),
- during a 2-minute shock pause,
- during a news window,
- when the spread is above 30 points.

Until it is reopened, the other anchor (and the worker, if open) has no hedge.

**Build 1.2 fix:**

- Reopening a missing anchor reduces risk. So it ignores trading hours, shock and news pauses, and the spread limits.
- It is still blocked by:
  - a safety stop (these close everything anyway),
  - Algo Trading switched off,
  - the broker's market being closed,
  - not enough margin,
  - the short back-off after failed requests.
- If the worker is on the same side as the lost anchor, it becomes the new anchor at once. Its SL moves from −£3 to the £25 disaster level, and the third slot is free for a new worker.

## 4. Basket stop on the cycle P&L at −£40

- **Cycle:** starts when the basket opens from empty and ends when the basket is empty again.
- **Cycle P&L:** everything v11 closed in this cycle (after commission and swap), plus the open trades now (after round-trip commission).
- At **−£40**, the bot closes everything, then waits out the existing 60-minute cooldown.
- **Note:** build 1.1 uses £25, counted on open trades only. I could not find −£40 in the spec or the code, but I will use −£40 as you asked.
- **Note:** profit already closed in a cycle gives the open trades more room. For example, after +£20 closed, the stop fires when the open trades reach −£60. The daily limit (£50) and the kill switch still protect the account.

## 5. Pulse bug fix

**The bug:** when the Pulse is UP, a score between −40 and −15 counts for nothing and also resets the count. So in a sharp fall the Pulse often cannot even turn NEUTRAL. The same happens for DOWN, the other way round.

**How build 1.2 counts it:** when the Pulse is UP, every bar that scores below +15 counts as "leaving UP". When 2 such bars come in a row:

- if both scored −40 or lower, the Pulse turns DOWN;
- otherwise it turns NEUTRAL.

Changes from NEUTRAL to UP or DOWN stay exactly as they are now.

Proposed new code (build 1.1 version: `ApplyPulse` in `Gold_Triad_Harvester_v11.00.mq5`):

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

## 6. Two rules I need your OK on (both will be inputs)

- **a. Bank re-anchoring is for anchors only.** Otherwise the bank keeps resetting a losing worker, and the −£3 stop is rarely reached.
- **b. After a worker stop, a new worker in the same direction waits until the Pulse has left that direction once.** This stops the bot buying straight back into the same fall. A worker in the other direction still opens as soon as the Pulse confirms it, as normal.

## How to answer

Reply **"ok"** in the chat, or change any point. For example: "2: use 4 stops" or "6b: no".
