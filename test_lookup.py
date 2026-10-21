"""Load the generated data in a real Lua 5.4 runtime and check known answers.

Needs lupa (pip install lupa). Run: python test_lookup.py
Fails loudly (non-zero exit) on any mismatch.
"""

import sys
import time
from pathlib import Path

import lupa.lua54 as lupa

PLUGIN = Path(__file__).resolve().parent / "plugin"

lua = lupa.LuaRuntime(unpack_returned_tuples=True)
lua.execute(f'package.path = "{PLUGIN.as_posix()}/?.lua"')

start = time.perf_counter()
Lookup = lua.eval('(require("lookup"))')  # parens: keep only the module
print(f"core load: {(time.perf_counter() - start) * 1000:.0f} ms")

failures = []


def check(label, condition, detail=""):
    print(("PASS " if condition else "FAIL ") + label + (f"  ({detail})" if detail else ""))
    if not condition:
        failures.append(label)


def lua_list(table):
    return [table[i] for i in range(1, len(table) + 1)] if table else []


def item_index(name):
    names = lua.eval('(require("data/items")).names')
    for i in range(1, len(names) + 1):
        if names[i] == name:
            return i
    return None


def source_index(name):
    names = lua.eval('(require("data/sources")).names')
    for i in range(1, len(names) + 1):
        if names[i] == name:
            return i
    return None


# Drops of an item, with the wiki's own Dust devil row as the known answer.
bones = item_index("Dragon bones")
start = time.perf_counter()
drops = lua_list(Lookup.dropsOfItem(bones))
print(f"dropsOfItem(Dragon bones): {len(drops)} rows in {(time.perf_counter() - start) * 1000:.0f} ms")
dust = [d for d in drops if Lookup.sourceName(d.other) == "Dust devil"]
check("Dust devil drops Dragon bones at 1/262,144, 35-45 noted",
      any(d.rarity == "1/262,144" and d.qtyLow == 35 and d.qtyHigh == 45 and d.noted for d in dust),
      f"{len(dust)} dust devil rows")
check("probability parsed for 1/262,144",
      any(d.probability and abs(d.probability - 1 / 262144) < 1e-12 for d in dust))
best = sorted((d for d in drops if d.probability), key=lambda d: -d.probability)[:5]
for d in best:
    print(f"    {Lookup.sourceName(d.other)}: {d.rarity} x{d.qtyLow}-{d.qtyHigh}"
          f" -> {Lookup.expectedPerAction(d)} per kill")
unknown = [d for d in drops if d.probability is None]
check("unknown rates come back as nil probability with text kept",
      all(d.rarity for d in unknown), f"{len(unknown)} rows with text-only rarity")

# What a source drops.
green = source_index("Green dragon")
green_drops = lua_list(Lookup.dropsFromSource(green))
check("Green dragon drops Dragon bones always",
      any(Lookup.itemName(d.other) == "Dragon bones" and d.rarity == "Always" for d in green_drops),
      f"{len(green_drops)} rows")

# Game id lookups (RS3 ids: Dragon bones obj 536, Dust devil npc 1624, Fire altar loc 2482).
check("itemByObj(536) is Dragon bones", Lookup.itemName(Lookup.itemByObj(536) or 0) == "Dragon bones")
check("sourceByNpc(1624) is Dust devil", Lookup.sourceName(Lookup.sourceByNpc(1624) or 0) == "Dust devil")
check("sourceByLoc(2482) is Fire altar", Lookup.sourceName(Lookup.sourceByLoc(2482) or 0) == "Fire altar")
check("versioned item: obj 3024 is Super restore (4)",
      Lookup.itemName(Lookup.itemByObj(3024) or 0) in ("Super restore (4)", "Super restore"),
      str(Lookup.itemName(Lookup.itemByObj(3024) or 0)))

# Recipes and shops.
overload = item_index("Overload")
recipes = lua_list(Lookup.recipesMaking(overload))
materials = {Lookup.itemName(m[1]) for r in recipes for m in lua_list(r.materials)}
check("Overload recipe uses Clean torstol", "Clean torstol" in materials, f"{len(recipes)} recipes")
shops = lua_list(Lookup.shopsSelling(item_index("Vial")))
check("Vial sold at Jatix's Herblore Shop",
      any(s.shop == "Jatix's Herblore Shop" for s in shops), f"{len(shops)} shops")

# Every chunk loads.
meta = Lookup.meta()
for view in ("by_item", "by_source"):
    starts = lua_list(meta.chunkStarts[view])
    for n in range(len(starts)):
        lua.eval(f'require("data/drops/{view}_{n:02d}")')
    check(f"all {len(starts)} {view} chunks load", True)

mem_kb = lua.eval("collectgarbage('count')")
print(f"Lua memory with everything loaded: {mem_kb / 1024:.1f} MB")
print(f"{len(failures)} failure(s)")
sys.exit(1 if failures else 0)
