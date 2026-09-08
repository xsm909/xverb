"""The event a view is handed, built the way the host builds it.

Run with ``python3 assets/python/test_view_event.py``.

**Why this file exists.** The host learnt to stamp every row event with the
part it came from, and the git tool was written to read `event.part` — but the
SDK's `ViewEvent` had no such attribute, so the first press in the real
application answered `'ViewEvent' object has no attribute 'part'`. Nothing
caught it, because what had been driven was a *stand-in* event object with a
`part` of its own. A stand-in cannot fail the way the real thing fails.

So: no stand-ins here. The event is built from the same wire parameters
`view.event` arrives with, and every field the contract carries is read off it.
"""

import sys

from xverb.plugin import ViewEvent


#: Stands in for a field the SDK does not have at all, which is the failure
#: this file exists for: reading it must be a *reported* failure, not a
#: traceback that stops the rest of the run.
MISSING = object()


def check(name, got, want):
    if got is MISSING:
        print("FAIL %s: the event has no such attribute" % name)
        return False
    if got != want:
        print("FAIL %s: %r, wanted %r" % (name, got, want))
        return False
    print("ok   %s" % name)
    return True


#: Exactly what the host puts on the wire, from `ViewEvent.toJson` in
#: `lib/core/plugins/view.dart`.
CASES = [
    ("a row opened in a part", {"type": "activate", "row": 3, "part": "log"},
     [("kind", "activate"), ("row", 3), ("part", "log")]),
    ("the cursor coming to rest", {"type": "cursor", "row": 0, "part": "files"},
     [("kind", "cursor"), ("row", 0), ("part", "files")]),
    ("the secondary press", {"type": "mark", "row": 7, "part": "refs"},
     [("kind", "mark"), ("row", 7), ("part", "refs")]),
    # Content that is not a split carries no part at all, and the field is
    # still there to be read — an empty string, never a missing attribute.
    ("a row in a view with no parts", {"type": "activate", "row": 1},
     [("kind", "activate"), ("row", 1), ("part", "")]),
    ("a button", {"type": "button", "id": "refresh"},
     [("id", "refresh"), ("part", "")]),
    ("a question answered", {"type": "answered", "id": "stage", "accepted": True},
     [("id", "stage"), ("accepted", True)]),
    ("a key", {"type": "key", "key": "down"}, [("key", "down")]),
    ("what was deleted", {"type": "deleted", "urls": ["file:///a"]},
     [("urls", ["file:///a"])]),
    # A field a newer host sends and this SDK has never heard of is ignored,
    # rather than being the end of the plugin.
    ("something from a newer app", {"type": "activate", "row": 1, "sparkle": True},
     [("kind", "activate"), ("row", 1)]),
]


def main():
    ok = True
    for name, params, wanted in CASES:
        event = ViewEvent(params.get("type") or "", params)
        for field, value in wanted:
            ok = check(
                "%s — %s" % (name, field),
                getattr(event, field, MISSING),
                value,
            ) and ok

    # Every field the contract names is readable on every event, whatever kind
    # it is. This is the check that would have caught it.
    for field in ("kind", "row", "key", "id", "accepted", "part", "urls"):
        ok = check(
            "an empty event still answers .%s" % field,
            hasattr(ViewEvent("open"), field),
            True,
        ) and ok
    return ok


if __name__ == "__main__":
    sys.exit(0 if main() else 1)
