import SwiftUI
import TabulaFoundation

extension ConnectionTag {
    var color: Color? {
        switch self {
        case .none: nil
        case .local: .gray
        case .development: .green
        case .staging: .orange
        case .production: .red
        }
    }
}

extension DatabaseKind {
    var symbol: String {
        switch self {
        case .postgres: "cylinder.split.1x2"
        case .mysql: "cylinder"
        case .sqlite: "doc.text"
        case .redis: "square.stack.3d.up"
        case .mongodb: "leaf"
        }
    }

    var badge: String {
        switch self {
        case .postgres: "Pg"
        case .mysql: "My"
        case .sqlite: "Sl"
        case .redis: "Re"
        case .mongodb: "Mg"
        }
    }

    var tint: Color {
        switch self {
        case .postgres: Color(red: 0.2, green: 0.4, blue: 0.7)
        case .mysql: Color(red: 0.0, green: 0.46, blue: 0.56)
        case .sqlite: Color(red: 0.3, green: 0.55, blue: 0.85)
        case .redis: Color(red: 0.84, green: 0.2, blue: 0.16)
        case .mongodb: Color(red: 0.0, green: 0.53, blue: 0.29)
        }
    }
}

struct KindBadge: View {
    let kind: DatabaseKind
    var size: CGFloat = 32

    var body: some View {
        Text(kind.badge)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(kind.tint.gradient, in: RoundedRectangle(cornerRadius: size * 0.25))
    }
}

/// Tabula's own mark: a stylized grid on a gradient tile.
struct AppMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 0.29, green: 0.36, blue: 0.95), Color(red: 0.55, green: 0.27, blue: 0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            VStack(spacing: size * 0.06) {
                RoundedRectangle(cornerRadius: size * 0.03).fill(.white).frame(height: size * 0.12)
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: size * 0.06) {
                        ForEach(0..<3, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: size * 0.02).fill(.white.opacity(0.55))
                                .frame(height: size * 0.08)
                        }
                    }
                }
            }
            .padding(size * 0.2)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.2), radius: size * 0.06, y: size * 0.03)
    }
}

extension View {
    /// Background for the thin filter, tab and status bars. A plain Color background spreads into the
    /// safe area, so a bar at the top would paint up under the toolbar; this one stays inside the bar.
    func barBackground() -> some View {
        background(Color(nsColor: .underPageBackgroundColor), ignoresSafeAreaEdges: [])
    }
}
