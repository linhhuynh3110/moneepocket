# MoneePocket 💰

A budgeting app for international students who work part-time in Australia. Track your spending, set budgets by category, split household bills with housemates and see where your money goes.

Built with **Flutter** and **Material 3**. It runs on the web as an installable PWA and adapts from phone to desktop.

**Live demo:** [linhhuynh3110.github.io/moneepocket](https://linhhuynh3110.github.io/moneepocket/)

> Built for COIT20270 *Application Development for Mobile Platforms* (CQUniversity, 2026). It develops an earlier prototype into a working app.

---

## Features

| Screen | What you can do |
|---|---|
| **Home** | See this month's budget, account balance, a chart of your top 5 categories and recent payments |
| **Add spending** | Record a payment with an amount and category, plus an optional note, date and receipt |
| **Payment details** | View, edit or delete a payment |
| **Budget** | Set weekly, monthly and yearly budgets and create your own categories |
| **Split a bill** | Split a household bill equally or by custom amounts and record your share |
| **Summary** | Compare Budget − Spent = Remaining for this week, month or year |
| **Privacy and data** | Change your display name, download a copy of your data or delete it all |

If a new payment would go over a category's budget, the app warns you before saving.

## Tech stack

- **Flutter** (Dart 3.9+), Material 3 with light and dark themes
- **[provider](https://pub.dev/packages/provider)**: state management with `ChangeNotifier`
- **[go_router](https://pub.dev/packages/go_router)**: URL-based routing with `StatefulShellRoute`
- **[shared_preferences](https://pub.dev/packages/shared_preferences)**: saves data between sessions (localStorage on the web)
- **GitHub Actions + GitHub Pages**: builds and deploys the PWA on every push to `main`

## Getting started

You'll need the [Flutter SDK](https://docs.flutter.dev/get-started/install) (stable channel).

```bash
git clone https://github.com/linhhuynh3110/moneepocket.git
cd moneepocket
flutter pub get
flutter analyze          # check the code
flutter run -d chrome    # run in Chrome
```

All the code is in one file, `lib/main.dart`, so you can also paste it into [dartpad.dev](https://dartpad.dev) to try it.

### Install it on your phone

- **Android (Chrome):** open the live demo, tap ⋮, then **Install app**.
- **iPhone (Safari):** open the live demo, tap Share, then **Add to Home Screen**.

Data is saved on each device, so the app opens with sample data the first time.

## How it works

### State management
All app data lives in one store, `MoneePocketStore`, which screens listen to through Provider. Data flows one way:

1. A screen calls a store method, for example `store.recordExpense(...)`.
2. The store updates its data and calls `_commit()`.
3. `_commit()` recalculates spending per category, notifies listeners and saves.
4. Every screen watching the store rebuilds with the new figures.

Screens never change or save data themselves. Only unsaved form input is kept as local widget state.

### Persistence
`MoneePocketServer` acts as a simulated backend. It saves the account as JSON with `shared_preferences`, so your changes are still there after you close or refresh the app.

### Navigation
Every screen has its own URL. The four main sections are kept separate with a `StatefulShellRoute`:

| Section | Route | Pages inside it |
|---|---|---|
| Home | `/home` | `/home/transactions`, `/home/privacy`, `/home/link-bank` |
| Budget | `/budget` | Budgets are edited in bottom sheets |
| Split | `/split` | `/split/status` |
| Summary | `/summary` | `/summary/category/:index` |

These open full-screen from any section: Add spending (`/add`), Saved confirmation (`/saved/:id`) and Payment details (`/expense/:id`, `/expense/:id/edit`).

### Gestures
| Gesture | Where |
|---|---|
| Swipe a payment left to delete it, with Undo | Home, All spending, Summary |
| Swipe a payment right to open its details | Home, All spending, Summary |
| Swipe a housemate away to remove them | Split a bill |
| Pull down to fetch housemates' replies | Split status |
| Swipe between tabs | Budget, Summary |

A short animation shows new users that payment rows can be swiped.

### Transitions
- Detail pages rise and fade in (`sharedAxisPage`).
- Add spending grows out of its button (`growFromActionPage`).
- The four sections cross-fade (`FadingSectionStack`).

### Responsive layout
`WindowSizeClass` sorts the window width into compact, medium or expanded:

| Width | Navigation | Layout |
|---|---|---|
| Under 600 dp | Bottom navigation bar | Single column |
| 600 dp and over | Navigation rail | Wider layout |
| 840 dp and over | Extended rail with labels | Two-pane Home, two-column Budget |

### Money model
The app keeps five figures separate: **account balance**, **budget**, **spent**, **remaining** (budget − spent) and **expected income**. Spent is always calculated from the recorded payments, so Home, Budget and Summary always agree.

## Design

| Colour | Hex | Used for |
|---|---|---|
| Teal | `#034C5F` | Primary colour: buttons, budget info, "Remaining" figures |
| Coral | `#EE6457` (text `#BF4236`) | Spending amounts |
| Mist | `#97BEC6` | Selected items |
| Peach | `#F9C4BA` | Highlights, such as a newly created budget |
| Cream | `#FDF5F4` | Background |

The palette feeds Material 3's `ColorScheme.fromSeed`, which also builds the dark theme. Each category has the same round icon (`CategoryAvatar`) on every screen. Buttons are at least 48 dp high so they're easy to tap.

## Project structure

```
lib/main.dart
├─ APP                              main(), MoneePocketApp
├─ STATE MANAGEMENT                 MoneePocketStore, MoneePocketScope
├─ PERSISTENCE - SIMULATED SERVER   MoneePocketServer
├─ NAVIGATION AND ROUTING           buildMoneePocketRouter (GoRouter)
├─ GESTURES                         SwipeableExpenseTile, swipe hint, Undo
├─ TRANSITIONS                      page transitions
├─ RESPONSIVE AND ADAPTIVE LAYOUT   WindowSizeClass, AdaptiveNavigationScaffold
├─ THEME                            BrandColors, moneePocketTheme
├─ MONEY MODEL                      SpendingCategory, Expense, budgets, split shares
├─ SHARED WIDGETS AND HELPERS       charts, avatar, amount input, dialogs
└─ SCREENS                          one block per route
web/                                PWA manifest, icons and index.html
.github/workflows/deploy.yml        builds and deploys to GitHub Pages
```

## Limitations

- There's no real backend. Bank linking and housemates' replies are simulated.
- Data is stored on one device and doesn't sync between devices.
- Receipts are saved by name only; no image is stored.

## Author

**Linh Huynh**, Master of Business Information Systems, CQUniversity Melbourne · [GitHub](https://github.com/linhhuynh3110)
