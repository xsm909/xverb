/// Application version, in `A.B.C.D` form. Each part promises something
/// different, and only one of the four is decided by eye.
///
/// **A — the contract with plugins.** It moves when, and only when, the
/// host/plugin protocol breaks. It is deliberately *not* "a big release": a
/// rewrite that leaves the protocol alone leaves A alone, and a protocol break
/// too small to feel like a major release moves it anyway. [kMajor] is the
/// number, and `kPluginApiVersion` is derived from it, so a plugin declaring
/// `apiVersion: 1` runs on every `1.*.*.*` and on nothing else.
///
/// **B — something is in the program that was not there before.** Not better,
/// not fixed, not repainted: absent, then present, with somewhere for the
/// reader to go — a key, a menu entry, a panel, a settings tab. This is the
/// judgement call, so when it is not obvious the answer is no. Nothing depends
/// on getting it right: see the rule about updates below.
///
/// **C — a public release.** A version somebody is meant to be able to name.
/// Moving it says "this one is worth talking about" and nothing else — it is
/// **not** what decides whether an update is offered, and this used to be
/// written as though it were.
///
/// **D — the build.** Bumped when a commit is written, and never reset, so a
/// build number names one commit in the whole history for ever. Kept in step
/// with the `version:` line in `pubspec.yaml`, which carries the same value as
/// `A.B.C+D`; `tool/package.dart` refuses to build when the two disagree.
///
/// **Any published version is an update, D included.** The check compares all
/// four parts numerically and is indifferent to which of them grew: a build
/// that moves only D is offered exactly like one that moves C. That follows
/// from who publishes and how — every archive in `xverb-release` is put there
/// by hand, one at a time, so a build reaching anybody at all is already the
/// decision that it should. A fix too small to move C can be the fix somebody
/// is waiting for, and there is nothing else here to weigh it against.
library;

/// A, on its own, so that the plugin API version cannot drift away from it.
///
/// `kPluginApiVersion` in `core/plugins/plugin_manifest.dart` is this constant
/// rather than a second `1` written beside it. The two say the same thing, and
/// two places saying the same thing is a promise to remember; one place is not.
const int kMajor = 1;

/// B.
const int kMinor = 0;

/// C. Moving this is the release.
const int kRelease = 0;

/// D.
const int kBuildNumber = 448;

/// A.B.C, which is what a release is called: the build is not part of the name.
///
/// The four are separate constants and this is assembled from three of them, so
/// that moving a part is editing one number rather than editing a string and
/// hoping. `tool/package.dart` reads the four by name for the same reason.
const String kVersionName = '$kMajor.$kMinor.$kRelease';

/// Displayed in Settings → About and in release artefact names.
const String kAppVersion = '$kVersionName.$kBuildNumber';

/// What this release is called.
///
/// **Iceland**, and the picture on the About card is a glacier photographed
/// there. The two are
/// the same word on purpose: the caption under the photograph says where it was
/// taken, the line under the card says which release this is, and a reader who
/// notices they match has understood something true about where the name came
/// from.
///
/// **Presentational, and deliberately so.** The archives, the release notes and
/// everything the updater compares are named by [kAppVersion] — a name is a
/// thing to say, and a number is a thing to compare. Nothing here may ever be
/// parsed.
const String kReleaseName = 'Iceland';

/// What the application calls itself: window title, title bar, about box.
///
/// The package, the repository and the bundle identifier are the same word in
/// lower case, `xverb`, so the name shown and the name built agree.
///
/// Short, and deliberately not the short form anyone reaches for first: XCOM
/// is a games mark held in class 9, the same class software registers in, and
/// hyphenating or punctuating it — X-Com, x@com — changes nothing, because
/// marks are compared by how they sound and what impression they leave.
///
/// **Xverb since 1.0.0.440.** Before it, *X2D* for four builds, and *XC* for
/// the twenty-five before that. Two letters
/// were short enough to be somebody else's, and X2D was free but said nothing.
/// *Verb* says what the application does: a file manager is copy, move, open,
/// delete — and Windows calls the actions in a context menu *shell verbs*, the
/// very ones `shell_menu.cpp` asks Explorer for. X before a consonant settles
/// the reading too: /zv/ cannot open an English word, so nobody says *zverb*.
///
/// **This is the only place the shown name is written in Dart.** Every platform
/// carries its own copy, because each is read before any Dart runs —
/// `CFBundleName` and `CFBundleDisplayName` on macOS, `ProductName` and
/// `FileDescription` in `Runner.rc` together with the title passed to
/// `window.Create` in `main.cpp` on Windows, the initial window title on Linux,
/// `CFBundleDisplayName` on iOS, and `android:label` in the manifest. Change one
/// and change them all: the two mobile labels kept an older spelling for months
/// precisely because nothing in Dart ever reads them.
const String kAppTitle = 'Xverb';
