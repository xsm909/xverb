import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';
import 'package:html/parser.dart' as html_parser;

import '../../core/i18n/i18n.dart';
import '../../core/vfs/shell_open.dart';
import '../viewer/reading_colours.dart';
import '../widgets/context_menu.dart';
import '../widgets/keyboard_scrollable.dart';

/// The largest page a plugin may hand over as HTML, in characters.
///
/// A page, not a book: past this the layout of one column of widgets is
/// seconds, and a plugin with that much to say has the Markdown reader, which
/// builds only what is on screen.
const int kHtmlLimit = 4 << 20;

/// A plugin's page written in HTML and CSS — backlog 87.
///
/// **Drawn by Flutter, not by a browser.** A web view is a window of its own
/// laid over the application: it takes the keyboard and does not give it back,
/// which is rule one broken on the first press, and it runs whatever script
/// the page holds. What is here instead is HTML and a good part of CSS turned
/// into the application's own widgets — colours, fonts, margins, borders,
/// tables, lists, pictures — and nothing that runs.
///
/// **What a page cannot do, on purpose:**
///
/// - run anything. `<script>`, `on…` attributes, `<iframe>`, `<object>`,
///   `<embed>` and forms are not drawn;
/// - reach anywhere. A picture is drawn only from a `data:` URL: nothing is
///   fetched from the network, the disk or the application's own files. A page
///   showing a file somebody sent would otherwise tell its author when it was
///   opened. Anything else is drawn as its `alt` text;
/// - do anything a click did not ask for. A link to `http`, `https` or
///   `mailto` is handed to the system, as Enter hands a file to it; a link to
///   `button:<id>` presses that button, the same as a button the content
///   declared, so a view can be driven from its own page. Any other link does
///   nothing.
///
/// **The keyboard.** The arrows, Page Up and Down, Home and End scroll it, as
/// any reading. Tab opens the page's links as a list, searchable, and Enter
/// follows one — a link the keyboard cannot reach does not exist.
class HtmlContentView extends StatefulWidget {
  const HtmlContentView({
    super.key,
    required this.html,
    this.onButton,
    this.hasKeyboard = true,
  });

  final String html;

  /// Where a `button:` link goes. Null where there is nobody to press it —
  /// a viewer showing a file.
  final void Function(String buttonId, Map<String, Object?> values)? onButton;

  final bool hasKeyboard;

  @override
  State<HtmlContentView> createState() => _HtmlContentViewState();
}

class _HtmlContentViewState extends State<HtmlContentView> {
  late List<HtmlLink> _links = linksIn(widget.html);

  @override
  void didUpdateWidget(HtmlContentView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) _links = linksIn(widget.html);
  }

  Future<bool> _follow(String url) async {
    final action = linkAction(url);
    switch (action) {
      case HtmlLinkAction.button:
        widget.onButton?.call(url.substring('button:'.length), const {});
      case HtmlLinkAction.system:
        await ShellOpen.open(url);
      case HtmlLinkAction.nothing:
        break;
    }
    // Always handled: a link the page is not allowed to follow must not fall
    // through to the widget's own default, which would try to open it anyway.
    return true;
  }

  KeyEventResult _onKey(KeyEvent event) {
    if (event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.tab ||
        HardwareKeyboard.instance.isShiftPressed ||
        _links.isEmpty) {
      return KeyEventResult.ignored;
    }
    _showLinks();
    return KeyEventResult.handled;
  }

  Future<void> _showLinks() async {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final origin = box.localToGlobal(Offset.zero);
    await showAppContextMenu(
      context: context,
      anchorRect: Rect.fromLTWH(origin.dx + 24, origin.dy + 24, 1, 1),
      searchHint: tr('Search links'),
      nodes: [
        for (final link in _links)
          MenuItem(
            link.text.isEmpty ? link.href : '${link.text} · ${link.href}',
            enabled: linkAction(link.href) != HtmlLinkAction.nothing,
            onSelected: () => _follow(link.href),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.html.length > kHtmlLimit) {
      return Center(
        child: Text(tr('This page is too large to draw.')),
      );
    }
    final page = readingColours(context);
    return KeyboardScrollable(
      hasKeyboard: widget.hasKeyboard,
      before: _onKey,
      builder: (controller) => SingleChildScrollView(
        controller: controller,
        padding: const EdgeInsets.all(24),
        child: SelectionArea(
          child: HtmlWidget(
            widget.html,
            factoryBuilder: _SealedFactory.new,
            onTapUrl: _follow,
            textStyle: TextStyle(color: page.ink, fontSize: 14, height: 1.5),
            customStylesBuilder: (element) => element.localName == 'a'
                ? {'color': _css(page.accent)}
                : null,
          ),
        ),
      ),
    );
  }
}

String _css(Color colour) {
  int channel(double value) => (value * 255).round().clamp(0, 255);
  return 'rgb(${channel(colour.r)}, ${channel(colour.g)}, ${channel(colour.b)})';
}

/// What following a link may do — see [HtmlContentView].
enum HtmlLinkAction { system, button, nothing }

HtmlLinkAction linkAction(String url) {
  final lower = url.trim().toLowerCase();
  if (lower.startsWith('button:') && lower.length > 'button:'.length) {
    return HtmlLinkAction.button;
  }
  if (lower.startsWith('https://') ||
      lower.startsWith('http://') ||
      lower.startsWith('mailto:')) {
    return HtmlLinkAction.system;
  }
  return HtmlLinkAction.nothing;
}

/// One `<a href>` of a page, in the order the page has them.
class HtmlLink {
  const HtmlLink(this.text, this.href);

  final String text;
  final String href;
}

List<HtmlLink> linksIn(String html) {
  if (html.length > kHtmlLimit) return const [];
  final document = html_parser.parse(html);
  return [
    for (final anchor in document.querySelectorAll('a[href]'))
      HtmlLink(
        anchor.text.replaceAll(RegExp(r'\s+'), ' ').trim(),
        anchor.attributes['href']!.trim(),
      ),
  ];
}

/// The page as plain text, for the clipboard.
String htmlText(String html) {
  if (html.length > kHtmlLimit) return '';
  return (html_parser.parse(html).body?.text ?? '').trim();
}

/// The widget factory with every road out of the page closed.
///
/// A picture from `data:` is the page's own bytes; every other source — the
/// network, a `file:` path, the application's assets — is refused, and the
/// picture is drawn as its `alt` text instead.
class _SealedFactory extends WidgetFactory {
  @override
  ImageProvider? imageProviderFromNetwork(String url) => null;

  @override
  ImageProvider? imageProviderFromFileUri(String url) => null;

  @override
  ImageProvider? imageProviderFromAsset(String url) => null;
}
