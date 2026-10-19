---
inclusion: always
---
# matanostoamr/v7: gold MT5 bots (project rules)

**Before any work, read `docs/HANDOVER.md` on the newest bot branch `feat/v15-dual-grid-scalper` (PR #7).** It holds the full state: the user, the rules, v15 build 1.0, v14 build 1.2 (demo forward test, PR #6), the test results and the next steps.
Raw link: https://raw.githubusercontent.com/matanostoamr/v7/feat/v15-dual-grid-scalper/docs/HANDOVER.md

#[[file:docs/HANDOVER.md]]

## Rules that always apply
- **Replies:** short, simple English plus **exactly one Bengali line**. Be fast and direct.
- **Links:** the user works only in the GitHub web UI. End every reply with full links (blob and raw file on the branch, PR, comment) and warn that `main` does not have the change.
- **Approval:** no new feature, and no change to a default, without his explicit OK. Merge only when he writes "merge".
- **Branches:** each bot version has its own branch and PR. v15 work goes to `feat/v15-dual-grid-scalper` (PR #7), v14 work to `feat/v14-hedge-harvester` (PR #6), never to `main`.
- **Tests:** he compiles and runs all MT5 backtests himself, so don't run backtests. Check code with `tools/mqlcheck`, and say it is not a MetaEditor compile.
- **Judging:** judge logic only by his own test reports and maths ("dont judge the logic from internet"), and analyse every trade or basket in a report he sends (`tools/reports`).
- **GitHub CLI:** use `gh api` REST calls only (`gh pr` and `gh issue` fail here).
