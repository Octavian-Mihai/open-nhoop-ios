import SwiftUI

// MARK: - TrendsLayoutSettingsView
// Drag-to-reorder editor for the six Trends chart cards.

struct TrendsLayoutSettingsView: View {
    @State private var order: [MetricKind] = TrendsLayoutStorage.loadOrder()
    @State private var editMode: EditMode = .inactive

    var body: some View {
        List {
            Section {
                ForEach(order) { kind in
                    HStack(spacing: WH.Spacing.sm) {
                        Image(systemName: kind.systemImage)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(kind.color)
                            .frame(width: 28)
                        Text(kind.title)
                            .foregroundStyle(WH.Color.textPrimary)
                    }
                }
                .onMove(perform: move)
            } header: {
                Text("Chart Order")
            } footer: {
                Text("Drag to reorder cards on the Trends tab. Heart Rate can be moved to the top even before daily history exists.")
                    .font(WH.Font.caption)
                    .foregroundStyle(WH.Color.textSecondary)
            }

            Section {
                Button("Reset to default") {
                    order = MetricKind.defaultTrendOrder
                    TrendsLayoutStorage.resetToDefault()
                }
                .foregroundStyle(WH.Color.strainBlue)
            }
        }
        .scrollContentBackground(.hidden)
        .background(WH.Color.background)
        .navigationTitle("Trends Layout")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                EditButton()
            }
        }
        .environment(\.editMode, $editMode)
    }

    private func move(from source: IndexSet, to destination: Int) {
        order.move(fromOffsets: source, toOffset: destination)
        TrendsLayoutStorage.saveOrder(order)
    }
}

// MARK: - Preview

#Preview("Trends Layout") {
    NavigationStack {
        TrendsLayoutSettingsView()
    }
    .preferredColorScheme(.dark)
}
