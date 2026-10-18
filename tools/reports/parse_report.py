import re, html, sys, json, collections
from html.parser import HTMLParser
src=open(sys.argv[1],encoding='utf-8').read()
class P(HTMLParser):
    def __init__(s):
        super().__init__(); s.rows=[]; s.row=None; s.cell=None
    def handle_starttag(s,t,a):
        if t=='tr': s.row=[]
        elif t in('td','th') and s.row is not None: s.cell=[]
    def handle_endtag(s,t):
        if t in('td','th') and s.cell is not None and s.row is not None:
            s.row.append(re.sub(r'\s+',' ',''.join(s.cell)).strip()); s.cell=None
        elif t=='tr' and s.row is not None:
            s.rows.append(s.row); s.row=None
    def handle_data(s,d):
        if s.cell is not None: s.cell.append(d)
p=P(); p.feed(src)
rows=p.rows
# find deals header
di=None
for i,r in enumerate(rows):
    if len(r)>=13 and r[0]=='Time' and r[1]=='Deal':
        di=i
deals=[]
for r in rows[di+1:]:
    if len(r)<13 or not re.match(r'\d{4}\.\d\d\.\d\d',r[0]): continue
    f=lambda x: float(x.replace(' ','')) if x.strip() not in ('',) else 0.0
    deals.append(dict(time=r[0],deal=int(r[1]),sym=r[2],type=r[3],dir=r[4],vol=r[5],price=f(r[6]) if r[6] else 0.0,
        order=int(r[7]) if r[7] else 0,comm=f(r[8]),swap=f(r[9]),profit=f(r[10]),bal=f(r[11]) if r[11] else 0.0,comment=r[12]))
out=sys.argv[2] if len(sys.argv)>2 else 'deals_4411.json'
json.dump(deals,open(out,'w'))
print("deals",len(deals))
c=collections.Counter((d['type'],d['dir']) for d in deals); print(c)
print(deals[:3]); print(deals[-3:])
