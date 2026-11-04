# How much of the downloads is automated?

The evaluation behind the "Likely automated" numbers on the Overview and on
About → Automated downloads. Run it on the committed snapshot with:

```sh
extension-downloads/analysis/run.sh        # DuckDB CLI + anofox_statistics; about 2 s
```

`01`–`08` build the tables, `09_results.sql` prints every number below.
Snapshot: `extension-downloads/demo/` fetched 2026-11-04; DuckDB v1.5.5,
anofox_statistics 179c1c6; bootstrap seeds 0.42 and 0.7, 200 resamples each.

## Bottom line

For all community extensions together, about one download in four is
automated: 24 % (95 % CI 16 to 35 %) from the DuckDB 2.0 release, in line
with the 21 % of the common floor method over Sep–Oct 2026. For a single
extension no method here gives a reliable "real users" number. The
dashboards therefore show the share of all downloads (and by GitHub star
group), never a per-extension estimate.

## Question and estimand

- Goal: estimation, with one-step prediction as the yardstick (there is no
  ground truth for the automated part).
- Estimand: the share of the community extensions' weekly `INSTALL`
  downloads that comes from automation (mirrors, scanners, CI matrices)
  rather than people; overall and, if possible, per extension.

## Data

- 11,465 extension-weeks, 407 extensions, 48 captures (2025-12-01 to
  2026-10-26), after the 2025-11-10 change to full listing. The latest
  capture (provisional, overlapping the week before) is left out.
- 298 rows (2.6 %) have no GitHub stars (repo not found) and are left out
  of the floor estimation. Stars are one current snapshot.
- Reference ("no-audience") group: built for a current DuckDB, at most 2
  stars, listed for at least 4 weeks: 2–7 extensions in Dec–Jan, 55 by
  late October.

## Methods

**Floor estimators** (`02_floor.sql`), every week, each fold of 5 (by
`hash(extension) % 5`) estimated without its own extensions:

- M0 (the current approach): the median of the reference group, with a
  distribution-free 95 % CI from order statistics.
- M1: a median regression of downloads on a restricted cubic spline (3
  knots) of log(1 + stars); the floor is the fit at 0 stars.
- M2: M1 plus "built for a current DuckDB" and log(weeks listed); the
  floor at 0 stars, built, 26 weeks listed.

**Structure and autoregression** (`03`–`05`, `08`): predict an
extension's downloads in week t from its own past and the other folds'
extensions in the same week, over 22 test weeks (2026-06-01 to
2026-10-26, 5,319 extension-weeks, 303 extensions, the same rows for every
model). AR coefficients are fitted on the weeks before June only. Models:
an additive floor plus a random walk or AR(1/2) of the rest; a
multiplicative common factor (the log median of all extensions) plus a
random walk or AR(2); no common factor; a per-extension loading on the
floor index; a per-extension elasticity to it. Metric: the absolute log
error; differences between models with a 95 % cluster bootstrap over
extensions.

**Natural experiment** (`06`, `07`): in the two captures after DuckDB
2.0.0 the reference group's downloads rose k = 12.7-fold. An extension's
jump r = s·k + (1 − s)·h gives its automated share s = (r − h)/(k − h),
with h the users' own release bump (1.0 / 1.5 / 2.0). The share of all
downloads weights each extension by its normal week (the median of the 5
captures before); 95 % bootstrap over extensions with k re-estimated in
each resample. The 1.5.0 release (k = 1.96) is the stability check.

## Results

| Comparison of mean absolute log error (A − B) | Normal weeks | 2.0 weeks |
|---|---|---|
| multiplicative + AR(2) − current additive floor | −0.20 (−0.28 to −0.14) | −0.25 (−0.36 to −0.16) |
| common factor − none (random walk) | −0.04 (−0.05 to −0.03) | −0.85 (−0.94 to −0.75) |
| AR(2) − random walk, multiplicative | −0.005 (−0.007 to −0.003) | +0.02 (+0.01 to +0.03) |
| per-extension elasticity − unit elasticity | +0.008 (+0.002 to +0.014) | +0.13 (+0.08 to +0.18) |

- The data are multiplicative: extensions move by about the same
  percentage with one common weekly factor. A single additive floor for
  every extension predicts clearly worse; about half of the no-audience
  extensions sit below it.
- Autoregression is strong but adds little: log downloads have ρ = 0.94
  (0.92 to 0.96) and a small second lag (φ₂ = 0.09, 0.05 to 0.12), yet AR(2)
  improves on a random walk by only 0.005 log units in normal weeks and
  does worse in release weeks.
- M0 and M2 agree within about 5–10 % in most weeks; M1 is lower (it
  averages in extensions without current binaries). Their intercept CIs
  are wider than M0's. In the 2.0 weeks they diverge (26 Oct: M0 12,122,
  M1 6,323).

| Automated share of all downloads | Estimate | 95 % CI |
|---|---|---|
| 2.0 natural experiment, h = 1.0 | 25.7 % | 17.2–37.3 % |
| 2.0 natural experiment, h = 1.5 | 24.0 % | 15.7–35.0 % |
| 2.0 natural experiment, h = 2.0 | 23.0 % | 14.7–33.2 % |
| M0 common floor, 14 Sep – 12 Oct 2026 | 20.6 % | – |
| M2 common floor, same weeks | 21.6 % | – |
| M1 common floor, same weeks | 16.2 % | – |

(The bootstrap medians above; the dashboards show the point estimate with
the same interval method, 23 % (15–38 %) at h = 1.5.)

## Checks and diagnostics

- Fold-out: no extension contributes to its own floor or common factor.
- Time order: AR coefficients, extension means and loadings use only
  earlier weeks.
- Per-extension shares are not identified: 53 % of the 2.0 shares fall
  outside 0–1, and 2.0 and 1.5.0 rank extensions alike only weakly
  (Spearman ρ = 0.12, p = 0.17, n = 136; compatible with no agreement).
- The assumption h moves the overall share only from 25.7 % to 23.0 %.

## Limitations

- The natural experiment assumes the 2.0 wave's automation is proportional
  to an extension's normal automation; a wave that depends on 2.0 binaries
  (extensions not built for 2.0 barely jumped) distorts per-extension shares.
- The reference group may hold some real users (a higher floor), and it is
  small before March 2026. Stars are today's, applied backwards.
- Weekly totals cannot separate steady CI in real projects from steady use,
  and downloads are not users (one per machine and DuckDB version).
- DuckDB's raw logs (user agents, IP ranges) or per-platform counts would
  resolve it.
