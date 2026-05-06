import SwiftUI
import PhotosUI

// MARK: - Receipt Scanner View

struct DebugReceiptScannerView: View {
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var receiptImage: UIImage?     // after editor adjustments
    @State private var ocrRows: [ReceiptOCRService.OCRRow] = []
    @State private var isProcessingOCR = false
    @State private var errorMessage: String?
    @State private var editorImage: UIImage?      // triggers editor cover
    @State private var showHighlighter = false

    private let ocr = ReceiptOCRService()

    var body: some View {
        NavigationStack {
            VStack(spacing: AppSpacing.xxl) {
                Spacer()

                if let image = receiptImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium))
                        .shadow(radius: 4)
                }

                if isProcessingOCR {
                    ProgressView("Scanning text...")
                        .padding()
                }

                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(AppColors.danger)
                        .font(.caption)
                        .padding(.horizontal)
                }

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose Receipt Photo", systemImage: "photo.on.rectangle")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AppColors.accentBold)
                .controlSize(.large)
                .padding(.horizontal, AppSpacing.xxxl)

                Spacer()
            }
            .navigationTitle("Receipt Scanner")
            .onChange(of: selectedPhoto) { _, newValue in
                loadImage(item: newValue)
            }
            .fullScreenCover(isPresented: Binding(
                get: { editorImage != nil },
                set: { if !$0 { editorImage = nil } }
            )) {
                if let img = editorImage {
                    ReceiptImageEditorView(originalImage: img) { editedImage in
                        editorImage = nil
                        receiptImage = editedImage
                        Task { @MainActor in await processOCR(image: editedImage) }
                    }
                }
            }
            .fullScreenCover(isPresented: $showHighlighter) {
                if let receiptImage {
                    ReceiptHighlighterView(
                        image: receiptImage,
                        ocrRows: ocrRows
                    )
                }
            }
        }
    }

    // MARK: - Actions

    private func loadImage(item: PhotosPickerItem?) {
        guard let item else { return }
        errorMessage = nil

        Task { @MainActor in
            do {
                if let data = try await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    editorImage = image
                } else {
                    errorMessage = "Could not load image."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func processOCR(image: UIImage) async {
        isProcessingOCR = true
        errorMessage = nil

        do {
            let lines = try await ocr.recognizeText(from: image)
            ocrRows = await ocr.groupIntoRows(from: lines)
            print("[Scanner] OCR: \(lines.count) observations → \(ocrRows.count) rows")

            if ocrRows.isEmpty {
                errorMessage = "No text found in image."
            } else {
                showHighlighter = true
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isProcessingOCR = false
    }
}

#Preview {
    DebugReceiptScannerView()
}
