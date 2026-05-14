import Foundation

/// Single source of truth for every analytics event the app emits.
/// Mirrors `docs/analytics-events.md` one-to-one — any change here
/// should be reflected in the markdown taxonomy and vice versa.
///
/// Design rules baked into the enum:
///   - Event names are `snake_case`, max 40 chars (Firebase limit).
///   - Param values are either short string enums (`mode: "evenly"`)
///     or pre-bucketed strings (`amount_bucket: "100-500"`). No raw
///     amounts, no PII, no free-form titles.
///   - Each `case` is a complete event description — the call-site
///     passes typed args, the enum maps them to the wire format. This
///     keeps the taxonomy in code review rather than spread across
///     50 untyped `track("foo", ["bar": baz])` calls.
enum AnalyticsEvent {

    // MARK: - Onboarding

    /// User reached the onboarding flow on first launch.
    case onboardingStarted
    /// Per-step funnel marker. `step` is the 0-based index of the
    /// currently visible step (0=intro/track, 1=split, 2=insights,
    /// 3=initial-balance setup).
    case onboardingStepViewed(step: Int)
    /// User tapped "Skip" on any step before completing.
    case onboardingSkipped(atStep: Int)
    /// User tapped "Get started" on the final step. `setInitialBalance`
    /// is `true` if they typed a non-zero starting amount. `seconds`
    /// is bucketed (`<10`, `10-30`, `30-60`, `1m-3m`, `3m+`).
    case onboardingCompleted(setInitialBalance: Bool, secondsBucket: String)

    // MARK: - Activation (first useful action per install)

    case activationFirstTransaction(timeSinceInstallMinutesBucket: String)
    case activationFirstSplit(timeSinceInstallMinutesBucket: String)
    case activationFirstFriendAdded(source: FriendCreationSource)
    case activationFirstReceiptScanned(timeSinceInstallMinutesBucket: String, outcome: ReceiptScanOutcome)
    case activationFirstShareLinkSent

    // MARK: - Transactions

    /// Fired once per save (insert) in the create modal. `source`
    /// tells us *where* the create kicked off: manual amount entry,
    /// scan-derived, share-link receive, or settle-up shortcut.
    case transactionCreated(
        type: TransactionTypeLabel,
        hasSplit: Bool,
        hasReceiptItems: Bool,
        isRecurring: Bool,
        currency: String,
        amountBucket: String,
        category: String,
        source: TransactionCreationSource,
        hasDescription: Bool
    )
    case transactionEdited(fieldChanged: TransactionEditField)
    case transactionDeleted(hadSplit: Bool, hadReceiptItems: Bool, ageDaysBucket: String)
    case transactionExcludedFromInsights
    case transactionIncludedInInsights

    // MARK: - Split

    case splitModeSelected(mode: SplitModeLabel, numFriends: Int)
    case splitCompleted(
        mode: SplitModeLabel,
        numFriends: Int,
        hasReceipt: Bool,
        totalAmountBucket: String,
        currency: String
    )
    case splitSharePromptShown
    case splitSharePromptAction(action: SharePromptAction)
    case settleUpInitiated(source: SettleUpSource)
    case settleUpCompleted

    // MARK: - Receipt scan

    case receiptScanStarted(source: ReceiptScanSource, numPhotos: Int)
    case receiptScanSucceeded(
        itemsCountBucket: String,
        confidence: ScanConfidence,
        parser: ScanParser,
        durationSecondsBucket: String,
        discountCount: Int,
        feeCount: Int,
        taxCount: Int
    )
    case receiptScanFailed(errorType: ScanErrorType, source: ReceiptScanSource)
    case receiptItemsEditedInReview(itemsAdded: Int, itemsDeleted: Int, itemsModified: Int, totalChanged: Bool)

    // MARK: - Share-link

    case shareLinkSent(source: ShareLinkSource, shareType: ShareLinkType)
    case shareLinkOpened(outcome: ShareLinkOpenOutcome)
    case shareLinkImported(hadPicker: Bool, numParticipantsBucket: String, isUpdate: Bool)
    case shareLinkUpdateDismissed

    // MARK: - iCloud sync

    case iCloudSyncEnabled
    case iCloudSyncDisabled
    case iCloudInitialSyncCompleted(durationSecondsBucket: String, txCountBucket: String, hadConflicts: Bool)

    // MARK: - Categories

    case categoryCreated
    case categoryEdited(titleChanged: Bool, emojiChanged: Bool, affectedTxCountBucket: String)
    case categoryDeleted(hadTransactions: Bool)

    // MARK: - Friends

    case friendCreated(source: FriendCreationSource)
    case friendEdited
    case friendDeleted(hadSplits: Bool)
    case friendDetailViewed(balanceState: FriendBalanceState, txCountBucket: String)

    // MARK: - Import / Export

    case exportStarted(format: ExportFormatLabel, txCountBucket: String, dateRangeDaysBucket: String)
    case exportCompleted(format: ExportFormatLabel, txCountBucket: String)
    case importFileSelected(format: ImportFormatLabel, txCountBucket: String, isNativeEnvelope: Bool)
    case importCompleted(
        format: ImportFormatLabel,
        mode: AnalyticsImportMode,
        txCountBucket: String,
        isNativeEnvelope: Bool,
        newCategoriesCreated: Int,
        newFriendsAdded: Int,
        receiptItemsImported: Int
    )
    case importFailed(format: ImportFormatLabel, errorType: ImportErrorType)

    // MARK: - Insights

    case insightsViewed(tab: InsightsTab)
    case insightsFilterChanged(filterType: InsightsFilterType, value: String)
    case insightsCardTapped(cardType: InsightsCardType)
    case homeQuickFilterTapped(category: String)

    // MARK: - Tips / IAP

    case tipJarViewed(source: TipJarSource)
    case tipPurchaseStarted(tier: TipTier)
    case tipPurchaseSucceeded(tier: TipTier, priceBucket: String)
    case tipPurchaseFailed(tier: TipTier, errorCode: String)
    case tipPurchaseCancelled(tier: TipTier)

    // MARK: - Help / settings

    case helpMailComposeOpened(kind: SupportKind)
    case licensesViewed
    case settingsViewed

    // MARK: - Screen views (manual SwiftUI tracking)

    case screenView(screenName: String)
}

// MARK: - String mapping

extension AnalyticsEvent {

    /// Firebase event name. Keep under 40 chars, `snake_case`,
    /// alphanumeric + underscores only.
    var name: String {
        switch self {
        case .onboardingStarted: return "onboarding_started"
        case .onboardingStepViewed: return "onboarding_step_viewed"
        case .onboardingSkipped: return "onboarding_skipped"
        case .onboardingCompleted: return "onboarding_completed"

        case .activationFirstTransaction: return "activation_first_transaction"
        case .activationFirstSplit: return "activation_first_split"
        case .activationFirstFriendAdded: return "activation_first_friend_added"
        case .activationFirstReceiptScanned: return "activation_first_receipt_scanned"
        case .activationFirstShareLinkSent: return "activation_first_share_link_sent"

        case .transactionCreated: return "transaction_created"
        case .transactionEdited: return "transaction_edited"
        case .transactionDeleted: return "transaction_deleted"
        case .transactionExcludedFromInsights: return "transaction_excluded_from_insights"
        case .transactionIncludedInInsights: return "transaction_included_in_insights"

        case .splitModeSelected: return "split_mode_selected"
        case .splitCompleted: return "split_completed"
        case .splitSharePromptShown: return "split_share_prompt_shown"
        case .splitSharePromptAction: return "split_share_prompt_action"
        case .settleUpInitiated: return "settle_up_initiated"
        case .settleUpCompleted: return "settle_up_completed"

        case .receiptScanStarted: return "receipt_scan_started"
        case .receiptScanSucceeded: return "receipt_scan_succeeded"
        case .receiptScanFailed: return "receipt_scan_failed"
        case .receiptItemsEditedInReview: return "receipt_items_edited_in_review"

        case .shareLinkSent: return "share_link_sent"
        case .shareLinkOpened: return "share_link_opened"
        case .shareLinkImported: return "share_link_imported"
        case .shareLinkUpdateDismissed: return "share_link_update_dismissed"

        case .iCloudSyncEnabled: return "icloud_sync_enabled"
        case .iCloudSyncDisabled: return "icloud_sync_disabled"
        case .iCloudInitialSyncCompleted: return "icloud_initial_sync_completed"

        case .categoryCreated: return "category_created"
        case .categoryEdited: return "category_edited"
        case .categoryDeleted: return "category_deleted"

        case .friendCreated: return "friend_created"
        case .friendEdited: return "friend_edited"
        case .friendDeleted: return "friend_deleted"
        case .friendDetailViewed: return "friend_detail_viewed"

        case .exportStarted: return "export_started"
        case .exportCompleted: return "export_completed"
        case .importFileSelected: return "import_file_selected"
        case .importCompleted: return "import_completed"
        case .importFailed: return "import_failed"

        case .insightsViewed: return "insights_viewed"
        case .insightsFilterChanged: return "insights_filter_changed"
        case .insightsCardTapped: return "insights_card_tapped"
        case .homeQuickFilterTapped: return "home_quick_filter_tapped"

        case .tipJarViewed: return "tip_jar_viewed"
        case .tipPurchaseStarted: return "tip_purchase_started"
        case .tipPurchaseSucceeded: return "tip_purchase_succeeded"
        case .tipPurchaseFailed: return "tip_purchase_failed"
        case .tipPurchaseCancelled: return "tip_purchase_cancelled"

        case .helpMailComposeOpened: return "help_mail_compose_opened"
        case .licensesViewed: return "licenses_viewed"
        case .settingsViewed: return "settings_viewed"

        case .screenView: return "screen_view"
        }
    }

    /// Flat string params dict the backend expects. We stringify
    /// everything so the wire format stays consistent across backends
    /// (Firebase auto-converts strings, PostHog accepts any).
    var parameters: [String: String] {
        switch self {
        case .onboardingStarted: return [:]
        case .onboardingStepViewed(let step): return ["step_index": String(step)]
        case .onboardingSkipped(let step): return ["step_index": String(step)]
        case let .onboardingCompleted(setInitialBalance, secondsBucket):
            return [
                "initial_balance_set": String(setInitialBalance),
                "seconds_bucket": secondsBucket
            ]

        case .activationFirstTransaction(let bucket):
            return ["time_since_install_minutes_bucket": bucket]
        case .activationFirstSplit(let bucket):
            return ["time_since_install_minutes_bucket": bucket]
        case .activationFirstFriendAdded(let source):
            return ["source": source.rawValue]
        case let .activationFirstReceiptScanned(bucket, outcome):
            return [
                "time_since_install_minutes_bucket": bucket,
                "outcome": outcome.rawValue
            ]
        case .activationFirstShareLinkSent: return [:]

        case let .transactionCreated(type, hasSplit, hasItems, isRecurring, currency, amountBucket, category, source, hasDescription):
            return [
                "type": type.rawValue,
                "has_split": String(hasSplit),
                "has_receipt_items": String(hasItems),
                "is_recurring": String(isRecurring),
                "currency": currency,
                "amount_bucket": amountBucket,
                "category": category,
                "source": source.rawValue,
                "has_description": String(hasDescription)
            ]
        case .transactionEdited(let field):
            return ["field_changed": field.rawValue]
        case let .transactionDeleted(hadSplit, hadItems, ageBucket):
            return [
                "had_split": String(hadSplit),
                "had_receipt_items": String(hadItems),
                "age_days_bucket": ageBucket
            ]
        case .transactionExcludedFromInsights: return [:]
        case .transactionIncludedInInsights: return [:]

        case let .splitModeSelected(mode, num):
            return ["mode": mode.rawValue, "num_friends": String(num)]
        case let .splitCompleted(mode, num, hasReceipt, totalBucket, currency):
            return [
                "mode": mode.rawValue,
                "num_friends": String(num),
                "has_receipt": String(hasReceipt),
                "total_amount_bucket": totalBucket,
                "currency": currency
            ]
        case .splitSharePromptShown: return [:]
        case .splitSharePromptAction(let action):
            return ["action": action.rawValue]
        case .settleUpInitiated(let source):
            return ["source": source.rawValue]
        case .settleUpCompleted: return [:]

        case let .receiptScanStarted(source, num):
            return ["source": source.rawValue, "num_photos": String(num)]
        case let .receiptScanSucceeded(itemsBucket, confidence, parser, durationBucket, discounts, fees, taxes):
            return [
                "items_count_bucket": itemsBucket,
                "confidence": confidence.rawValue,
                "parser": parser.rawValue,
                "duration_seconds_bucket": durationBucket,
                "discount_count": String(discounts),
                "fee_count": String(fees),
                "tax_count": String(taxes)
            ]
        case let .receiptScanFailed(errorType, source):
            return ["error_type": errorType.rawValue, "source": source.rawValue]
        case let .receiptItemsEditedInReview(added, deleted, modified, totalChanged):
            return [
                "items_added": String(added),
                "items_deleted": String(deleted),
                "items_modified": String(modified),
                "total_changed": String(totalChanged)
            ]

        case let .shareLinkSent(source, type):
            return ["source": source.rawValue, "share_type": type.rawValue]
        case .shareLinkOpened(let outcome):
            return ["outcome": outcome.rawValue]
        case let .shareLinkImported(hadPicker, partBucket, isUpdate):
            return [
                "had_picker": String(hadPicker),
                "num_participants_bucket": partBucket,
                "is_update": String(isUpdate)
            ]
        case .shareLinkUpdateDismissed: return [:]

        case .iCloudSyncEnabled: return [:]
        case .iCloudSyncDisabled: return [:]
        case let .iCloudInitialSyncCompleted(durationBucket, txBucket, conflicts):
            return [
                "duration_seconds_bucket": durationBucket,
                "tx_count_bucket": txBucket,
                "had_conflicts": String(conflicts)
            ]

        case .categoryCreated: return [:]
        case let .categoryEdited(titleChanged, emojiChanged, affectedBucket):
            return [
                "title_changed": String(titleChanged),
                "emoji_changed": String(emojiChanged),
                "affected_tx_count_bucket": affectedBucket
            ]
        case .categoryDeleted(let hadTx):
            return ["had_transactions": String(hadTx)]

        case .friendCreated(let source):
            return ["source": source.rawValue]
        case .friendEdited: return [:]
        case .friendDeleted(let hadSplits):
            return ["had_splits": String(hadSplits)]
        case let .friendDetailViewed(balance, txBucket):
            return ["balance_state": balance.rawValue, "tx_count_bucket": txBucket]

        case let .exportStarted(format, txBucket, dateBucket):
            return [
                "format": format.rawValue,
                "tx_count_bucket": txBucket,
                "date_range_days_bucket": dateBucket
            ]
        case .exportCompleted(let format, let txBucket):
            return ["format": format.rawValue, "tx_count_bucket": txBucket]
        case let .importFileSelected(format, txBucket, isNative):
            return [
                "format": format.rawValue,
                "tx_count_bucket": txBucket,
                "is_native_envelope": String(isNative)
            ]
        case let .importCompleted(format, mode, txBucket, isNative, newCats, newFriends, receiptItems):
            return [
                "format": format.rawValue,
                "mode": mode.rawValue,
                "tx_count_bucket": txBucket,
                "is_native_envelope": String(isNative),
                "new_categories_created": String(newCats),
                "new_friends_added": String(newFriends),
                "receipt_items_imported": String(receiptItems)
            ]
        case .importFailed(let format, let errorType):
            return ["format": format.rawValue, "error_type": errorType.rawValue]

        case .insightsViewed(let tab):
            return ["tab": tab.rawValue]
        case .insightsFilterChanged(let filterType, let value):
            return ["filter_type": filterType.rawValue, "value": value]
        case .insightsCardTapped(let card):
            return ["card_type": card.rawValue]
        case .homeQuickFilterTapped(let category):
            return ["category": category]

        case .tipJarViewed(let source):
            return ["source": source.rawValue]
        case .tipPurchaseStarted(let tier):
            return ["tier": tier.rawValue]
        case .tipPurchaseSucceeded(let tier, let priceBucket):
            return ["tier": tier.rawValue, "price_bucket": priceBucket]
        case .tipPurchaseFailed(let tier, let code):
            return ["tier": tier.rawValue, "error_code": code]
        case .tipPurchaseCancelled(let tier):
            return ["tier": tier.rawValue]

        case .helpMailComposeOpened(let kind):
            return ["kind": kind.rawValue]
        case .licensesViewed: return [:]
        case .settingsViewed: return [:]

        case .screenView(let name):
            return ["screen_name": name]
        }
    }
}

// MARK: - Enums for param values
//
// All event params that are not raw numbers / strings live as enums so
// the taxonomy stays in code review rather than spreading typo-prone
// stringly-typed literals across call-sites.

enum TransactionTypeLabel: String { case income, expense }
enum TransactionCreationSource: String {
    case manual, scan, shareLink = "share_link", settleUp = "settle_up"
}
enum TransactionEditField: String {
    case amount, title, category, date, splitInfo = "split", other
}
enum SplitModeLabel: String {
    case evenly, byItems = "by_items", byAmount = "by_amount", settleUp = "settle_up"
}
enum SharePromptAction: String { case shared, dismissed }
enum SettleUpSource: String { case friendDetail = "friend_detail", manual }
enum ReceiptScanSource: String { case camera, gallery }
enum ReceiptScanOutcome: String { case success, fail }
enum ScanConfidence: String { case high, medium, low }
enum ScanParser: String { case cloud, ocrFallback = "ocr_fallback" }
enum ScanErrorType: String {
    case network, noItems = "no_items", parseError = "parse_error", timeout
}
enum ShareLinkSource: String { case detail, postSplitPrompt = "post_split_prompt" }
enum ShareLinkType: String { case split, singleTx = "single_tx" }
enum ShareLinkOpenOutcome: String {
    case autoCreate = "auto_create"
    case pickerShown = "picker_shown"
    case identical
    case updatePrompt = "update_prompt"
    case malformed
}
enum FriendCreationSource: String { case manual, shareLink = "share_link" }
enum FriendBalanceState: String { case lent, owe, balanced }
enum ExportFormatLabel: String { case json, csv, xlsx }
enum ImportFormatLabel: String { case json, csv, xlsx }
/// Analytics-only echo of the UI's `ImportMode` enum. Kept separate
/// so this taxonomy file doesn't have to import the view layer, and
/// so a UI rename can't silently break dashboards.
enum AnalyticsImportMode: String { case add, replace }
enum ImportErrorType: String {
    case unreadable, malformed, noAmountColumn = "no_amount_column", parse, other
}
enum InsightsTab: String { case overview, categories, trends }
enum InsightsFilterType: String { case dateRange = "date_range", category, type }
enum InsightsCardType: String {
    case bigPurchase = "big_purchase"
    case categoryHistory = "category_history"
    case cannibalisation
    case topCategories = "top_categories"
    case monthlyTrend = "monthly_trend"
}
enum TipJarSource: String { case settings, onboarding, postSplit = "post_split" }
enum TipTier: String { case coffee, croissant, pizza, chefstable }
enum SupportKind: String { case feature, bug, support }

// MARK: - User properties

/// Long-lived user-level properties. Each enum case is a single key
/// (`UserProperty.name`) plus its possible string values — never
/// numerical, never PII. Updated at app start and when the underlying
/// state changes.
enum AnalyticsUserProperty {
    case txCountBucket(String)
    case splitCountBucket(String)
    case friendCountBucket(String)
    case defaultCurrency(String)
    case hasICloudSync(Bool)
    case hasCompletedOnboarding(Bool)
    case hasMadeTip(Bool)
    case daysSinceInstallBucket(String)

    var name: String {
        switch self {
        case .txCountBucket: return "tx_count_bucket"
        case .splitCountBucket: return "split_count_bucket"
        case .friendCountBucket: return "friend_count_bucket"
        case .defaultCurrency: return "default_currency"
        case .hasICloudSync: return "has_icloud_sync"
        case .hasCompletedOnboarding: return "has_completed_onboarding"
        case .hasMadeTip: return "has_made_tip"
        case .daysSinceInstallBucket: return "days_since_install_bucket"
        }
    }

    var stringValue: String {
        switch self {
        case .txCountBucket(let v), .splitCountBucket(let v),
             .friendCountBucket(let v), .defaultCurrency(let v),
             .daysSinceInstallBucket(let v):
            return v
        case .hasICloudSync(let v), .hasCompletedOnboarding(let v), .hasMadeTip(let v):
            return String(v)
        }
    }
}

// MARK: - Bucketing helpers

/// Bucket boundaries chosen so each event reveals product-level signal
/// without letting a single user's exact amount slip through. Tuned for
/// USD-equivalent — long-tail currencies (IDR, VND) naturally land in
/// higher buckets, which the dashboard can normalise to the user's
/// `default_currency` user property.
enum AnalyticsBuckets {

    static func amount(_ value: Double) -> String {
        let v = abs(value)
        switch v {
        case 0..<10:        return "<10"
        case 10..<50:       return "10-50"
        case 50..<200:      return "50-200"
        case 200..<1_000:   return "200-1k"
        case 1_000..<10_000: return "1k-10k"
        default:            return "10k+"
        }
    }

    static func count(_ value: Int) -> String {
        switch value {
        case 0:        return "0"
        case 1...5:    return "1-5"
        case 6...20:   return "6-20"
        case 21...50:  return "21-50"
        case 51...200: return "51-200"
        default:       return "200+"
        }
    }

    static func friendCount(_ value: Int) -> String {
        switch value {
        case 0:       return "0"
        case 1...2:   return "1-2"
        case 3...5:   return "3-5"
        case 6...15:  return "6-15"
        default:      return "15+"
        }
    }

    static func daysSinceInstall(_ days: Int) -> String {
        switch days {
        case 0:       return "0"
        case 1...7:   return "1-7"
        case 8...30:  return "8-30"
        case 31...90: return "31-90"
        default:      return "90+"
        }
    }

    static func minutesSinceInstall(_ minutes: Int) -> String {
        switch minutes {
        case 0...1:     return "<1m"
        case 2...5:     return "1-5m"
        case 6...30:    return "5-30m"
        case 31...120:  return "30m-2h"
        case 121...1440: return "2h-1d"
        default:         return "1d+"
        }
    }

    static func seconds(_ seconds: Double) -> String {
        switch seconds {
        case 0..<1:    return "<1s"
        case 1..<3:    return "1-3s"
        case 3..<10:   return "3-10s"
        case 10..<30:  return "10-30s"
        case 30..<60:  return "30-60s"
        default:       return "60s+"
        }
    }

    static func dateRangeDays(_ days: Int) -> String {
        switch days {
        case 0...7:      return "0-7"
        case 8...30:     return "8-30"
        case 31...90:    return "31-90"
        case 91...365:   return "91-365"
        default:         return "365+"
        }
    }
}
