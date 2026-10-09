# Submission checklist — Tiny Tapeout SKY26d

**Prepared 9 October 2026.** Deadline and status below are current as of
that date; re-check the countdown before acting.

---

## 1. Dates

| | |
|---|---|
| **Today** | Friday 9 October 2026 |
| **SKY26d closes** | **~Monday 30 November 2026, 19:00 UTC** (52 days) |
| GF26c closes (GlobalFoundries, not our target) | ~Monday 7 December 2026 |
| Chips back | Manufacturing is 6–9 months; **budget up to a year** including PCB assembly, test and fulfilment |

Note: the raw HTML of tinytapeout.com shows a placeholder "44 days 44 hours
44 mins" — that is not the real countdown. The live figure is 52 days, which
is where 30 November comes from.

## 2. Where to submit

**https://app.tinytapeout.com/projects/create**

It requires **signing in with GitHub**, which is why this step cannot be
automated for you — it ties the submission to your account and your payment.

## 3. Status: the engineering is done

Everything Tiny Tapeout checks is already green on the current commit.

| Requirement | State |
|---|---|
| Public GitHub repo | ✅ [jasonvanaardt-prog/SID_tinytapeout](https://github.com/jasonvanaardt-prog/SID_tinytapeout) |
| `gds` — hardens with LibreLane 3.0.14 | ✅ |
| `precheck` — official Tiny Tapeout precheck | ✅ |
| `gl_test` — tests against the hardened netlist | ✅ |
| `viewer` — 3D GDS view published | ✅ |
| `test` — 20 RTL tests, cocotb 2.1.0 | ✅ |
| `docs` — datasheet PDF builds | ✅ |
| `info.yaml`: title, author, description, language | ✅ all present |
| `docs/info.md`: "How it works", "How to test" | ✅ both present |
| Open-source licence | ✅ CERN-OHL-S-2.0 |

Required fields per the Tiny Tapeout FAQ are `author`, `title`,
`description`, `how_it_works`, `how_to_test`, `language`. The last two are
taken from the headings in `docs/info.md`, not from `info.yaml`.

## 4. What you actually have to do

1. **Go to https://app.tinytapeout.com/projects/create** and sign in with
   GitHub (account `jasonvanaardt-prog`).
2. **Choose the SKY26d shuttle** and the **SKY Verilog** submission type.
3. **Give the repo URL**: `https://github.com/jasonvanaardt-prog/SID_tinytapeout`
4. **Confirm the tile count is 4x2 (8 tiles).** This is read from
   `info.yaml`, but check it on the order screen — it is the single biggest
   cost driver.
5. **Pay.** See costs below.
6. **Accept the terms of service.**

That is the whole process. There is no separate document pack to fill in —
the repo *is* the submission.

## 5. Cost

From the [pricing calculator](https://app.tinytapeout.com/calculator?tiles=8&pcbs=1&shuttle=chipfoundry):

| Item | Academic/Industry | Individual (early bird) |
|---|---|---|
| 8 tiles @ €70 | €560 | €560 |
| DevKit (PCB) ×1 | €300 | €100 |
| Worldwide economy shipping | €15 | €15 |
| **Total** | **€875** | **€675** |

Tiles only, no devkit and no shipping: **€560**.

Early-bird/individual pricing is limited per shuttle and is only available
to individuals, not institutions — so if you are submitting as CSIRO, budget
for the €875 figure.

## 6. Optional before you submit

- **`info.yaml` has `discord: ""`.** Filling it in gets you the Tapeout role
  on their Discord automatically. Purely cosmetic.
- **Licence.** CERN-OHL-S-2.0 (strongly reciprocal) was chosen because the
  two reference implementations consulted for hardware constants, reDIP-SID
  and icesid, are under it. The RTL here was written from the datasheet
  rather than copied, so a permissive licence is arguable — but that is a
  decision to make deliberately, not by accident.
- **`submodules/reDIP-SID`** is a nested 54 MB git repo, currently
  untracked and gitignored. If you want it in the repo, register it properly
  with `git submodule add`.

## 7. After submitting

- You can **update the design up to the deadline**, but a change only takes
  effect if you **create a new submission** — editing the repo alone is not
  enough.
- Any push re-runs the pipeline, so keep it green.
- Manufacturing 6–9 months, then PCB assembly, test and fulfilment.

## 8. Decisions already made, for the record

- **4x2, not 3x2.** 3x2 would save €140 and does close locally, but at 75 %
  utilisation with double the routing iterations, 2.5× the slew violations
  and density 90 failing outright. Too close to a cliff to risk a shuttle
  slot. See HANDOVER.md.
- **`PL_TARGET_DENSITY_PCT: 75`** is required — at the template default of
  60, global placement fails with `GPL-0302`. This is committed and is what
  CI used successfully.
