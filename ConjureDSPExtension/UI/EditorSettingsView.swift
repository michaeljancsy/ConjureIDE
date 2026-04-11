import SwiftUI

struct EditorSettingsView: View {
    @AppStorage("editorTheme") private var selectedTheme: String = "conjuredsp"

    private static let themes: [(id: String, name: String)] = [
        ("auto", "Auto (System)"),
        ("conjuredsp", "ConjureDSP"),
        ("vs", "Light"),
        ("vs-dark", "Dark"),
        ("monokai", "Monokai"),
        ("dracula", "Dracula"),
        ("solarized-dark", "Solarized Dark"),
        ("solarized-light", "Solarized Light"),
        ("one-dark", "One Dark"),
        ("github-dark", "GitHub Dark"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Editor")
                .font(.headline)

            Picker("Theme", selection: $selectedTheme) {
                ForEach(Self.themes, id: \.id) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            .pickerStyle(.menu)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
