import SwiftUI
import AVFoundation
import AppKit
import CoreServices
import UniformTypeIdentifiers
import IOKit.pwr_mgt

private let libraryEventsCallback: FSEventStreamCallback = { _, clientInfo, _, eventPaths, _, _ in
    guard let clientInfo else { return }
    let model = Unmanaged<LibraryModel>.fromOpaque(clientInfo).takeUnretainedValue()
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    Task { @MainActor in model.handleLibraryEvents(paths) }
}

@MainActor
final class LibraryModel: ObservableObject {
    @Published var rootURL: URL?
    @Published var items: [LibraryItem] = []
    @Published var selectedItem: LibraryItem?
    @Published var searchText = ""
    @Published var libraryFilter: LibraryFilter = .all
    @Published var noteText = ""
    @Published var noteSaveState: NoteSaveState = .idle
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1
    @Published var isScanning = false
    @Published var isPreparingVideo = false
    @Published var preparationProgress: Double?
    @Published var statusMessage = ""
    @Published var issue: AppIssue?
    @Published var restoredSession = false
    @Published var expandedFolders: Set<String> = []
    @Published var documentPage = 0

    let player = AVPlayer()
    private var progress = ProgressFile()
    private var timeObserver: Any?
    private var noteSaveTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var conversionProcess: Process?
    private var conversionProgressTimer: DispatchSourceTimer?
    private var conversionWasCancelled = false
    private var isRestoringPlaybackPosition = false
    private var playbackGeneration = UUID()
    private var playbackEndObserver: NSObjectProtocol?
    private var playbackStatusObserver: NSKeyValueObservation?
    private var displaySleepAssertionID: IOPMAssertionID = 0
    private var libraryEventStream: FSEventStreamRef?
    private var lastProgressSave = Date.distantPast
    private var didStart = false
    private var didRestoreLastVideo = false
    private var progressBackupCreated = false
    private var backedUpNotes: Set<String> = []
    private let savedLibraryKey = "CoursePlayerLibraryPath"
    private let savedRateKey = "CoursePlayerPlaybackRate"
    private let savedFFmpegKey = "CoursePlayerFFmpegPath"
    private let expandedFoldersKey = "CoursePlayerExpandedFolders"

    private let videoExtensions: Set<String> = ["ts", "mp4", "mov", "m4v"]
    private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff"]
    private let documentExtensions: Set<String> = ["pdf", "doc", "docx", "txt", "md", "epub"]
    private let ignoredNames: Set<String> = ["Course Player Notes", "Course Player.app"]

    var displayedItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            return flatten(items).filter {
                $0.kind != .folder
                    && matchesFilter($0)
                    && ($0.name.localizedCaseInsensitiveContains(query)
                        || $0.relativePath.localizedCaseInsensitiveContains(query))
            }
        }
        return filteredTree(items)
    }

    var selectedProgress: ProgressRecord {
        guard let path = selectedItem?.relativePath else { return ProgressRecord() }
        return progress.records[path] ?? ProgressRecord()
    }

    var totalVideos: Int { flatten(items).filter { $0.kind == .video }.count }
    var completedVideos: Int {
        flatten(items).filter { $0.kind == .video && isCompleted($0) }.count
    }
    var inProgressVideos: Int { videos.filter { !isCompleted($0) && progressFraction(for: $0) > 0 }.count }
    var pendingVideos: Int { max(0, totalVideos - completedVideos - inProgressVideos) }
    var videos: [LibraryItem] { flatten(items).filter { $0.kind == .video } }
    var nextItem: LibraryItem? { adjacentItem(offset: 1) }
    var previousItem: LibraryItem? { adjacentItem(offset: -1) }
    func start() {
        guard !didStart else { return }
        didStart = true
        let savedRate = UserDefaults.standard.float(forKey: savedRateKey)
        if savedRate >= 0.5, savedRate <= 2 { playbackRate = savedRate }
        preserveConfiguredFFmpeg()
        if !isFFmpegReady { _ = adoptAutomaticallyAvailableFFmpeg() }
        expandedFolders = Set(UserDefaults.standard.stringArray(forKey: expandedFoldersKey) ?? [])
        installTimeObserver()
        playbackEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.playbackDidEnd() }
        }
        playbackStatusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            Task { @MainActor in self?.playbackStatusChanged(player.timeControlStatus) }
        }

        if let savedPath = UserDefaults.standard.string(forKey: savedLibraryKey) {
            let savedURL = URL(fileURLWithPath: savedPath, isDirectory: true)
            if looksLikeLibrary(savedURL) {
                rootURL = savedURL
            }
        }
        if rootURL != nil {
            loadProgress()
            scan()
            startWatchingLibrary()
            restoreLastVideo()
        } else {
            statusMessage = "Elige la carpeta que contiene tus cursos"
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        scanTask?.cancel()
        if let stream = libraryEventStream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
        }
        if let playbackEndObserver { NotificationCenter.default.removeObserver(playbackEndObserver) }
        playbackStatusObserver?.invalidate()
        if displaySleepAssertionID != 0 { IOPMAssertionRelease(displaySleepAssertionID) }
        conversionProgressTimer?.cancel()
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Elige la carpeta que contiene tus cursos"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        if panel.runModal() == .OK, let url = panel.url {
            openLibrary(url)
        }
    }

    func openLibrary(_ url: URL) {
        guard looksLikeLibrary(url) else {
            issue = AppIssue(title: "No es una carpeta válida", message: "Arrastra o selecciona una carpeta de cursos.", action: nil)
            return
        }
        saveCurrentNoteNow()
        stopWatchingLibrary()
        rootURL = url
        UserDefaults.standard.set(url.path, forKey: savedLibraryKey)
        selectedItem = nil
        progressBackupCreated = false
        backedUpNotes = []
        expandedFolders = []
        UserDefaults.standard.removeObject(forKey: expandedFoldersKey)
        player.replaceCurrentItem(with: nil)
        didRestoreLastVideo = false
        loadProgress()
        scan()
        startWatchingLibrary()
        restoreLastVideo()
    }

    func setFolder(_ id: String, expanded: Bool) {
        if expanded { expandedFolders.insert(id) } else { expandedFolders.remove(id) }
        UserDefaults.standard.set(Array(expandedFolders), forKey: expandedFoldersKey)
    }

    func scan(silently: Bool = false) {
        guard let rootURL else { return }
        if !silently { isScanning = true }
        let built = buildItems(at: rootURL, root: rootURL)
        let previousIDs = flatten(items).map(\.id)
        let newIDs = flatten(built).map(\.id)
        if previousIDs != newIDs { items = built }
        if !silently { isScanning = false }
        statusMessage = "\(totalVideos) videos encontrados"
    }

    func select(_ item: LibraryItem) {
        restoredSession = false
        open(item, autoplay: true)
    }

    private func open(_ item: LibraryItem, autoplay: Bool) {
        guard item.kind != .folder else { return }
        if item.kind == .document && item.url.pathExtension.lowercased() != "pdf" {
            NSWorkspace.shared.open(item.url)
            return
        }
        guard item.isPlayable || item.url.pathExtension.lowercased() == "pdf" else { return }
        saveCurrentNoteNow()
        storeCurrentPosition()
        conversionProcess?.terminate()
        conversionProcess = nil
        isPreparingVideo = false
        preparationProgress = nil
        issue = nil
        selectedItem = item
        loadNote(for: item)
        let record = progress.records[item.relativePath] ?? ProgressRecord()
        currentTime = record.position
        duration = record.duration
        var updated = record
        updated.lastOpened = .now
        progress.records[item.relativePath] = updated
        scheduleProgressSave()
        if item.url.pathExtension.lowercased() == "pdf" {
            player.pause()
            player.replaceCurrentItem(with: nil)
            isPlaying = false
            documentPage = max(0, record.pageIndex ?? 0)
            statusMessage = "Documento listo"
            return
        }
        if item.url.pathExtension.lowercased() == "ts" {
            prepareTransportStream(item, autoplay: autoplay)
        } else {
            play(item.url, for: item, autoplay: autoplay)
        }
    }

    func setDocumentPage(_ page: Int) {
        guard let item = selectedItem, item.url.pathExtension.lowercased() == "pdf" else { return }
        let value = max(0, page)
        documentPage = value
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.pageIndex = value
        record.lastOpened = .now
        progress.records[item.relativePath] = record
        scheduleProgressSave()
    }

    func togglePlayback() {
        guard selectedItem?.isPlayable == true, !isPreparingVideo, !isRestoringPlaybackPosition else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            storeCurrentPosition()
            saveCurrentNoteNow()
        } else {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        }
    }

    func skip(seconds: Double) {
        let upperBound = duration.isFinite && duration > 0 ? duration : max(0, currentTime + abs(seconds))
        let target = max(0, min(upperBound, currentTime + seconds))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setRate(_ rate: Float) {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: savedRateKey)
        if isPlaying { player.rate = rate }
    }

    func playPrevious() {
        guard let previousItem else { return }
        open(previousItem, autoplay: true)
    }

    func playNext() {
        guard let nextItem else { return }
        open(nextItem, autoplay: true)
    }

    func toggleCompleted() {
        guard let item = selectedItem else { return }
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.completed.toggle()
        record.completionSource = record.completed ? "manual" : nil
        progress.records[item.relativePath] = record
        objectWillChange.send()
        scheduleProgressSave()
    }

    func toggleCompleted(_ item: LibraryItem) {
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.completed.toggle()
        record.completionSource = record.completed ? "manual" : nil
        progress.records[item.relativePath] = record
        objectWillChange.send()
        scheduleProgressSave()
    }

    func resetProgress(_ item: LibraryItem) {
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.position = 0
        record.completed = false
        record.completionSource = "reset"
        record.lastOpened = .now
        progress.records[item.relativePath] = record
        if selectedItem?.id == item.id {
            currentTime = 0
            player.seek(to: .zero)
        }
        objectWillChange.send()
        saveProgressNow()
    }

    func setNoteText(_ text: String) {
        noteText = text
        noteSaveState = .saving
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveCurrentNoteNow()
        }
    }

    func retryLastIssue() {
        guard let action = issue?.action else { issue = nil; return }
        issue = nil
        switch action {
        case .retryVideo:
            if let selectedItem { open(selectedItem, autoplay: false) }
        case .findFFmpeg: configureFFmpegAutomatically()
        case .chooseFFmpeg: chooseFFmpeg()
        case .revealLibrary:
            if let rootURL { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) }
        }
    }

    func chooseFFmpeg() {
        let panel = NSOpenPanel()
        panel.title = "Elige el ejecutable de FFmpeg"
        panel.prompt = "Usar FFmpeg"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            issue = AppIssue(title: "FFmpeg no es ejecutable", message: "Elige un archivo FFmpeg ejecutable.", action: .chooseFFmpeg)
            return
        }
        guard let preserved = preserveFFmpeg(from: url) else {
            issue = AppIssue(title: "No se pudo conservar FFmpeg",
                             message: "Comprueba que Course Player tenga acceso a tu carpeta Application Support.",
                             action: .chooseFFmpeg)
            return
        }
        UserDefaults.standard.set(preserved.path, forKey: savedFFmpegKey)
        if selectedItem?.url.pathExtension.lowercased() == "ts", let selectedItem {
            open(selectedItem, autoplay: false)
        }
    }

    var isFFmpegReady: Bool { ffmpegExecutableURL() != nil }

    func configureFFmpegAutomatically() {
        if adoptAutomaticallyAvailableFFmpeg() {
            issue = nil
            statusMessage = "FFmpeg quedó configurado automáticamente"
            if selectedItem?.url.pathExtension.lowercased() == "ts", let selectedItem,
               player.currentItem == nil {
                open(selectedItem, autoplay: false)
            }
        } else {
            issue = AppIssue(title: "FFmpeg no se encontró automáticamente",
                             message: "Puedes instalar FFmpeg con Homebrew o elegir manualmente su ejecutable.",
                             action: .chooseFFmpeg)
        }
    }

    func cancelVideoPreparation() {
        conversionWasCancelled = true
        conversionProgressTimer?.cancel()
        conversionProgressTimer = nil
        conversionProcess?.terminate()
        conversionProcess = nil
        isPreparingVideo = false
        preparationProgress = nil
        statusMessage = "Preparación cancelada"
    }

    func revealNote() {
        guard let item = selectedItem, let url = noteURL(for: item) else { return }
        saveCurrentNoteNow()
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func addImageToNote() {
        guard let item = selectedItem, let note = noteURL(for: item) else { return }
        let panel = NSOpenPanel()
        panel.title = "Elige una imagen para la nota"
        panel.prompt = "Agregar"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let source = panel.url else { return }

        saveCurrentNoteNow()
        let noteBase = note.deletingPathExtension().lastPathComponent
        let resources = note.deletingLastPathComponent()
            .appendingPathComponent("Recursos", isDirectory: true)
            .appendingPathComponent(noteBase, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: source.lastPathComponent, in: resources)
            try FileManager.default.copyItem(at: source, to: destination)
            let relative = "Recursos/\(noteBase)/\(destination.lastPathComponent)"
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? destination.lastPathComponent
            let alt = source.deletingPathExtension().lastPathComponent
            let prefix = noteText.hasSuffix("\n") ? "" : "\n"
            setNoteText(noteText + "\(prefix)\n![\(alt)](\(relative))\n")
            saveCurrentNoteNow()
        } catch {
            statusMessage = "No se pudo copiar la imagen a la nota"
        }
    }

    func savePastedImage(_ image: NSImage) -> String? {
        guard let item = selectedItem, let note = noteURL(for: item),
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:]) else {
            statusMessage = "El portapapeles no contiene una imagen compatible"
            return nil
        }

        let noteBase = note.deletingPathExtension().lastPathComponent
        let resources = note.deletingLastPathComponent()
            .appendingPathComponent("Recursos", isDirectory: true)
            .appendingPathComponent(noteBase, isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = "Imagen-\(formatter.string(from: .now)).png"

        do {
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
            let destination = uniqueDestination(for: name, in: resources)
            try png.write(to: destination, options: .atomic)
            let relative = "Recursos/\(noteBase)/\(destination.lastPathComponent)"
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? destination.lastPathComponent
            return "\n\n![Imagen pegada](\(relative))\n\n"
        } catch {
            statusMessage = "No se pudo guardar la imagen del portapapeles"
            return nil
        }
    }

    var selectedNoteFolder: URL? {
        guard let item = selectedItem else { return nil }
        return noteURL(for: item)?.deletingLastPathComponent()
    }

    func openSelectedExternally() {
        if let url = selectedItem?.url { NSWorkspace.shared.open(url) }
    }

    func flushBeforeClosing() {
        storeCurrentPosition()
        saveCurrentNoteNow()
        saveProgressNow()
        releaseDisplaySleepAssertion()
    }

    func revealLibrary() {
        if let rootURL { NSWorkspace.shared.activateFileViewerSelecting([rootURL]) }
    }

    func progressForCourse(_ item: LibraryItem) -> Double {
        let videos = flatten(item.children ?? []).filter { $0.kind == .video }
        guard !videos.isEmpty else { return 0 }
        let done = videos.filter { progress.records[$0.relativePath]?.completed == true }.count
        return Double(done) / Double(videos.count)
    }

    func progressStateForCourse(_ item: LibraryItem) -> CourseProgressState {
        let courseVideos = flatten(item.children ?? []).filter { $0.kind == .video }
        guard !courseVideos.isEmpty else { return .unstarted }
        if courseVideos.allSatisfy(isCompleted) { return .completed }
        let hasStarted = courseVideos.contains { video in
            guard let record = progress.records[video.relativePath] else { return false }
            return record.completed || record.position > 1
        }
        return hasStarted ? .inProgress : .unstarted
    }

    func isCompleted(_ item: LibraryItem) -> Bool {
        progress.records[item.relativePath]?.completed == true
    }

    func completionDescription(for item: LibraryItem) -> String {
        guard let record = progress.records[item.relativePath], record.completed else { return "" }
        switch record.completionSource {
        case "watched": return "Completado al terminar el video"
        case "manual": return "Marcado como completado manualmente"
        default: return "Completado"
        }
    }

    func progressFraction(for item: LibraryItem) -> Double {
        guard let record = progress.records[item.relativePath], record.duration > 0 else { return 0 }
        return min(1, max(0, record.position / record.duration))
    }

    func completedCount(for item: LibraryItem) -> (completed: Int, total: Int) {
        let courseVideos = flatten(item.children ?? []).filter { $0.kind == .video }
        return (courseVideos.filter(isCompleted).count, courseVideos.count)
    }

    func displayTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        if total >= 3600 { return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60) }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func looksLikeLibrary(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private func buildItems(at directory: URL, root: URL) -> [LibraryItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            if ignoredNames.contains(url.lastPathComponent) { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let relative = relativePath(for: url, root: root)
            if values?.isDirectory == true {
                if directory.standardizedFileURL == root.standardizedFileURL,
                   looksLikeLegacyNoteStore(url) { return nil }
                let children = buildItems(at: url, root: root)
                guard !children.isEmpty else { return nil }
                return LibraryItem(id: relative, name: url.lastPathComponent, url: url, relativePath: relative, kind: .folder, children: children)
            }
            let ext = url.pathExtension.lowercased()
            let kind: LibraryItemKind
            if videoExtensions.contains(ext) { kind = .video }
            else if audioExtensions.contains(ext) { kind = .audio }
            else if documentExtensions.contains(ext) { kind = .document }
            else { return nil }
            return LibraryItem(id: relative, name: url.deletingPathExtension().lastPathComponent, url: url, relativePath: relative, kind: kind, children: nil)
        }.sorted { lhs, rhs in
            if lhs.kind == .folder && rhs.kind != .folder { return true }
            if rhs.kind == .folder && lhs.kind != .folder { return false }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func flatten(_ source: [LibraryItem]) -> [LibraryItem] {
        source.flatMap { [$0] + flatten($0.children ?? []) }
    }

    private func matchesFilter(_ item: LibraryItem) -> Bool {
        guard item.kind == .video else { return libraryFilter == .all }
        switch libraryFilter {
        case .all: return true
        case .unstarted: return !isCompleted(item) && progressFraction(for: item) == 0
        case .inProgress: return !isCompleted(item) && progressFraction(for: item) > 0
        case .completed: return isCompleted(item)
        }
    }

    private func filteredTree(_ source: [LibraryItem]) -> [LibraryItem] {
        source.compactMap { item in
            if item.kind == .folder {
                let children = filteredTree(item.children ?? [])
                return children.isEmpty ? nil : LibraryItem(id: item.id, name: item.name, url: item.url,
                                                             relativePath: item.relativePath, kind: item.kind,
                                                             children: children)
            }
            return matchesFilter(item) ? item : nil
        }
    }

    private func adjacentItem(offset: Int) -> LibraryItem? {
        guard let selectedItem, let index = videos.firstIndex(where: { $0.id == selectedItem.id }) else { return nil }
        let target = index + offset
        return videos.indices.contains(target) ? videos[target] : nil
    }

    private func relativePath(for url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var dataDirectory: URL? { rootURL?.appendingPathComponent(".course-player", isDirectory: true) }
    private var progressURL: URL? { dataDirectory?.appendingPathComponent("progress.json") }
    private var progressBackupDirectory: URL? { dataDirectory?.appendingPathComponent("backups", isDirectory: true) }

    private func loadProgress() {
        progress = ProgressFile()
        lastProgressSave = .now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let url = progressURL,
           let data = try? Data(contentsOf: url),
           let decoded = try? decoder.decode(ProgressFile.self, from: data) {
            progress = decoded
        }

        var recovered = false
        for url in compatibleRecoveryProgressURLs() {
            guard let data = try? Data(contentsOf: url),
                  let legacy = try? decoder.decode(ProgressFile.self, from: data) else { continue }
            for (path, candidate) in legacy.records {
                if ProgressRecoveryPolicy.shouldRecover(candidate, over: progress.records[path]) {
                    progress.records[path] = candidate
                    recovered = true
                }
            }
        }
        if recovered { saveProgressNow() }
    }

    private func compatibleRecoveryProgressURLs() -> [URL] {
        guard let rootURL,
              let children = try? FileManager.default.contentsOfDirectory(
                at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: []
              ) else { return [] }
        var urls: [URL] = children.compactMap { directory -> URL? in
            guard directory.lastPathComponent.hasPrefix("."),
                  directory.lastPathComponent != ".course-player",
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
            let candidate = directory.appendingPathComponent("progress.json")
            return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
        }
        if let progressBackupDirectory,
           let backups = try? FileManager.default.contentsOfDirectory(
                at: progressBackupDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
           ) {
            urls.append(contentsOf: backups.filter { $0.pathExtension.lowercased() == "json" })
        }
        return urls
    }

    private func scheduleProgressSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.saveProgressNow()
        }
    }

    private func saveProgressNow() {
        guard let directory = dataDirectory, let url = progressURL else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try createProgressBackupIfNeeded(of: url)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(progress)
            try data.write(to: url, options: .atomic)
            lastProgressSave = .now
        } catch {
            issue = AppIssue(title: "No se pudo guardar el progreso",
                             message: "Comprueba que la carpeta de la biblioteca permite escritura.",
                             action: .revealLibrary)
        }
    }

    private func createProgressBackupIfNeeded(of current: URL) throws {
        guard !progressBackupCreated else { return }
        progressBackupCreated = true
        guard FileManager.default.fileExists(atPath: current.path), let progressBackupDirectory else { return }
        try FileManager.default.createDirectory(at: progressBackupDirectory, withIntermediateDirectories: true)
        let destination = progressBackupDirectory.appendingPathComponent("progress-\(backupTimestamp()).json")
        try FileManager.default.copyItem(at: current, to: destination)
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: progressBackupDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = backups.filter { $0.pathExtension.lowercased() == "json" }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for old in sorted.dropFirst(12) { try? FileManager.default.removeItem(at: old) }
    }

    private func saveProgressCheckpointIfNeeded() {
        guard Date.now.timeIntervalSince(lastProgressSave) >= 10 else { return }
        saveProgressNow()
    }

    private func noteURL(for item: LibraryItem) -> URL? {
        guard let rootURL else { return nil }
        let pathURL = URL(fileURLWithPath: item.relativePath)
        let relativeFolder = pathURL.deletingLastPathComponent().path
        let base = pathURL.deletingPathExtension().lastPathComponent + ".md"
        return rootURL.appendingPathComponent("Course Player Notes", isDirectory: true)
            .appendingPathComponent(relativeFolder, isDirectory: true)
            .appendingPathComponent(base)
    }

    private func uniqueDestination(for fileName: String, in folder: URL) -> URL {
        let original = URL(fileURLWithPath: fileName)
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var candidate = folder.appendingPathComponent(fileName)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base)-\(number)" : "\(base)-\(number).\(ext)"
            candidate = folder.appendingPathComponent(name)
            number += 1
        }
        return candidate
    }

    private func loadNote(for item: LibraryItem) {
        guard let url = noteURL(for: item) else { noteText = ""; return }
        noteSaveState = .idle
        recoverNoteBackupIfNeeded(for: item, destination: url)
        recoverLegacyNoteIfNeeded(for: item, destination: url)
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            noteText = existing
        } else {
            let escapedPath = item.relativePath.replacingOccurrences(of: "\"", with: "\\\"")
            let relation = item.kind == .document ? "documento" : "video"
            noteText = "---\n\(relation): \"\(escapedPath)\"\ncurso: \"\(item.relativePath.split(separator: "/").first ?? "")\"\n---\n\n# \(item.name)\n\n## Ideas principales\n\n- \n\n## Reflexiones\n\n"
        }
    }

    private func recoverNoteBackupIfNeeded(for item: LibraryItem, destination: URL) {
        let manager = FileManager.default
        let existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard existingSize == 0, let backupDirectory = noteBackupDirectory(for: item),
              !manager.fileExists(atPath: backupDirectory.appendingPathComponent(".intentionally-empty").path),
              let candidates = try? manager.contentsOfDirectory(
                at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else { return }
        let latest = candidates.filter {
            $0.pathExtension.lowercased() == "md"
                && ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        }.max {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
        guard let latest else { return }
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) { try manager.removeItem(at: destination) }
            try manager.copyItem(at: latest, to: destination)
        } catch {
            issue = AppIssue(title: "No se pudo restaurar la nota",
                             message: "Existe una copia de seguridad, pero no pudo copiarse a la carpeta de notas.",
                             action: .revealLibrary)
        }
    }

    private func recoverLegacyNoteIfNeeded(for item: LibraryItem, destination: URL) {
        guard !FileManager.default.fileExists(atPath: destination.path), let rootURL else { return }
        let manager = FileManager.default
        let relativeNotePath = URL(fileURLWithPath: item.relativePath)
            .deletingPathExtension().appendingPathExtension("md").path
        guard let roots = try? manager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return }

        for noteRoot in roots where noteRoot.lastPathComponent != "Course Player Notes" {
            guard looksLikeLegacyNoteStore(noteRoot) else { continue }
            let source = noteRoot.appendingPathComponent(relativeNotePath)
            guard manager.fileExists(atPath: source.path),
                  let markdown = try? String(contentsOf: source, encoding: .utf8) else { continue }
            do {
                try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try manager.copyItem(at: source, to: destination)
                recoverReferencedImages(in: markdown, from: source.deletingLastPathComponent(),
                                        to: destination.deletingLastPathComponent())
            } catch {
                issue = AppIssue(title: "No se pudo recuperar una nota",
                                 message: "La nota original se conservó intacta. Comprueba los permisos de la biblioteca.",
                                 action: .revealLibrary)
            }
            return
        }
    }

    private func looksLikeLegacyNoteStore(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let normalizedName = directory.lastPathComponent.folding(
            options: [.diacriticInsensitive, .caseInsensitive], locale: .current
        )
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue,
              directory.lastPathComponent != "Course Player Notes",
              normalizedName.localizedCaseInsensitiveContains("note")
                || normalizedName.localizedCaseInsensitiveContains("nota") else { return false }
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return false }
        var checked = 0
        for case let url as URL in enumerator where url.pathExtension.lowercased() == "md" {
            checked += 1
            if let prefix = try? String(contentsOf: url, encoding: .utf8).prefix(600),
               prefix.hasPrefix("---"), prefix.contains("\nvideo:") { return true }
            if checked >= 8 { break }
        }
        return false
    }

    private func recoverReferencedImages(in markdown: String, from sourceFolder: URL, to destinationFolder: URL) {
        guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(([^\)]+)\)"#) else { return }
        let ns = markdown as NSString
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            guard match.numberOfRanges > 1,
                  let path = ns.substring(with: match.range(at: 1)).removingPercentEncoding,
                  !path.contains("://"), !path.hasPrefix("/") else { continue }
            let source = sourceFolder.appendingPathComponent(path).standardizedFileURL
            let destination = destinationFolder.appendingPathComponent(path).standardizedFileURL
            guard source.path.hasPrefix(sourceFolder.standardizedFileURL.path + "/"),
                  destination.path.hasPrefix(destinationFolder.standardizedFileURL.path + "/"),
                  FileManager.default.fileExists(atPath: source.path),
                  !FileManager.default.fileExists(atPath: destination.path) else { continue }
            try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.copyItem(at: source, to: destination)
        }
    }

    @discardableResult private func saveCurrentNoteNow() -> Bool {
        guard let item = selectedItem, let url = noteURL(for: item) else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try createNoteBackupIfNeeded(for: item, current: url)
            try noteText.write(to: url, atomically: true, encoding: .utf8)
            updateIntentionalEmptyMarker(for: item)
            noteSaveState = .saved
            return true
        } catch {
            noteSaveState = .failed
            issue = AppIssue(title: "No se pudo guardar la nota",
                             message: "Comprueba que la biblioteca sigue disponible y permite escritura.",
                             action: .revealLibrary)
            return false
        }
    }

    private func noteBackupDirectory(for item: LibraryItem) -> URL? {
        guard let dataDirectory else { return nil }
        let path = URL(fileURLWithPath: item.relativePath)
        let relativeFolder = path.deletingLastPathComponent().path
        let noteName = path.deletingPathExtension().lastPathComponent
        return dataDirectory.appendingPathComponent("note-backups", isDirectory: true)
            .appendingPathComponent(relativeFolder, isDirectory: true)
            .appendingPathComponent(noteName, isDirectory: true)
    }

    private func createNoteBackupIfNeeded(for item: LibraryItem, current: URL) throws {
        guard !backedUpNotes.contains(item.relativePath) else { return }
        backedUpNotes.insert(item.relativePath)
        guard FileManager.default.fileExists(atPath: current.path),
              let backupDirectory = noteBackupDirectory(for: item) else { return }
        try FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
        let destination = backupDirectory.appendingPathComponent("note-\(backupTimestamp()).md")
        try FileManager.default.copyItem(at: current, to: destination)
        let backups = (try? FileManager.default.contentsOfDirectory(
            at: backupDirectory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let sorted = backups.filter { $0.pathExtension.lowercased() == "md" }.sorted {
            let first = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first > second
        }
        for old in sorted.dropFirst(12) { try? FileManager.default.removeItem(at: old) }
    }

    private func updateIntentionalEmptyMarker(for item: LibraryItem) {
        guard let backupDirectory = noteBackupDirectory(for: item) else { return }
        let marker = backupDirectory.appendingPathComponent(".intentionally-empty")
        if noteText.isEmpty {
            try? FileManager.default.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: marker.path) {
                FileManager.default.createFile(atPath: marker.path, contents: Data())
            }
        } else {
            try? FileManager.default.removeItem(at: marker)
        }
    }

    private func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: .now)
    }

    private func storeCurrentPosition() {
        guard let item = selectedItem, player.currentItem != nil,
              currentTime.isFinite, currentTime >= 0 else { return }
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.position = currentTime
        if duration.isFinite, duration > 0 { record.duration = duration }
        record.lastOpened = .now
        progress.records[item.relativePath] = record
        saveProgressNow()
    }

    private func restoreLastVideo() {
        guard !didRestoreLastVideo else { return }
        didRestoreLastVideo = true
        let resumableItems = flatten(items).filter {
            $0.isPlayable || $0.url.pathExtension.lowercased() == "pdf"
        }
        guard let last = resumableItems.max(by: {
            let first = progress.records[$0.relativePath]?.lastOpened ?? .distantPast
            let second = progress.records[$1.relativePath]?.lastOpened ?? .distantPast
            return first < second
        }), progress.records[last.relativePath] != nil else { return }
        open(last, autoplay: false)
        restoredSession = true
    }

    private func playbackDidEnd() {
        guard let item = selectedItem else { return }
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.position = duration
        record.duration = duration
        record.completed = true
        record.completionSource = "watched"
        progress.records[item.relativePath] = record
        isPlaying = false
        releaseDisplaySleepAssertion()
        saveProgressNow()
        objectWillChange.send()
        if nextItem != nil {
            statusMessage = "Lección completada · Siguiente disponible"
        } else {
            statusMessage = "Lección completada"
        }
    }

    private func playbackStatusChanged(_ status: AVPlayer.TimeControlStatus) {
        let playbackActive = player.currentItem != nil && status != .paused
        isPlaying = playbackActive
        if playbackActive {
            acquireDisplaySleepAssertion()
        } else {
            releaseDisplaySleepAssertion()
        }
    }

    private func acquireDisplaySleepAssertion() {
        guard displaySleepAssertionID == 0 else { return }
        var assertionID = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Course Player está reproduciendo un video" as CFString,
            &assertionID
        )
        if result == kIOReturnSuccess { displaySleepAssertionID = assertionID }
    }

    private func releaseDisplaySleepAssertion() {
        guard displaySleepAssertionID != 0 else { return }
        IOPMAssertionRelease(displaySleepAssertionID)
        displaySleepAssertionID = 0
    }

    private func play(_ url: URL, for item: LibraryItem, autoplay: Bool) {
        guard selectedItem?.id == item.id else { return }
        let record = progress.records[item.relativePath] ?? ProgressRecord()
        currentTime = record.position
        duration = record.duration
        let itemID = item.id
        let generation = UUID()
        playbackGeneration = generation
        isRestoringPlaybackPosition = true
        isPlaying = false
        player.pause()
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        let target = CMTime(seconds: max(0, record.position), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self, self.playbackGeneration == generation,
                      self.selectedItem?.id == itemID else { return }
                self.isRestoringPlaybackPosition = false
                guard finished else { return }
                self.currentTime = max(0, record.position)
                if autoplay {
                    self.player.playImmediately(atRate: self.playbackRate)
                    self.isPlaying = true
                } else {
                    self.player.pause()
                    self.isPlaying = false
                }
            }
        }
        isPreparingVideo = false
        preparationProgress = nil
        statusMessage = "Listo"
    }

    private func prepareTransportStream(_ item: LibraryItem, autoplay: Bool) {
        guard let dataDirectory,
              let ffmpeg = ffmpegExecutableURL() else {
            statusMessage = "FFmpeg es necesario para este archivo .ts"
            issue = AppIssue(title: "No se puede abrir este video .ts",
                             message: "Course Player puede buscar y configurar FFmpeg por ti.",
                             action: .findFFmpeg)
            return
        }
        let cacheRoot = dataDirectory.appendingPathComponent("video-cache", isDirectory: true)
        let output = cacheRoot.appendingPathComponent(item.relativePath).deletingPathExtension().appendingPathExtension("mp4")
        let sourceDate = (try? item.url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantFuture
        let outputDate = (try? output.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if FileManager.default.fileExists(atPath: output.path), outputDate >= sourceDate {
            play(output, for: item, autoplay: autoplay)
            return
        }

        isPreparingVideo = true
        preparationProgress = 0
        conversionWasCancelled = false
        isPlaying = false
        player.replaceCurrentItem(with: nil)
        statusMessage = "Preparando video por primera vez…"
        try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = output.deletingPathExtension().appendingPathExtension("partial.mp4")
        try? FileManager.default.removeItem(at: partial)

        let process = Process()
        process.executableURL = ffmpeg
        process.arguments = ["-hide_banner", "-loglevel", "error", "-y", "-i", item.url.path,
                             "-map", "0:v:0?", "-map", "0:a:0?", "-c", "copy", partial.path]
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        process.terminationHandler = { [weak self] finished in
            let errorData = errors.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(data: errorData, encoding: .utf8) ?? ""
            Task { @MainActor in
                guard let self, self.selectedItem?.id == item.id else { return }
                self.conversionProgressTimer?.cancel()
                self.conversionProgressTimer = nil
                self.conversionProcess = nil
                if self.conversionWasCancelled {
                    self.conversionWasCancelled = false
                    try? FileManager.default.removeItem(at: partial)
                    return
                }
                if finished.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: output)
                    do {
                        try FileManager.default.moveItem(at: partial, to: output)
                        self.pruneVideoCache(at: cacheRoot, keeping: output)
                        self.play(output, for: item, autoplay: autoplay)
                    } catch {
                        self.isPreparingVideo = false
                        self.statusMessage = "No se pudo guardar el video preparado"
                        self.issue = AppIssue(title: "No se pudo guardar el video",
                                             message: "Comprueba el espacio disponible y los permisos de la biblioteca.",
                                             action: .retryVideo)
                    }
                } else {
                    self.isPreparingVideo = false
                    self.statusMessage = errorText.isEmpty ? "No se pudo preparar este video" : "No se pudo preparar este video"
                    self.issue = AppIssue(title: "No se pudo preparar el video",
                                         message: errorText.isEmpty ? "FFmpeg terminó con un error desconocido." : errorText,
                                         action: .retryVideo)
                }
            }
        }
        conversionProcess = process
        do {
            try process.run()
            let sourceBytes = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if sourceBytes > 0 {
                let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
                timer.schedule(deadline: .now() + 0.4, repeating: 0.5)
                timer.setEventHandler { [weak self] in
                    let outputBytes = (try? partial.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                    Task { @MainActor in
                        guard let self, self.isPreparingVideo else { return }
                        self.preparationProgress = min(0.99, Double(outputBytes) / Double(sourceBytes))
                    }
                }
                conversionProgressTimer = timer
                timer.resume()
            }
        }
        catch {
            conversionProcess = nil
            isPreparingVideo = false
            statusMessage = "No se pudo iniciar el componente de video"
            issue = AppIssue(title: "No se pudo iniciar FFmpeg", message: error.localizedDescription,
                             action: .findFFmpeg)
        }
    }

    private func ffmpegExecutableURL() -> URL? {
        let manager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
            preservedFFmpegURL,
            ProcessInfo.processInfo.environment["FFMPEG_PATH"].map { URL(fileURLWithPath: $0) },
            UserDefaults.standard.string(forKey: savedFFmpegKey).map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first { manager.isExecutableFile(atPath: $0.path) }
    }

    private var preservedFFmpegURL: URL? {
        guard let support = try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ) else { return nil }
        return support.appendingPathComponent("Course Player", isDirectory: true)
            .appendingPathComponent("Tools", isDirectory: true)
            .appendingPathComponent("ffmpeg")
    }

    private func preserveConfiguredFFmpeg() {
        guard let savedPath = UserDefaults.standard.string(forKey: savedFFmpegKey) else { return }
        let source = URL(fileURLWithPath: savedPath)
        if let preserved = preserveFFmpeg(from: source) {
            UserDefaults.standard.set(preserved.path, forKey: savedFFmpegKey)
        }
    }

    @discardableResult private func adoptAutomaticallyAvailableFFmpeg() -> Bool {
        if let existing = ffmpegExecutableURL() {
            if let preserved = preserveFFmpeg(from: existing) {
                UserDefaults.standard.set(preserved.path, forKey: savedFFmpegKey)
            }
            return true
        }
        for candidate in installedApplicationFFmpegCandidates()
            where FileManager.default.isExecutableFile(atPath: candidate.path) {
            guard let preserved = preserveFFmpeg(from: candidate) else { continue }
            UserDefaults.standard.set(preserved.path, forKey: savedFFmpegKey)
            return true
        }
        return false
    }

    private func installedApplicationFFmpegCandidates() -> [URL] {
        let roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]
        return roots.flatMap { root in
            let applications = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            return applications.filter { $0.pathExtension.lowercased() == "app" }.flatMap { application in
                [
                    application.appendingPathComponent("Contents/Resources/ffmpeg"),
                    application.appendingPathComponent("Contents/MacOS/ffmpeg")
                ]
            }
        }
    }

    private func preserveFFmpeg(from source: URL) -> URL? {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: source.path), let destination = preservedFFmpegURL else { return nil }
        if source.standardizedFileURL == destination.standardizedFileURL { return destination }
        if manager.isExecutableFile(atPath: destination.path) { return destination }
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent("ffmpeg.partial")
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try? manager.removeItem(at: temporary)
            try manager.copyItem(at: source, to: temporary)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try manager.moveItem(at: temporary, to: destination)
            }
            return destination
        } catch {
            try? manager.removeItem(at: temporary)
            return nil
        }
    }

    private func pruneVideoCache(at root: URL, keeping current: URL) {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return }
        let files = (enumerator.allObjects as? [URL] ?? []).filter { $0.pathExtension.lowercased() == "mp4" }
        let sorted = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
        for url in sorted.dropFirst(3) where url != current { try? FileManager.default.removeItem(at: url) }
    }

    private func installTimeObserver() {
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self, let item = self.selectedItem else { return }
                guard !self.isRestoringPlaybackPosition else { return }
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                self.isPlaying = self.player.rate != 0
                var record = self.progress.records[item.relativePath] ?? ProgressRecord()
                record.position = self.currentTime
                record.duration = self.duration
                if record.completionSource == "reset", self.currentTime > 1 { record.completionSource = nil }
                self.progress.records[item.relativePath] = record
                self.saveProgressCheckpointIfNeeded()
            }
        }
    }

    private func startWatchingLibrary() {
        stopWatchingLibrary()
        guard let rootURL else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            libraryEventsCallback,
            &context,
            [rootURL.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            2.0,
            flags
        ) else { return }
        libraryEventStream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    private func stopWatchingLibrary() {
        scanTask?.cancel()
        scanTask = nil
        guard let stream = libraryEventStream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        libraryEventStream = nil
    }

    fileprivate func handleLibraryEvents(_ paths: [String]) {
        guard let rootURL else { return }
        let ignoredRoots = [
            rootURL.appendingPathComponent(".course-player", isDirectory: true).standardizedFileURL.path,
            rootURL.appendingPathComponent("Course Player Notes", isDirectory: true).standardizedFileURL.path,
            rootURL.appendingPathComponent("Course Player.app", isDirectory: true).standardizedFileURL.path
        ]
        let containsLibraryChange = paths.contains { path in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            return !ignoredRoots.contains { normalized == $0 || normalized.hasPrefix($0 + "/") }
        }
        guard containsLibraryChange else { return }

        scanTask?.cancel()
        scanTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.scan(silently: true)
        }
    }
}
