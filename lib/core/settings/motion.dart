import 'package:flutter/animation.dart';

/// Every animation number in the application, and nothing else.
///
/// One constant per animated thing, in milliseconds. These are the lengths at
/// the *slowest* speed: `animationScale` (0..1, Off/Fast/Normal/Slow) multiplies
/// them, and the default Normal is half of what is written here.
///
/// Where a movement travels a distance rather than only taking time, the
/// distance lives here too, in logical pixels, and says so in its name. A
/// movement is a length and a duration; keeping half of it here and half of it
/// in a widget is how the two drift apart.
///
/// Nothing in this file does anything. Change a number, rebuild, look.

/// The frame that marks the active panel, changing sides.
const int kPanelAnimationDuration = 340;

/// The cursor mark sliding from row to row in a listing.
///
/// Short even at Slow: holding an arrow key walks several rows a second, and a
/// mark slower than the repeat never arrives.
const int kCursorAnimationDuration = 130;

/// The extension column changing width, and the name column giving way to it.
///
/// The width is set in whole letters, so it steps rather than slides — and a
/// step that is cut rather than travelled reads as the listing flinching. Both
/// panels are drawing off the one setting, so what this length actually shows
/// is that the two of them moved together.
const int kColumnWidthDuration = 130;

/// The mark that follows a dragged selection down a listing, and the outline
/// that says which panel would take it.
///
/// The same length as the cursor's, and for the same reason: a hand moving a
/// file across a window moves it about as fast as a held arrow key walks, and a
/// mark that arrives after the pointer has gone is a mark nobody reads. What it
/// buys over drawing the highlight outright is that the eye can see *which way*
/// the drop moved when it changes rows.
const int kDropMarkDuration = 130;

/// How long the panel's own outline takes to appear once a drag crosses into
/// it, and to go when it leaves.
///
/// Longer than the mark. The mark is answering the pointer; this is answering
/// the question of which half of the window is being aimed at, and a border
/// that snaps in and out as a drag crosses the middle of the window is a
/// flicker rather than an answer.
const int kDropPanelDuration = 200;

/// A row leaning aside as the pointer arrives over it, and coming back when it
/// leaves.
///
/// Two lengths, and the difference between them is the whole effect. A row
/// takes the lean quickly and gives it back slowly, so a pointer swept down a
/// listing leaves a wake behind it — several rows on their way back at once —
/// rather than one row stepping aside under the pointer and nothing else
/// happening. Equal lengths here and the listing goes back to being a grid with
/// a highlight in it.
const int kRowLeanInDuration = 100;
const int kRowLeanOutDuration = 210;

/// How far a row leans under the mouse, in logical pixels.
///
/// The icon and the name move, and nothing else does: a name that took the size
/// and the date with it would stop the columns being columns, and the point is
/// to answer the pointer, not to rearrange the listing.
const double kRowHoverLean = 6;

/// How far the row the keyboard is on leans, in logical pixels.
///
/// Further than the mouse, and it wins where the two are on the same row: the
/// cursor is where the next key press lands, and the pointer is only passing
/// through.
const double kRowCursorLean = 8;

/// How much bigger a row is drawn under the mouse, as a multiplier.
///
/// The other way a live row can answer the pointer — the same lengths, the same
/// curves, the same wake, said with size instead of with distance. Small on
/// purpose: this is the row acknowledging the pointer, not the row being
/// magnified, and text drawn much over its own size stops looking like the text
/// beside it.
const double kRowHoverScale = 1.08;

/// The same for the row the keyboard is on, and larger for the same reason it
/// leans further.
const double kRowCursorScale = 1.1;

/// What the four numbers above are multiplied by on macOS.
///
/// The four were chosen on the PC, which is the standard, and on the Mac a
/// Retina screen makes the same movement read as a smaller one — so this is
/// the only number that differs between the two, and it multiplies
/// **distance**, never duration. The speed setting stays the one scale it has
/// always been.
///
/// **Keyed on the platform**, and not on the device pixel ratio, which is the
/// truer statement of the cause: a Windows
/// laptop at 200% is a Retina screen too, and keying on the ratio would move
/// the PC — which is the thing every one of these numbers was measured
/// against. If it is ever to follow the ratio instead, that is a decision
/// about the PC and has to be made there.
const double kLiveRowReachOnMac = 1.5;

/// How far apart the chips of one row sit while they are stacked.
///
/// A *step* rather than a width: five branches on one
/// commit are five pills wider than any column they will ever be in, so they
/// lie on top of one another with this much of each one showing.
const double kChipStackStep = 30;

/// How long that stack takes to fan out, and to fall back together.
const int kChipSpreadDuration = 180;

/// How long a piece of a rendered document takes to answer the pointer.
///
/// Short, and shorter still on the way in than the way out is elsewhere: a
/// document is read by moving across it, so anything that lags behind the
/// pointer reads as the page being slow rather than as the page answering.
const int kMarkdownHoverDuration = 120;

/// How long a hint takes to arrive once the pointer has waited for it.
///
/// The waiting is not animation and is not here — it is a pause, and a pause
/// the user can feel is a pause that should not shrink when they speed the
/// animations up.
const int kHintDuration = 130;

/// How long it takes to go again.
///
/// **Shorter than the arrival, which is the general shape of a leaving.** A
/// thing arriving is asking to be looked at and the movement is what draws the
/// eye to it; a thing leaving has already been read, and a slow exit is a hint
/// still in the way of whatever the pointer moved on to. The arriving half
/// already existed; the leaving half was a single frame until this.
const int kHintLeaveDuration = 90;

/// A context menu unrolling.
const int kContextMenuAnimationDuration = 240;

/// A remark arriving along the bottom of the window.
const int kNoticeAnimationDuration = 240;

/// A whole page replacing another: settings, a viewer, a plugin's page.
const int kPageAnimationDuration = 480;

/// A button taking a hover or a press. Must not outlive the gesture.
const int kButtonAnimationDuration = 120;

/// The disk map's rings re-arranging.
const int kDiskMapAnimationDuration = 480;

/// The four speeds the settings page offers, as multipliers on everything
/// above. Off is not "very fast": at 0 nothing animates at all.
const double kAnimationOff = 0;
const double kAnimationFast = 0.33;
const double kAnimationNormal = 0.6;
const double kAnimationSlow = 1;

/// Coming in: fast at first, settling into place.
const Curve kArrivingCurve = Curves.easeOut;

/// Going out: slow to leave, then gone.
const Curve kLeavingCurve = Curves.easeIn;

/// Both, or a move from one place to another.
const Curve kBothCurve = Curves.easeInOut;

/// One thing replacing another in the same place: the properties panel when
/// the focus moves to another node, and anything else that swaps its content
/// without moving.
///
/// **Rule number two: nothing happens without animation.** A swap drawn in one
/// frame is a blink, and a blink says
/// "something broke"; a fade says "this is now that". Short, because it is on
/// the way to what was asked for and nobody asked to watch it.
const int kContentSwapDuration = 180;

/// The listing changing folders: the rows that were in the panel fade out, and
/// the rows that are in it now fade in.
///
/// **One length for the whole cycle**, not one per half — walking into a folder
/// and walking out of it are single events, and the two halves are the same
/// event seen from either end. The swap itself happens at the midpoint, where
/// there is nothing on screen to see it.
///
/// Short on purpose: the folder is already open by the time this starts, so it
/// is the panel catching up with a key that has been answered, and nobody asked
/// to watch it. What it buys is that a listing being replaced no longer reads
/// as the same listing suddenly holding different files.
const int kListingSwapDuration = 240;

/// How much bigger the listing being left is drawn as it goes, as a fraction
/// of its own size.
///
/// **This is the half of the exchange that says which way you went.** Walking
/// into a folder, what is being left grows by this much as it fades — the eye
/// is moving into it, so it passes you — and what is arriving starts this much
/// smaller and settles at its own size. Walking out, both are mirrored: the
/// folder you were in falls away from you and the one holding it comes forward.
/// One number for all four, because it is one movement seen from either end.
///
/// **A move that is neither in nor out does not scale at all** — a drive, a
/// path typed in, a result set. Those are not deeper or shallower than where
/// you were, and a movement has to state something true; they fade and nothing
/// else. Small on purpose: this is a whole panel of text, and text drawn much
/// over its own size stops looking like the text beside it. Multiplied on
/// macOS by [kLiveRowReachOnMac], which covers a scale as well as a slide.
const double kListingSwapZoom = 0.05;

/// How far the listing travels sideways under the other exchange, as a fraction
/// of the panel's own width.
///
/// **The same sentence said with distance instead of with size, and it is the
/// window that gives it its direction.** Going deeper, the listing travels
/// towards the middle of the window; coming back out, it travels towards the
/// edge its own panel sits on. So the left panel goes right on the way in and
/// left on the way out, the right panel does the mirror image of that, and the
/// two of them read as a pair of doors rather than as two panels that happen to
/// slide the same way. A move that is neither in nor out does not travel at
/// all: it fades, the same as under [kListingSwapZoom].
///
/// **A fraction and not a number of pixels**, which is the one thing that
/// differs from every other distance in this file: a panel is half a window
/// wide on one machine and a quarter of one on another, and a slide measured in
/// pixels would be a step on the first and a walk on the second. Small enough
/// that the rows never leave the panel — the fade is what takes them away, and
/// this only says which way they went. Multiplied on macOS by
/// [kLiveRowReachOnMac], the same as the zoom is.
const double kListingSwapSlide = 0.12;

/// How long a node takes to fold up, and to open out again.
const int kNodeFoldDuration = 200;

/// A group of settings folding shut while another opens.
///
/// **One movement, not two.** Only one group is open at a time, so closing and
/// opening happen together and have to read as one thing handing over to
/// another — which is why they share a length rather than each having its own.
/// Longer than a node folding because a group of settings is a taller thing to
/// travel, short enough that somebody looking for a switch is not waiting on it.
const int kSettingsFoldDuration = 240;

/// How long a settings row stays lit after the preview sent you to it.
///
/// It is an answer to "where does this colour live", so it lasts about as long
/// as it takes to look — and it fades rather than switching off, because a
/// light going out in one frame reads as a fault.
const int kSettingsFlashDuration = 1400;

/// A panel sliding out from the edge of the reading, and back into it.
///
/// It travels its own width and fades as it goes, and it does **not** scale:
/// the movement has to say something true, and the truth here is "it came from
/// the edge and it goes back there". Longer than a menu unrolling because it
/// crosses more of the window, short enough that the key that opens it does not
/// feel like a request.
const int kSlidePanelDuration = 260;

/// How long the node canvas takes to glide to the node the keyboard just moved
/// to.
///
/// It moves rather than jumping because **the movement says something true**:
/// it shows the reader the wire they have walked along. Long enough to be
/// followed by eye, short enough that holding an arrow key does not become a
/// queue — the same argument as the panel's own cursor.
const int kNodeGlideDuration = 220;

/// How long the reading takes to travel to the line a node in the structure
/// panel named.
///
/// It glides rather than jumping, for the reason the canvas does: the movement
/// says which way the document went, and a reader who sees it keeps their
/// bearings. Short, because it is on the way to what was asked for — and the
/// search, which jumps to a match, stays as it is: a match is *found*, where a
/// heading is *gone to*.
const int kOutlineJumpDuration = 240;

/// The structure panel's own small movements: a row brought into view, and the
/// twist of the mark that folds one.
const int kOutlineRowDuration = 160;

/// A picture travelling from one magnification to another.
///
/// **Rule number two, and here it also says something true:** a picture that
/// jumps from fitted to 1:1 has to be found again by eye, because nothing on
/// screen says which part of it you are now looking at. Interpolating the
/// magnification *and* the offset together shows the reader where they went.
///
/// Only the stepped changes — the keys, the switches, a double press. Dragging
/// and the wheel are the hand's own movement and follow it exactly, the way the
/// reading scrolls under an arrow key without animating.
const int kImageZoomDuration = 240;

/// The volume moving to where a key or the wheel just put it.
///
/// **Only when it was not dragged.** A finger on the selector is the hand's own
/// movement and follows it exactly — the same rule the picture canvas keeps
/// about dragging and the wheel — so this length is used for the steps and not
/// for the drag.
const int kVolumeGlideDuration = 140;

/// The shape of a sound rising into the window once it has been decoded.
///
/// **The one movement in the sound viewer that answers to the setting.** The
/// playhead runs on real time and the bars breathe with the music, because both
/// of those state something true about the file — slowing them down would make
/// the drawing lie. This is the interface arriving, which is ours to time.
const int kWaveformArriveDuration = 320;

/// How long the canvas says the wire it just followed.
///
/// **Not run through `animated()`.** The speed setting decides how things
/// *move*; at Off this would leave the words on screen for no time at all,
/// which is not what "no animation" means — the same argument the floating
/// remark's own life is written down under.
const Duration kNodeStepSaidLife = Duration(milliseconds: 2200);

/// The strip of neighbours along the bottom of a full-screen viewer: the strip
/// itself arriving and leaving, and the cell that has just been walked to being
/// brought into view.
///
/// **One length for both**, because they are one movement to the eye: the strip
/// slides up from the edge it belongs to, and thereafter the row travels under
/// a highlight that stays where it is. A highlight that jumped while the row
/// stood still would state nothing about which way along the folder you went.
const int kFilmStripDuration = 220;

/// How much bigger a thumbnail is drawn under the pointer, and how far it
/// leans, in degrees.
///
/// **The same acknowledgement a listing row makes** — [kRowHoverScale] — said
/// by a photograph instead of by a line of text, which is why it may also
/// tilt: a row of type cannot lean without looking broken, and a photograph
/// picked up off a table always does. Small on both counts: the cell is
/// answering the pointer, not being opened.
const double kThumbnailHoverScale = 1.25;

/// How far it may lean, in degrees either way. **The angle itself is drawn at
/// random inside this**, fresh each time the pointer arrives: photographs
/// dropped on a table do not all lie the same way round, and a strip where
/// every one of them leaned by the same three degrees looked like a setting
/// rather than like picking one up.
const double kThumbnailHoverTilt = 7;

/// The same strip folding into a grid under the pointer, and unfolding back
/// into one row when the pointer leaves.
///
/// **Longer than the strip's own arrival**, and that is the only reason it is
/// a number of its own. Sliding in is one thing travelling one way; this is
/// forty things each going somewhere different, and the eye needs the extra
/// moment to see that they are the same forty things rearranged rather than a
/// new set put in their place. Everything else about it — the curve, the
/// speed setting — is shared with the strip.
const int kFilmStripFoldDuration = 320;

/// A window arriving on the desk, and leaving it.
///
/// **The row the cursor is on becomes the window.** Not a window that grows
/// near the row — the *rectangle* is interpolated, so what leaves the listing
/// is a bar exactly the width and height of that row, and it turns into the
/// dialog on the way. F5 on a file, and the file's own row opens into the
/// question about it. Going back is the same journey in reverse.
///
/// **The cursor itself does not go with it.** The listing draws its own mark
/// and this animation never touches it, so the row stays lit where it was —
/// his condition, and the right one: a window flying out of the panel must not
/// cost the reader their place in it.
///
/// Where nothing can say where the window was asked for — a plugin opening one
/// on its own — it arrives about its own centre at [kWindowArriveScale]
/// instead, which claims nothing.
///
/// Longer than a menu unrolling and shorter than a page: the window crosses
/// most of the desk on its way in, and the eye has to be able to follow it
/// back to the row it came from or the movement has said nothing.
const int kWindowArriveDuration = 320;

/// Where a window starts when nothing can say where it was asked for.
///
/// A fraction of the size it settles at, about its own centre — the same
/// depth the listing arrives with, and it claims nothing beyond "this is now
/// in front of the desk". Close to 1 on purpose: a window that has no origin
/// to travel from should not pretend to have travelled.
const double kWindowArriveScale = 0.94;

/// Where the journey ends and the unfolding begins, as a fraction of
/// [kWindowArriveDuration].
///
/// **Two acts, one timeline.** The row travels and becomes the window's title
/// bar; then the form grows out from under it. One controller and one number,
/// because two animations describing one event must not have two timings — and
/// this is one event: a row opening into the question about it.
///
/// Past halfway, so the travelling has the longer half. That is the act that
/// says *where the window came from*, and it is the one the eye has to be able
/// to follow; the unfolding only has to say "and here is the rest of it".
const double kWindowUnfoldAt = 0.58;
