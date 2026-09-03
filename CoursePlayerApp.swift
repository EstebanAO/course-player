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
                    .keyboardShortcut(.space, modifiers: [])
                Button("Retroceder 15 segundos") { library.skip(seconds: -15) }
                    .keyboardShortcut("j", modifiers: [.command, .option])
                Button("Adelantar 15 segundos") { library.skip(seconds: 15) }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
    }
}
