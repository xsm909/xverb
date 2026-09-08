"""The entry point plugin authors use.

A plugin is a directory with a ``plugin.json`` and a script that builds a
:class:`Plugin`, registers what it contributes, and calls ``run()``::

    from xverb import Plugin, text

    plugin = Plugin("com.example.hello")

    @plugin.viewer("hello.text", "Plain text", extensions=["txt", "md"])
    def view_text(url):
        return text(plugin.read_file(url, max_bytes=1 << 20).decode("utf-8", "replace"))

    plugin.run()
"""

from __future__ import annotations

import base64
import inspect
import json
import os
import sys
from typing import Callable, Dict, List, Optional

from .fs import FileSystem
from .rpc import RpcError, RpcPeer

#: Protocol version this SDK speaks. Must match the host's.
API_VERSION = 1


def text(body: str, language: Optional[str] = None, truncated: bool = False) -> dict:
    """Content for a viewer that produces plain text."""
    return {
        "kind": "text",
        "text": body,
        "language": language,
        "truncated": truncated,
    }


def markdown(body: str, truncated: bool = False) -> dict:
    """Content the host renders as Markdown.

    Headings, lists, tables and code fences all work. Use this over
    :func:`table` when the answer has sections rather than columns.
    """
    return {"kind": "markdown", "text": body, "truncated": truncated}


def fact(label: str, value: object, wide: bool = False) -> dict:
    """One thing a file says about itself: a label and what it says for it.

    ``wide`` puts the value on its own line under the label — for a
    description, a comment, a list of keywords. Everything else reads better
    beside its label.
    """
    return {"label": label, "value": "" if value is None else str(value), "wide": wide}


def fact_group(title: str, facts: List[dict]) -> dict:
    """Facts that belong together, under a heading.

    **Grouping is the plugin's job and it is most of the work.** Two hundred
    EXIF tags in one column is a hex dump with names on it; what a reader wants
    is the camera, the exposure, when and where, and the rest kept back. The
    host draws the groups it is given in the order it is given them and knows
    nothing about cameras.
    """
    return {"title": title, "facts": [f for f in facts if f]}


def facts(
    groups: List[dict],
    note: Optional[str] = None,
    picture: Optional[bytes] = None,
    mime_type: str = "image/jpeg",
) -> dict:
    """What a file says about itself — the answer a describer returns.

    ``note`` is a sentence under the groups: what could not be read, or that
    the file carries nothing beyond its own size. It never stands in for the
    groups — a file with nothing to say still says how big it is.

    ``picture`` is a picture that *is* one of the facts: the cover art inside a
    recording, which the file says about itself as much as the album name is.
    Bytes, because it is inside the file and there is no path to it; the host
    draws it with the same engine as any other picture, above the groups.
    """
    answer = {
        "groups": [g for g in groups if g and g.get("facts")],
        "note": note,
    }
    if picture:
        answer["picture"] = base64.b64encode(picture).decode("ascii")
        answer["pictureType"] = mime_type
    return answer


def image(data: bytes, mime_type: str = "image/png") -> dict:
    """Content for a viewer that produces an image the host can decode."""
    return {
        "kind": "image",
        "data": base64.b64encode(data).decode("ascii"),
        "mimeType": mime_type,
    }


def file(url: str) -> dict:
    """Content that is *a file*, drawn by whichever viewer claims it.

    **You point at it; the host works out who can show it.** "Which viewer
    handles a `.png`" is the question the application answers every time
    somebody presses F3, and it has a register of them — so a plugin with
    something it cannot draw itself says where the thing is and stops.

    That is better than it sounds. You do not carry an image decoder, and then
    a second one for the next format; and the day a better viewer for that
    format is installed, your plugin shows it without being touched.

    The url can be anywhere the host can read, **including a file system your
    own plugin serves**: a git tool points at a blob inside a commit with its
    own `git://` url and gets a picture back.
    """
    return {"kind": "file", "url": url}


def column(
    label: str,
    flex: int = 0,
    width: Optional[float] = None,
    align: str = "left",
    kind: str = "text",
) -> dict:
    """One column of a :func:`table`.

    ``flex`` is its share of whatever width is left once the fixed columns have
    had theirs; ``width`` is what it takes when it does not stretch. Give one or
    the other — a column that says neither stretches, which is what a bare
    string column has always done.

    ``align`` is ``left``, ``right`` or ``centre``. ``kind`` is what the column
    *holds* — ``text``, ``mono`` for anything read column by column, ``chips``,
    ``icon`` — and never how it should look: the host owns that.
    """
    spec: dict = {"label": label, "align": align, "kind": kind}
    if flex:
        spec["flex"] = flex
    if width is not None:
        spec["width"] = width
    return spec


def chip(text: str, kind: str = "") -> dict:
    """A pill in front of a cell's text — a branch, a tag, a label.

    ``kind`` says what it *is*: ``head``, ``branch``, ``tag``, or anything else,
    which is drawn plainly. The colour comes from the palette, not from here.
    """
    return {"text": text, "kind": kind}


def cell(
    text: str = "",
    chips: Optional[List[dict]] = None,
    icon: Optional[str] = None,
    email: Optional[str] = None,
) -> dict:
    """One cell of a :func:`row`, for when a plain string is not enough.

    ``email`` belongs to an ``avatar`` column and is the person's address.
    **Sending one asks the host to go and find their picture** — it looks it up
    at Gravatar, keyed on that address. So send it when your user has said they
    want pictures, and not merely because you happen to have it: without one
    the ring carries their initials and nothing leaves the machine.
    """
    body: dict = {"text": text}
    if chips:
        body["chips"] = chips
    if icon is not None:
        body["icon"] = icon
    if email:
        body["email"] = email
    return body


def graph(
    lane: int = -1,
    closes: Optional[List[int]] = None,
    parents: Optional[List[int]] = None,
    through: Optional[List[List[int]]] = None,
    merge: bool = False,
    tint: int = -1,
    entering: Optional[List[int]] = None,
    leaving: Optional[List[int]] = None,
) -> dict:
    """What the braid does at one row of a history.

    Give it to :func:`row` as ``graph=``, and give the table a column of
    ``kind="graph"`` to draw it in. Everything here is in **lanes**, which is
    the half only you can work out; where a lane falls in pixels, how a line
    bends and what colour it is are the host's, which is why none of them
    appear here.

    * ``lane`` — where this commit's mark sits. ``-1`` draws lines and no mark.
    * ``closes`` — lanes arriving at the **top** edge that end at this commit:
      its own, unless nothing points at it yet, plus anything merging in.
    * ``parents`` — lanes at the **bottom** edge its parents carry on down.
    * ``through`` — every other line crossing the row, as ``[top, bottom]``.

    A **tint** is not a colour, it is *which line this is*: a number the host
    turns into one. Lanes are packed as branches end, so a line drifts left
    down a long history, and a colour taken from the lane would change under
    the reader's eyes with nothing having happened. Say which line, and the
    same line keeps the same colour the whole way down.

    * ``tint`` — this commit's own line. Left out, the lane stands for it.
    * ``entering`` — the tint of each line at the **top** edge, by top lane.
    * ``leaving`` — the same at the **bottom** edge, by bottom lane.

    :func:`lay_out` will work all of it out from a list of commits, and is what
    you want unless your history is not a git one.
    """
    body: dict = {"lane": lane}
    if closes:
        body["closes"] = closes
    if parents:
        body["parents"] = parents
    if through:
        body["through"] = through
    if merge:
        body["merge"] = True
    if tint >= 0:
        body["tint"] = tint
    if entering:
        body["entering"] = entering
    if leaving:
        body["leaving"] = leaving
    return body


def lay_out(commits: List[tuple]) -> List[dict]:
    """Turns ``[(hash, [parent hash, ...]), ...]`` into one :func:`graph` each.

    The commits must be in the order they are drawn — newest first, the order
    ``git log`` prints. Anything named as a parent but not in the list (the
    history was cut off at some depth) simply ends its line, which is the truth
    about what is on screen.

    **Lanes are packed as they free up.** A branch that ends gives its lane
    back and everything to the right shifts in, which is what keeps a long
    history two or three lanes wide instead of fifty. The shift is not a break:
    it comes out in ``through`` as a line entering at one lane and leaving at
    another, and the host draws that as a bend.

    **A tint belongs to the line, not to the lane.** It is handed out when a
    line begins, carried along every shift, and given back when the line ends,
    so scrolling past a shift shows the same line in the same colour — see
    :func:`graph`. Where two lines meet, **the older one keeps its tint**: the
    trunk is the oldest line on screen and it is the one that has to come out
    of a fork looking like itself.
    """
    open_lanes: List[Optional[str]] = []
    tints: List[Optional[int]] = []
    # When each open line began, in rows. Only ever compared, never drawn.
    born: List[Optional[int]] = []
    rows: List[dict] = []

    for age, (commit_hash, parent_hashes) in enumerate(commits):
        before = list(open_lanes)
        entering = [-1 if t is None else t for t in tints]

        # Where this commit was expected. A tip nobody points at takes a new
        # lane on the right, and a tint of its own with it.
        if commit_hash in open_lanes:
            mine = open_lanes.index(commit_hash)
            tint = tints[mine]
            mine_born = born[mine]
        else:
            mine = len(open_lanes)
            tint = _free_tint(tints)
            mine_born = age
            open_lanes.append(commit_hash)
            tints.append(tint)
            born.append(age)

        # Every lane expecting this commit ends here; they are the branches
        # being merged in, and its own lane is one of them.
        closes = [i for i, held in enumerate(before) if held == commit_hash]

        after: List[Optional[str]] = list(open_lanes)
        after_tints: List[Optional[int]] = list(tints)
        after_born: List[Optional[int]] = list(born)
        for i in closes:
            after[i] = None
            after_tints[i] = None
            after_born[i] = None
        after[mine] = None
        after_tints[mine] = None
        after_born[mine] = None

        # A parent already expected somewhere keeps that lane rather than
        # getting a second one. Without this a branch whose parent is on the
        # trunk draws two lines down to the same commit, and the picture says
        # there are two of it.
        #
        # The first parent that needs a lane carries this commit's own line on
        # down — same line, same tint. The others begin lines of their own,
        # which is what the second parent of a merge is.
        for parent in parent_hashes:
            if parent in after:
                continue
            if after[mine] is None:
                at = mine
            elif None in after:
                at = after.index(None)
            else:
                at = len(after)
                after.append(None)
                after_tints.append(None)
                after_born.append(None)
            after[at] = parent
            if at == mine:
                after_tints[at] = tint
                after_born[at] = mine_born
            else:
                # Not a tint this very row gave back, either: a line ending at
                # this commit and one beginning under it in the same colour
                # read as one line passing through.
                after_tints[at] = _free_tint(
                    after_tints + [entering[i] for i in closes]
                )
                after_born[at] = age

        # This commit's line found no lane of its own, so it ends here — into
        # the line its first parent is already standing in. The older of the
        # two carries on: a branch forked off the trunk long after the trunk
        # began, and it is the trunk that has to come out of the fork looking
        # like itself. Which is the only place a line changes colour, and the
        # host draws the change over the join rather than at a corner.
        if after[mine] is None and parent_hashes and parent_hashes[0] in after:
            joined = after.index(parent_hashes[0])
            if mine_born < after_born[joined]:
                after_tints[joined] = tint
                after_born[joined] = mine_born

        # Pack, and remember where everything went.
        moved: Dict[int, int] = {}
        packed: List[Optional[str]] = []
        leaving: List[int] = []
        packed_born: List[Optional[int]] = []
        for i, held in enumerate(after):
            if held is None:
                continue
            moved[i] = len(packed)
            packed.append(held)
            leaving.append(-1 if after_tints[i] is None else after_tints[i])
            packed_born.append(after_born[i])

        through = [
            [i, moved[i]]
            for i, held in enumerate(before)
            if held is not None and i != mine and i not in closes and i in moved
        ]
        parents = sorted(
            i for i, held in enumerate(packed) if held in parent_hashes
        )

        rows.append(
            # The mark keeps the lane it arrived in, not the one the packing
            # gave it. A line that shifts does so *below* the commit, which is
            # where it actually happens: the branch beside it ended here.
            graph(
                lane=mine,
                closes=closes,
                parents=parents,
                through=through,
                merge=len(parent_hashes) > 1,
                tint=tint,
                entering=entering,
                leaving=leaving,
            )
        )
        open_lanes = packed
        tints = [t if t >= 0 else None for t in leaving]
        born = packed_born

    return rows


def _free_tint(taken: List[Optional[int]]) -> int:
    """The lowest tint no open line is using.

    Lowest rather than next: the host's wheel of hues is short, and lines that
    are on screen together want to be as far apart on it as they can. A tint a
    finished branch gave back is free again — a colour is only ever wanted for
    telling apart what is drawn at the same time.
    """
    in_use = {t for t in taken if t is not None and t >= 0}
    tint = 0
    while tint in in_use:
        tint += 1
    return tint


def row(cells: List[object], role: str = "normal",
        braid: Optional[dict] = None) -> dict:
    """One row of a :func:`table`, saying what kind of row it is.

    ``braid`` is what :func:`graph` returns, for a table with a graph column.
    Named apart from the function so that ``from xverb import graph`` and
    ``row(..., braid=graph(...))`` can both be written on the same line.

    ``role`` is ``normal``, ``strong`` for the row the eye should land on first,
    ``dim`` for one that is there but not the point, or ``accent`` for one that
    is different in a way worth noticing. Say what the row *is*; the palette
    decides what that looks like.
    """
    body: dict = {"cells": cells, "role": role}
    if braid is not None:
        body["graph"] = braid
    return body


def table(columns: List[object], rows: List[object],
          cursor: Optional[int] = None) -> dict:
    """A listing with columns — an archive, a log, anything read row by row.

    The short form is a list of labels and a grid of strings::

        table(["Name", "Size"], [["notes.txt", "1.2 kB"]])

    and it is drawn as one of the application's own listings: the panel's font,
    a cursor the arrow keys move, Enter to open the row. Use :func:`column` and
    :func:`row` when the shape matters — which column stretches, which is a
    hash, which row is worth noticing.

    ``cursor`` puts the cursor on a row. **Send it once, not on every draw.**
    You are asked again whenever the cursor moves, so a table that named the
    cursor every time would drag it back and the arrow keys would fight you.
    It is for the answer that *opens* a page — coming back to where the reader
    was, rather than to the top of a list they had already walked down.
    """
    body: dict = {"kind": "table", "columns": columns, "rows": rows}
    if cursor is not None and cursor >= 0:
        body["cursor"] = cursor
    return body


def tab(tab_id: str, label: str, detail: Optional[str] = None) -> dict:
    """One way of looking at a :func:`part`.

    Pressing it raises the ordinary ``button`` event carrying ``tab_id``, so
    tabs are answered the way everything else is: you redraw the part with the
    other content and say which tab is showing. The host keeps no second copy
    of what the other tabs would hold — it cannot know, and a tab that shows a
    stale answer is worse than one that costs a round trip.

    ``detail`` is a small count beside the label — how many files, how many
    changes — which is what makes a tab worth pressing before it is pressed.
    """
    body: dict = {"id": tab_id, "label": label}
    if detail is not None:
        body["detail"] = detail
    return body


def part(
    part_id: str,
    content: dict,
    weight: float = 1,
    title: Optional[str] = None,
    tabs: Optional[List[dict]] = None,
    showing: Optional[str] = None,
) -> dict:
    """One part of a :func:`split`.

    ``part_id`` is what the part is called, and every event from inside it
    carries it — which is the whole reason a page of several lists works. A row
    number answers "which row" and says nothing about which of three lists it
    was in.

    ``tabs`` are the :func:`tab` list drawn in the strip the ``title`` would have
    used, and ``showing`` says which one is up. The title does not go away — it
    moves to the right of them, where it goes on saying what all of them are
    about.

    ``weight`` is its share of the room *before* anybody drags the divider,
    relative to the other parts. Where the divider ends up is the user's and
    stays in the application: a plugin has no idea how tall the window is, and
    asking it would put a round trip inside a drag.
    """
    body: dict = {"id": part_id, "content": content, "weight": weight}
    if title is not None:
        body["title"] = title
    if tabs:
        body["tabs"] = tabs
        body["tab"] = showing or tabs[0]["id"]
    return body


def split(parts: List[dict], direction: str = "vertical") -> dict:
    """A page made of more than one thing, with a divider between them.

    ``direction`` is ``vertical`` — one above another, which is what a log with
    its detail underneath is — or ``horizontal`` for side by side.

    A part may hold a split of its own, which is how a log above, a list of
    files below and the difference beside them is written::

        split([
            part("log", log_table, weight=3),
            part("detail", split([
                part("files", files_table, weight=1),
                part("diff", text(patch, language="diff"), weight=2),
            ], "horizontal"), weight=2),
        ])
    """
    return {"kind": "split", "direction": direction, "parts": parts}


def segment(
    label: str,
    value: float,
    parent: int = -1,
    url: Optional[str] = None,
    color: Optional[str] = None,
    marked: bool = False,
    folder: bool = False,
    detail: Optional[str] = None,
) -> dict:
    """One wedge of a :func:`chart`.

    ``parent`` is the index of the wedge this one sits inside — an index into
    the same list — or -1 for the innermost ring. ``value`` is what the wedge
    is worth in whatever unit you like: only the ratios are used. ``url`` is
    what it stands for, and a wedge without one is drawn but cannot be pressed.

    Leave ``color`` alone unless you mean it. The host colours a chart from the
    theme, keeping a branch's shades together, and a plugin that picks its own
    colours is a plugin that looks wrong in half the themes.
    """
    wedge: dict = {"label": label, "value": value, "parent": parent}
    if url is not None:
        wedge["url"] = url
    if color is not None:
        wedge["color"] = color
    if marked:
        wedge["marked"] = True
    if folder:
        wedge["folder"] = True
    if detail is not None:
        wedge["detail"] = detail
    return wedge


def button(button_id: str, label: str, danger: bool = False,
           primary: bool = False,
           items: Optional[List[dict]] = None) -> dict:
    """A button along the top of a :func:`chart` or the bottom of a :func:`form`.

    Pressing it raises an event whose ``id`` is ``button_id``. ``danger`` draws
    it in the warning colour — for the one that deletes things.

    ``primary`` names the one the page is *for*: Ctrl+Enter presses it, and on
    a form it stays out of reach until every ``required`` field has something
    in it. A page with two of them has none — "the one" is the whole meaning.

    ``items`` are more buttons, drawn behind an arrow beside this one — commit,
    or commit and push. The face of the button goes on doing the usual thing
    with one press; each row raises its own id and carries the same fields.
    """
    body: dict = {"id": button_id, "label": label, "danger": danger}
    if primary:
        body["primary"] = True
    if items:
        body["items"] = items
    return body


def field(
    field_id: str,
    kind: str = "text",
    label: str = "",
    value: str = "",
    hint: str = "",
    lines: int = 1,
    checked: bool = False,
    required: bool = False,
) -> dict:
    """One thing a :func:`form` asks for.

    ``kind`` is ``text`` for a line, ``lines`` for a message — which grows into
    whatever room the part gives it — or ``check`` for a switch.

    ``value`` is what it starts with, and **the user's typing wins over it**:
    a view that redraws because a file was staged must not take back the
    sentence being written beside it. Send a *different* value and the field
    takes it — which is how ticking "amend" fills in the last message.

    ``required`` is answered by the host, not by you: the primary button waits
    for it. Asking would mean a round trip per keystroke.
    """
    body: dict = {"id": field_id, "kind": kind}
    if label:
        body["label"] = label
    if value:
        body["value"] = value
    if hint:
        body["hint"] = hint
    if lines != 1:
        body["lines"] = lines
    if checked:
        body["checked"] = True
    if required:
        body["required"] = True
    return body


def form(fields: List[dict], buttons: Optional[List[dict]] = None) -> dict:
    """Content the user fills in — the one kind that answers back.

    Everything else here goes one way: you describe, the host draws, the user
    presses a row. A commit message is a sentence somebody types, and
    :func:`ask` is yes or no, which is why this exists.

    **Nothing is sent while it is typed.** Pressing a button raises the usual
    ``button`` event, and that event carries what every field held —
    ``event.values``, by field id, strings for text and booleans for checks.
    A keystroke does not cross the pipe, so a form is as quick as the keyboard.

    Put it in a :func:`part` beside the lists it is about::

        split([
            part("files", staged_and_unstaged, weight=2),
            part("message", form(
                [field("text", kind="lines", hint="Message", required=True),
                 field("amend", kind="check", label="Amend")],
                [button("commit", "Commit", primary=True)],
            ), weight=1),
        ])
    """
    content: dict = {"kind": "form", "fields": fields}
    if buttons:
        content["buttons"] = buttons
    return content


def nodes(
    nodes: List[dict],
    links: Optional[List[dict]] = None,
    groups: Optional[List[dict]] = None,
    notes: Optional[List[dict]] = None,
    layout: str = "given",
    direction: str = "lr",
    truncated: bool = False,
) -> dict:
    """A graph of boxes and the wires between them.

    A ComfyUI workflow, an n8n export, a Node-RED tab: files that *are* a node
    graph. The reader turns one into this and the host draws it — boxes, pins,
    wires, groups, notes, the keyboard and every colour.

    **Say what a node is, never what colour it is.** ``role`` is one of
    ``event``, ``flow``, ``pure``, ``input``, ``output``, ``variable``,
    ``note``, ``group``, ``error``, ``normal``, and the palette answers for how
    each looks — the same rule a grammar follows for code. A wire may carry a
    ``type`` (``LATENT``, ``MODEL``); wires of one type share a colour, taken
    from the theme's own wheel.

    ``layout`` is ``given`` when the file carries coordinates, which is the
    usual case, and ``layered`` to have the host work them out.

    ``width`` on a node is optional and usually best left out: a box is as wide
    as its text in the font the user chose, which is not knowable here.

    A wire naming a node that is not in ``nodes`` is dropped by the host, and
    the page says how many were.
    """
    return {
        "kind": "nodes",
        "layout": layout,
        "direction": direction,
        "nodes": nodes,
        "links": links or [],
        "groups": groups or [],
        "notes": notes or [],
        "truncated": truncated,
    }


def node(
    id: str,
    title: str,
    subtitle: Optional[str] = None,
    role: str = "normal",
    x: float = 0,
    y: float = 0,
    width: Optional[float] = None,
    collapsed: bool = False,
    group: Optional[str] = None,
    badges: Optional[List[str]] = None,
    inputs: Optional[List[dict]] = None,
    outputs: Optional[List[dict]] = None,
    fields: Optional[List[dict]] = None,
) -> dict:
    """One box in a :func:`nodes` graph.

    ``fields`` is what makes a workflow readable: the seed, the step count, the
    prompt — the values the editor writes on the face of the node, and most of
    what somebody opened the file to see.
    """
    body: dict = {"id": str(id), "title": title, "role": role, "x": x, "y": y}
    if subtitle:
        body["subtitle"] = subtitle
    if width is not None:
        body["width"] = width
    if collapsed:
        body["collapsed"] = True
    if group:
        body["group"] = str(group)
    if badges:
        body["badges"] = badges
    if inputs:
        body["inputs"] = inputs
    if outputs:
        body["outputs"] = outputs
    if fields:
        body["fields"] = fields
    return body


def pin(id: str, label: str = "", type: Optional[str] = None) -> dict:
    """One socket on a node. ``type`` names a colour family, not a colour."""
    body: dict = {"id": str(id)}
    if label:
        body["label"] = label
    if type:
        body["type"] = type
    return body


def link(
    from_node: str,
    to_node: str,
    from_pin: Optional[str] = None,
    to_pin: Optional[str] = None,
    role: str = "data",
    type: Optional[str] = None,
    label: str = "",
) -> dict:
    """One wire.

    The pins are optional: Node-RED joins nodes rather than ports, and a wire
    with no pin named leaves the edge of the box instead of inventing one.
    """
    body: dict = {"from": str(from_node), "to": str(to_node), "role": role}
    if from_pin is not None:
        body["fromPin"] = str(from_pin)
    if to_pin is not None:
        body["toPin"] = str(to_pin)
    if type:
        body["type"] = type
    if label:
        body["label"] = label
    return body


def chart(
    segments: List[dict],
    label: Optional[str] = None,
    detail: Optional[str] = None,
    buttons: Optional[List[dict]] = None,
) -> dict:
    """Content the host draws as a ring chart.

    The segments are a flat list that forms a tree through ``parent``, which
    is a shape that survives JSON without nesting and one you can go on
    appending to as you discover more. ``label`` and ``detail`` are what the
    middle says — and the middle is also the way back out: pressing it raises
    ``activate`` with row -1.

    Pressing a wedge raises ``activate`` with its index, exactly as pressing a
    table row does; the secondary press raises ``mark``. What being marked
    means is yours to decide.
    """
    content: dict = {"kind": "chart", "segments": segments}
    if label is not None:
        content["label"] = label
    if detail is not None:
        content["detail"] = detail
    if buttons:
        content["buttons"] = buttons
    return content


def error(message: str) -> dict:
    """Content telling the user why a file could not be shown."""
    return {"kind": "error", "message": message}


def navigate(url: str, panel: str = "other", name: Optional[str] = None,
             back: Optional[str] = None) -> dict:
    """Asks the host to send a panel to ``url``.

    ``panel`` is ``other`` (the default and the usual one — the view is in a
    panel, so this moves the one beside it), ``self``, ``left`` or ``right``.
    Sending a view's own panel somewhere replaces the view with the listing:
    a panel cannot be in a folder and handed over at the same time.

    ``name`` is the row to leave the cursor on once it arrives. **"Show me this
    file" is a folder plus a name**: a panel can only be sent somewhere that
    lists, so point it at the folder and say which row you meant. You know;
    working it out on the other side would mean asking your own file system
    what kind of thing it is, across a pipe, to learn what you already knew.

    ``back`` names the way back, and only means anything when the panel being
    sent is the view's own. Sending your own panel somewhere closes you, so
    without this it is a one-way door: the host draws a control at the head of
    the path bar carrying this text, and pressing it puts the panel — and the
    panel beside it — back where they were and opens you again. Name it after
    what the reader is going back *to*: "Back to commits", not "Back".
    """
    body = {"type": "navigate", "url": url, "panel": panel}
    if name:
        body["name"] = name
    if back:
        body["back"] = back
    return body


def open_viewer(url: str) -> dict:
    """Asks the host to view a file, exactly as F3 on it would."""
    return {"type": "view", "url": url}


def notice(message: str) -> dict:
    """A line of feedback along the bottom of the window."""
    return {"type": "notice", "message": message}


def refresh(panel: str = "other") -> dict:
    """Asks the host to re-read a panel, after something was changed on disk."""
    return {"type": "refresh", "panel": panel}


def close() -> dict:
    """Asks the host to close this view."""
    return {"type": "close"}


def page(title: Optional[str] = None) -> dict:
    """Puts what this answer draws **on top of** what is on screen.

    A view is one page, which was enough until a page had a second thing to do
    — a log, and the commit being written out of it. Return this beside the
    content of the new page::

        return respond(content=commit_form(), actions=[page()],
                       title="Commit")

    The host keeps the page underneath, down to where every cursor was
    standing, and draws Back where a full-screen view already has one. Escape
    goes back a page before it closes anything, and **you do not have to draw
    your way out**: going back is the host redrawing what it kept, not another
    round trip. You are told after the fact, by a ``back`` event carrying how
    many pages are still stacked in ``event.row``.

    ``title`` is a convenience — the same thing ``respond(title=...)`` does —
    because a page that does not rename the bar looks like the one it covered.
    """
    body: dict = {"type": "page"}
    if title:
        body["title"] = title
    return body


def fullscreen() -> dict:
    """Asks the host to take this view out of its panel and fill the window.

    The same thing Ctrl+Shift+Enter does, asked for by the view. For a page
    that does not fit in half a window — a form beside two lists and a
    difference is the case it was built for. Nothing happens when the view is
    already full screen, or when it has no full-screen surface.

    **The view is opened again**, so this is a new session and nothing carries
    across: keep what the new one has to know somewhere of your own, keyed by
    something that survives — the repository, the folder — rather than by the
    session it was in.
    """
    return {"type": "fullscreen"}


def back() -> dict:
    """Asks the host to go back a page — what Escape would have done.

    For when the page you pushed has finished: the commit is written, the form
    was cancelled. Nothing is drawn in answer; the host has the page it kept.
    """
    return {"type": "back"}


def ask(
    ask_id: str,
    title: str,
    message: Optional[str] = None,
    confirm: Optional[str] = None,
    danger: bool = False,
) -> dict:
    """Puts a question to the user, in the application's own dialog.

    The one way a plugin gets to ask anything. A plugin cannot draw, so it
    describes the question and the host asks it — which also means every
    question in the application looks and behaves the same, whoever asked it.

    ``confirm`` is what the agreeing button says. Name it after what agreeing
    *does* — "Switch", "Discard", "Stage" — because a dialog whose buttons say
    Yes and No makes the reader work out which one they want from the question
    they have just read. ``danger`` is for what cannot be undone: the host
    draws it differently and does not make it the easy answer.

    The answer arrives as an ``answered`` event carrying ``event.id`` and
    ``event.accepted``, and it arrives **either way** — no is an answer, and a
    plugin told only about yes cannot tell it from a question that got lost.
    """
    return {
        "type": "ask",
        "id": ask_id,
        "title": title,
        "message": message,
        "confirm": confirm,
        "danger": danger,
    }


def delete(urls: List[str]) -> dict:
    """Asks the host to delete a set of locations.

    The host does it, not the plugin: it asks the user first, in the
    application's own words, and uses the recycle bin wherever there is one.
    The view is then told what actually went, as a ``deleted`` event carrying
    ``urls`` — which is not necessarily what was asked for, because the user
    may well have said no.
    """
    return {"type": "delete", "urls": list(urls)}


def respond(
    content: Optional[dict] = None,
    actions: Optional[List[dict]] = None,
    title: Optional[str] = None,
    status: Optional[str] = None,
    trail: Optional[List[str]] = None,
    menus: Optional[List[dict]] = None,
    commands: Optional[List[dict]] = None,
    context_menu: Optional[List[dict]] = None,
) -> dict:
    """What a view returns when it wants more than to draw.

    Every part is optional. Returning no ``content`` leaves on screen whatever
    is already there, which is what an answer that only moves the other panel
    should do — blanking the view the user is looking at is not a side effect
    of clicking a row in it.

    ``trail`` is where the view has walked to, outermost first. The host draws
    it where a panel keeps its path, and pressing a level raises a ``step``
    event carrying its index — so a view that goes into things gets the way
    back out that the panels already have, rather than inventing one.

    ``context_menu`` answers a ``mark`` event — the secondary press — with the
    rows to draw where the press landed, shaped like a menu's items. **A press
    that does something in private is a press nobody can use**: right-clicking
    a commit used to send the other panel into it with no word about it, and
    the same press on a working-tree file staged it instead. Say what the press
    offers and let the user pick. Answering with nothing keeps whatever the
    press did before, which is what a view that marks things wants.

    ``menus`` and ``commands`` are the view's own main menu and its buttons in
    the title bar, and are shown while it is full screen: the application's
    menus are about a listing that is not on screen then, so a view either puts
    its own there or leaves the strip empty. Picking a menu row and pressing a
    command both raise a ``button`` event carrying its ``id``. Both are kept
    until replaced, the way ``title`` and ``trail`` are; a menu sent with no
    items is how one is taken away.
    """
    result: dict = {}
    if content is not None:
        result["content"] = content
    if actions:
        result["actions"] = actions
    if title is not None:
        result["title"] = title
    if status is not None:
        result["status"] = status
    if trail is not None:
        result["trail"] = list(trail)
    if menus is not None:
        result["menus"] = list(menus)
    if commands is not None:
        result["commands"] = list(commands)
    if context_menu is not None:
        result["contextMenu"] = list(context_menu)
    return result


class ViewContext:
    """Where a view is, and what it is pointed at.

    Handed to every view handler. ``url`` is the location the view was opened
    on, or — for a view that follows the other panel — whatever that panel is
    on now. ``session`` tells one open copy of a view from another: the same
    view can be in both panels and full screen at once, each with its own
    state.

    ``other_url`` is where the *other* panel is pointing, for the tools that
    are about both sides of the application at once — comparing two folders is
    the whole of one. In a panel it is the panel not holding the view; full
    screen it is the panel that was not being worked in. It is None when there
    is no other side to speak of.
    """

    __slots__ = (
        "session",
        "surface",
        "url",
        "other_url",
        "is_directory",
        "selection",
    )

    def __init__(self, params: dict):
        self.session: str = params.get("session") or ""
        self.surface: str = params.get("surface") or "fullscreen"
        self.url: Optional[str] = params.get("url")
        self.other_url: Optional[str] = params.get("otherUrl")
        self.is_directory: bool = bool(params.get("isDirectory"))
        #: What was marked in the panel the view was opened from.
        self.selection: List[str] = list(params.get("selection") or [])

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "ViewContext(surface=%r, url=%r)" % (self.surface, self.url)


class ViewEvent:
    """Something the user did inside a view.

    ``kind`` is ``open`` the first time and when the host re-points the view,
    ``activate`` when a row was pressed, ``cursor`` when one was merely walked
    onto, and ``key`` for a key press — the last two only reaching views whose
    manifest sets ``"cursor": true`` and ``"keys": true``.
    """

    __slots__ = ("kind", "row", "key", "id", "accepted", "part", "urls",
                 "values", "marked", "from_part")

    def __init__(self, kind: str, params: Optional[dict] = None):
        event = params or {}
        self.kind: str = kind
        #: Index into the rows — or the wedges — the view last returned. -1 is
        #: the middle of a chart: the way back out.
        self.row: Optional[int] = event.get("row")
        #: ``enter``, ``escape``, ``backspace``, ``up``, ``down``, ``left``,
        #: ``right``, ``home``, ``end``, ``pageup``, ``pagedown``, or the
        #: character typed.
        self.key: Optional[str] = event.get("key")
        #: Which button was pressed, for a ``button`` event — or which
        #: question was answered, for an ``answered`` one.
        self.id: Optional[str] = event.get("id")
        #: What the user said, for an ``answered`` event. None for anything
        #: else, which is not the same as False.
        self.accepted: Optional[bool] = event.get("accepted")
        #: Which part of a :func:`split` it came from, empty when the content
        #: is not one. A row number answers "which row" and says nothing about
        #: which of three lists it was in.
        self.part: str = event.get("part") or ""
        #: What was actually deleted, for a ``deleted`` event. For a ``step``
        #: event the level pressed is in :attr:`row`.
        self.urls: List[str] = list(event.get("urls") or [])
        #: What a :func:`form` held when its button was pressed, by field id —
        #: strings for text, booleans for checks. Empty for every other event:
        #: nothing crosses the pipe while it is being typed.
        self.values: dict = dict(event.get("values") or {})
        #: Where a ``drop`` was picked up from. :attr:`part` is where it
        #: landed, and :attr:`marked` is which rows — by index into the part it
        #: came from, as it was drawn. Empty for every other event.
        #:
        #: **What a drop means is yours.** The host knows the rows were
        #: carried from one list to another and nothing else about it.
        self.from_part: str = event.get("from") or ""
        #: Which rows of :attr:`part` are picked out — Insert in a listing, or
        #: Ctrl and Shift with the mouse — in the order they are drawn.
        #:
        #: **Sent with every press from a listing**, so a view that can act on
        #: several rows never has to ask which ones. Empty is the ordinary
        #: case and means "the row it happened on"; acting on marks uses them
        #: up, exactly as it does in a panel.
        self.marked: List[int] = list(event.get("marked") or [])

    def __repr__(self) -> str:  # pragma: no cover - debugging aid
        return "ViewEvent(%r, row=%r, part=%r, key=%r, id=%r)" % (
            self.kind,
            self.row,
            self.part,
            self.key,
            self.id,
        )


class Plugin:
    """Collects a plugin's contributions and serves the host's requests."""

    def __init__(self, plugin_id: str, name: Optional[str] = None):
        self.id = plugin_id
        self.name = name or plugin_id
        #: What the user chose in Settings → Plugins, over the defaults the
        #: manifest declared. Filled in before any handler runs, and replaced
        #: whenever the user changes something.
        self.settings: Dict[str, object] = {}
        self._peer = RpcPeer()
        self._filesystems: Dict[str, FileSystem] = {}
        self._viewers: Dict[str, dict] = {}
        self._describers: Dict[str, dict] = {}
        self._views: Dict[str, dict] = {}
        self._commands: Dict[str, dict] = {}
        self._on_view_closed: List[Callable[[str, str], None]] = []
        self._on_shutdown: List[Callable[[], None]] = []
        self._on_settings: List[Callable[[dict], None]] = []
        #: The language the host is showing, as a code — `ru`, `de`, `en`.
        self.language: str = "en"
        self._strings: Dict[str, str] = {}
        self._register_methods()

    # -- contributions -----------------------------------------------------

    def add_filesystem(self, filesystem: FileSystem) -> FileSystem:
        """Registers a transport. Its ``scheme`` becomes navigable in a panel."""
        if not filesystem.scheme:
            raise ValueError("FileSystem.scheme must be set")
        self._filesystems[filesystem.scheme] = filesystem
        return filesystem

    def viewer(
        self,
        viewer_id: str,
        title: str,
        extensions: Optional[List[str]] = None,
        priority: int = 0,
        probe: Optional[Callable[[bytes], bool]] = None,
        produces: str = "",
        thumbnail: Optional[Callable[[str, int], Optional[bytes]]] = None,
    ):
        """Decorator registering a viewer for a set of file extensions.

        Use ``extensions=["*"]`` for a catch-all viewer; the host only falls
        back to it when nothing more specific claims the file.

        ``probe`` is the third way of claiming a file, and the one an extension
        cannot express. Every node-graph format is a ``.json``, and ``.json``
        belongs to the text viewer; a reader that won it outright would open
        ``package.json`` as an empty canvas. Given a probe, the host hands over
        the **first pages of the file** before it settles the order, and a
        viewer that answers yes goes ahead of everything claiming by extension
        alone::

            def looks_like_a_workflow(head: bytes) -> bool:
                return b'"widgets_values"' in head

            @plugin.viewer("nodes.graph", "Node graph", extensions=["json"],
                           priority=5, probe=looks_like_a_workflow)
            def graph(url): ...

        ``produces`` says **what kind of thing this viewer gives back** —
        `picture`, `sound`, `document`, `drawing`, `model`. A free word, and
        the host keeps no list of them: it is there to tell two viewers that
        they are in the same business. The film strip in a full-screen viewer
        walks every file that *any* viewer of the same kind opens, so a folder
        of `.jpg` beside `.heic` is one strip even though the machine's own
        decoder reads one and this plugin the other. Say nothing and the viewer
        is its own kind, which is what everything written before this said.

        ``thumbnail`` is asked for a **small copy** of a file — `(url, pixels)`,
        answering the picture as bytes of PNG or JPEG, or ``None``. It is asked
        **only after the machine's own decoder has refused**, so it is for the
        formats no engine reads: `.xcf` anywhere, `.psd` and `.tga` off macOS.
        Most of them carry a cheap preview inside — a composite, a smaller
        level, an EXIF thumbnail — and taking that is the point; decoding a
        whole 24-megapixel file to make a 128-pixel square is work nobody
        asked for. It has eight seconds, and a strip that stalls is worse than
        a strip with a name in one cell.

        The head is **bytes and may stop mid-character**: it is the start of a
        file, not a document. Answer from what is there; the question is asked
        again for every file, and a wrong yes is worse than a missed one.
        """

        def decorate(function: Callable[[str], dict]):
            self._viewers[viewer_id] = {
                "spec": {
                    "id": viewer_id,
                    "title": title,
                    "extensions": [e.lstrip(".").lower() for e in (extensions or [])],
                    "priority": priority,
                    "probe": probe is not None,
                    "produces": produces,
                    "thumbnails": thumbnail is not None,
                },
                "handler": function,
                "probe": probe,
                "thumbnail": thumbnail,
            }
            return function

        return decorate

    def view(self, view_id: str, title: str, description: str = ""):
        """Decorator registering a view — a surface of the plugin's own.

        A viewer answers "what is in this file"; a view answers anything else:
        a map of the disk, a comparison of two folders, a queue of transfers.

        The handler is called with ``(context, event)`` and returns content, or
        :func:`respond` when it also wants something of the host::

            @plugin.view("disk.map", "Disk map")
            def disk_map(context, event):
                if event.kind == "activate":
                    return respond(actions=[navigate(rows[event.row])])
                return table(["Folder", "Size"], rows_for(context.url))

        **Where** the view appears comes from the manifest, not from here — see
        ``surfaces`` and ``follows`` in ``plugin.json``. A handler taking only
        the context is accepted too, for a view that never handles an event.
        """

        def decorate(function: Callable[..., object]):
            try:
                arity = len(inspect.signature(function).parameters)
            except (TypeError, ValueError):  # builtins, C callables
                arity = 2
            self._views[view_id] = {
                "spec": {"id": view_id, "title": title, "description": description},
                "handler": function,
                "arity": arity,
            }
            return function

        return decorate

    def describer(
        self,
        describer_id: str,
        title: str,
        extensions: Optional[List[str]] = None,
        names: Optional[List[str]] = None,
    ):
        """Decorator registering what this plugin can say *about* a file.

        **Separate from a viewer, and that is the whole point of it.** Who
        draws a photograph and who can read what is written inside it are not
        the same question: on both machines a JPEG is decoded by the system's
        own engine through a declarative plugin that runs no Python at all, so
        its EXIF would have nobody to come from if facts were something a
        viewer returned. A describer is asked by extension, and answers for a
        file whoever happens to be drawing it::

            @plugin.describer("pictures.about", "About this picture",
                              extensions=["jpg", "jpeg", "png", "heic"])
            def about(url):
                return facts([
                    fact_group("Camera", [fact("Model", "X-T5")]),
                ])

        ``title`` is what the panel is called while it is showing this — the
        plugin names it because the plugin knows what kind of thing it is
        describing. Return :func:`facts`; returning nothing is taken as a file
        that says nothing about itself, which is an answer rather than a
        failure.

        **There is no priority and no probe.** A file has one set of facts, so
        the first describer that claims the name answers; two plugins claiming
        one format is a collision in the collection, not a race to run.
        """

        def decorate(function: Callable[[str], dict]):
            self._describers[describer_id] = {
                "spec": {
                    "id": describer_id,
                    "title": title,
                    "extensions": [
                        e.lstrip(".").lower() for e in (extensions or [])
                    ],
                    "names": [n.lower() for n in (names or [])],
                },
                "handler": function,
            }
            return function

        return decorate

    def command(self, command_id: str, title: str, description: str = ""):
        """Decorator registering a command the user can invoke from the app.

        Return nothing and the command simply did something. Return content —
        :func:`text`, :func:`table`, :func:`markdown` — and it is shown as a
        page.

        **Return a :func:`form` and the command becomes a conversation.** The
        page draws the fields with whatever values you put in them, and pressing
        a button calls this same handler again with what was on screen::

            @plugin.command("thing.rename", "Rename with options")
            def rename(args):
                if not args.get("button"):
                    return form(
                        [field("name", value=current_name(), label="Name"),
                         field("lower", kind="check", label="Lower case")],
                        [button("go", "Rename", primary=True)],
                    )

                values = args.get("values") or {}
                name = values.get("name") or ""
                if not name:
                    return form(...)          # ask again, prefilled as you like
                do_the_work(name, values.get("lower"))
                return None                   # done: the page closes

        ``args`` is empty on the first call, and afterwards holds ``button``
        (the id of the one pressed) and ``values`` (every field by id — strings
        for text, booleans for checks). Answer with another form to ask again,
        with content to show a result, or with ``None`` to say it is over and
        let the page go.

        Nothing crosses the pipe while the user types: the values arrive with
        the press. A handler that raises leaves the page exactly as it was, with
        what was typed still in it, and the failure is said in a remark — an
        error is the moment somebody is most likely to want to press again.
        """

        def decorate(function: Callable[[dict], object]):
            self._commands[command_id] = {
                "spec": {
                    "id": command_id,
                    "title": title,
                    "description": description,
                },
                "handler": function,
            }
            return function

        return decorate

    def on_view_closed(
        self, function: Callable[[str, str], None]
    ) -> Callable[[str, str], None]:
        """Registers a hook called with ``(view_id, session)`` when a view is
        closed, so anything a session cached can be dropped.

        A plugin that keeps nothing per session needs no hook. Sessions are
        also all over when the plugin shuts down, so this is about freeing
        memory in a long-running plugin, not about correctness.
        """
        self._on_view_closed.append(function)
        return function

    def on_shutdown(self, function: Callable[[], None]) -> Callable[[], None]:
        """Registers cleanup to run when the host stops this plugin."""
        self._on_shutdown.append(function)
        return function

    def on_settings_changed(
        self, function: Callable[[dict], None]
    ) -> Callable[[dict], None]:
        """Registers a hook run when the user changes this plugin's settings.

        ``self.settings`` is already the new values when it runs. Only needed
        by a plugin that has to act on a change — one that simply reads
        ``plugin.setting(...)`` where it needs it needs no hook at all.
        """
        self._on_settings.append(function)
        return function

    def _use_language(self, code: str) -> None:
        """Reads `i18n/<code>.json` from beside this plugin's own manifest.

        **The same file the host reads**, keyed on the English text the same
        way — so a plugin has one catalogue, and translating it covers both the
        words in its manifest and the words it builds while it runs.
        """
        self.language = code
        self._strings = {}
        if not code or code == "en":
            return
        # Beside the entry script, which is what the host launched and
        # therefore where `plugin.json` and `i18n/` are.
        here = os.path.dirname(os.path.abspath(sys.argv[0]))
        path = os.path.join(here, "i18n", "%s.json" % code)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                loaded = json.load(handle)
        except Exception:  # noqa: BLE001 - no catalogue is the ordinary case
            return
        if isinstance(loaded, dict):
            self._strings = {
                str(k): str(v) for k, v in loaded.items() if isinstance(v, str) and v
            }

    def tr(self, source: str, values: Optional[dict] = None) -> str:
        """[source] in the user's language, or [source] itself.

        The English sentence is the key, written out in full where it is used —
        so the code reads as what the user sees, and a string nobody has
        translated falls back by construction rather than by a rule. Named
        placeholders, `{like_this}`, because a translated sentence puts them in
        a different order::

            plugin.tr("{count} file(s) in the archive", {"count": 12})
        """
        text = self._strings.get(source, source)
        for name, value in (values or {}).items():
            text = text.replace("{%s}" % name, str(value))
        return text

    def setting(self, key: str, default: object = None) -> object:
        """One value from :attr:`settings`, declared in ``plugin.json``."""
        value = self.settings.get(key)
        return default if value is None else value

    # -- host services -----------------------------------------------------

    def log(self, message: str, level: str = "info") -> None:
        """Writes to the plugin log shown in Settings → Plugins."""
        self._peer.notify("host.log", {"level": level, "message": str(message)})

    def read_file(self, url: str, max_bytes: int = 1 << 20, offset: int = 0) -> bytes:
        """Reads a file through the host, whatever file system it lives on.

        A viewer written against this works on the local disk and on any
        transport another plugin provides, without knowing the difference.
        """
        chunks = []
        total = 0
        while total < max_bytes:
            want = min(1 << 18, max_bytes - total)
            reply = self._peer.call(
                "host.read", {"url": url, "offset": offset + total, "length": want}
            )
            data = base64.b64decode(reply.get("data") or "")
            if data:
                chunks.append(data)
                total += len(data)
            if reply.get("eof") or not data:
                break
        return b"".join(chunks)

    def list_dir(self, url: str) -> List[dict]:
        """Lists a directory through the host, on whatever transport owns it.

        Each entry is a dict with ``name``, ``url``, ``kind`` (``file``,
        ``dir`` or ``link``), ``size``, ``modified`` and ``hidden``. The ``..``
        row never appears: it is something the panel draws, not something on
        the disk, and a walk that followed it would not end.

        This is the counterpart of :meth:`read_file` for a view that has to
        cross a tree rather than open one file, and it goes the same way — so
        the same code walks the local disk, an archive and an FTP server.
        """
        reply = self._peer.call("host.list", {"url": url})
        return list((reply or {}).get("entries") or [])

    def stat(self, url: str) -> Optional[dict]:
        """One entry, in the shape :meth:`list_dir` returns, or None."""
        return self._peer.call("host.stat", {"url": url})

    def update_view(
        self,
        view_id: str,
        session: str,
        content: Optional[dict] = None,
        title: Optional[str] = None,
        status: Optional[str] = None,
        trail: Optional[List[str]] = None,
        actions: Optional[List[dict]] = None,
        menus: Optional[List[dict]] = None,
        commands: Optional[List[dict]] = None,
    ) -> None:
        """Redraws an open view without having been asked.

        The answer to work that takes longer than a call may: return at once
        with what little you know, do the rest on a thread of your own, and
        push what you find. ``session`` is the one from the context — an update
        for a copy of the view nobody is holding any more is simply dropped, so
        a scan outliving its view does no harm.
        """
        message: dict = {"viewId": view_id, "session": session}
        if content is not None:
            message["content"] = content
        if title is not None:
            message["title"] = title
        if status is not None:
            message["status"] = status
        if trail is not None:
            message["trail"] = list(trail)
        if actions:
            message["actions"] = actions
        # A push can change the menu as well — a row that is only sensible
        # while a scan is running has to be able to grey out when it stops.
        if menus is not None:
            message["menus"] = list(menus)
        if commands is not None:
            message["commands"] = list(commands)
        self._peer.notify("host.viewUpdate", message)

    # -- lifecycle ---------------------------------------------------------

    def run(self) -> None:
        """Serves the host until it asks the plugin to shut down."""
        self._peer.serve_forever()

    # -- RPC surface -------------------------------------------------------

    def _register_methods(self) -> None:
        peer = self._peer
        peer.register("initialize", self._initialize)
        peer.register("shutdown", self._shutdown)
        peer.register("settings.changed", self._settings_changed)
        peer.register("command.invoke", self._invoke_command)
        peer.register("viewer.open", self._open_viewer)
        peer.register("viewer.probe", self._probe_viewer)
        peer.register("describe.open", self._describe)
        peer.register("viewer.thumbnail", self._thumbnail)
        peer.register("view.open", self._open_view)
        peer.register("view.event", self._view_event)
        peer.register("view.close", self._close_view)
        peer.register("fs.roots", self._fs_roots)
        peer.register("fs.defaultLocation", self._fs_default_location)
        peer.register("fs.list", self._fs_list)
        peer.register("fs.stat", self._fs_stat)
        peer.register("fs.read", self._fs_read)
        peer.register("fs.write", self._fs_write)
        peer.register("fs.finish", self._fs_finish)
        peer.register("fs.mkdir", self._fs_mkdir)
        peer.register("fs.delete", self._fs_delete)
        peer.register("fs.rename", self._fs_rename)
        peer.register("fs.copyWithin", self._fs_copy_within)

    def _initialize(self, params: dict) -> dict:
        host_api = params.get("apiVersion")
        if host_api != API_VERSION:
            raise RpcError(
                "Plugin speaks API %s, host speaks %s" % (API_VERSION, host_api)
            )
        # Before anything is registered, so a plugin can decide what it
        # contributes from its own settings.
        self.settings = dict(params.get("settings") or {})
        self._use_language(str(params.get("language") or "en"))
        return {
            "apiVersion": API_VERSION,
            "schemes": [
                {
                    "scheme": scheme,
                    # What a panel standing in this scheme may do, told rather
                    # than found out: the host dims the keys that cannot work
                    # and marks the panel, instead of letting the user press
                    # F8 in a commit and read a refusal.
                    "writable": bool(getattr(fs, "writable", True)),
                    "icon": getattr(fs, "icon", "") or "",
                }
                for scheme, fs in self._filesystems.items()
            ],
            "viewers": [v["spec"] for v in self._viewers.values()],
            "views": [v["spec"] for v in self._views.values()],
            "commands": [c["spec"] for c in self._commands.values()],
            "describers": [d["spec"] for d in self._describers.values()],
        }

    def _shutdown(self, _params: dict) -> None:
        for hook in self._on_shutdown:
            try:
                hook()
            except Exception as failure:  # noqa: BLE001 - cleanup must not block exit
                print("shutdown hook failed: %s" % failure, file=sys.stderr)
        self._peer.stop()
        return None

    def _settings_changed(self, params: dict) -> None:
        self.settings = dict(params.get("settings") or {})
        for hook in self._on_settings:
            try:
                hook(self.settings)
            except Exception as failure:  # noqa: BLE001 - one bad hook is not fatal
                print("settings hook failed: %s" % failure, file=sys.stderr)
        return None

    def _invoke_command(self, params: dict):
        command = self._commands.get(params.get("id"))
        if command is None:
            raise RpcError('Unknown command "%s"' % params.get("id"))
        return command["handler"](params.get("args") or {})

    def _open_viewer(self, params: dict) -> dict:
        viewer = self._viewers.get(params.get("viewerId"))
        if viewer is None:
            raise RpcError('Unknown viewer "%s"' % params.get("viewerId"))
        result = viewer["handler"](params["url"])
        if not isinstance(result, dict):
            return error("Viewer returned %s, expected content" % type(result).__name__)
        return result

    def _describe(self, params: dict) -> dict:
        describer = self._describers.get(params.get("describerId"))
        if describer is None:
            raise RpcError('Unknown describer "%s"' % params.get("describerId"))
        result = describer["handler"](params["url"])
        if not isinstance(result, dict):
            return facts([], note="This file says nothing about itself.")
        return result

    def _thumbnail(self, params: dict) -> dict:
        viewer = self._viewers.get(params.get("viewerId"))
        make = (viewer or {}).get("thumbnail")
        if make is None:
            return {"data": ""}
        small = make(params["url"], int(params.get("pixels") or 128))
        if not small:
            return {"data": ""}
        return {"data": base64.b64encode(small).decode("ascii")}

    def _probe_viewer(self, params: dict) -> dict:
        """Does this viewer claim *this* file, going by its first pages?

        A refusal is the answer to everything that goes wrong here — an unknown
        viewer, a viewer with no probe, a probe that raises. The host then
        orders by extension, which is what it did before any of this existed,
        so the worst a broken probe costs is one keypress.
        """
        viewer = self._viewers.get(params.get("viewerId"))
        if viewer is None or viewer.get("probe") is None:
            return {"claims": False}
        head = params.get("head") or ""
        try:
            raw = base64.b64decode(head) if head else b""
        except Exception:  # noqa: BLE001
            return {"claims": False}
        try:
            return {"claims": bool(viewer["probe"](raw))}
        except Exception:  # noqa: BLE001
            return {"claims": False}

    def _open_view(self, params: dict) -> dict:
        return self._call_view(params, ViewEvent("open"))

    def _view_event(self, params: dict) -> dict:
        event = params.get("event") or {}
        return self._call_view(params, ViewEvent(event.get("type") or "", event))

    def _call_view(self, params: dict, event: ViewEvent) -> dict:
        view = self._views.get(params.get("viewId"))
        if view is None:
            raise RpcError('Unknown view "%s"' % params.get("viewId"))

        context = ViewContext(params.get("context") or {})
        handler = view["handler"]
        # A view that never handles an event has no use for the second
        # argument. Which form was written is settled when the decorator runs,
        # not by calling and catching TypeError — that would swallow a real
        # TypeError from inside the handler and call it a second time.
        result = handler(context, event) if view["arity"] > 1 else handler(context)

        if result is None:
            return {}
        if not isinstance(result, dict):
            return error("View returned %s, expected content" % type(result).__name__)
        return result

    def _close_view(self, params: dict) -> None:
        for hook in self._on_view_closed:
            try:
                hook(params.get("viewId") or "", params.get("session") or "")
            except Exception as failure:  # noqa: BLE001 - one bad hook is not fatal
                print("view close hook failed: %s" % failure, file=sys.stderr)
        return None

    # -- file system dispatch ---------------------------------------------

    def _resolve(self, url: str) -> FileSystem:
        scheme = url.split(":", 1)[0]
        filesystem = self._filesystems.get(scheme)
        if filesystem is None:
            raise RpcError('This plugin does not serve "%s:"' % scheme)
        return filesystem

    def _by_scheme(self, params: dict) -> FileSystem:
        scheme = params.get("scheme") or ""
        filesystem = self._filesystems.get(scheme)
        if filesystem is None:
            raise RpcError('This plugin does not serve "%s:"' % scheme)
        return filesystem

    def _fs_roots(self, params: dict) -> list:
        return [root.to_json() for root in self._by_scheme(params).roots()]

    def _fs_default_location(self, params: dict) -> dict:
        return {"url": self._by_scheme(params).default_location()}

    def _fs_list(self, params: dict) -> dict:
        entries = self._resolve(params["url"]).list(params["url"])
        return {"entries": [entry.to_json() for entry in entries]}

    def _fs_stat(self, params: dict):
        entry = self._resolve(params["url"]).stat(params["url"])
        return None if entry is None else entry.to_json()

    def _fs_read(self, params: dict) -> dict:
        url = params["url"]
        length = int(params.get("length", 1 << 18))
        data = self._resolve(url).read(url, int(params.get("offset", 0)), length)
        return {
            "data": base64.b64encode(data).decode("ascii"),
            "eof": len(data) < length,
        }

    def _fs_write(self, params: dict) -> None:
        url = params["url"]
        mode = params.get("mode", "create")

        # The end of a file is its own call, never a write of no bytes: an FTP
        # backend reads anything that is not "append" as STOR, and a zero-byte
        # STOR truncates the file that was just uploaded. So the two closing
        # modes are answered here and never reach write() at all, which is what
        # lets every transport written before this go on working untouched.
        if mode in ("close", "abort"):
            self._resolve(url).close_write(url, mode == "close")
            return None

        filesystem = self._resolve(url)

        # What the host knows before the bytes start, and only on the first
        # chunk. A separate call rather than two more arguments to write(),
        # because write() is implemented by every transport already written and
        # its signature is a contract.
        if mode == "create":
            modified = params.get("modified")
            filesystem.begin_write(
                url,
                params.get("length"),
                None if modified is None else modified / 1000.0,
            )

        data = base64.b64decode(params.get("data") or "")
        filesystem.write(url, data, mode)
        return None

    def _fs_finish(self, params: dict) -> None:
        self._resolve(params["url"]).finish_writes(params["url"])
        return None

    def _fs_mkdir(self, params: dict) -> None:
        self._resolve(params["url"]).mkdir(params["url"])
        return None

    def _fs_delete(self, params: dict) -> None:
        self._resolve(params["url"]).delete(params["url"])
        return None

    def _fs_rename(self, params: dict) -> None:
        self._resolve(params["from"]).rename(params["from"], params["to"])
        return None

    def _fs_copy_within(self, params: dict) -> bool:
        return self._resolve(params["from"]).copy_within(params["from"], params["to"])
