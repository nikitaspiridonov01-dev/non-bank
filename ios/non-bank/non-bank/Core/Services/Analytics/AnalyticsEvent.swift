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
        hasDescription: Bool,
        /// For scan-derived creates: did the user keep the category the
        /// parser suggested, or override it? `nil` for non-scan sources.
        /// Drives "how accurate is auto-category" analysis.
        wasCategoryAutoMatched: Bool?
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
        taxCount: Int,
        /// Which backend provider actually returned the parse — the
        /// router falls through several. Lets us see real-world hit
        /// distribution and detect when a provider silently degrades.
        provider: ScanProvider,
        /// How many providers the router walked before getting a
        /// successful parse. `1` is the happy path; `4+` is a signal
        /// that the head-of-queue provider is struggling.
        attemptedProvidersCount: Int,
        /// Pre-upload JPEG size bucket — proxy for "how expensive was
        /// this AI call" without measuring tokens directly.
        imageSizeKbBucket: String,
        /// Receipt language detected by the parser (ISO-639-1) or
        /// `"other"` for anything outside our supported list. Drives
        /// localisation prioritisation.
        language: ReceiptLanguage,
        /// Coarse store-category tag derived from the parsed receipt
        /// (groceries / restaurant / services / …). NEVER the raw
        /// store name — keeps the event PII-free.
        storeCategory: StoreCategory
    )
    case receiptScanFailed(errorType: ScanErrorType, source: ReceiptScanSource)
    case receiptItemsEditedInReview(
        itemsAdded: Int,
        itemsDeleted: Int,
        /// Items whose name string was edited. High names-only edit
        /// count means the OCR has trouble with text rather than
        /// numbers (typical for cursive / non-Latin scripts).
        nameEdits: Int,
        /// Items whose line-total amount was edited. Numeric edit
        /// count complements `nameEdits` — high price edits = the
        /// parser misreads digits.
        priceEdits: Int,
        /// Items whose quantity was edited.
        quantityEdits: Int,
        totalChanged: Bool
    )

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
    /// User landed on a screen and bounced off in <1s. Two-frame
    /// dwell = either misnavigation or "I was looking for something
    /// else." Strong signal for IA / discoverability.
    case screenBouncedQuick(screen: String, dwellMs: Int)

    // MARK: - Navigation breadth (modal / sheet / tab)

    case tabSwitched(from: AnalyticsTab, to: AnalyticsTab)
    case sheetOpened(name: String, source: String)
    case sheetDismissed(name: String, action: SheetDismissAction, dwellSecondsBucket: String)

    // MARK: - Feature adoption

    /// Fired the first time a user touches a named feature in their
    /// install lifetime. Persistence is local — gives us "% of users
    /// who ever used X" without scanning the entire event stream.
    case featureFirstUse(feature: AnalyticsFeature)

    // MARK: - Tip-jar funnel (entry beyond `tipJarViewed`)

    /// User opened the tip jar but didn't purchase. Captures dwell +
    /// engagement signals so we can distinguish "saw and bounced" from
    /// "scrolled tiers, considered, dropped." Critical for tips funnel
    /// conversion analysis.
    case tipJarDismissed(
        source: TipJarSource,
        dwellSecondsBucket: String,
        scrolledTiers: Bool,
        tappedTier: TipTier?
    )

    // MARK: - Confusion signals

    /// Same element / button tapped 3+ times within 800ms. Proxy for
    /// "this is unresponsive or unclear." Wrap candidate buttons with
    /// the `RageTapDetector` modifier rather than firing manually.
    case rageTapDetected(element: String, tapCount: Int)

    /// Opened a flow (modal, multi-step picker), dwelled, dismissed
    /// without committing. `atStep` is the step name where the user
    /// bailed; `dwellSecondsBucket` filters out accidental back-out.
    case flowAbandoned(flow: AnalyticsFlow, atStep: String, dwellSecondsBucket: String)

    /// Search returned zero results. Distinguishes "user typed nothing
    /// they're searching for" (short query, no results) from "user
    /// searched something specific and got nothing" (long query, no
    /// results — strong signal for missing feature / poor matching).
    case searchNoResults(searchType: SearchType, queryLengthBucket: String)

    /// Form-level validation rejected user input. `field` is the
    /// machine name of the failing input (`amount`, `email`, …),
    /// `reason` is a short enum. Aggregate frequency = "where does
    /// our validation copy / UX fail to set expectations."
    case formValidationFailed(form: AnalyticsForm, field: String, reason: ValidationFailureReason)

    // MARK: - Errors (generic catchall)

    /// Catchall for errors that don't have a dedicated event yet.
    /// `domain` is the subsystem ("sync", "db", "share_decode", …),
    /// `code` is a short stable identifier (NOT a localised message
    /// — those drift), `recoverable` says whether the user can do
    /// anything about it (offer retry vs. silently log).
    case errorOccurred(
        domain: String,
        code: String,
        recoverable: Bool,
        contextScreen: String?
    )

    /// iCloud merged two divergent records. `kind` distinguishes
    /// what was conflicting (tx / friend / category / other) so we
    /// can prioritise sync-merge UX improvements.
    case iCloudConflictResolved(kind: ICloudConflictKind)
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
        case .screenBouncedQuick: return "screen_bounced_quick"

        case .tabSwitched: return "tab_switched"
        case .sheetOpened: return "sheet_opened"
        case .sheetDismissed: return "sheet_dismissed"

        case .featureFirstUse: return "feature_first_use"

        case .tipJarDismissed: return "tip_jar_dismissed"

        case .rageTapDetected: return "rage_tap_detected"
        case .flowAbandoned: return "flow_abandoned"
        case .searchNoResults: return "search_no_results"
        case .formValidationFailed: return "form_validation_failed"

        case .errorOccurred: return "error_occurred"
        case .iCloudConflictResolved: return "icloud_conflict_resolved"
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

        case let .transactionCreated(type, hasSplit, hasItems, isRecurring, currency, amountBucket, category, source, hasDescription, wasCategoryAutoMatched):
            var params: [String: String] = [
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
            // Only emit the auto-match param when it's meaningful
            // (i.e. a scan-derived create). Skipping the key on manual
            // creates keeps the dashboard's "wasCategoryAutoMatched"
            // segmentation clean instead of polluted with N/A rows.
            if let matched = wasCategoryAutoMatched {
                params["category_auto_matched"] = String(matched)
            }
            return params
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
        case let .receiptScanSucceeded(itemsBucket, confidence, parser, durationBucket, discounts, fees, taxes, provider, attemptedProviders, imageBucket, language, storeCategory):
            return [
                "items_count_bucket": itemsBucket,
                "confidence": confidence.rawValue,
                "parser": parser.rawValue,
                "duration_seconds_bucket": durationBucket,
                "discount_count": String(discounts),
                "fee_count": String(fees),
                "tax_count": String(taxes),
                "provider": provider.rawValue,
                "attempted_providers_count": String(attemptedProviders),
                "image_size_kb_bucket": imageBucket,
                "language": language.rawValue,
                "store_category": storeCategory.rawValue
            ]
        case let .receiptScanFailed(errorType, source):
            return ["error_type": errorType.rawValue, "source": source.rawValue]
        case let .receiptItemsEditedInReview(added, deleted, nameEdits, priceEdits, quantityEdits, totalChanged):
            return [
                "items_added": String(added),
                "items_deleted": String(deleted),
                "name_edits": String(nameEdits),
                "price_edits": String(priceEdits),
                "quantity_edits": String(quantityEdits),
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
        case let .screenBouncedQuick(screen, dwellMs):
            return ["screen": screen, "dwell_ms": String(dwellMs)]

        case let .tabSwitched(from, to):
            return ["from": from.rawValue, "to": to.rawValue]
        case let .sheetOpened(name, source):
            return ["name": name, "source": source]
        case let .sheetDismissed(name, action, dwellBucket):
            return [
                "name": name,
                "action": action.rawValue,
                "dwell_seconds_bucket": dwellBucket
            ]

        case .featureFirstUse(let feature):
            return ["feature": feature.rawValue]

        case let .tipJarDismissed(source, dwellBucket, scrolled, tappedTier):
            var params: [String: String] = [
                "source": source.rawValue,
                "dwell_seconds_bucket": dwellBucket,
                "scrolled_tiers": String(scrolled)
            ]
            // Only emit `tapped_tier` when the user actually tapped
            // one (proxy for "near-conversion"). Absence = "looked
            // and left without engaging any tier."
            if let tier = tappedTier {
                params["tapped_tier"] = tier.rawValue
            }
            return params

        case let .rageTapDetected(element, count):
            return ["element": element, "tap_count": String(count)]
        case let .flowAbandoned(flow, atStep, dwellBucket):
            return [
                "flow": flow.rawValue,
                "at_step": atStep,
                "dwell_seconds_bucket": dwellBucket
            ]
        case let .searchNoResults(searchType, queryBucket):
            return [
                "search_type": searchType.rawValue,
                "query_length_bucket": queryBucket
            ]
        case let .formValidationFailed(form, field, reason):
            return [
                "form": form.rawValue,
                "field": field,
                "reason": reason.rawValue
            ]

        case let .errorOccurred(domain, code, recoverable, contextScreen):
            var params: [String: String] = [
                "domain": domain,
                "code": code,
                "recoverable": String(recoverable)
            ]
            if let screen = contextScreen {
                params["context_screen"] = screen
            }
            return params
        case .iCloudConflictResolved(let kind):
            return ["kind": kind.rawValue]
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

// MARK: New (Phase A) — receipt-scan deep-dive

/// Backend providers the receipt-parse router walks through. Lowercase
/// rawValue matches the wire string the backend emits in its logs so
/// the same identifier groups data across client + server analytics.
enum ScanProvider: String {
    case gemini
    case groq
    case cloudflare
    case openrouter
    case mistral
    case sambanova
    case nvidia
    case huggingface
    case ocrFallback = "ocr_fallback"
    case unknown
}

/// ISO-639-1 codes for languages the parser explicitly understands.
/// Anything else collapses to `other` rather than emitting raw locale
/// IDs (high-cardinality, hurts Firebase aggregation).
enum ReceiptLanguage: String {
    case en, ru, uk, de, fr, es, it, pt, pl, nl, tr, cs, sr, hr
    case ja, zh, ko, ar
    case other
}

/// Coarse business-type buckets we can derive from the receipt's
/// `suggestedCategory` field WITHOUT logging the actual store name.
/// Anything that doesn't map cleanly goes to `other`.
enum StoreCategory: String {
    case groceries
    case restaurant
    case entertainment
    case services
    case transport
    case fashion
    case electronics
    case healthcare
    case utilities
    case other
}

// MARK: New (Phase A) — navigation breadth

/// Top-level tabs. Add cases here when the tab bar grows.
enum AnalyticsTab: String {
    case home
    case profile
}

/// How a sheet / modal closed. `swipedDown` is the system gesture
/// (no commit + no cancel button), telemetrically equivalent to
/// `cancelled` for most flows but worth distinguishing for UX work.
enum SheetDismissAction: String {
    case completed
    case cancelled
    case swipedDown = "swiped_down"
}

// MARK: New (Phase A) — feature adoption

/// Distinct user-visible features used by `featureFirstUse`. ONE per
/// feature concept — sub-flows fold into their parent (e.g.,
/// "receipt-scan source picker" and "receipt-scan review" are both
/// the `receiptScan` feature). Keep the list manageable so the
/// adoption dashboard stays readable.
enum AnalyticsFeature: String {
    case transactionCreateManual = "transaction_create_manual"
    case receiptScan = "receipt_scan"
    case split
    case settleUp = "settle_up"
    case recurring
    case friends
    case categories
    case search
    case quickFilter = "quick_filter"
    case allFilters = "all_filters"
    case insights
    case importTransactions = "import_transactions"
    case exportTransactions = "export_transactions"
    case shareLink = "share_link"
    case tipJar = "tip_jar"
    case iCloudSync = "icloud_sync"
}

// MARK: New (Phase A) — confusion signals

/// Multi-step flows the user can abandon. Each `atStep` is a string
/// scoped to the flow (passed at the call-site to keep stage names
/// local to where they're defined).
enum AnalyticsFlow: String {
    case onboarding
    case transactionCreate = "transaction_create"
    case transactionEdit = "transaction_edit"
    case splitFlow = "split_flow"
    case receiptScan = "receipt_scan"
    case importTransactions = "import_transactions"
    case settleUp = "settle_up"
    case shareReceive = "share_receive"
    case tipJar = "tip_jar"
}

enum SearchType: String {
    case transactions
    case friends
    case categories
}

/// User-facing forms that have validation. Distinct from `AnalyticsFlow`
/// because a form is one screen with synchronous field-level errors,
/// whereas a flow can span several screens.
enum AnalyticsForm: String {
    case newTransaction = "new_transaction"
    case friendForm = "friend_form"
    case categoryForm = "category_form"
    case currencyPicker = "currency_picker"
}

/// What KIND of validation failed. Stable short tokens, not localised
/// strings — dashboards group by this.
enum ValidationFailureReason: String {
    case empty
    case invalidFormat = "invalid_format"
    case outOfRange = "out_of_range"
    case duplicate
    case unavailable
    case other
}

// MARK: New (Phase A) — errors

/// Conflict outcomes we can resolve during iCloud sync. Lets us see
/// which collision type is most common and prioritise UX work.
enum ICloudConflictKind: String {
    case transactionDuplicate = "transaction_duplicate"
    case friendMerge = "friend_merge"
    case categoryMerge = "category_merge"
    case other
}

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

    // MARK: Phase A additions

    /// Count of distinct `AnalyticsFeature` values used in the last
    /// 7 days, bucketed. Strong engagement proxy — a user using 6+
    /// distinct features is a power user. Updated at app launch from
    /// a local rolling set.
    case featuresUsedDays7Bucket(String)
    /// Average count of items the user edited per scan, bucketed.
    /// Low = parser works well for this user (likely store / language
    /// match). High = friction. Lets us segment retention by
    /// parser-quality cohort.
    case avgScanEditsBucket(String)
    /// Where the user sits in the tip-jar funnel. Updated after each
    /// tipJar* event. `none` = never opened, `viewed` = opened but
    /// dismissed, `dismissedNear` = scrolled tiers, `purchased`.
    case tipFunnelStage(String)

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
        case .featuresUsedDays7Bucket: return "features_used_days7_bucket"
        case .avgScanEditsBucket: return "avg_scan_edits_bucket"
        case .tipFunnelStage: return "tip_funnel_stage"
        }
    }

    var stringValue: String {
        switch self {
        case .txCountBucket(let v), .splitCountBucket(let v),
             .friendCountBucket(let v), .defaultCurrency(let v),
             .daysSinceInstallBucket(let v),
             .featuresUsedDays7Bucket(let v), .avgScanEditsBucket(let v),
             .tipFunnelStage(let v):
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

    /// JPEG byte size in KB bucket — proxy for "AI call cost" without
    /// measuring tokens. Boundaries tuned for the 2560 px source path
    /// in `ImagePreprocessing`: typical receipts at quality 0.9 land
    /// in `200-500`, busy long-tape receipts in `500-1000`, the rare
    /// edge case in `1000-2500`.
    static func imageSizeKb(_ bytes: Int) -> String {
        let kb = bytes / 1024
        switch kb {
        case 0..<200:    return "<200"
        case 200..<500:  return "200-500"
        case 500..<1000: return "500-1000"
        case 1000..<2500: return "1000-2500"
        default:         return "2500+"
        }
    }

    /// Query-length bucket for `searchNoResults`. Distinguishes
    /// "user typed nothing meaningful" (1-2 chars) from "user
    /// searched something specific and got nothing" (10+ chars).
    static func queryLength(_ length: Int) -> String {
        switch length {
        case 0...2:    return "<3"
        case 3...5:    return "3-5"
        case 6...10:   return "6-10"
        case 11...20:  return "11-20"
        default:       return "20+"
        }
    }

    /// Coarse dwell-time buckets used by sheet-dismiss, flow-abandon,
    /// and tip-jar-dismiss events. Sub-second buckets keep "instant
    /// bounce" distinct from "looked then left."
    static func dwellSeconds(_ seconds: Double) -> String {
        switch seconds {
        case 0..<1:    return "<1s"
        case 1..<3:    return "1-3s"
        case 3..<10:   return "3-10s"
        case 10..<30:  return "10-30s"
        case 30..<120: return "30-120s"
        default:       return "120s+"
        }
    }
}
