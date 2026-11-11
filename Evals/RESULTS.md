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

## Apple on-device model vs LFM3 1.7B (2026-11-12)

M2, 8 GB, macOS 27. All 9 fixtures (61 gold items), both on the R2 line-label prompt. Apple's model runs through the
Foundation Models framework with a runtime guided-generation schema that mirrors the R2 grammar (one entry per line,
echo of the first words first). Run with `--model apple`.

| Model | Recall | Precision | Kind | Date | Secs (9 dumps) | Download |
|---|---|---|---|---|---|---|
| LFM3 1.7B (R2) | 98% | 62% | 85% | 90% | 99 | 1.1 GB |
| Apple, LinePrompt as-is, 110-word chunks | 90% | 81% | 95% | 87% | 166 | 0 |
| **Apple, tuned instructions, 220-word / 16-line chunks** | 89% | 83% | 98% | 88% | 151 | 0 |

Apple tuning (dev only, then holdout once): dropping the echo cost 15-30 points of recall; leaving the schema out of the
prompt broke parsing; bigger chunks were +1 dev hit and ~10% faster. The tuned instructions (thoughts spelled out,
wishes named as skips) made no measurable difference beyond kind accuracy. Holdout for the final config: recall 81%,
precision 94% (was 90% / 83% untuned). With 61 items these differences are within noise.

Failure patterns: Apple misses thoughts (feelings and worries with nothing to do) and saves someday wishes as ideas.
LFM3 finds almost everything but over-extracts (8 items for 1 on `slow-saturday`).

## Categories: To-do / Event / Idea / Reflection (2026-11-12)

Gold relabelled: task and reminder → todo (or event for scheduled occurrences), thought → reflection; undated todos
no longer default to today. 61 items: 40 todo, 10 reflection, 9 idea, 2 event. Prompt, grammar and Apple schema are
generated from the category list.

| Model | Recall | Precision | Kind | Date | Secs (9 dumps) |
|---|---|---|---|---|---|
| LFM3 1.7B | 100% | 64% | 97% | 87% | 101 |
| Apple (220-word chunks) | 85% | 85% | 100% | 88% | 231 |
| **Apple + fallback titles** | **98%** | 76% | **100%** | 89% | 216 |

Apple left titles empty on 22 labelled lines (mostly reflections), which the validator rejected. Untitled labelled lines
now keep their label and borrow the line's first words as a low-confidence title. Apple is ~2x slower than LFM3 on this
prompt (longer instructions with per-category examples); worth profiling.
