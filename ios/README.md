# Expense Tracker (native iOS)

SwiftUI + SwiftData. Everything runs on the phone: the database, the matching and the OCR (Apple's Vision
framework). No server, no account, no paid API.

## Open it

```bash
cd ios/ExpenseTracker
open ExpenseTracker.xcodeproj
```

`ExpenseTracker.xcodeproj` is generated from `project.yml` by [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`, then `xcodegen generate`). Re-run it after adding or removing files.

## Run it in the simulator

Pick an iPhone simulator at the top of Xcode and press **Run** (⌘R). Tap *Or look around with sample data*
on the first screen to load made-up spending.

## Run it on your own iPhone (free, no developer programme)

1. Plug the iPhone in and trust the computer. On the phone: Settings → Privacy & Security → Developer Mode → on.
2. In Xcode: the **ExpenseTracker** project → **Signing & Capabilities** → tick *Automatically manage signing*,
   and set **Team** to your Apple ID ("Personal Team"). Sign in under Xcode → Settings → Accounts if it isn't listed.
3. Choose your iPhone as the run destination and press **Run**.
4. First launch only: on the phone, Settings → General → VPN & Device Management → trust your Apple ID.

A free-signed app stops opening after **7 days**. Plug in and press Run again to refresh it. Your data stays on
the phone and is untouched by that (it lives in the app's own storage, not in the signature).

## Tests

```bash
xcodebuild test -project ExpenseTracker.xcodeproj -scheme ExpenseTracker \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

`RealImageOCRTests` runs OCR on `youtrip_screenshot.png` / `translated_receipt.png` in the repo root if they're
there, and skips otherwise (they're personal and gitignored).

## Layout

- `Models/` SwiftData models (the same schema as the Python backend)
- `Services/` ledger and insights logic, the Hungarian matcher, the actions that change data, OCR and parsers
- `Views/` SwiftUI screens and components
