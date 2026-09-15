import SwiftUI

/// Hover detail. Milestone 1 renders counts only; session rows land in milestone 2.
struct PopoverView: View {
    let state: LightState

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // The menu bar lamps are ~5px when upright — too small to be the payoff.
            // This is where the stoplight is actually legible.
            upright

            VStack(alignment: .leading, spacing: 7) {
                Text(state.summary)
                    .font(.system(size: 13, weight: .semibold))

                ForEach(Lamp.allCases, id: \.self) { lamp in
                    HStack(spacing: 6) {
                        Text(lamp.label)
                            .font(.system(size: 11))
                            .foregroundStyle(state.count(lamp) > 0 ? .primary : .secondary)
                        Spacer(minLength: 10)
                        Text("\(state.count(lamp))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 150, alignment: .leading)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
    }

    private var upright: some View {
        VStack(spacing: 5) {
            ForEach(Lamp.allCases, id: \.self) { lamp in
                Circle()
                    .fill(Color(nsColor: state.count(lamp) > 0
                                ? StoplightIcon.litColor(lamp)
                                : StoplightIcon.unlitColor))
                    .frame(width: 22, height: 22)
            }
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: StoplightIcon.housingColor))
        )
    }
}
