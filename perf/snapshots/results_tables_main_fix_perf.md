
### cold: compile time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 28,829.8 | 13,897.7 | 14,800.6 | 0.513 × |
| 2 expand macro: @CompositeAlgorithm | 55,321.9 | 55,223.8 | 56,778.8 | 1.026 × |
| 2 expand macro: nested @Routine | 20,437.1 | 20,566.8 | 20,993.6 | 1.027 × |
| 3 construct: @CompositeAlgorithm | 501,343.0 | 558,423.4 | 521,089.3 | 1.039 × |
| 3 construct: nested @Routine | 54,041.3 | 54,218.2 | 54,594.9 | 1.010 × |
| 4 resolve | 946,961.8 | 693,756.7 | 699,902.0 | 0.739 × |
| **total** | **1,606,934.9** | **1,396,086.6** | **1,368,159.2** | 0.851 × |

### warm, same uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.3 | 0.2 | 0.2 | 0.667 × |
| 2 expand macro: nested @Routine | 0.4 | 0.3 | 0.3 | 0.750 × |
| 3 construct: @CompositeAlgorithm | 11,976.7 | 13,956.8 | 16,892.0 | 1.410 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | — |
| **total** | **11,977.4** | **13,957.3** | **16,892.5** | 1.410 × |

### warm, same uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.1 | 0.1 | 0.1 | 1.000 × |
| 2 expand macro: nested @Routine | 0.1 | 0.2 | 0.2 | 1.500 × |
| 3 construct: @CompositeAlgorithm | 0.5 | 0.8 | 0.6 | 1.333 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | — |
| **total** | **0.7** | **1.1** | **0.8** | 1.308 × |

### same shape, new uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.3 | 0.3 | 0.2 | 0.667 × |
| 2 expand macro: nested @Routine | 0.2 | 0.2 | 0.2 | 1.000 × |
| 3 construct: @CompositeAlgorithm | 207,479.4 | 225,685.7 | 225,315.8 | 1.086 × |
| 3 construct: nested @Routine | 40,553.8 | 41,353.3 | 41,783.5 | 1.030 × |
| 4 resolve | 570,304.0 | 356,272.6 | 2,749.1 | 0.005 × |
| **total** | **818,337.7** | **623,312.1** | **269,848.8** | 0.330 × |

### same shape, new uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.3 | 0.3 | 0.2 | 0.833 × |
| 2 expand macro: nested @Routine | 0.3 | 0.2 | 0.2 | 0.667 × |
| 3 construct: @CompositeAlgorithm | 221,860.5 | 212,976.8 | 221,591.0 | 0.999 × |
| 3 construct: nested @Routine | 39,898.5 | 39,762.2 | 40,602.5 | 1.018 × |
| 4 resolve | 553,103.9 | 351,306.8 | 2,531.0 | 0.005 × |
| **total** | **814,863.5** | **604,046.4** | **264,724.9** | 0.325 × |

### cold: wall time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 29,203.1 | 14,269.9 | 15,264.9 | 0.523 × |
| 2 expand macro: @CompositeAlgorithm | 56,839.7 | 56,744.3 | 58,366.4 | 1.027 × |
| 2 expand macro: nested @Routine | 21,454.4 | 21,544.4 | 22,020.5 | 1.026 × |
| 3 construct: @CompositeAlgorithm | 506,248.0 | 563,636.9 | 526,096.8 | 1.039 × |
| 3 construct: nested @Routine | 55,507.0 | 55,816.6 | 56,327.5 | 1.015 × |
| 4 resolve | 948,465.1 | 694,408.5 | 700,687.2 | 0.739 × |
| **total** | **1,617,717.3** | **1,406,420.6** | **1,378,763.3** | 0.852 × |

### warm, same uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 899.2 | 950.6 | 938.0 | 1.043 × |
| 2 expand macro: nested @Routine | 479.1 | 491.3 | 487.5 | 1.018 × |
| 3 construct: @CompositeAlgorithm | 14,582.2 | 16,696.5 | 19,528.8 | 1.339 × |
| 3 construct: nested @Routine | 1,047.8 | 1,087.6 | 1,083.5 | 1.034 × |
| 4 resolve | 242.2 | 195.7 | 235.9 | 0.974 × |
| **total** | **17,250.5** | **19,421.7** | **22,273.7** | 1.291 × |

### warm, same uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 888.0 | 913.9 | 894.1 | 1.007 × |
| 2 expand macro: nested @Routine | 391.6 | 377.2 | 399.2 | 1.019 × |
| 3 construct: @CompositeAlgorithm | 2,238.2 | 2,261.8 | 2,268.1 | 1.013 × |
| 3 construct: nested @Routine | 963.2 | 997.9 | 1,005.8 | 1.044 × |
| 4 resolve | 154.2 | 124.2 | 150.1 | 0.974 × |
| **total** | **4,635.2** | **4,675.1** | **4,717.4** | 1.018 × |

### same shape, new uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 256.2 | 253.8 | 277.3 | 1.082 × |
| 2 expand macro: @CompositeAlgorithm | 992.0 | 1,025.7 | 1,023.5 | 1.032 × |
| 2 expand macro: nested @Routine | 613.6 | 652.7 | 631.5 | 1.029 × |
| 3 construct: @CompositeAlgorithm | 211,044.1 | 229,326.7 | 229,349.3 | 1.087 × |
| 3 construct: nested @Routine | 41,802.4 | 42,609.0 | 43,100.5 | 1.031 × |
| 4 resolve | 571,256.2 | 356,843.3 | 3,000.3 | 0.005 × |
| **total** | **825,964.5** | **630,711.2** | **277,382.4** | 0.336 × |

### same shape, new uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | fix (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 273.4 | 270.9 | 248.8 | 0.910 × |
| 2 expand macro: @CompositeAlgorithm | 1,008.7 | 1,004.5 | 1,025.7 | 1.017 × |
| 2 expand macro: nested @Routine | 449.8 | 450.9 | 443.8 | 0.987 × |
| 3 construct: @CompositeAlgorithm | 225,329.4 | 216,520.8 | 225,181.7 | 0.999 × |
| 3 construct: nested @Routine | 41,267.2 | 41,038.5 | 42,004.8 | 1.018 × |
| 4 resolve | 554,093.0 | 351,887.2 | 2,853.5 | 0.005 × |
| **total** | **822,421.6** | **611,172.6** | **271,758.2** | 0.330 × |
