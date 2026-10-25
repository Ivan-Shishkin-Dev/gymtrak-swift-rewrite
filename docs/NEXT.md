# Next features — briefs for implementation agents

Each brief is self-contained. Read the named files first. Rules for every brief:

- Project is XcodeGen: after adding a file run `xcodegen generate`.
- Build + test: `xcodebuild -scheme GymTrak -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test | tail -40`
- Copy is terse ("less words"). Matte black theme: use `Theme.*` colors, never hardcode.
- Add Swift Testing tests in `GymTrakTests/GymTrakTests.swift` for any pure logic.
- One commit per brief. Message ends with `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`.

---

## 1. Finish summary sheet (PRs + next targets)

**Why:** Finishing a workout currently shows a one-line banner. The win is invisible. Show what was hit and what's next so the loop closes.

**Files:** `GymTrak/Views/RootView.swift` (`nav.completed`, lines ~131–150), `GymTrak/Views/WorkoutView.swift` (`finish(session:day:)`), `GymTrak/Model/Coach.swift` (`liftHistory`, `liftAdvice`, `loadScore`).

**Build:**
1. New file `GymTrak/Views/WorkoutSummaryView.swift`: `struct WorkoutSummaryView: View { let sessionId: String }`. Presented as a `.sheet` from `RootView` instead of the banner (keep `nav.completed` as the trigger; `.presentationDetents([.medium, .large])`).
2. Content, top to bottom:
   - Title: day name. Subtitle: duration (`durationSec`) and "N sets".
   - Section "PRs": every exercise whose top-set `loadScore` this session beats all prior sessions (`liftHistory(for:before:)` excluding this session). Row: name, trophy icon, "135 → 140". Hide section if empty.
   - Section "Next time": for each exercise, `liftAdvice(for:)` computed now (history includes this session), show `advice.target` + `advice.why`. Reuse `CoachLabelStyle` from `TodayView.swift`.
   - Big "Done" button.
3. Add `Snapshot.prs(sessionId:) -> [(Exercise, before: Double, now: Double)]` in `Coach.swift` as a pure function. Test: two sessions, second heavier → 1 PR; same weight → 0.

**Done when:** finishing a workout in the simulator shows the sheet with correct PRs and next targets; tests pass.

---

## 2. Exercise history chart

**Why:** "Am I progressing?" has no answer in the app today. One tap on an exercise should show the trend.

**Files:** `GymTrak/Model/Coach.swift` (`liftHistory(for:before:limit:)` returns `[LiftPerformance]`), `GymTrak/Views/WorkoutView.swift` (`allSetsList` section headers, `coachCard`), `GymTrak/Views/PlanView.swift` (`DayDetailView` exercise rows).

**Build:**
1. New file `GymTrak/Views/ExerciseHistoryView.swift`: `struct ExerciseHistoryView: View { let ex: Exercise }`. `import Charts`.
2. Load `store.db.liftHistory(for: ex, before: "9999-12-31", limit: 12)`, oldest first.
3. `Chart`: `LineMark` + `PointMark` of top-set load (lb) by date. Below the chart, a plain list: date · "135 × 8, 8, 7". Use `Theme.lift` for the line.
4. Empty state: "No history yet."
5. Entry points: tapping the exercise name in `allSetsList` section header and in `DayDetailView` rows opens it as a `.sheet`. Also a "History" item in `exerciseMenu`.

**Done when:** an exercise with ≥2 sessions shows a line that goes up; an exercise with none shows the empty state.

---

## 3. Haptics + rest auto-start

**Why:** Marking a set done should feel like something. Starting the rest timer by hand is a tap the lifter shouldn't need.

**Files:** `GymTrak/Views/WorkoutView.swift` (`toggle(_:ex:)`, `stepButton`, `bottomBar`), `GymTrak/Store/RestTimer.swift`.

**Build:**
1. In `WorkoutView` add `@State private var hapticTick = 0` and `.sensoryFeedback(.success, trigger: hapticTick)` on the root view. Increment in `toggle` when a set becomes done.
2. `.sensoryFeedback(.impact(weight: .light), trigger:)` for `stepLoad` / `stepReps` (a second tick counter).
3. In `toggle`, when a set becomes done and it is not the last set of the session, call `rest.start(ex.restSeconds ?? rest.defaultSec)` (check the actual `RestTimer` API first; if auto-start already exists, skip this step).
4. Settings → "Rest timer" section: add `Toggle("Auto-Start")` backed by `UserDefaults` key `gt_rest_auto` (default on). Respect it in step 3.

**Done when:** tapping a set done in the simulator starts the rest bar; toggling Auto-Start off stops that.

---

## 4. Last-7-days dots + streak on Today

**Why:** Consistency is the real metric. A row of dots under the hero makes the week visible at a glance.

**Files:** `GymTrak/Views/TodayView.swift` (`DaySections` hero card), `GymTrak/Model/Program.swift` (`scheduleWeek(_:)`, `scheduleTemplate`), `GymTrak/Model/Models.swift` (`Session.slotDate`).

**Build:**
1. Pure function in `Program.swift`: `Snapshot.weekDots(ending today: Date) -> [DayDot]` where `DayDot { date: String; state: .done | .missed | .rest | .upcoming }`. Done = a finished session with that `slotDate`. Missed = slot had a lift or run, date is past, no session. Rest = slot `isRest`.
2. `Snapshot.streakWeeks(today:) -> Int`: count consecutive past weeks (Mon–Sun) with zero missed days, stopping at the first week with a miss. The current week doesn't count until it ends.
3. Tests: 7 days with 3 scheduled, all done → 3 done dots; one missed → streak 0.
4. UI: in the hero card on `TodayView` (only when `showExercises == false`, i.e. home), a `HStack` of 7 circles 10 pt wide. Colors: done `Theme.lift`, missed `.red.opacity(0.6)`, rest `Theme.surface`, upcoming stroked. Right of it: "3 wk" in caption when streak ≥ 1.

**Done when:** the home hero shows the dots and the tests pass.

---

## 5. Plate breakdown on the set page

**Why:** For plate-loaded machines the number is "4 pl + 25"; the lifter still has to think about which plates. Show it.

**Files:** `GymTrak/Model/Load.swift` (`parseLoad`, plate grammar), `GymTrak/Views/WorkoutView.swift` (`coachCard`, `valueRow`, `displayLoad`).

**Build:**
1. Pure function in `Load.swift`: `func plateBreakdown(add: Double) -> [Double]` greedy over `[45, 35, 25, 10, 5, 2.5]`. Example: 40 → `[25, 10, 5]`.
2. `func plateLine(_ raw: String, type: LoadType) -> String?`: for `.plates` only, returns e.g. "4 × 45 + 25 + 10 + 5"; nil otherwise.
3. Tests: 40 → "25 + 10 + 5"; 0 add → just "4 × 45"; non-plate type → nil.
4. UI: under the load `valueRow` in `currentSetPage`, show `plateLine` in `.caption` `.secondary` when non-nil.

**Done when:** a plate exercise shows the breakdown line; a pin machine shows nothing extra.

---

## 6. Spotify media controller

**Why:** Switching to Spotify mid-set breaks the workout flow. A small bar on the workout screen with play/pause/skip and the track name keeps the lifter in the app.

**Reality check (iOS):** a third-party app cannot control "whatever is playing" system-wide; Apple gives no API for that. Spotify is controllable through its Web API (Spotify Connect), which needs a **Spotify Premium** account and a network connection. Use the Web API, not the Spotify iOS SDK (the SDK is a binary framework that needs the Spotify app open and makes the build harder).

**Files:** `GymTrak/Store/Connections.swift` (copy the Strava OAuth pattern: `StravaConfig.load`, `finishStrava`, `stravaTokenRequest`, `Keychain`), `GymTrak/Views/WorkoutView.swift` (`bottomBar`, `decorate`), `GymTrak/Views/RestBar.swift` (layout reference for a bottom strip), `GymTrak/Views/SettingsView.swift` (`connectionsSection`), `project.yml` + `Secrets.xcconfig` (`SPOTIFY_CLIENT_ID`).

**Setup (Ivan, 5 min):** developer.spotify.com → create app → redirect URI `gymtrak://spotify` → put the client ID in `Secrets.xcconfig` as `SPOTIFY_CLIENT_ID`. No secret needed (PKCE).

**Build:**
1. `project.yml`: add `SpotifyClientID: $(SPOTIFY_CLIENT_ID)` under info properties, like `StravaClientID`.
2. New file `GymTrak/Store/Spotify.swift`: `@MainActor @Observable final class Spotify`.
   - `connect()`: PKCE flow with `ASWebAuthenticationSession`, auth URL `https://accounts.spotify.com/authorize`, scopes `user-read-playback-state user-modify-playback-state user-read-currently-playing`, redirect `gymtrak://spotify`. Token exchange at `https://accounts.spotify.com/api/token`. Store refresh token in `Keychain` (key `spotify_token`). Reuse the existing `gymtrak://` URL handling and route `spotify` host to `finishSpotify(callback:)`.
   - `var state: PlaybackState?` with `track`, `artist`, `artURL`, `isPlaying`, `progressMs`, `durationMs`.
   - `refresh()`: `GET https://api.spotify.com/v1/me/player`. 204 = nothing playing.
   - `playPause()`, `next()`, `previous()`: `PUT /me/player/play`, `PUT /me/player/pause`, `POST /me/player/next`, `POST /me/player/previous`. A 403 with reason `PREMIUM_REQUIRED` → set `error = "Spotify Premium needed."`; a 404 (no active device) → `error = "Open Spotify first."`
   - Poll `refresh()` every 3 s only while `isVisible` is true (a `Task` started/cancelled by the view).
3. New file `GymTrak/Views/MediaBar.swift`: one row, 44 pt tall, matte surface: 40 pt album art (`AsyncImage`), track name + artist in two lines (caption, truncated), then `backward.fill` / `play.fill` or `pause.fill` / `forward.fill` buttons. Not connected → a single "Spotify" button that calls `connect()`. Error → show the error text in place of the track.
4. Place it in `WorkoutView` above `bottomBar` (inside the same `safeAreaInset(edge: .bottom)` stack as `RestBar`). Set `spotify.isVisible` in `.onAppear` / `.onDisappear`.
5. Settings → connections section: a "Spotify" row showing Connected / Not connected with Disconnect, matching the Strava row.
6. Inject `Spotify` the same way `Connections` is injected (check `RootView.swift` / the app entry for `.environment(...)`).

**Done when:** with Spotify playing on the phone, the bar shows the track and play/pause/skip work in the simulator (sign in once in the simulator's web view).

**Later:** lock-screen control is already Spotify's own; nothing to add. Playlist picker ("Gym" playlist on Start) via `PUT /me/player/play` with `context_uri` if wanted.

---

## Later (bigger, needs project.yml / Apple accounts)

- Home-screen widget "Today: Upper A" with a Start deep link (widget extension target + App Group for the JSON).
- Rest-timer Live Activity on the lock screen (ActivityKit, same extension).
- Strava app + Apple Health (paid team), then install on the phone.
- Paste `supabase/email-sign-in.html` into Supabase when accounts go live.
