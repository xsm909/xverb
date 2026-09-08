"""Where a written file ends, and why that is a call of its own.

Run with ``python3 assets/python/test_write_close.py``. No framework, for the
same reason as the rest of these: this file ships to every machine that installs
a plugin.

**Why it exists.** A write arrives as ``create`` and then any number of
``append``\\ s, and nothing said where they stopped. A transport did not care —
the file was on the server after the last chunk — but a backend that has to
*close* something does, and an archive is exactly that: a member is not in the
archive until its sizes and its directory entry are written. So the host now
sends a final ``close``, or ``abort`` when the copy failed part way.

**The trap this pins down.** The obvious spelling — a final ``write`` of no
bytes — would have destroyed data. The FTP backend reads any mode that is not
``append`` as ``STOR``, and a zero-byte ``STOR`` truncates the file that was
just uploaded. So the closing modes are answered by the dispatcher and must
never reach ``write`` at all, which is also what lets every transport written
before this go on working with no change.
"""

import base64
import sys

from xverb import FileSystem, Plugin

FAILURES = []


def check(name, got, expected):
    if got != expected:
        FAILURES.append("%s\n  expected %r\n  got      %r" % (name, expected, got))


class Recording(FileSystem):
    """A file system that writes down what it was asked to do, in order."""

    scheme = "recording"

    def __init__(self):
        self.calls = []

    def begin_write(self, url, size, modified):
        self.calls.append(("begin_write", size, modified))

    def write(self, url, data, mode):
        self.calls.append((mode, data))

    def close_write(self, url, complete):
        self.calls.append(("close_write", complete))

    def finish_writes(self, url):
        self.calls.append(("finish_writes",))


class Oblivious(FileSystem):
    """One written before any of this existed: it knows create and append."""

    scheme = "oblivious"

    def __init__(self):
        self.modes = []

    def write(self, url, data, mode):
        # What the FTP backend does, and the reason the closing modes are not
        # spelled as a write of no bytes.
        self.modes.append("append" if mode == "append" else "STOR")


def send(plugin, filesystem, mode, data=b"", **extra):
    params = {
        "url": "%s:///box" % filesystem.scheme,
        "data": base64.b64encode(data).decode("ascii"),
        "mode": mode,
    }
    params.update(extra)
    plugin._fs_write(params)


def main():
    plugin = Plugin("org.xverb.test.write")

    recording = Recording()
    plugin.add_filesystem(recording)
    send(plugin, recording, "create", b"ab", length=4, modified=1500000000000)
    send(plugin, recording, "append", b"cd")
    send(plugin, recording, "close")
    check(
        "a whole file: what it is, two chunks, and then the end of it",
        recording.calls,
        [
            ("begin_write", 4, 1500000000.0),
            ("create", b"ab"),
            ("append", b"cd"),
            ("close_write", True),
        ],
    )

    # The date is what an archive cannot recover afterwards, and the host may
    # not know it — a source that never said keeps None rather than now.
    recording.calls.clear()
    send(plugin, recording, "create", b"")
    send(plugin, recording, "close")
    check(
        "nothing known about the file is nothing invented",
        recording.calls[0],
        ("begin_write", None, None),
    )

    recording.calls.clear()
    send(plugin, recording, "create", b"ab")
    send(plugin, recording, "abort")
    check(
        "a cancelled copy says so, so the half member can be thrown away",
        recording.calls,
        [("begin_write", None, None), ("create", b"ab"), ("close_write", False)],
    )

    oblivious = Oblivious()
    plugin.add_filesystem(oblivious)
    send(plugin, oblivious, "create", b"ab")
    send(plugin, oblivious, "append", b"cd")
    send(plugin, oblivious, "close")
    send(plugin, oblivious, "abort")
    check(
        "a backend that never heard of closing is never told about it",
        oblivious.modes,
        ["STOR", "append"],
    )

    # The end of the whole operation, which is a different question from the end
    # of a file: a backend that can only assemble itself as a whole is told once,
    # here, rather than after every file.
    recording.calls.clear()
    plugin._fs_finish({"url": "recording:///box"})
    check("the operation ending is its own call", recording.calls,
          [("finish_writes",)])

    # The defaults do nothing and do not raise: a transport has no work to do at
    # either end of a file, nor at the end of an operation, and it must not have
    # to say so.
    FileSystem().begin_write("recording:///box", 4, 1500000000.0)
    FileSystem().close_write("recording:///box", True)
    FileSystem().finish_writes("recording:///box")

    if FAILURES:
        print("\n\n".join(FAILURES))
        print("\n%d failed" % len(FAILURES))
        return 1
    print("write close: all cases pass")
    return 0


if __name__ == "__main__":
    sys.exit(main())
