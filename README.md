# abap-performance-patterns

**Before/after implementations of the optimisations that fixed slow production reports — `FOR ALL ENTRIES` done safely, parallel cursor, hashed-table lookups — plus the checklist used to find the problem in the first place.**

See [`zcl_perf_patterns.clas.abap`](zcl_perf_patterns.clas.abap): every pattern is a pair of methods, `*_slow` (what was in production) and `*_fast` (what replaced it).

## The patterns

| # | Symptom | Fix | Complexity |
|---|---|---|---|
| 1 | `SELECT` inside `LOOP` — thousands of round trips (N+1) | One `FOR ALL ENTRIES` with three guards: non-empty driver table, de-duplicated keys, full key in the field list | N DB calls → 1 (per block) |
| 2 | `LOOP … LOOP … WHERE` over two large tables | **Parallel cursor**: sort both by the join key, `BINARY SEARCH` to position, inner loop `FROM idx` and `EXIT` on key change | O(n·m) → O(n+m) |
| 3 | `READ TABLE … WITH KEY` on a standard table inside a loop | `HASHED TABLE` with `UNIQUE KEY` + `WITH TABLE KEY` (or `SORTED TABLE` + `BINARY SEARCH` for non-unique keys) | O(n) per lookup → O(1) |

Two further rules that are not code but matter as much:

4. **Select only the fields you use.** `SELECT *` on wide tables (`VBAP`, `EKPO`, `MSEG`) is often the single largest cost in a report. On HANA a narrow field list is what lets the column store skip whole columns.
5. **Push aggregation to the database.** `SUM( )` / `GROUP BY` in SQL or a CDS view beats fetching everything and summing in ABAP — see the AMDP example in [abap-cds-amdp-odata-rap-examples](https://github.com/sunny-bhanu/abap-cds-amdp-odata-rap-examples).

## The three `FOR ALL ENTRIES` traps

1. **Empty driver table ⇒ full-table select.** Not a warning, not an error — a `WHERE` clause that silently disappears. Always `IF lt_keys IS INITIAL. RETURN. ENDIF.` first.
2. **Duplicate rows in the result are removed implicitly.** If the field list does not contain the full primary key, legitimately identical rows (two items with the same quantity) collapse into one. Either select the key or use `SELECT DISTINCT` consciously.
3. **Large driver tables are split into blocks** (`rsdb/max_blocking_factor`). Duplicates in the driver table multiply the blocks for nothing — `SORT` + `DELETE ADJACENT DUPLICATES` first.

## How to find the problem

| Tool | Use it for |
|---|---|
| **ST05** (SQL trace) | Identical statements repeated thousands of times → pattern 1. Sort by *Duration* and *Executions*. |
| **SAT / SE30** (runtime analysis) | Time in ABAP vs. DB; a hit list dominated by `LOOP AT` / `READ TABLE` → patterns 2 and 3. |
| **ST12** | Both at once, with call-stack attribution. |
| **ATC** performance checks (`CL_CI_TEST_…`) | Catches nested selects and `SELECT *` in code review, before it reaches production. |

## Rules of thumb

- Measure first. The slowest statement is rarely the one that *looks* slow.
- A `SORT` followed by `BINARY SEARCH` is almost always cheaper than a hashed table **if the table is read once**; hashed wins when the same table is read many times.
- `LOOP AT … ASSIGNING FIELD-SYMBOL` instead of `INTO` avoids copying wide structures — small per row, large over a million rows.
- `STATICS` buffers inside a method survive for the internal session — ideal for expensive FM calls like `READ_TEXT` inside list BAdIs (see [abap-badi-me2n-longtext-column](https://github.com/sunny-bhanu/abap-badi-me2n-longtext-column)).

---
*Written as generic reference material. No client data or client-specific logic.* MIT License — see [LICENSE](LICENSE).
