import SwiftUI

/// Visual language: dark editing surface, single coral accent, compact controls.
enum Theme {
    static let background = Color(red: 0.055, green: 0.055, blue: 0.065)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.125)
    static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.18)
    static let stroke = Color.white.opacity(0.08)
    static let accent = Color(red: 1.0, green: 0.235, blue: 0.38)
    static let accentSoft = Color(red: 1.0, green: 0.235, blue: 0.38).opacity(0.18)
    static let secondaryText = Color.white.opacity(0.6)
    static let clipVideo = Color(red: 0.25, green: 0.45, blue: 0.95)
    static let clipAudio = Color(red: 0.2, green: 0.75, blue: 0.55)
    static let clipText = Color(red: 0.95, green: 0.6, blue: 0.2)
    static let clipCaption = Color(red: 0.7, green: 0.45, blue: 0.95)
}

struct ToolButton: View {
    let title: String
    let systemImage: String
    var isActive = false
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: systemImage)
                        .font(.system(size: 20, weight: .medium))
                        .frame(width: 44, height: 30)
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8, weight: .heavy))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Theme.accent, in: Capsule())
                            .offset(x: 8, y: -4)
                    }
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(isActive ? Theme.accent : .white)
            .frame(minWidth: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("tool.\(title)")
    }
}

struct PanelHeader: View {
    let title: String
    let onDone: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action: onDone) {
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 34, height: 34)
                    .background(Theme.accent, in: Circle())
                    .foregroundStyle(.white)
            }
            .accessibilityIdentifier("panel.done")
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}

struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double> = -1...1
    var format: (Double) -> String = { String(format: "%+.0f", $0 * 100) }

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.subheadline)
                .frame(width: 84, alignment: .leading)
            Slider(value: $value, in: range)
                .tint(Theme.accent)
                .accessibilityIdentifier("slider.\(title)")
            Text(format(value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 40, alignment: .trailing)
        }
    }
}

struct ChipButton: View {
    let title: String
    var isSelected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(isSelected ? Theme.accent : Theme.surfaceRaised, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("chip.\(title)")
    }
}

/// Small transient message ("Captions added", "Removed 3 pauses").
struct Toast: Equatable {
    var message: String
    var systemImage: String = "sparkles"
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().stroke(Theme.stroke))
            .accessibilityIdentifier("toast")
    }
}

/// Spinner overlay for on-device analysis.
struct BusyOverlay: View {
    let message: String
    var progress: Double?
    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress).tint(Theme.accent).frame(width: 160)
            } else {
                ProgressView().tint(.white).controlSize(.large)
            }
            Text(message).font(.subheadline.weight(.medium))
            Text("On device · Private").font(.caption).foregroundStyle(Theme.secondaryText)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityIdentifier("busy")
    }
}
