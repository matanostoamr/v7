"""Where did the market time go? Inside a basket / limit order waiting / no signal.

  python3 frequency_v14.py report_1414.html

Market time = Monday to Friday, 01:00-24:00 server time, over the report's period.
"""
import collections, sys
from datetime import timedelta
from report_rows import rows_of, period_of, orders_of, deals_of, baskets_of

rows = rows_of(sys.argv[1])
p0, p1 = period_of(rows)
baskets, _ = baskets_of(deals_of(rows))
lims = [o for o in orders_of(rows) if "limit" in o["type"]]

mk, t = {}, p0
while t < p1:
    if t.weekday() < 5 and t.hour >= 1:
        mk[t] = "idle"
    t += timedelta(minutes=1)
M = len(mk)

def paint(a, b, label, only=None):
    t = a.replace(second=0)
    while t < b:
        if t in mk and (only is None or mk[t] == only):
            mk[t] = label
        t += timedelta(minutes=1)

for b in baskets:
    paint(b["start"], b.get("end", p1), "hedged" if b["hedge"] else "trade1")
for o in lims:
    paint(o["open"], o["done"] or p1, "limit", only="idle")
c = collections.Counter(mk.values())
inb = c["trade1"] + c["hedged"]
print("market time %.0f h" % (M / 60.0))
for k, lab in (("trade1", "in a basket, trade 1 alone"), ("hedged", "in a basket, hedged"),
               ("limit", "limit order waiting"), ("idle", "no signal / no order")):
    print("  %-28s %5.1f%%" % (lab, 100.0 * c[k] / M))
print("  in a basket total             %5.1f%%" % (100.0 * inb / M))
n = len(baskets)
cycle = M / n
print("baskets %d | average cycle %.0f min (%.0f in the basket)" % (n, cycle, inb / n))
print("most possible with one basket at a time: %d (%+.0f%%)" % (M / (inb / n), 100.0 * (cycle / (inb / n) - 1)))
for k, lab in (("limit", "limit waiting"), ("idle", "no-signal time")):
    print("removing all %-15s at most %+.0f%%" % (lab, 100.0 * (cycle / (cycle - c[k] / n) - 1)))

med = lambda xs: sorted(xs)[len(xs) // 2] if xs else float("nan")
for tag in ("HV", "BT", "HS"):
    w = []
    for a in baskets:
        if a["tag"] == tag and "end" in a:
            nxt = next((o for o in lims if o["open"] >= a["end"]), None)
            if nxt:
                w.append((nxt["open"] - a["end"]).total_seconds() / 60.0)
    print("after %s: next limit placed after a median of %.1f min (%d baskets)" % (tag, med(w), len(w)))
fills = [(o["done"] - o["open"]).total_seconds() / 60.0 for o in lims if o["state"] == "filled"]
print("limit placed -> filled: median %.0f min" % med(fills))
