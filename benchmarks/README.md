# Benchmarks

`moire-bench` builds fixed pairs of folders in `~/Library/Caches/moire-bench` and times the folder
engine on them. Every scenario also checks the engine's answer against the changes the generator
made, so a fast but wrong engine fails.

```bash
swift build -c release --product moire-bench
.build/release/moire-bench run --files 100000 --large
.build/release/moire-bench clean
```

The trees are mostly small text files (about 4.7 KB on average), 100 per folder. The right side is
an APFS clone of the left, so it costs almost no extra disk space. Timings are taken with a warm
file cache: the first, untimed run reads everything once.

| File | What it holds |
| --- | --- |
| `legacy-2000.json`, `legacy-5000.json`, `legacy-10000.json` | The 1.0 engine. Its time grows with the square of the file count (sorting rebuilt a lookup table on every comparison), so 100,000 files would take about half an hour per run. |
| `engine-100k-m2max.json` | The new engine on an M2 Max (12 cores, 64 GB), 100,000 files and 16 files of 64 MB. |
| `baseline-ci.json` | The CI baseline, taken from a run of the `benchmark` job on GitHub. |

`MOIRE_FOLDER_THREADS` and `MOIRE_CONTENT_THREADS` override the thread counts, for tuning.
