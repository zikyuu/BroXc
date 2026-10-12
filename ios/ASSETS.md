# UI assets needed

What the app uses today is emoji and SF Symbols standing in for real artwork. This is every place that needs a proper asset, in the order it's worth doing.

**Conventions.** Vector first (SVG or PDF, single-colour glyphs as template images so the app can tint them); 1x artwork for illustrations at 3x export. Names `category-meat`, `account-dbs`, `empty-activity` and so on, in `Assets.xcassets`. The app draws a coloured rounded tile behind category and account icons, so those glyphs are one colour on transparent.

## 1. App identity (do first)
| Asset | Spec | Today |
|---|---|---|
| App icon, light | 1024×1024 PNG, no transparency, no rounded corners | a generated placeholder |
| App icon, dark | 1024×1024 (iOS 18 dark appearance) | none |
| App icon, tinted | 1024×1024 greyscale (iOS 18 tinted appearance) | none |
| Launch screen | simple logo mark on the warm background `#FBF6EE` | blank |
| Wordmark / logo mark | SVG, for the empty states and About | none |

## 2. Category icons (the biggest set)
21 seeded categories, 20 more in the "pick an icon" strip, and users can type any emoji. A custom glyph set means the tree reads consistently. Single-colour, 24pt grid, 2px stroke.

Seeded now: Food, Cooking Ingredients, Meat, Chicken, Pork, Beef, Fish, Vegetables, Fruit, Carbs, Condiments, Grocery Shopping, Eat Out, Snacks, Drinks, Transport, Public Transit, Taxi, Long Distance, Accommodation, Activities, Shopping, Clothes, Electronics, Souvenirs, Household, Health, Pant (bottle deposit), Misc.

Picker strip (also needed): coffee, ramen, game controller, books, briefcase, plane, dog, film, haircut, phone, receipt, plus a **custom category** fallback glyph and an **"Unsorted"** question-mark glyph.

## 3. Account icons
DBS, PayLah, YouTrip, savings / fixed deposit, cash, plus a generic bank for anything the user adds. Use the real brand logos only if you're happy with the brand-use rules; otherwise neutral glyphs in the account's colour.

## 4. Transaction-type icons
Reimbursement (handshake), income, refund, **cashback**, top-up / transfer between own accounts, money in (generic), **paid to a person**, paid for others, deposit / pant, **shared cost** ("I owe"), photo attached.

## 5. Trip artwork
- A trip emoji picker today: 🧳 🏰 🗼 🌆 🌲 🎉 🎌 🎡 🏔️ 🏖️ 🚂 🛳️ ✈️. Replace with ~12 illustrated stickers (city, beach, mountain, road trip, ski, festival, train, ferry, camping, museum, food tour, flight).
- Trip banner backgrounds: 6 soft gradients or illustrated patterns, matching the 6 trip colours. (Currently a flat gradient.)
- Trip Mode on / off badge.

## 6. Tab bar and navigation (SF Symbols are fine; this is only a decision)
Home, Activity, Trip, Reimburse, More: filled and outline variants. Keep SF Symbols for chevrons, plus, checkmark, ellipsis, pencil, magnifier, trash, camera, xmark. No custom art needed unless you want a signature tab bar.

## 7. Empty-state illustrations (one style, 4 colours max)
Home with no data (replaces 🌱), Activity empty, trip with no spending, "All clear" in Needs a look, "All settled" (replaces 🎉), nothing paid out yet, nothing owed, no search results, no sample data, backup restored / erased.

## 8. Receipt and photo placeholders
- Receipt thumbnail placeholder when the photo is missing (currently a 🧾 emoji).
- Photo-attachment placeholder and camera glyph.
- A "scan guide" overlay for the document camera (optional).
- Sample receipt image for Help, showing what a good photo looks like.

## 9. Charts
No images, but the palette needs a decision: 14 category colours (`Category.palette`) plus the pace colours (good, watch, over) and the chart's green budget line `#8FE3A9`. Check contrast in dark mode.

## 10. Help and onboarding
- 3 to 4 onboarding illustrations (add a screenshot, it's read on your phone, nothing leaves the phone).
- A Help hero image.
- Small step diagrams for: adding a receipt, reading a PayLah / DBS / YouTrip screenshot, the reimbursement log.

## 11. Dark mode
Every illustration needs a dark variant or must work on both backgrounds. Glyphs tinted by the app need no extra work.

## Suggested order
1. App icon (all 3) and launch screen.
2. Category glyph set and the 6 account glyphs.
3. Transaction-type glyphs.
4. Empty-state illustrations.
5. Trip stickers and banners.
6. Onboarding.

## Free sources that fit the "free, no paid API" rule
Phosphor Icons, Lucide and Tabler (MIT) for glyphs; unDraw and Open Peeps (free licences) for illustrations; SF Symbols for system chrome. Check each licence for app-store use.
