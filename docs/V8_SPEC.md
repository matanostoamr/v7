# Gold Bidirectional Harvester v8.00: Spec

ফাইল: [`Gold_Bidirectional_Harvester_v8.00.mq5`](../Gold_Bidirectional_Harvester_v8.00.mq5)। v7 অপরিবর্তিত আছে। v8 আলাদা magic (80001 / 80002 / 80003) ব্যবহার করে, তাই দুটো একসাথে চললেও একে অপরের trade ধরবে না।

## 1. লক্ষ্য

XAUUSD-এ সারাদিন ছোট ছোট **net** লাভ harvest করা। ভালো entry দিয়ে trap হওয়ার সম্ভাবনা কমানো। কোনো trade আটকে গেলে hedge ও harvest-এর লাভ মিলিয়ে পুরো cycle net positive করে স্বাভাবিক harvesting-এ ফিরে আসা। কোনো একটা খারাপ cycle যেন account বা আগের অনেক harvest-এর লাভ শেষ না করে।

## 2. প্রতি pass-এ কাজের ক্রম (`Drive()`, প্রতি tick ও প্রতি 1 সেকেন্ডে)

1. **Snapshot:** quotes আর indicator (ATR M1/M5/M15, EMA9/21 M1, EMA50/200 M15) পড়া, তারপর book scan।
2. **Accounting:** যে position বন্ধ হয়েছে, তার আসল net broker history থেকে নেওয়া হয় (profit + swap + commission + fee)।
3. **Cycle evaluation:** hard stop, target, অথবা deficit repaid।
4. **Daily limit ও weekend flatten।**
5. **Hedge:** নতুন hedge খোলা অথবা খোলা hedge-এর SL trail করা।
6. **Base trade:** trap → harvest/runner → conditional scratch।
7. **Entry:** pullback limit order বসানো।

## 3. Harvest (মূল আয়)

- Base lot **0.01 fixed**। একটা BUY slot আর একটা SELL slot।
- **Net** = profit + swap + আসল entry commission − আনুমানিক exit commission (`InpCommissionPerLotSide × lot`)।
- Net ≥ **£0.50** হলে:
  - স্পষ্ট continuation **না** থাকলে → সাথে সাথে harvest close।
  - continuation থাকলে (M1 EMA9 > EMA21, EMA9 উঠছে, price EMA9-এর উপরে; SELL-এর জন্য উল্টো) → **runner**।
- **Runner:**
  - Floor হয় এ দুটোর বড়টা: `£0.50 × 0.80 = £0.40` অথবা `net − £0.30`।
  - এই floor-এ server-side SL বসে এবং **শুধু টাইট হয়**।
  - Continuation শেষ হলে → close (`RUNNER_BANK`)।
  - Net floor-এর নিচে নামলে → client-side close (`RUNNER_FLOOR`)।
  - প্রতিটি trade-এ £1-এর জন্য অপেক্ষা বাধ্যতামূলক নয়।

## 4. Entry quality

- Harvest-এর পর **pullback limit order** বসে: BUY limit = ask − offset, SELL limit = bid + offset।
  - Offset = max(20 pts, 0.30 × ATR M1, broker stops level)।
- Order প্রতিস্থাপন (cancel করে নতুন করে বসানো) হয় দুই ক্ষেত্রে:
  - 120 সেকেন্ডে fill না হলে।
  - Price offset + 0.5 × ATR M1-এর বেশি দূরে চলে গেলে।
- নতুন entry বন্ধ থাকে যখন:
  - spread > 35 pts;
  - shock (M1 bar ≥ 3 × ATR, 5 মিনিট বিরতি);
  - high-impact USD news ±15 মিনিট (শুধু live-এ);
  - server midnight-এর আগে 20 মিনিট ও পরে 70 মিনিট;
  - Friday 21:00 server time-এর পর;
  - hard stop-এর পর 60 মিনিটের cooldown;
  - daily halt চলাকালীন।
- শক্ত M15 trend থাকলে (|EMA50 − EMA200| ≥ 1 ATR এবং slope একই দিকে) **counter-trend side-এ নতুন entry বন্ধ**। Trend-এর দিকে harvesting চলতে থাকে।
- যে দিকের trade trap হয়ে cycle-এ আছে, সেই দিকে নতুন entry বন্ধ। বিপরীত দিকে harvesting চলে।
- প্রতিটি base trade-এ broker-side disaster SL (£20) থাকে, যাতে terminal বন্ধ থাকলেও loss সীমাহীন না হয়।

## 5. Cycle ledger (মূল নিয়ম)

```
Ledger NET = realised (বন্ধ হওয়া সব member-এর আসল net, history থেকে)
           + credit   (harvest-এর অংশ)
           + floating (খোলা member-দের net)
           − exit reserve (£0.10, শুধু member খোলা থাকলে)
```

**কোন position ledger-এ ঢোকে:**
- trap হওয়া trade (net ≤ −£8);
- scratch হওয়া trade;
- সব hedge;
- daily limit বা weekend-এ জোর করে বন্ধ হওয়া losing trade;
- harvest নিয়মের বাইরে loss-এ বন্ধ হওয়া base trade (যেমন disaster SL বা manual close)।

**কোনো realised loss লুকানো যায় না।** নতুন trade খুললে ledger reset হয় না।

**Harvest credit:**
- Trapped trade বা hedge খোলা থাকলে প্রতিটি harvest-এর **50%**।
- শুধু deficit থাকলে (কোনো member খোলা নেই) **100%**।

**Cycle কখন শেষ হয়:**

| অবস্থা | কী হয় |
|---|---|
| Member খোলা এবং NET ≥ +£1.00 | সব member বন্ধ, cycle সফল (`TARGET`) |
| Member নেই এবং NET ≥ 0 | Deficit শোধ হয়েছে (`DEFICIT_REPAID`) |
| NET ≤ −hard stop | সব member বন্ধ, loss গ্রহণ, 60 মিনিট cooldown (`HARD_STOP`) |

## 6. Hard stop (শুধু শেষ সুরক্ষা)

- Default £25। এটা input, final মান নয়।
- Cycle শুরুর মুহূর্তে freeze হয়ে GlobalVariable-এ সংরক্ষিত হয়। Cycle চলাকালীন input বাড়ালে বা restart করলেও **ঢিলা হয় না**। কমালে টাইট হয় (`min(পুরনো, নতুন)`)।
- `OnInit` যাচাই করে যে hard stop > trap trigger + hedge loss budget (8 + 8 < 25)। অর্থাৎ hard stop-এর আগে recovery-র জায়গা থাকতে হবে, নইলে EA চালু হয় না।

## 7. Early scratch (শর্তসাপেক্ষে)

Trade close হয় শুধু যখন **A, B, C তিনটাই** সত্য, এবং trade কমপক্ষে 180 সেকেন্ড পুরনো:

- **A, entry-র কারণ ভেঙেছে:** M5 close entry থেকে ≥ 1 × ATR(M5) বিপক্ষে, **এবং** M1 EMA9/21 momentum-ও বিপক্ষে।
- **B, trade রাখলে basket-এর ঝুঁকি বাড়ে:** শক্ত M15 trend বিপক্ষে, **অথবা** একটা recovery cycle ইতিমধ্যে চলছে (দ্বিতীয় trap-এর ঝুঁকি)।
- **C, loss-এর মাপ:** round-trip খরচের ≥ 2 গুণ (noise নয়) এবং ≤ £3 (এর বেশি হলে hedge-এর এলাকা)।

Scratch-এর realised loss ledger-এ যায়, তারপর harvest দিয়ে শোধ হয়।

## 8. Hedge (backup)

- Trap হলে hedge খোলে: 0.02 lot, trapped trade-এর বিপরীত দিকে, broker-side SL **£4** (commission সহ)।
- Hedge net ≥ £1.50 হলে SL break-even + খরচে সরে, তারপর £2.00 দূরত্বে trail করে। SL **শুধু টাইট** হয়।
- **Friction cap:** এক cycle-এ সর্বোচ্চ **3টা** hedge, অথবা মোট realised hedge loss **£8**। বাকি budget অনুযায়ী প্রতিটি নতুন hedge-এর SL ছোট হয়ে আসে।
- **Re-arm:** একটা hedge বন্ধ হলে, নতুন hedge খোলে শুধু তখন যখন:
  - কমপক্ষে 300 সেকেন্ড পার হয়েছে, এবং
  - price আগের hedge-এর close থেকে 0.5 × ATR(M15) trend-এর দিকে আরও এগিয়েছে।

  এতে range-এ বারবার hedge stop-out হওয়া বন্ধ হয়।
- Hedge budget শেষ হলে cycle চলে শুধু harvest credit আর trapped trade-এর recovery দিয়ে। Hard stop তখনও কার্যকর থাকে।

## 9. Capital shield

- **Daily limit £50**, floating সহ, শুধু এই EA-র magic-গুলোর হিসাব। সীমা পেরোলে সব flat হয় এবং পরের server day পর্যন্ত বিরতি থাকে। Losing trade-গুলো ledger-এ যায়, তাই পরের দিন harvest সেই deficit শোধ করে।
- **Weekend:** Friday 23:15 server time-এ সব flat (gap থেকে সুরক্ষা)। নিয়ম daily limit-এর মতোই।
- **Margin:** নতুন risk নেওয়ার আগে projected margin level ≥ 300% হতে হবে।

## 10. Restart ও নিরাপত্তা

- সব state GlobalVariable-এ থাকে: `GBH8_<login>_<symbol>_<magic>_*`। এর মধ্যে আছে cycle, member list, scratch বা close request, known base ticket, daily halt, cooldown, lifetime stats।
- Realised সংখ্যা সবসময় broker history থেকে নেওয়া হয়, তাই restart-এ কোনো হিসাব হারায় না।
- Cycle-এর বাইরে কোনো hedge পাওয়া গেলে সেটা adopt করে ledger-এ নেওয়া হয়। অতিরিক্ত base position পাওয়া গেলে ledger-এ নিয়ে বন্ধ করা হয়।
- প্রতিটি request-এর retcode check হয়। ব্যর্থ হলে 3 সেকেন্ড backoff, SL modify ব্যর্থ হলে 5 সেকেন্ড।
- Strategy Tester-এ প্রতিটি run শুরুতে তার নিজের GlobalVariable মুছে ফেলে।
- প্রতিটি cycle শেষে `Common\Files\GBH8_<login>_<symbol>_cycles.csv`-এ এক লাইন লেখা হয়।

## 11. Pass/fail নিয়ম (test-এর আগেই ঠিক করা)

Pepperstone, **"Every tick based on real ticks"**, £1,000 deposit, সব default।

| Period | শর্ত |
|---|---|
| সাম্প্রতিক 3 মাস | সব খরচ বাদে net > 0 |
| তার আগের 3 মাস | net > 0 |
| আরও আগের 1 মাস (ছোঁয়া হয়নি) | net > 0 |

এছাড়া পুরো সময়ে:
- মোট harvest income ÷ মোট recovery loss (`HARD_STOP` cycle + hedge loss) **≥ 1.2**;
- সবচেয়ে খারাপ cycle ≤ hard stop + slippage;
- max drawdown ≤ 10%।

যদি কোনো `HARD_STOP` না ঘটে, তাহলে ফলাফলকে **"অপ্রমাণিত"** ধরা হবে, "সফল" নয়। Result দেখার পর setting বদলালে নতুন untouched period-এ আবার test করতে হবে।

## 12. জানা সীমাবদ্ধতা

- Sandbox-এ MQL5 compiler নেই। **প্রথমে MetaEditor-এ compile করুন।** Error এলে লাইন নম্বর সহ পাঠান।
- Server time-ভিত্তিক window-গুলো (rollover, Friday) Pepperstone-এর server time (GMT+2/+3) ধরে বসানো। Broker বদলালে মিলিয়ে নিন।
- Exit commission একটা আনুমানিক input (`InpCommissionPerLotSide`, per lot per side)। Demo-তে প্রথম কয়েকটা deal দেখে মিলিয়ে নিন।
- Hedge margin হিসাব রক্ষণশীল (hedged margin-এর ছাড় ধরা হয়নি)।
