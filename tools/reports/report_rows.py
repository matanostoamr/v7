"""Shared reader for MT5 Strategy Tester HTML reports (UTF-8 text, see extract_report.py)."""
import re
from datetime import datetime
from html.parser import HTMLParser


class _Rows(HTMLParser):
    def __init__(self):
        super().__init__()
        self.rows, self.row, self.cell = [], None, None

    def handle_starttag(self, tag, attrs):
        if tag == "tr":
            self.row = []
        elif tag in ("td", "th") and self.row is not None:
            self.cell = []

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self.cell is not None and self.row is not None:
            self.row.append(re.sub(r"\s+", " ", "".join(self.cell)).strip())
            self.cell = None
        elif tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None

    def handle_data(self, data):
        if self.cell is not None:
            self.cell.append(data)


def rows_of(html_path):
    p = _Rows()
    p.feed(open(html_path, encoding="utf-8").read())
    return p.rows


def T(s):
    return datetime.strptime(s, "%Y.%m.%d %H:%M:%S")


def num(s):
    s = (s or "").replace(" ", "")
    return float(s) if s else 0.0


def inputs_of(rows):
    """{'InpLots': '0.01', ...} from the Settings block."""
    out, on = {}, False
    for r in rows:
        cells = [c for c in r if c]
        if not cells:
            continue
        if cells[0] == "Inputs:":
            on, cells = True, cells[1:]
        elif on and cells[0].endswith(":"):
            break
        if on:
            for c in cells:
                if "=" in c:
                    k, v = c.split("=", 1)
                    out[k.strip()] = v.strip()
    return out


def period_of(rows):
    """(start, end) datetimes from 'Period: M5 (2026.09.01 - 2026.10.15)'."""
    for r in rows:
        cells = [c for c in r if c]
        if cells and cells[0] == "Period:":
            m = re.search(r"(\d{4}\.\d\d\.\d\d)\s*-\s*(\d{4}\.\d\d\.\d\d)", cells[1])
            return datetime.strptime(m.group(1), "%Y.%m.%d"), datetime.strptime(m.group(2), "%Y.%m.%d")
    return None, None


def orders_of(rows):
    oi = next(i for i, r in enumerate(rows) if r[:2] == ["Open Time", "Order"])
    out = []
    for r in rows[oi + 1:]:
        if r[:2] == ["Time", "Deal"]:
            break
        if len(r) >= 11 and re.match(r"\d{4}\.\d\d\.\d\d", r[0]):
            out.append(dict(open=T(r[0]), order=int(r[1]), type=r[3], vol=r[4], price=num(r[5]),
                            done=T(r[8]) if r[8] else None, state=r[9], comment=r[10]))
    return out


def deals_of(rows):
    di = next(i for i, r in enumerate(rows) if len(r) >= 13 and r[0] == "Time" and r[1] == "Deal")
    out = []
    for r in rows[di + 1:]:
        if len(r) < 13 or not re.match(r"\d{4}\.\d\d\.\d\d", r[0]):
            continue
        out.append(dict(time=r[0], t=T(r[0]), deal=int(r[1]), sym=r[2], type=r[3], dir=r[4], vol=r[5],
                        v=num(r[5]) if r[5] else 0.0, price=num(r[6]), order=int(r[7]) if r[7] else 0,
                        comm=num(r[8]), swap=num(r[9]), profit=num(r[10]), bal=num(r[11]), comment=r[12]))
    return out


def baskets_of(deals):
    """Rebuild v14 baskets: one starts at an 'in' deal while nothing is open and ends when all are closed.
    An 'out' deal closes the open trade of the other type with the same volume."""
    open_pos, baskets, cur, problems = [], [], None, []
    for d in deals:
        if d["type"] == "balance":
            continue
        d["net"] = round(d["comm"] + d["swap"] + d["profit"], 2)
        if d["dir"] == "in":
            if not open_pos:
                if d["comment"] != "V14 1":
                    problems.append("basket starts with %s at deal %d" % (d["comment"], d["deal"]))
                cur = dict(no=len(baskets) + 1, start=d["t"], dir=1 if d["type"] == "buy" else -1,
                           t1price=d["price"], t1vol=d["v"], t1deal=d, deals=[], ins=[], outs=[], maxopen=0)
                baskets.append(cur)
            elif d["comment"] == "V14 1":
                problems.append("trade 1 while a basket is open at deal %d" % d["deal"])
            open_pos.append(dict(type=d["type"], v=d["v"]))
            cur["ins"].append(d)
            cur["maxopen"] = max(cur["maxopen"], len(open_pos))
        else:
            want = "buy" if d["type"] == "sell" else "sell"
            k = next((i for i, p in enumerate(open_pos) if p["type"] == want and abs(p["v"] - d["v"]) < 1e-9), None)
            if k is None:
                problems.append("out deal %d has no open trade" % d["deal"])
            else:
                open_pos.pop(k)
            cur["outs"].append(d)
        cur["deals"].append(d)
        if not open_pos and d["dir"] == "out":
            cur["end"] = d["t"]
            cur = None
    for b in baskets:
        b["net"] = round(sum(x["net"] for x in b["deals"]), 2)
        tags = sorted(set(x["comment"].replace("V14 ", "") for x in b["outs"]))
        b["tag"] = "+".join(tags) if tags else "OPEN"
        b["ntr"] = len(b["ins"])
        h = [x for x in b["ins"] if x["comment"] == "V14 H"]
        b["hedge"] = h[0] if h else None
        b["hdist"] = round((b["t1price"] - h[0]["price"]) * b["dir"], 2) if h else None
        t3 = [x for x in b["ins"] if x["comment"] == "V14 3"]
        b["t3"] = t3[0] if t3 else None
        b["closed"] = "end" in b and b["tag"] not in ("end of test", "OPEN")
        b["dur"] = ((b["end"] if "end" in b else b["deals"][-1]["t"]) - b["start"]).total_seconds() / 60.0
    return baskets, problems
