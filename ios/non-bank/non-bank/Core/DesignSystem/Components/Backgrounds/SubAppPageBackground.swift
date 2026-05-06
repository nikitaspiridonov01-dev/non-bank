import SwiftUI

// MARK: - Sub-app page backgrounds
//
// Replaces the flat `reminderBackgroundTint` / `splitBackgroundTint`
// page fills with a soft pastel `MeshGradient` (iOS 18+). The visual
// is a low-saturation aurora — the sub-palette base tint plus a few
// faint blobs of the sub-app's own accent colours, blurred together.
// Sits between "completely flat brand surface" and "loud gradient" —
// gives the screen a subtle warmth/depth without competing with the
// glass chips and rows that float on top.
//
// Both views call `.ignoresSafeArea()` themselves so callers can use
// them via `.background { ReminderPageBackground() }` without an
// extra modifier. Each carries its own light/dark tuning.
//
// **Where to use:** any *full-page* surface that previously called
// `.background(AppColors.reminderBackgroundTint)` /
// `.background(AppColors.splitBackgroundTint)` — RemindersView page,
// DebtSummaryView, FriendsView (Split mode), FriendDetailView,
// ShareDistributionView, PaidUpfrontView, TransactionDetailView when
// `source.isReminder` / `source == .debts`.
//
// **Where NOT to use:** inline shapes that just need a tinted fill
// (a row chip, a `.fill(...)` on a `RoundedRectangle` inside another
// view, or a small section background). The flat token still serves
// those — gradients there would clash with the surrounding page.

// MARK: - Reminders

/// Soft pastel gradient page background for Reminders screens.
/// Base is `reminderBackgroundTint` (warm cream); aurora picks up
/// pink and red blobs blended from `reminderAccent` (calendar red
/// `#EB534E`) — the sub-app's primary accent — so the gradient
/// telegraphs **red Reminders**, not warm orange. All colours stay
/// near-white in lightness so text readability matches the flat-
/// tint version.
struct ReminderPageBackground: View {
    var body: some View {
        // Base solid behind the mesh — guards against any seam at
        // the very edges of `MeshGradient`'s control points and gives
        // the gradient something coherent to fade into where the
        // control colours are at their most "base".
        ZStack {
            AppColors.reminderBackgroundTint

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    ReminderPalette.cornerSoftPink,    ReminderPalette.base,             ReminderPalette.cornerCoral,
                    ReminderPalette.base,              ReminderPalette.centerBright,     ReminderPalette.base,
                    ReminderPalette.cornerPink,        ReminderPalette.base,             ReminderPalette.cornerRed
                ]
            )
        }
        .ignoresSafeArea()
    }
}

// MARK: - Reminder transaction detail variant
//
// **Vignette pattern** — pale red corners with a brighter cream
// centre, so the eye is drawn to the title and amount in the middle
// of the page. Uses its own inline ultra-pale red blends (paler
// than `ReminderPalette.cornerSoftPink`) so the detail card reads
// as a much calmer page than the main Reminders list it was pushed
// from. Control points stay on a uniform 3×3 grid (no seams).

struct ReminderDetailPageBackground: View {
    var body: some View {
        ZStack {
            AppColors.reminderBackgroundTint

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Self.palePink,     Self.paleSoft,    Self.palePink,
                    Self.paleSoft,     Self.bright,      Self.paleSoft,
                    Self.palePink,     Self.paleSoft,    Self.palePink
                ]
            )
        }
        .ignoresSafeArea()
    }

    /// Brightest cream — pulls the eye to the centre of the page.
    private static var bright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.13, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.98, blue: 0.97, alpha: 1.0)      // ~#FFFAF7 whisper-cream
        })
    }

    /// Pale cream with a red whisper — sits between the vignette
    /// corners and the bright centre.
    private static var paleSoft: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.12, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.95, blue: 0.94, alpha: 1.0)      // ~#FFF2EE
        })
    }

    /// Pale pink — the four corners, ~6.5% `reminderAccent` blend.
    private static var palePink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.14, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.93, blue: 0.91, alpha: 1.0)      // ~#FFEDE8 pale pink
        })
    }
}

// MARK: - Shared Reminder palette
//
// Lifts the Reminder colour helpers out of `ReminderPageBackground`
// so both variants paint with the **same** hex values — only the
// control-point geometry and colour-grid rotation differ. All
// blobs blend `reminderAccent` (calendar red `#EB534E`) with white
// at varying ratios so the dominant hue is **red**, not orange or
// yellow. Earlier iterations leaned on `accent` (warm orange
// `#F18A4D`) and ended up reading as a sunrise gradient instead of
// a reminder gradient.

private enum ReminderPalette {
    static var base: Color {
        AppColors.reminderBackgroundTint
    }

    /// Bright cream — keeps the centre of the page light so titles
    /// and amounts in the visual middle of any screen stay readable.
    static var centerBright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.13, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.96, blue: 0.94, alpha: 1.0)      // ~#FFF6F0 cream with red whisper
        })
    }

    /// Lightest red blend — soft pink cream. ~15% `reminderAccent` /
    /// 85% white.
    static var cornerSoftPink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.15, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.91, blue: 0.89, alpha: 1.0)      // ~#FFE8E2 soft pink
        })
    }

    /// Medium pink. ~25% `reminderAccent` / 75% white.
    static var cornerPink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.18, green: 0.07, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.84, blue: 0.81, alpha: 1.0)      // ~#FFD6CE clear pink
        })
    }

    /// Red coral. ~40% `reminderAccent` / 60% white. Visibly red,
    /// not orange.
    static var cornerCoral: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.22, green: 0.08, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 1.00, green: 0.74, blue: 0.71, alpha: 1.0)      // ~#FFBDB5 red coral
        })
    }

    /// Deepest red blob — strongest blend of `reminderAccent` so the
    /// gradient's "loudest" point reads clearly as the red sub-app
    /// accent.  ~55% accent / 45% white.
    static var cornerRed: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.26, green: 0.08, blue: 0.07, alpha: 1.0)
            }
            return UIColor(red: 0.98, green: 0.65, blue: 0.61, alpha: 1.0)      // ~#FAA59C clear red
        })
    }
}

// MARK: - Split

/// Soft pastel gradient page background for Split / Debts screens.
/// Base is `splitBackgroundTint` (muted lavender); aurora picks up
/// faint violet and pink whispers from the Split accent family.
struct SplitPageBackground: View {
    var body: some View {
        ZStack {
            AppColors.splitBackgroundTint

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Self.cornerLavender,   Self.base,            Self.cornerPink,
                    Self.base,             Self.centerBright,    Self.base,
                    Self.cornerCool,       Self.base,            Self.cornerViolet
                ]
            )
        }
        .ignoresSafeArea()
    }

    private static var base: Color {
        AppColors.splitBackgroundTint
    }

    private static var centerBright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.96, green: 0.94, blue: 0.98, alpha: 1.0)      // ~#F5EFFA brighter lavender
        })
    }

    private static var cornerLavender: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.88, green: 0.82, blue: 0.94, alpha: 1.0)      // ~#E0D0F0 clear lavender
        })
    }

    private static var cornerCool: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1.0)
            }
            return UIColor(red: 0.82, green: 0.86, blue: 0.94, alpha: 1.0)      // ~#D0DCF0 clear blue-lavender
        })
    }

    private static var cornerPink: Color {
        // Stronger pink — visible blob that pulls warmth into one
        // corner so the page doesn't feel monotonously violet.
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.13, green: 0.08, blue: 0.11, alpha: 1.0)
            }
            return UIColor(red: 0.94, green: 0.81, blue: 0.88, alpha: 1.0)      // ~#EFCFE0 clear pink
        })
    }

    private static var cornerViolet: Color {
        // Stronger blend of `splitAccent` deep violet — visible blob.
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.07, blue: 0.18, alpha: 1.0)
            }
            return UIColor(red: 0.84, green: 0.71, blue: 0.94, alpha: 1.0)      // ~#D5B5F0 clear violet
        })
    }
}

// MARK: - Friend detail variant
//
// **Diagonal pattern** — pale pink anchors top-left + bottom-right,
// pale lavender fills the rest. Uses its own inline ultra-pale
// blends (paler than `SplitPalette.cornerLavender` / `cornerPink`)
// so the friend detail page is the calmest of the three Split
// variants. Uniform 3×3 grid keeps the gradient seam-free.

struct FriendDetailPageBackground: View {
    var body: some View {
        ZStack {
            AppColors.splitBackgroundTint

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Self.palePink,     Self.paleLavender, Self.paleLavender,
                    Self.paleLavender, Self.bright,       Self.paleLavender,
                    Self.paleLavender, Self.paleLavender, Self.palePink
                ]
            )
        }
        .ignoresSafeArea()
    }

    private static var bright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.98, green: 0.97, blue: 1.00, alpha: 1.0)      // ~#FAF7FF
        })
    }

    /// Pale lavender — fills most of the page (~6.5% blend).
    private static var paleLavender: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.09, green: 0.08, blue: 0.13, alpha: 1.0)
            }
            return UIColor(red: 0.95, green: 0.94, blue: 0.99, alpha: 1.0)      // ~#F2F0FC pale lavender
        })
    }

    /// Pale pink — diagonal accents at TL / BR corners only.
    private static var palePink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.08, blue: 0.10, alpha: 1.0)
            }
            return UIColor(red: 0.98, green: 0.94, blue: 0.97, alpha: 1.0)      // ~#FAF0F7 pale pink
        })
    }
}

// MARK: - Split transaction detail variant
//
// **Horizontal split pattern** — pale lavender top half, pale pink
// bottom half. Different geometry from the diagonal `FriendDetail`
// and the vignette `ReminderDetail` so the three soft sub-app
// detail pages each carry their own unique blur drawing. Uses its
// own inline ultra-pale tones.

struct SplitDetailPageBackground: View {
    var body: some View {
        ZStack {
            AppColors.splitBackgroundTint

            MeshGradient(
                width: 3,
                height: 3,
                points: [
                    [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                    [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                    [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                ],
                colors: [
                    Self.paleLavender,  Self.paleLavender,  Self.paleLavender,
                    Self.bright,        Self.bright,        Self.bright,
                    Self.palePink,      Self.palePink,      Self.palePink
                ]
            )
        }
        .ignoresSafeArea()
    }

    private static var bright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.98, green: 0.97, blue: 1.00, alpha: 1.0)      // ~#FAF7FF
        })
    }

    /// Pale lavender — top half of the page (~6.5% blend).
    private static var paleLavender: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.09, green: 0.08, blue: 0.13, alpha: 1.0)
            }
            return UIColor(red: 0.94, green: 0.93, blue: 0.99, alpha: 1.0)      // ~#F0EDFC pale lavender
        })
    }

    /// Pale pink — bottom half of the page.
    private static var palePink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.08, blue: 0.10, alpha: 1.0)
            }
            return UIColor(red: 0.97, green: 0.94, blue: 0.96, alpha: 1.0)      // ~#F7F0F5 pale pink
        })
    }
}

// MARK: - Shared Split palette
//
// Lifts the Split colour helpers out of `SplitPageBackground` so the
// three variants (`SplitPageBackground` / `FriendDetailPageBackground`
// / `SplitDetailPageBackground`) all paint with exactly the same
// hex values — only the control-point geometry and colour-grid
// rotation differ. Keeps the sub-app one tonal family even though
// each screen has its own unique flow.

private enum SplitPalette {
    static var base: Color {
        AppColors.splitBackgroundTint
    }

    static var centerBright: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.96, green: 0.94, blue: 0.98, alpha: 1.0)      // ~#F5EFFA brighter lavender
        })
    }

    static var cornerLavender: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.10, green: 0.08, blue: 0.14, alpha: 1.0)
            }
            return UIColor(red: 0.88, green: 0.82, blue: 0.94, alpha: 1.0)      // ~#E0D0F0 clear lavender
        })
    }

    static var cornerCool: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.07, green: 0.08, blue: 0.13, alpha: 1.0)
            }
            return UIColor(red: 0.82, green: 0.86, blue: 0.94, alpha: 1.0)      // ~#D0DCF0 clear blue-lavender
        })
    }

    static var cornerPink: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.13, green: 0.08, blue: 0.11, alpha: 1.0)
            }
            return UIColor(red: 0.94, green: 0.81, blue: 0.88, alpha: 1.0)      // ~#EFCFE0 clear pink
        })
    }

    static var cornerViolet: Color {
        Color(UIColor { trait in
            if trait.userInterfaceStyle == .dark {
                return UIColor(red: 0.11, green: 0.07, blue: 0.18, alpha: 1.0)
            }
            return UIColor(red: 0.84, green: 0.71, blue: 0.94, alpha: 1.0)      // ~#D5B5F0 clear violet
        })
    }
}
