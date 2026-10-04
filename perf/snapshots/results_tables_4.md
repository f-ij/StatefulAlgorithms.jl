
### cold: compile time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 26,468.2 | 12,401.3 | 14,157.9 | 12,213.7 | 0.461 × |
| 2 expand macro: @CompositeAlgorithm | 49,608.0 | 50,414.0 | 48,816.7 | 49,339.8 | 0.995 × |
| 2 expand macro: nested @Routine | 18,371.1 | 17,454.7 | 18,286.4 | 17,939.8 | 0.977 × |
| 3 construct: @CompositeAlgorithm | 479,014.4 | 498,766.1 | 105,255.9 | 105,195.8 | 0.220 × |
| 3 construct: nested @Routine | 48,156.7 | 47,779.2 | 25,489.5 | 24,705.9 | 0.513 × |
| 4 resolve | 838,695.1 | 590,395.0 | 635,106.7 | 678,234.7 | 0.809 × |
| **total** | **1,460,313.5** | **1,217,210.3** | **847,113.1** | **887,629.7** | 0.608 × |

### warm, same uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.2 | 0.1 | 0.2 | 0.2 | 1.000 × |
| 2 expand macro: nested @Routine | 0.2 | 0.2 | 0.2 | 0.2 | 1.000 × |
| 3 construct: @CompositeAlgorithm | 15,102.6 | 16,436.5 | 0.0 | 0.0 | 0.000 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | 0.0 | — |
| **total** | **15,103.0** | **16,436.8** | **0.4** | **0.4** | 0.000 × |

### warm, same uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.0 | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: nested @Routine | 0.1 | 0.0 | 0.0 | 0.1 | 2.000 × |
| 3 construct: @CompositeAlgorithm | 0.2 | 0.2 | 0.0 | 0.0 | 0.000 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | 0.0 | — |
| **total** | **0.2** | **0.2** | **0.0** | **0.1** | 0.500 × |

### same shape, new uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.2 | 0.1 | 0.1 | 0.2 | 1.000 × |
| 2 expand macro: nested @Routine | 0.1 | 0.1 | 0.1 | 0.2 | 2.000 × |
| 3 construct: @CompositeAlgorithm | 185,299.3 | 196,632.7 | 37,538.8 | 37,770.8 | 0.204 × |
| 3 construct: nested @Routine | 34,849.4 | 33,175.5 | 10,824.2 | 11,110.4 | 0.319 × |
| 4 resolve | 540,153.0 | 308,754.7 | 318,135.9 | 2,172.0 | 0.004 × |
| **total** | **760,302.0** | **538,563.1** | **366,499.1** | **51,053.6** | 0.067 × |

### same shape, new uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.2 | 0.2 | 0.2 | 0.2 | 1.000 × |
| 2 expand macro: nested @Routine | 0.3 | 0.2 | 0.2 | 0.2 | 0.667 × |
| 3 construct: @CompositeAlgorithm | 194,960.4 | 189,025.1 | 37,961.2 | 40,729.2 | 0.209 × |
| 3 construct: nested @Routine | 34,881.7 | 33,682.2 | 10,851.0 | 11,024.2 | 0.316 × |
| 4 resolve | 514,745.5 | 312,171.3 | 318,798.8 | 2,366.0 | 0.005 × |
| **total** | **744,588.1** | **534,879.0** | **367,611.3** | **54,119.8** | 0.073 × |

### cold: wall time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 26,821.0 | 12,740.8 | 14,566.4 | 12,559.8 | 0.468 × |
| 2 expand macro: @CompositeAlgorithm | 51,001.6 | 51,824.8 | 50,185.7 | 50,698.0 | 0.994 × |
| 2 expand macro: nested @Routine | 19,328.0 | 18,309.3 | 19,132.0 | 18,811.2 | 0.973 × |
| 3 construct: @CompositeAlgorithm | 483,323.8 | 503,407.3 | 108,916.7 | 108,861.3 | 0.225 × |
| 3 construct: nested @Routine | 49,685.7 | 49,291.7 | 27,160.1 | 26,329.6 | 0.530 × |
| 4 resolve | 839,692.6 | 590,885.9 | 635,579.7 | 678,892.3 | 0.809 × |
| **total** | **1,469,852.7** | **1,226,459.8** | **855,540.6** | **896,152.2** | 0.610 × |

### warm, same uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 927.2 | 927.8 | 925.5 | 925.7 | 0.998 × |
| 2 expand macro: nested @Routine | 458.0 | 464.5 | 455.0 | 490.5 | 1.071 × |
| 3 construct: @CompositeAlgorithm | 17,619.9 | 18,883.5 | 2,460.6 | 2,528.3 | 0.143 × |
| 3 construct: nested @Routine | 1,051.0 | 1,046.4 | 1,044.0 | 1,048.0 | 0.997 × |
| 4 resolve | 215.6 | 146.2 | 143.7 | 170.8 | 0.792 × |
| **total** | **20,271.7** | **21,468.4** | **5,028.8** | **5,163.3** | 0.255 × |

### warm, same uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 842.3 | 839.7 | 852.9 | 855.3 | 1.015 × |
| 2 expand macro: nested @Routine | 359.3 | 363.0 | 356.2 | 374.6 | 1.042 × |
| 3 construct: @CompositeAlgorithm | 2,138.6 | 2,128.6 | 2,112.4 | 2,140.2 | 1.001 × |
| 3 construct: nested @Routine | 914.0 | 923.3 | 936.0 | 944.0 | 1.033 × |
| 4 resolve | 125.2 | 103.1 | 100.2 | 129.9 | 1.038 × |
| **total** | **4,379.5** | **4,357.8** | **4,357.8** | **4,444.0** | 1.015 × |

### same shape, new uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 230.2 | 224.6 | 230.0 | 231.8 | 1.007 × |
| 2 expand macro: @CompositeAlgorithm | 975.0 | 980.5 | 917.5 | 904.5 | 0.928 × |
| 2 expand macro: nested @Routine | 576.8 | 578.5 | 396.1 | 384.0 | 0.666 × |
| 3 construct: @CompositeAlgorithm | 188,519.6 | 199,719.2 | 40,540.1 | 40,803.6 | 0.216 × |
| 3 construct: nested @Routine | 35,988.5 | 34,324.9 | 11,947.4 | 12,265.0 | 0.341 × |
| 4 resolve | 540,962.8 | 309,193.0 | 318,541.4 | 2,381.2 | 0.004 × |
| **total** | **767,252.9** | **545,020.7** | **372,572.5** | **56,970.1** | 0.074 × |

### same shape, new uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | fix-types (µs) | fix-construction (µs) | perf (µs) | perf vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 248.7 | 238.2 | 241.6 | 238.0 | 0.957 × |
| 2 expand macro: @CompositeAlgorithm | 981.1 | 975.4 | 955.0 | 983.0 | 1.002 × |
| 2 expand macro: nested @Routine | 436.4 | 435.6 | 430.2 | 429.7 | 0.985 × |
| 3 construct: @CompositeAlgorithm | 198,053.1 | 194,399.4 | 40,973.4 | 43,846.7 | 0.221 × |
| 3 construct: nested @Routine | 36,064.9 | 34,860.2 | 12,039.9 | 12,195.5 | 0.338 × |
| 4 resolve | 515,510.7 | 312,604.7 | 319,222.5 | 2,621.7 | 0.005 × |
| **total** | **751,294.9** | **543,513.6** | **373,862.7** | **60,314.5** | 0.080 × |
