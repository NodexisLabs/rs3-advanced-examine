"""Tests for rswiki_mirror against a fake wiki (no network).

Run: python test_mirror.py
"""

import json
import re
import sys
import tempfile
from pathlib import Path

import rswiki_mirror as rm

rm.REQUEST_GAP_S = 0
failures = []


def check(label, ok, detail=""):
    print(("PASS " if ok else "FAIL ") + label + (f"  ({detail})" if detail else ""))
    if not ok:
        failures.append(label)


class FakeWiki:
    """Answers recentchanges and Bucket queries from in-memory tables."""

    def __init__(self, tables, changes, fail_with=None):
        self.tables, self.changes, self.fail_with = tables, changes, fail_with
        self.calls = []

    def request(self, params, post=False):
        self.calls.append((params.get("action"), post))
        if self.fail_with:
            return self.fail_with, b"error code: 502"
        if params["action"] == "query":
            return 200, json.dumps({"query": {"recentchanges": self.changes}}).encode()
        q = params["query"]
        bucket = re.match(r"bucket\('(\w+)'\)", q).group(1)
        titles = set(re.findall(r"\{'page_name','((?:[^'\\]|\\.)*)'\}", q))
        titles = {t.replace("\\'", "'") for t in titles}
        rows = [r for r in self.tables.get(bucket, []) if not titles or r["page_name"] in titles]
        return 200, json.dumps({"bucket": rows}).encode()


with tempfile.TemporaryDirectory() as tmp:
    tmp = Path(tmp)
    cache = tmp / "cache"
    cache.mkdir()
    (cache / "dropsline.json").write_text(json.dumps({
        "fetched": "2026-10-20T23:09:13+00:00", "fields": ["page_name", "item_name"],
        "rows": [{"page_name": "Cow", "item_name": "Raw beef"},
                 {"page_name": "Goblin", "item_name": "Bones"},
                 {"page_name": "Old page", "item_name": "Junk"},
                 {"page_name": "Moved from", "item_name": "Thing"}]}))
    (cache / "legacy.json").write_text(json.dumps({"fetched": "2026-10-20T23:00:00+00:00", "rows": []}))

    # 1. Import costs nothing and sets the sync point.
    wiki = FakeWiki({}, [])
    m = rm.Mirror(tmp / "m.db", transport=wiki)
    m.import_cache(cache)
    check("import makes no requests", wiki.calls == [])
    check("sync point is the fetch time", m.synced_to() == "2026-10-20T23:09:13Z", m.synced_to())
    check("rows readable", len(m.rows("dropsline", ["page_name", "item_name"])) == 4)
    try:
        m.rows("dropsline", ["drop_json"])
        check("missing field fails loudly", False)
    except KeyError as e:
        check("missing field fails loudly", "lacks fields" in str(e))

    # 2. Update: edit Cow, new page, delete Old page, move a page, template edit.
    wiki = FakeWiki(
        {"dropsline": [{"page_name": "Cow", "item_name": "Raw beef"},
                       {"page_name": "Cow", "item_name": "Cowhide"},
                       {"page_name": "New monster", "item_name": "Shiny"},
                       {"page_name": "Moved to", "item_name": "Thing"},
                       {"page_name": "Goblin", "item_name": "Bones"}]},
        [{"type": "edit", "ns": 0, "title": "Cow"},
         {"type": "new", "ns": 0, "title": "New monster"},
         {"type": "log", "ns": 0, "title": "Old page", "logtype": "delete", "logaction": "delete"},
         {"type": "log", "ns": 0, "title": "Moved from", "logtype": "move", "logaction": "move",
          "logparams": {"target_title": "Moved to"}},
         {"type": "edit", "ns": 828, "title": "Module:DropsLine"},
         {"type": "edit", "ns": 0, "title": "O'Brien's page"}])
    m.transport = wiki
    m.run_requests = 0
    report = m.update()
    pages = sorted({r["page_name"] for r in m.rows("dropsline", ["page_name"])})
    check("edited page refreshed", sum(1 for r in m.rows("dropsline", ["page_name"]) if r["page_name"] == "Cow") == 2)
    check("new page added", "New monster" in pages)
    check("deleted page removed", "Old page" not in pages)
    check("moved page follows its new title", "Moved to" in pages and "Moved from" not in pages, str(pages))
    check("unchanged page untouched", "Goblin" in pages)
    check("template edits reported", report["templates"] == ["Module:DropsLine"])
    check("one RC request + one bucket query", len(wiki.calls) == 2, str(wiki.calls))
    check("bucket queries are POSTed", wiki.calls[1] == ("bucket", True))
    check("sync point advanced", m.synced_to() > "2026-10-20T23:09:13Z", m.synced_to())

    # 3. A wiki error stops the run, is ledgered, and is not retried.
    wiki = FakeWiki({}, [], fail_with=502)
    m.transport = wiki
    m.run_requests = 0
    try:
        m.update()
        check("502 stops the run", False)
    except rm.WikiError as e:
        check("502 stops the run", "HTTP 502" in str(e), str(e))
    check("no retry after error", len(wiki.calls) == 1)
    last = m.db.execute("SELECT status FROM ledger ORDER BY rowid DESC LIMIT 1").fetchone()[0]
    check("error recorded in ledger", last.startswith("502"), last)
    print(m.ledger_summary())
    m.close()

print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
