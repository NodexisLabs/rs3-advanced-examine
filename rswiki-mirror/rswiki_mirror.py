"""rswiki-mirror: one local copy of RuneScape Wiki Bucket tables for every tool.

Every project that needs wiki data reads from this mirror instead of querying
the wiki itself. The mirror talks to the wiki only when told to, keeps every
request in a ledger, and refreshes by fetching just the pages that changed.

    python rswiki_mirror.py status
    python rswiki_mirror.py import-cache <dir>      # load builder cache JSONs (0 requests)
    python rswiki_mirror.py add <bucket> [--fields a,b,c]   # fill (or widen) a table, all fields by default
    python rswiki_mirror.py update                  # pages changed since the last sync only
    python rswiki_mirror.py full <bucket>           # complete refill (rarely: template changes)
    python rswiki_mirror.py ledger                  # request totals by endpoint and month

From Python:
    from rswiki_mirror import Mirror
    rows = Mirror().rows("dropsline", ["page_name", "item_name", "drop_json"])

Politeness rules built in:
  - descriptive User-Agent with a contact address;
  - one request at a time with a gap, `maxlag=5` on every request;
  - no automatic retries: any 429/5xx/maxlag error stops the run and says why;
  - a hard cap per run, and every request recorded in the ledger table.

Known limit: when a wiki template or module changes, Bucket rows can change on
many pages without those pages being edited. `update` cannot see that; it
lists such template/module edits and recommends `full` instead of guessing.
"""

import argparse
import datetime as dt
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://runescape.wiki/api.php"
# Contact goes in the User-Agent so wiki admins can reach whoever runs the mirror.
# Set RSWIKI_CONTACT (an email or URL) to your own; the default points at this repo.
USER_AGENT = "NodexisLabs-rswiki-mirror/0.1 (%s)" % os.environ.get(
    "RSWIKI_CONTACT", "+https://github.com/NodexisLabs/rs3-advanced-examine")
DB_PATH = Path(__file__).resolve().parent / "mirror.db"

REQUEST_GAP_S = 1.0       # one request a second at most
MAX_REQUESTS_PER_RUN = 120
PAGE_SIZE = 5000          # Bucket's maximum limit
TITLES_PER_QUERY = 150    # page names OR'd into one POSTed Bucket query
OR_FN = "bucket.Or"       # Bucket's OR combinator as named inside an API query string
RC_MAX_AGE = dt.timedelta(days=60)   # recent changes older than this may be gone

# Content namespaces whose edits change Bucket rows directly, and the
# template/module namespaces whose edits can change rows without an edit.
NS_CONTENT = 0
NS_TEMPLATE, NS_MODULE = 10, 828


def utc_now():
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(t):
    return t.strftime("%Y-%m-%dT%H:%M:%SZ")


class WikiError(RuntimeError):
    """The wiki refused or failed a request; the run stops rather than retrying."""


# --------------------------------------------------------------------------
# Transport: the only code that talks to the network
# --------------------------------------------------------------------------
class HttpTransport:
    def request(self, params, post=False):
        params = {**params, "format": "json", "maxlag": "5"}
        data = urllib.parse.urlencode(params).encode() if post else None
        url = API if post else API + "?" + urllib.parse.urlencode(params)
        req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return resp.status, raw
        except urllib.error.HTTPError as e:
            return e.code, e.read()


# --------------------------------------------------------------------------
# The mirror
# --------------------------------------------------------------------------
class Mirror:
    def __init__(self, db_path=DB_PATH, transport=None):
        self.db = sqlite3.connect(db_path)
        self.transport = transport or HttpTransport()
        self.run_requests = 0
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS rows (bucket TEXT, page_name TEXT, data TEXT);
            CREATE INDEX IF NOT EXISTS rows_bucket_page ON rows (bucket, page_name);
            CREATE TABLE IF NOT EXISTS buckets (
                bucket TEXT PRIMARY KEY, fields TEXT, filled_at TEXT, row_count INTEGER);
            CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE IF NOT EXISTS ledger (
                time TEXT, endpoint TEXT, status TEXT, rows INTEGER, bytes INTEGER, detail TEXT);
        """)

    def close(self):
        self.db.close()

    # ---- small helpers ----------------------------------------------------
    def meta(self, key, value=None):
        if value is None:
            row = self.db.execute("SELECT value FROM meta WHERE key=?", (key,)).fetchone()
            return row[0] if row else None
        self.db.execute("INSERT OR REPLACE INTO meta VALUES (?,?)", (key, value))
        self.db.commit()

    def tracked(self):
        """{bucket: [fields]} for every bucket the mirror holds."""
        return {b: json.loads(f) for b, f in self.db.execute("SELECT bucket, fields FROM buckets")}

    def _call(self, endpoint, params, post=False):
        """One wiki request: capped, spaced, ledgered, never retried."""
        if self.run_requests >= MAX_REQUESTS_PER_RUN:
            raise WikiError(f"request cap {MAX_REQUESTS_PER_RUN} reached for this run")
        if self.run_requests:
            time.sleep(REQUEST_GAP_S)
        self.run_requests += 1
        status, raw = self.transport.request(params, post=post)
        body, detail, rows = None, "", 0
        try:
            body = json.loads(raw)
        except (ValueError, TypeError):
            detail = (raw or b"")[:120].decode("utf-8", "replace")
        if isinstance(body, dict) and "error" in body:
            err = body["error"]
            detail = err.get("code", "") + ": " + str(err.get("info", err)) if isinstance(err, dict) else str(err)
        if isinstance(body, dict) and isinstance(body.get("bucket"), list):
            rows = len(body["bucket"])
        ok = status == 200 and isinstance(body, dict) and "error" not in body
        self.db.execute("INSERT INTO ledger VALUES (?,?,?,?,?,?)",
                        (iso(utc_now()), endpoint, "ok" if ok else f"{status} {detail}"[:200],
                         rows, len(raw or b""), json.dumps(params)[:300]))
        self.db.commit()
        if not ok:
            raise WikiError(f"{endpoint} failed: HTTP {status} {detail}".strip())
        return body

    # ---- reading (what consumers use) --------------------------------------
    def rows(self, bucket, fields):
        """All rows of a bucket. Fails loudly if a field was never mirrored."""
        held = self.tracked().get(bucket)
        if held is None:
            raise KeyError(f"bucket {bucket!r} is not mirrored; run: add {bucket}")
        missing = [f for f in fields if f not in held]
        if missing:
            raise KeyError(f"bucket {bucket!r} lacks fields {missing}; run: add {bucket} "
                           f"--fields {','.join(sorted(set(held) | set(fields)))}")
        out = []
        for (data,) in self.db.execute("SELECT data FROM rows WHERE bucket=?", (bucket,)):
            row = json.loads(data)
            out.append({f: row.get(f) for f in fields})
        return out

    def synced_to(self):
        return self.meta("synced_to")

    # ---- filling -----------------------------------------------------------
    def _bucket_query(self, bucket, fields, where="", offset=0):
        select = ",".join(f"'{f}'" for f in fields)
        q = f"bucket('{bucket}').select({select}){where}.limit({PAGE_SIZE}).offset({offset}).run()"
        return self._call(f"bucket:{bucket}", {"action": "bucket", "query": q}, post=True)["bucket"]

    def schema_fields(self, bucket):
        """All field names of a bucket, read from its Bucket: page (1 request)."""
        title = "Bucket:" + bucket[:1].upper() + bucket[1:]
        body = self._call("parse:schema", {"action": "parse", "page": title, "prop": "wikitext"})
        schema = json.loads(body["parse"]["wikitext"]["*"])
        return ["page_name"] + [f for f in schema if f != "page_name"]

    def full(self, bucket, fields=None, all_fields=False):
        """Refill a bucket completely. Keeps the fields already held unless
        `fields` is given or `all_fields` asks for every field in its schema."""
        if all_fields:
            fields = self.schema_fields(bucket)
        fields = fields or self.tracked().get(bucket) or self.schema_fields(bucket)
        if "page_name" not in fields:
            fields = ["page_name"] + list(fields)
        rows, offset = [], 0
        while True:
            page = self._bucket_query(bucket, fields, offset=offset)
            rows.extend(page)
            if len(page) < PAGE_SIZE:
                break
            offset += PAGE_SIZE
        self._replace_bucket(bucket, fields, rows, iso(utc_now()))
        if self.synced_to() is None:
            self.meta("synced_to", iso(utc_now()))
        return len(rows)

    def _replace_bucket(self, bucket, fields, rows, filled_at):
        with self.db:
            self.db.execute("DELETE FROM rows WHERE bucket=?", (bucket,))
            self.db.executemany("INSERT INTO rows VALUES (?,?,?)",
                                [(bucket, r.get("page_name"), json.dumps(r)) for r in rows])
            self.db.execute("INSERT OR REPLACE INTO buckets VALUES (?,?,?,?)",
                            (bucket, json.dumps(fields), filled_at, len(rows)))

    def import_cache(self, cache_dir):
        """Load builder cache files ({fetched, fields, rows}) without any request.

        The sync point becomes the oldest fetch time, so the next update picks
        up every edit made after any of the files was downloaded.
        """
        times = []
        for path in sorted(Path(cache_dir).glob("*.json")):
            cached = json.loads(path.read_text(encoding="utf-8"))
            if "fields" not in cached:
                print(f"  skip {path.name}: no field list (old cache format)")
                continue
            self._replace_bucket(path.stem, cached["fields"], cached["rows"], cached["fetched"])
            times.append(cached["fetched"])
            print(f"  {path.stem}: {len(cached['rows'])} rows (fetched {cached['fetched']})")
        if times:
            oldest = min(dt.datetime.fromisoformat(t) for t in times)
            current = self.synced_to()
            if current is None or dt.datetime.fromisoformat(current.replace("Z", "+00:00")) > oldest:
                self.meta("synced_to", iso(oldest.astimezone(dt.timezone.utc)))

    # ---- incremental update ------------------------------------------------
    def recent_changes(self, since):
        """Titles edited/created/moved/deleted since `since`, plus template/module edits."""
        changed, deleted, templates = set(), set(), set()
        params = {"action": "query", "list": "recentchanges", "rcend": since, "rcdir": "older",
                  "rcnamespace": f"{NS_CONTENT}|{NS_TEMPLATE}|{NS_MODULE}",
                  "rcprop": "title|loginfo|timestamp", "rctype": "edit|new|log", "rclimit": "500"}
        while True:
            body = self._call("recentchanges", params)
            for rc in body["query"]["recentchanges"]:
                title, ns = rc["title"], rc.get("ns", 0)
                if ns in (NS_TEMPLATE, NS_MODULE):
                    templates.add(title)
                    continue
                action = rc.get("logaction")
                if rc.get("type") == "log":
                    if rc.get("logtype") == "delete" and action == "delete":
                        deleted.add(title)
                    elif rc.get("logtype") == "move":
                        deleted.add(title)
                        target = (rc.get("logparams") or {}).get("target_title")
                        if target:
                            changed.add(target)
                    continue
                changed.add(title)
            if "continue" not in body:
                break
            params = {**params, **body["continue"]}
        return changed - deleted, deleted, templates

    def update(self):
        since = self.synced_to()
        if since is None:
            raise SystemExit("mirror has never been filled; run add or import-cache first")
        started = utc_now()
        age = started - dt.datetime.fromisoformat(since.replace("Z", "+00:00"))
        if age > RC_MAX_AGE:
            raise SystemExit(f"last sync is {age.days} days old; recent-changes history may be "
                             f"incomplete. Run `full <bucket>` for each bucket instead.")

        changed, deleted, templates = self.recent_changes(since)
        tracked = self.tracked()
        titles = sorted(changed)
        report = {"since": since, "changed": len(titles), "deleted": len(deleted),
                  "templates": sorted(templates), "rows": {}}

        with self.db:
            for title in (deleted | changed) if tracked else ():
                self.db.execute("DELETE FROM rows WHERE page_name=? AND bucket IN (%s)"
                                % ",".join("?" * len(tracked)), (title, *tracked))
        for bucket, fields in tracked.items():
            fetched = []
            for i in range(0, len(titles), TITLES_PER_QUERY):
                batch = titles[i:i + TITLES_PER_QUERY]
                conds = ",".join("{'page_name','%s'}" % t.replace("\\", "\\\\").replace("'", "\\'")
                                 for t in batch)
                fetched.extend(self._bucket_query(bucket, fields, where=f".where({OR_FN}({conds}))"))
            with self.db:
                self.db.executemany("INSERT INTO rows VALUES (?,?,?)",
                                    [(bucket, r.get("page_name"), json.dumps(r)) for r in fetched])
                count = self.db.execute("SELECT COUNT(*) FROM rows WHERE bucket=?", (bucket,)).fetchone()[0]
                self.db.execute("UPDATE buckets SET row_count=? WHERE bucket=?", (count, bucket))
            report["rows"][bucket] = len(fetched)

        self.meta("synced_to", iso(started))
        return report

    # ---- reporting ---------------------------------------------------------
    def ledger_summary(self):
        month = utc_now().strftime("%Y-%m")
        total = self.db.execute("SELECT COUNT(*), COALESCE(SUM(rows),0), COALESCE(SUM(bytes),0) "
                                "FROM ledger WHERE time LIKE ?", (month + "%",)).fetchone()
        top = self.db.execute("SELECT endpoint, COUNT(*) c FROM ledger WHERE time LIKE ? "
                              "GROUP BY endpoint ORDER BY c DESC LIMIT 3", (month + "%",)).fetchall()
        tops = ", ".join(f"{e} {c}" for e, c in top) or "none"
        return (f"RS Wiki via mirror: {self.run_requests} requests this run / {total[0]} this month "
                f"({total[1]:,} rows, {total[2] / 1e6:.1f} MB); top: {tops}")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------
def main(argv=None):
    p = argparse.ArgumentParser(description="Local RuneScape Wiki Bucket mirror")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("status")
    sub.add_parser("ledger")
    sub.add_parser("update")
    s = sub.add_parser("import-cache"); s.add_argument("dir")
    s = sub.add_parser("add"); s.add_argument("bucket"); s.add_argument("--fields")
    s = sub.add_parser("full"); s.add_argument("bucket")
    args = p.parse_args(argv)

    m = Mirror()
    try:
        if args.cmd == "status":
            print(f"synced to: {m.synced_to()}")
            for b, f, filled, n in m.db.execute("SELECT * FROM buckets ORDER BY bucket"):
                print(f"  {b}: {n} rows, filled {filled}, fields {len(json.loads(f))}")
        elif args.cmd == "import-cache":
            m.import_cache(args.dir)
        elif args.cmd == "add":
            fields = args.fields.split(",") if args.fields else None
            # add = first fill or widening: every schema field unless --fields says otherwise
            print(f"{args.bucket}: {m.full(args.bucket, fields, all_fields=fields is None)} rows")
        elif args.cmd == "full":
            print(f"{args.bucket}: {m.full(args.bucket)} rows")
        elif args.cmd == "update":
            r = m.update()
            print(f"since {r['since']}: {r['changed']} pages changed, {r['deleted']} deleted/moved")
            for b, n in r["rows"].items():
                print(f"  {b}: {n} rows re-fetched")
            if r["templates"]:
                print(f"WARNING: {len(r['templates'])} template/module edits may have changed rows "
                      f"on unedited pages. If any affect your buckets, run `full <bucket>`:")
                for t in r["templates"][:20]:
                    print(f"    {t}")
    except WikiError as e:
        print(f"STOPPED: {e}", file=sys.stderr)
        print(m.ledger_summary())
        return 1
    print(m.ledger_summary())
    return 0


if __name__ == "__main__":
    sys.exit(main())
