import SwiftUI
import Lottie

// MARK: - Empty Transactions View

struct EmptyTransactionsView: View {
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: AppSpacing.lg) {
                LottieView(animation: .named("empty_transactions_list"))
                    .looping()
                    .frame(height: 230)
                    .frame(maxWidth: .infinity)
                Text("No transactions yet")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text("Add your first transaction to start tracking your spending.")
                    .font(AppFonts.emojiSmall)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxxl)
            }
            .frame(maxWidth: .infinity)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }
}
