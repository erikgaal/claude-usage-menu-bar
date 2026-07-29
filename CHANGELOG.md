# Changelog

Notable changes to Claude Usage, newest first. Entries describe what a release
does for you rather than which pull requests went into it — where a feature
landed in pieces and was reworked before shipping, it's written up once, in the
state it actually reached.

This project follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html),
and this file follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [1.2.0] — 2026-07-29

### Added

- **Burndown charts for multi-day limits.** Every weekly window gets a
  collapsible chart: quota left on the y-axis, descending across the window. A
  solid line for what's been recorded, a dashed continuation for where you're
  heading, and a hairline diagonal for the pace that would spend the window
  exactly — so below the line is overspending and above it is headroom. The
  caption says the same thing in words: `71% used · 29% left · on pace to land
  at 6%`, or the time it runs out. Collapsed by default, and each chart
  remembers whether you opened it.
- **Projections that follow your daily rhythm.** Nobody spends quota evenly
  around the clock, so a single burn rate carried across a weekly window spends
  it through every night too, and a chart opened at the end of a working day
  read as far more alarming than it should. Each limit now learns how much it
  typically consumes in each hour of the day, and the projection replays that
  shape — standing still through the hours you're reliably idle, dropping
  through the hours you work. How *much* you're working is fitted separately
  over the last two days, so the level keeps up with a busy week while the shape
  stays steady. Backtested on real recorded history this cuts a day-ahead
  projection's error by about a third, and the run-out time lands in working
  hours instead of at 4am. Windows without enough history yet, and the five-hour
  session windows, keep the single fitted rate.
- **A settings window.** The dropdown now shows usage and nothing else, with
  Settings… (⌘,) and Quit at the bottom. General holds launch-at-login and
  notifications — a master switch plus one per kind. Accounts holds renaming,
  quota weights, drag-to-reorder, and removal behind a confirmation. About holds
  the version and build (selectable, for bug reports), the author, and a link to
  the repository.
- **A Best badge on the account with the most usable capacity.** Not the one
  with the most headroom on paper: it accounts for how fast each account is
  burning, treats capacity that expires sooner as worth spending first, and
  factors in the weekly limits, so a session that looks free but sits under a
  nearly-spent week no longer wins. A debug view shows the ranking's working.
- **Switch suggestions.** A notification when a better account becomes
  available, posted at the one moment the advice is actionable rather than only
  being visible in a panel you aren't looking at. Three gates keep it quiet: an
  edge trigger on the (from, to) pair, a 30-minute per-group cooldown, and
  4-hour per-pair repeat suppression.
- **Notifications** when a limit reaches 90%, when a limit resets, and when a
  sign-in expires — each individually switchable.
- **Update check** against GitHub releases.
- **Account reordering**, by drag or the row menu.
- **Local usage history.** Every poll's per-limit percents are appended to one
  JSON file per account under Application Support (14 days of 5-minute
  samples), which is where the trend charts and projections come from. The
  learned daily shape lives in a separate few-hundred-byte file per account, so
  it keeps accumulating after the raw samples are pruned. Nothing leaves your
  machine.

### Changed

- Install instructions no longer describe the "Open Anyway" and `xattr` steps.
  Releases have been signed with a Developer ID and notarized since 1.1.0, so
  Gatekeeper doesn't ask.

### Internal

- CI builds and runs the test suite on every pull request, covering OAuth, the
  callback server, provider parsing, the account store, and the history and
  projection maths.

## [1.1.0] — 2026-07-24

### Added

- **Extra-usage credits bar.** Each Claude account shows its pay-as-you-go
  spend beneath the rate-limit rows. With a spend cap set, the bar fills used ÷
  cap and colours by threshold, captioned `extra usage · 50% of £25.00`; without
  a cap there's no denominator, so it shows the amount spent and says `no spend
  limit`. Accounts with extra usage enabled but nothing spent and no cap stay
  hidden.
- Reproducible README screenshots from mock data (`make screenshots`).

### Fixed

- A decode bug that would have taken down every usage bar for accounts with a
  spend cap.

## [1.0.0] — 2026-07-16

### Added

- First release: a menu bar app showing Claude and Codex subscription usage.
- Universal build (Apple Silicon and Intel), signed with a Developer ID and
  notarized by Apple — unzip and run, with no Gatekeeper approval needed.
- Panel design with named accounts, provider badges, and grouped reset lines.
- Tokens consolidated into one Keychain item, under a stable signing identity so
  access survives across releases.
- Backs off on 429s and polls less aggressively.

[Unreleased]: https://github.com/erikgaal/claude-usage-menu-bar/compare/v1.2.0...HEAD
[1.2.0]: https://github.com/erikgaal/claude-usage-menu-bar/compare/v1.1.0...v1.2.0
[1.1.0]: https://github.com/erikgaal/claude-usage-menu-bar/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/erikgaal/claude-usage-menu-bar/releases/tag/v1.0.0
