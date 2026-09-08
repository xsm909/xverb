"""The lane layout, checked against histories whose shape is known by hand.

Run with ``python3 assets/python/test_lay_out.py``. No framework: this file is
shipped to every machine that installs a plugin, and a test that needs pytest
installed is a test nobody runs.

The rule every case checks is the one the drawing depends on: **what leaves the
bottom of a row is what arrives at the top of the next one.** Break that and the
lines come apart, which is exactly the failure the ASCII graph used to have and
the reason this exists.
"""

import sys

from xverb import lay_out


def check(name, commits, expected):
    rows = lay_out(commits)
    got = [
        (
            row["lane"],
            row.get("closes", []),
            row.get("parents", []),
            [list(e) for e in row.get("through", [])],
            row.get("merge", False),
        )
        for row in rows
    ]
    if got != expected:
        print("FAIL %s" % name)
        for (h, _), was, want in zip(commits, got, expected):
            mark = "  " if was == want else "->"
            print("%s %-4s %s" % (mark, h, was))
            if was != want:
                print("     wanted %s" % (want,))
        return False

    # Continuity: every lane a row leaves by must be a lane the next row knows
    # about, or the picture has a line that starts from nothing.
    for i in range(len(rows) - 1):
        leaves = set(rows[i].get("parents", []))
        leaves |= {edge[1] for edge in rows[i].get("through", [])}
        below = rows[i + 1]
        arrives = set(below.get("closes", []))
        arrives |= {edge[0] for edge in below.get("through", [])}
        if below["lane"] >= 0 and not below.get("closes"):
            arrives.add(below["lane"])
        if not leaves <= arrives:
            print("FAIL %s: row %d leaves by %s, row %d knows %s"
                  % (name, i, sorted(leaves - arrives), i + 1, sorted(arrives)))
            return False

        # The colours: what a row says is leaving is what the next row sees
        # arriving, lane for lane. The host colours a line by its tint, so a
        # tint that changed between two rows would repaint a line nothing had
        # happened to — which is exactly what a lane-coloured braid did.
        if rows[i].get("leaving", []) != below.get("entering", []):
            print("FAIL %s: row %d leaves %s, row %d arrives %s"
                  % (name, i, rows[i].get("leaving", []),
                     i + 1, below.get("entering", [])))
            return False

    for i, drawn in enumerate(rows):
        # A tint says which line; two lines at once in the same one would be
        # two lines the reader cannot tell apart.
        for edge in ("entering", "leaving"):
            tints = drawn.get(edge, [])
            if len(set(tints)) != len(tints):
                print("FAIL %s: row %d has %s twice over" % (name, i, edge))
                return False
        # A line that shifts lanes keeps its tint. This is the whole point —
        # and the one exception is the lane the commit joins, where two lines
        # become one and the older of them says what colour that is.
        joined = set(drawn.get("parents", []))
        for top, bottom in drawn.get("through", []):
            if bottom in joined:
                continue
            if drawn.get("entering", [])[top] != drawn.get("leaving", [])[bottom]:
                print("FAIL %s: row %d repaints the line crossing it" % (name, i))
                return False

    print("ok   %s" % name)
    return True


def tints_of(commits):
    """The tint each row's own commit is drawn in, for the cases below."""
    return [row.get("tint", row["lane"]) for row in lay_out(commits)]


CASES = [
    (
        "a straight line",
        [("a", ["b"]), ("b", ["c"]), ("c", [])],
        [
            (0, [], [0], [], False),
            (0, [0], [0], [], False),
            (0, [0], [], [], False),
        ],
    ),
    (
        "a side branch, merged",
        [("m", ["c", "b"]), ("c", ["p"]), ("b", ["p"]), ("p", [])],
        [
            (0, [], [0, 1], [], True),
            (0, [0], [0], [[1, 1]], False),
            # b's parent is already expected on the trunk, so b's lane bends
            # into it rather than carrying a second copy of p.
            (1, [1], [0], [[0, 0]], False),
            (0, [0], [], [], False),
        ],
    ),
    (
        "two tips of their own",
        [("a", ["z"]), ("b", ["z"]), ("z", [])],
        [
            (0, [], [0], [], False),
            (1, [], [0], [[0, 0]], False),
            (0, [0], [], [], False),
        ],
    ),
    (
        "a lane freed in the middle packs the rest in",
        [("a", ["c"]), ("b", ["d"]), ("c", ["e"]), ("d", []), ("e", [])],
        [
            (0, [], [0], [], False),
            (1, [], [1], [[0, 0]], False),
            (0, [0], [0], [[1, 1]], False),
            (1, [1], [], [[0, 0]], False),
            (0, [0], [], [], False),
        ],
    ),
    (
        "a parent below the end of the log ends its line",
        [("a", ["gone"])],
        [(0, [], [0], [], False)],
    ),
    (
        "an octopus merge is three lines out, and they pack in behind it",
        [("m", ["a", "b", "c"]), ("a", []), ("b", []), ("c", [])],
        [
            (0, [], [0, 1, 2], [], True),
            # `a` ends, so the two lanes to its right shift in — one lane each,
            # and both shifts are bends rather than breaks.
            (0, [0], [], [[1, 0], [2, 1]], False),
            (0, [0], [], [[1, 0]], False),
            (0, [0], [], [], False),
        ],
    ),
]


def colours_hold():
    """The two things a reader would notice, said plainly.

    A line that moves lane must not change colour, and a branch that ends must
    hand its colour back for the next one to use — nine hues do not go far in
    a repository with thirty branches in it.
    """
    ok = True

    # `b` opens the second line and its history walks it back into lane 0 as
    # `a`'s ends. One line, one tint, whatever lane it is standing in.
    history = [("a", ["c"]), ("b", ["d"]), ("c", ["e"]), ("d", []), ("e", [])]
    tints = tints_of(history)
    if tints[1] != tints[3]:
        print("FAIL a shifted line keeps its colour: %s" % (tints,))
        ok = False
    elif tints[0] == tints[1]:
        print("FAIL two lines at once are two colours: %s" % (tints,))
        ok = False
    else:
        print("ok   a shifted line keeps its colour")

    # A branch forks off the trunk: `b` is the newer line, and below the fork
    # the history is the trunk's. The trunk goes down through it in the colour
    # it came in with, and it is `b` that ends.
    tints = tints_of([("t1", ["t2"]), ("b1", ["t2"]), ("t2", ["t3"]),
                      ("t3", [])])
    if tints[0] != tints[2] or tints[2] != tints[3]:
        print("FAIL the older line comes out of the fork: %s" % (tints,))
        ok = False
    elif tints[1] == tints[0]:
        print("FAIL the branch is a line of its own: %s" % (tints,))
        ok = False
    else:
        print("ok   the older line comes out of the fork")

    # One line at a time, three times over: each takes the colour the one
    # before it gave back.
    tints = tints_of([("a", []), ("b", []), ("c", [])])
    if tints != [0, 0, 0]:
        print("FAIL a finished line gives its colour back: %s" % (tints,))
        ok = False
    else:
        print("ok   a finished line gives its colour back")

    return ok


if __name__ == "__main__":
    passed = all([check(*case) for case in CASES])
    sys.exit(0 if passed and colours_hold() else 1)
