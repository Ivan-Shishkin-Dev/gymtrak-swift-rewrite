# Next features — briefs for implementation agents

No open briefs. The first five (finish summary, exercise history chart, haptics and rest auto-start, week dots and streak, plate breakdown) shipped. Spotify was built and later removed, as were Strava, the home-screen widget, the Apple Watch app and Kisi; don't add them back unless asked.

Rules for any new brief:

- Each brief is self-contained: why, files to read first, numbered build steps, and "done when".
- Project is XcodeGen: after adding a file run `xcodegen generate`.
- Build + test: `xcodebuild -scheme GymTrak -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' test | tail -40`
- Copy is terse ("less words"). Matte black theme: use `Page` / `Theme` colors, never hardcode.
- Add Swift Testing tests in `GymTrakTests/GymTrakTests.swift` for any pure logic.
- One commit per brief. Message ends with `Co-Authored-By: Claude Haiku 5.5 <noreply@anthropic.com>`.
