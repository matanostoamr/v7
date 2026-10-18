"""Check every v14 basket in an MT5 report against the bot's rules, and summarise the results.

  python3 analyse_v14.py report_1414.html

The inputs (harvest, hedge distance, lots, news window ...) are read from the report itself.
"""
import collections, sys
from datetime import timedelta
from report_rows import rows_of, inputs_of, period_of, orders_of, deals_of, baskets_of

EPS = 0.005
rows = rows_of(sys.argv[1])
inp = inputs_of(rows)
p0, p1 = period_of(rows)
deals = deals_of(rows)
orders = orders_of(rows)
baskets, problems = baskets_of(deals)

f = lambda k, d: float(inp.get(k, d))
LOTS, MAXT = f("InpLots", 0.01), int(f("InpMaxTrades", 2))
HARVEST, DIST = f("InpHarvestNet", 4.0), f("InpHedgeDistance", 8.0)
HMULT, T3MULT = f("InpHedgeMult", 2.0), f("InpTrade3Mult", 3.0)
TARGET, STOP = f("InpBasketTarget", 1.0), f("InpHardStop", 30.0)
NEWS = inp.get("InpNewsFilter", "false").lower() == "true"
hm = lambda s: int(s.split(":")[0]) * 60 + int(s.split(":")[1])
NS, NE = hm(inp.get("InpNewsStart", "15:00")), hm(inp.get("InpNewsEnd", "15:45"))
in_news = lambda t: t.weekday() < 5 and NS <= t.hour * 60 + t.minute < NE

print("period %s -> %s | inputs: %s" % (p0.date(), p1.date(), ", ".join("%s=%s" % kv for kv in inp.items())))
print("deals %d, orders %d, baskets %d | rebuild problems: %s" % (
    len(deals) - 1, len(orders), len(baskets), problems if problems else "none"))

closed = [b for b in baskets if b["closed"]]
total = sum(b["net"] for b in baskets)
print("\n=== outcomes (sum of all baskets %+.2f)" % total)
for tag, n in sorted(collections.Counter(b["tag"] for b in baskets).items()):
    g = [b for b in baskets if b["tag"] == tag]
    nets = [b["net"] for b in g]
    durs = sorted(b["dur"] for b in g)
    print("%-11s n=%3d sum %+8.2f avg %+6.2f min %+6.2f max %+6.2f | minutes median %.0f max %.0f" % (
        tag, n, sum(nets), sum(nets) / n, min(nets), max(nets), durs[n // 2], durs[-1]))

hv = [b for b in closed if b["tag"] == "HV"]
hedged = [b for b in closed if b["hedge"]]
bt = [b for b in hedged if b["tag"] == "BT"]
hs = [b for b in closed if b["tag"] == "HS"]
if closed and hv and bt and hs:
    p = len(hv) / len(closed)
    a_hv, a_bt, a_hs = (sum(b["net"] for b in g) / len(g) for g in (hv, bt, hs))
    q_be = (-p * a_hv / (1 - p) - a_hs) / (a_bt - a_hs)
    print("\nclosed %d | trade 1 harvested alone %.1f%% | hedged %d | BT share of hedged %.1f%% (break-even %.1f%%) | "
          "hard stops %.1f%% of baskets | average %+.3f per closed basket | one HS instead of a BT costs %.2f" % (
              len(closed), 100 * p, len(hedged), 100.0 * len(bt) / len(hedged), 100 * q_be,
              100.0 * len(hs) / len(closed), sum(b["net"] for b in closed) / len(closed), a_bt - a_hs))

print("\n=== rule checks (0 = OK)")
def report(name, bad):
    print("%-58s %d" % (name, len(bad)))
    for b in bad[:8]:
        print("    #%d %s %s net %+.2f" % (b["no"], b["start"], b["tag"], b["net"]))
report("HV below +%.2f net or not alone" % HARVEST, [b for b in hv if b["net"] < HARVEST - EPS or b["ntr"] != 1])
report("BT below +%.2f net" % TARGET, [b for b in closed if b["tag"] == "BT" and b["net"] < TARGET - EPS])
report("hedge closer than $%.2f to trade 1" % DIST, [b for b in hedged if b["hdist"] < DIST - EPS])
report("hedge lot not trade 1 x %.1f" % HMULT, [b for b in hedged if abs(b["hedge"]["v"] - round(b["t1vol"] * HMULT, 2)) > 1e-9])
report("trade 1 lot not %.2f" % LOTS, [b for b in baskets if abs(b["t1vol"] - LOTS) > 1e-9])
report("more than %d trades open at once" % MAXT, [b for b in baskets if b["maxopen"] > MAXT])
report("trade 3 without the hedge, or lot not x %.1f" % T3MULT,
       [b for b in baskets if b["t3"] and (not b["hedge"] or abs(b["t3"]["v"] - round(b["t1vol"] * T3MULT, 2)) > 1e-9)])
report("closes of one basket on different seconds (BT/HS)",
       [b for b in closed if b["tag"] in ("BT", "HS") and len(set(x["time"] for x in b["outs"])) > 1])
bar = lambda t: int(t.timestamp()) // 300
report("trade 1 in the same M5 bar as the last basket end",
       [b for a, b in zip(baskets, baskets[1:]) if "end" in a and bar(b["start"]) <= bar(a["end"])])
report("HF / RS / other closes", [b for b in baskets if b["tag"] not in ("HV", "BT", "HS", "end of test")])
if NEWS:
    report("trade 1 filled in the news window %s-%s" % (inp.get("InpNewsStart"), inp.get("InpNewsEnd")),
           [b for b in baskets if in_news(b["start"])])
    print("%-58s %d" % ("limit orders placed in the news window",
                        sum(1 for o in orders if "limit" in o["type"] and in_news(o["open"]))))
if hedged:
    print("hedge distance min %.2f avg %.2f max %.2f | HS worst %+.2f (%.2f past the stop)" % (
        min(b["hdist"] for b in hedged), sum(b["hdist"] for b in hedged) / len(hedged), max(b["hdist"] for b in hedged),
        min((b["net"] for b in hs), default=0.0), min((b["net"] for b in hs), default=-STOP) + STOP))

lim = [o for o in orders if "limit" in o["type"]]
canc = [o for o in lim if o["state"] == "canceled"]
on_bar = lambda t: t.second <= 1 and t.minute % 5 == 0 or (t.hour == 1 and t.minute == 1 and t.second == 0)
print("\n=== orders: %d limit (%d filled, %d canceled, %d of them mid-bar) | trade 1 at market %d" % (
    len(lim), sum(o["state"] == "filled" for o in lim), len(canc), sum(not on_bar(o["done"]) for o in canc),
    sum(1 for o in orders if o["comment"] == "V14 1" and "limit" not in o["type"])))

print("\n=== by day (basket close)")
day = collections.OrderedDict()
for b in closed:
    e = day.setdefault(b["end"].date(), collections.Counter())
    e["n"] += 1; e[b["tag"]] += 1; e["net"] += b["net"]
for k, e in day.items():
    print("%s %s baskets %2d (HV %2d BT %2d HS %d) net %+7.2f" % (k, k.strftime("%a"), e["n"], e["HV"], e["BT"], e["HS"], e["net"]))
print("days %d, losing days %d" % (len(day), sum(1 for e in day.values() if e["net"] < 0)))
mon, wk = collections.OrderedDict(), collections.OrderedDict()
for b in closed:
    mon[b["end"].strftime("%Y-%m")] = mon.get(b["end"].strftime("%Y-%m"), 0.0) + b["net"]
    k = str((b["end"] - timedelta(days=b["end"].weekday())).date())
    wk[k] = wk.get(k, 0.0) + b["net"]
print("by month:", {k: round(v, 2) for k, v in mon.items()})
print("by week (Monday):", {k: round(v, 2) for k, v in wk.items()})

print("\n=== hard stops")
for b in hs:
    print("  #%3d %s -> %s %s net %+.2f hedge $%s" % (b["no"], b["start"], b["end"], "BUY" if b["dir"] > 0 else "SELL",
                                                     b["net"], b["hdist"]))
win = [b for b in closed if in_news(b["start"])]
print("baskets started %s-%s Mon-Fri: %d, net %+.2f, HS %d" % (inp.get("InpNewsStart", "15:00"), inp.get("InpNewsEnd", "15:45"),
                                                               len(win), sum(b["net"] for b in win), sum(b["tag"] == "HS" for b in win)))
m1530 = [b for b in closed if b["end"].strftime("%H:%M") == "15:30"]
print("baskets closed in the 15:30 minute: %d, net %+.2f, HS %d" % (len(m1530), sum(b["net"] for b in m1530),
                                                                   sum(b["tag"] == "HS" for b in m1530)))
wkd = [b for b in closed if b["start"].weekday() == 4 and b["end"].weekday() == 0]
print("held over a weekend: %d, net %+.2f, HS %d" % (len(wkd), sum(b["net"] for b in wkd), sum(b["tag"] == "HS" for b in wkd)))

bal = peak = 0.0
mdd = 0.0
for b in closed:
    bal += b["net"]; peak = max(peak, bal); mdd = max(mdd, peak - bal)
print("\nbiggest drop of the closed-basket balance %.2f (the report's equity drawdown is the real one)" % mdd)
