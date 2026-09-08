"""A native path and a ``file:`` URL, in both directions.

Run with ``python3 assets/python/test_file_url.py``. No framework: this file is
shipped to every machine that installs a plugin, and a test that needs pytest
installed is a test nobody runs.

**Why it exists.** On 2026-08-18 a Windows machine reported *"Git: / is not in
80796e4…"*, which was the git plugin running ``git -C /Work/flutter/xverb``
on a machine where the repository lives on ``E:``. The drive had been eaten by a
URL: the plugin built one as ``"file://" + root``, git prints a Windows root as
``E:/Work/x``, and that leaves the URL reading ``E:`` as its *host* — so what
came back out was ``/Work/x``, a path on nothing.

Every case below runs on every platform, because that is the whole point: the
expression that lost the drive is *correct* on POSIX, which is why it survived
until somebody ran it on Windows. The paths here are text, so this is about the
spelling and not about what happens to be on this disk.
"""

import sys

from xverb import file_url, local_path

FAILURES = []


def check(name, got, expected):
    if got != expected:
        FAILURES.append("%s\n  expected %r\n  got      %r" % (name, expected, got))


def main():
    # -- what the host writes, and what has to come back out ------------------
    # The host builds these with Dart's `Uri.file`, so this is the spelling the
    # SDK has to both produce and read. Note the colon is *not* escaped: two
    # spellings of one place is how "am I already in this folder" starts
    # answering no.
    check("windows drive", file_url("E:/Work/x"), "file:///E:/Work/x")
    check("windows backslashes", file_url(r"E:\Work\x"), "file:///E:/Work/x")
    check("posix", file_url("/Users/me/Work"), "file:///Users/me/Work")
    check("a space", file_url("C:/Program Files/App"),
          "file:///C:/Program%20Files/App")
    # A server really is a host, and belongs where a URL puts one.
    check("unc", file_url(r"\\server\share\folder"),
          "file://server/share/folder")

    # -- and back -------------------------------------------------------------
    for native in ["E:/Work/x", "/Users/me/Work", "C:/Program Files/App"]:
        check("round trip %s" % native, local_path(file_url(native)), native)
    check("round trip unc", local_path(file_url(r"\\server\share\folder")),
          r"\\server\share\folder")

    # -- the drive is not a server -------------------------------------------
    # The broken spelling, which is what the git plugin was writing. URLs
    # outlive the code that wrote them — a panel's history or a saved tab may
    # hold one — so reading it has to work even though nothing writes it now.
    check(
        "a drive in the host is still a drive",
        local_path("file://E:/Work/x"),
        r"E:\Work\x",
    )
    check(
        "and the bare drive, which is not the current directory on it",
        local_path("file://E:"),
        "E:\\",
    )

    # A real server is still read as one.
    check("a server in the host is a server", local_path("file://server/share"),
          r"\\server\share")

    # -- what is not a file at all -------------------------------------------
    check("another scheme", local_path("ftp://host/pub"), None)
    check("a drive root keeps its separator", local_path("file:///E:/"), "E:/")

    if FAILURES:
        print("\n\n".join(FAILURES))
        print("\n%d failed" % len(FAILURES))
        return 1
    print("file_url: all cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
