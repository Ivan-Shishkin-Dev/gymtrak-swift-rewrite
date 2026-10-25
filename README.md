# GymTrak — Swift rewrite

Native iPhone version of [GymTrak](https://github.com/Ivan-Shishkin-Dev/GymTrak), for personal use only.

## Stack
- SwiftUI, native iOS look (light + dark)
- Local JSON store; Supabase sync on the same `gt_state` blob as the PWA

## Run
1. `brew install xcodegen && xcodegen generate`
2. Copy `Secrets.example.xcconfig` to `Secrets.xcconfig` and fill it in
3. Open `GymTrak.xcodeproj`, press ⌘R

Launch with `-demo` for a local sandbox (no sync, editing on).

## Plan
1. Xcode project setup
2. Port data model + logic (`types`, `program`, `load`, `rotation`, `actions`) with tests
3. Screens: Program, live workout, week list, schedule editor
4. Supabase sync
5. Native extras: rest-timer Live Activity, widget, Apple Health
