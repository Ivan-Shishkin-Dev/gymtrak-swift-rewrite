# GymTrak — Swift rewrite

Native iPhone version of [GymTrak](https://github.com/Ivan-Shishkin-Dev/GymTrak), for personal use only.

## Stack
- SwiftUI + SwiftData
- Supabase sync (same `gt_state` blob as the PWA)

## Plan
1. Xcode project setup
2. Port data model + logic (`types`, `program`, `load`, `rotation`, `actions`) with tests
3. Screens: Program, live workout, week list, schedule editor
4. Supabase sync
5. Native extras: rest-timer Live Activity, widget, Apple Health
