// overnits — unlock the XDR brightness range for ordinary macOS content.
// Copyright (C) 2026 kanapitsas
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the LICENSE file for details.
//
// The technique used here (a one-pixel EDR window to engage HDR mode, plus a
// scaled display gamma table) was learned from BrightIntosh by Niklas Rousset,
// https://github.com/niklasr22/BrightIntosh — also GPL v3. This is an
// independent implementation.

import AppKit
import Metal
import MetalKit
import CoreGraphics
import Carbon.HIToolbox

// ---------------------------------------------------------------------------
// Deux etages, entierement independants :
//
//  1. Une fenetre EDR de 1x1 pixel dans un coin de l'ecran. Elle n'est la que
//     pour faire basculer la dalle en mode HDR : macOS monte le retroeclairage
//     des qu'un contenu EDR est visible, quelle que soit sa taille.
//
//  2. La table gamma de l'ecran, multipliee par le facteur voulu. Le gamma
//     s'applique tout en fin de pipeline d'affichage, donc a tout ce qui est
//     affiche : plans video materiels, transitions de bureau, curseur. Rien
//     n'est compose par-dessus quoi que ce soit, donc rien ne peut blanchir.
// ---------------------------------------------------------------------------

enum Options {
    static func value(_ n: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: n),
              i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }
    // nil si --boost est absent : un --boost 1.0 explicite doit pouvoir
    // l'emporter sur le niveau memorise (cf. README, section Caveats).
    static let boost   = value("--boost").flatMap { Float($0) }
    static let seconds = Double(value("--seconds") ?? "") ?? 0
    static let log     = CommandLine.arguments.contains("--log")
}

func displayId(of screen: NSScreen) -> CGDirectDisplayID? {
    screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
}

// --- Etage 2 : table gamma -------------------------------------------------

final class GammaTable {
    let display: CGDirectDisplayID
    private var red = [CGGammaValue](repeating: 0, count: 256)
    private var green = [CGGammaValue](repeating: 0, count: 256)
    private var blue = [CGGammaValue](repeating: 0, count: 256)

    init?(display: CGDirectDisplayID) {
        self.display = display
        var count: UInt32 = 0
        let err = CGGetDisplayTransferByTable(display, 256, &red, &green, &blue, &count)
        guard err == .success, count == 256 else { return nil }
    }

    @discardableResult
    func apply(factor: Float) -> CGError {
        // Les valeurs depassent 1.0 : en mode HDR c'est exactement ce qui
        // adresse la plage au-dela du blanc SDR.
        var r = red.map { $0 * factor }
        var g = green.map { $0 * factor }
        var b = blue.map { $0 * factor }
        return CGSetDisplayTransferByTable(display, 256, &r, &g, &b)
    }

    @discardableResult
    func restore() -> CGError {
        CGSetDisplayTransferByTable(display, 256, &red, &green, &blue)
    }
}

// --- Etage 1 : declencheur HDR d'un pixel ----------------------------------

final class HDRTrigger: NSObject, MTKViewDelegate {
    let window: NSWindow
    private let view: MTKView
    private let queue: MTLCommandQueue

    init?(screen: NSScreen) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let q = device.makeCommandQueue() else { return nil }
        queue = q

        let rect = NSRect(x: 0, y: 0, width: 1, height: 1)
        window = NSWindow(contentRect: rect, styleMask: [], backing: .buffered, defer: false)
        window.collectionBehavior = [.stationary, .canJoinAllSpaces, .ignoresCycle]
        window.level = .screenSaver
        window.animationBehavior = .none
        window.isOpaque = false
        window.hasShadow = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.canHide = false

        view = MTKView(frame: rect, device: device)
        view.autoResizeDrawable = false
        view.drawableSize = CGSize(width: 1, height: 1)
        view.colorPixelFormat = .rgba16Float
        view.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)
        view.clearColor = MTLClearColorMake(1.6, 1.6, 1.6, 1.0)
        view.preferredFramesPerSecond = 5
        if let layer = view.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.isOpaque = false
            layer.pixelFormat = .rgba16Float
        }
        super.init()
        view.delegate = self
        window.contentView = view

        var origin = screen.frame.origin
        origin.y += screen.frame.height - 1
        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let buffer = queue.makeCommandBuffer(),
              let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.endEncoding()
        buffer.present(drawable)
        buffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func close() { window.orderOut(nil) }
}

// --- Raccourcis clavier globaux --------------------------------------------
//
// RegisterEventHotKey est l'API Carbon historique. Contrairement a un capteur
// d'evenements, elle ne demande aucune autorisation Accessibilite. Les touches
// de luminosite du clavier, elles, sont consommees par le systeme avant
// d'atteindre les applications, et ne sont donc pas exploitables ici.

final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private static var actions: [UInt32: () -> Void] = [:]

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: OSType(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { HotKeys.actions[id.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(id: UInt32, keyCode: Int, modifiers: Int, action: @escaping () -> Void) {
        HotKeys.actions[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x58445242), id: id) // 'XDRB'
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

// --- Orchestration ---------------------------------------------------------

final class Controller: NSObject, NSApplicationDelegate {
    private var triggers: [HDRTrigger] = []
    private var tables: [GammaTable] = []
    private var statusItem: NSStatusItem!
    private var hotKeys: HotKeys?
    private var lastActive: Float = 1.6
    private static let savedKey = "overnits.boost"
    private var applied: Float = 1.0
    private var watchdog: Timer?

    var boost: Float = 1.0 {
        didSet {
            boost > 1.001 ? enable() : disable()
            updateTitle()
            UserDefaults.standard.set(boost, forKey: Controller.savedKey)
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        setupMenu()
        setupHotKeys()
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let saved = UserDefaults.standard.float(forKey: Controller.savedKey)
        if let forced = Options.boost { boost = forced }
        else if saved > 1.001 { boost = saved }
        if Options.seconds > 0 {
            Timer.scheduledTimer(withTimeInterval: Options.seconds, repeats: false) { _ in NSApp.terminate(nil) }
        }
    }

    private func enable() {
        guard triggers.isEmpty else { reapply(); return }
        triggers = NSScreen.screens.compactMap { HDRTrigger(screen: $0) }
        tables = NSScreen.screens.compactMap { displayId(of: $0).flatMap { GammaTable(display: $0) } }
        // Le gamma n'atteint la plage etendue qu'une fois la dalle passee en
        // HDR : on attend que la reserve monte avant d'appliquer.
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.reapply()
        }
        reapply()
    }

    private func reapply() {
        let headroom = Float(NSScreen.main?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        let target = min(boost, max(1.0, headroom))
        if abs(target - applied) > 0.001 {
            tables.forEach { $0.apply(factor: target) }
            applied = target
        }
        if Options.log {
            print(String(format: "reserve=%.3f  gamma=x%.3f", headroom, applied))
        }
    }

    private func disable() {
        watchdog?.invalidate(); watchdog = nil
        tables.forEach { $0.restore() }
        tables.removeAll()
        triggers.forEach { $0.close() }
        triggers.removeAll()
        applied = 1.0
    }

    @objc private func screensChanged() {
        guard boost > 1.001 else { return }
        disable(); enable()
    }

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        for v: Float in [1.0, 1.2, 1.4, 1.6, 1.8, 2.0] {
            let item = NSMenuItem(title: v == 1.0 ? "Desactive" : String(format: "x%.1f", v),
                                  action: #selector(pick(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = v
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quitter", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        updateTitle()
    }

    @objc private func pick(_ s: NSMenuItem) { boost = s.representedObject as? Float ?? 1.0 }

    private func setupHotKeys() {
        let mods = cmdKey | optionKey
        hotKeys = HotKeys()
        hotKeys?.register(id: 1, keyCode: kVK_ANSI_B, modifiers: mods) { [weak self] in
            guard let self else { return }
            if self.boost > 1.001 { self.lastActive = self.boost; self.boost = 1.0 }
            else { self.boost = self.lastActive }
        }
        hotKeys?.register(id: 2, keyCode: kVK_ANSI_Equal, modifiers: mods) { [weak self] in
            guard let self else { return }
            self.boost = min(2.0, max(1.0, self.boost) + 0.1)
        }
        hotKeys?.register(id: 3, keyCode: kVK_ANSI_Minus, modifiers: mods) { [weak self] in
            guard let self else { return }
            let next = self.boost - 0.1
            self.boost = next < 1.05 ? 1.0 : next
        }
    }

    private func updateTitle() {
        statusItem?.button?.title = boost > 1.001 ? String(format: "☀︎ x%.1f", boost) : "☀︎"
    }

    func applicationWillTerminate(_ n: Notification) {
        disable()
        CGDisplayRestoreColorSyncSettings()
    }
}

let app = NSApplication.shared
let controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
signal(SIGINT)  { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
signal(SIGTERM) { _ in CGDisplayRestoreColorSyncSettings(); exit(0) }
app.run()
