"""Base classes for plugins that add a file system to xverb.

Subclass :class:`FileSystem`, implement as much of it as your transport
supports, and register it with ``Plugin.add_filesystem``. Everything the panels
do with a local disk then works against your backend too.
"""

from __future__ import annotations

from typing import Iterable, List, Optional
from urllib.parse import parse_qs, quote, unquote, urlparse

DIRECTORY = "dir"
FILE = "file"
LINK = "link"


class Entry:
    """One row in a directory listing."""

    def __init__(
        self,
        name: str,
        kind: str = FILE,
        size: int = 0,
        modified: Optional[float] = None,
        hidden: bool = False,
        target: Optional[str] = None,
    ):
        self.name = name
        self.kind = kind
        self.size = size
        # Seconds since the epoch, as returned by ``os.stat``. Converted to the
        # milliseconds the host expects on the way out.
        self.modified = modified
        self.hidden = hidden
        self.target = target

    def to_json(self) -> dict:
        return {
            "name": self.name,
            "kind": self.kind,
            "size": self.size,
            "modified": None if self.modified is None else int(self.modified * 1000),
            "hidden": self.hidden,
            "target": self.target,
        }


class Root:
    """A starting point offered in the drives-and-connections list."""

    def __init__(
        self,
        url: str,
        label: str,
        subtitle: Optional[str] = None,
        icon: str = "server",
    ):
        self.url = url
        self.label = label
        self.subtitle = subtitle
        self.icon = icon

    def to_json(self) -> dict:
        return {
            "url": self.url,
            "label": self.label,
            "subtitle": self.subtitle,
            "icon": self.icon,
        }


class FileSystem:
    """Override the operations your transport can do.

    Anything left unimplemented raises, and the host turns that into a normal
    error message in the panel — a read-only backend simply never implements
    ``write``, ``mkdir``, ``delete`` or ``rename``. The messages are written to
    be read by whoever pressed the key, because that is where they end up.
    """

    #: URI scheme this file system serves, e.g. ``"ftp"``.
    scheme = ""

    #: False for a file system that cannot be written to at all — a commit, an
    #: archive, a service that only serves. **Say it here rather than letting
    #: it be discovered**: the host dims the keys that cannot work and marks
    #: the panel with :attr:`icon`, instead of offering Delete and answering
    #: the press with an error from three layers down.
    writable = True

    #: What the panel draws beside the path while it stands in this scheme,
    #: named from the host's icon table — ``history`` for a commit, ``archive``
    #: for a box of files. Empty for a transport that is simply another disk:
    #: the path already says where it is.
    icon = ""

    def roots(self) -> Iterable[Root]:
        return []

    def default_location(self) -> str:
        return "%s:///" % self.scheme

    def list(self, url: str) -> List[Entry]:
        raise NotImplementedError("This file system cannot list directories")

    def stat(self, url: str) -> Optional[Entry]:
        raise NotImplementedError("This file system cannot look at an entry")

    def read(self, url: str, offset: int, length: int) -> bytes:
        """Returns up to ``length`` bytes starting at ``offset``.

        Returning fewer bytes than asked for signals end of file.
        """
        raise NotImplementedError("This file system cannot be read")

    def begin_write(
        self, url: str, size: Optional[int], modified: Optional[float]
    ) -> None:
        """A file is about to arrive: what the host knows about it up front.

        Called before the first :meth:`write`, and only with what the host
        actually knows — either may be ``None``. Does nothing by default.

        ``modified`` is seconds since the epoch, the way :class:`Entry` counts
        them. It is here because a date cannot be recovered afterwards: a member
        goes into an archive with whatever date it is given, and without this
        every file in a new archive was stamped the moment it was packed.
        ``size`` is the whole file's length, for a backend that has to declare
        it before the bytes start.
        """
        return None

    def write(self, url: str, data: bytes, mode: str) -> None:
        """``mode`` is ``"create"`` for the first chunk, ``"append"`` after."""
        raise NotImplementedError("This file system is read-only")

    def close_write(self, url: str, complete: bool) -> None:
        """The file is finished: ``complete`` says whether every byte arrived.

        A transport writing straight through has nothing to do here — the file
        was on the server after the last chunk, which is why this does nothing
        by default and why no existing backend had to change for it.

        Override it where the last chunk is not the end of the work. A member
        being deflated into an archive is not *in* the archive until its sizes
        and its directory entry are written, and nothing else in the protocol
        says where the bytes stop: a write arrives as a ``create`` and then any
        number of ``append``\\ s. ``complete=False`` means the copy failed or was
        cancelled part way — throw the half-written member away rather than
        sealing a truncated one into the archive.
        """
        return None

    def finish_writes(self, url: str) -> None:
        """The copy, move or delete that was writing here has finished.

        Nothing else says so. A write is one file at a time, and a backend that
        can only assemble itself as a whole cannot tell the last file of a copy
        from the middle of one — so it either does the whole assembly after
        every file or it never knows when to do it at all.

        **A compressed tarball is the case this exists for.** There is no
        appending to one: adding a file means writing the archive again, so
        fifty files would be fifty rewrites of a growing archive. With this,
        members are staged and the archive is written once.

        It is a hint about *timing*, never about correctness: whatever is staged
        has to survive not being told, because a call that crosses a process is
        a call that can be missed. The worst it may cost is a panel showing
        something out of date.
        """
        return None

    def mkdir(self, url: str) -> None:
        raise NotImplementedError("This file system cannot create folders")

    def delete(self, url: str) -> None:
        raise NotImplementedError("This file system cannot delete anything")

    def rename(self, source: str, target: str) -> None:
        raise NotImplementedError("This file system cannot rename anything")

    def copy_within(self, source: str, target: str) -> bool:
        """Optional server-side copy. Return False to let the host stream it."""
        return False


def query_of(url: str) -> dict:
    """Returns the URL's query parameters as a flat dict.

    Connection options the host does not understand are passed through this
    way, so a transport can define its own without the core knowing them.
    """
    return {key: values[0] for key, values in parse_qs(urlparse(url).query).items()}


def local_path(url: str) -> Optional[str]:
    """The native path behind a ``file:`` URL, or None for any other scheme.

    Use this rather than picking the path out of the URL yourself. The corner
    that catches everyone is a Windows drive root: the URL path is ``/C:/``, and
    a bare ``C:`` is not the drive — Windows reads it as *the current directory
    on drive C*, so scanning it lists whatever folder the plugin happens to be
    running in. A drive always keeps its separator here.

    UNC paths come back as ``\\\\server\\share\\...``, which is what the
    platform expects.
    """
    parsed = urlparse(url)
    if parsed.scheme != "file":
        return None

    path = unquote(parsed.path)
    if parsed.netloc:
        # **A drive letter is not a server.** `file://E:/Work/x` is what you get
        # from gluing "file://" to a path git printed, and a URL reads the `E:`
        # as its *host* — so the drive falls out and what is left is
        # `/Work/x`, a path on nothing. It reached us as a bug report from
        # Windows on 2026-08-18: *"Git: / is not in 80796e4…"*, which was
        # `git -C /Work/flutter/xverb` failing on a machine where the
        # repository is on E:. Accepted here rather than only fixed at the
        # source, because URLs outlive the code that wrote them — a panel's
        # history or a saved tab may hold one of these.
        if len(parsed.netloc) == 2 and parsed.netloc[1] == ":":
            path = parsed.netloc + (path or "/").replace("/", "\\")
            return path
        # file://server/share/x — the host is part of the path on Windows.
        return "\\\\" + parsed.netloc + path.replace("/", "\\")

    # Windows arrives as /C:/Users/... — the leading slash belongs to the URL,
    # not to the path.
    if len(path) > 2 and path[0] == "/" and path[2] == ":":
        path = path[1:]
    if len(path) == 2 and path[1] == ":":
        # The drive on its own. Without the separator this means somewhere else
        # entirely, and the URL may well not have carried one.
        return path + "\\"
    return path


def file_url(path: str) -> str:
    """A native path as a ``file:`` URL — the other half of [local_path].

    **Use this rather than gluing ``"file://"`` to a path.** On a Windows
    machine that is one slash short, and the slash it is short of is the one
    that keeps the drive out of the URL's host: ``"file://" + "E:/Work/x"``
    parses as *host* ``E:`` and *path* ``/Work/x``, so the drive is silently
    gone. On a POSIX machine the same expression is right, which is why this
    survived until somebody ran it on Windows.

    UNC paths keep their server as the host, which is where a URL puts it.
    """
    if not path:
        return "file:///"

    # \\server\share\x — the server is the URL's host, and that one really is
    # a host.
    if path.startswith("\\\\"):
        rest = path[2:].replace("\\", "/")
        server, _, inner = rest.partition("/")
        return "file://" + quote(server) + "/" + quote(inner, safe="/:")

    forward = path.replace("\\", "/")
    if not forward.startswith("/"):
        # A drive, or a relative path somebody handed us. Either way the URL
        # needs the root slash of its own.
        forward = "/" + forward
    # The colon is left alone, because the host writes these with `Uri.file`
    # and that does not escape it: `file:///E:/Work`. An `%3A` here would mean
    # the same place spelled a second way, and two spellings of one place is
    # how "is this the folder I am already in" starts answering no.
    return "file://" + quote(forward, safe="/:")


def split_url(url: str):
    """Splits a VFS URL into ``(host, port, user, password, path)``.

    Handy for network transports, where the panel path carries the credentials
    the user typed in the connect dialog.
    """
    parsed = urlparse(url)
    path = unquote(parsed.path) or "/"
    return (
        parsed.hostname,
        parsed.port,
        unquote(parsed.username) if parsed.username else None,
        unquote(parsed.password) if parsed.password else None,
        path,
    )
