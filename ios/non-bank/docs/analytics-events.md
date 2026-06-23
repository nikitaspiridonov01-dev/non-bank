# non-bank · Analytics Event Taxonomy

Single source of truth for what we track, what each event answers, and
how to use it. Mirrors the Swift `AnalyticsEvent` enum one-to-one — any
event mentioned here is implemented there, and vice versa.

## North-star questions we want to answer

Every event below earns its keep by helping us answer at least one of:

1. **Where do new users drop off?** Cold-start → first useful action.
2. **What's the killer feature people stay for?** Splits, scanning,
   insights, sync — which is the retention driver?
3. **Who is a paying-power user?** What signals predict willingness to
   pay before we even launch a subscription?
4. **Where does the AI / OCR fail in production?** Confidence scores
   vs. correction frequency.
5. **What features are dead weight?** Built but unused — remove or
   redesign rather than maintain.

## Naming conventions

- `snake_case` event names, max 40 chars (Firebase limit).
- Parameter values stay either string buckets (`tx_count_bucket: "11-50"`)
  or short enums (`mode: "evenly"`). No raw amounts, free-form strings,
  or PII.
- Currency is always the ISO-4217 code (`USD`, `IDR`, …).
- Buckets keep PII-resistance: a single user's amount can't be exfiltrated
  through bucket boundaries.

## Event categories

### 1. Acquisition (mostly Firebase auto)
| Event | Auto? | Why we care |
|---|---|---|
| `first_open` | ✓ | New install. Drives DAU/MAU baselines. |
| `session_start` | ✓ | Session count, length, frequency. |

### 2. Onboarding funnel
Critical: this is the first 60 seconds — every drop-off here is a user
we lose forever.

| Event | Params | Question |
|---|---|---|
| `onboarding_started` | — | Did the user reach the flow? |
| `onboarding_step_viewed` | `step_index` (0–3) | Per-step funnel. Where does the bleed happen? |
| `onboarding_skipped` | `step_index` | Skipped vs. completed share. Which step prompts the skip? |
| `onboarding_completed` | `initial_balance_set: bool`, `time_seconds_bucket` | Completion rate. % of users who set an initial balance — proxy for "engaged from minute one." |

### 3. Activation — "first useful action"

A user is *activated* when they do at least one of the killer-feature
actions. We track each first occurrence so cohort tools can compute
"time-to-activation" — the single most predictive retention metric.

| Event | Params | Why |
|---|---|---|
| `activation_first_transaction` | `time_since_install_minutes_bucket` | Baseline activation. |
| `activation_first_split` | `time_since_install_minutes_bucket` | Strongest predictor of week-2 retention. |
| `activation_first_friend_added` | `source: "manual"/"share_link"` | Adoption of the social loop. |
| `activation_first_receipt_scanned` | `time_since_install_minutes_bucket`, `outcome: "success"/"fail"` | Adoption of the AI moment. |
| `activation_first_share_link_sent` | — | Virality kicks in here. |

### 4. Engagement — transactions

| Event | Params | Question |
|---|---|---|
| `transaction_created` | `type` (income/expense), `has_split`, `has_receipt_items`, `is_recurring`, `currency`, `amount_bucket`, `category`, `source` (manual/scan/share_link/settle_up), `has_description`, `category_auto_matched`? (bool — only emitted for scan-derived creates) | Daily volume by feature. Category mix. The `category_auto_matched` field measures auto-category accuracy. |
| `transaction_edited` | `field_changed` (amount/title/category/date/split/other) | Which fields trip people up? Edits = friction signal. |
| `transaction_deleted` | `had_split`, `had_receipt_items`, `age_days_bucket` | Quick deletes = user mistake. Old deletes = housekeeping. |
| `transaction_excluded_from_insights` | — | Insights credibility — too many opt-outs = bad defaults. |
| `transaction_included_in_insights` | — | Reversal counterpart. |

### 5. Engagement — split flow (the killer feature)

| Event | Params | Question |
|---|---|---|
| `split_mode_selected` | `mode` (evenly/byItems/byAmount/settleUp), `num_friends` | Mode mix. Are we maintaining four modes for nothing? |
| `split_completed` | `mode`, `num_friends`, `has_receipt`, `total_amount_bucket`, `currency` | Per-mode adoption + size of splits. |
| `split_share_prompt_shown` | — | Auto-shown after split create. |
| `split_share_prompt_action` | `action` (shared/dismissed) | Adoption rate of the post-create nudge. |
| `settle_up_initiated` | `source` (friend_detail/manual) | Settle-up entry points. |
| `settle_up_completed` | — | Resolution funnel. |

### 6. Receipt scan (AI moment)

| Event | Params | Question |
|---|---|---|
| `receipt_scan_started` | `source` (camera/gallery), `num_photos` (1/2/3) | Capture path. Multi-image adoption. |
| `receipt_scan_succeeded` | `items_count_bucket`, `confidence` (high/medium/low), `parser` (cloud/ocr_fallback), `duration_seconds_bucket`, `discount_count`, `fee_count`, `tax_count`, `provider` (gemini/groq/cloudflare/openrouter/mistral/sambanova/nvidia/huggingface/ocr_fallback/unknown), `attempted_providers_count`, `image_size_kb_bucket`, `language` (en/ru/de/.../other), `store_category` (groceries/restaurant/services/entertainment/transport/fashion/electronics/healthcare/utilities/other) | AI quality + cost segmentation. `provider` shows real-world hit distribution; `attempted_providers_count > 1` flags silent provider degradation; `image_size_kb_bucket` is cost proxy without tokens; `language` + `store_category` segment by receipt type without leaking store names or item content. |
| `receipt_scan_failed` | `error_type` (network/no_items/parse_error/timeout), `source` | Failure categorisation drives parser improvements. |
| `receipt_items_edited_in_review` | `items_added`, `items_deleted`, `name_edits`, `price_edits`, `quantity_edits`, `total_changed` | Per-field parser-accuracy. High `name_edits` = OCR text problems; high `price_edits` = OCR digit problems; high `quantity_edits` = weighted-item misparsing. |

### 7. Share-link round-trip

| Event | Params | Question |
|---|---|---|
| `share_link_sent` | `source` (detail/post_split_prompt), `share_type` (split/single_tx) | Where do users share from? |
| `share_link_opened` | `outcome` (auto_create/picker_shown/identical/update_prompt/malformed) | Reception side. Picker rate = friend graph match-rate. |
| `share_link_imported` | `had_picker`, `num_participants_bucket`, `is_update` | Successful round-trip. |
| `share_link_update_dismissed` | — | "Friend edited" prompt rejection rate. |

### 8. iCloud sync (power-user proxy)

| Event | Params | Question |
|---|---|---|
| `icloud_sync_enabled` | — | Adoption of sync. |
| `icloud_sync_disabled` | — | Churn signal. |
| `icloud_initial_sync_completed` | `duration_seconds_bucket`, `tx_count_bucket`, `had_conflicts` | Time to backfill — performance regression detector. |

### 8b. Server sync (friend auto-sync)

Server-mediated split delivery between paired friends (`SyncEngine`).
Fire-and-forget telemetry only — never gates the upload / apply path.

| Event | Params | Question |
|---|---|---|
| `split_auto_synced` | `recipient_count` | A split upload landed on ≥1 paired recipient. Fires once per save/edit. Volume = how often the auto-sync path actually delivers. |
| `sync_upload_failed` | `reason` (pairing_inactive/failed/offline) | Per-recipient upload didn't land. `pairing_inactive` = recipient revoked the pairing; `failed` = transient / 5xx. |
| `pairing_established` | `via` (handshake/self_heal/link_import) | A friend NEWLY became connected via the sync path. Which channel converges pairings — drives "does self-heal carry its weight." |
| `sync_delivery_received` | `count_bucket` | A foreground pull fetched ≥1 inbox delivery. Inbound traffic volume. |
| `sync_delivery_applied` | `op` (upsert/delete/pair), `was_update` (bool) | A delivery applied successfully. `was_update` = updated an existing tx vs created a new one. |
| `sync_delivery_failed` | `reason` (decrypt_failed/version_stale/apply_error) | A delivery couldn't be applied. `decrypt_failed` = no key authenticated; `version_stale` = guarded by the monotonic-version check; `apply_error` = the headless apply threw. |

### 9. Categories

| Event | Params | Question |
|---|---|---|
| `category_created` | — | Personalisation depth. |
| `category_edited` | `title_changed`, `emoji_changed`, `affected_tx_count_bucket` | Cascade rename usage. |
| `category_deleted` | `had_transactions` | Cleanup vs. mistake. |

### 10. Friends

| Event | Params | Question |
|---|---|---|
| `friend_created` | `source` (manual/share_link) | How friends enter the system. |
| `friend_edited` | — | Maintenance signal. |
| `friend_deleted` | `had_splits` | Power-user housekeeping. |
| `friend_detail_viewed` | `balance_state` (lent/owe/balanced), `tx_count_bucket` | Engagement with the friend page. |

### 11. Import / Export

| Event | Params | Question |
|---|---|---|
| `export_started` | `format` (json/csv/xlsx), `tx_count_bucket`, `date_range_days_bucket` | Adoption of export. Format mix tells us which integrations matter. |
| `export_completed` | `format`, `tx_count_bucket` | Successful share-sheet hand-off. |
| `import_file_selected` | `format` (json/csv/xlsx), `tx_count_bucket`, `is_native_envelope` | Adoption of import. |
| `import_completed` | `format`, `mode` (add/replace), `tx_count_bucket`, `is_native_envelope`, `new_categories_created`, `new_friends_added`, `receipt_items_imported` | Successful full ingest. |
| `import_failed` | `format`, `error_type` | Where does the wizard get stuck? |

### 12. Insights / Analytics screens

| Event | Params | Question |
|---|---|---|
| `insights_viewed` | `tab` (overview/categories/trends) | Adoption of the analytics moment. |
| `insights_filter_changed` | `filter_type` (date_range/category/type), `value` | Filter usage — feature value signal. |
| `insights_card_tapped` | `card_type` (big_purchase/category_history/cannibalisation/top_categories/monthly_trend) | Which cards are useful enough to drill into? |
| `home_quick_filter_tapped` | `category` | Quick-filter adoption. |

### 13. Tips / IAP (direct revenue proxy)

| Event | Params | Question |
|---|---|---|
| `tip_jar_viewed` | `source` (settings/onboarding/post_split) | Where do tip-jar discovery moments come from? |
| `tip_purchase_started` | `tier` (coffee/croissant/pizza/chefstable) | Price-tier funnel. |
| `tip_purchase_succeeded` | `tier`, `price_bucket` | Conversion rate by tier. **Best leading indicator for subscription willingness.** |
| `tip_purchase_failed` | `tier`, `error_code` | Apple sandbox / production failure surface. |
| `tip_purchase_cancelled` | `tier` | Bail-out point in the StoreKit flow. |

### 14. Help / Settings

| Event | Params | Question |
|---|---|---|
| `help_mail_compose_opened` | `kind` (feature/bug/support) | Support load + feature-request volume by type. |
| `licenses_viewed` | — | Privacy-conscious cohort. |
| `settings_viewed` | — | Engagement with the configuration surface. |

### 15. Screen views (SwiftUI manual tracking)

Firebase autotracks UIKit screens, but SwiftUI requires us to fire
`screen_view` manually. Wrap with the `.trackScreen("HomeView")`
view modifier (defined in `AnalyticsEnvironment.swift`) so the
call-site is one line. The modifier also fires
`screen_bounced_quick` for sub-second dwells — automatic
misnavigation signal.

| Event | Params | Why |
|---|---|---|
| `screen_view` | `screen_name` | Funnel building. Aggregate session paths. |
| `screen_bounced_quick` | `screen`, `dwell_ms` | <1s dwell — user landed on the wrong screen or expected something else. Discoverability signal. |

Currently instrumented: `HomeView`, `InsightsView`, `DebtSummaryView`,
`FriendsView`, `FriendDetailView`, `TransactionDetailView`,
`SettingsView`, `TipJarView`, `CreateTransactionModal` (name
flips to `EditTransactionModal` when editing).

### 16. Navigation breadth (tabs + sheets)

| Event | Params | Question |
|---|---|---|
| `tab_switched` | `from` (home/profile), `to` | Tab-bar usage distribution. |
| `sheet_opened` | `name`, `source` | Modal-flow entry-point measurement. |
| `sheet_dismissed` | `name`, `action` (completed/cancelled/swiped_down), `dwell_seconds_bucket` | Sheet-funnel drop-off + commit-vs-bail. |

### 17. Feature adoption

| Event | Params | Question |
|---|---|---|
| `feature_first_use` | `feature` (transaction_create_manual / receipt_scan / split / settle_up / recurring / friends / categories / search / quick_filter / all_filters / insights / import_transactions / export_transactions / share_link / tip_jar / icloud_sync) | "% users who ever touched X" — fires once per install per feature via UserDefaults-gated helper. |

### 18. Tip-jar funnel (extension)

In addition to the `tip_purchase_*` events in §13:

| Event | Params | Question |
|---|---|---|
| `tip_jar_dismissed` | `source`, `dwell_seconds_bucket`, `scrolled_tiers` (bool), `tapped_tier`? (coffee/croissant/pizza/chefstable — only when user tapped a tier without buying) | Funnel-leak side of the jar. Distinguishes "saw and bounced" from "considered but didn't buy." `tapped_tier` present = near-conversion. |

### 19. Confusion signals

| Event | Params | Question |
|---|---|---|
| `rage_tap_detected` | `element`, `tap_count` | User mashed the same button ≥3 times within 800ms. Wrap candidate buttons with `.rageTapTracked("element_name")`. |
| `flow_abandoned` | `flow` (onboarding/transaction_create/transaction_edit/split_flow/receipt_scan/import_transactions/settle_up/share_receive/tip_jar), `at_step`, `dwell_seconds_bucket` | User opened a multi-step flow, dwelled, dismissed without committing. Drive with `analytics.startFlow(.X, atStep:)` token; call `complete()` on success path. |
| `search_no_results` | `search_type` (transactions/friends/categories), `query_length_bucket` (<3/3-5/6-10/11-20/20+) | Empty-results frustration. `query_length >= 11` = "user searched something specific" = potential missing feature or poor matching. |
| `form_validation_failed` | `form` (new_transaction/friend_form/category_form/currency_picker), `field`, `reason` (empty/invalid_format/out_of_range/duplicate/unavailable/other) | Where does the UX fail to set expectations before the user types? |

### 20. Errors (generic)

In addition to domain-specific failure events (`receipt_scan_failed`,
`tip_purchase_failed`, `import_failed`):

| Event | Params | Question |
|---|---|---|
| `error_occurred` | `domain` (sync/db/share_decode/...), `code`, `recoverable` (bool), `context_screen`? | Catchall for the long tail. Use `analytics.trackError(domain:error:recoverable:contextScreen:)` from any catch site. |
| `icloud_conflict_resolved` | `kind` (transaction_duplicate/friend_merge/category_merge/other) | Fired per resolved conflict in `SyncManager.merge*` functions. Volume here tracks "how often does iCloud actually find divergent state to merge." |

## User properties

Set once per session (or when the relevant field changes). Used for
cohort splits — never for targeting individuals.

| Property | Buckets / type | Why |
|---|---|---|
| `tx_count_bucket` | `0` / `1-5` / `6-20` / `21-50` / `51-200` / `200+` | Single-best engagement proxy. |
| `split_count_bucket` | same | Split adoption depth. |
| `friend_count_bucket` | `0` / `1-2` / `3-5` / `6-15` / `15+` | Social-graph density. |
| `connected_friend_count` | `0` / `1-2` / `3-5` / `6-15` / `15+` | Server-sync paired-friend depth. Distinguishes "has friends" from "has friends who actually auto-sync." |
| `default_currency` | ISO-4217 | Locale segmentation. |
| `has_icloud_sync` | bool | Power-user. |
| `has_completed_onboarding` | bool | Funnel stage. |
| `has_made_tip` | bool | Direct revenue signal. |
| `days_since_install_bucket` | `0` / `1-7` / `8-30` / `31-90` / `90+` | Lifecycle stage. |
| `features_used_days7_bucket` | count of distinct `AnalyticsFeature` kinds touched in past 7 days | Engagement breadth — a user touching 6+ features in a week is a power-user candidate even at low tx volume. |
| `avg_scan_edits_bucket` | average items-edited per scan | Parser-quality cohort. Low edits = parser works well for this user (likely store/language match). Useful for retention analysis. |
| `tip_funnel_stage` | `none` / `viewed` / `dismissed_near` / `purchased` | Where the user sits in the tip-jar funnel. Updated after each `tip_jar_*` event. |

## What we deliberately don't track

- **Names** — friend names, transaction titles, descriptions, category
  custom titles. The user types these for themselves.
- **Amounts** as raw numbers. Always bucketed.
- **Receipt images** — never logged or sent to analytics.
- **Friend UUIDs**, transaction UUIDs, sync IDs.
- **GPS / IP-derived location** beyond Firebase's default country.
- **IDFA** — `ATTrackingManager` not invoked. App Privacy nutrition
  label lands in "Data Not Linked to You."

## Operating cadence

- **Weekly:** funnel review for onboarding + activation + scan.
- **Monthly:** retention cohorts by `tx_count_bucket`,
  `has_icloud_sync`, `has_made_tip`.
- **Quarterly:** feature-usage audit — events with <5% session
  coverage are candidates for removal.

When subscription launches:
- The `has_made_tip = true` cohort becomes the seed for "willing to
  pay" — measure their conversion separately.
- Pre-paywall: track `paywall_viewed`, `paywall_dismissed`,
  `paywall_cta_tapped`, `subscription_started`, `subscription_cancelled`,
  with `tier`, `trial_offered`, and `source` params.
