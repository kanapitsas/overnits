import AppKit
import Metal
import QuartzCore
import CoreImage

// ---------------------------------------------------------------------------
// Overlay plein écran : couche Metal en EDR (valeurs > 1.0) composée avec le
// bureau en "multiply". resultat = pixel_bureau * boost, en lumière linéaire.
// Les noirs restent noirs, le blanc SDR (600 nits) monte à 600 * boost nits.
// ---------------------------------------------------------------------------

final class BoostOverlay {
    let window: NSWindow
    let metalLayer = CAMetalLayer()
    let queue: MTLCommandQueue
    var boost: Float = 1.0
    var lastHeadroom: Float = 1.0
    var lastEffective: Float = 1.0
    var lastAlpha: Float = 1.0
    var lastK: Float = 1.0

    init(screen: NSScreen, device: MTLDevice, queue: MTLCommandQueue) {
        self.queue = queue

        window = NSWindow(contentRect: screen.frame,
                          styleMask: .borderless,
                          backing: .buffered,
                          defer: false,
                          screen: screen)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .screenSaver
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]

        metalLayer.device = device
        metalLayer.pixelFormat = .rgba16Float
        metalLayer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metalLayer.wantsExtendedDynamicRangeContent = true
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = screen.backingScaleFactor
        switch Options.filter {
        case "ci":     metalLayer.compositingFilter = CIFilter(name: "CIMultiplyBlendMode")
        case "add":    metalLayer.compositingFilter = "linearDodgeBlendMode"
        case "screen": metalLayer.compositingFilter = "screenBlendMode"
        case "none":   metalLayer.compositingFilter = nil
        default:       metalLayer.compositingFilter = "multiplyBlendMode"
        }

        let view = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        view.layer = metalLayer
        window.contentView = view

        resize(to: screen)
    }

    func resize(to screen: NSScreen) {
        window.setFrame(screen.frame, display: true)
        let scale = screen.backingScaleFactor
        metalLayer.frame = CGRect(origin: .zero, size: screen.frame.size)
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: screen.frame.width * scale,
                                         height: screen.frame.height * scale)
    }

    func render() {
        guard abs(boost - 1.0) > 0.001 else { window.orderOut(nil); return }
        if !window.isVisible { window.orderFrontRegardless() }
        // La reserve EDR depend de la luminosite courante de la dalle : au
        // dela, les blancs seraient simplement ecretes. On plafonne.
        let headroom = Float(window.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        // Marge de securite : au-dela de la reserve, le resultat sature en blanc.
        lastHeadroom = headroom

        // Le multiply avec opacite a donne : dst * (1 - a + k*a).
        // Un meme facteur peut donc s'obtenir avec un k eleve et un a faible.
        // Interet : la ou le filtre perd son arriere-plan (plan video materiel,
        // transition de bureau), la couche retombe en dessin normal et ne
        // montre plus qu'un voile de a, au lieu d'un blanc opaque.
        var premul: Double
        var alpha: Double
        if boost < 1.0 {
            premul = Double(boost); alpha = 1.0
            lastEffective = boost
        } else {
            let k = max(1.05, min(headroom * 0.95, 4.0))
            let a = min(max((boost - 1.0) / (k - 1.0), 0.0), 1.0)
            premul = Double(k * a); alpha = Double(a)
            lastEffective = 1.0 + a * (k - 1.0)
            lastAlpha = a
            lastK = k
        }
        guard let drawable = metalLayer.nextDrawable(),
              let buffer = queue.makeCommandBuffer() else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: premul,
                                                            green: premul,
                                                            blue: premul,
                                                            alpha: alpha)
        buffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }
}

enum Options {
    static func value(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    static let filter  = value("--filter") ?? "multiply"
    static let boost   = Float(value("--boost") ?? "") ?? 1.0
    static let seconds = Double(value("--seconds") ?? "") ?? 0
    static let log     = CommandLine.arguments.contains("--log")
}

final class Controller: NSObject, NSApplicationDelegate {
    var startBoost: Float = 1.0
    var overlays: [BoostOverlay] = []
    let device = MTLCreateSystemDefaultDevice()!
    var queue: MTLCommandQueue!
    var statusItem: NSStatusItem!
    var timer: Timer?
    var boost: Float = 1.0 { didSet { overlays.forEach { $0.boost = boost }; renderAll(); updateTitle() } }
    var testSeconds: Double = 0

    func applicationDidFinishLaunching(_ n: Notification) {
        queue = device.makeCommandQueue()
        rebuild()
        setupMenu()
        NotificationCenter.default.addObserver(self,
            selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Pendant le changement de bureau, le serveur de fenetres capture une
        // image de chaque fenetre. Une fenetre a filtre de composition n'a pas
        // d'image propre et sort en blanc : on l'efface le temps de l'animation.
        NSWorkspace.shared.notificationCenter.addObserver(self,
            selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            self?.renderAll()
        }
        if abs(startBoost - 1.0) > 0.001 { boost = startBoost }
        if Options.log {
            var t = 0.0
            Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
                t += 0.4
                for o in self.overlays {
                    print(String(format: "t=%5.1fs  reserve=%.3f  facteur=%.3f  k=%.2f  opacite=%.0f%%", t, o.lastHeadroom, o.lastEffective, o.lastK, o.lastAlpha * 100))
                }
            }
        }
        if testSeconds > 0 {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in self.printHeadroom("EDR actif") }
            Timer.scheduledTimer(withTimeInterval: self.testSeconds, repeats: false) { _ in NSApp.terminate(nil) }
        }
    }

    func printHeadroom(_ label: String) {
        for s in NSScreen.screens {
            let cur = s.maximumExtendedDynamicRangeColorComponentValue
            let pot = s.maximumPotentialExtendedDynamicRangeColorComponentValue
            let ref = s.maximumReferenceExtendedDynamicRangeColorComponentValue
            print("\(label) — \(s.localizedName): courant=\(cur)  potentiel=\(pot)  reference=\(ref)")
        }
    }

    @objc func screensChanged() { rebuild(); renderAll() }

    private var resumeWork: DispatchWorkItem?

    @objc func spaceChanged() {
        overlays.forEach { $0.window.orderOut(nil) }
        resumeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.boost > 1.001 else { return }
            self.rebuild()
            self.renderAll()
        }
        resumeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: work)
    }

    func rebuild() {
        overlays.forEach { $0.window.orderOut(nil) }
        overlays = NSScreen.screens.map { BoostOverlay(screen: $0, device: device, queue: queue) }
        overlays.forEach { $0.boost = boost }
    }

    func renderAll() { overlays.forEach { $0.render() } }

    func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        for value: Float in [1.0, 1.25, 1.5, 1.75, 2.0, 2.5] {
            let title = value == 1.0 ? "Desactive (SDR)" : String(format: "x%.2f", value)
            let item = NSMenuItem(title: title, action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let q = NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(q)
        statusItem.menu = menu
        updateTitle()
    }

    @objc func pick(_ sender: NSMenuItem) {
        boost = sender.representedObject as? Float ?? 1.0
    }

    func updateTitle() {
        statusItem?.button?.title = boost > 1.001 ? String(format: "☀︎ x%.2f", boost) : "☀︎"
    }

    func applicationWillTerminate(_ n: Notification) {
        overlays.forEach { $0.window.orderOut(nil) }
    }
}

let app = NSApplication.shared
let controller = Controller()
controller.testSeconds = Options.seconds
controller.startBoost = Options.boost
print("filtre=\(Options.filter)  boost=\(Options.boost)  duree=\(Options.seconds)s")
app.delegate = controller
app.setActivationPolicy(.accessory)
controller.printHeadroom("Avant")
app.run()
