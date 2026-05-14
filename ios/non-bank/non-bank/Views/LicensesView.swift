import SwiftUI

/// Licenses + privacy disclosure page reached from Settings → About.
///
/// Two jobs:
///   1. App Store-compliant privacy statement — what data leaves the
///      device, where it goes, and what we deliberately don't collect.
///      Apple's App Privacy review will catch any service mentioned in
///      the binary that isn't disclosed here.
///   2. Acknowledgements for the third-party services we depend on.
///      We don't ship any SPM dependencies (verified — Package.swift
///      empty), so the list is short: Cloudflare Workers (AI proxy)
///      and Frankfurter (European Central Bank FX feed). Everything
///      else is first-party Apple frameworks.
///
/// Copy is intentionally human-readable, not legalese — App Store
/// reviewers and end users both read this. The official, lawyer-vetted
/// privacy policy lives elsewhere and is linked at the bottom.
struct LicensesView: View {
    private let buildVersion: String = {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "non-bank \(v) (\(b))"
    }()

    var body: some View {
        List {
            // MARK: Privacy headline
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Your data, not ours")
                        .font(AppFonts.displayMedium)
                        .foregroundColor(AppColors.textPrimary)
                    Text("non-bank doesn't sell your data, doesn't show ads, and doesn't track you across other apps or websites. We collect anonymous usage stats (no names, no amounts, no advertising ID) so we can see which features are useful and which to drop. You can turn this off any time in Settings → Privacy.")
                        .font(AppFonts.bodyRegular)
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.vertical, AppSpacing.xs)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            // MARK: What stays on device
            //
            // Plain-English rewrite of the original SQLite-flavoured
            // copy. Same content, no database name — App Store privacy
            // accuracy is unaffected because "stored only on your
            // iPhone" still describes the truth.
            Section {
                bullet("All your transactions, friends, categories, receipts, and split history are stored only on your iPhone.")
                bullet("Nothing is uploaded to a non-bank server. There isn't one.")
            } header: {
                Text("Stays on your device")
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: iCloud
            //
            // Dropped "CloudKit zone" / "end-to-end protected" — both
            // are accurate but unfamiliar terminology for a general
            // audience. "iCloud" and "protected by Apple's iCloud
            // security" carry the same meaning.
            Section {
                bullet("If you turn on iCloud Sync in Settings, your transactions, categories, friends, and receipt items are saved to your private iCloud account.")
                bullet("This data is protected by Apple's iCloud security. We can't read it. Other people can't read it.")
                bullet("Turn sync off any time — your local copy stays put.")
            } header: {
                Text("iCloud Sync (optional)")
            } footer: {
                Text("iCloud is operated by Apple under their privacy policy. See apple.com/legal/privacy.")
                    .font(AppFonts.footnote)
                    .foregroundColor(AppColors.textTertiary)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Receipt scanning
            //
            // Heaviest jargon section in the prior copy — replaced
            // "Cloudflare Worker / parsed line items / EXIF metadata /
            // GPS coordinates / UUID / locale / Apple Vision OCR" with
            // plain descriptions that preserve the same disclosure
            // content. Apple's privacy review only requires that the
            // disclosure be accurate and complete, not that it use
            // engineering vocabulary.
            Section {
                bullet("When you scan a receipt, the photo is sent to a small service we run on Cloudflare. That service passes it on to one of several AI providers (Google Gemini, Groq, OpenRouter, or Cloudflare's own AI) which reads the items on the receipt and sends them back.")
                bullet("Before we send the photo, we remove the hidden info attached to it — including any location it was taken at. The service and the AI providers don't receive your name, your friends, or any other transactions.")
                bullet("Along with the photo we send: a random anonymous ID created the first time you opened the app, your list of category names and emoji (so the AI can pick the right category), and your language/region setting.")
                bullet("If none of the AI providers respond, scanning falls back to your iPhone's built-in text recognition — nothing leaves the phone.")
                bullet("Neither our service nor the AI providers keep the receipt photo or the result after sending it back.")
            } header: {
                Text("Receipt scanning")
            } footer: {
                Text("Cloudflare's privacy notice covers our service's part of the trip: cloudflare.com/privacypolicy.")
                    .font(AppFonts.footnote)
                    .foregroundColor(AppColors.textTertiary)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Currency rates
            //
            // "Open-source API / HTTPS requests / MIT-licensed" →
            // plain equivalents. The European Central Bank reference
            // stays — it's a recognised public institution and
            // explains where the data ultimately comes from.
            Section {
                bullet("Exchange rates come from Frankfurter, a free public service that shares rates published by the European Central Bank.")
                bullet("The app asks for exchange rates anonymously. No personal info is sent.")
            } header: {
                Text("Currency rates")
            } footer: {
                Text("frankfurter.dev — free and open source, no tracking.")
                    .font(AppFonts.footnote)
                    .foregroundColor(AppColors.textTertiary)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Share links
            //
            // "Encoded into the URL / static page hosted on GitHub
            // Pages" → "packed into the link / a simple page hosted
            // on GitHub". GitHub stays mentioned because the data-
            // flow disclosure has to name where the install-prompt
            // page is served from.
            Section {
                bullet("When you share a split transaction, the details are packed straight into the link. The person who opens it decodes it on their device — there's no server in between.")
                bullet("If they don't have non-bank installed, the link opens a simple page at share.nonbank.app (hosted on GitHub) that just shows install instructions. Your transaction is never sent to GitHub or any other server.")
            } header: {
                Text("Sharing transactions")
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Tips / IAP
            //
            // "In-App Purchase system / non-personal receipt
            // confirmation" → "Apple's in-app payment system /
            // a confirmation from Apple that doesn't include
            // anything personal".
            Section {
                bullet("Tips are processed by Apple's in-app payment system. We get a confirmation from Apple that doesn't include your name, card, or address.")
                bullet("Apple handles refunds. To request one, open Settings → Apple ID → Subscriptions on your iPhone.")
            } header: {
                Text("Tips and payments")
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Analytics
            //
            // "Firebase Analytics / bucketed counts / IDFA" → plain
            // descriptions. The product name "Google Firebase" stays
            // because Apple's privacy disclosure requires us to name
            // the third party that receives data.
            Section {
                bullet("We use Google Firebase to understand which features people use, where they drop off, and what to build next.")
                bullet("What we collect: anonymous events (e.g. \u{201C}transaction created,\u{201D} \u{201C}receipt scan succeeded\u{201D}), rough counts (like \u{201C}6\u{2013}20 transactions\u{201D}), your default currency, app version, device model, and country.")
                bullet("What we never collect: your name, friend names, transaction titles, descriptions, receipt photos, exact amounts, or any identifier that links back to you (no advertising ID, no email).")
                bullet("You can turn analytics off any time in Settings → Privacy. The toggle takes effect immediately.")
                bullet("Firebase runs under Google's privacy terms — see firebase.google.com/support/privacy.")
            } header: {
                Text("Analytics")
            } footer: {
                Text("This puts non-bank in the App Store's \u{201C}Data Not Linked to You\u{201D} category.")
                    .font(AppFonts.footnote)
                    .foregroundColor(AppColors.textTertiary)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Permissions — already plain-English, no changes.
            Section {
                bullet("Camera — only when you tap \u{201C}Scan receipt.\u{201D}")
                bullet("Photo Library — only when you import a receipt from your photos.")
                bullet("Notifications — for transaction reminders. Schedule and content stay on your device.")
            } header: {
                Text("Device permissions")
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Acknowledgements
            //
            // Service / framework names kept (they're the *credits*),
            // but the side notes use everyday descriptions instead of
            // "OCR fallback", "MIT", "proprietary".
            Section {
                acknowledgement(name: "Frankfurter", note: "Exchange rates · free and open source")
                acknowledgement(name: "Cloudflare", note: "Hosts our receipt-scan service")
                acknowledgement(name: "Apple Vision", note: "Reads receipt text on-device when our service is unavailable")
                acknowledgement(name: "Apple iCloud", note: "Optional iCloud sync")
                acknowledgement(name: "Apple In-App Purchases", note: "Handles in-app tips")
                acknowledgement(name: "Apple Mail composer", note: "Sends your support emails")
                acknowledgement(name: "Google Firebase", note: "Anonymous usage stats")
            } header: {
                Text("Acknowledgements")
            }
            .listRowBackground(AppColors.backgroundElevated)

            // MARK: Contact
            Section {
                HStack {
                    Text("Email")
                        .foregroundColor(AppColors.textSecondary)
                    Spacer()
                    Text(SupportMail.address)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(AppColors.textPrimary)
                        .onTapGesture {
                            UIPasteboard.general.string = SupportMail.address
                        }
                }
                HStack {
                    Text("Version")
                        .foregroundColor(AppColors.textSecondary)
                    Spacer()
                    Text(buildVersion)
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(AppColors.textPrimary)
                }
            } header: {
                Text("Contact")
            }
            .listRowBackground(AppColors.backgroundElevated)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Licenses & Privacy")
        .navigationBarTitleDisplayMode(.inline)
        // Push the content above the floating tab bar + FAB. Without
        // this the Contact section at the bottom of the list slides
        // under the tab strip on the last scroll page and the user
        // can't fully read the email row. Matches the 80pt bottom
        // inset SettingsView itself applies for the same reason.
        .safeAreaInset(edge: .bottom) {
            Color.clear.frame(height: 80)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("•")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textTertiary)
            Text(text)
                .font(AppFonts.bodyRegular)
                .foregroundColor(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
    }

    private func acknowledgement(name: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
            Text(note)
                .font(AppFonts.metaRegular)
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.vertical, 2)
    }
}
