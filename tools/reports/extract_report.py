"""Get an MT5 Strategy Tester HTML report as UTF-8 text.

MT5 saves reports as UTF-16 (bytes FF FE at the start). Two ways in:
  python3 extract_report.py --file  1414.html            report_1414.html
  python3 extract_report.py --session messages.jsonl     report_1414.html [--name 1414]
--session: a chat attachment. Kiro keeps it base64-encoded in the session log
(/projects/.kiro/sessions/<id>/<id>/messages.jsonl), in payload.documents[i].data
of the user message. The newest attachment wins; --name picks one by file name.
"""
import base64, json, sys


def decode(raw):
    if raw[:2] == b"\xff\xfe":
        return raw[2:].decode("utf-16-le", errors="replace")
    if raw[:2] == b"\xfe\xff":
        return raw[2:].decode("utf-16-be", errors="replace")
    if raw[:3] == b"\xef\xbb\xbf":
        raw = raw[3:]
    return raw.decode("utf-8", errors="replace")


def from_session(log, name):
    found = None
    for line in open(log, encoding="utf-8", errors="replace"):
        if '"documents"' not in line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        payload = rec.get("payload") or {}
        for d in payload.get("documents") or []:
            if name and name not in str(d.get("name", "")):
                continue
            if d.get("data"):
                found = (d.get("name"), d["data"])
    if not found:
        sys.exit("no attachment found" + (" named %s" % name if name else ""))
    print("attachment:", found[0])
    return base64.b64decode(found[1])


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("--file", "--session"):
        sys.exit(__doc__)
    name = sys.argv[sys.argv.index("--name") + 1] if "--name" in sys.argv else None
    raw = open(sys.argv[2], "rb").read() if sys.argv[1] == "--file" else from_session(sys.argv[2], name)
    text = decode(raw)
    open(sys.argv[3], "w", encoding="utf-8").write(text)
    print("saved %s (%d characters)" % (sys.argv[3], len(text)))


main()
