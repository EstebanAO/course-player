import SwiftUI
import AVFoundation
import AppKit
import CoreServices
import UniformTypeIdentifiers

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
    @Published var noteText = ""
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var playbackRate: Float = 1
    @Published var isScanning = false
    @Published var isPreparingVideo = false
    @Published var statusMessage = ""

    let player = AVPlayer()
    private var progress = ProgressFile()
    private var timeObserver: Any?
    private var noteSaveTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var conversionProcess: Process?
    private var libraryEventStream: FSEventStreamRef?
    private var lastProgressSave = Date.distantPast
    private var didStart = false
    private var didRestoreLastVideo = false
    private let savedLibraryKey = "CoursePlayerLibraryPath"

    private let videoExtensions: Set<String> = ["ts", "mp4", "mov", "m4v"]
    private let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff"]
    private let documentExtensions: Set<String> = ["pdf", "doc", "docx", "txt", "md", "epub"]
    private let ignoredNames: Set<String> = ["Course Player Notes", "Course Player.app"]

    var filteredItems: [LibraryItem] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return items }
        return flatten(items).filter {
            $0.kind != .folder && $0.name.localizedCaseInsensitiveContains(query)
                || $0.relativePath.localizedCaseInsensitiveContains(query)
        }
    }

    var selectedProgress: ProgressRecord {
        guard let path = selectedItem?.relativePath else { return ProgressRecord() }
        return progress.records[path] ?? ProgressRecord()
    }

    var totalVideos: Int { flatten(items).filter { $0.kind == .video }.count }
    var completedVideos: Int {
        flatten(items).filter { $0.kind == .video && isCompleted($0) }.count
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        installTimeObserver()

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
    }

    func chooseLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Elige la carpeta que contiene tus cursos"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = rootURL
        if panel.runModal() == .OK, let url = panel.url {
            saveCurrentNoteNow()
            stopWatchingLibrary()
            rootURL = url
            UserDefaults.standard.set(url.path, forKey: savedLibraryKey)
            selectedItem = nil
            player.replaceCurrentItem(with: nil)
            didRestoreLastVideo = false
            loadProgress()
            scan()
            startWatchingLibrary()
            restoreLastVideo()
        }
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
        open(item, autoplay: true)
    }

    private func open(_ item: LibraryItem, autoplay: Bool) {
        guard item.kind != .folder else { return }
        if item.kind == .document {
            NSWorkspace.shared.open(item.url)
            return
        }
        guard item.isPlayable else { return }
        saveCurrentNoteNow()
        storeCurrentPosition()
        conversionProcess?.terminate()
        conversionProcess = nil
        isPreparingVideo = false
        selectedItem = item
        loadNote(for: item)
        let record = progress.records[item.relativePath] ?? ProgressRecord()
        var updated = record
        updated.lastOpened = .now
        progress.records[item.relativePath] = updated
        scheduleProgressSave()
        if item.url.pathExtension.lowercased() == "ts" {
            prepareTransportStream(item, autoplay: autoplay)
        } else {
            play(item.url, for: item, autoplay: autoplay)
        }
    }

    func togglePlayback() {
        guard selectedItem?.isPlayable == true, !isPreparingVideo else { return }
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
        if isPlaying { player.rate = rate }
    }

    func toggleCompleted() {
        guard let item = selectedItem else { return }
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.completed.toggle()
        if record.completed, duration > 0 { record.position = duration }
        progress.records[item.relativePath] = record
        objectWillChange.send()
        scheduleProgressSave()
    }

    func setNoteText(_ text: String) {
        noteText = text
        noteSaveTask?.cancel()
        noteSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveCurrentNoteNow()
        }
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
    }

    func progressForCourse(_ item: LibraryItem) -> Double {
        let videos = flatten(item.children ?? []).filter { $0.kind == .video }
        guard !videos.isEmpty else { return 0 }
        let done = videos.filter { progress.records[$0.relativePath]?.completed == true }.count
        return Double(done) / Double(videos.count)
    }

    func isCompleted(_ item: LibraryItem) -> Bool {
        progress.records[item.relativePath]?.completed == true
    }

    func progressFraction(for item: LibraryItem) -> Double {
        guard let record = progress.records[item.relativePath], record.duration > 0 else { return 0 }
        return min(1, max(0, record.position / record.duration))
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

    private func relativePath(for url: URL, root: URL) -> String {
        String(url.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private var dataDirectory: URL? { rootURL?.appendingPathComponent(".course-player", isDirectory: true) }
    private var progressURL: URL? { dataDirectory?.appendingPathComponent("progress.json") }

    private func loadProgress() {
        progress = ProgressFile()
        lastProgressSave = .now
        guard let url = progressURL, let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let decoded = try? decoder.decode(ProgressFile.self, from: data) else { return }
        progress = decoded
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
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(progress) {
            try? data.write(to: url, options: .atomic)
            lastProgressSave = .now
        }
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
        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            noteText = existing
        } else {
            let escapedPath = item.relativePath.replacingOccurrences(of: "\"", with: "\\\"")
            noteText = "---\nvideo: \"\(escapedPath)\"\ncurso: \"\(item.relativePath.split(separator: "/").first ?? "")\"\n---\n\n# \(item.name)\n\n## Ideas principales\n\n- \n\n## Reflexiones\n\n"
        }
    }

    private func saveCurrentNoteNow() {
        guard let item = selectedItem, let url = noteURL(for: item) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? noteText.write(to: url, atomically: true, encoding: .utf8)
    }

    private func storeCurrentPosition() {
        guard let item = selectedItem else { return }
        var record = progress.records[item.relativePath] ?? ProgressRecord()
        record.position = currentTime
        record.duration = duration
        record.lastOpened = .now
        if duration > 0, currentTime / duration >= 0.9 { record.completed = true }
        progress.records[item.relativePath] = record
        saveProgressNow()
    }

    private func restoreLastVideo() {
        guard !didRestoreLastVideo else { return }
        didRestoreLastVideo = true
        let videos = flatten(items).filter { $0.kind == .video }
        guard let last = videos.max(by: {
            let first = progress.records[$0.relativePath]?.lastOpened ?? .distantPast
            let second = progress.records[$1.relativePath]?.lastOpened ?? .distantPast
            return first < second
        }), progress.records[last.relativePath] != nil else { return }
        open(last, autoplay: false)
    }

    private func play(_ url: URL, for item: LibraryItem, autoplay: Bool) {
        guard selectedItem?.id == item.id else { return }
        let record = progress.records[item.relativePath] ?? ProgressRecord()
        currentTime = record.position
        duration = record.duration
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.seek(to: CMTime(seconds: record.position, preferredTimescale: 600))
        if autoplay {
            player.playImmediately(atRate: playbackRate)
            isPlaying = true
        } else {
            player.pause()
            isPlaying = false
        }
        isPreparingVideo = false
        statusMessage = "Listo"
    }

    private func prepareTransportStream(_ item: LibraryItem, autoplay: Bool) {
        guard let dataDirectory,
              let ffmpeg = ffmpegExecutableURL() else {
            statusMessage = "Instala FFmpeg o define FFMPEG_PATH para reproducir archivos .ts"
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
                self.conversionProcess = nil
                if finished.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: output)
                    do {
                        try FileManager.default.moveItem(at: partial, to: output)
                        self.pruneVideoCache(at: cacheRoot, keeping: output)
                        self.play(output, for: item, autoplay: autoplay)
                    } catch {
                        self.isPreparingVideo = false
                        self.statusMessage = "No se pudo guardar el video preparado"
                    }
                } else {
                    self.isPreparingVideo = false
                    self.statusMessage = errorText.isEmpty ? "No se pudo preparar este video" : "No se pudo preparar este video"
                }
            }
        }
        conversionProcess = process
        do { try process.run() }
        catch {
            conversionProcess = nil
            isPreparingVideo = false
            statusMessage = "No se pudo iniciar el componente de video"
        }
    }

    private func ffmpegExecutableURL() -> URL? {
        let manager = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.url(forResource: "ffmpeg", withExtension: nil),
            ProcessInfo.processInfo.environment["FFMPEG_PATH"].map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first { manager.isExecutableFile(atPath: $0.path) }
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
                self.currentTime = max(0, time.seconds.isFinite ? time.seconds : 0)
                let itemDuration = self.player.currentItem?.duration.seconds ?? 0
                if itemDuration.isFinite, itemDuration > 0 { self.duration = itemDuration }
                self.isPlaying = self.player.rate != 0
                var record = self.progress.records[item.relativePath] ?? ProgressRecord()
                record.position = self.currentTime
                record.duration = self.duration
                if self.duration > 0, self.currentTime / self.duration >= 0.9 { record.completed = true }
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
