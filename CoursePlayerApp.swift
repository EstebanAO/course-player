import SwiftUI
import AppKit

@main
struct CoursePlayerApp: App {
    @StateObject private var library = LibraryModel()

    var body: some Scene {
        WindowGroup("Course Player") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1080, minHeight: 680)
                .onAppear { library.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    library.flushBeforeClosing()
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Actualizar biblioteca") { library.scan() }
                    .keyboardShortcut("r", modifiers: [.command])
                Button("Elegir carpeta de cursos…") { library.chooseLibrary() }
            }
            CommandMenu("Reproducción") {
                Button("Reproducir / Pausar") { library.togglePlayback() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Button("Video anterior") { library.playPrevious() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                    .disabled(library.previousItem == nil)
                Button("Siguiente video") { library.playNext() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(library.nextItem == nil)
                Button("Retroceder 15 segundos") { library.skip(seconds: -15) }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("Adelantar 15 segundos") { library.skip(seconds: 15) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }

        Settings {
            CoursePlayerSettingsView()
                .environmentObject(library)
                .frame(width: 460)
        }
    }
}

private struct CoursePlayerSettingsView: View {
    @EnvironmentObject private var library: LibraryModel

    var body: some View {
        Form {
            Section("Reproducción") {
                Picker("Velocidad preferida", selection: Binding(
                    get: { Double(library.playbackRate) },
                    set: { library.setRate(Float($0)) }
                )) {
                    ForEach([0.5, 0.75, 1, 1.25, 1.5, 1.75, 2], id: \.self) { rate in
                        Text("\(rate.formatted())×").tag(rate)
                    }
                }
            }
            Section("Biblioteca") {
                LabeledContent("Carpeta") {
                    Text(library.rootURL?.lastPathComponent ?? "Sin elegir")
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                HStack {
                    Button("Elegir otra…") { library.chooseLibrary() }
                    Button("Mostrar en Finder") { library.revealLibrary() }
                        .disabled(library.rootURL == nil)
                }
            }
            Section("Videos .ts") {
                LabeledContent("FFmpeg") {
                    Label(library.isFFmpegReady ? "Listo" : "No configurado",
                          systemImage: library.isFFmpegReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(library.isFFmpegReady ? Color.green : Color.orange)
                }
                HStack {
                    Button("Buscar automáticamente") { library.configureFFmpegAutomatically() }
                    Button("Elegir archivo…") { library.chooseFFmpeg() }
                }
            }
            Section {
                Text("Las notas y el progreso se guardan dentro de la biblioteca. Course Player no envía datos a internet.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 12)
    }
}
