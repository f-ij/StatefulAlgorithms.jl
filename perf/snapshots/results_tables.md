
### cold: compile time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 29,208.7 | 13,363.4 | 13,535.2 | 0.463 × |
| 2 expand macro: @CompositeAlgorithm | 54,567.0 | 53,298.5 | 54,485.5 | 0.999 × |
| 2 expand macro: nested @Routine | 19,148.7 | 18,484.1 | 20,099.3 | 1.050 × |
| 3 construct: @CompositeAlgorithm | 497,250.1 | 521,288.3 | 523,101.4 | 1.052 × |
| 3 construct: nested @Routine | 51,691.9 | 48,998.5 | 53,761.9 | 1.040 × |
| 4 resolve | 925,797.8 | 730,861.2 | 632,954.2 | 0.684 × |
| **total** | **1,577,664.2** | **1,386,294.0** | **1,297,937.5** | 0.823 × |

### warm, same uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.2 | 0.2 | 0.2 | 1.000 × |
| 2 expand macro: nested @Routine | 0.3 | 0.3 | 0.3 | 1.000 × |
| 3 construct: @CompositeAlgorithm | 11,705.7 | 16,871.5 | 15,572.8 | 1.330 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | — |
| **total** | **11,706.2** | **16,872.0** | **15,573.3** | 1.330 × |

### warm, same uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 0.1 | 0.1 | 0.0 | 0.000 × |
| 2 expand macro: nested @Routine | 0.1 | 0.1 | 0.1 | 1.000 × |
| 3 construct: @CompositeAlgorithm | 0.4 | 0.3 | 0.2 | 0.625 × |
| 3 construct: nested @Routine | 0.0 | 0.0 | 0.0 | — |
| 4 resolve | 0.0 | 0.0 | 0.0 | — |
| **total** | **0.6** | **0.6** | **0.3** | 0.583 × |

### same shape, new uuids (1st re-run): compile time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.3 | 0.2 | 0.2 | 0.667 × |
| 2 expand macro: nested @Routine | 0.3 | 0.1 | 0.1 | 0.333 × |
| 3 construct: @CompositeAlgorithm | 201,928.9 | 218,020.0 | 207,142.7 | 1.026 × |
| 3 construct: nested @Routine | 38,740.0 | 37,648.7 | 35,670.5 | 0.921 × |
| 4 resolve | 547,108.9 | 396,486.5 | 319,896.3 | 0.585 × |
| **total** | **787,778.4** | **652,155.5** | **562,709.8** | 0.714 × |

### same shape, new uuids (re-runs 2-5): compile time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 0.0 | 0.0 | 0.0 | — |
| 2 expand macro: @CompositeAlgorithm | 0.3 | 0.2 | 0.2 | 0.667 × |
| 2 expand macro: nested @Routine | 0.3 | 0.2 | 0.3 | 1.000 × |
| 3 construct: @CompositeAlgorithm | 205,582.4 | 201,412.6 | 205,355.9 | 0.999 × |
| 3 construct: nested @Routine | 38,221.4 | 36,624.2 | 36,546.2 | 0.956 × |
| 4 resolve | 537,037.3 | 404,143.2 | 335,359.7 | 0.624 × |
| **total** | **780,841.7** | **642,180.4** | **577,262.3** | 0.739 × |

### cold: wall time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 29,593.5 | 13,735.8 | 13,948.0 | 0.471 × |
| 2 expand macro: @CompositeAlgorithm | 56,087.4 | 54,838.8 | 55,971.9 | 0.998 × |
| 2 expand macro: nested @Routine | 20,076.4 | 19,390.5 | 21,160.5 | 1.054 × |
| 3 construct: @CompositeAlgorithm | 501,932.1 | 525,797.4 | 527,808.3 | 1.052 × |
| 3 construct: nested @Routine | 53,318.6 | 50,540.6 | 55,402.5 | 1.039 × |
| 4 resolve | 927,112.1 | 731,821.6 | 633,543.9 | 0.683 × |
| **total** | **1,588,120.1** | **1,396,124.7** | **1,307,835.1** | 0.824 × |

### warm, same uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 932.5 | 1,128.9 | 933.7 | 1.001 × |
| 2 expand macro: nested @Routine | 472.3 | 470.0 | 471.4 | 0.998 × |
| 3 construct: @CompositeAlgorithm | 14,354.4 | 19,156.8 | 18,113.8 | 1.262 × |
| 3 construct: nested @Routine | 1,037.5 | 1,049.5 | 1,076.5 | 1.038 × |
| 4 resolve | 228.3 | 219.8 | 160.1 | 0.701 × |
| **total** | **17,025.0** | **22,025.0** | **20,755.5** | 1.219 × |

### warm, same uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 2 expand macro: @CompositeAlgorithm | 866.6 | 870.2 | 872.1 | 1.006 × |
| 2 expand macro: nested @Routine | 379.7 | 386.4 | 369.6 | 0.973 × |
| 3 construct: @CompositeAlgorithm | 2,236.2 | 2,206.8 | 2,170.6 | 0.971 × |
| 3 construct: nested @Routine | 947.5 | 946.1 | 937.7 | 0.990 × |
| 4 resolve | 141.1 | 133.3 | 106.7 | 0.756 × |
| **total** | **4,571.1** | **4,542.9** | **4,456.7** | 0.975 × |

### same shape, new uuids (1st re-run): wall time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 265.0 | 442.2 | 246.3 | 0.929 × |
| 2 expand macro: @CompositeAlgorithm | 1,009.8 | 1,031.3 | 1,004.8 | 0.995 × |
| 2 expand macro: nested @Routine | 608.0 | 389.6 | 595.0 | 0.979 × |
| 3 construct: @CompositeAlgorithm | 205,471.2 | 221,424.7 | 210,350.5 | 1.024 × |
| 3 construct: nested @Routine | 39,998.3 | 38,848.7 | 36,819.6 | 0.921 × |
| 4 resolve | 547,966.3 | 397,078.5 | 320,355.1 | 0.585 × |
| **total** | **795,318.6** | **659,215.0** | **569,371.3** | 0.716 × |

### same shape, new uuids (re-runs 2-5): wall time (µs, median)

| Phase | main (µs) | inference fix (µs) | route fix (µs) | route fix vs main (×) |
|---|---|---|---|---|
| 1 create Unique handles | 265.9 | 261.0 | 260.0 | 0.978 × |
| 2 expand macro: @CompositeAlgorithm | 1,001.5 | 1,016.2 | 1,002.0 | 1.001 × |
| 2 expand macro: nested @Routine | 461.4 | 448.6 | 440.3 | 0.954 × |
| 3 construct: @CompositeAlgorithm | 208,997.2 | 204,990.5 | 208,800.2 | 0.999 × |
| 3 construct: nested @Routine | 39,467.7 | 37,859.4 | 37,812.1 | 0.958 × |
| 4 resolve | 537,899.8 | 404,756.1 | 335,832.2 | 0.624 × |
| **total** | **788,093.6** | **649,331.8** | **584,146.9** | 0.741 × |
