# Writing an xverb extension

There are two runtimes. Pick the weakest one that does the job.

| | `declarative` | `python` |
| --- | --- | --- |
| What it is | JSON naming a built-in primitive | a real program |
| Runs | in the app, no interpreter | as a child process, JSON-RPC over stdio |
| Platforms | all, including iOS and Android | desktop only |
| Can add a file system | no | yes |
| Can parse a new format | only what primitives cover | yes |
| Failure mode | a bad spec is skipped with a warning | a crash kills only that plugin |

This mirrors Blender, which has the same split: Python add-ons for logic, and
data-only extensions — node groups, themes — for everything expressible as a
composition of what the application already ships.

Current API version: **1**.

## Target Python version

**Write plugins against Python 3.12. Nothing older is accepted, and nothing
newer is what your code will actually run on.**

The app runs its own interpreter — one pinned build, the same on every machine
and every operating system:

| | |
| --- | --- |
| Language version plugins target | **3.12** |
| Pinned build | `cpython-3.12.13+20260807` |
| Source | [python-build-standalone](https://github.com/astral-sh/python-build-standalone) |
| Platforms from that one release | Windows x64, macOS arm64 and x64, Linux x64 and arm64 |

This is a rule rather than a preference, and it exists because the alternative
was tried first. When the app used whichever `python3` it found on PATH, the
same plugin ran on 3.9 on a stock Mac, on 3.12 on Windows and on 3.14 where
Homebrew had been used — a five-version spread that no plugin author can test
against. An interpreter the app controls is the only way a plugin written once
behaves the same everywhere.

Consequences worth knowing before you write anything:

- **The standard library is what you get.** The managed interpreter is not the
  user's Python, so their `site-packages` is not on your path. Plugins that
  need a third-party package cannot assume it is installed.
- **A newer interpreter on the machine is ignored,** deliberately. Finding 3.14
  and using it would put your plugin back on an interpreter you never tested.
- **`XVERB_PYTHON` still overrides everything**, for development. It is an
  escape hatch for trying another interpreter, not a supported configuration to
  ship against.
- **The floor is enforced, not documented-and-hoped.** An interpreter below 3.12
  is refused with a message naming what was found, instead of starting and
  failing later on syntax it cannot parse.

When the pin moves to a newer Python, it moves in a release of its own, and the
API version above is bumped with it.

## Bundled versus installed

The app carries a copy of the viewers so that a fresh install can open a file
at all — the core cannot display one on its own. **They are a first copy, not a
home:** on the first launch each is written into the plugins folder and becomes
an ordinary installed plugin, and the collection updates it from then on. Once
handed over it is never handed over again, so one you delete stays deleted.

An installed copy therefore *wins* over the one that ships, which is the whole
point: the newer copy is the one the collection put there. What ships fills in
only for a plugin that is not installed at all — a build that cannot write to
the plugins folder, or a launch before the first one finished.

**Only declarative extensions are bundled**, and that is the rule rather than
what happened to fit: pure data loads on every platform, including the ones
where running plugin code is impossible, so bundling it costs nothing and
excludes nobody. Anything with code in it — FTP, SMB, the archive viewer —
ships in the collection instead, where it can be released on its own schedule
rather than waiting for a release of the app.

## Installing

Settings → Plugins reads
[xsm909/xverb-plugins](https://github.com/xsm909/xverb-plugins)
on its own, and more sources can be added by address — `owner/name`, a browser
URL, or a link to a `.tar.gz`. A repository needs nothing prepared: the app
downloads the branch tarball and reads the folders, so a plugin is installable
the moment it is committed.

Installing by hand works too. That page also shows the plugins directory for
your platform — drop a folder in and press Rescan.

A debug build also scans the working directory, which `flutter run` sets to the
project root, so a `plugins/` folder in a checkout is picked up with nothing
copied anywhere — which is how a plugin is worked on without reinstalling it
after every edit. Only a debug build does this: a released app must not load
code out of whatever directory it was started from.

Otherwise, or to point the app at a plugin collection kept somewhere else:

```
XVERB_PLUGINS=/path/to/xverb-plugins/plugins
XVERB_PYTHON=/path/to/python3     # optional, overrides the managed interpreter
```

The `xverb` SDK is unpacked from the app bundle at startup and put on
`PYTHONPATH`, so `import xverb` works with nothing installed. Beyond the
SDK, plugins get the standard library of the pinned interpreter and nothing
else — see [Target Python version](#target-python-version). The app manages no
virtual environments and installs no packages, so a plugin that needs one has
to vendor it next to `main.py`.

## Manifest

```json
{
  "id": "com.example.thing",
  "name": "Thing",
  "version": "0.1.0",
  "description": "One line, shown in the plugin manager.",
  "category": "Tools",
  "author": "you",
  "homepage": "https://example.com",
  "apiVersion": 1,
  "runtime": "python",
  "entry": "main.py",
  "platforms": ["windows", "macos", "linux"],
  "pythonMin": "3.12",
  "schemes": ["thing"],
  "containers": [
    {"scheme": "thing", "title": "Thing bundle", "extensions": ["thg"]}
  ],
  "viewers": [
    {"id": "thing.view", "title": "Thing", "extensions": ["thg"],
     "priority": 10, "produces": "picture"}
  ],
  "describers": [
    {"id": "thing.about", "title": "About this thing", "extensions": ["thg"]}
  ],
  "views": [
    {
      "id": "thing.map",
      "title": "Thing map",
      "icon": "chart",
      "surfaces": ["fullscreen", "panel", "locations"],
      "follows": "location"
    }
  ],
  "commands": [
    {"id": "thing.do", "title": "Do the thing"}
  ],
  "settings": [
    {"key": "depth", "label": "How deep to look", "type": "integer", "default": 3}
  ]
}
```

A scheme may be written as a bare name, as above, or as an object when it has
something to say about itself: `{"scheme": "git", "writable": false, "icon":
"history"}`. Both forms are read, so nothing already written has to change —
and what the running plugin reports from `initialize` says the same thing, from
the `writable` and `icon` attributes on the `FileSystem` class.

`apiVersion` **is the host's major version** — the first number of `A.B.C.D`. A
plugin declaring `apiVersion: 1` runs on every Xverb `1.x`, whatever the other
three parts say, and on no other major. It must match exactly; a mismatch is
refused rather than guessed at.

That is the whole of the compatibility promise, and it is the reason the major
moves: it changes when the host/plugin protocol breaks, and at no other time. A
release that adds features without touching the protocol moves the second
number, so nothing you have written stops working. When the first number moves,
assume it does. `platforms` may be omitted to mean "all". The `schemes`, `viewers`,
`describers`, `views` and `commands` in the manifest are a declaration for the
plugin manager
— what actually gets registered is what the plugin reports from `initialize`, so
the two should agree. A view is the one case where the manifest wins outright:
`surfaces` and `follows` are read from it and nowhere else, because they decide
where the view can be reached and the SDK's decorator does not carry them.

`icon` is either one of the names the host draws — `chart`, `code`, `folder`,
`archive` and a handful more — or **the name of a picture beside your
`plugin.json`**, which is anything with a dot in it: `"icon": "icon.png"`. A
picture is drawn as it is, unrecoloured, because a mark that follows the
palette is not a mark. Only a plain file name is accepted, not a path: an icon
is not a way to read the disk. If the file is missing the host falls back to
the shape rather than to a broken box.

`category` is what the plugin manager files this under. It shows shelves first
and the extensions inside them second, so a plugin without one is a plugin
nobody browses to. The published collection requires it; the app falls back to
guessing from what the manifest contributes, which keeps an older extension
working but puts it wherever the guess lands. Use one of **Tools**, **Viewers**,
**Transports**, **Archives**, **Appearance** or **Development** unless you have
a reason not to — the point of a shelf is that similar things share it.

`pythonMin` may be omitted, and usually should be: the host already guarantees
[the target version](#target-python-version), so declaring `"3.12"` states what
is true anyway. Set it only when the plugin needs something newer than everyone
targets — an interpreter below it is refused with both versions named, instead
of the plugin starting and dying on a `SyntaxError` that points at a line
number rather than at the cause.

## Speaking the user's language

Ship an `i18n/<code>.json` beside your `plugin.json`, keyed on **the English
text itself**:

```json
{
  "PDF as Markdown": "PDF как Markdown",
  "Document": "Документ",
  "Pages to read at most": "Сколько страниц читать"
}
```

That is the whole of it. The keys are the sentences you already wrote — nothing
has to be renamed, nothing needs an identifier, and a string you have not
translated falls back to English by construction rather than by a rule. The
codes are the ones the application ships: `ru`, `de`, `es`, `fr`, `ja`, `ko`.

**The host looks it up for everything you declared** — your name and description
in the manager, a viewer's or a view's title, a command's label, a setting's
label, note and choices. You do nothing.

**You look it up for everything you build while running.** The host cannot
translate a sentence it has never seen, so a Python plugin gets the language at
`initialize` and reads the same file:

```python
plugin.tr("This file carries no tags — only what its header says.")
plugin.tr("{count} file(s) in the archive", {"count": 12})
```

`plugin.language` is the code in force. Placeholders are named and written
`{like_this}`, because a translated sentence puts them in a different order and
a positional `%s` cannot survive that.

A **declarative** plugin has no code to run, which is exactly why the manifest
half is the host's job: otherwise half the plugins in the world could never
speak anything but English.

## Settings

A plugin declares the settings it wants and the host does the rest: it draws
the form, stores the answers, and hands them over. There is no settings screen
to write, which is the same bargain the connection dialog makes — the plugin
declares, the host renders.

```json
"settings": [
  {"key": "depth", "label": "How deep to look", "type": "integer", "default": 3},
  {"key": "follow", "label": "Follow links", "type": "boolean", "default": false},
  {
    "key": "units",
    "label": "Units",
    "type": "choice",
    "default": "si",
    "options": [
      {"value": "si", "label": "Metric"},
      {"value": "imperial", "label": "Imperial"}
    ],
    "note": "Small print under the input."
  }
]
```

`type` is one of `text`, `integer`, `boolean` or `choice`; `options` may be
objects as above or bare strings when the value reads well enough as its own
label. `hint`, `note` and `hiddenWhen` work as they do in a connection field —
`hiddenWhen` names a boolean setting that hides this one when it is on.

There is no `password` setting. Settings live in ordinary preferences, which is
no place for a secret; declare a connection instead, where the password goes to
the platform key store.

Only what the user *changed* is stored, so revising a `default` in a later
version reaches everyone who never touched that field.

Keys beginning `host.` are **reserved**: the app keeps its own answers about a
plugin there — where each command appears (`host.surface.<id>`) and where each
view does (`host.views.<id>`) — and strips them from what the plugin is told. Do
not declare one.

## Where a command appears

Every command is in the Tools menu, filed under the plugin's `category`. A
command may also ask for an icon in the application's title bar:

```json
"commands": [
  {"id": "thing.do", "title": "Do the thing", "icon": "memory", "inTitleBar": true}
]
```

`inTitleBar` is the *default*, not the decision: Settings → Plugins → the
plugin's own settings offers Tools menu, title bar, both, or nowhere, and what
the user picked wins. The title bar shows three icons and folds the rest behind
a `…` button. `icon` names one of the marks the host knows — `memory`, `cloud`,
`archive`, `view`, `image`, `table`, `text`, `code`, `terminal`, `folder`,
`info`, `chart` — and anything else draws a neutral one.

The same rule runs through [views](#views), which say `surfaces` instead and can
be in several places at once: a plugin declares what it can reach, the user
picks from that, and the user wins. Commands and views share the title-bar row
and the arrangement the user made of it.

The values arrive in `initialize` — before any handler runs, so a plugin can
decide what it contributes from them — and again whenever the user changes
something:

```python
@plugin.command("thing.do", "Do the thing")
def do_thing(args):
    return {"depth": plugin.setting("depth", 3)}

@plugin.on_settings_changed
def reconfigure(settings):
    cache.clear()
```

A whole number that declares **both `minimum` and `maximum`** — with a `step`
for how far one move goes — is drawn as a slider rather than as a box, the same
one the appearance settings use. Declare a range where there is one to show; a
number with no end to it, like how many commits to read, stays typed. A box also
takes digits only, so a setting that may go below zero needs the range to be
reachable at all.

A plugin that simply reads `plugin.setting(...)` where it needs it needs no
hook. A declarative extension may declare settings too — it has no code to read
them with, so only the host does, for the ones the host knows the meaning of.
There is one: **`weightOffset`**, a shift of the interface's font weight on the
appearance settings' own hundred scale (−300 to 300, in steps of 100), applied
to the text a viewer draws. A monospaced family reads thinner than the interface
at the same number, and that is a fact about a viewer rather than about the
application.

## Declarative extensions

A declarative extension is a `plugin.json` and nothing else. Each viewer carries
a `render` block naming one primitive and configuring it.

```json
{
  "id": "com.example.csv",
  "name": "CSV",
  "version": "1.0.0",
  "apiVersion": 1,
  "runtime": "declarative",
  "viewers": [
    {
      "id": "example.csv",
      "title": "Table",
      "extensions": ["csv"],
      "priority": 20,
      "render": {
        "kind": "table",
        "source": "csv",
        "delimiter": "auto",
        "hasHeader": true,
        "maxBytes": 4194304,
        "maxRows": 5000
      }
    }
  ]
}
```

### The primitives

| `kind` | Options | Result |
| --- | --- | --- |
| `text` | `encoding` (`utf-8`, `latin1`), `transform` (`none`, `json-pretty`), `syntax`, `maxBytes` | selectable monospaced text; `json-pretty` also colours it |
| `hex` | `maxBytes` | offset / bytes / ASCII dump |
| `image` | `maxBytes` | zoomable image; the host decodes PNG, JPEG, GIF, WebP, BMP |
| `table` | `source` (`csv`, `tsv`, `json`, `lines`), `delimiter`, `hasHeader`, `maxRows`, `maxBytes` | a data table |
| `audio` | `maxBytes` | a sound, played by the machine's own engine, drawn as its waveform. See [Sound](#sound) |

`delimiter: "auto"` sniffs `,`, `;`, tab and `|` from the first line. The CSV
reader handles quoted fields, doubled quotes, and separators or newlines inside
quotes. `source: "json"` expects a top-level array — of objects (columns are the
union of keys, in first-seen order) or of arrays (columns are numbered).

Every primitive caps how much it reads and reports `truncated` when it hits the
cap, so pointing a viewer at a huge file degrades instead of hanging.

A `render` block naming a kind this build does not implement is skipped with a
warning in the plugin log; the rest of the extension still loads. That is what
lets a newer extension load on an older app without breaking it.

### Colouring a language

`"syntax": "dart"` on a `text` render colours the file as Dart; `"syntax":
"auto"` colours it as whatever language claims its extension. What a language
*is* comes from a `grammars` block, which any plugin may carry — a plugin with
no code at all, or a Python one alongside its own contributions.

```json
"grammars": [
  {
    "id": "ini",
    "name": "INI and config",
    "extensions": ["ini", "cfg", "conf"],
    "caseSensitive": false,
    "lineComment": [";", "#"],
    "blockComment": [["/*", "*/"]],
    "strings": [
      {"open": "\"", "close": "\"", "escape": "\\", "multiline": false}
    ],
    "keywords": [],
    "types": [],
    "constants": ["true", "false"],
    "linePatterns": [
      {"match": "\\[[^\\]]*\\]", "role": "meta"}
    ]
  }
]
```

The host reads the file once, left to right, with that grammar. `linePatterns`
are matched at the head of a line, after its indent, and are how a section
heading or a key before its `=` is picked out; everything else is found in
order — comment, string, number, word.

**A grammar names roles, never colours.** The roles are `keyword`, `type`,
`constant`, `number`, `string`, `comment`, `meta`, `punctuation` and `plain`;
what each looks like comes from the appearance settings, so a file coloured by
somebody else's grammar still belongs to the user's palette.

A grammar cannot describe nesting, cannot look at more than one line except
through the string and comment rules that say they are `multiline`, and cannot
say what a word *means*. That is the trade for a language costing a block of
data rather than a build. Anything beyond it is a Python viewer producing its
own content.

### What you cannot do declaratively

Add a file system, run a command, offer a view, parse a format no primitive
covers. Those need the Python runtime — a view answers events, and answering
takes code. The `zip-viewer` example exists to mark that line.

## Python extension points

### Viewers

The core cannot display a file. F3 collects every viewer that claims the file,
sorts them, and opens the best one; Shift+F3 lets the user pick.

**Whoever names the type comes first**, whatever their priority, and `priority`
breaks ties among those that name it. A viewer may also declare
`"fallback": true` — or `"*"` among its extensions, which says the same thing —
to take a file nothing else claims. The two are not exclusive: the text viewer
names the types it is really for *and* takes anything unknown, which is why an
unfamiliar file opens as text with the hex dump one Shift+F3 away, rather than
the other way round.

A viewer returns *content*, not widgets — plugins run in Python and cannot draw
Flutter. The host renders these shapes:

| Helper | Renders as |
| --- | --- |
| `text(body, language=None, truncated=False)` | Monospaced, selectable text. `language="json"` is coloured — names, values, numbers and atoms, in the panel's own palette — and `language="diff"` is coloured as a unified diff |
| `image(data: bytes, mime_type)` | A picture, decoded by the host, on a canvas with fit, 1:1 and zoom |
| `table(columns, rows)` | A listing with columns — the log, the archive, anything read row by row. See [Tables](#tables) |
| `file(url)` | **A file, drawn by whichever viewer claims it.** See below |
| `error(message)` | A message explaining why nothing is shown |
| `{"kind": "vector", …}` | A drawing made of shapes. See [Drawings](#drawings) |
| `{"kind": "mesh3d", …}` | A model, turned and lit by the host |
| `{"kind": "audio", "url": …}` | A sound, played by the host. See [Sound](#sound) |

**The rule the last two are instances of, and it is the one to follow when
adding another:** a plugin sends what the *format* means, already free of
whatever the format calls it, and the host owns everything that depends on the
window — size, colour, magnification, lighting, the keyboard. A plugin that
rasterises a drawing, or that ships a picture of a model, has thrown away the
thing the host was going to do well.

```python
from xverb import Plugin, table

plugin = Plugin("com.example.zip")

@plugin.viewer("zip.list", "Archive contents", extensions=["zip"], priority=10)
def list_archive(url):
    import io, zipfile
    data = plugin.read_file(url, max_bytes=64 << 20)
    with zipfile.ZipFile(io.BytesIO(data)) as archive:
        return table(
            ["Name", "Size", "Compressed"],
            [[i.filename, i.file_size, i.compress_size] for i in archive.infolist()],
        )

plugin.run()
```

### Sound

`{"kind": "audio", "url": "file:///…"}` — the file to play, and nothing else.

**Sound is the one content that is a place rather than a payload.** Everything
else a plugin returns is the file already read and turned into something: text,
a table, a list of shapes. A sound is not, and cannot be — playing it means
decoding it as it goes, an hour of music is not something to hold in memory, and
the machine already has a player that does both. So the plugin says *where the
sound is* and the host hands that to `AVAudioPlayer` on macOS, Media Foundation
on Windows or GStreamer on Linux.

Which formats play therefore belongs to the machine, not to the application: mp3,
wav and m4a everywhere, flac on both recent systems, aiff and caf on the Mac, wma
on Windows, and on Linux whatever GStreamer has plugins for — which is usually
everything, ogg included, because that platform ships the decoders the other two
do not. A file the machine will not read is said so in a sentence, the way an
unreadable picture is — not treated as a broken file.

The url must name a local file. A plugin serving something over its own protocol
should copy it out first, which is what the declarative `audio` primitive does
for a file inside an archive or on a server.

What the host draws around it: the shape of the whole file taken off the decoded
samples — or, with `S`, the same file seen as frequencies, a spectrum a slice of
time at a time over its whole length — a playhead on real time, the codec, rate,
channels, depth, bitrate, size and true peak level. Space plays and pauses, `W`
and `S` choose which way to look, the arrows seek, the digits
jump through the file in tenths, up and down are the volume, and Escape stops it
— **a sound never goes on playing behind a closed viewer.** In a panel viewport
it does not start by itself, because a cursor walking down a folder of music
would otherwise fire off a track a step.

What the file's tags say — the title, who played it, the cover — is a different
question, and one a plugin that reads the format answers, not this contract.

### Drawings

`{"kind": "vector", "width": …, "height": …, "shapes": [...]}` — a flat list of
paths, drawn as paths, so the result stays sharp at any magnification. The
reader does everything the format knows about; what crosses is geometry and
colour and nothing else.

One shape:

```json
{
  "verbs": "<base64 bytes>",       // 0 move, 1 line, 2 cubic, 3 close
  "points": "<base64 float32>",    // 2 floats a point: 1 for a move or line, 3 for a cubic
  "fill": "#rrggbbaa",             // or null
  "stroke": "#rrggbbaa",
  "strokeWidth": 1.0,              // in the drawing's own units
  "evenOdd": false,
  "cap": "butt", "join": "miter",
  "fillGradient": {                // instead of a flat fill, where there is one
    "kind": "linear",              // or "radial"
    "from": [x, y], "to": [x, y],  // centre and focus for a radial
    "radius": 0.0,
    "stops": [{"at": 0.0, "colour": "#rrggbbaa"}],
    "spread": "pad"                // or "reflect", "repeat"
  }
}
```

**Everything is absolute and already resolved**: transforms composed down the
tree and applied to the coordinates, arcs cut into cubics, quadratics raised,
styles inherited and cascaded, fractions of a shape's own box turned into real
coordinates. There is exactly one thing the host is asked to work out, and it is
the magnification.

### Tables

A table is drawn as one of the application's own listings: the panel's font,
the panel's cursor, the arrow keys, Page Up and Down, Home and End, and Enter
to open the row under the cursor. None of that costs the plugin anything — it
sends columns and rows.

The short form is a list of labels and a grid of strings, and it still works
everywhere it ever did:

```python
table(["Name", "Size"], [["notes.txt", "1.2 kB"]])
```

The long form is for when the shape matters. **A column says how wide it is;
a row says what kind of row it is.** Both are described, never styled — the
palette is the application's, and a plugin that picked its own colours would be
a plugin that looks wrong in half the themes.

```python
table(
    [
        column("", width=22, kind="icon"),
        column("Commit", width=72, kind="mono"),
        column("Subject", flex=3),
        column("When", width=118, align="right"),
    ],
    [
        row(
            ["", "a1b2c3d",
             cell("The viewer keeps one bar", chips=[chip("main", "head")]),
             "2026-08-13 10:04"],
            role="accent",
        ),
    ],
)
```

| On a column | Means |
| --- | --- |
| `flex` | its share of whatever width is left. The default when nothing else is said |
| `width` | how wide it is when it does not stretch |
| `align` | `left`, `right` or `centre` |
| `kind` | `text`, `mono` (fixed-pitch — a hash, a size), `chips`, `icon`, `avatar`, `graph` |

A column that says neither `flex` nor `width` stretches — unless what it holds
has a width of its own, which `icon` and `graph` do.

| On a row | Means |
| --- | --- |
| `role` | `normal`, `strong` (the eye lands here first), `dim` (a heading over what is under it), `pending` (real, but not written down yet — drawn a fifth lighter), `accent` (something is different about this one) |

An `avatar` column takes the cell's text as a *person's name* and draws their
initials in a ring, with the name beside it.

`cell(name, email=...)` asks for their **picture** instead. That is the one
thing in this application that fetches because of what is on screen, so it is
built to be exactly that: it goes to **two hosts and no others** — GitHub for an
address GitHub itself handed out, Gravatar for anybody else — and both urls are
worked out *from the address* — a plugin cannot point it at a url of its own — it asks once per
address and remembers "there is none" as firmly as a picture, it keeps what it
finds on the disk, and **a row never waits for it**. The initials are drawn this
frame; a face replaces them if one ever arrives.

**So send an address when your user has asked for pictures, and not merely
because you have it.** Give the setting and let them answer — the git tool's is
off by default. Without an address nothing leaves the machine.

A cell is a string, or `cell(text, chips=[...], icon="...")`. In an `icon`
column the mark is drawn and the text becomes its tooltip, so a column of
`added / changed / deleted` reads as marks rather than as a column of words —
and the host colours the ones whose colour *is* their meaning (`added`,
`deleted`, `untracked`, `staged`, `conflict`) from the same green and red the
diff uses. A chip is a pill
in front of the text — `chip(text, kind)`, where `kind` is `head`, `branch`,
`tag`, or anything else, which is drawn plainly. `icon` names one from the
host's set.

Anything a newer app understands and this one does not is ignored, and the rest
of the same table still draws.

##### A page of more than one part

`split` holds other content, with a divider between them:

```python
split([
    part("log", log_table, weight=3),
    part("detail", split([
        part("files", files_table, weight=1),
        part("diff", text(patch, language="diff"), weight=2),
    ], "horizontal"), weight=2, title="b2f08b4 — what it says"),
])
```

`direction` is `vertical` (one above another) or `horizontal`. `weight` is a
part's share of the room *before* anybody drags the divider — where it ends up
is the user's and stays in the application, because a plugin has no idea how
tall the window is and asking it would put a round trip inside a drag.

A part may carry **tabs** instead of a title — `part(..., tabs=[tab("t.commit",
"Commit", "7"), tab("t.tree", "File Tree")], showing="t.commit")`. Pressing one
raises the ordinary `button` event with the tab's id, and the plugin answers
with the part drawn the other way. The host keeps no second copy of what the
other tabs would hold: it cannot know, and a tab showing a stale answer is
worse than one that costs a round trip. The title does not go away — it moves
to the right of the tabs.

**Every event from inside a split carries the part it came from**, as
`event.part`. A row number answers "which row" and says nothing about which of
three lists it was in. Each part keeps its own cursor, and the one with the keyboard is marked down
its edge. **Ctrl+Tab** walks to the next part and **Ctrl+Shift+Tab** back, on
both surfaces — in a panel plain Tab is the panel switch and always has been,
and a key that works on one surface and not the other is a key nobody trusts.
Full screen, plain Tab does it as well, because there is no second panel for it
to switch to.

Only the parts that *draw* something are walked to. A part that holds a split
of its own is a box, not a place the keyboard can be.

#### Following the cursor

A view whose manifest says `"cursor": true` is told when the cursor comes to
rest on a row, as a **`cursor`** event with the same `row` and `part` an
`activate` carries. That is what makes a log with its detail underneath feel
like one: you walk down the commits and the bottom half follows, with nothing
pressed.

The settling is the host's and is not negotiable — 120 ms, the same wait the
panel viewport has always had. Holding an arrow key walks a listing faster than
any round trip, and a view asked about every row on the way is a view that
cannot keep up. The same row twice is never sent twice, so a part that redraws
another part cannot chase its own tail.

Off by default: it costs a round trip every time somebody stops moving, and
most views have nothing to do with it.

### The braid

A `graph` column draws the shape of a history: lanes, the mark on each commit,
and the curves where one lane joins another. **The lanes are yours and the
drawing is the host's**, and the line between them is where it has to be —
which lane a commit belongs in is a question about the repository, and how wide
a lane is at this font size is a question about a widget.

`lay_out` answers the first from the thing git already tells you:

```python
from xverb import column, lay_out, row, table

commits = [(c.hash, c.parents) for c in log]      # newest first

table(
    [column("", kind="graph"), column("Subject", flex=1)],
    [
        row(["", c.subject], braid=braid)
        for c, braid in zip(log, lay_out(commits))
    ],
)
```

Work them out yourself with `graph(...)` if your history is not a git one. It
takes, all in lanes: `lane` (where the mark sits, `-1` for none), `closes`
(lanes arriving at the **top** edge that end at this commit — its own, plus
anything merging in), `parents` (lanes at the **bottom** edge its parents carry
on down), `through` (`[top, bottom]` for every other line crossing the row) and
`merge`.

The rule the picture depends on: **what leaves the bottom of one row is what
arrives at the top of the next.** Lanes pack in as they free up, and a shift is
a bend rather than a break — which is why `through` names two lanes and not
one.

There are no rows that are only a drawing. `git log --graph` prints those and
they had to be kept, because dropping them broke the lines; described this way
there is nothing to drop.

`plugin.read_file(url, max_bytes=..., offset=0)` reads through the **host**, so a
viewer works on the local disk and on any transport another plugin provides,
without knowing the difference. Only reach for `open()` when you specifically
mean the local file system.

### File systems

Subclass `FileSystem`, set `scheme`, implement what your transport supports, and
register it. Anything you leave unimplemented raises, and the host turns that
into a normal error in the panel — a read-only backend simply never implements
`write`, `mkdir`, `delete` or `rename`.

**Say so as well as leaving it out.** `writable = False` on the class tells the
host before anything is pressed: the keys that cannot work go dim in the F-key
bar and in the right-click menu, and the operations refuse without starting.
Leaving it to the exception means the panel offers Delete inside a commit and
then explains itself afterwards. `icon` names a mark from the host's table —
`history` for a commit, `archive` for a box of files — and the panel wears it
beside the path, in the accent colour, so nobody takes history for the working
tree.

```python
class CommitFs(FileSystem):
    scheme = "git"
    writable = False
    icon = "history"
```

```python
from xverb import DIRECTORY, Entry, FileSystem, Plugin, Root

class ThingFs(FileSystem):
    scheme = "thing"

    def roots(self):
        return [Root("thing:///", "Thing", "Example backend")]

    def list(self, url):
        return [Entry("readme.txt", size=12), Entry("sub", kind=DIRECTORY)]

    def read(self, url, offset, length):
        return b"hello world."[offset:offset + length]

plugin = Plugin("com.example.thing")
plugin.add_filesystem(ThingFs())
plugin.run()
```

Two plugins cannot serve the same scheme; the second one is skipped and a
warning goes to the plugin log.

### Files that are really folders

`containers` in the manifest says that files of a given type should be *entered*
rather than opened. Pressing Enter on one then turns its location into your
scheme instead of launching it, which is how an archive opens as a directory:

```json
"schemes": ["zip"],
"containers": [{"scheme": "zip", "extensions": ["zip", "jar"]}]
```

**The extension chooses the plugin, in both directions.** The same declaration
that makes Enter on `box.zip` step into it is what makes *"Pack into archive…"*
write one: the name typed into that dialog is read for its extension, and
whichever container claims it does the writing. A format is offered there only
when its plugin is running **and** its scheme is writable — a `writable = False`
file system goes on opening archives as folders and is never asked to create
one.

**What a container can *make* is a different list from what it can open**, and
`packs` is where it says so:

```json
"containers": [{
  "scheme": "tar",
  "title": "Tarball",
  "extensions": ["tgz", "tar", "gz", "bz2", "xz"],
  "packs": [
    {"extension": "tgz", "title": "Tarball, gzip"},
    {"extension": "txz", "title": "Tarball, xz"},
    {"extension": "tar", "title": "Tarball, no compression"}
  ]
}]
```

A bare `.gz` opens perfectly well and there is nothing sensible to create under
that name; a tarball can be made four ways and only the plugin knows what to
call them. Those titles are the plugin's own words because only the plugin knows
what the difference *is*.

They appear in the pack dialog's **Kind** list, in the order written here, and
picking one rewrites the extension in the name.

**No `packs` means it cannot be created**, and that is not a formality. It used
to fall back to the first extension a container claimed, which put *Playlist ·
.m3u* in the list of archive kinds: the playlist plugin opens an `.m3u` as a
folder and has no idea how to write one, so packing a folder into it failed on
the first file and on all fifty-seven after it. There is no reading of "can be
entered" that implies "can be made" — so a plugin that wants to be offered says
so here.

Unpacking needs nothing beyond this. **Extract here** and **Extract to a folder**
are the application's ordinary copy, out of the archive read as a directory, so
the progress, the collisions and the cancel are the ones every other copy uses,
and a plugin implements no unpack of its own.

The location the host hands you looks like

```
zip:///inner/path?from=file:///C:/temp/box.zip
```

— the path *within* the container, with the container itself in the `from`
query. Two consequences worth having: going up a level is ordinary path work
for the host, and the container can live on any transport, so a ZIP sitting on
an FTP server opens exactly like one on the disk. Read it back through
`plugin.read_file(from_url)` and the host resolves whatever that is.

`zip-viewer` in the plugin collection does exactly this, in about a hundred
lines.
It is read-only on purpose: writing into an archive means rewriting it, and a
panel that offers to move a file into a ZIP and then cannot is worse than one
that says no.

### Where a written file begins and ends

A write arrives as one `create` and then any number of `append`s. Before the
first of them the host says what it knows about the file:

```python
def begin_write(self, url, size, modified):
    ...
```

Either may be `None` — this is what the host knows, not what it promises.
`modified` is seconds since the epoch, the way an `Entry` counts them, and it is
here because **a date cannot be recovered afterwards**: a member goes into an
archive with whatever date it is given, and without this every file in a new
archive was stamped the moment it was packed. It is a call of its own rather
than two more arguments to `write`, because `write` is implemented by every
transport already written and its signature is a contract.

The host finishes the file with a **`close`** — or with **`abort`**, when the copy failed or was
cancelled part way through. Both reach the class as one method:

```python
def close_write(self, url, complete):
    ...
```

It does nothing by default, and a transport writing straight through has nothing
to add: the file was on the server after the last chunk. Override it where the
last chunk is not the end of the work. **An archive is the case it exists for**
— a member is not *in* one until its sizes and its central directory entry are
written, and until this call existed the last file of every pack stayed
unfinished. `complete=False` means throw the half-written member away rather than
sealing a truncated one in.

And when the whole operation is over — the copy, the move or the delete, not the
file — the backend that was written to is told once more:

```python
def finish_writes(self, url):
    ...
```

**A compressed tarball is what this is for.** There is no appending to one:
adding a file means writing the archive again, so fifty files would be fifty
rewrites of a growing archive. With this, members are staged and the archive is
written once. It is a hint about *timing* and never about correctness — whatever
is staged has to survive not being told, because a call that crosses a process is
a call that can be missed, and the worst that may cost is a panel showing
something out of date.

Note what the closing modes are *not*: a final write of no bytes. The FTP backend
reads any mode that is not `append` as `STOR`, and a zero-byte `STOR` truncates
the file that was just uploaded — so `close` and `abort` are answered before
`write` is reached, and every transport written before this went on working
untouched.

`split_url(url)` returns `(host, port, user, password, path)` for network
transports — credentials the user typed in the Go to dialog ride along in the
URL.

### Commands

```python
@plugin.command("thing.do", "Do the thing")
def do_thing(args):
    plugin.log("doing it with %r" % args)
    return {"ok": True}
```

Return nothing and the command simply did something. Return content and it is
shown as a page.

**Return a [`form`](#a-form-the-user-fills-in) and the command becomes a
conversation.** The page
draws the fields with the values you put in them, and pressing a button calls
the same handler again — `args` then holds `button`, the id of the one pressed,
and `values`, every field by id:

```python
@plugin.command("thing.rename", "Rename with options")
def rename(args):
    if not args.get("button"):
        return form(
            [field("name", value=current_name(), label="Name"),
             field("lower", kind="check", label="Lower case")],
            [button("go", "Rename", primary=True)],
        )

    values = args.get("values") or {}
    if not values.get("name"):
        return form(…)          # ask again, prefilled however you like
    do_the_work(values)
    return None                 # done: the page closes
```

Answer with another form to ask again, with content to show a result, or with
`None` to say it is over. Nothing crosses the pipe while the user types — the
values arrive with the press — and a handler that raises leaves the page as it
was, with what was typed still in it, saying so in a remark.

### Shutdown

```python
@plugin.on_shutdown
def cleanup():
    connection.close()
```

The host calls `shutdown`, waits three seconds, then kills the process.

### `thumbnail`: a small copy, for the strip

```python
def small(url, pixels):
    return a_png_at_most_this_wide(url, pixels)   # or None

@plugin.viewer("thing.view", "Thing", extensions=["thg"],
               produces="picture", thumbnail=small)
def view(url): ...
```

**Asked only after the machine's own decoder has refused.** The strip along the
bottom of a viewer gets its pictures from the engine, which decodes straight to
the size wanted and costs no process; this costs a call down the pipe and a
plugin doing real work. So it is for the formats no engine reads — `.xcf`
anywhere, `.psd` and `.tga` off macOS — which used to put a file's name in the
cell instead of a picture.

**Take the cheap preview if the format has one.** A composite, a smaller level,
an EXIF thumbnail: decoding a whole 24-megapixel file to make a 128-pixel square
is work nobody asked for. Eight seconds, and answering `None` puts the name
back, which is what was there before.

### `produces`: what kind of thing a viewer gives back

`picture`, `sound`, `document`, `drawing`, `model` — a free word, matched
exactly, and the host keeps no list of them. It is there to tell two viewers
that they are **in the same business**.

The film strip in a full-screen viewer walks every file that any viewer of the
same kind opens. Without this, a folder of `.jpg` beside `.heic` was two strips
— the machine's own decoder reads one and a Python reader the other — and the
strip stopped at the first `.heic`, telling the reader the folder ended there.

Say nothing and your viewer is its own kind, which is what everything written
before this said, and it keeps exactly the strip it had. A Python plugin has to
say it in the **decorator** as well as the manifest: what a running plugin
reports at `initialize` is what gets registered.

## Describers: what a file says about itself

```python
from xverb import Plugin, fact, fact_group, facts

@plugin.describer("thing.about", "About this thing", extensions=["thg"])
def about(url):
    head = plugin.read_file(url, max_bytes=1 << 20)
    return facts(
        [
            fact_group("Thing", [
                fact("Name", url.rsplit("/", 1)[-1]),
                fact("Made by", read_the_author(head)),
            ]),
        ],
        note="14 field(s) in the file.",
    )
```

The panel on the left of a viewer — the one a document's structure opens in —
shows this for a file that has no structure to show. `Ctrl+Shift+O`, or the
button in the title bar, which takes its name from the describer's `title`.

**A describer is not a viewer, and that is the whole reason it exists.** Who
draws a photograph and who can read what is written inside it are not the same
question: on both machines a JPEG is decoded by the *system's own engine*
through a declarative plugin that runs no Python at all, so its EXIF would have
nobody to come from if facts were something a viewer returned. A describer is
asked by extension and answers for a file whoever happens to be drawing it —
which is also why the sound viewer's tags and a picture's EXIF are one
contribution rather than two.

**Nothing is asked until somebody opens the panel.** Walking a folder of
photographs with an arrow key opens a file on every repeat, and reading the
metadata of each on the way past would be a call down the pipe for something
nobody has asked to see. Expect your describer to be called once, late, and
possibly never.

**Group, and leave things out.** EXIF has several hundred tags and a panel
listing all of them is a hex dump with names on it. Decide what a reader
actually wants, put it in `fact_group`s in the order it should be read, and say
in `note` how much was left — a summary that does not admit to being one is a
claim.

There is no priority and no probe. A file has one set of facts, so the first
describer claiming the name answers; two plugins claiming one format is a
collision in the collection rather than a race to run. `wide=True` on a fact
puts its value under its own label, for a description or a comment.

**A picture may be one of the facts.** `facts(..., picture=bytes,
mime_type="image/jpeg")` puts it above the groups — the cover art inside a
recording, which the file says about itself as much as the album name does.
Bytes, because it is inside the file and there is no path to point at; the host
draws it with the same engine as any other picture, and a cover it cannot decode
is a missing cover rather than a broken panel.

## Views

A **viewer** answers "what is in this file". A **view** answers anything else: a
map of the disk, a comparison of two folders, a queue of transfers. The two are
separate contributions because they are asked for in different ways — F3 on a
file resolves a viewer, whereas a view is picked by name, sent to a panel, or
opened full screen.

### Where a view can go

```json
"views": [
  {
    "id": "map.disk",
    "title": "Disk map",
    "description": "What is taking up the room",
    "icon": "chart",
    "surfaces": ["fullscreen", "panel", "locations"],
    "follows": "location",
    "keys": false
  }
]
```

| Surface | Where it is |
| --- | --- |
| `fullscreen` | A page of its own, over the whole client area |
| `panel` | One of the two file panels, in place of its listing |
| `locations` | The menu a panel drops on **Alt+F1 / Alt+F2**, under the drives |
| `menu` | The Tools menu, filed under the plugin's `category` |
| `titleBar` | An icon in the application's title bar |

`surfaces` is both what the view *can* do and where it appears by default, and
the user's own choice in Settings → Plugins can only narrow it. **Declare only
what actually works.** A view that draws a folder makes no sense pointed at
nothing, and a `locations` entry that cannot take the panel is an entry that
lies — so `locations` requires `panel`, and the host drops it otherwise.

Omitting `surfaces` means `["fullscreen"]`, which is the surface with no
prerequisites. A surface named here that this build has never heard of is
dropped with the rest kept, so a view written for a newer app still loads.

### Being pointed at something

`follows` is what makes a panel a viewport:

| `follows` | The view is re-opened on |
| --- | --- |
| `none` (default) | nothing — it keeps the location it was opened with |
| `location` | the directory the **other** panel is in |
| `cursor` | the entry under the **other** panel's cursor |

Navigate on the left, and a `cursor` view on the right redraws for whatever the
cursor is on. Moves are settled for 120 ms before anything is read, so holding
an arrow key down walks the listing instead of opening every file on the way.

The user gets a viewport over the existing viewers for free, with **Ctrl+Q** —
no plugin involved, and every viewer ever written works in it. Reach for
`follows` when the plugin wants to show something a viewer cannot.

### Writing one

```python
from xverb import Plugin, navigate, notice, respond, table

plugin = Plugin("com.example.map")

@plugin.view("map.disk", "Disk map")
def disk_map(context, event):
    rows = measure(context.url)          # your own work

    if event.kind == "activate":         # a row was pressed
        return respond(actions=[navigate(rows[event.row].url)])

    return respond(
        content=table(["Folder", "Size"], [[r.name, r.size] for r in rows]),
        title=context.url,
        status="%d folders" % len(rows),
    )

plugin.run()
```

The handler takes `(context, event)` and returns content — the same four shapes
a viewer returns — or `respond(...)` when it wants more than to draw. A view
that never handles an event may take just `(context)`.

`context` carries where the view is:

| | |
| --- | --- |
| `context.url` | what it is pointed at, or `None` |
| `context.other_url` | where the **other** panel is, for tools about both sides |
| `context.is_directory` | whether that is a folder |
| `context.surface` | `fullscreen`, `panel`, `locations`, `menu`, `titleBar` |
| `context.selection` | what was marked in the panel it was opened from |
| `context.session` | which open copy of the view this is |

The same view can be in both panels and full screen at once, each with its own
state; `session` is what tells them apart, and is `left`, `right` or `page`.
`@plugin.on_view_closed` is called with `(view_id, session)` when one is closed,
for a plugin with something cached to drop.

`event.kind` is one of:

| `kind` | Raised by | Carries |
| --- | --- | --- |
| `open` | the view opening, or the host re-pointing it | — |
| `activate` | a row or a wedge being pressed | `event.row`, `event.part` |
| `mark` | the **secondary** press on one | `event.row`, `event.part` |
| `button` | a button the content declared | `event.id` |
| `step` | a level of the view's own trail | `event.row` |
| `deleted` | the host having deleted what you asked it to | `event.urls` |
| `answered` | the user answering a question you asked | `event.id`, `event.accepted` |
| `cursor` | the cursor coming to rest on a row, for a view that asked | `event.row`, `event.part` |
| `key` | a key press | `event.key` |

`event.row` indexes the rows of the last table, or the segments of the last
chart, the view returned; -1 is the middle of a chart. What `mark` *means* is
yours — the disk map puts the wedge on the list to delete, and a view that has
no such idea can ignore it.

**A press that does something in private is a press nobody can use.** Answer
`mark` with `context_menu=[...]` and the host draws those rows where the press
landed, in the application's own menu; picking one raises the ordinary `button`
event with its id. The git log used to send the other panel into a commit on a
right-click, and the same press on a working-tree file staged it instead —
neither written down anywhere. Now the press asks.

```python
if event.kind == "mark" and event.part == "log":
    return respond(context_menu=[
        {"id": "goto." + hash, "label": "Go to the files as they were"},
        {},
        {"id": "beside." + hash, "label": "Open them in the panel beside this one"},
    ])
```

The items are shaped like a menu's: `id` and `label`, `{}` for a separator,
`items` for a submenu, `checked` for a tick. A menu row carries its id and
nothing else, so put what it is about *in* the id — a table of pending subjects
has to be kept in step with a menu the user is already looking at.

Keys only arrive if the manifest says `"keys": true`, and then only the ones the
panel does not need for itself: `enter`, `escape`, `backspace`, the arrows,
`home`, `end`, `pageup`, `pagedown`, and printable characters. The function row
and Tab are never handed over — a view that could swallow F5 would be a view
that can break copying.

### Where the view has walked to

A view that goes *into* things has the panels' own problem, so it gets the
panels' own answer rather than one of its own:

```python
return respond(content=..., trail=["x", "Pictures", "Holidays"])
```

The host draws it where a panel keeps its path — the same buttons, the same
chevrons, scrolling the same way — full screen and in a panel alike. Pressing a
level raises `step` with its index in `event.row`. Outermost first; the last one
is where you are and is not pressable. Sending no `trail` leaves the one that is
already there, exactly as `title` and `status` do.

### Full screen: the title bar is yours

A view on the whole window *is* the application for as long as it is up, so it
gets the application's title bar rather than a second bar of its own. Back, the
switch into a panel and the view's title stand there; the view fills everything
under them, and its `status` runs along the bottom where a panel keeps its own.

**The application's menus are not shown.** File, Mark and Commands are about a
listing that is not on screen. A view may put its own there instead:

```python
return respond(
    content=table(...),
    menus=[
        {"label": "Query", "accelerator": "q", "items": [
            {"id": "run", "label": "Run", "shortcut": "F5"},
            {"id": "stop", "label": "Stop", "enabled": running},
            {},                                    # a separator
            {"label": "Recent", "items": [         # a submenu
                {"id": "recent.1", "label": "select * from files"},
            ]},
            {"id": "wrap", "label": "Wrap lines", "checked": wrapping},
        ]},
    ],
    commands=[
        {"id": "copy", "label": "Copy", "icon": "copy"},
        # No icon, so it is drawn as a pill saying its label — and with items,
        # they drop out of it. The path bar's own drive button, in a tool's
        # bar: it says where you are and opens the way to somewhere else.
        {"id": "branch", "label": branch, "items": [
            {"label": "Branches"},
            {"id": "ref.main", "label": "main", "checked": True},
            {},
            {"label": "Tags"},
            {"id": "ref.v1", "label": "v1.0"},
        ]},
    ],
)
```

| Key | Means |
| --- | --- |
| `label` | what the row says |
| `id` | raises `button` with this id when picked |
| `accelerator` | on a menu: the letter that opens it with Alt held |
| `shortcut` | shown right-aligned. **Informational** — the host does not bind it |
| `enabled` | false greys the row |
| `checked` | draws a checkbox in that state |
| `items` | on a menu: its rows. On a row: makes it a submenu |

A row with neither `id` nor `items` is a **separator**. Picking any row raises
the same `button` event a `commands` button or a chart button does, so there is
one kind of thing to answer:

```python
@plugin.view("sql.console")
def sql(context, event):
    if event.kind == "button" and event.id == "run":
        ...
```

`commands` are buttons for the title bar, between the tools icons and the
window's own buttons, with a rule drawn between the two groups. `icon` is a
name from the same set the manifest uses.

**Both are kept until you replace them**, exactly as `title` and `trail` are —
answer a click with new content and the menu stays. To take a menu away, send it
with no items.

A view that declares `panel` as well as `fullscreen` can be moved between the
two with the button beside Back, or with **Ctrl+Shift+Enter** either way. The
view is closed and re-opened on the other surface, with a new `session`; nothing
is carried across, so keep what matters to you rather than in the host.

### Drawing a ring

`chart` is the fifth content shape, and the only interactive one besides a
table. The plugin sends a flat list of wedges; the host works out the geometry,
because that depends on the size of the widget and on the theme, and a plugin in
another process can see neither.

```python
from xverb import button, chart, segment

segment("Photos", 4_200_000_000, url="file:///Users/me/Photos", folder=True)
```

`parent` is an index into the same list — -1 for the innermost ring — so the
tree travels as a flat list and can be appended to as it is discovered. A
wedge's children divide *its* arc by *its* value, so the part of a folder that
has not been accounted for stays visibly empty rather than being papered over.

`label` and `detail` are what the middle says, and the middle is also the way
back out: pressing it raises `activate` with row -1. Hovering a wedge puts its
own name there, which is how a ring answers "which one is that" without
labelling every sliver. `buttons` draws a row along the top; pressing one raises
`button`.

Leave `color` alone unless you mean it. The host colours a chart from the theme
and keeps a branch's shades together; a plugin that picks its own colours is a
plugin that looks wrong in half of them.

### Work that takes longer than a call

A call has sixty seconds. Scanning a disk does not fit in sixty seconds, and a
view that waits for the whole answer before drawing anything is a view that
looks broken for a minute and then blinks.

So answer at once with what you have, do the rest on a thread of your own, and
push what you find:

```python
plugin.update_view(VIEW_ID, session, content=chart(...), status="Scanning…")
```

`session` is the one from the context. An update for a copy of the view nobody
is holding any more is dropped, so a scan that outlives its view does no harm —
and the host tweens the wedges between one push and the next, so a chart filling
in looks like one thing settling rather than a slideshow.

Calls from a thread of your own are safe: the SDK reads on one thread, runs your
handlers one at a time on another, and serialises what it writes. The single
exception is a shutdown hook, which must not wait on the host for anything — it
is already on its way out. `plugin.log` is fine there, because nothing answers
it.

### Walking a tree

`plugin.list_dir(url)` and `plugin.stat(url)` are the counterparts of
`read_file` for a view that has to cross a tree rather than open one file. They
go through the host, so the same code walks the local disk, an archive and an
FTP server; each entry is a dict with `name`, `url`, `kind`, `size`, `modified`
and `hidden`. The `..` row never appears — it is drawn by the panel, not present
on the disk, and a walk that followed it would not end.

### Asking the user something

A plugin cannot draw, so it cannot put up a dialog — and one that could would
be one whose dialogs look like nothing else in the application. It describes
the question instead:

```python
return respond(actions=[ask(
    "checkout",
    "Switch to %s?" % branch,
    "Your working tree is clean, so nothing will be lost.",
    confirm="Switch",
)])
```

The host asks it, in its own words and its own shapes, and the answer comes
back as an `answered` event carrying the `id` you gave it and `event.accepted`.
**It arrives either way**: no is an answer, and a plugin told only about yes
cannot tell that apart from a question that got lost.

Name the `confirm` button after what agreeing *does* — "Switch", "Discard",
"Stage". A dialog whose buttons say Yes and No makes the reader work out which
one they want from the question they have just read. Set `danger=True` for what
cannot be undone: the host draws it differently and does not make it the easy
answer.

**Ask before anything the user would not expect**, and refuse outright what
they cannot undo and did not ask for. A question is not a licence: a tool that
asks and then does something else with the answer is worse than one that never
asked.

### A form the user fills in

The one content that answers back. Everything else goes one way — you describe,
the host draws, the user presses a row — and a sentence somebody types needs a
road home.

```python
form(
    [field("message", kind="lines", hint="Message", required=True),
     field("amend", kind="check", label="Amend")],
    [button("commit", "Commit", primary=True)],
)
```

`field` takes `kind` (`text`, `lines`, `check`), a `label`, a `hint`, and
**`value` — what it starts with**. That is how the plugin puts data *into* the
form: the current name to be edited, the last commit message, whatever the
answer should begin as. The user's typing wins over it, so a view that redraws
because something else changed does not take back the sentence being written;
send a *different* value and the field takes it.

`required` is answered by the host — the `primary` button stays out of reach
until every required field has something in it — because asking would mean a
round trip per keystroke.

**The answer comes back with the press, and only with the press.** Nothing
crosses the pipe while the user types, so a form is as quick as the keyboard.
Where it arrives depends on what put the form on screen:

| The form is in | The answer arrives as |
| --- | --- |
| a view | a `button` event, with `event.values` — every field by id |
| a command | that same command invoked again, with `button` and `values` in its `args` |

Either way the values are strings for text and booleans for checks. See
[Commands](#commands) for the shape of a command that asks something and then
does it.

### Deleting

A view cannot delete anything. It asks:

```python
return respond(actions=[delete(marked_urls)])
```

The host asks the user, in the application's own words, uses the recycle bin
wherever there is one, and shows the same progress window F8 does. It then tells
the view what **actually** went, as a `deleted` event carrying `urls` — which is
not necessarily what was asked for, because the user may have said no. Prune
your own picture from that event and nothing else, and a cancelled confirmation
leaves the map showing the truth.

### Asking the host for something

A plugin cannot drive the application: it is another process, it cannot draw,
and it does not know what else is on screen. It returns intentions, and the host
carries them out where the view happens to be.

| Helper | What it asks for |
| --- | --- |
| `navigate(url, panel="other")` | send a panel to a location |
| `open_viewer(url)` | view a file, as F3 would |
| `notice(message)` | a line of feedback along the bottom |
| `refresh(panel="other")` | re-read a panel after something changed |
| `close()` | close this view |

`panel` is `other` (the default), `self`, `left` or `right`. For a view in a
panel, `other` is the panel beside it — which is the useful one: press something
here, show it there. A full-screen view has no panel beside it and nothing for
`other` to contrast with, so there it means the panel that was being worked in —
the one the user comes back to when the view is closed.

Sending a view's **own** panel somewhere closes the view: a panel cannot be in a
folder and handed over at the same time. An action this build has never heard of
is ignored, and the rest of the same answer still happens.

Returning no content leaves what is on screen alone, which is what an answer
that only moves the other panel should do — clicking a row should not blank the
view the row was in.

### What a view cannot do

Draw its own widgets. A view returns `text`, `markdown`, `image`, `table` or a
`split` of those, exactly as a viewer does, and the host renders them. Rows of a `table` are
pressable and raise `activate`, and the arrow keys move a cursor along them
without the plugin being asked anything; nothing else is clickable. If your view needs a
shape the host does not have, that is a request for a new primitive rather than
something to work around.

## Protocol

Newline-delimited JSON, one JSON-RPC 2.0 object per line. **stdout carries
protocol traffic only** — a stray `print()` there looks like a malformed message.
Use `plugin.log(...)` or write to stderr, which is captured into the plugin log.

### Host → plugin

| Method | Params | Result |
| --- | --- | --- |
| `initialize` | `apiVersion`, `pluginId`, `pluginDirectory`, `platform`, `settings` | `{apiVersion, schemes, viewers, views, commands}` |
| `shutdown` | — | — |
| `settings.changed` | `settings` | notification |
| `viewer.open` | `viewerId`, `url` | content object |
| `view.open` | `viewId`, `context` | content object, or `{content, actions, title, status}` |
| `view.event` | `viewId`, `context`, `event` | the same |
| `view.close` | `viewId`, `session` | notification |
| `command.invoke` | `id`, `args` | anything JSON |
| `fs.roots` | `scheme` | `[{url, label, subtitle, icon}]` |
| `fs.defaultLocation` | `scheme` | `{url}` |
| `fs.list` | `url` | `{entries: [entry]}` |
| `fs.stat` | `url` | entry or `null` |
| `fs.read` | `url`, `offset`, `length` | `{data: base64, eof: bool}` |
| `fs.write` | `url`, `data: base64`, `mode: create\|append\|close\|abort`, and on `create` the `length` and `modified` the host knows | — |
| `fs.finish` | `url` | — | 
| `fs.mkdir` | `url` | — |
| `fs.delete` | `url` | — |
| `fs.rename` | `from`, `to` | — |
| `fs.copyWithin` | `from`, `to` | `bool` — false means "stream it yourself" |

An entry is `{name, kind: file|dir|link, size, modified: epoch ms, hidden, target}`.

A view's `context` is `{session, surface, url, isDirectory, selection}` and its
`event` is `{type: open|activate|key, row, key}`. An `action` is
`{type: navigate|view|notice|refresh|close, url, panel, message}`.

### Plugin → host

| Method | Params | Result |
| --- | --- | --- |
| `host.log` | `level`, `message` | notification |
| `host.read` | `url`, `offset`, `length` | `{data: base64, eof}` |
| `host.apiVersion` | — | `int` |

Calls in both directions may interleave; the SDK dispatches incoming requests
while it waits for a reply, so calling `host.read` from inside a `viewer.open`
handler is fine.

## Limits worth knowing

- Bulk data crosses as base64 in JSON, which costs about 33% overhead. Fine for
  viewers and ordinary transfers; a plugin moving terabytes should implement
  `fs.copyWithin` so the data never enters the pipe.
- One call has 60 seconds to answer before the host gives up.
- Plugin processes are not sandboxed. A plugin can do anything the user can.
  Install plugins you trust.
