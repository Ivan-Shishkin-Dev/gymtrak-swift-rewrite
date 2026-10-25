import SwiftUI

/// The training week as seven plain-language rows. Tapping a row selects that day.
struct WeekListView: View {
    let week: ProgramWeek
    let days: [Day]
    let doneDates: Set<String>
    let todayKey: String
    let selected: Dow
    let onSelect: (Dow) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(Dow.allCases.enumerated()), id: \.element) { i, dow in
                if i > 0 { Rectangle().fill(Theme.separator).frame(height: 1).padding(.leading, 14) }
                row(dow)
            }
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.cardBorder))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private func row(_ dow: Dow) -> some View {
        let slot = week.slot(dow)
        let date = week.date(of: dow)
        let isToday = date == todayKey
        let isSel = dow == selected
        let done = doneDates.contains(date)
        let dayName = days.first { $0.id == slot?.liftDayId }?.name
        let run = slot?.run
        let rest = dayName == nil && run == nil

        return Button { onSelect(dow) } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(dow.short.uppercased()).font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    Text(DateKey.label(date, "d")).font(.system(size: 15, weight: .semibold)).monospacedDigit()
                }
                .frame(width: 34)
                .foregroundStyle(isToday ? Theme.volt : Theme.dim)

                if let dayName {
                    Image(systemName: "dumbbell.fill").font(.system(size: 11)).foregroundStyle(Theme.volt.opacity(rest ? 0 : 0.8))
                    Text(dayName).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                } else if let run {
                    Image(systemName: "figure.run").font(.system(size: 12)).foregroundStyle(Theme.run)
                    Text(run.label.rawValue).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.text)
                } else {
                    Text("Rest").font(.system(size: 15)).foregroundStyle(Theme.dim)
                }
                Spacer()
                if dayName != nil, let run {
                    Text("+ \(run.durationMin) min run").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.run)
                } else if let run {
                    Text("\(run.durationMin) min").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.run)
                }
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.volt)
                }
            }
            .padding(.leading, 14).padding(.trailing, 16).padding(.vertical, 12)
            .background(isSel ? Theme.voltTint : .clear)
            .overlay(alignment: .leading) {
                if isSel { Rectangle().fill(Theme.volt).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
