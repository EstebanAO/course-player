import SwiftUI
import AVKit
import PDFKit
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var library: LibraryModel
    @AppStorage("CoursePlayerNotesVisible") private var notesVisible = true

    var body: some View {
        VStack(spacing: 0) {
            if let issue = library.issue { IssueBanner(issue: issue) }
            NavigationSplitView {
                LibrarySidebar()
                    .navigationSplitViewColumnWidth(min: 245, ideal: 310, max: 440)
            } detail: {
                if library.selectedItem == nil {
                    WelcomeView()
                } else if notesVisible {
                    HSplitView {
                        PrimaryPane(notesVisible: $notesVisible)
                            .frame(minWidth: 430)
                        NotesPane().frame(minWidth: 330)
                    }
                } else {
                    PrimaryPane(notesVisible: $notesVisible)
                }
            }
        }
        .navigationTitle("Course Player")
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first else { return false }
            library.openLibrary(folder)
            return true
        }
    }
}

private struct PrimaryPane: View {
    @EnvironmentObject private var library: LibraryModel
    @Binding var notesVisible: Bool

    var body: some View {
        if library.selectedItem?.url.pathExtension.lowercased() == "pdf" {
            PDFPane(notesVisible: $notesVisible)
        } else {
            PlayerPane(notesVisible: $notesVisible)
        }
    }
}

private struct PDFPane: View {
    @EnvironmentObject private var library: LibraryModel
    @Binding var notesVisible: Bool
    @State private var pageCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if let item = library.selectedItem {
                PDFDocumentView(
                    url: item.url,
                    pageIndex: Binding(get: { library.documentPage }, set: { library.setDocumentPage($0) }),
                    onPageCountChanged: { pageCount = $0 }
                )
                Divider()
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline).lineLimit(1)
                        Text(item.relativePath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { library.setDocumentPage(library.documentPage - 1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .disabled(library.documentPage <= 0).help("Página anterior")
                    Text(pageCount == 0 ? "—" : "Página \(library.documentPage + 1) de \(pageCount)")
                        .font(.caption.monospacedDigit()).frame(minWidth: 110)
                    Button { library.setDocumentPage(library.documentPage + 1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .disabled(pageCount == 0 || library.documentPage + 1 >= pageCount).help("Página siguiente")
                    Button { notesVisible.toggle() } label: {
                        Image(systemName: "sidebar.trailing")
                    }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .help(notesVisible ? "Ocultar notas" : "Mostrar notas")
                    Button { library.openSelectedExternally() } label: { Image(systemName: "arrow.up.forward.app") }
                        .help("Abrir PDF en otra aplicación")
                }
                .padding(12).background(.bar)
            }
        }
    }
}

private struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    @Binding var pageIndex: Int
    let onPageCountChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        context.coordinator.connect(to: view)
        load(url, into: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedURL != url {
            load(url, into: view, coordinator: context.coordinator)
        } else if let document = view.document,
                  document.pageCount > 0,
                  let current = view.currentPage,
                  document.index(for: current) != pageIndex,
                  let page = document.page(at: min(max(0, pageIndex), document.pageCount - 1)) {
            context.coordinator.isNavigating = true
            view.go(to: page)
            context.coordinator.isNavigating = false
        }
    }

    private func load(_ url: URL, into view: PDFView, coordinator: Coordinator) {
        coordinator.loadedURL = url
        view.document = PDFDocument(url: url)
        let count = view.document?.pageCount ?? 0
        DispatchQueue.main.async { onPageCountChanged(count) }
        guard count > 0, let page = view.document?.page(at: min(max(0, pageIndex), count - 1)) else { return }
        coordinator.isNavigating = true
        view.go(to: page)
        coordinator.isNavigating = false
    }

    final class Coordinator {
        var parent: PDFDocumentView
        var loadedURL: URL?
        var isNavigating = false
        private var observer: NSObjectProtocol?

        init(_ parent: PDFDocumentView) { self.parent = parent }

        func connect(to view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                guard let self, !self.isNavigating, let view,
                      let document = view.document, let page = view.currentPage else { return }
                self.parent.pageIndex = document.index(for: page)
            }
        }

        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}

private struct IssueBanner: View {
    @EnvironmentObject private var library: LibraryModel
    let issue: AppIssue

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title).font(.subheadline.bold())
                Text(issue.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if issue.action != nil { Button(actionTitle) { library.retryLastIssue() } }
            Button { library.issue = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).help("Cerrar")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }

    private var actionTitle: String {
        switch issue.action {
        case .findFFmpeg: return "Configurar automáticamente"
        case .chooseFFmpeg: return "Elegir FFmpeg"
        case .retryVideo: return "Reintentar"
        case .revealLibrary: return "Mostrar carpeta"
        case nil: return ""
        }
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

            if let item = library.selectedItem, library.restoredSession {
                Button { library.togglePlayback(); library.restoredSession = false } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "play.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Continuar estudiando").font(.caption.bold())
                            Text(item.name).lineLimit(1)
                            Text(item.url.pathExtension.lowercased() == "pdf"
                                 ? "Página \(library.documentPage + 1)"
                                 : "Desde \(library.displayTime(library.currentTime))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                }
                .buttonStyle(.plain)
                Divider()
            }

            Picker("Filtrar", selection: $library.libraryFilter) {
                ForEach(LibraryFilter.allCases) { filter in Text(filter.title).tag(filter) }
            }
            .labelsHidden().pickerStyle(.menu).padding(.horizontal, 10).padding(.vertical, 6)

            if library.searchText.isEmpty {
                if library.displayedItems.isEmpty {
                    SidebarEmptyState(title: "No hay elementos", icon: "line.3.horizontal.decrease.circle",
                                      detail: "Prueba otro filtro o actualiza la biblioteca.")
                } else {
                    List {
                        ForEach(library.displayedItems) { item in LibraryRow(item: item) }
                    }
                    .listStyle(.sidebar)
                }
            } else {
                if library.displayedItems.isEmpty {
                    SidebarEmptyState(title: "Sin resultados", icon: "magnifyingglass",
                                      detail: "No se encontró “\(library.searchText)”.")
                } else {
                    List(library.displayedItems) { item in
                        Button { library.select(item) } label: { LeafLabel(item: item) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.sidebar)
                }
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

private struct SidebarEmptyState: View {
    let title: String
    let icon: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: icon).font(.title).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
        }
        .padding(20)
    }
}

private struct LibraryRow: View {
    @EnvironmentObject private var library: LibraryModel
    let item: LibraryItem

    var body: some View {
        if item.kind == .folder {
            DisclosureGroup(isExpanded: Binding(
                get: { library.expandedFolders.contains(item.id) },
                set: { library.setFolder(item.id, expanded: $0) }
            )) {
                ForEach(item.children ?? []) { child in LibraryRow(item: child) }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: courseStatusIcon)
                        .foregroundStyle(courseStatusColor)
                        .frame(width: 14)
                        .help(courseStatusHelp)
                    Image(systemName: "books.vertical.fill").foregroundStyle(.orange)
                    Text(item.name).lineLimit(2)
                    Spacer(minLength: 4)
                    let value = library.progressForCourse(item)
                    let count = library.completedCount(for: item)
                    if value > 0 || count.total > 0 {
                        Text("\(count.completed)/\(count.total)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        } else {
            Button { library.select(item) } label: { LeafLabel(item: item) }
                .buttonStyle(.plain)
                .contextMenu {
                    Button(library.isCompleted(item) ? "Marcar como pendiente" : "Marcar como completado") {
                        library.toggleCompleted(item)
                    }
                    Button("Reiniciar progreso") { library.resetProgress(item) }
                    Divider()
                    Button("Abrir archivo original") { NSWorkspace.shared.open(item.url) }
                }
        }
    }

    private var courseStatus: CourseProgressState {
        library.progressStateForCourse(item)
    }

    private var courseStatusIcon: String {
        switch courseStatus {
        case .unstarted: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .completed: return "checkmark.circle.fill"
        }
    }

    private var courseStatusColor: Color {
        switch courseStatus {
        case .unstarted: return .secondary.opacity(0.35)
        case .inProgress: return .orange
        case .completed: return .green
        }
    }

    private var courseStatusHelp: String {
        let count = library.completedCount(for: item)
        switch courseStatus {
        case .unstarted: return "Curso sin comenzar"
        case .inProgress: return "Curso comenzado · \(count.completed) de \(count.total) videos completados"
        case .completed: return "Curso completado"
        }
    }
}

private struct LeafLabel: View {
    @EnvironmentObject private var library: LibraryModel
    let item: LibraryItem

    var body: some View {
        HStack(spacing: 7) {
            if item.kind == .video {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                    .frame(width: 14)
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
    private var statusIcon: String {
        if isDone { return "checkmark.circle.fill" }
        if fraction > 0 { return "circle.lefthalf.filled" }
        return "circle"
    }
    private var statusHelp: String {
        if isDone { return library.completionDescription(for: item) }
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
                .buttonStyle(.borderedProminent)
            Text("También puedes arrastrar aquí una carpeta de cursos.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 26) {
                welcomeStep("1", "Elige una carpeta", "La aplicación encuentra cursos y lecciones automáticamente.")
                welcomeStep("2", "Estudia y anota", "El video y las notas Markdown viven en la misma ventana.")
                welcomeStep("3", "Continúa después", "Se recuerda el video, el minuto y tu velocidad.")
            }
            .frame(maxWidth: 720)
        }
        .padding(40)
    }

    private func welcomeStep(_ number: String, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 7) {
            Text(number).font(.headline).frame(width: 30, height: 30)
                .background(.orange.opacity(0.18), in: Circle())
            Text(title).font(.subheadline.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
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
    @Binding var notesVisible: Bool
    @State private var fullscreenCommand: VideoFullscreenCommand?
    private let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                NativeVideoPlayer(
                    player: library.player,
                    fullscreenCommand: fullscreenCommand,
                    onVideoClick: { library.togglePlayback() }
                )
                if library.isPreparingVideo {
                    VStack(spacing: 14) {
                        ProgressView().controlSize(.large)
                        Text("Preparando el video…").font(.headline).foregroundStyle(.white)
                        Text("Solo ocurre la primera vez que abres este archivo.")
                            .font(.caption).foregroundStyle(.white.opacity(0.75))
                        if let progress = library.preparationProgress { ProgressView(value: progress).frame(width: 220) }
                        Button("Cancelar") { library.cancelVideoPreparation() }
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

                ZStack {
                    HStack {
                        Menu {
                            ForEach(rates, id: \.self) { rate in
                                Button { library.setRate(rate) } label: {
                                    if library.playbackRate == rate { Label("\(rate.formatted())×", systemImage: "checkmark") }
                                    else { Text("\(rate.formatted())×") }
                                }
                            }
                        } label: {
                            Label("\(library.playbackRate.formatted())×", systemImage: "speedometer")
                                .monospacedDigit()
                        }
                        .menuStyle(.borderlessButton)
                        .help("Velocidad de reproducción")

                        Spacer()

                        HStack(spacing: 6) {
                            Button { notesVisible.toggle() } label: {
                                Image(systemName: "sidebar.trailing")
                            }
                            .keyboardShortcut("n", modifiers: [.command, .shift])
                            .help(notesVisible ? "Ocultar notas" : "Mostrar notas")
                            Button { fullscreenCommand = VideoFullscreenCommand() } label: {
                                Image(systemName: "arrow.up.left.and.arrow.down.right")
                            }
                            .keyboardShortcut("f", modifiers: [.command, .shift])
                            .help("Pantalla completa")
                            Button { library.openSelectedExternally() } label: {
                                Image(systemName: "arrow.up.forward.app")
                            }
                            .help("Abrir archivo original")
                        }
                        .buttonStyle(.borderless)
                    }

                    HStack(spacing: 18) {
                        Button { library.playPrevious() } label: { Image(systemName: "backward.end") }
                            .disabled(library.previousItem == nil).help("Video anterior")
                        Button { library.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
                            .help("Retroceder 15 segundos")
                        Button { library.togglePlayback() } label: {
                            Image(systemName: library.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 36))
                        }
                        .help(library.isPlaying ? "Pausar" : "Reproducir")
                        Button { library.skip(seconds: 15) } label: { Image(systemName: "goforward.15") }
                            .help("Adelantar 15 segundos")
                        Button { library.playNext() } label: { Image(systemName: "forward.end") }
                            .disabled(library.nextItem == nil).help("Siguiente video")
                    }
                    .buttonStyle(.borderless)
                }
                .frame(minHeight: 38)
                if !library.statusMessage.isEmpty && library.statusMessage != "Listo" {
                    Text(library.statusMessage).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(.bar)
        }
    }
}

private struct VideoFullscreenCommand: Equatable {
    let id = UUID()
}

private struct NativeVideoPlayer: NSViewRepresentable {
    let player: AVPlayer
    let fullscreenCommand: VideoFullscreenCommand?
    let onVideoClick: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ClickableAVPlayerView {
        let view = ClickableAVPlayerView()
        view.player = player
        view.controlsStyle = .minimal
        view.showsFullScreenToggleButton = true
        view.allowsVideoFrameAnalysis = true
        view.onVideoClick = onVideoClick
        if #available(macOS 14.0, *) {
            view.videoFrameAnalysisTypes = [.text]
        }
        return view
    }

    func updateNSView(_ view: ClickableAVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onVideoClick = onVideoClick
        view.allowsVideoFrameAnalysis = true
        if #available(macOS 14.0, *) {
            view.videoFrameAnalysisTypes = [.text]
        }
        guard let command = fullscreenCommand,
              context.coordinator.lastCommandID != command.id else { return }
        context.coordinator.lastCommandID = command.id
        DispatchQueue.main.async { [weak view] in
            guard let view else { return }
            if view.isInFullScreenMode {
                view.exitFullScreenMode(options: nil)
            } else if let screen = view.window?.screen ?? NSScreen.main {
                _ = view.enterFullScreenMode(screen, withOptions: [
                    .fullScreenModeApplicationPresentationOptions:
                        NSApplication.PresentationOptions.autoHideMenuBar.rawValue
                        | NSApplication.PresentationOptions.autoHideDock.rawValue
                ])
            }
        }
    }

    final class Coordinator {
        var lastCommandID: UUID?
    }
}

private final class ClickableAVPlayerView: AVPlayerView, NSGestureRecognizerDelegate {
    var onVideoClick: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureVideoClick()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureVideoClick()
    }

    private func configureVideoClick() {
        let click = NSClickGestureRecognizer(target: self, action: #selector(videoWasClicked(_:)))
        click.numberOfClicksRequired = 1
        click.delegate = self
        addGestureRecognizer(click)
    }

    @objc private func videoWasClicked(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        guard recognizer.location(in: self).y > 64 else { return }
        onVideoClick?()
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: NSGestureRecognizer
    ) -> Bool {
        true
    }
}

private struct NotesPane: View {
    @EnvironmentObject private var library: LibraryModel
    @State private var formatCommand: MarkdownFormatCommand?
    @State private var activeFormats: Set<MarkdownFormatStyle> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label(library.selectedItem?.url.pathExtension.lowercased() == "pdf"
                      ? "Notas del documento" : "Notas del video",
                      systemImage: "square.and.pencil").font(.headline)
                if library.noteSaveState != .idle {
                    Label(library.noteSaveState.title,
                          systemImage: library.noteSaveState == .failed ? "exclamationmark.circle" : "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(library.noteSaveState == .failed ? Color.red : Color.secondary)
                }
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
                formatButton(.bulletList, icon: "list.bullet", help: "Lista con viñetas (-)")
                formatButton(.numberedList, icon: "list.number", help: "Lista numerada")
                formatButton(.taskList, icon: "checklist", help: "Lista de tareas")
                Menu {
                    Button("Marcatextos") { format(.highlight) }
                    Button("Tachado") { format(.strikethrough) }
                    Button("Insertar enlace") { format(.link) }
                    Divider()
                    Button("Línea divisora") { format(.divider) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).help("Más formatos")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.bar)
            Divider()
            LiveMarkdownEditor(
                text: Binding(get: { library.noteText }, set: { library.setNoteText($0) }),
                documentID: library.selectedItem?.id,
                baseURL: library.selectedNoteFolder,
                onPasteImage: { library.savePastedImage($0) },
                formatCommand: formatCommand,
                onSelectionFormatsChanged: { activeFormats = $0 }
            )
        }
    }

    private func format(_ style: MarkdownFormatStyle) {
        formatCommand = MarkdownFormatCommand(style: style)
    }

    private func formatButton(_ style: MarkdownFormatStyle, icon: String, help: String) -> some View {
        Button { format(style) } label: { Image(systemName: icon) }
            .buttonStyle(.plain)
            .foregroundStyle(activeFormats.contains(style) ? Color.accentColor : Color.primary)
            .help(help)
    }
}
