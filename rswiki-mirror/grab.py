"""One-time grab: every wiki table the plugin family needs, with all fields.

Runs the incremental update first (to test it against the live wiki), then
fills each table below completely. It stops at the first error and prints the
ledger either way. Expected: about 100-150 requests in total.

    python grab.py            # do it
    python grab.py --list     # just show the plan
"""

import sys

import rswiki_mirror as rm

TOTAL_CAP = 250   # whole grab; each table also has the per-run cap

# (bucket, why we want it)
TABLES = [
    # held already, widened to all fields
    ("dropsline", "drops: Advanced Examine core"),
    ("item_id", "game obj ids"),
    ("npc_id", "game npc ids"),
    ("object_id", "game scenery ids"),
    ("recipe", "made by / used in"),
    ("storeline", "shop stock"),
    # new
    ("infobox_item", "examine text, members, alch, weight, tradeable"),
    ("infobox_monster", "level, slayer, members"),
    ("infobox_npc", "non-combat NPCs"),
    ("infobox_scenery", "scenery that drops or is gathered"),
    ("infobox_shop", "shop owners and locations"),
    ("infobox_location", "places"),
    ("coordinates", "map positions: nearest source / teleport"),
    ("resource_locations", "where to gather each resource"),
    ("quest", "quest requirements: ironman planning"),
    ("infobox_quest", "quest details"),
    ("quest_rewards", "quest rewards"),
]


def main():
    if "--list" in sys.argv:
        for bucket, why in TABLES:
            print(f"  {bucket:20} {why}")
        return 0
    m = rm.Mirror()
    total = 0
    try:
        print("update (pages changed since last sync)")
        r = m.update()
        print(f"  {r['changed']} pages changed, {r['deleted']} deleted/moved, "
              f"{len(r['templates'])} template/module edits")
        total += m.run_requests
        for bucket, why in TABLES:
            if total >= TOTAL_CAP:
                raise rm.WikiError(f"grab cap {TOTAL_CAP} reached before {bucket}")
            m.run_requests = 0
            try:
                rows = m.full(bucket, all_fields=True)
            except rm.WikiError as e:
                # A table name that doesn't exist is skipped; any other error stops the grab.
                if "missingtitle" in str(e) or "does not exist" in str(e):
                    total += m.run_requests
                    print(f"  {bucket}: skipped, no such table ({e})")
                    continue
                raise
            total += m.run_requests
            fields = len(m.tracked()[bucket])
            print(f"  {bucket}: {rows} rows, {fields} fields, {m.run_requests} requests ({why})")
    except rm.WikiError as e:
        print(f"STOPPED: {e}")
        print(f"requests this grab: {total + m.run_requests}")
        print(m.ledger_summary())
        return 1
    print(f"requests this grab: {total}")
    print(m.ledger_summary())
    return 0


if __name__ == "__main__":
    sys.exit(main())
