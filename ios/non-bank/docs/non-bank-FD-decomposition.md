# Functional Description — non-bank (decomposition)

_Decomposition of the non-bank iOS app onto the AYT FD template taxonomy. Generated from a multi-agent code analysis. Each leaf below becomes one Notion page; every page opens with a high-level mermaid diagram (sequence for integrations/screen-transitions, other types for single-screen logic)._

## Introduction

non-bank is an iOS personal-finance app for tracking money in/out without connecting to any bank. The central object is a Transaction (expense or income) that the user logs by typing an amount, scanning a receipt with AI/OCR, or importing a file. Three optional overlays compose onto any transaction: recurrence (auto-spawns dated child transactions and fires local reminder notifications), bill-splitting among locally-stored friends (with Splitwise-style netted debts and shareable deep links), and an exclude-from-insights flag. A read-only Insights screen turns the user's own logged history into category breakdowns, statistical-outlier cards (big purchase, big category month, cannibalization, small-purchase savings), linear-regression trends, and a per-day spending heatmap — all currency-normalized via a USD-pivot FX table refreshed daily from the Frankfurter API. Everything persists locally in SQLite and optionally syncs across the user's own devices via CloudKit (last-modified-wins), with lossless JSON / interop CSV+XLSX export. Identity is a stable human-readable user ID; the only monetization is a donation-only StoreKit tip jar. The app is privacy-first: anonymous bucketed analytics (default-on, toggleable), App Attest gating the AI endpoint, and no PII in share links or telemetry. Architecturally it is a SwiftUI app over a protocol-driven dependency-injection container, ObservableObject stores as single sources of truth, pure value-type services for testable business logic, and a centralized design-token system.

## Legend (page types)

| Icon | Type | Page content |
|---|---|---|
| 🔖 | Entity | definition + Properties table + Relations table |
| 🪄 | Action | trigger, preconditions, steps, result, errors |
| 🔅 | Property | requirements + formula/variable legend |
| 💡 | General rule | app-wide validation/formula/constraint |
| 🌀 | Global state | property values for a specific scenario |
| 🫧 | UX flow | step-by-step user journey |
| ⚙ | Configuration | configurable params / flags |
| 🧩 | Integration | external SDK/API/OS service |

## Page-count estimate

| Bucket | Pages |
|---|---|
| entities | 52 |
| propertyPages | 63 |
| actionPages | 150 |
| generalRulePages | 13 |
| globalStatePages | 24 |
| flowPages | 29 |
| configPages | 15 |
| integrationPages | 18 |
| **TOTAL** | **364** |

## Entities by area

### Transactions

#### 🔖 Transaction
_A single money event (expense or income) — the central domain object — with optional recurrence, split, and insights-exclusion overlays. Past one-offs and recurring children live on Home; future one-offs and recurring parents live on Reminders._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | Local SQLite autoincrement primary key; 0 for drafts/children pre-insert; re-stamped to 0 on import and rotated on Replace-reminder so it is never trusted across devices. | calculated — SQLite AUTOINCREMENT on insert |  |
| syncID | Stable cross-device/cross-version UUID identity; the durable key for CloudKit, share links, notification routing, SpawnTracker acks, receipt-item wiring, and detail-view lookup (because id can rotate). | derived — defaults to UUID().uuidString; preserved across edits/Replace/import |  |
| emoji | Display glyph; mirrors the chosen category's emoji. | derived from selectedCategory.emoji |  |
| category | Category title as a plain TEXT reference (not a FK). Renames walk the table; unknown titles resolve to 'General' (Uncategorized). | input/derived — validated via CategoryStore.validatedCategory | ✅ |
| title | Human label in rows/detail; trimmed, empty → 'My {category}' fallback, capped at 40 chars. | input |  |
| description | Optional free-text note rendered as Markdown in detail; nil when empty. | input |  |
| amount | Recorded out-of-pocket value (REAL). For splits equals splitInfo.paidByMe; for non-splits the full keypad value. Import stores abs(). | input/calculated | ✅ |
| currency | ISO 4217 code of this transaction, independent of the global base currency; defaults to global selectedCurrency, validated against the catalog. | input — defaults to selectedCurrency; can be set by receipt parser/import | ✅ |
| date | When the transaction counts: past/present → Home, future → reminder. Future dates allowed and show a 'Saved as a reminder' hint. | input — defaults to Date() |  |
| type | Expenses or Income; drives sign in balances/trends and notification title. Manual import infers from sign/synonyms, default Expenses. | input | ✅ |
| tags | Optional tag list; modeled and persisted (comma-joined) but always written nil by create/spawn — reserved/dead schema. | input — currently always nil |  |
| lastModified | Edit timestamp; CloudKit last-writer-wins ordering key; bumped on every create/edit/rename/orphan. | calculated — Date() |  |
| repeatInterval | Recurrence schedule (RepeatInterval). Non-nil + parentReminderID nil → recurring parent that spawns children and is shown only on Reminders. | input — built by DatePickerModal | ✅ |
| parentReminderID | Links a spawned child to its recurring parent's id; nil for parents/one-offs; cleared on orphaning. | calculated — set by ReminderService.spawnChild |  |
| splitInfo | Split breakdown (SplitInfo). Non-nil → split transaction; dropped if a split transaction is saved in income mode. | calculated — buildTransaction |  |
| payloadChecksum | SHA-256 of the share-link payload that produced an imported transaction; lets the classifier distinguish identical re-share vs edit. Synced via CloudKit. | fetched/derived — only for share-imported transactions |  |
| excludedFromInsights | Per-transaction flag: when true the row never contributes to insights/balance/trends but stays visible in the list. Inherited by spawned children; must be carried forward on every rebuild path. | input — default false; toggled in detail + row swipe | ✅ |
| isRecurringParent / isReminder | Role flags: isRecurringParent = repeatInterval!=nil && parentReminderID==nil; isReminder = isFuture \|\| isRecurringParent (drives Home vs Reminders partition). | calculated |  |
| displayPrimaryAmount | Row/detail amount: when includePotentialExpenses && splitInfo!=nil returns split.myShare ('Your share'), else the stored amount. Analytics do NOT use this. | calculated | ✅ |

**🪄 Actions:** Create, Edit, Delete, DeleteAll (Replace-all import wipe), RenameCategory (cascade), ToggleExcludeFromInsights, Share, ReplaceRecurringParent, SpawnRecurringChildren, OrphanFromParent, UpgradePhantomFriendID, Search, Filter, ProcessRecurringSpawns, ScheduleNotification, CancelNotification, OpenFromNotification, SettleUp (prefilled), Encode CSV/XLSX/JSON row, Parse manual import row, To/From CKRecord

**Relations:**
- Transaction 1→Many ReceiptItem (via transactionID/syncID; explicit cascade delete, no SQL FK)
- Transaction (recurring parent) 1→Many Transaction (children via parentReminderID)
- Transaction 1→1 SplitInfo (optional)
- Transaction 1→1 RepeatInterval (optional)
- Transaction Many→Many Friend (via splitInfo.friends FriendShare)
- Transaction Many→1 Category (by title reference)
- Transaction 1→Many UNNotificationRequest (one-off or per-pattern fan-out)
- Transaction (parent) 1→1 SpawnTracker ack entry (by syncID)
- Transaction 1→1 SharedTransactionPayload (encode/decode)
- Transaction 1→1 CKRecord (CloudKit mirror)
- Transaction Many→1 InsightsPeriod (filtered) and AnalyticsContext (input feed)

### Friends, Split & Debt

#### 🔖 SplitInfo
_The split breakdown persisted on a Transaction: full total, what I paid, my fair share, money I lent, per-friend shares, and the split mode._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| totalAmount | Full purchase amount before splitting (the keypad value); may be raised via the paid-upfront exceed-confirm flow. | input/calculated |  |
| paidByMe | How much the user actually paid out of pocket (sum of the 'me' payer entries); copied into Transaction.amount for splits. | calculated | ✅ |
| myShare | The user's fair share of the total; mode-dependent; drives include-potential display + insights normalization + share-link payload. | calculated | ✅ |
| lentAmount | Money fronted beyond my share = max(paidByMe − myShare, 0); equals the full total for a settle-up where 'me' paid. | calculated |  |
| friends | Per-friend FriendShare entries (share + paidAmount + isSettled), including extra payers not in the selected-friends set. | calculated |  |
| splitMode | How the split was computed (evenly/byItems/byAmount/settleUp); nil for legacy; auto-coerced to settleUp when the shape is 1-payer-1-distinct-receiver, and re-coerced on receive depending on item availability. | derived — resolveStoredSplitMode / normaliseSettleUp | ✅ |

**🪄 Actions:** Build, NormaliseSettleUp, ResolveStoredSplitMode, RehydrateForEdit, ComputePerTransactionSettlement

**Relations:**
- SplitInfo 1→1 Transaction (belongs-to)
- SplitInfo 1→Many FriendShare
- SplitInfo 1→1 SplitMode (optional)
- SplitInfo 1→1 SharedTransactionPayload (serialized)

#### 🔖 FriendShare
_One friend's portion within a split: their owed share, what they actually paid, and a settled flag._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| friendID | References a Friend record (or a phantom/payload participant id pre-upgrade). | input — Friend.id |  |
| share | This friend's fair portion of the total (mode-dependent: perPerson / manual / item-sum). | calculated |  |
| paidAmount | How much this friend actually paid upfront (0 if none); backward-compatible decode default 0. | calculated — from payers |  |
| isSettled | Whether this friend settled their debt — declared future scope for repayment tracking; never set true anywhere today. | input — default false |  |

**🪄 Actions:** Create, RewritePhantomID

**Relations:**
- FriendShare Many→1 SplitInfo (belongs-to)
- FriendShare Many→1 Friend (by friendID)

#### 🔖 Friend
_A local contact who can participate in split transactions; either a locally-typed 'phantom' or a verified connected user after a share-link round-trip._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | Primary key: a FriendIDGenerator phantom id (adjective-noun-4charBase32) or a real userID after share round-trip; dashed format never collides with the '__me__' sentinel. | input/generated — FriendIDGenerator.generate() | ✅ |
| name | Display name on rows/avatars/debt labels; trimmed, ≤35 chars, non-empty required for isValid. | input |  |
| groups | Group/tag names (Family, Work…) for filter chips and group-scoped debt; case-insensitively de-duplicated; stored as groups_json. | input |  |
| splitMode | Optional default split mode (picker currently hidden in the form but value preserved on edit). | input — optional SplitMode |  |
| lastModified | Sync conflict-resolution timestamp. | derived — Date() |  |
| isConnected | Whether id is a verified real userID vs a phantom; drives coloured vs B&W pixel-cat avatar; backward-compatible decode default false. | derived | ✅ |

**🪄 Actions:** Create, Edit, GuardedDelete (blocked if referenced by any split), UpgradePhantom, FilterByGroup, Search, SettleUp

**Relations:**
- Friend Many→Many Group (via groups)
- Friend 1→Many FriendShare (by friendID)
- Friend 1→Many Transaction (via splitInfo.friends)
- Friend 1→1 SimplifiedDebt (per-friend net balance)
- Friend 1→1 CKRecord (CloudKit mirror)
- Friend referenced-by DebtSummary.topFriendIDs

#### 🔖 SimplifiedDebtsSummary
_Splitwise-style netted debt result computed from all valid past splits: one SimplifiedDebt row per involved friend (positive = friend owes me, negative = I owe), plus an overall netAmount and status._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| rows | Per-friend simplified transfers touching '__me__', sorted non-zero-first then by magnitude; balances-out friends kept at amount 0. | calculated — greedy debt simplification | ✅ |
| netAmount | Sum of my simplified debts in the target currency. | calculated |  |
| status | settled / youOwe / youLent using a 0.005 epsilon. | derived |  |

**🪄 Actions:** Calculate (greedy simplify), Filter (active rows), ComputeUserPosition (per transaction)

**Relations:**
- SimplifiedDebtsSummary 1→Many SimplifiedDebt
- SimplifiedDebt 1→1 Friend (counterparty)
- SimplifiedDebtsSummary aggregates Many Transaction (past, non-parent, split)

#### 🔖 DebtSummary
_Aggregate debt position used by the Home debt badge: per-friend net map, overall net, top-3 friend avatars, and non-zero friend count for the overflow pill._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| perFriend | Per-friend net amounts excluding zero balances. | calculated |  |
| netAmount | Overall net position. | calculated |  |
| topFriendIDs | Up to 3 friends with largest \|amount\| (both directions), magnitude desc with friendID tiebreak. | calculated | ✅ |
| nonZeroFriendCount | Count of all non-zero-balance friends, for the '+N' overflow pill. | calculated |  |

**🪄 Actions:** Calculate (badge)

**Relations:**
- DebtSummary 1→1 DebtBadgeView
- DebtSummary 1→Many Friend (topFriendIDs)
- DebtSummary derived-from SimplifiedDebtsSummary

#### 🔖 SplitMode
_Enum describing how a split is calculated: evenly, byItems, byAmount, settleUp — with picker presentation metadata._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| rawValue | Wire/persistence format; evenly persists as '50/50' to avoid a backfill migration. | derived |  |
| displayLabel | Human label (Evenly / By items in receipt / By amount / Settle up). | derived |  |
| iconName/iconColor/helpText | Picker presentation (SF Symbol, tint, subtitle). | derived |  |

**🪄 Actions:** Select, Pick

**Relations:**
- SplitMode 1→Many SplitInfo
- SplitMode 1→Many Friend (default)

#### 🔖 Payer
_A who-paid-picker row (id 'me' or friend.id) with the amount they paid; the input shape that becomes paidByMe / FriendShare.paidAmount._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | 'me' sentinel for the user, else Friend.id. | input |  |
| name | 'You' or friend name. | derived |  |
| amount | Amount this payer contributed (numpad); balance/exceed rules with last-row rounding crumb. | input | ✅ |

**🪄 Actions:** EnterAmount, SetDefaultPayer, UpdateForTotal, ResetRow, ResetAll, AddRemaining, ConfirmWithNewTotal (exceed-overflow)

**Relations:**
- Payer Many→1 split draft (CreateTransactionViewModel.payers)
- Payer 1→1 Friend (by id, except 'me')

#### 🔖 PhantomUpgrade
_An inferred phantomID→realID mapping produced when an incoming share-link round-trip reveals a locally-typed phantom friend is actually the now-connected sharer._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| phantomID | Current local phantom Friend id to replace; the single unambiguous candidate from the old−new participant diff. | derived | ✅ |
| realID | Replacement real userID (= payload sharerID). | fetched — incoming share payload |  |

**🪄 Actions:** DetectUpgrade, ApplyUpgrade (FriendStore.upgradePhantom: insert-new + delete-old, isConnected=true)

**Relations:**
- PhantomUpgrade 1→1 Friend (the upgraded record)

### Reminders & Notifications

#### 🔖 RepeatInterval
_Codable recurrence-schedule enum (daily/weekly/monthly/yearly) carrying a fire time and day/month selectors; computes next-occurrence dates and notification triggers._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| case payload | daily(hour,minute) \| weekly(hour,minute,daysOfWeek) \| monthly(hour,minute,daysOfMonth) \| yearly(hour,minute,month,dayOfMonth); built from the picked date. | input — DatePickerModal.makeInterval |  |
| displayLabel | Full human description ('Every day at 09:00', 'Weekly on Mon, Wed at 09:00', etc.); not localized. | calculated |  |
| badgeLabel | Short row badge text (Every day / Weekly / Monthly / Yearly). | calculated |  |
| nextOccurrence(after:) | Next fire Date strictly after a reference date, per case, with seconds forced to 0 and bounded search horizons. | calculated | ✅ |

**🪄 Actions:** Calculate nextOccurrence, Calculate nextOccurrences, Calculate displayLabel, Build notification triggers

**Relations:**
- RepeatInterval belongs-to 1 Transaction (the recurring parent)
- RepeatInterval 1→Many DayOfWeek (weekly)
- RepeatInterval 1→1 MonthOfYear (yearly)
- RepeatInterval 1→1 SharedRecurring (share-link payload)

#### 🔖 DayOfWeek / MonthOfYear
_Codable Int-raw enums used by RepeatInterval: DayOfWeek sunday=1…saturday=7 (matches Calendar weekday); MonthOfYear january=1…december=12; both expose localized labels from Calendar symbols._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| rawValue | Maps directly to Calendar weekday/month component values. | static enum |  |
| label / shortLabel | Localized full/short symbol for display (via Calendar.current symbols). | calculated |  |

**🪄 Actions:** Provide label, Provide raw component value

**Relations:**
- DayOfWeek Many→1 RepeatInterval.weekly
- MonthOfYear 1→1 RepeatInterval.yearly

#### 🔖 SpawnTracker
_Stateless UserDefaults-backed helper tracking the highest acknowledged recurring-occurrence date per parent reminder syncID, so deleted auto-spawned children are not re-created._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| spawnAcks | UserDefaults dict [parentSyncID → unix timestamp] of the last acknowledged occurrence; monotonic high-water mark, never moves backward. | derived (persisted) | ✅ |

**🪄 Actions:** LastAcknowledged, Acknowledge, Clear

**Relations:**
- SpawnTracker Many→1 Transaction (parent reminder, by syncID)
- SpawnTracker read-by ReminderService.transactionsNeedingSpawn

#### 🔖 NotificationCoordinator
_ObservableObject + UNUserNotificationCenterDelegate bridging the OS notification center into SwiftUI: surfaces tapped notifications and keeps foreground banners visible._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| pendingTransactionSyncID | syncID of the transaction whose notification was tapped; consumed by MainTabView to open its detail sheet; set even pre-UI for cold-start handling. | fetched from userInfo[transactionSyncID] |  |

**🪄 Actions:** ConsumePendingTransaction, HandleNotificationTap (didReceive), PresentForegroundBanner (willPresent)

**Relations:**
- NotificationCoordinator 1→1 UNUserNotificationCenter (delegate at launch)
- NotificationCoordinator observed-by MainTabView

#### 🔖 UNNotificationRequest
_An OS-level scheduled local notification representing one fire pattern for a reminder, keyed by tx syncID so edits/deletes cancel the right set._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| identifier | 'tx-<syncID>-<suffix>' (once/daily/weekly-N/monthly-D/yearly); namespace for cancel/cleanup. | derived | ✅ |
| content.title/body/userInfo | 'Scheduled income/expense' title; '<emoji> <title>: <±><integerPart> <currency>' body; userInfo carries syncID. | calculated |  |
| trigger | UNCalendarNotificationTrigger; repeats=false for one-off, true (fanned out per sub-pattern) for recurring; ignores start-date. | calculated |  |

**🪄 Actions:** Schedule (cancel-then-add), Cancel, CleanupStale (launch)

**Relations:**
- UNNotificationRequest Many→1 Transaction (via syncID prefix)
- UNNotificationRequest 1→1 RepeatInterval sub-pattern (recurring)

### Categories

#### 🔖 Category
_A user- or system-defined spending/income classification, identified by a unique emoji + unique title, used as the grouping key for every transaction._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | Stable UUID stored as TEXT PRIMARY KEY and CloudKit syncID. | input — UUID() at creation |  |
| emoji | Visual glyph; must be a single emoji, unique across categories, and not the reserved 'General' 🙂. | user-input (emoji keyboard) / random suggested on create | ✅ |
| title | Display name + canonical grouping key matched against Transaction.category; trimmed, ≤32 chars, case-insensitive-unique. | user-input | ✅ |
| lastModified | Last-edit timestamp; bumped on update for CloudKit latest-wins. | derived — Date() |  |
| isValid | Model-level gate: emoji & title non-empty AND title.count ≤ 32. | calculated |  |
| isReserved | True for 'General' or one of the 18 seeded defaults (title-based, case-insensitive); reserved rows are read-only (no edit/delete/swipe). | calculated — CategoryStore.isReserved | ✅ |

**🪄 Actions:** Create, Edit (cascade rename across transactions), Delete, Calculate usage frequency, Pick for transaction, Drill into history

**Relations:**
- Category 1→Many Transaction (by title text reference)
- Category 1→Many CategoryTotal (per period)
- Category 1→Many MonthlyTotal (per month)
- Category Many→1 CategoryStore
- Category 1→1 CKRecord (CloudKit mirror)

### Receipt Scanning & OCR

#### 🔖 ReceiptItem
_A single line on a receipt (product, discount, fee, or tip) with name, optional quantity/unit-price/total, plus persistence and byItems split-assignment fields._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | In-memory UUID for SwiftUI iteration; distinct from persistedID so a record survives renumbering. | derived — UUID() |  |
| name | Item label as read from the receipt or typed; empty-string decode fallback. | input/parsed |  |
| quantity | Units purchased (optional, fractional allowed). | input/parsed via FlexibleDouble |  |
| price | Unit price (optional); OCR fallback = lineTotal/quantity. | input/parsed |  |
| total | Stored line total; preferred over qty*price. | input/parsed via FlexibleDouble |  |
| lineTotal | Best-effort signed line total used everywhere for sums/pruning/split. | calculated | ✅ |
| kind | Classification (item/discount/fee/tip) driving icon + split treatment; pure function of name+lineTotal, never persisted. | derived | ✅ |
| isUsable | True if name non-empty AND price-or-total != 0 (negatives allowed for discounts); filters garbage on decode. | calculated | ✅ |
| assignedParticipantIDs | Friend.id or '__me__' (selfParticipantID) responsible for this line in a byItems split; empty = unassigned; stored as JSON, NULL when empty. | input — ItemAssignmentFlow |  |
| persistedID | SQLite autoincrement PK; nil until inserted. | fetched/assigned |  |
| transactionID | Parent transaction local id; nil while in review; stamped on save. | assigned on save |  |
| syncID | Stable cross-device id for CloudKit and export linking. | derived — UUID |  |
| position | Display order top-to-bottom on the original receipt. | assigned on save (enumerate index) |  |
| lastModified | Edit timestamp. | derived — Date() |  |

**🪄 Actions:** Create, Edit (numpad), Delete, Rename, Classify (kind), AddPreset (Fee/Tips/Discount), AssignToParticipants, Persist (insertBatch/update/delete, replace-all per transaction), Sync (CloudKit reconcile), ReconcilePaidExtra (placeholder), RewriteItemAssignees (on share import)

**Relations:**
- ReceiptItem Many→1 Transaction (via transactionID/syncID)
- ReceiptItem Many→Many Participant (via assignedParticipantIDs)
- ReceiptItem Many→1 ParsedReceipt
- ReceiptItem 1→1 ReceiptItem.Kind (derived)
- ReceiptItem packaged-into ShareItems WireItem + ExportedReceiptItem

#### 🔖 ParsedReceipt
_The full structured result of parsing one receipt image: store, date, items, total, currency, suggested category, language._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| storeName | Merchant name (cloud path only; nil on OCR fallback). | fetched (LLM) / extracted |  |
| date | Receipt date string. | fetched (LLM) / parsed (geometry) |  |
| items | Line items; decode filters out non-isUsable rows. | fetched/parsed + filtered |  |
| totalAmount | Printed grand total used to cross-check Σitems; nil on OCR fallback. | fetched (LLM) via FlexibleDouble |  |
| currency | ISO code; backfilled from user base currency if nil. | fetched/detected (NLP/geometry) else user base |  |
| suggestedCategory | LLM's best match against the reserved-category list (tolerant compare); cloud only. | fetched |  |
| language | ISO-639-1 dominant language; analytics only. | fetched/detected |  |

**🪄 Actions:** Decode (JSON), Construct (heuristic), PostProcess, CrossCheckTotals, MergeBands, MergeMultiImage

**Relations:**
- ParsedReceipt 1→Many ReceiptItem
- HybridReceiptParser.Result 1→1 ParsedReceipt

#### 🔖 HybridReceiptParser.Result
_Wrapper around a ParsedReceipt carrying parse confidence, source provenance, totals-match flag, and AI-capacity telemetry._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| parsedReceipt | The structured receipt. | derived |  |
| confidence | high/medium/low — drives review-screen banners; high=cloud & totals match, medium=cloud & diverge, low=OCR fallback; multi-image takes the lowest. | calculated | ✅ |
| totalsMatch | Whether Σitems ≈ grandTotal within tolerance max(1%, 0.50); true by default for .low. | calculated | ✅ |
| source | cloud(provider) or ocrFallback. | derived |  |
| attemptedProvidersCount / poolRemaining / poolLow / reconciliationPasses | AI router/quota telemetry (analytics only). | fetched (backend) / calculated |  |
| cloudFallbackReason | Why cloud wasn't used (cloudOff/rateLimited/providersUnavailable/network/cloudError). | derived from thrown error |  |

**🪄 Actions:** Construct, MergeMultiImage, RankConfidence, OpenReview

**Relations:**
- HybridReceiptParser.Result 1→1 ParsedReceipt
- HybridReceiptParser.Result drives ReceiptReviewView

#### 🔖 OCRRow / ParsedItemGroup
_On-device OCR intermediates: an OCRRow is a visual row of recognized Vision text (grouped by Y-proximity) with a union bounding box; a ParsedItemGroup is the extracted item (name/qty/unitPrice/lineTotal) plus the source OCR row IDs for the highlighter overlay._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| OCRRow.lines / boundingBox / text | Member RecognizedLines (left-to-right), their union box (Vision normalized coords), and joined text. | fetched (Vision) / calculated |  |
| ParsedLineItem.name/quantity/unitPrice/lineTotal | Cleaned item fields; lineTotal is the rightmost price token on the row. | parsed (regex) / calculated |  |
| rowIDs | OCR row IDs that produced this item (highlighter overlay). | derived |  |

**🪄 Actions:** Recognize (Vision), GroupIntoRows, Classify (ReceiptColumnDetector), ExtractItems (geometry pairing), ParseItemLine, Highlight (manual selection), MapToReceiptItem

**Relations:**
- RecognizedLine Many→1 OCRRow
- OCRRow Many→1 ParsedItemGroup (via rowIDs)
- ParsedItemGroup 1→1 ParsedLineItem

### Insights & Spending Analytics

#### 🔖 AnalyticsContext
_A value-type bundle of the four pieces of state every Insights analytic needs (pre-normalised transactions, target currency, FX-convert closure, live emoji map), plus facade methods over CategoryAnalyticsService; memoised per host by AnalyticsContextCache._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| transactions | Pre-normalised feed: excluded rows dropped, split amounts rewritten to myShare when 'include potential' is ON, so every aggregator can naively read tx.amount. | derived — normaliseForInsights | ✅ |
| targetCurrency | ISO code all amounts are converted into before maths. | fetched — currencyStore.selectedCurrency |  |
| convert | Per-amount FX closure captured from CurrencyStore so live rate changes flow through. | derived |  |
| emojiByCategory | title→emoji map so analytics show the current category emoji, not the one frozen on the first matching transaction. | fetched — categoryStore.categories |  |

**🪄 Actions:** BuildFromStores, FilterByPeriod, NormaliseForInsights, Memoise (AnalyticsContextCache), Calculate (12 facade aggregators)

**Relations:**
- AnalyticsContext 1→Many Transaction (input feed)
- AnalyticsContext 1→1 InsightsPeriod
- AnalyticsContext 1→Many computed-result entities (CategoryTotal/BigPurchase/BigCategoryMonth/SmallPurchasesSavings/CategoryCannibalization/MonthlyTrend/DailyExpense/DayOfMonthAverage/DayOfWeekAverage/MonthlyTotal)
- AnalyticsContextCache 1→1 AnalyticsContext

#### 🔖 InsightsPeriod
_The time window the Insights screen aggregates over (independent from the Home DateFilterType): a specific calendar month, a rolling range (last 3/6/12 months, all time), or a user-defined inclusive custom range._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| case | month(year,month) \| last3Months \| last6Months \| lastYear \| allTime \| customRange(from,to). | input — PeriodPickerSheet / calendar chevrons / CustomRangeSheet |  |
| filter | Predicate per case; customRange normalises to start-of-day(from)..end-of-day(to) and swaps inverted bounds. | calculated | ✅ |
| headline / menuLabel | Display strings for the card headline and picker rows. | derived |  |
| previousFullMonth | Default selection = most recent fully-completed calendar month. | calculated |  |

**🪄 Actions:** FilterTransactions, FormatHeadline, ComputeRecentMonths, ApplyCustomRange

**Relations:**
- InsightsPeriod 1→Many Transaction (filters)
- InsightsPeriod 1→1 AnalyticsContext
- InsightsPeriod shared across CategoryTopCard / InsightsDetailView / SpendingCalendarCard

#### 🔖 CategoryTotal
_One aggregated row in a per-category breakdown for a TransactionType in a period: title, emoji, summed converted total, count, and share of the grand total._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| category | Category title; doubles as the grouping key (case-sensitive; assumed pre-canonicalised). | derived — tx.category |  |
| emoji | Glyph; prefers live emojiByCategory, falls back to first matching tx.emoji. | derived |  |
| total | Sum of converted amounts for this category. | calculated | ✅ |
| count | Number of contributing transactions. | calculated |  |
| share | 0..1 fraction of the grand total; drives the bar + % label ('<1%' for nonzero sub-1%). | calculated | ✅ |

**🪄 Actions:** Aggregate (topCategories), FormatPercent, DrillIntoHistory

**Relations:**
- CategoryTotal 1→1 Category (by title)
- CategoryTotal Many→Many Transaction
- CategoryTopCard 1→Many CategoryTotal

#### 🔖 MonthlyTotal
_One per-month bucket in a single category's history (drives CategoryHistoryView chart+list); every month in the window appears, zero-filled._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | 'yyyy-MM' stable sortable key matching the accumulation key. | calculated |  |
| total / count | Sum/count of converted amounts for the category in that month (0 for empty months). | calculated |  |
| date / fullLabel | First-of-month chart x-axis date + 'March 2026' list label. | calculated |  |

**🪄 Actions:** ComputeMonthlyHistory (monthCount / skipCurrentMonth params)

**Relations:**
- MonthlyTotal Many→1 Category
- CategoryHistoryView 1→Many MonthlyTotal

#### 🔖 BigPurchase
_The single most-outstanding individual transaction in the previous full month, by per-category z-score against the user's all-time per-transaction history of that category._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| transaction | The outlier transaction (opens detail on tap). | derived |  |
| convertedAmount | Amount in target currency (cached). | calculated |  |
| categoryMean | All-time mean per-transaction amount in this category ('your usual'). | calculated |  |
| multiplier | 'Nx more than usual' = convertedAmount/categoryMean (1 if mean≤0). | calculated | ✅ |
| zScore | (amount−mean)/stddev; ranks the winner; not rendered. | calculated |  |

**🪄 Actions:** Detect (biggestPurchaseInLastMonth), Open/Edit/Delete the outlier

**Relations:**
- BigPurchase 1→1 Transaction
- BigPurchase Many→1 AnalyticsContext

#### 🔖 BigCategoryMonth
_The single category whose total spend last full month was the most-outstanding outlier vs that category's prior monthly totals._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| total / mean | Last month's category total vs the mean of prior months (excluding last). | calculated |  |
| multiplier | 'Nx higher than typical' = total/mean (1 if mean≤0). | calculated | ✅ |
| zScore | (total−mean)/stddev over prior months; ranks the winner. | calculated |  |
| date | First-of-last-month narrative anchor. | derived |  |

**🪄 Actions:** Detect (biggestCategorySumInLastMonth)

**Relations:**
- BigCategoryMonth 1→1 Category (by title)
- BigCategoryMonth Many→1 AnalyticsContext

#### 🔖 SmallPurchasesSavings
_Habit-based savings result: small recurring purchases below an adaptive smallness threshold that form a recognisable habit, with the worst-month total (X) and qualifying count (N)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| smallnessThreshold | min(Q1, mean × 0.4) over all expense amounts; not rendered, kept for future surfaces. | calculated | ✅ |
| maxMonthlySavings | X — largest single-month sum of qualifying small purchases. | calculated |  |
| totalQualifyingSmallPurchases | N — count of small purchases inside qualifying months. | calculated |  |
| mostFrequentCategoryTitle/Emoji | Dominant habit category anchoring the card emoji. | calculated |  |
| smallPurchases | Full qualifying list, newest-first, for the detail sheet. | calculated |  |

**🪄 Actions:** Detect (smallPurchasesSavings), OpenFullList

**Relations:**
- SmallPurchasesSavings 1→Many Transaction
- SmallPurchasesSavings Many→1 AnalyticsContext

#### 🔖 CategoryCannibalization
_A single detected substitution event: one month where one category rose ≥+2σ while another dropped ≤−2σ, with deltas similar enough to read as substitution._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| categoryUp / categoryDown | The two categories involved (one increased, one decreased). | derived |  |
| deltaUp / deltaDown | Positive magnitudes above/below each category's mean. | calculated |  |
| zScoreUp / zScoreDown | Per-category z-scores vs prior-months baseline (excluding the candidate month). | calculated |  |
| monthDate | The month the substitution occurred in. | derived |  |

**🪄 Actions:** Detect (categoryCannibalization, with ≤0.30 asymmetry tolerance)

**Relations:**
- CategoryCannibalization 2→1 Category (up + down)
- CategoryCannibalization Many→1 AnalyticsContext

#### 🔖 MonthlyTrend
_Linear-regression monthly trend for one of three series (net balance cumulative / monthly expenses / monthly income), expressed as a signed average % change per month._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| kind | .netBalance / .expenses / .income. | input (card param) |  |
| percentPerMonth | Signed % change per month = slope/\|meanY\|×100; magnitudes <1% suppressed. | calculated — least-squares regression | ✅ |
| monthsCovered | Length of the time series ('Based on N months'). | calculated |  |
| isFavorable | Whether the direction is good for the user (balance/income up, expenses down). | derived |  |

**🪄 Actions:** Compute (monthlyTrend)

**Relations:**
- MonthlyTrend Many→1 AnalyticsContext
- MonthlyTrend Many→Many Transaction

#### 🔖 DailyExpense / DayOfMonthAverage / DayOfWeekAverage
_Per-day calendar-heatmap aggregates: one DailyExpense per calendar day of a month (zero-filled), one DayOfMonthAverage per day-of-month 1..31, one DayOfWeekAverage per weekday 1..7._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| DailyExpense.total/count | Sum/count of expense transactions on a specific calendar day (target currency). | calculated | ✅ |
| DayOfMonthAverage.average/monthsCounted | Average spend on that day-of-month; denominator varies for days 29-31. | calculated | ✅ |
| DayOfWeekAverage.average/daysCounted | Average spend per weekday occurrence across history. | calculated | ✅ |

**🪄 Actions:** ComputeDailyExpenses, ComputeAverageByDayOfMonth, ComputeAverageByDayOfWeek, ComputeMaxDailyExpenseEver, TapCell (day detail)

**Relations:**
- DailyExpense Many→1 InsightsPeriod month
- All Many→1 AnalyticsContext
- Heatmap colour scale anchored to maxDailyExpenseEver (all-time)

### Currency & Money Formatting

#### 🔖 CurrencyInfo
_Static metadata record for one supported currency: ISO 4217 code, English display name, and a flag/region emoji. The ~165-entry catalog is the single source of truth for supported currencies._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| code | ISO 4217 code; primary identifier (Identifiable id) and dictionary key. | input — hardcoded catalog |  |
| name | English display name shown in the rates sheet and search. | input — hardcoded (never fetched) |  |
| emoji | Flag/region emoji row glyph; '💱' fallback for unknown codes. | input — hardcoded |  |
| catalog / byCode / allCodes | Ordered array + O(1) lookup map + membership Set built from the catalog. | input / derived |  |

**🪄 Actions:** Lookup (byCode), ValidateMembership (allCodes)

**Relations:**
- CurrencyInfo 1→Many referenced-by Transaction.currency
- CurrencyInfo 1→1 ExchangeRate (by code)
- CurrencyStore 1→Many CurrencyInfo (catalog drives currencyOptions)

#### 🔖 CurrencyStore
_ObservableObject hub that owns the user's base currency and the USD-relative rate table, persists both, refreshes rates daily, and exposes conversion plus a usage-ranked currency picker list._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| selectedCurrency | User's base/display currency; locale-detected once on first launch (only if catalog-supported, else USD) then persisted; drives all conversion targets. | user-input / derived | ✅ |
| usdRates | [code: rate-vs-USD] table behind every conversion; 10-entry hardcoded seed, merged (per-key) with Frankfurter fetches, persisted as JSON. | fetched (merged) + seed + cache | ✅ |
| currencyOptions | Ordered picker list: base first, then by usage frequency desc → recency desc → alphabetical. | calculated | ✅ |
| ratesCacheDate | yyyy-MM-dd marker gating once-per-calendar-day refetch (date-equality, device-local). | calculated/persisted |  |
| transactions | Private snapshot (homeTransactions) used only to rank currencies in the picker. | input — updateTransactions |  |

**🪄 Actions:** DetectInitialCurrency, SetBaseCurrency, FetchRates, FetchIfNeeded, Convert, ConvertToUsd, ConvertFromUsd, UpdateTransactions, PersistOnChange

**Relations:**
- CurrencyStore 1→1 CurrencyService (converter)
- CurrencyStore 1→1 CurrencyAPI
- CurrencyStore 1→Many CurrencyInfo (catalog)
- CurrencyStore 1→Many ExchangeRate (usdRates)
- CurrencyStore 1→Many consumer views (BalanceHeaderView, DebtSummaryView, AnalyticsContext, etc.)

#### 🔖 ExchangeRate
_A single code→USD-relative multiplier (units of that currency per 1 USD; USD=1.0)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| code | Currency the rate applies to (dictionary key). | fetched (Frankfurter quote) / seeded |  |
| rate | Units of currency per 1 USD. | fetched / hardcoded seed |  |

**🪄 Actions:** Merge (per-key overwrite on fetch), Encode/Decode (JSON persistence)

**Relations:**
- ExchangeRate Many→1 CurrencyStore.usdRates
- ExchangeRate 1→1 CurrencyInfo (by code)

### Sharing & Cloud Sync

#### 🔖 SharedTransactionPayload
_Compact two-letter-key JSON object encoding a split transaction that round-trips entirely inside a share-link URL with no backend needed for the financials._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| v | Schema version (1); decoder rejects unknown versions. | input (constant) |  |
| id / s | Transaction syncID + sharer's UserIDService.currentID() (create-vs-update detection, sharer avatar/exclusion). | derived / fetched |  |
| ta / pa / ms | Total amount, sharer's paidByMe, sharer's myShare. | derived from SplitInfo |  |
| c / d / k / t / cn / ce | Currency, date (unix), kind (exp/inc), title, category title, category emoji. | derived |  |
| sm / sn | Split-mode raw value (nil for legacy) + sharer display name (nil → 'Friend'). | derived / fetched |  |
| f | Other participants (everyone except the sharer), order-preserved. | derived — array of Participant |  |
| r | Recurring rule (SharedRecurring); optional; unknown kinds → non-recurring import. | derived |  |
| checksum | SHA-256 hex of canonical sorted-keys JSON; identity/edit detection + the {share_id} storage key for the encrypted items channel. | calculated | ✅ |

**🪄 Actions:** Encode, Decode, CalculateChecksum, Base64URLEncode/Decode

**Relations:**
- SharedTransactionPayload 1→Many Participant (f[])
- SharedTransactionPayload 1→0..1 SharedRecurring
- SharedTransactionPayload 1→1 SharedTransactionLink URL
- SharedTransactionPayload 1→1 ResolvedShare (via mapper)
- SharedTransactionPayload Many→Many ReceiptItem (via ShareItems keyed by checksum)

#### 🔖 ResolvedShare
_Receiver-perspective output of ReceivedTransactionMapper: a ready-to-insert Transaction (identity flipped) plus the Friends/Category to create first and the payload checksum to persist._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| transaction | Ready-to-insert Transaction with receiver-perspective SplitInfo (sharer is now a Friend, receiver is 'me'). | calculated — identity flip | ✅ |
| newFriends | Friends not yet on the receiver's side; sharer at index 0 when included, marked isConnected=true. | calculated (set-difference) |  |
| newCategory | Category to create; nil when the payload title matches an existing one; unique-emoji fallback walk. | calculated | ✅ |
| payloadChecksum | SHA-256 of the source payload stored with the transaction for future re-import detection. | calculated |  |
| resolvedSplitMode | Items-aware split-mode decision: byItems promoted/demoted depending on whether items are available locally or arrived with the share. | calculated | ✅ |

**🪄 Actions:** Map (build), RewriteItemAssignees, PickUniqueEmoji

**Relations:**
- ResolvedShare 1→1 Transaction
- ResolvedShare 1→Many Friend (newFriends)
- ResolvedShare 1→0..1 Category (newCategory)
- ResolvedShare built-from 1 SharedTransactionPayload

#### 🔖 ShareIntent
_Classifier verdict telling the receiver UI what to do with an incoming payload: createAuto / createWithPicker / identical / updatePrompt / malformed._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| case | createAuto(index) \| createWithPicker \| identical(existingID) \| updatePrompt(existingID, knownIndex) \| malformed. | calculated — ShareIntentClassifier | ✅ |

**🪄 Actions:** Classify

**Relations:**
- ShareIntent produced-from 1 SharedTransactionPayload + receiver state
- ShareIntent 1→1 ShareLinkCoordinator.RoutingState

#### 🔖 ShareLinkCoordinator
_@MainActor app-level state machine driving the incoming-share flow from onOpenURL through classify, participant pick, encrypted-items fetch/decrypt, and store commit._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| routingState | Single source of truth for which share surface is on screen (picker/update-alert/identical/completed/errored/idle). | calculated (state machine) |  |
| pendingPayload | Decoded but unclassified payload; the View calls startRouting once stores are loaded. | derived — decode(url:) |  |
| fetchedReceiptItems | Items pulled+decrypted from the server-side store; nil = none/fallback. | fetched async |  |
| itemsFetchTask | Handle to the in-flight fetch/decrypt task awaited before deciding byItems vs byAmount. | derived (Task) |  |

**🪄 Actions:** HandleURL, FetchEncryptedItems, StartRouting, PickedParticipant (commit), ConfirmedUpdate, PersistFetchedReceiptItems, Reset

**Relations:**
- ShareLinkCoordinator 1→1 ShareIntentClassifier
- ShareLinkCoordinator 1→1 ReceivedTransactionMapper
- ShareLinkCoordinator 1→1 ShareItemsService + ShareItemsCrypto
- ShareLinkCoordinator 1→1 PhantomFriendUpgradeDetector
- ShareLinkCoordinator 1→Many stores (commits)

#### 🔖 ShareItems
_Server-side AES-256-GCM-encrypted bundle of a split transaction's receipt items, stored on the Worker at /v1/share-items/{checksum}, augmenting the URL payload (which carries only financials)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| shareID | Storage key = lowercase 64-char hex = payload.checksum. | derived |  |
| ciphertextBase64 | base64(nonce(12) ‖ ciphertext ‖ tag(16)) of compact WireItem JSON; key derived (HKDF-SHA256) from the URL payload string so the Worker can't decrypt. | calculated — ShareItemsCrypto | ✅ |
| WireItem (n,q,p,t,a) | Compact per-item wire format: name, quantity, unit price, line total, assigned participant IDs (~10 KB cap). | derived from ReceiptItem |  |

**🪄 Actions:** EncryptItems, DecryptItems, DeriveKey, Upload, Fetch, RewriteItemAssignees

**Relations:**
- ShareItems 1→1 SharedTransactionPayload (keyed by checksum)
- ShareItems 1→Many ReceiptItem (WireItem list)
- ShareItems served-by Cloudflare Worker

#### 🔖 CloudKitSync
_iCloud private-database mirror of the four local entities (Transaction, Category, Friend, ReceiptItem) as CKRecords in a custom zone 'NonBankZone', with last-modified-wins merge and change-token delta sync; foreground-driven._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| recordID | '<Type>_<syncID>' so the same logical row maps to one CKRecord across devices. | derived |  |
| lastModified | Conflict-resolution key — newest wins on push and pull. | input/derived |  |
| ck_serverChangeToken | Persisted CKServerChangeToken for delta fetches. | fetched / persisted |  |
| pendingDeletes | Per-type syncID lists of deletes that failed; retried on next pull. | derived (UserDefaults) |  |

**🪄 Actions:** CheckAccountStatus, CreateCustomZone, CreateSubscription, To/From CKRecord (4 types), SaveRecords (batched 400), DeleteRecords (batched 400), FetchChanges (delta), ResetChangeToken, InitialSync, PullChanges, Push (save/delete/batch), MergeTransactions, MergeCategories, ReconcileReceiptItems, RetryPendingDeletes, ReloadStores, EnableSync, DisableSync, ForegroundSync

**Relations:**
- CloudKitSync 1→Many Transaction/Category/Friend/ReceiptItem (CKRecord mirror)
- SyncManager 1→1 CloudKitService
- SyncManager 1→1 SQLiteService
- ReceiptItem record Many→1 Transaction record (by transactionSyncID)

### Import & Export

#### 🔖 NonBankExport
_Codable file envelope for lossless device-to-device transfer of transactions, the friends those transactions reference, and receipt items; the only fully round-tripping export format._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| schemaVersion | Version gate (1); importer accepts only matching versions, else routes the file through the manual wizard. | input / validated |  |
| exportedAt | Export timestamp (not read back on import). | calculated |  |
| transactions | Full Transaction records (splitInfo, recurrence, excludedFromInsights, syncID) within the date range. | fetched — filteredTransactions |  |
| friends | Only Friends referenced by any splitInfo so split rows keep real names on a fresh device. | derived |  |
| receiptItems | ExportedReceiptItem list keyed by parent transactionSyncID (local ids don't survive re-import). | derived |  |

**🪄 Actions:** BuildEnvelope, Encode (JSON export), DecodeNativeEnvelope (import), ExecuteNativeImport, ReplaceAllWipe, EstimateFileSize

**Relations:**
- NonBankExport 1→Many Transaction
- NonBankExport 1→Many Friend
- NonBankExport 1→Many ExportedReceiptItem
- ExportedReceiptItem Many→1 Transaction (via transactionSyncID)

#### 🔖 ExportedReceiptItem
_Receipt-item payload used only inside NonBankExport; a distinct Codable shape from ReceiptItem because ReceiptItem only encodes name/quantity/price/total and local transactionID won't survive re-import._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| transactionSyncID | Stable cross-device link to the parent transaction (used instead of local transactionID). | derived |  |
| name/quantity/price/total/assignedParticipantIDs/syncID/position/lastModified | Copied from ReceiptItem so byItems splits keep line detail. | copied |  |

**🪄 Actions:** InitFromReceiptItem (export), toReceiptItem (import rebuild, transactionID nil until parent inserted)

**Relations:**
- ExportedReceiptItem Many→1 Transaction (via transactionSyncID)

#### 🔖 ParsedImportRow / AppField
_Manual-import wizard intermediates: ParsedImportRow is one parsed record (user-mappable fields only) before becoming a Transaction; AppField is the enum of the 8 mappable fields (title, amount, currency, category, date, description, type, emoji) the wizard maps source columns onto._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| ParsedImportRow.amount | abs() of parsed numeric amount; the only REQUIRED field — record dropped (failedCount++) if unparseable. | calculated |  |
| ParsedImportRow.title/currency/category/emoji/date/description/type | Resolved with per-field fallbacks (title→'My {category}', currency→default, category→'General', date→today, type→Expenses/sign-inferred). | calculated |  |
| AppField.isRequired/label/fallbackDescription | Only .amount required; per-field human label + 'when unmapped' copy. | derived/static |  |

**🪄 Actions:** AutoDetectMapping (1:1 name + >50% sample heuristic), ManualMap (wizard step), Unmap/Skip, ValidateAvailableSourceFields (>30% rule), ParseRow, ParseAll (+ failed count), MapToTransaction (executeManualImport)

**Relations:**
- ParsedImportRow 1→1 Transaction
- AppField Many→1 source column (mapping [AppField:String])
- AppField drives ParsedImportRow build

#### 🔖 ZipEntry / MinimalZip
_Hand-rolled ZIP container used to package/unpackage .xlsx files (avoids an SPM dependency); MinimalZip writes STORE-only and reads STORE(0)+DEFLATE(8)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| path | Entry filename inside the archive (e.g. xl/worksheets/sheet1.xml). | input |  |
| data | Raw uncompressed bytes of the entry. | input/decoded |  |
| crc32 | CRC-32 (poly 0xEDB88320) written into headers; advisory only on read. | calculated | ✅ |

**🪄 Actions:** write (STORE-only archive), read (parse central directory), inflate (DEFLATE via Compression), XLSXCodec Encode/Decode, CSVCodec Encode/Decode

**Relations:**
- MinimalZip 1→Many ZipEntry
- XLSXCodec uses MinimalZip

### User, Onboarding, Settings & Monetization

#### 🔖 UserProfile
_The user's optional self-chosen display name, persisted locally and embedded in share-link payloads so recipients see a real name instead of 'Friend'._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| displayName | Name shown to share-link recipients (sn field); UserDefaults key user_profile_display_name; whitespace-trimmed; empty → nil. Stored in UserDefaults so it does NOT survive app deletion. | user-input | ✅ |
| isNameSet | Convenience flag the share flow uses to decide whether to show the pre-share name prompt. | derived — displayName() != nil |  |

**🪄 Actions:** Edit (ProfileNameSheet), Read

**Relations:**
- UserProfile 1→1 UserID (this device's user)
- UserProfile embedded-into SharedTransactionPayload (sn)

#### 🔖 UserID
_A permanent, human-readable identifier of the form adjective-noun-4charBase32 (e.g. 'amber-lynx-7K2D') identifying this user across devices and share links; iCloud- or device-bound._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| id | Stable identity shown in Settings (copyable), seeds the pixel-cat avatar, and is the friend-matching key for share links; resolved cloud > keychain > generate. | generated once; Keychain (device-bound, survives deletion) + iCloud KVS when sync on | ✅ |
| format | FriendIDGenerator output: 80-adjective + 72-noun + 4 Crockford-Base32 chars (no I/L/O/U); no collision check. | derived | ✅ |

**🪄 Actions:** Generate, Resolve (currentID), CopyToClipboard

**Relations:**
- UserID 1→1 UserProfile
- UserID seeds PixelCatView avatar
- UserID is the 's' field of SharedTransactionPayload

#### 🔖 OnboardingState
_Single boolean tracking whether first-launch onboarding completed; the gate between Splash and the main app. Device-scoped, deliberately NOT iCloud-synced._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| isCompleted | False → RootView shows OnboardingView; true → MainTabView. UserDefaults key onboarding.isCompleted; @Published. | user-input — set true on 'Get started' |  |
| initialBalanceText | Keypad string for the optional starting balance; only persisted as an 'Initial balance' Income transaction (Uncategorized) when parsed amount > 0. | input | ✅ |

**🪄 Actions:** Complete (markCompleted, optionally create initial-balance tx), Reset (test/QA only)

**Relations:**
- OnboardingState gates RootView
- OnboardingState set-by OnboardingView completion

#### 🔖 TipTier
_One of four consumable tip-jar in-app purchases with a culinary theme; buying grants nothing functional (pure donation)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| productID | StoreKit/App Store Connect identifier; must match the .storekit config (com.nonbank.tip.coffee/.croissant/.pizza/.chefstable). | static |  |
| emoji / title / blurb | Card presentation copy (☕ Coffee, 🥐 Croissant, 🍕 Pizza night, 🧑‍🍳 Chef's table). | static |  |
| badge | Pizza = 'Recommended', Chef's table = 'Most generous', others none. | derived |  |
| displayPrice | Localized StoreKit price string ('—' fallback); nominal $0.99/$2.99/$4.99/$9.99. | fetched — Product.displayPrice |  |

**🪄 Actions:** LoadProducts, Purchase, DismissConfirmation

**Relations:**
- TipTier 1→1 StoreKit Product
- TipTier purchased-via TipJarService
- TipTier maps-to analytics TipTier enum

#### 🔖 AppAttestKey
_A Secure-Enclave attestation key (one per install) that signs per-request assertions proving requests to the AI receipt endpoint come from a genuine, unmodified app on real Apple hardware._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| keyId | Reference to the Secure Enclave key (private key never leaves the enclave); sent as X-Attest-Key-Id; UserDefaults appattest.keyId (not secret). | generated by DCAppAttestService.generateKey() |  |
| attested | Whether the key has been attested and registered with the backend (fast-path guard). | UserDefaults appattest.attested |  |
| clientData / assertion | Per-request {t,n} blob + Secure-Enclave signature for replay-protected auth. | generated per request | ✅ |

**🪄 Actions:** EnsureAttestedKey, FetchChallenge, RegisterAttestation, GenerateAuthHeaders

**Relations:**
- AppAttestKey 1→1 install
- AppAttestKey authenticates the AI receipt-parse request
- AppAttestKey verified-by Cloudflare Worker (challenge/verify)

#### 🔖 SupportMailKind
_A pre-templated support email category (feature request / bug report / contact support) opened from Help & feedback._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| kind | feature \| bug \| support (CaseIterable). | enum |  |
| subject | Pre-filled subject, e.g. '[non-bank] Bug report'. | derived |  |
| body | Pre-filled prompt + device/version footer for triage. | derived | ✅ |
| recipient | Support address nonbankapp@gmail.com. | static |  |

**🪄 Actions:** ComposeMail (MFMailComposeViewController), FallbackToMailto, CopyAddress

**Relations:**
- SupportMailKind 1→1 mail composer (MailComposeView or mailto:)

### Core Infrastructure, Config & Integrations

#### 🔖 DIContainer
_App-wide hand-rolled dependency-injection registry mapping protocol types to concrete service instances, registered once at boot and resolved everywhere by protocol type._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| services | Backing dictionary keyed by String(describing: protocol type) → instance. | derived — register/registerDefaults |  |
| didRegisterDefaults | Idempotency + RELEASE self-heal guard so registerDefaults runs at most once. | derived |  |
| shared | Process-wide singleton. | derived |  |

**🪄 Actions:** Register, Resolve, ResolveOptional, RegisterDefaults

**Relations:**
- DIContainer 1→Many service instances (DatabaseProtocol, KeyValueStoreProtocol, repositories, NetworkClientProtocol, CurrencyAPI/Service, AnalyticsServiceProtocol)
- DIContainer consults AnalyticsAvailability.isFirebaseLinked

#### 🔖 SQLiteService
_Singleton raw-SQLite3 database conforming to DatabaseProtocol; owns table creation, a versioned ALTER-TABLE migration ladder, and async CRUD for transactions, categories, friends, and receipt items on a serial dispatch queue._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| db | OpaquePointer to the opened sqlite3 connection. | derived — sqlite3_open at init |  |
| dbName | On-disk filename app-data.sqlite in Application Support. | input (constant) |  |
| dbQueue | Serial DispatchQueue serializing all DB access; exposed async via withCheckedContinuation. | derived |  |
| jsonEncoder/jsonDecoder | Encode/decode complex columns (repeat_interval, split_info, assigned_participant_ids) to/from JSON text. | derived | ✅ |

**🪄 Actions:** OpenDatabase, CreateTables, MigrateSchema, Insert, InsertBatch (single transaction), FetchAll, Update, Delete, DeleteAll, FetchBySyncID, Close

**Relations:**
- SQLiteService 1→Many transactions/categories/friends/receipt_items rows
- SQLiteService conforms-to DatabaseProtocol
- SQLiteService backs all four repositories

#### 🔖 NavigationRouter
_@MainActor ObservableObject centralizing tab selection and app-level sheet presentation (create/edit transaction, import success, split-share prompt), injected as EnvironmentObject from the root._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| selectedTab / hideTabBar | Current tab index + whether the tab bar is hidden inside a flow. | input |  |
| showTransactionEditor / editingTransaction | Drive the create/edit modal; editingTransaction nil for create. | derived/input |  |
| autoOpenSplitFlow / autoOpenScanFlow / autoSplitByItems / prefilledFriendIDs | On-appear auto-open the split orchestrator or receipt picker, pre-arm byItems, and pre-select participants (friend-scoped CTAs). | input |  |
| showImportSuccess / importedCount / pendingSplitShareSyncID | Drive the import-complete toast and the post-create split-share prompt. | input |  |

**🪄 Actions:** ShowCreateTransaction, ShowEditTransaction, DismissTransactionEditor, ShowImportComplete, PromptSplitShare, DismissSplitSharePrompt

**Relations:**
- NavigationRouter 1→1 editingTransaction (Transaction)
- NavigationRouter references Friend (prefilledFriendIDs)

#### 🔖 AnalyticsEvent
_Closed enum that is the single source of truth for every analytics event, mapping each typed case to a snake_case Firebase name and a flat PII-free stringified parameter dictionary._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| name | Firebase event name; snake_case, ≤40 chars, alphanumeric+underscore. | derived (switch) |  |
| parameters | Flat [String:String]; values are short enums or pre-bucketed strings via AnalyticsBuckets — never raw amounts/PII. | derived (switch) | ✅ |

**🪄 Actions:** Track, TrackScreen

**Relations:**
- AnalyticsEvent Many→1 AnalyticsServiceProtocol
- AnalyticsEvent uses AnalyticsBuckets
- AnalyticsEvent references param enums (TransactionCreationSource, ScanProvider, ReceiptLanguage, StoreCategory, TipTier)

#### 🔖 AnalyticsServiceProtocol
_Backend-agnostic analytics surface implemented by FirebaseAnalyticsService (when linked) or NoOpAnalyticsService; resolved from DIContainer and reachable via @Environment(\.analytics). Owns first-use/activation gating, install clock, screen tracking, and error stabilization._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| enabled | Master on/off switch honoured by track/setUserProperty; toggled by the consent service. | input (consent) / derived |  |
| trackError code | Stable low-cardinality token: domain.code or 'msg_'+base36(hashedMessage) to protect dashboard cardinality. | calculated | ✅ |
| activation/firstUse gating | Once-per-install UserDefaults-flagged events; activation buckets time-since-install against the install clock. | calculated | ✅ |

**🪄 Actions:** Track, SetUserProperty, TrackScreen, SetEnabled, BeginSheet/EndSheet, RecordFeatureUseIfFirst, RecordActivation*IfNeeded, BootstrapInstallClock, RefreshUserProperties, TrackError, StartFlow

**Relations:**
- AnalyticsServiceProtocol 1→Many AnalyticsEvent
- AnalyticsServiceProtocol 1→1 AnalyticsConsentService (weak)
- AnalyticsServiceProtocol 1→Many AnalyticsUserProperty

#### 🔖 AnalyticsConsentService
_@MainActor singleton ObservableObject holding the user-controlled anonymous-analytics toggle (default ON), persisting it and pushing changes into the analytics master switch._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| isEnabled | User consent flag (default true); didSet persists + calls analytics.setEnabled immediately. | input | ✅ |
| hasUserSet | True once explicitly written, distinguishing default from explicit off. | derived (persisted) |  |
| analytics | Weak reference to the analytics service it drives. | input (wired at boot) |  |

**🪄 Actions:** Toggle (set isEnabled)

**Relations:**
- AnalyticsConsentService 1→1 AnalyticsServiceProtocol (weak)

#### 🔖 BackendConfig
_Compile-time config enum: the single source of truth for the Cloudflare Worker host backing receipt parsing, App Attest, and share-link previews (staging in DEBUG, production otherwise)._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| host | Active host (staging.non-bank.app DEBUG, non-bank.app otherwise); no runtime toggle. | derived — #if DEBUG |  |
| acceptedHosts | Set of all valid share-link backend hosts (current + legacy workers.dev + future) the decoder accepts so old links keep opening. | derived |  |
| baseURL | https://<host> root used by CloudReceiptParser and AppAttestService. | derived |  |

**🪄 Actions:** ResolveHost, ResolveBaseURL

**Relations:**
- BackendConfig 1→1 CloudReceiptParser
- BackendConfig 1→1 AppAttestService
- BackendConfig 1→1 SharedTransactionLink (acceptedHosts)

#### 🔖 ColorContext
_SwiftUI environment-driven sub-palette switcher (standard / reminders / split) letting a screen declare its color vocabulary once so descendants auto-pick the matching accent, surface tint, and pixel-illustration tint._

**Properties**

| Property | Purpose | Source | 🔅 page |
|---|---|---|---|
| accent / accentBold | Inline-highlight accent and the filled-button variant (≥3:1 white-on-fill). | derived — AppColors tokens | ✅ |
| surfaceTint / pixelTint | Page/card background hue and matching illustration tint giving the screen its atmosphere. | derived |  |

**🪄 Actions:** ApplyColorContext

**Relations:**
- ColorContext 1→Many AppColors token

## 💡 General rules

### General rules // Input amount (keypad)
- Keypad accepts up to 8 integer digits and 2 decimal digits (maxDecimalDigits=2).
- Single leading '.' becomes '0.'; only one decimal point; leading zeros stripped except '0.'; ',' normalized to '.'.
- isAmountValid requires Double(amount) > 0; for pure splits where the user paid 0, amount may be 0 and the transaction is still saved (validity bypass when splitInfo != nil).
- Receipt-locked amount: when pendingReceiptItems are present the keypad is blurred/disabled (except confirm), amount locked to the items' sum, edited only via the items editor.

### General rules // Money rounding & decimal precision
- Canonical rounding is (value*100).rounded()/100 (2 decimals); cents computed as Int((|amount|*100).rounded()) (half-up at the cent level).
- decimalPart always emits '.NN' (balance header); decimalPartIfAny omits the segment when cents==0 (rows); integerPart groups thousands with a single SPACE separator, 0 fraction digits.
- No currency-specific minor units: zero-decimal (JPY/KRW/VND) and 3-decimal (KWD/BHD) currencies are still rendered/rounded to 2 decimals.
- Compact K/M/B form (shouldUseCompact) triggers at |amount| ≥ 100,000: 1 decimal below 100 of the scaled unit, 0 decimals at/above, trailing .0 trimmed.
- Sign is rendered separately by the caller (balanceSign / explicit ±); formatters return absolute magnitude. Amount narratives swap spaces to non-breaking U+00A0 so a number never wraps mid-value.

### General rules // Amount parsing on paste/import
- Strip currency symbols/ISO codes/thousands separators/parens; take abs() (sign owned by type); normalize NBSP/narrow-NBSP to space.
- Support leading +/- and accounting parentheses '(100.50)' as negative; last-separator-wins decimal disambiguation; comma-only/dot-only use the ≤2-trailing-digit cutoff to tell decimal from thousands.
- Reject >8 integer digits; round to 2 decimals; manual import stores abs(amount), native import keeps the value verbatim.

### General rules // Validation (isValid)
- Transaction.isValid = emoji & category & title non-empty AND amount > 0 AND currency non-empty; buildTransaction returns nil with no category selected, but returns the tx for splits even when amount is 0.
- Category.isValid = emoji & title non-empty AND title.count ≤ 32. Friend.isValid / UserProfile / category title all require a non-empty trimmed value.

### General rules // Category title input
- Trim whitespace+newlines; max 32 chars enforced live (truncate) and at save; non-empty required.
- Case-insensitive uniqueness across all categories; SQLite UNIQUE on the title column (case-sensitive at DB level — a known divergence); dedup on load keys on title.lowercased() keeping the first occurrence.

### General rules // Category emoji input
- Exactly one emoji character (emoji keyboard forced; paste/cut/delete blocked); non-empty required.
- Cannot equal the reserved 'General' emoji 🙂; exact uniqueness across categories; SQLite UNIQUE on the emoji column; random unused suggestion on create (fallback ✨).

### General rules // Reserved categories & edit cascade
- 'General' + the 18 seeded defaults are reserved: no delete, no edit, no swipe; 'General' is auto-recreated on load if missing; isReserved is title-based (case-insensitive).
- Edit allowed only when valid AND dirty; on save, TransactionStore.renameCategory rewrites every transaction whose category==oldTitle to newTitle+newEmoji, bumps lastModified, and batch-pushes to CloudKit.
- Deleting a category does NOT reassign its transactions to General — orphans keep the old title text and render via fallback emoji.

### General rules // Friend & display-name input
- Friend.name and UserProfile.displayName trimmed, max 35 chars (truncated live); non-empty required to save.
- Group names de-duplicated case-insensitively; FriendIDGenerator/UserID avoid ambiguous Crockford chars (no I/L/O/U); display name must round-trip Cyrillic/accented/emoji unchanged (ships in share-link JSON).

### General rules // Money / debt epsilons
- Debt status, simplification, and avatar/row gating use 0.005 (creditor>0.005, debtor<−0.005); SplitMathHelpers payer/share detection uses a tighter 0.001.
- WhoPaid balance tolerance scales with participant count: 0.01×max(count,1); exceed detection uses total+0.001; a residual delta is added to the last payer's amount (rounding crumb).
- Insights normalisation substitutes split myShare only when |myShare − amount| > 0.0001; receipt-editor divergence/zero checks use exactMatchEpsilon 0.005; byItems calculator zeroEpsilon 0.001.

### General rules // Currency conversion
- All rates are USD-relative (USD=1.0); cross conversion always pivots through USD: amount_to = amount_from / rate_from × rate_to.
- Conversion is graceful/non-throwing: from==to short-circuits; a missing or zero rate returns the INPUT amount unchanged (passthrough, never crash/zero).
- Double arithmetic, no intermediate rounding — rounding only at display time. Analytics, balances, debts, and trends all convert into the user's selectedCurrency before any maths.
- Per-transaction settlement amounts stay in the transaction's own currency (no conversion); BigPurchase narrative deliberately shows the transaction's own-currency amount while ranking uses converted amounts.

### General rules // Currency code validity & rate freshness
- A code is supported only if present in CurrencyInfo.catalog/byCode (~165 codes); locale-detected currency accepted only if in the catalog, else USD; unknown codes render '💱' + bare code.
- Rates refresh at most once per calendar day (device-local yyyy-MM-dd equality, not a TTL); a successful fetch merges per key (keeps prior values for absent codes) and stamps the date; a failed fetch leaves rates/date untouched to retry next launch.

### General rules // Date / reminder handling & recurrence precision
- date ≤ now → Home; date > now → reminder; recurring parent (repeatInterval!=nil, parentReminderID==nil) → Reminders only, never Home; recurring children → Home, never Reminders. A transaction appears in exactly one list logically.
- Occurrence candidates always normalized to hour:minute:00 (seconds forced 0); spawn detection offsets minute-normalized parent.date by −1s so a save with non-zero seconds still spawns the HH:MM:00 occurrence; nextOccurrence returns strictly > the reference.
- Search horizons bounded (weekly 8 days, monthly 3 months, yearly 2 years); invalid calendar dates (e.g. Feb 30) skipped via nil from Calendar.date(from:).
- All reminder/date labels use en_US_POSIX with relative Today/Tomorrow shortcuts and year-aware formats; 'last month' everywhere means the previous fully-completed calendar month.

### General rules // Spawn idempotency (recurring)
- An occurrence is handled once: SpawnTracker ack is a monotonic high-water mark per parent syncID and never moves backward.
- Deleting an auto-spawned child still acks its occurrence so it is not regenerated; spawn detection uses max(latest child date, stored ack, pre-parent-date) as the lower bound.
- processRecurringSpawns is single-flight via one spawnTask handle so concurrent triggers (60s timer, scene-active, share-receive, store mutation) coalesce; catch-up is foreground-only (no background task).

### General rules // Notification identity & lifecycle
- All requests namespaced 'tx-<syncID>-'; only 'tx-' requests are app-owned; schedule() cancels the existing set before re-adding so edits don't leave stale fires.
- Recurring parent fans out to one repeating UNCalendarNotificationTrigger per sub-pattern; OS triggers ignore start-date so a future recurring may alert before tx.date (spawning still respects tx.date).
- cleanupStale at launch removes orphaned 'tx-*' requests left by interrupted deletes/older builds; authorization is fire-and-forget ([.alert,.sound,.badge]) with no re-prompt UI.

### General rules // Insights feed normalisation & gating
- Analytics run on homeTransactions only (past-dated, non-recurring-parent; recurring children included); excludedFromInsights rows always dropped; only amounts > 0 are counted by extreme/savings/trend/cannibalization aggregators.
- includePotentialExpenses ON substitutes split amount with myShare (>0.0001 difference), OFF uses raw paidByMe; this single pre-transform lets every aggregator read tx.amount naively.
- Sample stddev uses denominator max(n-1,1); outlier threshold z ≥ 2.0σ; baselines exclude the candidate/last month; card activity floors (≥14 active days, ≥2 categories, etc.) and per-category sample floors (≥5 tx, ≥3 prior months) gate visibility.
- Trend/extremes/averages/cannibalization always run on FULL history (ignore the picked period); only the Top cards and the calendar's Month mode respond to the shared period binding. A card hides entirely when its gates fail.

### General rules // Stable identifiers & ID generation
- Local SQLite autoincrement id is device-specific and never serialized/trusted across devices; every imported/spawned transaction is re-stamped id=0 so SQLite assigns a fresh value.
- syncID (UUID) is the durable identity used by detail views, CloudKit, share links, notifications, SpawnTracker, and receipt-item wiring; missing sync_id is backfilled on migration/read.
- CKRecord recordName = '<Type>_<syncID>' (Categories use UUID string, Friends use Friend.id); Friend/User IDs use FriendIDGenerator adjective-noun-4charBase32 (Crockford, no I/L/O/U), no collision check.
- Replace-reminder rotates id but preserves syncID by passing the old syncID into buildTransaction; phantom upgrade is insert-new + delete-old (id is PK, cannot UPDATE in place).

### General rules // Canonical JSON, checksum & crypto
- All checksum/link encoding uses JSONEncoder .sortedKeys + .withoutEscapingSlashes so identical data yields identical bytes; checksum is lowercase SHA-256 hex (64 chars).
- base64url for share links: standard base64 then '+'→'-','/'→'_', strip '='; decode reverses and re-pads.
- Share-items key derived via HKDF-SHA256 from the URL ?p= string (salt 'non-bank-share-items-v1', info 'items', 32-byte key); AES-256-GCM combined nonce(12)‖ciphertext‖tag(16); any decrypt/auth-tag failure → no-items fallback.
- App Attest client data is hand-formatted {"t","n"} JSON (fixed key order) with a 16-byte random nonce; clientDataHash = SHA256.

### General rules // Persistence invariants
- SQLite at Application Support/app-data.sqlite; all access serialized on one serial queue and exposed async; statements always finalized; batch inserts wrap rows in BEGIN/COMMIT.
- Schema evolution is forward-only additive ALTER TABLE inside migrateSchema gated by columnExists; split_info/repeat_interval/assigned_participant_ids stored as JSON TEXT; SplitMode.evenly persists raw '50/50' and FriendShare.paidAmount decodes 0 when absent to avoid backfills.
- Receipt items have no SQL FK cascade — the store deletes children explicitly and reconciles them on CloudKit; saving items for a transaction is replace-all (deleteAll then insertBatch).
- Device-scoped flags (onboarding.isCompleted) stay in UserDefaults; cross-device preferences (includePotentialExpenses) use NSUbiquitousKeyValueStore + UserDefaults mirror; settings toggles take effect immediately via didSet.

### General rules // Sync & conflict resolution
- Last-modified-wins for every synced entity; categories additionally dedupe by case-insensitive title; receipt items merge only once the parent transaction resolves locally.
- Every CRUD reloads from SQLite, bumps a monotonic version counter, schedules/cancels notifications, runs processRecurringSpawns, and pushes to CloudKit; failed deletes queue in pending-delete lists and retry.
- Sync is foreground-only (scene-active); the CKDatabaseSubscription is created best-effort but no remote-notification handler consumes it yet; missing record types on a fresh container are tolerated (return []).

### General rules // Insights exclusion & excluded-from-share
- excludedFromInsights rows drop from all aggregates but stay visible; spawned children inherit the flag; it must be manually carried forward on every rebuild path (edit, recurring-replace, rename, phantom-upgrade) — a fragile invariant.
- The share link deliberately omits emoji (re-derived), description, receipt items (separate channel), tags, lentAmount (derivable), isSettled (local-only), and excludedFromInsights (receiver decides); on update re-import the receiver's local title/category/emoji are preserved.

### General rules // Format capability / data loss on export
- Only the native JSON envelope round-trips fully (splits, receipt items, recurrence, excludedFromInsights, syncID); CSV/XLSX are flat 8-column interop formats that drop split/sync/recurrence/receipt metadata.
- CSV/XLSX emit UNSIGNED absolute amounts with the type column as the sole sign source; decimal separator always '.', locale grouping never written; ISO-8601 dates.
- Native envelope is auto-detected on import (decodable NonBankExport + matching schemaVersion + non-empty transactions) and skips the wizard; CSV/XLSX always go through the manual 8-step mapping wizard.
- No duplicate detection on import (re-importing in Add mode duplicates rows); Replace mode wipes all transactions but keeps local friends.

### General rules // Field-detection heuristics (import)
- Auto-map pass 1: exact case-insensitive column-name == AppField.rawValue; pass 2 (smart): chosen if >50% of up to 10 sample values pass that field's parser.
- Wizard 'available fields' filter: a column is offered for a field only if >30% of ≤10 samples parse (title/description/category/type accept any string); import is rejected unless an amount-candidate column exists (>30%).
- Ambiguous slash dates (both first parts 1..12) resolved by the user-chosen DD/MM vs MM/DD hint (default DD/MM); unparseable/unmapped date → today.

### General rules // Receipt parsing tolerances & non-product filtering
- Parser-level Σitems-vs-grandTotal tolerance = max(1% of total, 0.50); review-screen mismatch banner and tiled-cascade escalation fire at |diff| > 0.05.
- Price parsing supports EU (1.100,00) and US (1,100.00) thousands/decimals, currency glyphs and a closed ISO allow-list; bare integers accepted only when ≥10; rightmost price token = the line total; date/time false positives killed by shared lookbehind/lookahead.
- Non-product filtering spans 9 languages: tax/VAT lines are filtered (no .tax kind); fee/tip rows kept positive for proportional distribution; discount rows kept negative; masked cards/phones/dates/URLs/emails filtered.
- Multi-image merge concatenates items, sums per-image totals, takes the lowest confidence, and forces totalsMatch false.

### General rules // Privacy & analytics taxonomy
- Anonymous only: no names, amounts, titles, descriptions, receipt photos, email, or advertising ID; continuous numerics are bucketed (AnalyticsBuckets) before sending.
- Event names are snake_case ≤40 chars defined once in AnalyticsEvent; param values are short enums or pre-bucketed strings; unknown enums collapse to 'other'; error codes stabilized to low cardinality.
- Consent defaults ON (App Store 'Data Not Linked to You', no IDFA); the toggle flips the master switch immediately; activation/feature-first-use fire exactly once per install (UserDefaults-gated).
- Cloud upload bakes the image to strip EXIF; only device_id, reserved-category set, and locale accompany it; telemetry stores no image bytes/OCR text/merchant names; App Attest proves a genuine app instance (lenient on staging, strict on prod).

### General rules // Dependency injection & boot
- All cross-cutting services are accessed by protocol type via DIContainer.shared.resolve(_:); never instantiate production services at call sites; registerDefaults() runs once at launch and is idempotent.
- resolve crashes on a missing registration in DEBUG; in RELEASE it self-heals once via registerDefaults() then crashes only if still missing; use resolveOptional for tolerant dependencies.
- Firebase must be configured (FirebaseApp.configure) BEFORE the analytics service is registered/resolved, else logEvent silently no-ops; the Firebase-vs-NoOp choice is compile-time (canImport).

### General rules // Networking & backend host
- HTTP goes through NetworkClientProtocol.fetchData(from:); only 200–299 accepted, else NetworkError.badResponse; no API key/rate-limit handling on the anonymous Frankfurter endpoint.
- The active backend host is compile-time selected (DEBUG→staging, Release→production) with no runtime toggle; share-link decoding accepts any host in BackendConfig.acceptedHosts (current + legacy + future).
- App Attest graceful degradation: unsupported (simulator) or any error attaches no headers and lets the request proceed; concurrent first-requests coalesce onto a single in-flight attestation Task; prod 403 → caller falls back to local Vision OCR.

### General rules // Design tokens & styling
- AppColors/AppFonts/AppSpacing/AppRadius/AppSizes/AppMotion are the single source of truth; views use tokens, not raw colors/sizes/animations.
- Warm-palette rule: light mode uses warm cream/beige surfaces and warm greys (no system blue-greys or pure whites); dark mode mostly uses system semantic colors.
- Filled white-on-accent CTAs must use the *Bold accent variants (≥3:1), not the lighter tint accent; typography is fixed-pt (not Dynamic-Type aware by design).
- Sub-app screens declare a ColorContext (.reminders/.split) at the root so descendants inherit the matching accent/surface/pixel tint; text/danger/success/info do NOT flip per context. Avatars are coloured for connected/verified participants, B&W for phantoms; 'You' is always coloured.

## 🌀 Global states

- **App boot sequence (cold launch)** — non_bankApp.init: FirebaseApp.configure() (if linked) → DIContainer.registerDefaults() → wire AnalyticsConsentService.analytics → setEnabled(persisted consent) → bootstrapInstallClock() → build NotificationCoordinator and set it as UNUserNotificationCenter delegate (before SwiftUI mounts, for cold-start taps). All top-level @StateObject stores (currency/router/sync/notification/shareLink/transaction/category/friend/receiptItem) are created at app level and injected as EnvironmentObjects into RootView.
- **Splash gate** — splashDone=false on launch; SplashView held a minimum 1.5s (deterministic LCG star field) then cross-fades (easeInOut 0.35s) to Onboarding (first run) or MainTabView.
- **First-run / fresh install** — onboarding.isCompleted=false; displayName nil ('Not set'); no UserID yet (generated lazily on first currentID()); analytics consent=true (hasUserSet false); includePotentialExpenses=true; iCloud sync off; selectedCurrency locale-detected (fallback USD); usdRates = 10-entry seed; App Attest key not generated; SpawnTracker empty; CategoryStore not yet seeded.
- **First-launch seeded categories** — On first load with an empty DB: the 18 defaultCategories plus the reserved 'General' (🙂) catch-all are inserted (19 total); seeding skipped if any default title already exists.
- **DIContainer default registration set** — DatabaseProtocol→SQLiteService.shared; KeyValueStoreProtocol→UserDefaultsService; the four repositories→backed by SQLiteService; NetworkClientProtocol→NetworkClient; CurrencyAPIProtocol→CurrencyAPI(client); CurrencyServiceProtocol→CurrencyService; AnalyticsServiceProtocol→FirebaseAnalyticsService(enabled:true) if Firebase linked else NoOpAnalyticsService.
- **Empty SQLite database** — On first open all four tables are created via CREATE TABLE IF NOT EXISTS plus the receipt_items transaction_id index; fetchAll* return [] until rows are inserted.
- **Cold-launch loading** — hasLoadedOnce=false while the SQLite fetch is in flight; views show a skeleton (SkeletonTransactionList) instead of the empty state; flips true after first load() and stays true for the session (avoids flashing empty illustrations).
- **New transaction defaults (create modal open)** — isIncome=false, amount='', title='', selectedCurrency=global selectedCurrency (else USD), selectedCategory=most-frequent for the type (fallback Food/Income), note='', date=now, repeatInterval=nil, splitInfo=nil, excludedFromInsights=false, tab=.expense.
- **Settle-up prefill** — Opened from Friend detail 'Settle up': amount/currency/category('General')/single payer prefilled, splitMode=.settleUp, youIncludedInSplit=true, one friend selected, direction friendPaysMe (you lent) or iPayFriend; the user only taps Save and the balance zeroes.
- **Receipt-locked amount** — When pendingReceiptItems are non-empty the keypad is blurred + disabled (except confirm), backspace hidden, paste/clear suppressed; amount is locked to the items' sum and edited only via the items review/editor.
- **OCR-fallback / re-open / multi-image receipt states** — OCR fallback ParsedReceipt: store/date/total/currency/category/language all nil, confidence .low, totalsMatch true, source .ocrFallback. Re-open review uses a synthetic Result with confidence forced .high so banners don't fire. Multi-image merge forces lowest confidence + totalsMatch false. Discount preset seeds activeInput '-' with a locked leading minus and sum-floor at 0.
- **Default Insights period & include-potential default** — On Insights open, period = previousFullMonth (most recent fully-completed calendar month). includePotentialExpenses defaults true (iCloud value wins, else local UserDefaults, else true), so split analytics count myShare ('what the purchase cost me').
- **Insights empty / per-period empty states** — Zero transactions of either type → growing-plant 'Nothing to analyse yet'. Data overall but none for the picked period/type → compact 'No data for this period' pill. Calendar grid always renders 42 cells (6×7) padded so card height never jumps.
- **Reminders / Home reminders-chip states** — Empty reminders → SleepingCat (.reminders tint) + 'No Reminders'. Home chip: reminderCount==0 shows a plain clock glyph; >0 shows a capsule clock.badge + monospaced count ('Reminders, N pending'). Spawned-child defaults: id=0, new syncID, date=spawnDate, repeatInterval=nil, parentReminderID=parent.id, exclude flag inherited.
- **Friends / Debt empty states & settled badge** — No friends → EmptyBox 'No friends yet'. No past splits → SleepingCat (.split tint) 'Nothing to settle yet' / 'No splits yet with {name}'. DebtBadge when net~0 → lavender 'Settled' pill, no avatars. DebtSummary header derives from totalSummary across ALL transactions so it stays constant while group filters change.
- **Currency: seeded rates / stale-cache / offline / dropdown-collapse** — usdRates seed (USD 1.0, EUR 0.92, RUB 84, KZT 450, UAH 39, BYN 3.2, TRY 32, GBP 0.79, JPY 151, CNY 7.2) until a fetch populates others (other codes passthrough). On init, stale ratesCacheDate triggers a Frankfurter fetch with cached rates used meanwhile. Fetch failure leaves rates/date untouched. When no extra used currencies exist, CurrencyDropdownButton opens the full sheet directly instead of a menu.
- **Share routing idle / fresh CloudKit / sync-disabled / no-items share** — ShareLinkCoordinator.idle: routingState idle, no pending payload/items. Fresh CloudKit container: no record types (tolerated), zone/subscription not created, no change token — initial sync creates schema on first save. Default install: iCloudSyncEnabled=false, lastSyncedDate nil, device-bound user ID. No-items share (404/decrypt fail): fetchedReceiptItems nil, byItems coerced to byAmount, per-row 'N items' affordance hidden.
- **Export / Import idle & success states** — Export defaults: startDate one month ago, endDate today (clamped to today), format=.json; button disabled when no transactions in range. Import idle: only 'Choose a file' + 'JSON, CSV or Excel' footer. Wizard initial: defaultCurrency=selectedCurrency, dateFormatHint=.dayFirst, step 0=Amount, auto-map applied then unmappable fields cleared. Import success: green checkmark 'Import Complete', '{count} transactions imported', interactive-dismiss-disabled.
- **App Attest unsupported (simulator)** — DCAppAttestService.isSupported false → authHeaders returns [:]; staging backend leniently allows missing attestation so simulator dev works; production rejects (only ever runs on real devices, where the request still falls back to local OCR).
- **Tip jar unavailable / post-purchase** — Product fetch failure/empty → 'Tips are unavailable right now.' rows disabled, price '—'. On .succeeded: lastPurchasedTier set, 'Thank you!' card with the tier emoji, tip_purchase_succeeded fired, dismissal-dwell event suppressed.

## 🫧 UX flows

### App launch gating
1. Cold launch → RootView shows SplashView (pulsing crystal + 'non bank' wordmark + stars)
2. Hold splash ≥1.5s then set splashDone=true with a 0.35s cross-fade
3. If OnboardingState.isCompleted==false → OnboardingView, else → MainTabView
4. On .task, analytics.refreshUserProperties recomputes cohort user-properties; SQLite stores serve persisted data

### First-launch onboarding
1. onboarding_started fired; three paged illustration steps (Scan receipts, Split with friends, See where it goes), each firing onboarding_step_viewed
2. Final step 'Have any savings?': big amount header + currency dropdown + custom numpad (no Skip)
3. Tap 'Get started' → if amount>0 add an 'Initial balance' Income transaction in Uncategorized; setUserProperty has_completed_onboarding=true; markCompleted() flips the gate and fades into the tab view

### Create a simple expense
1. Tab-bar + opens CreateTransactionModal on .expense; default category auto-selected from history
2. Type the amount on the keypad; optionally tap title (NoteTagsModal), category pill, or date pill
3. Tap the checkmark (enabled once isAmountValid) → buildTransaction → TransactionStore.add
4. Insert to SQLite, reload, schedule notification, run spawn pass, push to CloudKit, dismiss

### Create a recurring reminder
1. In create modal tap the date pill → DatePickerModal; pick a (possibly future) date/time and a Repeat option (Daily/Weekly/Monthly/Yearly)
2. 'Saved as a reminder' hint appears; Done; Save → stored as a recurring parent (appears in Reminders, not Home)
3. NotificationService schedules repeating triggers (one per sub-pattern); processRecurringSpawns later materializes dated children on each elapsed occurrence (inherit parent fields, exclude flag, parentReminderID set)

### Recurring spawn catch-up (internal)
1. Trigger: app becomes active, the 60s timer ticks, or any transaction mutation
2. ReminderService.transactionsNeedingSpawn computes occurrences ≤ now not yet handled (using child max, SpawnTracker ack, minute-normalized parent.date)
3. spawnChild builds each child; repo.insertBatch persists; SpawnTracker.acknowledge bumps the ack; children pushed to sync; store reloads (single-flight via spawnTask)

### Edit a recurring parent (Replace)
1. Open the reminder detail → Edit → CreateTransactionModal in edit mode; change fields and confirm
2. Because it's a recurring parent, a 'Replace reminder?' alert is shown
3. Confirm → old parent deleted (children remain), new parent inserted with the SAME syncID and exclude flag preserved; notifications re-scheduled; tracked as an edit

### Tap a reminder notification
1. OS delivers the scheduled local notification (banner+sound+badge, even foreground)
2. NotificationCoordinator.didReceive reads userInfo[transactionSyncID] into pendingTransactionSyncID
3. MainTabView switches to Home, resolves the freshest transaction by syncID, opens TransactionDetailView (debts style if split), then consumes the event (cold-start retries on next store change)

### Delete a reminder (parent vs child)
1. Swipe-delete a row or delete from detail → TransactionStore.delete cancels its notifications
2. Deleting a child: SpawnTracker.acknowledge(parent, at: child.date) so the occurrence is not re-spawned
3. Deleting a parent: SpawnTracker.clear and surviving children orphaned (parentReminderID cleared) so they stop rendering as recurring

### Split a bill (evenly / byAmount)
1. In create modal (expense) tap the mode-entry chip → TransactionModeFlowSheet orchestrator
2. Pick mode and friends (FriendPickerView, includeYou); optionally set who paid (WhoPaidPickerView: compact single-payer or multi-select numpad, can exceed and confirm a new total)
3. Enter amount, Save → buildTransaction computes per-person shares, paidByMe, lentAmount; resolveStoredSplitMode may coerce to settleUp
4. ShareSplitPromptSheet ('Split saved') nudges the user to Share now

### Scan a receipt (happy path)
1. From CreateTransactionModal (amount=0) toolbar or byItems-without-receipt, open ReceiptSourcePickerView; take a photo (PlainCameraView) or pick up to 3 from the library
2. handleScannedImage shows ReceiptScanLoader (min 5s), builds CloudParseConfig, hands to HybridReceiptParser (tile tall receipts / upload to cloud with App Attest → ParsedReceipt; postProcess; confidence)
3. ReceiptReviewView shows store/items/totals + confidence banner if needed; on empty show an error
4. Tap 'Edit items' → ReceiptItemEditorSheet (numpad; presets Fee/Tips/Discount; live colour-coded total; save confirms divergence) ; Save → applyReceiptItems (currency + locked total carried through)

### Split a bill by items in a scanned receipt
1. From a Debts/Friend scan CTA, modal opens with autoSplitByItems and splitMode=.byItems; scan + review items
2. TransactionModeFlowSheet walks ItemAssignmentFlow one participant per step ('Which items did X take?'), fees/tips/discounts auto-distributed; final participant guarded so nothing is orphaned
3. ItemAssignmentReview shows per-person amount/count/percent (See breakdown → ProportionalChargesSheet); confirm → SplitShareCalculator distributes item totals + proportional charges; Save persists splitInfo + receipt_items

### Settle a debt
1. On Friend detail, when |balance|≥0.005 a 'Settle up' button appears; tap builds a SettleUpPrefill
2. CreateTransactionModal opens prefilled (amount, currency, category General, single payer, splitMode=.settleUp)
3. Save → normaliseSettleUp clamps to one payer (full total paidAmount) + one receiver (full total share), zeroing others, so the balance reads settled

### View and drill into debts
1. Home shows DebtBadgeView (Settled / You lent / You borrow + up to 3 cat avatars + '+N')
2. Tap → DebtSummaryView: header net total, optional group chips, per-friend rows, date-grouped past split transactions
3. Tap a friend → FriendDetailView (status, settle-up CTA, split history); tap a transaction → SplitBreakdownView (two-tone chart; PaidUpfrontView for who paid; ShareDistributionView for each person's share + 'N items' sheet)

### Create / edit / delete a friend
1. FriendsView '+' → FriendFormView with a fresh generated ID and focused name field; type a name (≤35), optionally assign groups
2. Save → FriendStore.add → repo.insert → reload → SyncManager.pushFriend(save) → analytics
3. Edit an existing row → FriendFormView(friend) → update; swipe-delete blocked with a 'Can't delete' alert if the friend is referenced by any split, else remove + pushFriend(delete)

### Filter & search the home feed
1. Tap quick-filter category chips, or open FilterSheetView for full category/type multi-select + jump-to-date calendar
2. Active filters render in ActiveFiltersBar; tapping a chip or 'Clear all' removes them
3. HomeViewModel.recomputeFiltered runs a 100ms-debounced off-main filter→group pipeline (date cut, search match, category/type match, group-by-day)
4. Search via SearchTransactionsView matches title/description case-insensitively, grouped by day

### Exclude a transaction from insights
1. Swipe a row's leading edge (eye.slash) OR open detail and tap the insights status card
2. transactionStore.update writes the toggled flag, light haptic, analytics event
3. Excluded rows drop from all aggregates (balance, trends, insights) but stay visible in the list so the user can unhide

### Manage categories (create / edit-rename / delete / pick / drill-into-history)
1. Open the Categories sheet or 'Choose Category' picker; create via + (random emoji + name, live conflict hints, save when valid+unique)
2. Tap a non-reserved row → EditCategoryModal (dirty + unique required); on save TransactionStore.renameCategory cascades the new title+emoji across every matching transaction and batch-pushes to CloudKit
3. Swipe-delete a non-reserved row (reserved rows are inert). Pick a category → onSelect commits to the draft. Tap a Top card row → CategoryHistoryView (6-month bar chart with dashed average + 'By month' list)

### Open Insights and review last month
1. On Home tap the 'Insights' capsule in PeriodPickerBar; the sheet opens with period=previousFullMonth
2. AnalyticsContextCache builds/returns the memoised context; cards render top-to-bottom subject to gates (Top spending/earning, trends, big purchase, big category month, cannibalization, small-purchases savings, spending calendar)
3. Tap a Top card period text → PeriodPickerSheet (month list + Custom range → CustomRangeSheet); period-aware surfaces re-render in lockstep
4. Explore the spending calendar (Month / Avg. month / Avg. week tabs, green→red heatmap, day-detail bottom sheet); tap 'See all' → InsightsDetailView; act on small-purchases savings → SmallExpensesListView

### Change the global base currency
1. Tap the currency dropdown in BalanceHeaderView/DebtSummaryView (CurrencyDropdownButton)
2. With multiple used currencies an inline menu shows base + used + 'More currencies'; otherwise the full CurrencyRatesSheet opens directly
3. Pick a code (or 'More currencies' → searchable rates sheet with 1-unit cross-rate subtitles) → onSelect sets selectedCurrency; @Published change persists and re-renders all balances/debts in the new base

### Daily exchange-rate refresh (internal)
1. App launch; CurrencyStore.init restores selectedCurrency + cached usdRates, then fetchIfNeeded
2. If ratesCacheDate != today, an async GET to Frankfurter /rates?base=USD runs
3. On success, rates merge into usdRates and today's date is stamped (and persisted); on failure existing rates/date persist and retry next stale launch

### Share a split transaction (outbound)
1. Save a split → ShareSplitPromptSheet, or tap Share on the detail; if no profile name → ProfileNameSheet first
2. buildShareURL: SharedTransactionLink.encode → https://<worker>/share?p=<base64url(JSON)>; byItems with items → encrypt + upload to /v1/share-items/{checksum} (best-effort)
3. System share sheet presents the URL (plain for AirDrop/Files; summary+URL for messengers/mail); the recipient sees the Worker OpenGraph preview; analytics shareLinkSent

### Open a received share link (inbound) and commit
1. Recipient taps the link → Worker /share HTML → redirect to nonbank://share?p=…; app onOpenURL → ShareLinkCoordinator.handle (decode, kick parallel item fetch, stash pendingPayload)
2. Once stores load, ShareIntentClassifier.classify → routingState: createAuto (no picker) / createWithPicker ('Who are you?') / updatePrompt (edit alert) / identical (navigate) / malformed (error)
3. pickedParticipant: optional PhantomFriendUpgradeDetector; await decrypted items; ReceivedTransactionMapper.map → identity flip + new friends/category + items-aware splitMode
4. Insert friends → category → add/update transaction; rewriteItemAssignees and persist fetched items; navigate to the transaction by syncID

### Enable iCloud sync & foreground delta sync
1. Settings → Sync toggle on → checkAvailability; if available enableSync (create zone + subscription), else 'iCloud Unavailable' alert
2. performInitialSync: fetch all remote + local, merge each type in dependency order (categories→friends→transactions→receiptItems), push deltas both ways, reset+prime change token, markSynced
3. On scene-active, syncIfEnabled → pullChanges (retry pending deletes, fetchChanges via token, apply deletes/changes, resolve receipt items to local parents, reloadStores)

### Export & re-import (lossless or via wizard)
1. ExportTransactionsView: pick a date range + format (JSON full backup / CSV / Excel), see count + estimated size, Export → write a temp file '{start}__{end}.{ext}' → ShareSheet
2. ImportTransactionsView: choose a file; if a native NonBankExport (schemaVersion 1) → straight to a Review screen (Add vs Replace) and lossless import (re-stamp id=0 keeping syncID, wire receipt items by transactionSyncID)
3. Generic JSON/CSV/XLSX → 8-step field-mapping wizard (amount required; default currency, DD/MM-vs-MM/DD hint) → Review → addBatch → Import Complete screen

### Authenticated AI receipt request (internal)
1. HybridReceiptParser needs auth for /v1/parse-receipt → AppAttestService.authHeaders(backendURL)
2. First time: generateKey → GET /v1/attest/challenge → attestKey(SHA256(challenge)) → POST /v1/attest/verify → persist keyId/attested
3. Per request: sign a fresh {t,n} clientData → attach X-Attest-* headers; backend verifies signature + monotonic counter; unsupported/error → no headers, request proceeds (prod 403 → fall back to local Vision OCR)

### Settings: leave a tip / toggle analytics consent / contact support
1. Settings → 'Leave a tip' → TipJarView loads StoreKit products; tap a tier → purchase sheet; verified success → transaction.finish() + 'Thank you!' card; cancel/fail → tracked
2. Settings → Privacy → flip the anonymous-analytics switch → AnalyticsConsentService persists + calls analytics.setEnabled immediately
3. Settings → Help & feedback → Request a feature / Report a bug / Contact support → MailComposeView prefilled (or mailto: fallback, or 'Copy address')

### Set / edit display name & pre-share name prompt
1. Settings → 'Your name' row → ProfileNameSheet (centered field, 35-char cap); Save persists the trimmed name (shown to split-share recipients; empty shares as 'Friend')
2. When sharing a split without a profile name, ProfileNameSheet appears first ('What's your name?') with dismissOnSave=false so the parent can transition the sheet from .askName to .share without the dismiss racing the swap

### Database schema upgrade on app update
1. SQLiteService.init runs migrateSchema on the serial queue
2. columnExists checks each new column via PRAGMA table_info; missing columns are added via ALTER TABLE and backfilled (sync_id UUIDs, last_modified now, defaults)
3. Legacy friends.emoji NOT-NULL column is removed by recreating the table; CRUD proceeds against the upgraded schema

## ⚙ Configurations

- Receipt scan: scanFeatureEnabled gates the toolbar scan button; maxReceiptPhotos=3; minimumLoaderSeconds=5.0; ImagePreprocessing receiptMaxDimension=2560, bandMaxDimension=2200, upscaledBandUploadDimension=3600, tallReceiptAspectThreshold=2.4, band overlapFraction=0.16, upscale retry 1.6×; CloudReceiptParser JPEG quality curve (0.9/≤4MB, 0.75/≤4.5MB, 0.55) + 30s timeout; ReceiptOCRService recognitionLevel .accurate, languages [en, sr-Latn, de, fr, es, it, pt, pl, ru], minimumConfidence 0.3; ReceiptColumnDetector verticalPairingThreshold 0.06; parser tolerances totals max(1%,0.50), cascade/review mismatch 0.05, prune guard 3×grandTotal; cloud category hint = reserved set only; ParseTelemetry cap 200 events / 30-day window.
- Keypad: maxDecimalDigits=2; 8-digit integer cap on keypad and paste/import; WhoPaid numpad maxIntDigits=8, maxDecDigits=2, balance tolerance 0.01×max(count,1).
- Split/Debt: debt/zero epsilon 0.005; payer/share detection 0.001; phantom-merge requires exactly one unambiguous candidate; DebtBadge/avatar stack maxVisible=3 (50% overlap, '+N'); byItems availability gated on a scanned receipt with >1 product line; lastUsedSplitMode key (never byAmount); default per-friend split-mode picker hidden; WhoPaysPicker drum-roll fully commented out.
- Trend/balance chart: trendBarsCount = AppSizes.trendBarsCount (44 bars); OccurrenceTimeline future page size 30.
- Insights gates: includePotentialExpenses default ON (iCloud key insights.includePotentialExpenses); extremesMinTotalActiveDays=14, extremesMinCategories=2, extremesZThreshold=2.0, extremesMinTransactionsPerCategory=5, extremesMinPriorMonthsPerCategory=3; savingsMinActiveDays=14, savingsMinTotalTransactions=10, savingsMinPurchasesPerCategoryPerMonth=4, savingsMinQualifyingMonths=2, savingsMinCategories=2, savingsThresholdMeanFactor=0.4; trendMinMonths=2, trendMinPercentToShow=1.0; cannibalizationMinTotalMonths=2, candidateMonths=6, minSamplesPerCategory=3, zThreshold=2.0, substitutionTolerance=0.30; CategoryTopCard.collapsedLimit=3; SpendingCalendarCard.totalCellsInMonthGrid=42; heatmap saturation/brightness (dark 0.62/0.72, light 0.55/0.88); PeriodPickerSheet recentMonths=24; day-detail detent .height(220); CustomRangeSheet .medium.
- Categories: chartMonthsToShow=6, minListMonthsToShow=7, maxCategoryTitleLength=32, monthlyHistory skipCurrentMonth (chart true/list false), 31-emoji suggestion pool, 18 seed defaults, EmojiTile size presets; 'Show all categories' threshold 5.
- Currency: Frankfurter base URL https://api.frankfurter.dev/v2, /rates?base=USD; rate cache TTL once per calendar day; compact-display threshold |amount|≥100,000; grouping separator space; multiplier precision cutoff ≥10 → 0 decimals; percent floor '<1%'; fallback emoji '💱'; UserDefaults keys selectedCurrency/usdRates/ratesCacheDate; ~165-entry catalog; 10-entry seed rate map.
- Filter/search: filter debounce 100ms; search no-results analytics debounce 600ms with min query length 3.
- Reminders/notifications: authorization [.alert,.sound,.badge]; foreground presentation [.banner,.sound,.badge]; spawn timer 60s + scene-active + mutation hooks; SpawnTracker UserDefaults key recurring.spawnAcks; notification id scheme 'tx-<syncID>-<suffix>'; userInfo key transactionSyncID; nextOccurrence horizons weekly 8d / monthly 3mo / yearly 2y.
- Sharing & sync: SharedTransactionLink defaultURLStyle .webBackend (.universalLink dormant), currentSchemaVersion 1, payload key 'p', webBackendPath '/share', custom scheme 'nonbank' host 'share'; ShareItemsCrypto hkdfSalt 'non-bank-share-items-v1', info 'items', AES-256, ~10KB cap; CloudKit zoneName 'NonBankZone', batch 400, record types Transaction/Category/Friend/ReceiptItem, subscription id 'non-bank-private-changes'; idempotency keys ck_zoneCreated/ck_subscriptionCreated/ck_serverChangeToken/iCloudLastSyncedAt/ck_pendingDelete*; SyncManager.isCloudKitEnabled (true) + iCloudSyncEnabled (default false); NonBankExport currentSchemaVersion 1.
- Import/Export: ExportFormat JSON/CSV/Excel (only JSON roundTripsFully); accepted UTTypes .json + csv + xlsx single-selection; auto-detect sample 10 with >50%, available-field >30%, amount-candidate gate >30%, ambiguous-date scan 20; ImportMode Add vs Replace-all; DateFormatHint DD/MM (default) vs MM/DD; MinimalZip STORE-only write, no ZIP64/encryption/multi-volume, ~2GB cap, EOCD window last 65557 bytes; JSON export prettyPrinted+sortedKeys+iso8601.
- Backend/config: BackendConfig.host compile-time (staging.non-bank.app DEBUG, non-bank.app Release) no runtime toggle; acceptedHosts incl. legacy workers.dev; AISettings.resolvedBackendURL hard-coded to BackendConfig.baseURL (old toggle/custom-URL UI removed, telemetry hooks no-ops); AppAttest UserDefaults keys appattest.keyId/attested, endpoints v1/attest/challenge & verify, entitlement environment=development.
- User/monetization: ProfileNameSheet nameMaxLength 35; onboarding integer cap 8 / 2 decimals; TipTier productIDs com.nonbank.tip.* (must match .storekit); support address nonbankapp@gmail.com; Universal-Link host/path dormant pending paid Apple Dev + associated-domains; Keychain service/account com.nonbank.user-id / app_user_id, cloud key app_user_id.
- Analytics/infra: AnalyticsConsentService.isEnabled default ON (keys analytics.consent.isEnabled/hasUserSet); AnalyticsAvailability.isFirebaseLinked compile-time; NoOp console logging DEBUG-only; -D ANALYTICS_DISABLED flag; RageTapState windowMs 800/threshold 3; ScreenTracker quick-bounce <1000ms; AppMotion fast 0.15/normal 0.22/slow 0.35s; AppSpacing 4-pt scale; AppSizes (FAB 64, 44 trend bars); RootView splash floor 1.5s.
- Entitlements & Info.plist: iCloud/CloudKit container iCloud.$(PRODUCT_BUNDLE_IDENTIFIER), ubiquity KV store, App Attest environment=development; ITSAppUsesNonExemptEncryption=false; CFBundleDisplayName 'Non Bank'; UIBackgroundModes remote-notification; CFBundleURLSchemes nonbank; Camera/PhotoLibrary/Documents usage descriptions; PrivacyInfo.xcprivacy + GoogleService-Info.plist present.

## 🧩 Integrations

- **SQLite3 (SQLiteService via DatabaseProtocol)** — On-device relational persistence (app-data.sqlite) of transactions, categories, friends, and receipt_items; JSON-encoded complex columns; additive ALTER-TABLE migrations; serial-queue async CRUD.
- **UserDefaults (UserDefaultsService / KeyValueStoreProtocol / NSUbiquitousKeyValueStore)** — Key-value persistence for preferences and lightweight state: selected currency, rate cache, consent flags, install clock, activation/first-use flags, App Attest keyId, recurring spawn acks, onboarding flag, display name, CloudKit idempotency markers; iCloud KVS for user ID + includePotentialExpenses with external-change observation.
- **Apple Keychain (Security framework)** — Device-bound persistence of the user ID (AfterFirstUnlockThisDeviceOnly) that survives app deletion; offline cache for the iCloud-bound ID.
- **CloudKit (CKContainer private DB via SyncManager / CloudKitService)** — Cross-device sync of transactions/categories/friends/receipt items as CKRecords in a custom zone with last-modified-wins merge and change-token delta sync; foreground-driven; receipt items reconciled/cascade-deleted.
- **UserNotifications (NotificationService / NotificationCoordinator)** — Schedule/cancel UNCalendarNotificationTrigger local reminders (one-off + per-pattern recurring fan-out), deliver foreground banners, route taps back to the matching transaction, and run one-shot stale cleanup at launch.
- **Frankfurter Currency API (api.frankfurter.dev/v2 over URLSession/NetworkClient)** — Source of latest USD-base FX rates; anonymous public endpoint GET /rates?base=USD decoded into the USD-relative rate table (validated 200–299, else NetworkError).
- **Cloudflare Worker backend (BackendConfig host)** — Edge backend serving /v1/parse-receipt (AI receipt parsing, routing 4 vision-LLM providers + pool stats), /v1/attest/challenge & /verify (App Attest), /v1/share-items/{checksum} (encrypted-items store), and /share (share-link HTML/OpenGraph preview deep-linking nonbank://).
- **Vision-LLM providers (Gemini, Groq, Cloudflare Workers AI, OpenRouter)** — Actual receipt OCR+structuring behind the Worker; provider chosen by the router with exclude_provider support for second-opinion retries.
- **Apple Vision (VNRecognizeTextRequest) + Core Image + Natural Language** — On-device OCR fallback (text lines + bounding boxes), CIColorControls/CIUnsharpMask image sharpening for tiled bands, and NLLanguageRecognizer dominant-language/currency inference.
- **VisionKit / UIImagePickerController (camera) + PhotosUI PhotosPicker** — Receipt capture: plain camera (no document detection) and up to 3 library photos/screenshots feeding the parse flow.
- **App Attest (DeviceCheck DCAppAttestService) + CryptoKit** — Cryptographically prove a genuine app instance to the AI endpoint (Secure-Enclave key, per-request assertion); CryptoKit provides SHA-256, HKDF-SHA256 key derivation, and AES-256-GCM for the share-items channel.
- **StoreKit 2 (TipJarService)** — Donation-only consumable tip IAPs: products fetch, purchase, verification (.verified/.unverified), transaction.finish(), localized displayPrice; no entitlement stored, no restore path.
- **Firebase Analytics** — Anonymous, bucketed, PII-free event + user-property analytics via FirebaseAnalyticsService gated behind canImport(FirebaseAnalytics) with a NoOp fallback and a consent master switch; 'Data Not Linked to You'.
- **MessageUI (MFMailComposeViewController)** — In-app mail compose for feature/bug/support emails with device/version footer; mailto: fallback when no mail account is configured.
- **UIActivityViewController (system share sheet) + custom URL scheme / Universal Links** — Outbound sharing of transaction share links / export files (TransactionShareItemSource provides per-destination URL vs summary+URL/UTIs); inbound deep-link delivery of nonbank://share via onOpenURL (https Universal Links wired but dormant).
- **Apple Compression framework + Foundation XMLParser / JSON / Calendar / DateFormatter / Locale** — Inflate DEFLATE entries inside Excel .xlsx ZIPs; SAX-parse worksheet/sharedStrings XML; parse/encode generic JSON and the NonBankExport envelope; all date/recurrence math, localized labels, and first-launch currency detection.
- **UIKit haptics / UIPasteboard / UIDevice / UIApplication** — Keypad/save/conflict haptics, copy of amount/user ID/email, device info in the mail footer, and opening mailto: URLs.
- **SwiftUI Charts** — Renders the per-category monthly bar chart (CategoryHistoryView) with a dashed average RuleMark.

## Scope after MVP

- Tagging: Transaction.tags is modeled and persisted but always written nil — decide whether tagging ships or the schema is removed.
- Debt settlement tracking: FriendShare.isSettled exists but is never set true and is not synced/shared; settle-up currently creates an offsetting transaction rather than marking prior shares settled.
- Default per-friend split-mode picker: built but hidden in FriendFormView (value preserved on edit) — decide whether to ship it.
- Universal Links: fully coded but dormant, blocked on a paid Apple Developer Program + associated-domains entitlement.
- Real-time CloudKit sync: the CKDatabaseSubscription is created best-effort but no remote-notification handler consumes it — sync is foreground-only today.
- Explicit 'merge contacts' UX: phantom-upgrade intentionally does not merge when a real-ID friend already exists, so duplicate contacts can result.
- Legacy/dead code to retire: ImportExportSheets (Russian-language stub superseded by Import/Export views), WhoPaysPicker drum-roll (commented out), ReceiptParserService (Apple Foundation Models on-device LLM) + ReceiptGeometryService + the debug manual highlighter flow (ReceiptHighlighterView/DebugReceiptScannerView/ReceiptImageEditorView), and the empty AISettingsView (removed AI-settings screen).
- Currency minor units: no zero-decimal (JPY/KRW) or 3-decimal (KWD) handling — modeling true minor units is deferred.
- Dynamic Type / accessibility scaling: typography is intentionally fixed-pt for now.
- AI quota/error UX: pool/quota telemetry hooks are no-ops and there is no user-facing rate-limit error UI (cloud failures silently fall back to local OCR).
- Duplicate-import detection: import has no syncID-based upsert for transactions, so re-importing in Add mode duplicates rows.
- Tip jar restore: no 'Restore purchases' (consumables grant nothing — by design, pending App Review confirmation).
- App Attest production environment: entitlement is 'development' and must flip to 'production' for release.

## Open questions / decisions for the spec author

- excludedFromInsights must be manually carried forward on every transaction rebuild path (edit, recurring-replace, category rename, phantom-upgrade) — a fragile invariant worth a maintenance guardrail or a single rebuild helper.
- Income+split is 'unusual but legal': opening an existing split in income mode and saving drops the split data — confirm this is intended.
- byItems share math has acknowledged floating-point residual; the create flow gives the crumb to the last row in some paths but ShareDistributionView/SplitBreakdown read stored shares directly — decide whether exact-balance to total is required.
- Two distinct 'self' sentinels coexist ('me' for Payer/WhoPaid vs '__me__'/ReceiptItem.selfParticipantID for byItems) — a known non-refactored inconsistency.
- Category uniqueness is inconsistent: title is case-insensitive at the app level but the SQLite UNIQUE constraint is case-sensitive (no COLLATE NOCASE); monthlyHistory matches category case-SENSITIVELY while dedup is case-insensitive — casing drift could split a category or diverge DB-vs-app uniqueness.
- Deleting a category does not reassign its transactions to General (orphans keep the old title/fallback emoji); confirm intended.
- isReserved is title-based and case-insensitive, so a category renamed via direct DB/CloudKit sync would lose reserved protection.
- Re-seeding behavior on partial-default DBs (some defaults deleted/renamed) may re-seed unexpectedly — confirm.
- Some analytics signals are hardcoded/inaccurate: categoryDeleted(hadTransactions) always false, categoryEdited affectedTxCountBucket always 0, friendDeleted hadSplits always false; trackError/tipPurchase error codes hash locale-dependent messages.
- Currency conversion silently passes through the input amount when a rate is missing/zero (e.g. an un-fetched currency shows raw magnitude as if converted) — define the desired fallback (passthrough vs '—' vs block); usdRates is cached/merged and never pruned, so stale seed defaults can persist with no user-visible staleness indicator.
- currencyOptions ranking is fed homeTransactions (past only) while CurrencyDropdownButton ranks over transactionStore.transactions (past + reminders) — two 'used currencies' sources; confirm the divergence.
- DebtSummary group filter excludes mixed-group transactions entirely — confirm vs partial inclusion; and copy says 'You borrow' (present tense) vs 'You owe' — confirm wording across DebtRowView/DebtBadge/header.
- Deleted-friend transactions can still reference a missing Friend id (legacy data) rendering a 'Contact unavailable' placeholder — confirm handling.
- Should 'Reminder' be modeled as its own FD entity/page or documented as Transaction role-states (it is a filtered view over Transaction, not a separate table)?
- Monthly recurrence for a day-of-month that never occurs within the 3-month horizon (e.g. only day 31) yields nil nextOccurrence — confirm/specify the edge behavior.
- Trends/extremes/averages/cannibalization ignore the user-picked period and always use full history while Top cards + calendar Month mode honor it — confirm this is acceptable product behavior (deliberate in code but may surprise users who picked a narrow range).
- DatabaseProtocol is narrower than the concrete SQLiteService surface (several syncID/byID lookups callers rely on are not in the protocol) — decide whether to document the protocol or the concrete class; SQLiteService binds isIncome on write but reconstructs income/expense from `type` on read.
- Multi-image export totalAmount is a naive sum of per-image totals with confidence/totalsMatch forced pessimistic — confirm intended.
- XLSXCodec.decode reads only the first worksheet (doesn't follow the workbook rels chain) so multi-sheet files where data isn't sheet1 import the wrong sheet; SheetParserDelegate's empty-cell padding loop has a suspect no-op expression worth a correctness review; CSV/XLSX type-column round-trip only covers English synonyms (non-English type columns won't parse); parseEmoji rejects multi-scalar emoji (flags/ZWJ/skin-tone).
- Replace-mode import wipes all transactions but does not delete orphaned receipt items belonging to deleted transactions — verify cleanup.
- The exact Worker contracts (parse-receipt prompt + sanitizeDiscountSemantics + provider routing, share-items request/response JSON + TTL/expiry, 10KB cap enforcement) live server-side, out of this repo — should be specced separately and referenced.
- UserID/Friend ID generation has no collision check (relies on adjective×noun×base32^4 probability) — document acceptable collision risk or add server-side uniqueness if IDs become matching keys at scale.
- Onboarding 'Initial balance' transaction is created in the Uncategorized ('General') category with id:0 — confirm the intended category.
- Two share-sheet wrappers may coexist (ShareActivityView vs a 'ShareSheet' wrapper used by ShareSplitPromptSheet) — confirm which is canonical; lentAmount is recomputed on the receiver as paid−share rather than transported — verify rounding parity.
- BalanceTrendBar is the generic Home balance sparkline, not wired into any Insights card — confirm it belongs to the Home/Balance subsystem rather than Insights.
- Smaller deferred-decision flags: HomeViewModel keeps an unused legacy synchronous filter path alongside the cached async pipeline; the brief frame-zero window where analytics is constructed enabled:true before consent reconciliation; ColorContext historical split-accentBold bug (now fixed) — confirm no residual callers.
