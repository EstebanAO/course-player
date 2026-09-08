import SwiftUI
import AVFoundation
import VisionKit
import ImageIO

/// Displays a selectable Live Text layer for the current video frame while playback is paused.
struct PausedVideoTextOverlay: NSViewRepresentable {
    let player: AVPlayer
    let videoID: String
    let time: Double
    let isActive: Bool
    let onBackgroundClick: () -> Void
    let onAddToNotes: (String) -> Void

    func makeNSView(context: Context) -> PausedVideoTextContainer {
        PausedVideoTextContainer()
    }

    func updateNSView(_ view: PausedVideoTextContainer, context: Context) {
        view.configure(
            player: player,
            videoID: videoID,
            time: time,
            isActive: isActive,
            onBackgroundClick: onBackgroundClick,
            onAddToNotes: onAddToNotes
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PausedVideoTextContainer,
                      context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else { return nil }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ view: PausedVideoTextContainer, coordinator: ()) {
        view.deactivate()
    }
}

@MainActor
final class PausedVideoTextContainer: NSView, ImageAnalysisOverlayViewDelegate {
    private let imageView = NSImageView()
    private lazy var analysisView = ImageAnalysisOverlayView(self)
    private let statusBackground = NSVisualEffectView()
    private let statusSpinner = NSProgressIndicator()
    private let statusLabel = NSTextField(labelWithString: "Reconociendo texto…")
    private var recognitionTask: Task<Void, Never>?
    private var requestID = UUID()
    private var displayedVideoID = ""
    private var displayedTime = -Double.infinity
    private var backgroundAction: (() -> Void)?
    private var addToNotesAction: ((String) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        // The paused AVPlayer remains the visual source of truth. VisionKit still
        // tracks this image to position Live Text, but the captured frame must not
        // replace the player because anamorphic video can otherwise appear zoomed.
        imageView.alphaValue = 0.001
        imageView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        imageView.setContentHuggingPriority(.defaultLow, for: .vertical)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        analysisView.preferredInteractionTypes = [.textSelection]
        analysisView.trackingImageView = imageView
        analysisView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(analysisView)

        statusBackground.material = .hudWindow
        statusBackground.blendingMode = .withinWindow
        statusBackground.state = .active
        statusBackground.wantsLayer = true
        statusBackground.layer?.cornerRadius = 9
        statusBackground.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusBackground)

        statusSpinner.style = .spinning
        statusSpinner.controlSize = .small
        statusSpinner.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.textColor = .white
        statusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusBackground.addSubview(statusSpinner)
        statusBackground.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            analysisView.leadingAnchor.constraint(equalTo: leadingAnchor),
            analysisView.trailingAnchor.constraint(equalTo: trailingAnchor),
            analysisView.topAnchor.constraint(equalTo: topAnchor),
            analysisView.bottomAnchor.constraint(equalTo: bottomAnchor),
            statusBackground.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            statusBackground.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusSpinner.leadingAnchor.constraint(equalTo: statusBackground.leadingAnchor, constant: 10),
            statusSpinner.centerYAnchor.constraint(equalTo: statusBackground.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: statusSpinner.trailingAnchor, constant: 7),
            statusLabel.trailingAnchor.constraint(equalTo: statusBackground.trailingAnchor, constant: -10),
            statusLabel.topAnchor.constraint(equalTo: statusBackground.topAnchor, constant: 7),
            statusLabel.bottomAnchor.constraint(equalTo: statusBackground.bottomAnchor, constant: -7)
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.buttonMask = 0x1
        addGestureRecognizer(click)
        showStatus(false)
    }

    required init?(coder: NSCoder) { nil }

    func configure(
        player: AVPlayer,
        videoID: String,
        time: Double,
        isActive: Bool,
        onBackgroundClick: @escaping () -> Void,
        onAddToNotes: @escaping (String) -> Void
    ) {
        backgroundAction = onBackgroundClick
        addToNotesAction = onAddToNotes
        guard isActive, player.currentItem != nil else {
            deactivate()
            return
        }

        let safeTime = time.isFinite ? max(0, time) : 0
        guard displayedVideoID != videoID || abs(displayedTime - safeTime) > 0.35 else { return }
        scheduleRecognition(player: player, videoID: videoID, time: safeTime)
    }

    func deactivate() {
        requestID = UUID()
        recognitionTask?.cancel()
        recognitionTask = nil
        analysisView.resetSelection()
        analysisView.analysis = nil
        imageView.image = nil
        displayedVideoID = ""
        displayedTime = -Double.infinity
        showStatus(false)
    }

    private func scheduleRecognition(player: AVPlayer, videoID: String, time: Double) {
        requestID = UUID()
        let currentRequest = requestID
        recognitionTask?.cancel()
        analysisView.resetSelection()
        analysisView.analysis = nil
        showStatus(true)

        guard let asset = player.currentItem?.asset else {
            showUnavailable()
            return
        }

        recognitionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled else { return }

            let result: Result<CGImage, Error> = await Task.detached(priority: .userInitiated) {
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.12, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.12, preferredTimescale: 600)
                do {
                    return .success(try generator.copyCGImage(
                        at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil
                    ))
                } catch {
                    return .failure(error)
                }
            }.value

            guard !Task.isCancelled, let self, self.requestID == currentRequest else { return }
            switch result {
            case .success(let cgImage):
                let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                self.imageView.image = image
                self.displayedVideoID = videoID
                self.displayedTime = time

                guard ImageAnalyzer.isSupported else {
                    self.showUnavailable()
                    return
                }
                do {
                    var configuration = ImageAnalyzer.Configuration([.text])
                    let preferred = ["es", "en"]
                    configuration.locales = preferred.filter {
                        ImageAnalyzer.supportedTextRecognitionLanguages.contains($0)
                    }
                    let analysis = try await ImageAnalyzer().analyze(
                        cgImage, orientation: .up, configuration: configuration
                    )
                    guard !Task.isCancelled, self.requestID == currentRequest else { return }
                    self.analysisView.analysis = analysis
                    self.showStatus(false)
                } catch {
                    self.showUnavailable()
                }
            case .failure:
                self.showUnavailable()
            }
        }
    }

    private func showUnavailable() {
        statusSpinner.stopAnimation(nil)
        statusLabel.stringValue = "No se encontró texto"
        statusBackground.isHidden = false
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.showStatus(false)
        }
    }

    private func showStatus(_ visible: Bool) {
        statusBackground.isHidden = !visible
        statusLabel.stringValue = "Reconociendo texto…"
        if visible { statusSpinner.startAnimation(nil) } else { statusSpinner.stopAnimation(nil) }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        let point = recognizer.location(in: analysisView)
        if analysisView.hasActiveTextSelection {
            analysisView.resetSelection()
            return
        }
        guard !analysisView.analysisHasText(at: point) else { return }
        backgroundAction?()
    }

    func contentsRect(for overlayView: ImageAnalysisOverlayView) -> CGRect {
        guard let image = imageView.image, image.size.width > 0, image.size.height > 0 else { return bounds }
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                      width: size.width, height: size.height)
    }

    func contentView(for overlayView: ImageAnalysisOverlayView) -> NSView? { imageView }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldBeginAt point: CGPoint,
                     forAnalysisType analysisType: ImageAnalysisOverlayView.InteractionTypes) -> Bool {
        true
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldHandleKeyDownEvent event: NSEvent) -> Bool {
        true
    }

    func overlayView(_ overlayView: ImageAnalysisOverlayView, shouldShowMenuForEvent event: NSEvent,
                     atPoint point: CGPoint) -> Bool {
        true
    }

    @available(macOS 14.0, *)
    func overlayView(_ overlayView: ImageAnalysisOverlayView, updatedMenuFor menu: NSMenu,
                     for event: NSEvent, at point: CGPoint) -> NSMenu {
        guard !overlayView.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return menu }
        menu.addItem(.separator())
        let item = NSMenuItem(title: "Añadir a las notas con la hora", action: #selector(addSelectionToNotes), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func addSelectionToNotes() {
        guard #available(macOS 14.0, *) else { return }
        let text = analysisView.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        addToNotesAction?(text)
        analysisView.resetSelection()
    }
}
