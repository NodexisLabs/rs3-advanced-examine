# rswiki-mirror

One local copy of RuneScape Wiki [Bucket](https://meta.weirdgloop.org/w/Extension:Bucket) tables,
shared by every tool that needs wiki data. Tools read `mirror.db`; only this mirror talks to the wiki.

The wiki is volunteer-run infrastructure under real strain from plugin traffic (see Cook Me Plox,
"OSRS Wiki and RuneLite are increasingly under strain from low-effort AI development", 2026-09-16).
The rules here exist so our tools never add to that.

## Use

```
python rswiki_mirror.py status                  # what is held, and since when
python rswiki_mirror.py update                  # fetch only pages changed since the last sync
python rswiki_mirror.py add <bucket>            # first fill of a new table (all its fields)
python rswiki_mirror.py full <bucket>           # complete refill; only after template changes
python rswiki_mirror.py import-cache <dir>      # load existing download caches, 0 requests
python test_mirror.py                           # tests against a fake wiki (no network)
```

```python
from rswiki_mirror import Mirror
rows = Mirror().rows("dropsline", ["page_name", "item_name", "drop_json"])
```

`rows()` raises if a field was never mirrored instead of returning blanks.

## How updates stay small

1. `list=recentchanges` since the last sync: one request per 500 changes, covering content,
   template and module namespaces.
2. Changed and new pages are re-queried in batches of 150 titles per table (`bucket.Or`, POSTed).
   Deleted pages are removed, and moved pages follow their new title.
3. Template or module edits can change rows on pages nobody edited. `update` can't see those
   rows, so it lists the edits and recommends `full <bucket>` instead of guessing.

## Request estimate

Tables held now: dropsline, item_id, npc_id, object_id, recipe, storeline (6).

| Operation | Requests | Rows transferred | When |
|---|---|---|---|
| `update` (500 pages changed) | 1 RC + 6 tables × 4 batches = **25** light | changed pages only (hundreds) | once per game update, about weekly |
| `full` on all 6 tables | **49** heavy (5,000-row pages) | ~230,000 | only when a relevant template/module changed |
| First `add` of a table | 1 schema + rows/5,000 | whole table | once per new table |

That is about 100 light requests a month at a weekly update, versus about 200 heavy ones for a
full re-download each week. The exact number of changed pages per week is not measured yet.
The first real `update` will show it, and this table will be corrected then.

## Politeness rules (in code, not just policy)

- Descriptive User-Agent with a contact address.
- At most one request per second, and `maxlag=5` on every request.
- **No automatic retries.** Any HTTP 429/5xx or maxlag error stops the run, writes it to the
  ledger and says why.
- A hard cap of 120 requests per run.
- Every request is recorded in the `ledger` table: time, endpoint, status, rows, bytes. Each run
  prints a one-line summary: requests this run / this month, and the top endpoints.

## History

- 2026-10-20: created. The six tables were imported from the Examine Data builder's download made
  that day (49 requests, logged in `examine-data/build/usage.jsonl` with 44 from an earlier run).
  About 65 more exploratory requests that day were not logged. Sync point: 2026-10-20T23:11:57Z.

## Licence

Wiki content is CC BY-NC-SA 3.0. The mirror and anything built from it are derivatives: credit the
RuneScape Wiki, non-commercial use only, same licence.
