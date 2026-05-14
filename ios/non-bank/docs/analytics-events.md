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
| `transaction_created` | `type` (income/expense), `has_split`, `has_receipt_items`, `is_recurring`, `currency`, `amount_bucket`, `category`, `source` (manual/scan/share_link/settle_up), `has_description` | Daily volume by feature. Category mix. |
| `transaction_edited` | `field_changed` (amount/title/category/date/split/other) | Which fields trip people up? Edits = friction signal. |
| `transaction_deleted` | `had_split`, `had_receipt_items`, `age_days_bucket` | Quick deletes = user mistake. Old deletes = housekeeping. |
| `transaction_excluded_from_insights` | — | Insights credibility — too many opt-outs = bad defaults. |

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
| `receipt_scan_succeeded` | `items_count_bucket`, `confidence` (high/medium/low), `parser` (cloud/ocr_fallback), `duration_seconds_bucket`, `discount_count`, `fee_count`, `tax_count` | AI quality per cohort. Edit-rate × confidence = trust signal. |
| `receipt_scan_failed` | `error_type` (network/no_items/parse_error/timeout), `source` | Failure categorisation drives parser improvements. |
| `receipt_items_edited_in_review` | `items_added`, `items_deleted`, `items_modified`, `total_changed` | Did the user trust the AI output? High edit-count = retrain prompt. |

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
`screen_view` manually. Wrap with a `.analyticsScreen("home")` view
modifier so the call-site is one line.

| Event | Params | Why |
|---|---|---|
| `screen_view` | `screen_name` | Funnel building. Aggregate session paths. |

Main screens to track: `home`, `debts`, `friends`, `friend_detail`,
`insights`, `settings`, `transaction_detail`, `create_transaction`,
`import`, `export`, `tip_jar`, `licenses`, `onboarding`, `lock_screen`,
`reminders`.

## User properties

Set once per session (or when the relevant field changes). Used for
cohort splits — never for targeting individuals.

| Property | Buckets / type | Why |
|---|---|---|
| `tx_count_bucket` | `0` / `1-5` / `6-20` / `21-50` / `51-200` / `200+` | Single-best engagement proxy. |
| `split_count_bucket` | same | Split adoption depth. |
| `friend_count_bucket` | `0` / `1-2` / `3-5` / `6-15` / `15+` | Social-graph density. |
| `default_currency` | ISO-4217 | Locale segmentation. |
| `has_icloud_sync` | bool | Power-user. |
| `has_completed_onboarding` | bool | Funnel stage. |
| `has_made_tip` | bool | Direct revenue signal. |
| `days_since_install_bucket` | `0` / `1-7` / `8-30` / `31-90` / `90+` | Lifecycle stage. |

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
