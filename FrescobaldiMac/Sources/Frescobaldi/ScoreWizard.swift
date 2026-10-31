import AppKit
import FrescobaldiCore
import SwiftUI

/// File > New Score…: choose the players, key, time, titles and layout, and
/// get a project folder laid out for entering music (see ProjectTemplate).
final class ScoreWizardWindowController: NSWindowController, NSWindowDelegate {
    private static var current: ScoreWizardWindowController?

    static func show() {
        let controller = current ?? ScoreWizardWindowController()
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private let model = ScoreWizardModel()
    private var themeObserver: Any?

    /// The same appearance and window color as the document windows.
    private func applyTheme() {
        let theme = EditorTheme.current
        window?.appearance = theme.appearance
        window?.backgroundColor = theme.chrome ?? .windowBackgroundColor
    }

    private init() {
        let hosting = NSHostingController(rootView: ScoreWizardView(model: model))
        hosting.sizingOptions = [.minSize]
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .resizable]
        window.title = "New Score"
        window.setContentSize(NSSize(width: 1000, height: 660))
        window.setFrameAutosaveName("ScoreWizard")
        super.init(window: window)
        window.delegate = self
        if !window.setFrameUsingName("ScoreWizard") { window.center() }
        applyTheme()
        themeObserver = NotificationCenter.default.addObserver(forName: Preferences.didChange, object: nil,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        model.onCancel = { [weak self] in self?.close() }
        model.onCreate = { [weak self] in self?.chooseFolder() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        model.preview.stop()
        if let themeObserver { NotificationCenter.default.removeObserver(themeObserver) }
        Self.current = nil
    }

    private func chooseFolder() {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.title = "New Score"
        panel.message = "The project folder gets the score, the music in one file per player, and the parts."
        panel.nameFieldLabel = "Project:"
        let title = model.spec.title.trimmingCharacters(in: .whitespaces)
        panel.nameFieldStringValue = title.isEmpty ? "Untitled Score" : title
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.create(at: folder)
        }
    }

    private func create(at folder: URL) {
        do {
            let main = try ProjectTemplate.write(model.spec, to: folder, version: AppDelegate.shared.lilypondVersion)
            model.remember()
            // Show the new project's files.
            UserDefaults.standard.set("project", forKey: "sidebarMode")
            NSDocumentController.shared.openDocument(withContentsOf: main, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
            close()
        } catch {
            if let window { NSApp.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
        }
    }
}

// MARK: - Model

@MainActor
final class ScoreWizardModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case ensemble, music, titles, layout
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .ensemble: "Ensemble"
            case .music: "Music"
            case .titles: "Titles"
            case .layout: "Layout"
            }
        }
    }

    @Published var spec: ScoreSpec
    @Published var step: Step = .ensemble
    let preview = ScorePreview()
    var onCancel: () -> Void = {}
    var onCreate: () -> Void = {}

    init() {
        var spec = ScoreSpec(ensemble: Ensemble.named("piano")!)
        spec.paperSize = Locale.current.measurementSystem == .us ? "letter" : "a4"
        Remembered.load(into: &spec)
        self.spec = spec
    }

    /// The preset these players are, if they are one.
    var preset: Ensemble? {
        let instruments = spec.players.map(\.instrument)
        return Ensemble.all.first { $0.instruments == instruments }
    }

    func choose(_ ensemble: Ensemble) {
        spec.apply(ensemble)
    }

    // MARK: My Ensembles

    /// An ensemble the user saved, with its players' names.
    struct SavedEnsemble: Codable, Hashable, Identifiable {
        var name: String
        var players: [Player]
        var grouping: Grouping
        var instrumentNames: InstrumentNames
        var makeParts: Bool
        var id: String { name }

        func matches(_ spec: ScoreSpec) -> Bool {
            grouping == spec.grouping && players.map { [$0.instrument, $0.name ?? ""] }
                == spec.players.map { [$0.instrument, $0.name ?? ""] }
        }
    }

    private static let savedKey = "scoreWizardEnsembles"

    @Published private(set) var saved: [SavedEnsemble] = {
        guard let data = UserDefaults.standard.data(forKey: savedKey) else { return [] }
        return (try? JSONDecoder().decode([SavedEnsemble].self, from: data)) ?? []
    }()

    var savedMatch: SavedEnsemble? { saved.first { $0.matches(spec) } }

    /// Saves the players as `name`, replacing one of that name.
    func saveEnsemble(as name: String) {
        let ensemble = SavedEnsemble(name: name, players: spec.players, grouping: spec.grouping,
                                     instrumentNames: spec.instrumentNames, makeParts: spec.makeParts)
        saved.removeAll { $0.name == name }
        saved.append(ensemble)
        saved.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        storeSaved()
    }

    func deleteEnsemble(_ ensemble: SavedEnsemble) {
        saved.removeAll { $0.name == ensemble.name }
        storeSaved()
    }

    func choose(_ ensemble: SavedEnsemble) {
        // Fresh players, so ids stay unique.
        spec.players = ensemble.players.map { Player(instrument: $0.instrument, name: $0.name) }
            .filter { Instrument.named($0.instrument) != nil }
        spec.grouping = ensemble.grouping
        spec.instrumentNames = ensemble.instrumentNames
        spec.makeParts = ensemble.makeParts
        spec.hideEmptyStaves = nil
        spec.scoreStaffSize = nil
    }

    private func storeSaved() {
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: Self.savedKey) }
    }

    /// Adds a player in score order; returns its id.
    @discardableResult
    func add(_ instrument: Instrument) -> Player.ID {
        let player = Player(instrument: instrument.id)
        spec.players.insert(player, at: spec.insertionIndex(for: instrument))
        // A solo piano has no instrument names; an ensemble does.
        if spec.instrumentNames == .none && spec.playedCount > 1 { spec.instrumentNames = .fullThenShort }
        return player.id
    }

    var summary: String {
        var parts = ["\(spec.staffCount) \(spec.staffCount == 1 ? "staff" : "staves")", spec.key.title, spec.time.title]
        if spec.hasParts { parts.append("\(spec.playedCount) parts") }
        return parts.joined(separator: " · ")
    }

    func remember() { Remembered.save(spec) }

    /// The choices people make once and keep: their name, pitch names, paper,
    /// and the last ensemble.
    private enum Remembered {
        static let key = "scoreWizard"

        struct Values: Codable {
            var players: [Player]
            var grouping: Grouping
            var composer: String
            var language: String
            var entry: String
            var concertPitch: Bool
            var transposedScore: Bool
            var paperSize: String
            var tagline: Bool
            var midi: Bool
        }

        static func load(into spec: inout ScoreSpec) {
            guard let data = UserDefaults.standard.data(forKey: key),
                  let values = try? JSONDecoder().decode(Values.self, from: data) else { return }
            let players = values.players.filter { Instrument.named($0.instrument) != nil }
            if !players.isEmpty {
                if let ensemble = Ensemble.all.first(where: { $0.instruments == players.map(\.instrument) }) {
                    spec.apply(ensemble)
                } else {
                    spec.instrumentNames = .fullThenShort
                    spec.makeParts = true
                }
                spec.players = players
                spec.grouping = values.grouping
            }
            spec.composer = values.composer
            spec.language = PitchLanguage(rawValue: values.language) ?? spec.language
            spec.entry = EntryMode(rawValue: values.entry) ?? spec.entry
            spec.concertPitch = values.concertPitch
            spec.transposedScore = values.transposedScore
            spec.paperSize = values.paperSize
            spec.tagline = values.tagline
            spec.midi = values.midi
        }

        static func save(_ spec: ScoreSpec) {
            let values = Values(players: spec.players, grouping: spec.grouping, composer: spec.composer,
                                language: spec.language.rawValue, entry: spec.entry.rawValue,
                                concertPitch: spec.concertPitch, transposedScore: spec.transposedScore,
                                paperSize: spec.paperSize, tagline: spec.tagline, midi: spec.midi)
            if let data = try? JSONEncoder().encode(values) { UserDefaults.standard.set(data, forKey: key) }
        }
    }
}

// MARK: - Views

struct ScoreWizardView: View {
    @ObservedObject var model: ScoreWizardModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("Step", selection: $model.step) {
                ForEach(ScoreWizardModel.Step.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(.vertical, 10)
            Divider()
            HStack(spacing: 0) {
                Group {
                    switch model.step {
                    case .ensemble: EnsembleStep(model: model)
                    case .music: MusicStep(spec: $model.spec)
                    case .titles: TitlesStep(spec: $model.spec)
                    case .layout: LayoutStep(spec: $model.spec)
                    }
                }
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScorePreviewPane(preview: model.preview)
            }
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { model.onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(model.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Back") { move(-1) }
                    .disabled(model.step == .ensemble)
                // Not on Return, which finishes typing a name or title.
                if model.step != .layout {
                    Button("Next") { move(1) }
                }
                Button("Create…") { model.onCreate() }
                    .keyboardShortcut(model.step == .layout ? .defaultAction : nil)
                    .disabled(model.spec.players.isEmpty || !model.spec.time.isValid)
                    .help(model.spec.players.isEmpty ? "Add at least one instrument." : "Choose where to create the project.")
            }
            .padding(12)
        }
        .frame(minWidth: 900, minHeight: 580)
        .themedBackground()
        .onChange(of: model.spec, initial: true) { _, spec in model.preview.update(spec) }
    }

    private func move(_ offset: Int) {
        if let step = ScoreWizardModel.Step(rawValue: model.step.rawValue + offset) { model.step = step }
    }
}

// MARK: Ensemble

private struct EnsembleStep: View {
    @ObservedObject var model: ScoreWizardModel
    @State private var selection: Set<Player.ID> = []
    @State private var naming = false
    @State private var newName = ""

    private static let savedPrefix = "saved:"

    var body: some View {
        HStack(spacing: 0) {
            List(selection: presetSelection) {
                ForEach(Ensemble.Category.allCases, id: \.self) { category in
                    Section(category.title) {
                        ForEach(Ensemble.all.filter { $0.category == category }) { ensemble in
                            Text(ensemble.title).tag(ensemble.id)
                        }
                    }
                }
                if !model.saved.isEmpty {
                    Section("My Ensembles") {
                        ForEach(model.saved) { ensemble in
                            Text(ensemble.name)
                                .tag(Self.savedPrefix + ensemble.name)
                                .contextMenu {
                                    Button("Delete “\(ensemble.name)”") { model.deleteEnsemble(ensemble) }
                                }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 220)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.preset?.title ?? model.savedMatch?.name ?? "Custom Ensemble")
                        .font(.title3)
                        .fontDesign(.serif)
                    Spacer()
                    Text("Drag to reorder. Click a name to rename a player.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                playerList
                HStack(spacing: 6) {
                    addMenu
                    Button {
                        remove(selection)
                    } label: {
                        Image(systemName: "minus")
                            .frame(width: 16, height: 16)
                    }
                    .help("Remove the selected players")
                    .disabled(selection.isEmpty)
                    Button("Save Ensemble…") {
                        newName = model.savedMatch?.name ?? ""
                        naming = true
                    }
                    .disabled(model.spec.players.isEmpty)
                    .help("Keep these players under My Ensembles, to start other scores with")
                    Spacer()
                    Picker("Brackets:", selection: $model.spec.grouping) {
                        ForEach(Grouping.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    .help("Brackets join the staves of a section, such as the strings.")
                }
            }
            .padding(14)
        }
        .alert("Save Ensemble", isPresented: $naming) {
            TextField("Name", text: $newName)
            Button("Save") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.saveEnsemble(as: name) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The players, their names and the brackets are kept under My Ensembles. Right-click one there to delete it.")
        }
    }

    private var presetSelection: Binding<String?> {
        Binding(get: { model.preset?.id ?? model.savedMatch.map { Self.savedPrefix + $0.name } },
                set: { id in
                    guard let id else { return }
                    if id.hasPrefix(Self.savedPrefix) {
                        let name = String(id.dropFirst(Self.savedPrefix.count))
                        if let ensemble = model.saved.first(where: { $0.name == name }) { model.choose(ensemble) }
                    } else if let ensemble = Ensemble.named(id) {
                        model.choose(ensemble)
                    }
                    selection = []
                })
    }

    private var playerList: some View {
        let resolved = model.spec.resolvedPlayers
        return List(selection: $selection) {
            ForEach(Array(model.spec.players.enumerated()), id: \.element.id) { index, player in
                if index < resolved.count {
                    PlayerRow(resolved: resolved[index], name: nameBinding(player.id))
                }
            }
            .onMove { model.spec.players.move(fromOffsets: $0, toOffset: $1) }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .onDeleteCommand { remove(selection) }
        .overlay {
            if model.spec.players.isEmpty {
                Text("Add instruments with the + menu below, or choose an ensemble.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func nameBinding(_ id: Player.ID) -> Binding<String> {
        Binding(get: { model.spec.players.first { $0.id == id }?.name ?? "" },
                set: { name in
                    if let index = model.spec.players.firstIndex(where: { $0.id == id }) {
                        model.spec.players[index].name = name.isEmpty ? nil : name
                    }
                })
    }

    private var addMenu: some View {
        Menu {
            ForEach(Instrument.Family.allCases, id: \.self) { family in
                Menu(family.title) {
                    ForEach(Instrument.all.filter { $0.family == family }) { instrument in
                        Button(instrument.menuTitle) { selection = [model.add(instrument)] }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add an instrument")
    }

    private func remove(_ ids: Set<Player.ID>) {
        model.spec.players.removeAll { ids.contains($0.id) }
        selection = []
    }
}

private struct PlayerRow: View {
    let resolved: ResolvedPlayer
    @Binding var name: String

    var body: some View {
        HStack {
            TextField("Name", text: shown)
                .textFieldStyle(.plain)
            Spacer()
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// The numbered name ("Violin II") unless the user gave another; clearing
    /// the field brings it back.
    private var shown: Binding<String> {
        Binding(get: { name.isEmpty ? resolved.numberedName : name },
                set: { name = $0 == resolved.numberedName ? "" : $0 })
    }

    /// The instrument when renamed; otherwise what kind of staff it gets.
    private var detail: String {
        if !name.isEmpty { return resolved.instrument.menuTitle }
        switch resolved.instrument.kind {
        case .grand: return "Two staves"
        case .organ: return "Manuals and pedals"
        case .voice: return "With lyrics"
        case .drums: return "Drum staff"
        case .percussion: return "One-line staff"
        case .tablature: return "Staff and tablature"
        case .chordNames: return "Chord symbols"
        case .single: return resolved.instrument.family.title
        }
    }
}

// MARK: Music

private struct MusicStep: View {
    @Binding var spec: ScoreSpec
    @State private var customTime = false

    var body: some View {
        Form {
            Section("Key and Time") {
                LabeledContent("Key") {
                    HStack {
                        Picker("Key", selection: $spec.key) {
                            ForEach(KeySignature.keys(spec.key.mode), id: \.self) { key in
                                Text(key.tonic.displayName + accidentals(key.fifths)).tag(key)
                            }
                        }
                        .labelsHidden()
                        Picker("Mode", selection: mode) {
                            ForEach(KeySignature.Mode.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                    }
                    .fixedSize()
                }
                Picker("Time signature", selection: time) {
                    ForEach(TimeSignature.common, id: \.self) { Text($0.title).tag(TimeSignature?.some($0)) }
                    Divider()
                    Text("Other").tag(TimeSignature?.none)
                }
                if customTime || !TimeSignature.common.contains(spec.time) {
                    LabeledContent("Other") {
                        HStack {
                            Stepper("\(spec.time.numerator)", value: numerator, in: 1...32)
                            Text("/")
                            Picker("Beat", selection: denominator) {
                                ForEach([1, 2, 4, 8, 16, 32], id: \.self) { Text("\($0)").tag($0) }
                            }
                            .labelsHidden()
                        }
                        .fixedSize()
                    }
                }
                Picker("Pickup", selection: $spec.pickup) {
                    Text("None").tag(String?.none)
                    ForEach(TimeSignature.pickups.filter { spec.time.fits(pickup: $0) }, id: \.self) {
                        Text(durationName($0)).tag(String?.some($0))
                    }
                }
                Stepper("Empty bars to start with: \(spec.bars)", value: $spec.bars, in: 1...64)
            }

            Section("Tempo") {
                TextField("Tempo", text: $spec.tempo.text, prompt: Text("Allegro"))
                Toggle("Metronome mark", isOn: metronome)
                if let beat = spec.tempo.beat {
                    LabeledContent("Beat") {
                        HStack {
                            Picker("Beat", selection: Binding(get: { beat }, set: { spec.tempo.beat = $0 })) {
                                ForEach(["2", "2.", "4", "4.", "8", "8."], id: \.self) { Text(durationName($0)).tag($0) }
                            }
                            .labelsHidden()
                            Text("=")
                            TextField("Beats per minute", value: $spec.tempo.bpm, format: .number)
                                .labelsHidden()
                                .frame(width: 50)
                            Stepper("Beats per minute", value: $spec.tempo.bpm, in: 20...300)
                                .labelsHidden()
                        }
                        .fixedSize()
                    }
                }
            }

            Section {
                Picker("Pitch names", selection: $spec.language) {
                    ForEach(PitchLanguage.allCases) { Text($0.title).tag($0) }
                }
                Picker("Octaves", selection: $spec.entry) {
                    ForEach(EntryMode.allCases) { Text($0.title).tag($0) }
                }
                if spec.hasKeyTransposingInstruments {
                    Picker("Transposing instruments", selection: $spec.concertPitch) {
                        Text("Enter at concert pitch").tag(true)
                        Text("Enter as written").tag(false)
                    }
                    Picker("Full score", selection: $spec.transposedScore) {
                        Text("Transposed").tag(true)
                        Text("In C (as it sounds)").tag(false)
                    }
                    .disabled(!spec.concertPitch)
                }
            } header: {
                Text("Note Entry")
            } footer: {
                if spec.hasKeyTransposingInstruments {
                    Text(spec.concertPitch
                         ? "You write what sounds; the parts are transposed for the players."
                         : "You write what the players read, as when copying from printed parts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var mode: Binding<KeySignature.Mode> {
        Binding(get: { spec.key.mode },
                set: { mode in
                    let key = KeySignature(tonic: spec.key.tonic, mode: mode)
                    spec.key = abs(key.fifths) <= 7 ? key : KeySignature.keys(mode)[7]
                })
    }

    private var time: Binding<TimeSignature?> {
        Binding(get: { customTime || !TimeSignature.common.contains(spec.time) ? nil : spec.time },
                set: { time in
                    if let time {
                        customTime = false
                        setTime(time)
                    } else {
                        customTime = true
                    }
                })
    }

    private var numerator: Binding<Int> {
        Binding(get: { spec.time.numerator }, set: { setTime(TimeSignature($0, spec.time.denominator)) })
    }

    private var denominator: Binding<Int> {
        Binding(get: { spec.time.denominator }, set: { setTime(TimeSignature(spec.time.numerator, $0)) })
    }

    private func setTime(_ time: TimeSignature) {
        spec.time = time
        if spec.tempo.beat != nil { spec.tempo.beat = time.beat }
        if let pickup = spec.pickup, !time.fits(pickup: pickup) { spec.pickup = nil }
    }

    private var metronome: Binding<Bool> {
        Binding(get: { spec.tempo.beat != nil }, set: { spec.tempo.beat = $0 ? spec.time.beat : nil })
    }

    private func accidentals(_ fifths: Int) -> String {
        fifths == 0 ? "" : "  (\(abs(fifths))\(fifths > 0 ? "♯" : "♭"))"
    }

    private func durationName(_ duration: String) -> String {
        let names = ["1": "Whole", "2": "Half", "4": "Quarter", "8": "Eighth", "16": "Sixteenth"]
        let base = names[duration.filter(\.isNumber)] ?? duration
        return duration.hasSuffix(".") ? "Dotted \(base.lowercased())" : base
    }
}

// MARK: Titles

private struct TitlesStep: View {
    @Binding var spec: ScoreSpec

    var body: some View {
        Form {
            Section {
                TextField("Title", text: $spec.title, prompt: Text("The project's name"))
                TextField("Subtitle", text: $spec.subtitle)
                TextField("Dedication", text: $spec.dedication)
            }
            Section {
                TextField("Composer", text: $spec.composer)
                TextField("Arranger", text: $spec.arranger)
                TextField("Poet", text: $spec.poet, prompt: Text("Author of the words"))
                TextField("Opus", text: $spec.opus, prompt: Text("Op. 1"))
            }
            Section {
                TextField("Copyright", text: $spec.copyright, prompt: Text("© 2026 Your Name"))
                Toggle("“Music engraving by LilyPond” at the end", isOn: $spec.tagline)
            } footer: {
                Text("The titles go in header.ily, which the score and the parts share.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

// MARK: Layout

private struct LayoutStep: View {
    @Binding var spec: ScoreSpec

    private static let papers = [("a4", "A4"), ("letter", "Letter"), ("a3", "A3"), ("tabloid", "Tabloid (11 × 17 in)"),
                                 ("b4", "B4"), ("legal", "Legal")]

    var body: some View {
        Form {
            Section("Paper") {
                Picker("Size", selection: $spec.paperSize) {
                    ForEach(Self.papers, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Orientation", selection: $spec.landscape) {
                    Text("Portrait").tag(false)
                    Text("Landscape").tag(true)
                }
                .pickerStyle(.segmented)
            }

            Section("Score") {
                Picker("Staff size", selection: $spec.scoreStaffSize) {
                    Text("Automatic (\(automaticSize))").tag(Int?.none)
                    Divider()
                    ForEach(12...24, id: \.self) { Text("\($0)").tag(Int?.some($0)) }
                }
                Picker("Instrument names", selection: $spec.instrumentNames) {
                    ForEach(InstrumentNames.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Hide staves with only rests after the first system", isOn: hideEmpty)
                Toggle("MIDI file, with repeats played out", isOn: $spec.midi)
            }

            Section {
                Toggle("A part for each player", isOn: $spec.makeParts)
                    .disabled(spec.playedCount < 2)
                Picker("Staff size", selection: $spec.partStaffSize) {
                    ForEach(16...24, id: \.self) { Text("\($0)").tag($0) }
                }
                .disabled(!spec.hasParts)
            } header: {
                Text("Parts")
            } footer: {
                Text("Staff sizes are in points: 20 is LilyPond's default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var automaticSize: Int {
        var automatic = spec
        automatic.scoreStaffSize = nil
        return automatic.effectiveScoreStaffSize
    }

    private var hideEmpty: Binding<Bool> {
        Binding(get: { spec.effectiveHideEmptyStaves }, set: { spec.hideEmptyStaves = $0 })
    }
}
