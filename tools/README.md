# Tools (agent helpers, not part of any bot)

Used to check bot code without MetaEditor and to analyse MT5 Strategy Tester reports. Nothing here trades. Run from the folder the script is in.

## `mqlcheck/`: offline syntax and type check of an .mq5 file
```
cd tools/mqlcheck
python3 mql2cpp.py ../../Gold_Hedge_Harvester_v14.00.mq5 v14_check.cpp
g++ -std=c++17 -fsyntax-only -Wall -Wextra -Wno-unused-parameter v14_check.cpp
```
- **Passing:** no output from g++ means 0 errors and 0 warnings. This is **not** MetaEditor: the user still compiles in MT5.
- **ASCII only:** `mql2cpp.py` stops on any non-ASCII byte, so keep `.mq5` files ASCII (no `£` in code or comments).
- **Shim:** `mql5_shim.h` declares the MQL5 functions and types the bots use. If a new MQL5 function is used, add its declaration there.
- **News test:** `news_window_test.cpp` checks the v14 news window code (53 cases, incl. quoted optimizer inputs since build 1.1.1). Build it after `mql2cpp.py`:
  ```
  g++ -std=c++17 -O0 -w -o news_window_test news_window_test.cpp -Wl,--unresolved-symbols=ignore-all && ./news_window_test
  ```

## `reports/`: MT5 report analysis (v14)
```
cd tools/reports
python3 extract_report.py --session /projects/.kiro/sessions/<id>/<id>/messages.jsonl report.html --name 1414
python3 analyse_v14.py report.html      # every basket against the rules, results by outcome/day/week, hard stops, news, weekends
python3 frequency_v14.py report.html    # time in a basket / limit waiting / no signal
```
- **Attachments:** a report attached in chat is base64 inside the session log (`payload.documents[i].data`). The file is UTF-16 (starts with FF FE), and `extract_report.py` decodes it. `--file x.html` converts a UTF-16 file that is already on disk.
- **Shared code:** `report_rows.py` reads the tables and rebuilds the baskets. A basket starts at an `in` deal while nothing is open and ends when all trades are closed. An `out` deal closes the open trade of the other type with the same volume.
- **Net:** net = commission + swap + profit, summed over all deals of the basket. Same as the bot.
- **Drawdown:** use the report's **equity** drawdown. The balance drawdown is inflated, because one leg of a basket closes a moment before the other.
- `parse_report.py` is the older deals-to-JSON parser (v11–v13 reports).
