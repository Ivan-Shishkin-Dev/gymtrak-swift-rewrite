# GymTrak

A personal lifting and running tracker for iPhone and Apple Watch, written in SwiftUI. It's the native rewrite of the [GymTrak web app](https://github.com/Ivan-Shishkin-Dev/GymTrak). Built for one person: no accounts, no server, and all data stays on the phone.

## What it does

| Screen | What's on it |
| --- | --- |
| **Today** | Greeting and date. Today's Lift and Run tiles, Start Workout, Steps and Calories from Apple Health. Adherence calendar. |
| **Workout** | The live workout. One set at a time with big − / + controls, or every exercise in a list. Rest timer, coach targets, PRs. |
| **History** | One Monday–Sunday week at a time, lit up on a month calendar (tap a day to jump to its week): workouts, runs, miles, average workout time, and each finished session. |
| **Plan** | Lift days and their exercises (the source of truth for weights), plus the weekly schedule of lifts and runs. |
| **Settings** | Name, accent color, Strava and Apple Health, coach, notifications, rest timer, backup export/import. |

### Adherence calendar

A month at a time, Sunday to Saturday. Tap a colored day to open it.

- **Green**: lifted. **Blue**: ran. **Half and half**: did both.
- **Faded**: planned but missed.
- **Gray with a moon**: rest day (no lift and no run planned).
- **Plain gray**: before the program started, or still ahead.

### Coach

Targets come from your own history, not a fixed program (`GymTrak/Model/Coach.swift`).

- Double progression: hit the top of the rep goal on every set, then the weight goes up one step.
- After a dip, it works back up toward a weight you've already lifted.
- A top-set jump of over 30% between sessions counts as a new machine or setup, so it starts fresh.
- During a workout it nudges the next set up or down.
- Runs: +10% time while your heart rate stayed in zone.
- With **Auto-Set Weights** on (Settings), new workouts start already filled with the coach's targets.

Each exercise has a **Step** (Plan → exercise): how much one tap of − / + changes the weight.

### Load types

Every exercise picks how its weight is written (`LoadType` in `Models.swift`, grammar in `Load.swift`). The stored value is always a string.

| Type | Examples |
| --- | --- |
| Weight | `225 lb` |
| Dumbbell | `70 lb` (each hand) |
| Machine | `10` (pin) · `120 lb` · `Max` · `Max + 10` |
| Plates | `6 pl` · `5 pl + 25` |
| Body | `BW` · `+70` (added) · `−25` (assisted) |
| Other | free text, kept as typed |

### Notifications

Planned 7 days ahead and rebuilt every time the data changes (`GymTrak/Store/Notifier.swift`). Each can be turned off in Settings.

| When | Title | Body |
| --- | --- | --- |
| 7:00 AM on a training day | "Lower A today" | none |
| 8:00 PM if it's not logged | "Lower A isn't logged yet" | "Still time to keep the week clean." |
| Sunday 7:00 PM | "Your week" | "4 of 5 workouts", then "9.1 mi" on the next line |
| When rest ends | "Rest's up" | "Time for the next set." |

### Beyond the app

- **Live Activity**: the rest countdown and the next set, on the lock screen and in the Dynamic Island.
- **Widgets**: a Today widget (small, medium, and three lock-screen sizes).
- **Apple Watch**: today's plan, the live set with the Digital Crown, rest haptics, and heart rate and calories saved to Apple Health. The Ultra's Action Button starts today's lift. Watch complications too.
- **Apple Health**: reads runs, steps and calories. Saves lifts.
- **Strava**: reads runs. A run found in both Strava and Health counts once.
- **Spotify**: play/pause and skip during a workout (needs a client ID and Premium).

## Requirements

- macOS with **Xcode 27** or newer. The app targets iOS 26 and watchOS 26.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`
- A paid Apple Developer team, for Apple Health, the App Group, and installing on a phone

## Setup

1. Generate the Xcode project:
   ```bash
   xcodegen generate
   ```
2. Copy the secrets file. Every value is optional; the app runs without them.
   ```bash
   cp Secrets.example.xcconfig Secrets.xcconfig
   ```
   | Key | Where to get it |
   | --- | --- |
   | `STRAVA_CLIENT_ID`, `STRAVA_CLIENT_SECRET` | strava.com/settings/api. Callback domain: `strava` |
   | `SPOTIFY_CLIENT_ID` | developer.spotify.com. Redirect URI: `gymtrak://spotify` |
3. Set your team in `Config.xcconfig` (`DEVELOPMENT_TEAM`).
4. Open `GymTrak.xcodeproj` and press ⌘R.

### Install on an iPhone from the terminal

Turn on Developer Mode on the phone first (Settings → Privacy & Security). Keep the phone unlocked while it installs.

```bash
xcodebuild -scheme GymTrak -destination 'generic/platform=iOS' -derivedDataPath build -allowProvisioningUpdates build
```

```bash
xcrun devicectl list devices
```

```bash
xcrun devicectl device install app --device <DEVICE_ID> build/Build/Products/Debug-iphoneos/GymTrak.app
```

Installing over the app keeps its data.

### Move data onto a phone

A fresh install starts from the built-in plan. To copy a data file over:

```bash
xcrun devicectl device copy to --device <DEVICE_ID> --domain-type appDataContainer --domain-identifier dev.ivanshishkin.gymtrak --source gymtrak.json --destination Documents/gymtrak.json
```

Or use **Settings → Export Backup / Import Backup**.

### Launch flags

| Flag | Effect |
| --- | --- |
| `-demo` | Uses a separate `gymtrak-demo.json`, so you can try things without touching real data |
| `-holdLoading` | Keeps the launch animation on screen |

## Tests

Swift Testing, in `GymTrakTests/GymTrakTests.swift`. They cover the pure logic: loads, the coach, history, the adherence calendar, notifications.

```bash
xcodebuild test -scheme GymTrak -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

## How it's built

- **One snapshot.** The whole database is one `Snapshot` value (`Model/Models.swift`): days, exercises, the schedule, sessions and sets. Its JSON shape matches the web app's `gt_state`.
- **One store.** `Store/Store.swift` holds the snapshot in memory and writes `Documents/gymtrak.json` after every change. The iPhone's iCloud Backup includes that file.
- **Pure changes.** Every edit is a plain function on `Snapshot` in `Model/Actions.swift`, run through `store.mutate { … }`. Reads work the same way: the coach, history, stats and notification plans are pure functions, which keeps them easy to test.
- **The phone is in charge.** The widget, the watch and the Live Activity never touch the store. The app sends each one a small summary:
  - widgets: `WidgetData`, written to the App Group `group.dev.ivanshishkin.gymtrak`
  - watch: `WatchState`, over WatchConnectivity (`Store/WatchBridge.swift`)
  - Live Activity: `RestActivityAttributes` (`Store/LiveRest.swift`)

  `RootView.refreshOutputs()` resends them, and replans notifications, whenever the data changes.

## Project layout

```
GymTrak/            iPhone app
  Model/            Snapshot types, actions, coach, history, loads, dates and schedule
  Store/            Store, rest timer, Live Activity, notifications, Health/Strava, Spotify, watch and widget bridges
  Views/            Screens; Theme.swift has the colors and shared pieces
Shared/             Code used by more than one target (widget data, watch messages, Live Activity)
Widgets/            iPhone widget and the rest Live Activity
Watch/              Apple Watch app
WatchWidgets/       Watch complications
GymTrakTests/       Unit tests
scripts/            make-icon.swift (draws the app icon)
docs/NEXT.md        Feature briefs
project.yml         XcodeGen spec (run `xcodegen generate` after adding or removing files)
```

## Conventions

- Matte black by default. Use the `Page` and `Theme` colors in `Views/Theme.swift`; never hardcode colors.
- Short labels, no filler text.
- Add a test for any new pure logic.
- Small commits, one change each.

## Not done yet

- Strava: no API app has been created, so Connect doesn't work yet.
- Spotify: needs a client ID.
- The watch app hasn't been installed on a real watch.
