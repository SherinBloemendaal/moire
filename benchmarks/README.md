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
| `legacy-2000.json`, `legacy-5000.json`, `legacy-10000.json` | The 1.0 engine, measured before it was removed. Its time grows with the square of the file count (sorting rebuilt a lookup table on every comparison), so 100,000 files would take about half an hour per run. |
| `engine-100k-m2max.json` | The new engine on an M2 Max (12 cores, 64 GB), 100,000 files. |
| `engine-1m-m2max.json` | The same with 1,000,000 files (about 4.7 GB), past what macOS keeps in its file cache. |
| `baseline-ci.json` | The CI baseline, from the `benchmark` job on GitHub (Apple M1, virtual, 3 cores). A run fails when a scenario of 0.5 s or more takes over 50% longer; shorter ones vary too much on those machines (the same 0.1 s scenario measured from 0.06 s to 0.23 s). |

`MOIRE_FOLDER_THREADS` and `MOIRE_CONTENT_THREADS` override the thread counts, for tuning.
