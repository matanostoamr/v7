# Gold Triad Harvester v11 — ডিজাইন স্পেসিফিকেশন

**অবস্থা:** কোড লেখা হয়েছে (`Gold_Triad_Harvester_v11.00.mq5`, build 1.2)। Build 1.2-এ যোগ হয়েছে: trade role (BUY anchor, SELL anchor, worker), worker-এর −£3 stop, পরপর stop হলে worker pause (paper worker), anchor disaster SL লাগলে পুরো basket বন্ধ, anchor guard (option B), cycle P&L-এ −£40 basket stop, এবং Pulse fix। বিস্তারিত: [V11_BUILD_1.2_PLAN.md](V11_BUILD_1.2_PLAN.md)। MetaEditor compile (user, build 1.0): 0 error, 1 warning — build 1.1-এ ঠিক করা হয়েছে। Runtime test (Strategy Tester ও demo) user করবেন।

| | |
|---|---|
| EA file | `Gold_Triad_Harvester_v11.00.mq5` |
| Branch | `feat/v11-triad-harvester` |
| Symbol / chart | XAUUSD, M1 |
| Account | Pepperstone, hedging, GBP |
| Lot | প্রতিটি trade 0.01 |
| Magic number | 110001 (সব v11 trade) |
| Log prefix | `[V11]` |
| অন্য bot-এর সাথে সম্পর্ক | সম্পূর্ণ নতুন bot। v7, v8, v10-এর সাথে কোনো file, magic বা setting ভাগাভাগি নেই। |

## 1. মূল ধারণা

Basket-এ সর্বোচ্চ ৩টি trade থাকে। কোনো slot-এর স্থায়ী direction নেই; bot পুরো basket-এর বিন্যাস নিয়ন্ত্রণ করে। যে trade net £0.50 profit-এ পৌঁছায়, সেটি harvest হয়, আর তার জায়গা সাথে সাথে নতুন trade দিয়ে ভরে। লক্ষ্য: harvesting যেন থেমে না থাকে, আর দুটি trade-এর মাঝের gap যতটা সম্ভব কম হয়।

## 2. Basket বিন্যাস

| Market (Pulse, §3) | লক্ষ্য বিন্যাস |
|---|---|
| UP | 2 BUY + 1 SELL |
| DOWN | 1 BUY + 2 SELL |
| NEUTRAL | 1 BUY + 1 SELL; তৃতীয় slot অপেক্ষা করে |

স্থায়ী নিয়ম:
1. তিনটি trade কখনো একই দিকে নয়। Basket চালু থাকলে সবসময় অন্তত ১টি BUY ও ১টি SELL থাকে।
2. Market direction বদলেছে বলে চলমান trade জোর করে বন্ধ হয় না (worker flip বন্ধ)।
3. বিন্যাস বদলায় শুধু নতুন entry দিয়ে: harvest-এর পর refill, অথবা re-anchor (§6)।

**খালি জায়গার direction:** বাকি positions আর বর্তমান Pulse দেখে, উপর থেকে নিচের ক্রমে প্রথম যে সারি মেলে:

| বাকি positions | Pulse | নতুন trade |
|---|---|---|
| কোনো BUY নেই | যেকোনো | BUY |
| কোনো SELL নেই | যেকোনো | SELL |
| 1 BUY + 1 SELL | UP | BUY → 2 BUY + 1 SELL |
| 1 BUY + 1 SELL | DOWN | SELL → 1 BUY + 2 SELL |
| 1 BUY + 1 SELL | NEUTRAL | কিছু না; তৃতীয় slot অপেক্ষা করে |

Basket পুরো খালি থাকলে (শুরুতে, বা basket stop-এর পর) BUY আর SELL একই মুহূর্তে খোলে, তারপর তৃতীয়টি উপরের নিয়মে।

## 3. Pulse: market direction

- প্রতিটি closed M1 candle-এ একটি score হিসাব হয়, −100 থেকে +100। উপাদান:
  - M5 EMA50-এর slope (বড় trend)
  - M1 EMA9 বনাম EMA21
  - শেষ ৩টি M1 candle-এর structure: higher high/higher low, নাকি lower high/lower low
  - M1 Efficiency Ratio (move কতটা এক দিকে টানা)
- শুধু closed candle থেকে হিসাব, তাই কোনো repaint নেই।
- Direction বদলের নিয়ম (confirmation + hysteresis):

| থেকে | যেখানে | শর্ত |
|---|---|---|
| NEUTRAL | UP | score ≥ +40, পরপর ২টি candle |
| NEUTRAL | DOWN | score ≤ −40, পরপর ২টি candle |
| UP | DOWN (confirmed reversal) | score ≤ −40, পরপর ২টি candle |
| DOWN | UP (confirmed reversal) | score ≥ +40, পরপর ২টি candle |
| UP বা DOWN | NEUTRAL | trend মরে গেছে: UP-এ score +15-এর নিচে (DOWN-এ −15-এর ওপরে), পরপর ২টি candle, কিন্তু উল্টো দিকের জন্য যথেষ্ট শক্ত নয় (build 1.2 fix) |

## 4. Harvest

- **Harvest line:** trade-এর net profit = profit + swap − round-trip commission ≥ £0.50।
- Harvest bot নিজে করে, swap পদ্ধতিতে (§5)।
- **Backup TP:** প্রতিটি trade-এ broker-এর server-এ একটি TP থাকে net ≈ £0.80-এ। Terminal ধীর হলে বা offline থাকলেও profit নেওয়া হয়।
- প্রতিটি harvest-এর net profit Harvest Bank-এ জমা হয় (§6)।

## 5. Swap ও gap নিয়ন্ত্রণ

1. কোনো trade harvest line ছুঁলে bot একই মুহূর্তে দুটি order পাঠায়: ওই trade-এর close, আর তার জায়গার নতুন trade। নতুন trade-এর direction §2-এর নিয়মে, বাকি দুটি trade দেখে। Order দুটি MT5-এর async sending-এ যায়, একটি আরেকটির উত্তরের জন্য অপেক্ষা করে না, তাই slot প্রায় এক মুহূর্তও খালি থাকে না।
2. একসাথে একটিই swap চলে। পরের harvest শুরু হয় আগের swap-এর close ও refill দুটোই confirm হলে। একই tick-এ দুটি trade line ছুঁলে বেশি profit-এরটি আগে যায়। অন্যটি পরের মুহূর্তে তখনও line-এর উপরে থাকলে harvest হয়; না থাকলে খোলা থেকে কাজ চালিয়ে যায়।
3. Refill-এর অনুমতি না থাকলে (spread spike, news, rollover, শুক্রবার, margin): harvest তবুও হয়, কারণ profit নেওয়া নিরাপদ। ওই slot "অপেক্ষমাণ" থাকে এবং অনুমতি আসামাত্র ভরে। অপেক্ষমাণ slot ভরার আগে আর কোনো harvest নয়, তাই একসাথে সর্বোচ্চ একটি জায়গা খালি থাকে।
4. Pulse NEUTRAL আর বাকি দুটি 1 BUY + 1 SELL হলে swap-এ refill থাকে না। তখন তৃতীয় slot ইচ্ছাকৃতভাবে খালি; এটি অপেক্ষমাণ slot নয়।
5. Backup TP-তে broker নিজে কোনো trade বন্ধ করলে bot সাথে সাথে refill করে। এটি fallback; শুধু তখনই একসাথে দুটি জায়গা খালি হতে পারে।
6. **Gap meter:** প্রতিটি slot close থেকে refill fill পর্যন্ত কত মিলিসেকেন্ড খালি ছিল, bot তা মাপে। Dashboard ও log-এ আজকের গড় ও সর্বোচ্চ দেখায়।

## 6. Harvest Bank ও Re-anchor

জোরালো move-এ উল্টো দিকের trade দাম থেকে পিছিয়ে পড়ে। দূরে থাকা trade নিজে £0.50-এ পৌঁছাতে পারে না, ফলে ওই slot আর harvest করে না। Re-anchor এই slot-কে আবার কাজে ফেরায়। এটি v8-এর amortization ধারণারই নতুন রূপ: harvest-এর জমা টাকা দিয়ে আটকে পড়া trade-এর খরচ মেটানো।

- **Bank** = এই cycle-এ harvest থেকে জমা net profit, re-anchor-এর খরচ বাদে। Bank কখনো শূন্যের নিচে নামে না, আর restart-এর পরও থাকে।
- **আটকে পড়া trade:** net loss ≥ £1.50।
- **Re-anchor-এর শর্ত:** Bank ≥ ওই trade-এর loss + £0.50 রিজার্ভ।
- **Re-anchor নিজেও একটি swap:** আটকে পড়া trade-এর close আর নতুন trade একসাথে যায়। নতুন trade-এর direction §2-এর নিয়মে নতুন করে ঠিক হয়, তাই confirmed reversal-এর পর basket-এর বিন্যাস এভাবেই নতুন দিকে ঘোরে। Bank থেকে আসল realized loss কাটা হয়।
- একাধিক trade আটকে থাকলে সবচেয়ে বেশি loss-এরটি আগে। Harvest আর re-anchor একসাথে দরকার হলে harvest আগে, কারণ তাতে Bank বাড়ে।
- Bank-এ যথেষ্ট না থাকলে trade অপেক্ষা করে। আরও harvest জমলে re-anchor হয়।

**উদাহরণ (UP, 2 BUY + 1 SELL):**
- দুই BUY পালা করে ছয়বার harvest করেছে, Bank = £3.00।
- SELL পিছিয়ে পড়ে এখন −£1.50।
- শর্ত মেলে (£3.00 ≥ £1.50 + £0.50)। Bot SELL বন্ধ করে, আর একই মুহূর্তে বর্তমান দামে নতুন trade খোলে। বাকি দুটি BUY, তাই নিয়মমতো নতুনটি SELL।
- Bank = £1.50। তিনটি trade-ই আবার দামের কাছে, সবাই harvest করতে পারে।

## 7. সুরক্ষা

| স্তর | কাজ | প্রস্তাবিত মান |
|---|---|---|
| Entry gate | Spread spike, news (USD high-impact), rollover, শুক্রবার রাত, margin level: নতুন entry (শুরু, refill, re-anchor) বন্ধ। Harvest চলে (§5.3)। | v10-এর test করা অংশ থেকে |
| Disaster stop | প্রতিটি trade-এ broker-এর server-এ একটি দূরের stop, শুধু terminal offline হলে কাজে লাগে। খোলার সময় বসে, কখনো বড় হয় না। | £25 / trade |
| Basket hard stop | খোলা trade-গুলোর মোট floating loss সীমা ছুঁলে সব বন্ধ, cooldown, তারপর নতুন cycle। সীমা input-এ স্থির, bot কখনো বাড়ায় না। | £25, cooldown 60 min |
| Daily limit | দিনের realized + floating loss সীমা ছুঁলে সব বন্ধ, ওই server দিনের জন্য বিরতি। | £50 |
| শুক্রবার | 21:00-এর পর নতুন entry নয়, 22:45-এ সব বন্ধ (weekend gap থেকে সুরক্ষা)। | চালু |
| Real account lock | Real-money account-এ `InpAllowRealAccount = true` ছাড়া কোনো order নয়। | v10 থেকে |
| Equity kill switch (যোগ করা) | Equity তার সর্বোচ্চ মান থেকে এই % নামলে সব বন্ধ, আর কোনো trade নয়। আবার চালু করতে `InpResetKillSwitch = true`। | 10% |

- দৈনিক flatten নেই; basket রাত পার করে। শুধু rollover-এর সময় নতুন entry বন্ধ থাকে।
- Basket stop, daily limit বা শুক্রবারে সব বন্ধ হলে cycle শেষ হয়: Bank = max(0, Bank − ওই বন্ধে realized loss)।

## 8. Dashboard, log ও CSV

- **৩টি slot:** direction, entry, net, harvest line পর্যন্ত দূরত্ব, আর ভূমিকা (trend দিকের, নাকি hedge)।
- **Pulse:** score ও direction, আর পরের direction বদলের জন্য কী লাগবে।
- **Bank ও আজকের হিসাব:** Bank, আজকের harvest ও re-anchor সংখ্যা, gap-এর গড় ও সর্বোচ্চ।
- **CSV (`Common\Files`):** প্রতিটি harvest, re-anchor ও stop ঘটনা এক লাইনে, সাথে ঘটনার পরের Bank।

## 9. প্রথম version-এ নেই (পরে যোগ করা যাবে)

- Worker flip (direction বদলালে চলমান trade বন্ধ): সিদ্ধান্ত অনুযায়ী বন্ধ।
- NEUTRAL-এ breakout trap (BUY STOP + SELL STOP)।
- কোনো trade-এর বড় target বা runner। সব trade £0.50।
- তিনটি trade একই দিকে।

## 10. সিদ্ধান্ত (চূড়ান্ত: user লিখেছেন "ok go")

1. **Re-anchor:** চালু; loss ≥ £1.50, Bank-এ £0.50 রিজার্ভ।
2. **Harvest পদ্ধতি:** bot-side harvest + swap + backup TP। Live-এ swap async (একসাথে পাঠানো), Strategy Tester-এ sync।
3. **সুরক্ষার মান:** disaster stop £25/trade, basket stop £25 (cooldown 60 min), daily limit £50।

## 11. Inputs

| গ্রুপ | Input | Default |
|---|---|---|
| General | `InpMode` | TRADE (বা OBSERVE: শুধু দেখায়, order নয়) |
| | `InpMagic` | 110001 |
| | `InpAllowRealAccount` | false |
| Harvest | `InpLots` | 0.01 |
| | `InpHarvestNet` | 0.50 |
| | `InpBackupTpNet` | 0.80 |
| | `InpCommissionPerLotRT` | 4.00 (real deal-এ বেশি দেখালে bot নিজে বাড়ায়) |
| | `InpUseAsync` | true (live-এ close ও refill একসাথে) |
| Pulse | `InpPulseOn` / `InpPulseOff` | 40 / 15 |
| | `InpPulseConfirmBars` | 2 |
| Re-anchor | `InpUseReanchor` | true |
| | `InpReanchorLoss` | 1.50 |
| | `InpBankKeep` | 0.50 |
| | `InpResetBank` | false (true দিলে start-এ Bank = 0) |
| Entry gate | `InpMaxSpreadPts` / `InpSpreadSpikeRatio` | 30 / 1.8 |
| | `InpNewsBeforeMin` / `InpNewsAfterMin` | 10 / 15 |
| | `InpShockATR` / `InpShockWindowSec` / `InpShockPauseSec` | 3.0 / 20 / 120 |
| | `InpMinMarginLevel` | 150% |
| | `InpTradeStart` / `InpTradeEnd` / `InpMondayDelayMin` | 01:30 / 23:00 / 60 |
| Protection | `InpDisasterLoss` | 25.00 |
| | `InpBasketStop` / `InpBasketCooldownMin` | 25.00 / 60 |
| | `InpDailyLossLimit` | 50.00 |
| | `InpFridayLastEntry` / `InpFridayFlatten` | 21:00 / 22:45 |
| | `InpEquityKillPct` / `InpResetKillSwitch` | 10 / false |
