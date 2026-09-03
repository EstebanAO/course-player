import SwiftUI
import AVKit

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        NavigationSplitView {
            LibrarySidebar()
                .navigationSplitViewColumnWidth(min: 245, ideal: 300, max: 420)
        } detail: {
            if library.selectedItem == nil {
                WelcomeView()
            } else {
                HSplitView {
                    PlayerPane()
                        .frame(minWidth: 430)
                    NotesPane()
                        .frame(minWidth: 330)
                }
            }
        }
        .navigationTitle("Course Player")
    }
}

private struct LibrarySidebar: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                AppLogo(size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MI BIBLIOTECA").font(.caption.bold()).foregroundStyle(.secondary)
                    Text("\(library.completedVideos) de \(library.totalVideos) completados")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { library.scan() } label: {
                    Image(systemName: library.isScanning ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                }
                .buttonStyle(.plain).help("Actualizar biblioteca")
            }
            .padding(12)

            ProgressView(value: library.totalVideos == 0 ? 0 : Double(library.completedVideos) / Double(library.totalVideos))
                .padding(.horizontal, 12).padding(.bottom, 9)

            Divider()

            if library.searchText.isEmpty {
                List {
                    ForEach(library.items) { item in LibraryRow(item: item) }
                }
                .listStyle(.sidebar)
            } else {
                List(library.filteredItems) { item in
                    Button { library.select(item) } label: { LeafLabel(item: item) }
                        .buttonStyle(.plain)
                }
                .listStyle(.sidebar)
            }
        }
        .searchable(text: $library.searchText, prompt: "Buscar curso o video")
        .toolbar {
            ToolbarItem {
                Button { library.chooseLibrary() } label: { Image(systemName: "folder.badge.gearshape") }
                    .help("Elegir otra biblioteca")
            }
        }
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var library: LibraryModel
    let item: LibraryItem

    var body: some View {
        if item.kind == .folder {
            DisclosureGroup {
                ForEach(item.children ?? []) { child in LibraryRow(item: child) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "books.vertical.fill").foregroundStyle(.orange)
                    Text(item.name).lineLimit(2)
                    Spacer(minLength: 4)
                    let value = library.progressForCourse(item)
                    if value > 0 { Text("\(Int(value * 100))%").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        } else {
            Button { library.select(item) } label: { LeafLabel(item: item) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Abrir archivo original") { NSWorkspace.shared.open(item.url) }
                }
        }
    }
}

private struct LeafLabel: View {
    @EnvironmentObject private var library: LibraryModel
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 7) {
            if item.kind == .video {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .help(statusHelp)
            }
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).lineLimit(2)
                if !library.searchText.isEmpty {
                    Text(item.relativePath).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 2)
        }
        .contentShape(Rectangle())
    }

    private var isDone: Bool { item.kind == .video && library.isCompleted(item) }
    private var fraction: Double { library.progressFraction(for: item) }
    private var statusColor: Color {
        if isDone { return .green }
        if fraction > 0 { return .orange }
        return .secondary.opacity(0.35)
    }
    private var statusHelp: String {
        if isDone { return "Completado" }
        if fraction > 0 { return "En progreso: \(Int(fraction * 100))%" }
        return "Sin comenzar"
    }
    private var icon: String {
        switch item.kind {
        case .video: return "play.rectangle"
        case .audio: return "waveform"
        case .document: return "doc.text"
        default: return "doc"
        }
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var library: LibraryModel
    var body: some View {
        VStack(spacing: 18) {
            AppLogo(size: 108)
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
            Text("Tu espacio de estudio").font(.largeTitle.bold())
            Text("Elige un video en la barra lateral para comenzar.\nTu avance y tus notas se guardan automáticamente.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 24) {
                Label("\(library.totalVideos) videos", systemImage: "play.rectangle")
                Label("Notas Markdown", systemImage: "doc.plaintext")
                Label("Progreso automático", systemImage: "checkmark.circle")
            }.foregroundStyle(.secondary)
            Button("Elegir otra carpeta…") { library.chooseLibrary() }
        }
        .padding(40)
    }
}

private struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Course Player")
    }
}

private struct PlayerPane: View {
    @EnvironmentObject private var library: LibraryModel
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                VideoPlayer(player: library.player)
                VStack(spacing: 0) {
                    Color.clear
                        .contentShape(Rectangle())
                        .onTapGesture { library.togglePlayback() }
                        .help(library.isPlaying ? "Pausar" : "Reproducir")
                    Color.clear
                        .frame(height: 64)
                        .allowsHitTesting(false)
                }
                if library.isPreparingVideo {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Preparando el video…").font(.headline).foregroundStyle(.white)
                        Text("Solo ocurre la primera vez que abres este archivo.")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(24).background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            VStack(spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(library.selectedItem?.name ?? "").font(.headline).lineLimit(1)
                        Text(library.selectedItem?.relativePath ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { library.toggleCompleted() } label: {
                        Label(library.selectedProgress.completed ? "Completado" : "Marcar completo",
                              systemImage: library.selectedProgress.completed ? "checkmark.circle.fill" : "circle")
                    }
                    .buttonStyle(.bordered)
                    .tint(library.selectedProgress.completed ? .green : .accentColor)
                }

                HStack(spacing: 12) {
                    Text(library.displayTime(library.currentTime)).font(.caption.monospacedDigit()).frame(width: 54, alignment: .trailing)
                    Slider(value: Binding(get: { library.currentTime }, set: { value in
                        library.player.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                        library.currentTime = value
                    }), in: 0...max(library.duration, 1))
                    Text(library.displayTime(library.duration)).font(.caption.monospacedDigit()).frame(width: 54, alignment: .leading)
                }

                HStack(spacing: 14) {
                    Button { library.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }.buttonStyle(.plain)
                    Button { library.togglePlayback() } label: {
                        Image(systemName: library.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 34))
                    }.buttonStyle(.plain)
                    Button { library.skip(seconds: 15) } label: { Image(systemName: "goforward.15") }.buttonStyle(.plain)
                    Spacer()
                    Menu {
                        ForEach(rates, id: \.self) { rate in
                            Button { library.setRate(rate) } label: {
                                if library.playbackRate == rate { Label("\(rate.formatted())×", systemImage: "checkmark") }
                                else { Text("\(rate.formatted())×") }
                            }
                        }
                    } label: { Text("\(library.playbackRate.formatted())×").monospacedDigit().frame(minWidth: 42) }
                    .menuStyle(.borderlessButton)
                    Button { library.openSelectedExternally() } label: { Image(systemName: "arrow.up.forward.app") }
                        .buttonStyle(.plain).help("Abrir archivo original")
                }
                if !library.statusMessage.isEmpty && library.statusMessage != "Listo" {
                    Text(library.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.bar)
        }
    }
}

private struct NotesPane: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var formatCommand: MarkdownFormatCommand?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Notas del video", systemImage: "square.and.pencil").font(.headline)
                Spacer()
                Button { library.addImageToNote() } label: { Image(systemName: "photo.badge.plus") }
                    .buttonStyle(.plain).help("Agregar imagen a la nota")
                Button { library.revealNote() } label: { Image(systemName: "folder") }
                    .buttonStyle(.plain).help("Mostrar archivo .md en Finder")
            }
            .padding(12).background(.bar)
            Divider()
            HStack(spacing: 12) {
                Menu {
                    Button("Título 1") { format(.heading1) }
                    Button("Título 2") { format(.heading2) }
                    Button("Título 3") { format(.heading3) }
                    Divider()
                    Button("Texto normal") { format(.body) }
                } label: {
                    Image(systemName: "textformat.size")
                }
                .menuStyle(.borderlessButton).help("Título o texto normal")
                formatButton(.bold, icon: "bold", help: "Negrita")
                formatButton(.italic, icon: "italic", help: "Cursiva")
                formatButton(.underline, icon: "underline", help: "Subrayado")
                formatButton(.highlight, icon: "highlighter", help: "Marcatextos")
                formatButton(.strikethrough, icon: "strikethrough", help: "Tachado")
                formatButton(.bulletList, icon: "list.bullet", help: "Lista con viñetas (-)")
                formatButton(.numberedList, icon: "list.number", help: "Lista numerada")
                formatButton(.divider, icon: "minus", help: "Línea divisora")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            LiveMarkdownEditor(
                text: Binding(get: { library.noteText }, set: { library.setNoteText($0) }),
                baseURL: library.selectedNoteFolder,
                onPasteImage: { library.savePastedImage($0) },
                formatCommand: formatCommand
            )
        }
    }

    private func format(_ style: MarkdownFormatStyle) {
        formatCommand = MarkdownFormatCommand(style: style)
    }

    private func formatButton(_ style: MarkdownFormatStyle, icon: String, help: String) -> some View {
        Button { format(style) } label: { Image(systemName: icon) }
            .buttonStyle(.plain)
            .help(help)
    }
}
