/// Where the application sends people when it sends them out.
///
/// **One place, because these will all move at once.** The site is new and the
/// rest still point at the repositories, which is where those answers actually
/// live; when any of that moves, it is this file that changes and nothing else.
library;

/// The site.
///
/// **Published from Cloudflare Pages, and that address is the real one.** The
/// page itself declares `https://xverb.app/` as its canonical URL, which does
/// not resolve yet — so the application links to where the site *is*, not to
/// where it is meant to end up. The day the domain answers, this line is the
/// change.
const String kWebsiteUrl = 'https://xverb.pages.dev';

/// The project itself: what it is, what it costs, where the source is.
const String kProjectUrl = 'https://github.com/xsm909/xverb';

/// Where the releases and their notes are published.
///
/// The same repository the updater reads — see `GithubReleaseSource`. So *What's
/// new* opens the place the version somebody is running actually came from,
/// rather than a page written separately and left behind.
const String kReleasesUrl = 'https://github.com/xsm909/xverb-release';

// **There is deliberately no donate link.**
//
// It was drawn twice — the accent row on the About card and an entry in the
// application menu — and both are gone as of 2026-09-07. The rule that removed
// them is the one that used to be written here: a donate button that goes
// nowhere is worse than no donate button, and every route that leads somewhere
// is closed for now. The card platforms — GitHub Sponsors, Ko-fi, Open
// Collective, Patreon — all end at a Stripe or PayPal account, and none of them
// will open one here. A wallet address is the one thing that would work, and a
// wallet address standing alone on a project nobody uses yet asks a question
// about the project rather than answering one.
//
// It comes back when there is somewhere real to send people, and when there are
// enough people for the question to be worth asking. The strings are still in
// all six dictionaries, so returning it is this constant and two call sites.

/// Where a bug goes.
const String kIssuesUrl = 'https://github.com/xsm909/xverb/issues';
