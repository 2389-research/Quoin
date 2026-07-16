import AppKit
import SwiftUI
import QuoinRender

/// The appearance preference: follow the system, or pin light/dark.
/// Persisted in UserDefaults ("QuoinAppearance") and applied to
/// `NSApp.appearance` at launch and on change.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// Applies this preference app-wide. The screenshot-automation pin
    /// (`-QuoinForceDarkMode`) wins over the stored preference so CI
    /// captures stay deterministic.
    static func applyStored() {
        guard !UserDefaults.standard.bool(forKey: "QuoinForceDarkMode") else {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            return
        }
        let stored = UserDefaults.standard.string(forKey: "QuoinAppearance") ?? ""
        NSApp.appearance = (AppAppearance(rawValue: stored) ?? .system).nsAppearance
    }
}

/// The Settings window (Quoin ▸ Settings…, ⌘,): the classic macOS tabbed
/// preferences layout. **General** holds the everyday appearance/editor
/// choices; **Advanced** is the home for power-user knobs — the "twiddly
/// bits" that most writers never touch but power users want.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettings()
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        // A fixed width keeps the window from resizing as you switch tabs.
        .frame(width: 480)
    }
}

/// General: appearance, code theme, launch behavior, review identity.
private struct GeneralSettings: View {
    @AppStorage("QuoinAppearance") private var appearanceRaw = AppAppearance.system.rawValue
    @AppStorage("QuoinShowStatusBar") private var showStatusBar = true
    @AppStorage("QuoinReviewerName") private var reviewerName = ""
    @AppStorage("QuoinLaunchBehavior") private var launchBehavior = "restore"
    @AppStorage("QuoinCodeTheme") private var codeTheme = "match"

    var body: some View {
        Form {
            Section {
                Picker("Appearance", selection: $appearanceRaw) {
                    ForEach(AppAppearance.allCases) { appearance in
                        Text(appearance.label).tag(appearance.rawValue)
                    }
                }
                .pickerStyle(.radioGroup)
                .horizontalRadioGroupLayout()
            } footer: {
                Text("The accent color follows System Settings.")
            }

            Section {
                Toggle("Show status bar", isOn: $showStatusBar)
            } footer: {
                Text("The current section and word count, at the foot of the window.")
            }

            Section {
                Picker("Code blocks", selection: $codeTheme) {
                    Text("Match Appearance").tag("match")
                    Divider()
                    ForEach(CodePalette.registry.filter(\.isDark)) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                    Divider()
                    ForEach(CodePalette.registry.filter { !$0.isDark }) { palette in
                        Text(palette.name).tag(palette.id)
                    }
                }
            } footer: {
                Text("The syntax theme for code blocks. Match Appearance pairs GitHub Light with Graphite.")
            }

            Section {
                Picker("When Quoin opens", selection: $launchBehavior) {
                    Text("Open the folders from last time").tag("restore")
                    Text("Start with an empty window").tag("empty")
                }
                .pickerStyle(.radioGroup)
            } footer: {
                Text("Each window remembers its own folder.")
            }

            Section {
                TextField("Review as", text: $reviewerName, prompt: Text(NSUserName()))
            } footer: {
                Text("Comments and suggestions you create are attributed to this name.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: appearanceRaw) {
            AppAppearance.applyStored()
        }
    }
}

/// Advanced: the twiddly bits — writing targets, update policy, and the home
/// for future rendering knobs.
private struct AdvancedSettings: View {
    @AppStorage("QuoinWordGoal") private var wordGoal = 0
    // Sparkle reads this exact defaults key (falling back to the Info.plist
    // value) for `automaticallyChecksForUpdates`, so binding a Toggle to it is
    // the whole integration — no Sparkle import needed here.
    @AppStorage("SUEnableAutomaticChecks") private var autoUpdateChecks = true

    var body: some View {
        Form {
            Section {
                LabeledContent("Word goal") {
                    HStack(spacing: 6) {
                        TextField("", value: $wordGoal, format: .number)
                            .frame(width: 64)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $wordGoal, in: 0...1_000_000, step: 50)
                            .labelsHidden()
                        Text(wordGoal == 0 ? "off" : "words")
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Writing")
            } footer: {
                Text("The status bar shows progress toward this target. Zero turns it off.")
            }

            Section {
                Toggle("Automatically check for updates", isOn: $autoUpdateChecks)
            } header: {
                Text("Updates")
            } footer: {
                Text("Quoin checks for a new version in the background — the only time it connects to the network. Use “Check for Updates…” in the Quoin menu to check now.")
            }
        }
        .formStyle(.grouped)
    }
}
