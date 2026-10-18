# HANDOVER: read this first (state on 2026-10-18)

This file lets a new chat continue the work exactly where the old one stopped. It covers the user, the rules, the repo, the current bot (v14 build 1.1.1), all test evidence, the decisions and what happens next.

- **Branch:** `feat/v14-hedge-harvester` (PR #6). `main` has only v7.
- **Detail lives in:** [`docs/V14_PLAN.md`](V14_PLAN.md) rev 3 (the design, maths, inputs and tests) and the PR #6 comments. This file is the summary; when they disagree, the code wins, then the plan.

---

## 1. The user and how to work with him
- **Who:** GitHub user `matanostoamr`, public repo `matanostoamr/v7`. He builds MQL5 (MetaTrader 5) bots for gold, XAUUSD.
- **How he tests:** PepperstoneUK-Demo, GBP account, £1,000 deposit, 1:30 leverage, M5, "Every tick based on real ticks". UK gold margin is 1:20 (5%).
- **He works only in the GitHub web UI** and cannot see the sandbox. Always give:
  - full clickable links: the blob URL on the branch, the raw URL for copying, the PR, the comment;
  - the branch name;
  - a warning that `main` does **not** have the change.
- **Language:** he writes simple English mixed with Bengali. **Reply in short, simple English plus exactly one Bengali line.** Lead with the result and use small tables.
- **Speed:** he gets impatient ("why taking too long", "i cant see anything"). Be fast and direct; no long preambles.
- **His standing rules (his words):**
  - "make the bot as i want. and the best way possible"
  - "dont judge the logic from internet": judge only from his own test reports and maths.
  - "if failed its fine"
  - "keep it seperate": each version gets its own branch, PR and files.
  - "Please don't add any extra features beyond the agreed design."
- **Workflow rules:**
  1. **No new feature, and no change to a default, without his explicit OK.** Propose first, build after "OK".
  2. **Merge only when he writes "merge".** All PRs are open and unmerged today.
  3. **Each bot version gets its own branch and PR.** Builds of one version (1.0, 1.1, …) go on that version's branch.
  4. **He compiles in MetaEditor and runs all MT5 backtests himself** ("No need to run backtests on your end"). The agent writes code, checks it offline, pushes, and analyses the reports he sends.
- **What he sends:**
  - an attached Strategy Tester HTML report (UTF-16; see section 8 to extract it);
  - pasted report text;
  - an optimizer result as MT5 XML (one row per pass with Profit, Profit Factor, Equity DD %, Trades and the inputs).

## 2. Repo map (all PRs open, none merged)
| PR | Branch | Head | Bot file | Outcome |
|---|---|---|---|---|
| — | `main` | `edb35d5` | `Gold_Bidirectional_Harvester_v7.00.mq5` | his original v7 |
| #1 | `feat/v8-harvester` | `ec28e6e` | `Gold_Bidirectional_Harvester_v8.00.mq5`, `docs/V8_SPEC.md` | first rebuild after the v7 review |
| #2 | `feat/v10-regime-scalper` | `dfc7fd0` | `Gold_Regime_Scalper_v10.00.mq5`, `docs/V10_SPEC.md` | "Round 2 of 3 - trading build" |
| #3 | `feat/v11-triad-harvester` | `0e5f8b2` | `Gold_Triad_Harvester_v11.00.mq5` + 3 docs | 3-trade harvester, builds 1.1/1.2. Reports 4411, t1, t2: about −£192, −£192, −£131 |
| #4 | `feat/v12-two-mode-harvester` | `7104b93` | `Gold_TwoMode_Harvester_v12.00.mq5`, `docs/V12_PLAN.md` | Harvest + Recovery modes. Build 1.0 −£205.94, build 1.1 balance 796. Frozen |
| #5 | `feat/v13-market-harvester` | `289e5cc` | `Gold_Market_Harvester_v13.00.mq5`, `docs/V13_PLAN.md` | Market Harvester. **Stopped** (see below) |
| #6 | `feat/v14-hedge-harvester` | this branch | `Gold_Hedge_Harvester_v14.00.mq5`, `docs/V14_PLAN.md` | **current work** |

**Why v13 stopped (PR #5).** The design:
- trade 1 at market in the market direction;
- up to 4 trades, each added by a stop order $3 beyond the furthest trade;
- harvest +£4 net, close all on a $`InpTurn` turn, hard stop −£30.

Its results:
- Oct 1–7 reports 1313 and 13132: +£37.78 and +£116.81.
- September with InpTurn 8: **−£849.60**. Margin ran out and about 45,000 orders were refused.
- Optimizers (InpTurn 5–40 on September, the October week and August): the best InpTurn was different every month.
- InpTurn 20: August −£313.96, September +£169.23, October week −£5.47, a total of −£150.20.
- He chose option "2": stop v13 and design v14 with more trades (comment 6204354528).

## 3. v14 Hedge Harvester: the user's idea (his words, shortened)
- "Concept: Indicator-Guided Harvester with Recovery Hedging … places an opposite hedge trade with a doubled lot size (e.g., if initial trade is 0.01 BUY, open 0.02 SELL) … Strictly limited to 1 to 3 trades max open … A hard basket stop loss as the ultimate safety net … use your 10000% ai brain to polish my idea … Let's build a clean spec on a new feat/v14-hedge-harvester branch."
- **Build approval:**
  - "OK, go ahead and code v14."
  - Inputs exposed (`InpHarvestNet`, `InpHedgeDistance`, `InpBasketTarget`).
  - "Don't make the entry filters so strict that the bot sits idle for days."
  - "No need to run backtests on your end."
- **Build 1.1 request (2026-10-18):**
  - "News Filter ONLY (No Friday / General Quiet Time): I want the bot to trade maximum hours. Please do NOT add general quiet times or disable Friday nights. Only add a dedicated US News Window Filter (… 15:00 and 15:45 on weekdays …). Make this a toggle input (InpNewsFilter = true/false, with start/end time inputs)."
  - "Increase Trade Frequency … If switching to Market Entry (InpEntryMode=2) or adjusting the entry EMA/ADX gives more active intraday trades without adding excessive risk, let's enable that."

## 4. v14 build 1.2: what the bot does now (1.1 rules, new entry defaults since 1.2)
**File:** `Gold_Hedge_Harvester_v14.00.mq5`, magic 140001. It needs a hedging account. The code is ASCII-only.

**Direction** is read on each new M5 bar, from closed bars:
- **Trend:** M15 EMA 20 above EMA 50 → buys only; below → sells only.
- **Movement:** M15 ADX(14) must be at least `InpAdxMin` 10 (0 = off; was 15 before build 1.2).
- **RSI:** no buy while M5 RSI(14) ≥ 70, no sell while it is ≤ 30.

**Trade 1** (0.01). **One basket at a time.**
- **Mode 1 (default), limit:** while the last M5 close is on the trend side of the M5 EMA 20, a BUY/SELL LIMIT waits at that EMA. It moves to the new EMA value on each new bar, and is deleted when the conditions stop.
- **Mode 2, market:** an M5 close beyond the EMA against the trend (the pullback), then the first close back with RSI on the trend side of 50 → trade 1 at market.
- After a basket ends, the next trade 1 needs a new bar's signal.

**Exits:**
1. **Harvest:** trade 1 alone closes at **+£4.00 net** (`V14 HV`).
2. **Hedge:** gold **$8** against trade 1 → **0.02** the other way at market (`V14 H`).
3. **Trade 3** (only if `InpMaxTrades` 3): after the hedge, gold back at trade 1's price → **0.03** in trade 1's direction (`V14 3`). It is 0.03 and not 0.04: with 0.04 the hard stop would sit right at the hedge price.
4. **Basket target:** after the hedge, all trades close together at **+£1.00 net** (`V14 BT`).
5. **Hard stop:** all trades close together at **−£30.00 net** (`V14 HS`).

**Safety features:**
- **P1 margin:** trade 1 only if free margin ≥ 1.5 × the whole basket's margin, by the broker's hedge rule. If the hedge or trade 3 fails 3 times, all trades close (`V14 HF`).
- **P2 spread:** no new trade 1 while the spread is above $1.00. Mode 1 deletes the limit until the next bar; mode 2 waits.
- **P3 news (new in 1.1):** with `InpNewsFilter` true, no new trade 1 from `InpNewsStart` "15:00" to `InpNewsEnd` "15:45" server time, Monday to Friday. A waiting limit is deleted, and open baskets carry on as normal. `InpNewsFilter` false = build 1.0 exactly.
  - **No Friday rule and no other quiet time:** the user refused them.
  - **Known limit:** the tester fills a pending order before the bot sees the tick, so the first tick of the window can still fill a waiting limit. That basket is normal.
- **Restart:** the bot carries on with its own open trades if they form a basket; otherwise it closes them (`V14 RS`).

**Net** = profit + swap + both commissions. In the code: `TradeNet = FloorCent(profit) + swap + 2 × entry commission`, and the basket = the sum of its open trades.

**Every input with its default** (plan section 8):

| Input | Default | | Input | Default |
|---|---|---|---|---|
| InpLots | 0.01 | | InpEmaFast / InpEmaSlow | 20 / 50 |
| InpMaxTrades | 2 | | InpAdxPeriod / InpAdxMin | 14 / 10.0 (1.2) |
| InpHarvestNet | 4.00 | | InpEntryTF | M5 |
| InpHedgeDistance | 8.00 | | InpPullEma | 10 (1.2) |
| InpHedgeMult / InpTrade3Mult | 2.0 / 3.0 | | InpRsiPeriod / InpRsiMax | 14 / 70 (100 = off) |
| InpBasketTarget | 1.00 | | InpMaxSpread | 1.00 (0 = off) |
| InpHardStop | 30.00 | | InpNewsFilter | true |
| InpEntryMode | 2 (market; 1 = limit) (1.2) | | InpNewsStart / InpNewsEnd | "15:00" / "15:45" |
| InpTrendTF | M15 | | InpMagic | 140001 |

**Code map:**
- **Order of checks in `OnTick`:**
  1. `UpdateNewsWindow`
  2. `Sync` / `SyncLimit`
  3. `ServiceClosing` (while closing all trades)
  4. `CheckExits` (hard stop, then `Harvest` or the basket target)
  5. `Hedge`
  6. `Trade3`
  7. `ReadSignal` on a new bar
  8. `ManageEntry`
- **Other functions:** `BeginCloseAll`, `FinishBasket` (writes the `BASKET #n …` journal line), `MarginOk` / `BasketMargin` / `HedgedShare` (P1), `SpreadOk` (P2), `MinutesOf` / `NewsWindowNow` (P3), `Adopt` (restart).
- **Journal:** a settings line at the start, a margin line on the first tick, one line per news window, the `BASKET #n` lines, and a `SUMMARY` line at the end.
- **Build convention (since v12):**
  - keep the file name and `#property version "14.00"`;
  - bump `V14_BUILD` and the header lines;
  - bump the plan rev and add a "Build x notes" section to `docs/V14_PLAN.md`.

## 5. Test evidence: report "1414" (build 1.0, all defaults, Sep 1 → Oct 15 2026)
**Summary:**
- **Result:** net **+£100.37**, profit factor 1.04, Sharpe 1.91, recovery factor 0.39.
- **Drawdown:** biggest equity drop **£258.37 (24.93%)**. The balance drop of £273.39 is inflated, because one leg of a basket closes before the other.
- **Activity:**
  - margin level never below 240.58%;
  - 397 positions, 925 orders (410 limit orders: 279 filled, 131 canceled);
  - **279 baskets** in 32 trading days, 8.7 per day.

**Every rule was followed in all 279 baskets.** There are no bugs, and the checks (`tools/reports/analyse_v14.py`) found 0 problems:
- harvests ≥ +£4.00 (the lowest was exactly 4.00);
- hedges 0.02 at ≥ $8 (lowest 8.00, average 8.27, highest 21.35 at the Monday-open gap on Sep 28);
- basket targets ≥ +£1.00, with both trades closed in the same second;
- hard stops averaged −£30.50, worst −£33.89 (Oct 14 15:30:02 news);
- one basket at a time, never more than 2 trades;
- the new-bar rule held;
- no HF or RS closes;
- 2 limit orders were deleted mid-bar, which only P2 does.

| Outcome | Baskets | Total | Average |
|---|---|---|---|
| HV harvest | 160 | +681.64 | +4.26 |
| BT basket target | 95 | +124.76 | +1.31 |
| HS hard stop | 23 | **−701.58** | −30.50 |
| Still open at the end of the test | 1 | −4.45 | |

**What it means:**
- **Trade 1 harvested alone in 57.6% of closed baskets.** The plan's coin-flip figure is 57%, and the plan said 60–64% is needed. So the entry filter gave almost no edge.
- **The profit came from the hedge stage:**
  - hard stops were 8.3% of baskets (coin flip: 11%);
  - 80.5% of hedged baskets reached +£1 (break-even share 77.7%).
- **The edge is thin:** +£0.38 per closed basket. One hard stop instead of a basket target costs £31.82, so 3–4 more hard stops would wipe out the profit.
- **By time:**
  - September −£68.11; October 1–14 +£172.93 for closed baskets, or +£168.48 with the open trade;
  - worst week Sep 7–11 −£179 (9 hard stops), best week Oct 5–9 +£113.14;
  - worst day Sep 3 −£88.35;
  - 14 of the 32 trading days lost money.
- **News:**
  - 8 baskets closed in the 15:30 minute: 4 hard stops, net −£81.69.
  - The two biggest wins were also news jumps: HV +£22.67 (Oct 2) and BT +£15.18 (Sep 4).
  - 11 baskets started 15:00–15:45: net **−£97.13** (4 hard stops). This is the case for P3.
  - 3 of the 4 hard stops right at 15:30 came from baskets opened hours earlier (#22, #193, #273), which P3 doesn't touch.
- **Weekends:** 6 baskets were held over a weekend, net −£51.71 (2 hard stops). He doesn't want a Friday rule, so don't propose one again.
- **Margin:** the 2-trade basket used about £328 (the bigger leg, worked out from the 240.58% margin level). So 3 trades need about £656, and P1 then needs about £984 free: **use £2,000 for any max-3 test.**
- **Comparison:** v13 lost −£849.60 in September with its defaults.
- **Against the plan's pass rule** (profit in every test month and a drop under £250), the 1.0 defaults fail: September lost money and the drop was £258.

**Frequency (what keeps the number of trades down), from `tools/reports/frequency_v14.py`:**

| Market time, 736 h (Mon–Fri 01:00–24:00) | Share |
|---|---|
| Inside a basket | **62.8%** (hedged 52.4%, trade 1 alone 10.4%) |
| Limit order waiting at the M5 EMA | 19.4% |
| No signal (ADX, EMA side, RSI) | 17.7% |

- **One basket at a time is the main limit.** Even with zero waiting, the most possible was about 444 baskets (+59%). Removing all limit waiting adds at most +24%, and removing all no-signal time at most +22%.
- **The next limit was placed:**
  - after a harvest: a median of 3.2 minutes;
  - after a basket target: a median of 43 minutes (gold is then on the other side of the EMA);
  - after a hard stop: a median of 7 minutes.
- **Limit placed to fill:** a median of 13 minutes.

**The advice already given to the user (PR #6 comment 6252596106):**
- **Mode 2:** probably *fewer* trades. It needs a close through the EMA and then a close back; mode 1 fills on any touch.
- **Lower ADX:** a small gain, and the extra baskets come in flat markets, where the hedge loses.
- **`InpPullEma` 20 → 10:** probably the most extra trades, with the same risk per basket.
- **A second basket while one is hedged:** the biggest gain, but **not recommended**. It breaks his 1–3 trades rule and doubles the worst case.
- **No entry default was changed in 1.1**, so that Test A measures the news filter alone.

## 6. Where we are: waiting for the user
**Build 1.1.1 (optimizer fix, plan section 14):** in optimization MT5 passed `InpNewsStart`/`InpNewsEnd` with quotes (`"15:00"`), so all 30 Test B passes stopped in `OnInit`. The parser now ignores quotes and spaces around the time, and a refused time is logged with its character codes. Trading is unchanged.

**Test A (news filter), done as two runs with build 1.1 (PR #6 comments 6252936431 and 6252965289):**
- 1414-21, Sep 1–30: +£45.57, equity drop £201.71, 187 baskets, 16 hard stops (build 1.0 September: −£68.11);
- 1414-2, Oct 1–17: +£212.80, drop £40.61, 99 baskets, 3 hard stops;
- both months pass the pass rule; 0 rule problems; 0 baskets started 15:00–15:45. The edge is still thin (+£0.24 per basket in September).

**Test B (frequency), optimizer on August:**
- Period 2026.08.01 → 2026.09.01, build 1.1.1 defaults, "Slow complete algorithm".
- `InpEntryMode` 1 → 2, `InpPullEma` 10 → 20 step 5, `InpAdxMin` 0 → 20 step 5. That's 30 passes; he pastes the XML.
- **Result (PR #6 comment 6253298119):** 27 of 30 passes lost. Defaults (mode 1, PullEma 20, ADX 15) −£152.37, drop 21.84%. Only mode 2 + PullEma 10 made money: +£8.17 with ADX 0/5/10 (all three the same), 222 trades. **The pick: mode 2, PullEma 10, ADX 10.**

**Test C (the pick, build 1.1.1, one run per month):**

| Run | Period | Net | Equity drop | Baskets | HS | Same month, defaults |
|---|---|---|---|---|---|---|
| 1414-41 | Aug 1–31 | +£8.17 | £101.67 | 160 | 15 | −£152.37 |
| 1414-42 | Sep 1–30 | +£24.26 | £157.69 | 167 | 15 | +£45.57 (drop £201.71) |
| 1414-43 | Oct 1–18 | +£145.72 | £55.99 | 86 | 4 | +£212.80 (Oct 1–17) |

- 0 rule problems in all three; every trade 1 at market; 0 starts in 15:00–15:45.
- Passes the pass rule in Aug, Sep, Oct. Sum +£178.15 vs defaults +£106.00. Edge is thin in Aug/Sep (PF 1.01 / 1.02).
- July was not run: on 2026-10-18 he decided 3 months is enough and gave the OK.

**Build 1.2 (done, his OK):** defaults now `InpEntryMode` 2, `InpPullEma` 10, `InpAdxMin` 10, news filter on (plan section 15). Next: demo forward test, and talk about edge ideas (none approved yet).

**Build 1.2:** the new defaults from B and C, **only after his OK.** He said "let's enable that" if more trades come without excessive risk, but he was told "With your OK it becomes the new default in build 1.2". So show the pick and ask for OK.

**Trade 3 test, 1414-5 (build 1.2, `InpMaxTrades` 3, £1,300, Aug 1 → Oct 17): FAILED.**

| | Test C (MaxTrades 2) | 1414-5 (MaxTrades 3) |
|---|---|---|
| Net | +£178.15 | −£205.95 |
| Equity drop | £157.69 (max month) | £432.33 (31.3%) |
| Baskets / HS | 412 / 34 | 509 / 56 |

- Trade 3 opened in 109 baskets: 53 BT (+£85.29), 56 HS (−£1,703.19). That's a 49% win rate, but it needs about 95%.
- Why: Trade 3 moves the hard stop to about $12 past trade 1's price (it was about $24). The target is about $9 away. So it's a coin flip that risks £30 to win £1.6.
- The earlier "saves ≈ £1,065" was a best case and wrong: it ignored the stop moving closer. `InpMaxTrades` stays 2.
- The cut-hedge idea has the same problem: about half the baskets that come back to trade 1's price still end BT. A rough estimate is about break-even, not +£751. Don't build it without his OK.

**2026-10-18, his decision: build 1.2 is the FINAL version.** He wants no more recovery rules or changes for now. He is starting a demo forward test on a VPS with the build 1.2 defaults (mode 2, PullEma 10, ADX 10, MaxTrades 2, news filter on), and he will send **weekly history reports**. For each one: extract it, run `analyse_v14.py`, check the rules, compare with Test C (about +£0.43 per basket, HS about 8% of baskets), post a PR #6 comment, and reply. Don't propose code changes unless he asks. PR #6 stays open until he writes "merge".

**Later (not approved):** `InpHedgeDistance` 6 → 14 step 2, on £2,000 (Trade 3 dropped).

**When a report arrives:**
1. Extract it.
2. Run `analyse_v14.py` and `frequency_v14.py`.
3. Check the rules and compare with 1414.
4. Post a PR #6 comment.
5. Reply: the result, the rules check, an honest view of the edge, the next step, the links, the `main` warning and one Bengali line.

## 7. Ideas NOT approved: don't build without his OK
- **P4 daily loss limit** (after −£60 closed in a day, no new basket). In 1414 it would only have saved £23.79.
- **A Friday or weekend rule, or general quiet times.** **Refused by the user.**
- **A second basket while one is hedged.** Not recommended.
- **From plan section 11 ("later"):**
  - ATR-based distances;
  - broker-side safety stops (needed before a live account, because the hard stop only works while MT5 runs);
  - more news times (for example 21:00 for US rate decisions).
- **Rejected earlier:** my first v14 draft (clean-move check, dip entry, $8 stop loss, daily stop) was replaced by his hedge idea. A 42-pass v13 optimizer was dropped when v13 stopped.

## 8. How the agent works here (commands and gotchas)
**Git and GitHub:**
- **Commits:** commit to `feat/v14-hedge-harvester` (never `main`). Message style: `feat(v14): build 1.x - …`. Push with `git push`.
- **Use only `gh api` (REST).** `gh pr` and `gh issue` subcommands fail in this sandbox.
  - Update the PR: `gh api -X PATCH repos/matanostoamr/v7/pulls/6 -f title="…" -F body=@body.md`
  - Comment: `gh api repos/matanostoamr/v7/issues/6/comments -F body=@comment.md --jq .html_url`
  - Then check that the posted body equals the file.

**Offline check of the bot** (not MetaEditor, so say so). From `tools/mqlcheck`:
```
python3 mql2cpp.py ../../Gold_Hedge_Harvester_v14.00.mq5 v14_check.cpp
g++ -std=c++17 -fsyntax-only -Wall -Wextra -Wno-unused-parameter v14_check.cpp
```
- Build 1.1 gave 0 errors and 0 warnings.
- New MQL5 functions need a declaration in `mql5_shim.h`.
- The source must stay ASCII.

**Reports** (`tools/reports`, see `tools/README.md`):
1. Extract a chat attachment: `python3 extract_report.py --session /projects/.kiro/sessions/<id>/<id>/messages.jsonl report.html --name <file name>`. MT5 reports are UTF-16, and the attachment is base64 in `payload.documents[i].data`.
2. Then run `python3 analyse_v14.py report.html` and `python3 frequency_v14.py report.html`. Both read the inputs and the period from the report.

**Sandbox:**
- `/tmp` doesn't keep files between commands; work in `/projects/sandbox/...`.
- The user can't see sandbox files. Push them and give links.

**Status:** after each reply, set the session status (waiting on the user).

## 9. Reply template
1. **One line:** the result or what was done.
2. **Short bullets or a small table:** numbers, the rules check, an honest view (thin edge, risks).
3. **Next step for him:** the exact tester settings (dates, deposit, inputs or optimizer ranges).
4. **One Bengali line.**
5. **Links:**
   - bot file (blob);
   - raw file;
   - plan;
   - PR #6 and the new comment;
   - ⚠️ "`main` still doesn't have v14".

**Key links:**
- PR #6: https://github.com/matanostoamr/v7/pull/6
- Bot file: https://github.com/matanostoamr/v7/blob/feat/v14-hedge-harvester/Gold_Hedge_Harvester_v14.00.mq5
- Raw file: https://raw.githubusercontent.com/matanostoamr/v7/feat/v14-hedge-harvester/Gold_Hedge_Harvester_v14.00.mq5
- Plan: https://github.com/matanostoamr/v7/blob/feat/v14-hedge-harvester/docs/V14_PLAN.md
- Report 1414 analysis: https://github.com/matanostoamr/v7/pull/6#issuecomment-6251717434
- Build 1.1 notes: https://github.com/matanostoamr/v7/pull/6#issuecomment-6252596106
