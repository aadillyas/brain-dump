# Extraction eval results

The fixtures (`Evals/fixtures.json`) are synthetic: 9 spoken-style dumps (6 dev, 3 holdout) written by the same author as the prompts. Treat the numbers as rough. Tuning stopped early when the owner changed scope, after 2 improvement rounds.

Run with `swift run -c release braindump-eval --model <id> [--split dev|holdout|all] [--verbose]`.
Matching: an extraction matches a gold item if its cited sentences contain the gold keywords. Precision counts every unmatched extraction as a false positive. Dates are scored only on matches with exactly the gold kind.

## Model comparison (dev: 6 fixtures, 40 gold items)

| Model | Size | Prompt version | Recall | Precision | Kind | Date | Secs (6 dumps) | tok/s |
|---|---|---|---|---|---|---|---|---|
| LFM2.5 350M | 229 MB | R0 items JSON | 68% | 57% | 56% | 70% | 17.0 | 82 |
| LFM2.5 350M | 229 MB | R2 line labels + echo | 80% | 56% | 66% | 69% | 23.3 | 96 |
| Qwen3.5 0.8B | 532 MB | R0 items JSON | 75% | 47% | 73% | 89% | 56.9 | 27 |
| **LFM2.5 1.2B Instruct** | 731 MB | R0 items JSON | 62% | 46% | 60% | 91% | 27.3 | 60 |
| **LFM2.5 1.2B Instruct** | 731 MB | **R2 line labels + echo** | **90%** | **55%** | 72% | 91% | 35.5 | 62 |
| LFM3 1.7B | 1.1 GB | R0 items JSON | 78% | 48% | 97% | 88% | 51.2 | 37 |
| Qwen3.5 2B | 1.3 GB | — | not run | | | | | |

Holdout (3 fixtures, 21 gold items), run once and never used for tuning:

| Model | Prompt | Recall | Precision | Kind | Date | Secs |
|---|---|---|---|---|---|---|
| LFM2.5 1.2B Instruct | R2 | 95% | 62% | 60% | 100% | 15.3 |
| all others | | not run | | | | |

Default: **LFM2.5 1.2B Instruct with R2**, the best measured recall/precision trade-off. LFM3 1.7B was not re-measured on R2. Its R0 kind accuracy (97%) suggests it could beat the default there.

## Rounds

- **R0, starting design.** One call per chunk, JSON `{"items":[{"lines":[..],"kind","title","when"}]}` under a per-chunk GBNF grammar, 3 few-shots. Failures: filler lines extracted ("Morning.", "Personal stuff."), past/done/other people's items, few-shot titles copied onto unrelated lines, and cited line numbers off by one.
- **R1, line labels.** The grammar forces every line in order: `N. skip` or `N. kind | title | when`. Lines under 3 words are forced to `skip`. Items whose title shares no content word with the cited line are rejected. A 4th contrastive few-shot covers done, past, someone else's job and someday. The 1.2B still put correct titles in the wrong slot, so many items were rejected: recall 60%, precision 60%.
- **R2, echo anchoring.** The grammar also forces each answer line to begin with the first 5 words of its source line (`3. Oh and I have... -> reminder | ...`), so the model always sees which line it is labeling. On the 1.2B, recall went from 60% to 90%; precision dropped to 55%.

## Known failure patterns (R2, 1.2B)

- Precision is the main gap. Narration about the past or things already done still gets labeled: "I already ordered the boots", "went for a run yesterday". The almost-empty `slow-saturday` dump gives 9 extractions for 1 gold item.
- Kind confusion: tasks labeled thought/idea ("Review Priya's pull request" -> thought).
- DateResolver (not in this layer) returns nil for "before ten", "before three", "four thirty" (gives 16:00), "end of the month", "on the first". The extractor falls back to `firstDate` and then today/undated, so timed gold items lose their time.

## Not measured

- Time for a 2,000-word dump. Extrapolating from about 6 s per 250-word dump on the 1.2B gives roughly 45-50 s. Not measured directly.
- Prefix-cache equivalence. `--check-cache` exists (it runs each fixture with and without the cache and diffs the outputs) but was not run. The cache is active: about 80% of prompt tokens are reused on hybrid models via state snapshots.
- CloudLLM: compiles, never called (no API key).
- Qwen3.5 2B: not downloaded.
