import SwiftUI

/// Logs a weigh-in to Apple Health (or the demo data).
struct WeightEntrySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var date = Date.now
    @State private var isSaving = false
    @State private var error: String?
    @FocusState private var isFocused: Bool

    init(initialKg: Double?) {
        _text = State(initialValue: initialKg.map { Format.number($0, digits: 1) } ?? "")
    }

    /// Accepts either decimal separator, whatever the locale.
    private var kg: Double? {
        Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            .flatMap { (20...400).contains($0) ? $0 : nil }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        TextField("Weight", text: $text)
                            .keyboardType(.decimalPad)
                            .font(.title2.bold())
                            .monospacedDigit()
                            .focused($isFocused)
                        Text("kg").foregroundStyle(.secondary)
                    }
                    DatePicker("Time", selection: $date, in: ...Date.now)
                } footer: {
                    Text(model.savesToHealth
                        ? "Saved to Apple Health, where other apps can see it too. The first time, Apple Health asks whether Stride may save weight."
                        : "Demo data: the weigh-in shows until the next refresh and isn't saved to Apple Health.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Log weight")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save", role: .confirm) { save() }
                            .disabled(kg == nil)
                    }
                }
            }
            .onAppear { isFocused = true }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        guard let kg else { return }
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await model.logWeight(kg: kg, at: date)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
