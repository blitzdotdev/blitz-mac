import SwiftUI
import Charts

struct AnalyticsView: View {
    var appState: AppState

    private var asc: ASCManager { appState.ascManager }
    @State private var dateRange: DateRange = .last30Days

    enum DateRange: String, CaseIterable {
        case last7Days = "7 Days"
        case last30Days = "30 Days"
        case last90Days = "90 Days"
    }

    var body: some View {
        ASCCredentialGate(
            ascManager: asc,
            projectId: appState.activeProjectId ?? "",
            bundleId: appState.activeProject?.metadata.bundleIdentifier
        ) {
            ASCTabContent(asc: asc, tab: .analytics, platform: appState.activeProject?.platform ?? .iOS) {
                analyticsContent
            }
        }
        .task(id: appState.activeProjectId) { await asc.ensureTabData(.analytics) }
    }

    @ViewBuilder
    private var analyticsContent: some View {
        let hasVendor = asc.app?.vendorNumber != nil

        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    Text("Analytics")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    Picker("Range", selection: $dateRange) {
                        ForEach(DateRange.allCases, id: \.self) {
                            Text($0.rawValue).tag($0)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                    ASCTabRefreshButton(asc: asc, tab: .analytics, helpText: "Refresh analytics tab")
                }

                if !hasVendor {
                    vendorNumberNotice
                } else {
                    salesReportsNotice
                }

                // Placeholder chart with mock data to illustrate layout
                VStack(alignment: .leading, spacing: 12) {
                    Text("Downloads (sample)")
                        .font(.headline)

                    Chart(mockDownloadData(for: dateRange)) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Downloads", point.value)
                        )
                        .foregroundStyle(.blue)

                        AreaMark(
                            x: .value("Date", point.date),
                            y: .value("Downloads", point.value)
                        )
                        .foregroundStyle(.blue.opacity(0.1))
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .day, count: dateRange == .last7Days ? 1 : dateRange == .last30Days ? 5 : 15)) {
                            AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        }
                    }
                    .chartYAxis {
                        AxisMarks { value in
                            AxisValueLabel()
                            AxisGridLine()
                        }
                    }
                    .frame(height: 200)

                    Text("Sample data only — connect sales reports for live data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(.background.secondary)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .padding(24)
        }
    }

    private var vendorNumberNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Sales Reports Require Vendor Number")
                    .font(.callout.weight(.medium))
                Text("Your app's vendor number is not available. This is typically shown on the Payments and Financial Reports page in App Store Connect.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var salesReportsNotice: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundStyle(.blue)
                .font(.title3)
            VStack(alignment: .leading, spacing: 4) {
                Text("Live Sales Data Coming Soon")
                    .font(.callout.weight(.medium))
                Text("Sales report fetching via the ASC API is in development. The chart above shows sample data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private struct DataPoint: Identifiable {
        let id = UUID()
        let date: Date
        let value: Int
    }

    private func mockDownloadData(for range: DateRange) -> [DataPoint] {
        let days: Int
        switch range {
        case .last7Days: days = 7
        case .last30Days: days = 30
        case .last90Days: days = 90
        }
        let calendar = Calendar.current
        var result: [DataPoint] = []
        for i in stride(from: days - 1, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -i, to: Date()) else { continue }
            // Deterministic mock value based on day of year
            let seed = calendar.ordinality(of: .day, in: .year, for: date) ?? 1
            let value = 50 + (seed * 17 % 200)
            result.append(DataPoint(date: date, value: value))
        }
        return result
    }
}
