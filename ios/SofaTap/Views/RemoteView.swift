import SwiftUI
import UIKit

struct RemoteView: View {
    // Xcode uses the asset catalog; the direct compiler fallback bundles the
    // same PNG as a resource, which SwiftUI's named-image lookup does not read.
    private static let brandImage: UIImage = {
        if let image = UIImage(named: "BrandMark") { return image }
        if let path = Bundle.main.path(forResource: "BrandMark", ofType: "png"),
           let image = UIImage(contentsOfFile: path) { return image }
        return UIImage(systemName: "sofa.fill") ?? UIImage()
    }()
    @ObservedObject var model: ControllerModel
    @ObservedObject private var unlock: ComputerUnlockController
    init(model: ControllerModel) {
        self.model = model; self.unlock = model.unlock
        _tv = StateObject(wrappedValue: WebOSTVController(enabled: !model.demo))
        _androidTV = StateObject(wrappedValue: AndroidTVController(enabled: !model.demo, targetSelected: !model.desktopControlEnabled && UserDefaults.standard.string(forKey: "manualRemoteTarget") == "androidtv"))
        _androidSelected = State(initialValue: !model.demo && UserDefaults.standard.string(forKey: "manualRemoteTarget") == "androidtv")
#if targetEnvironment(simulator)
        // Isolated layout fixtures never create a receiver connection.
        _composerVisible = State(initialValue: model.demo && ProcessInfo.processInfo.arguments.contains("--demo-composer"))
        _keyboardFocused = State(initialValue: model.demo && ProcessInfo.processInfo.arguments.contains("--demo-keyboard"))
#endif
    }
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @StateObject private var dictation = SpeechDictationController()
    @StateObject private var tv: WebOSTVController
    @StateObject private var androidTV: AndroidTVController
    @State private var androidSelected: Bool
    @State private var pairingSheet = false
    @State private var repairScanSheet = false
    @State private var tvRemoteSetupSheet = false
    @State private var tvDirectionSheet = false
    @State private var tvKeyboardFocused = false
    @State private var tvWantsDictation = false
    @State private var tvControlModes = UserDefaults.standard.dictionary(forKey: "sofatap.tvControlModes.v1") as? [String: String] ?? [:]
    @State private var incomingPairingLink: String?
    @State private var guideSheet = false
    @State private var gestureSettingsSheet = false
    @State private var volumeSheet = false
    @State private var deviceSheet = false
    /// Re-renders titles once the downloadable Songti SC is active.
    @ObservedObject private var song = KareSong.shared
    @AppStorage(ControllerModel.airMouseSweepKey) private var sweepDegrees = AirMouseGain.defaultSweepDegrees
    @AppStorage(ControllerModel.airMouseShakeRecenterKey) private var shakeRecenter = true
    @AppStorage("sofatap.remoteSurface.v1") private var remoteSurface = "airMouse"
    @State private var gestureSettingsTarget = GestureTarget.computer
    @State private var gesturePreferences = GesturePreferences.load(from: .standard)
    @State private var showingSpeechError = false
    @State private var touchControl = TouchSurface.Control()
    @State private var tvNavigationControl = AndroidTVNavigationPad.Control()
    @State private var tvAuxiliaryControl = TVAuxiliaryPager.Control()
    @State private var edgeScrollControl = EdgeScrollStrip.Control()
    @State private var draftEditorControl = NativeDraftEditor.Control()
    @State private var dictationImpact = UIImpactFeedbackGenerator(style: .light)
    @State private var resendAlert = false
    @State private var clearAlert = false
    @State private var composerVisible = false
    @State private var keyboardFocused = false
    @State private var remoteFocus = RemoteTextFocusPolicy()
    @State private var speechBaseDraft = ""
    @State private var speechBaseSnapshot: LiveTextSnapshot?
    @State private var speechRequest: UUID?
    @State private var speechOwnsDraft = false
    @State private var dictationStartTask: Task<Void, Never>?
    @State private var shortcutPanel: ShortcutPanelSelection?
    @State private var shortcutPanelTracking = false
    @AppStorage("sofatap.lastDesktopShortcut") private var lastDesktopShortcut = DesktopShortcut.space.rawValue

    private var speechBusy: Bool { dictation.state != .idle }
    private var televisionSelected: Bool {
#if SOFATAP_TV_UI_TESTING
        if model.demo && ProcessInfo.processInfo.arguments.contains("--demo-tv-controls") { return true }
#endif
        return !model.desktopControlEnabled
    }
    private var androidTVSelected: Bool { televisionSelected && androidSelected }
    private var tvMode: AndroidTVControlMode {
#if SOFATAP_TV_UI_TESTING
        if model.demo, let mode = androidTV.fixtureModeSelection { return mode }
#endif
        if let identity = androidTV.saved?.deviceIdentity, let raw = tvControlModes[identity], let mode = AndroidTVControlMode(rawValue: raw) { return mode }
        return androidTV.status?.tvControls == nil ? .pointer : .navigation
    }
    private var tvNavigationSelected: Bool { androidTVSelected && tvMode == .navigation }
    private var currentStatusTitle: String { androidTVSelected ? androidTV.title : televisionSelected ? tv.title : model.statusTitle }
    private var inputSessionAvailable: Bool {
        scenePhase == .active && !pairingSheet && !repairScanSheet && !guideSheet && !gestureSettingsSheet && !volumeSheet && !deviceSheet &&
        !tvRemoteSetupSheet && !showingSpeechError && !resendAlert && !clearAlert
    }
    // The direction sheet contains TV controls; keep its session available while
    // disabling the touch surface behind it. Other modals block both paths.
    private var interfaceAvailable: Bool { inputSessionAvailable && !tvDirectionSheet }
    private var inputEnabled: Bool {
        (androidTVSelected ? androidTV.canControl : televisionSelected ? tv.canControl : model.canControl) && interfaceAvailable
    }

    private var gestureTarget: GestureTarget { televisionSelected ? .television : .computer }
    private var gestureConfiguration: GestureConfiguration { gesturePreferences[gestureTarget] }
    private var gestureAvailableActions: Set<GestureAction>? {
        guard androidTVSelected else { return nil }
        guard let capabilities = androidTV.status?.capabilities else { return [.none] }
        var actions: Set<GestureAction> = [.none]
        if capabilities.overlayCursor { actions.insert(.movePointer) }
        if capabilities.nodeClick { actions.insert(.leftClick) }
        if capabilities.scroll { actions.insert(.scroll) }
        if capabilities.directionalFocus { actions.insert(.confirm) }
        if capabilities.back { actions.insert(.back) }
        if capabilities.home { actions.insert(.home) }
        return actions
    }

    private var guideContext: DeviceGuideContext {
        if androidTVSelected {
            return DeviceGuideContext(kind: .androidTV, deviceName: currentDeviceName,
                                      connected: androidTV.phase == .ready,
                                      availableActions: androidTV.status == nil ? nil : gestureAvailableActions,
                                      tvNavigation: tvNavigationSelected,
                                      tvNavigationReady: androidTV.status?.tvControls?.navigationStatus == .ready,
                                      tvTextStatus: androidTV.status?.tvControls?.textStatus.rawValue)
        }
        if televisionSelected {
            return DeviceGuideContext(kind: .webOS, deviceName: currentDeviceName,
                                      connected: tv.phase == .ready,
                                      availableActions: tv.phase == .ready ? [.movePointer, .leftClick, .scroll, .confirm, .back, .home] : nil)
        }
        let platform = model.connected ? model.receiverState.platform.rawValue :
            model.savedDevices.first(where: { $0.id == model.selectedDeviceID })?.platform
        return DeviceGuideContext(kind: .computer(platform: platform), deviceName: currentDeviceName,
                                  connected: model.connected,
                                  availableActions: model.connected ? (model.inputAvailable ? Set(GestureAction.allCases) : []) : nil)
    }

    var body: some View { dictationEvents }

    // Keep each opaque view expression small enough for the CI Swift compiler.
    // The modifier order remains layout -> presentation -> lifecycle -> dictation.
    private var layout: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) {
                touchpad
                    .frame(maxWidth: .infinity, minHeight: min(170, geometry.size.height * 0.4), maxHeight: .infinity)
                if androidTVSelected, let feedback = androidTV.inputFeedback {
                    Text(feedback)
                        .font(.footnote).foregroundStyle(Palette.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .accessibilityIdentifier("androidTVInputFeedback")
                }
                if composerVisible && androidTVSelected {
                    AndroidTVComposer(tv: androidTV, keyboardFocused: $tvKeyboardFocused, wantsDictation: $tvWantsDictation,
                                      active: inputEnabled, height: geometry.size.height < 500 ? 76 : 92)
                        .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
                        .padding(.horizontal, 12)
                } else if composerVisible && !televisionSelected {
                    composer(height: geometry.size.height < 500 ? 76 : 92)
                        .fixedSize(horizontal: false, vertical: true)
                        .layoutPriority(1)
                }
            }
            .padding(.bottom, composerVisible && !televisionSelected && !androidTVSelected ? 0 : 4)
        }
        .background(KareSandBackground(rings: showsAirMouse).ignoresSafeArea())
    }

    private var presentation: some View {
        layout
        .overlay { deviceSheetOverlay }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: deviceSheet)
        .sheet(isPresented: $pairingSheet) {
            PairingView(model: model, tv: tv, androidTV: androidTV, selectAndroidTV: selectAndroidTelevision,
                        selectTV: selectTelevision, selectComputer: { selectComputer(reconnect: false) },
                        androidSelected: androidTVSelected, incomingLink: $incomingPairingLink)
                .sofaSheet(.mediumLarge)
        }
        .sheet(isPresented: $repairScanSheet) {
            RepairScanSheet(model: model).sofaSheet(.large)
        }
        .sheet(isPresented: $tvRemoteSetupSheet) {
            AndroidTVRemoteSetupView(tv: androidTV).sofaSheet(.mediumLarge)
        }
        .sheet(isPresented: $tvDirectionSheet) {
            AndroidTVDirectionButtons(tv: androidTV).sofaSheet(.height300)
        }
        .sheet(isPresented: $guideSheet) { RemoteGuideView(configuration: gestureConfiguration, context: guideContext) }
        .sheet(isPresented: $volumeSheet) {
            SystemVolumeSheet(model: model)
                .sofaSheet(.mediumLarge)
        }
        .sheet(isPresented: $gestureSettingsSheet) {
            GestureSettingsView(configuration: Binding(
                get: { gesturePreferences[gestureSettingsTarget] },
                set: { gesturePreferences[gestureSettingsTarget] = $0.sanitized(for: gestureSettingsTarget) }
            ), target: gestureSettingsTarget, availableActions: gestureSettingsTarget == gestureTarget ? gestureAvailableActions : nil,
                                guideContext: gestureSettingsTarget == gestureTarget ? guideContext : nil)
        }
        .alert(String(localized: "语音输入暂不可用"), isPresented: $showingSpeechError) {
            Button(String(localized: "使用键盘")) { toggleKeyboard() }
            Button(String(localized: "好"), role: .cancel) {}
        } message: { Text(dictation.errorMessage ?? String(localized: "请尝试键盘或 Typeless。")) }
        .alert(String(localized: "允许再次发送这段文字？"), isPresented: $resendAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "已查看屏幕，允许重发")) { model.allowManualResend() }
        } message: {
            Text(String(localized: "上一次的文字可能已经输入。请先检查电脑屏幕，再手动按发送；重复文字无法自动撤销。"))
        }
        .alert(model.usesLiveText ? String(localized: "清空电脑当前输入框？") : String(localized: "清空手机上的草稿？"), isPresented: $clearAlert) {
            Button(String(localized: "取消"), role: .cancel) {}
            Button(String(localized: "清空草稿"), role: .destructive) { model.clearDraft() }
        } message: {
            Text(model.usesLiveText ? String(localized: "这会同步删除当前输入框中的文字。") : String(localized: "不会删除电脑里已经输入的文字。"))
        }
    }

    private var connectionEvents: some View {
        presentation
        .onAppear {
            model.setPointerSpeed(gesturePreferences[.computer].pointerSpeed)
            model.becameActive()
#if SOFATAP_TV_UI_TESTING
            if model.demo && ProcessInfo.processInfo.arguments.contains("--demo-tv-controls") {
                androidSelected = true
                androidTV.configureUIFixture(pairingRequired: ProcessInfo.processInfo.arguments.contains("--demo-tv-pairing"),
                                             editorReady: ProcessInfo.processInfo.arguments.contains("--demo-tv-keyboard"))
                composerVisible = ProcessInfo.processInfo.arguments.contains("--demo-tv-keyboard")
            }
#endif
            androidTV.setTargetSelected(androidTVSelected, reconnect: false)
            if scenePhase == .active { androidTV.becameActive() }
            else { androidTV.becameInactive() }
            if model.textDelivery == .uncertain { composerVisible = true }
            applyRemoteFocus()
#if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--soak-typing") { startSoak() }
#endif
#if targetEnvironment(simulator)
            if model.demo {
                gestureSettingsSheet = ProcessInfo.processInfo.arguments.contains("--demo-gestures")
                guideSheet = ProcessInfo.processInfo.arguments.contains("--demo-guide")
                pairingSheet = ProcessInfo.processInfo.arguments.contains("--demo-pairing") || ProcessInfo.processInfo.arguments.contains("--demo-add-device") || ProcessInfo.processInfo.arguments.contains("--demo-added-device")
                let arguments = ProcessInfo.processInfo.arguments
                if let index = arguments.firstIndex(of: "--demo-surface"), index + 1 < arguments.count {
                    remoteSurface = arguments[index + 1] == "trackpad" ? "trackpad" : "airMouse"
                }
                deviceSheet = arguments.contains("--demo-device-sheet")
            }
#endif
        }
        .onDisappear { stopInteraction(); androidTV.becameInactive() }
        .onOpenURL { url in
            // QR scans, pasted links and system links share one routing and
            // naming flow. Parsing happens before selecting any target.
            incomingPairingLink = url.absoluteString
            pairingSheet = true
        }
        .onChangeCompat(of: model.focusRevision) { _, _ in applyRemoteFocus() }
        .onChangeCompat(of: model.desktopControlEnabled) { _, enabled in
            // Covers explicit computer pairing links delivered by the OS.
            stopInteraction()
            composerVisible = false
            remoteFocus.reset()
            if enabled { tv.disconnect(); androidTV.setTargetSelected(false) }
        }
        .onChangeCompat(of: androidTV.acceptedInputFeedback) { _, _ in
            if androidTVSelected && scenePhase == .active { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        }
        .onChangeCompat(of: androidTV.rejectedInputFeedback) { _, _ in
            if androidTVSelected && scenePhase == .active { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        }
        .onChangeCompat(of: androidTV.selectedDeviceID) { _, _ in
            tvWantsDictation = false; tvKeyboardFocused = false; composerVisible = false
        }
        .onChangeCompat(of: androidTV.status?.tvControls?.editorEpoch) { old, new in
            guard androidTVSelected, scenePhase == .active else { return }
            tvWantsDictation = false
            if new != nil && old != new && !pairingSheet && !guideSheet && !gestureSettingsSheet && !tvRemoteSetupSheet && !tvDirectionSheet {
                composerVisible = true; tvKeyboardFocused = true
            } else if new == nil { tvKeyboardFocused = false }
        }
        .onChangeCompat(of: androidTV.phase) { _, phase in
            if androidTVSelected && phase != .ready { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
            if androidTVSelected && phase == .ready && scenePhase == .active && !pairingSheet && !guideSheet && !gestureSettingsSheet && !tvRemoteSetupSheet { androidTV.resumeInput() }
        }
        .onChangeCompat(of: androidTV.canControl) { _, available in
            if androidTVSelected && !available { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
        }
        .onChangeCompat(of: tv.phase) { _, phase in
            if televisionSelected && !androidTVSelected && phase != .ready { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() }
            if televisionSelected && !androidTVSelected && phase == .ready && scenePhase == .active && !pairingSheet && !guideSheet && !gestureSettingsSheet { tv.resumeInput() }
        }
    }

    private var desktopEvents: some View {
        connectionEvents
        .onChangeCompat(of: model.liveTextStatus) { _, _ in
            if model.liveTextPaused || (model.usesLiveText && model.liveTextStatus == .idle && speechRequest != nil) {
                cancelSpeech()
            }
        }
        .onChangeCompat(of: model.dragging) { _, dragging in
            if !dragging { applyRemoteFocus() }
        }
        .onChangeCompat(of: model.canControl) { _, enabled in
            if enabled { applyRemoteFocus() }
        }
        .onChangeCompat(of: model.controlAvailable) { _, available in
            // A pending drag release blocks new input without disconnecting or
            // stopping dictation. Only session/permission loss resets UI state.
            if !available && !televisionSelected { remoteFocus.reset(); stopInteraction() }
        }
    }

    private var interactionEvents: some View {
        desktopEvents
        .onChangeCompat(of: tvRemoteSetupSheet) { _, shown in
            if shown { stopInteraction() } else { resumeCurrentInput() }
        }
        .onChangeCompat(of: repairScanSheet) { _, shown in
            if shown { stopInteraction() } else { resumeCurrentInput() }
        }
        .onChangeCompat(of: pairingSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChangeCompat(of: guideSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChangeCompat(of: gestureSettingsSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChangeCompat(of: volumeSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChangeCompat(of: deviceSheet) { _, shown in
            if shown { stopInteraction() }
            else { resumeCurrentInput() }
        }
        .onChangeCompat(of: gesturePreferences) { _, preferences in
            touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel()
            model.setPointerSpeed(preferences[.computer].pointerSpeed)
            if !model.demo { _ = preferences.save(to: .standard) }
        }
        .onChangeCompat(of: model.pairingError) { _, error in
            if !televisionSelected && error != nil && !pairingSheet && !repairScanSheet { stopInteraction(); pairingSheet = true }
        }
        .onChangeCompat(of: dictation.errorMessage) { _, error in
            if error != nil { interruptTouch(); showingSpeechError = true }
        }
        .onChangeCompat(of: scenePhase) { _, phase in
            if phase == .background { stopInteraction(); tv.disconnect(); androidTV.becameInactive() }
            else if phase == .inactive {
                interruptTouch()
                keyboardFocused = false
                if dictation.state != .requestingPermission { cancelSpeech() }
            } else {
                androidTV.setTargetSelected(androidTVSelected, reconnect: false)
                androidTV.becameActive()
                resumeCurrentInput()
            }
        }
    }

    private var dictationEvents: some View {
        interactionEvents
        .onReceive(dictation.$transcript) { transcript in
            guard !televisionSelected else { return }
            // @Published replays its current value when SwiftUI subscribes. Ignore
            // an idle session's previous result and a new session's empty reset.
            guard let draft = DictationTranscript.draft(base: speechBaseDraft, transcript: transcript,
                                                       ownsDraft: speechOwnsDraft,
                                                       sessionIsActive: dictation.state != .idle) else { return }
            // Recognition is provisional until the session ends: update only the
            // phone, like marked IME text. The final string is sent once, below.
            if let base = speechBaseSnapshot {
                guard let snapshot = base.replacingSelection(with: transcript) else { return }
                model.editText(snapshot.text, selection: snapshot.selection, marked: true)
            } else { model.draft = draft; model.composing = true }
        }
        .onChangeCompat(of: dictation.state) { _, state in
            if state == .idle {
                let owned = speechOwnsDraft
                speechOwnsDraft = false; speechRequest = nil
                if owned { model.finishDictation() }
            }
        }
    }

    private var currentDeviceName: String {
#if SOFATAP_TV_UI_TESTING
        if model.demo && androidTVSelected { return androidTV.name }
#endif
        if androidTVSelected { return androidTV.saved == nil ? String(localized: "选择设备") : androidTV.currentDisplayName }
        if televisionSelected { return tv.saved == nil ? String(localized: "选择设备") : tv.currentDisplayName }
        if model.selectedDeviceID == nil { return String(localized: "选择设备") }
        return model.currentDisplayName
    }

    private var connectionLabel: String {
        if androidTVSelected { return androidTV.title }
        if televisionSelected { return tv.title }
        if model.demo { return String(localized: "界面演示") }
        if model.connecting { return String(localized: "正在安全连接…") }
        if model.connected && model.inputAvailable && model.usesPeerTransport { return String(localized: "已连接 · 设备直连") }
        if model.connected { return model.inputAvailable ? String(localized: "已连接 · 普通 Wi-Fi") : model.receiverState.unavailableTitle }
        return String(localized: "未连接")
    }

    private var deviceSymbol: String {
        if televisionSelected { return "tv" }
        let platform = model.savedDevices.first(where: { $0.id == model.selectedDeviceID })?.platform
        return platform == "macos" ? "laptopcomputer" : "desktopcomputer"
    }

    private var statusDotColor: Color {
        if androidTVSelected { return androidTV.phase == .failed ? Kare.accent : androidTV.canControl ? Kare.accent : Kare.mute }
        if televisionSelected { return tv.phase == .failed ? Kare.accent : tv.phase == .ready ? Kare.accent : Kare.mute }
        if model.pairingError != nil || (model.connected && !model.inputAvailable) { return Kare.accent }
        return model.canControl || model.demo ? Kare.accent : Kare.mute
    }

    private var statusConnected: Bool {
        if androidTVSelected { return androidTV.canControl }
        if televisionSelected { return tv.phase == .ready }
        return model.canControl || model.demo
    }

    /// Dot, serif device name and a thin chevron. Opens the device sheet.
    private var deviceButton: some View {
        Button {
            stopInteraction()
            UISelectionFeedbackGenerator().selectionChanged()
            deviceSheet = true
        } label: {
            HStack(spacing: 8) {
                Group {
                    if statusConnected { Circle().fill(statusDotColor) }
                    else { Circle().strokeBorder(statusDotColor, lineWidth: 1) }
                }
                .frame(width: 6, height: 6)
                Text(currentDeviceName).font(Kare.song(17)).tracking(1).lineLimit(1)
                    .foregroundStyle(Kare.ink)
                KareIcon(name: "chev", size: 12).foregroundStyle(Kare.mute)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 220, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(RemoteIconButtonStyle())
        .onAppear { KareSong.shared.prepare() }
        .accessibilityLabel(String(localized: "配对设备与连接设置"))
        .accessibilityValue(currentDeviceName + ", " + connectionLabel)
        .accessibilityIdentifier("pairingButton")
    }

    private var header: some View {
        deviceButton.frame(maxWidth: .infinity)
    }

    // MARK: Device sheet

    @ViewBuilder
    private var deviceSheetOverlay: some View {
        if deviceSheet {
            KareSheet(onDismiss: { deviceSheet = false }) { deviceSheetContent }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .zIndex(10)
        }
    }

    private func closeDeviceSheet() {
        UISelectionFeedbackGenerator().selectionChanged()
        deviceSheet = false
    }

    private func platformLabel(_ value: String?) -> String {
        switch value { case "macos": return "Mac"; case "windows": return "Windows"; case "linux": return "Linux"; default: return String(localized: "电脑") }
    }

    private var deviceSheetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(String(localized: "设备")).font(Kare.song(20)).tracking(1).foregroundStyle(Kare.ink)
                Spacer(minLength: 0)
                Button {
                    deviceSheet = false
                    guideSheet = true
                } label: {
                    KareIcon(name: "help", size: 22)
                        .frame(width: 40, height: 40).contentShape(Rectangle())
                }
                .accessibilityLabel(String(localized: "使用指南"))
                .accessibilityIdentifier("guideButton")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Kare.mute)
            .padding(.bottom, 2)
            ForEach(model.savedDevices) { device in
                let selected = model.desktopControlEnabled && model.selectedDeviceID == device.id
                Button {
                    closeDeviceSheet()
                    guard !selected else { return }
                    selectComputer(reconnect: false)
                    model.selectDevice(device.id)
                } label: {
                    KareSheetRow(title: device.displayName,
                                 subtitle: selected ? connectionLabel : platformLabel(device.platform)) {
                        if selected { KareIcon(name: "chk", size: 20).foregroundStyle(Kare.accent) }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            ForEach(androidTV.savedDevices) { device in
                let selected = !model.desktopControlEnabled && androidSelected && androidTV.selectedDeviceID == device.id
                Button {
                    closeDeviceSheet()
                    guard !selected else { return }
                    selectAndroidTelevision()
                    androidTV.selectDevice(device.id)
                } label: {
                    KareSheetRow(title: device.displayName,
                                 subtitle: showsAirMouse ? String(localized: "仅支持触控板") : "Android TV",
                                 dimmed: showsAirMouse && !selected) {
                        if selected { KareIcon(name: "chk", size: 20).foregroundStyle(Kare.accent) }
                    }
                }
                .buttonStyle(.plain)
            }
            ForEach(tv.savedDevices) { device in
                let selected = !model.desktopControlEnabled && !androidSelected && tv.selectedDeviceID == device.id
                Button {
                    closeDeviceSheet()
                    guard !selected else { return }
                    selectTelevision()
                    tv.selectDevice(device.id)
                } label: {
                    KareSheetRow(title: device.displayName,
                                 subtitle: showsAirMouse ? String(localized: "仅支持触控板") : "LG webOS",
                                 dimmed: showsAirMouse && !selected) {
                        if selected { KareIcon(name: "chk", size: 20).foregroundStyle(Kare.accent) }
                    }
                }
                .buttonStyle(.plain)
            }
            Button {
                deviceSheet = false
                pairingSheet = true
            } label: {
                KareSheetRow(title: String(localized: "添加或配对设备"), dimmed: false) {
                    KareIcon(name: "plus", size: 18).foregroundStyle(Kare.mute)
                }
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("addOrPairDevice")
            if showsAirMouse { airMouseSheetSection }
            Button {
                deviceSheet = false
                gestureSettingsTarget = gestureTarget
                gestureSettingsSheet = true
            } label: {
                KareSheetRow(title: String(localized: "设置"), icon: "set", separator: false) {
                    Text(verbatim: "›").font(.system(size: 16)).foregroundStyle(Kare.mute)
                }
            }
            .buttonStyle(.plain)
            .padding(.top, showsAirMouse ? 8 : 0)
            .accessibilityIdentifier("deviceSheetSettings")
        }
    }

    private var selectedDisplayLabel: String {
        guard let display = model.receiverState.displays.first(where: { $0.id == model.selectedRemoteDisplayID }) else { return "—" }
        return display.isMain ? String(localized: "主屏幕") : "\(display.width)×\(display.height)"
    }

    private var airMouseSheetSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(String(localized: "空鼠")).font(.system(size: 11)).tracking(3).foregroundStyle(Kare.mute)
                .padding(.top, 22).padding(.bottom, 4)
            Menu {
                ForEach(model.receiverState.displays) { display in
                    Button {
                        model.selectRemoteDisplay(display.id)
                    } label: {
                        if display.id == model.selectedRemoteDisplayID {
                            Label(AirMouseView.displayLabel(display), systemImage: "checkmark")
                        } else {
                            Text(AirMouseView.displayLabel(display))
                        }
                    }
                }
            } label: {
                KareSheetRow(title: String(localized: "电视屏幕"), icon: "screen") {
                    Text(verbatim: selectedDisplayLabel + " ›").font(.system(size: 14)).foregroundStyle(Kare.mute)
                }
            }
            .disabled(model.receiverState.displays.isEmpty)
            .accessibilityIdentifier("airMouseDisplayPicker")
            Button {
                model.recenterAirMouse()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                KareSheetRow(title: String(localized: "光标回中"), icon: "center", dimmed: !model.airMouseCanRecenter) {
                    if shakeRecenter {
                        Text(String(localized: "或摇一摇")).font(.system(size: 13)).foregroundStyle(Kare.mute)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(!model.airMouseCanRecenter)
            .accessibilityIdentifier("airMouseRecenter")
            Text(String(localized: "灵敏度")).font(.system(size: 16)).foregroundStyle(Kare.ink)
                .padding(.top, 16)
            KareSlider(value: Binding(
                get: { AirMouseGain.sensitivitySliderPosition(sweepDegrees: sweepDegrees) },
                set: { sweepDegrees = AirMouseGain.sweepDegrees(sensitivitySliderPosition: $0) }
            ), range: AirMouseGain.minimumSweepDegrees...AirMouseGain.maximumSweepDegrees, step: 1,
               label: String(localized: "灵敏度"))
            .accessibilityHint(String(localized: "手腕转一点，光标走多远"))
            .accessibilityIdentifier("airMouseSensitivity")
            HStack {
                Text(String(localized: "慢"))
                Spacer()
                Text(String(localized: "快"))
            }
            .font(.system(size: 12)).foregroundStyle(Kare.mute)
            .accessibilityHidden(true)
        }
    }

    private var touchpad: some View {
        ZStack {
            if model.needsRepairing && !televisionSelected {
                // Receiver refused this pairing: the stone area becomes the way back.
                RepairPairingPanel(stoneAsset: model.airMouseAppearance.stone.assetName) { repairScanSheet = true }
                    .padding(.top, Self.headerHeight)
                    .padding(.bottom, Self.barReserve + 16)
                    .transition(.opacity)
            } else if showsAirMouse {
                // 16 pt of dead space above the bottom bar so a blind thumb
                // does not slide from the stone onto a button.
                AirMouseView(model: model)
                    .padding(.top, Self.headerHeight)
                    .padding(.bottom, Self.barReserve + 16)
                    .transition(.opacity)
            } else {
            TouchSurface(enabled: inputEnabled && !tvNavigationSelected, control: touchControl,
                         profile: televisionSelected ? .tvPointer : .desktop,
                         configuration: gestureConfiguration,
                         onMove: { dx, dy in
                             if androidTVSelected { androidTV.move(dx: dx, dy: dy) }
                             else if televisionSelected { tv.move(dx: dx, dy: dy) }
                             else { model.moveFromTouch(dx: dx, dy: dy) }
                         },
                         onLeftTap: { if androidTVSelected { androidTV.click() } else if televisionSelected { tv.click() } else { model.click("left") } },
                         onRightTap: { if !televisionSelected { model.click("right") } },
                         onDraggingChanged: { if !televisionSelected { model.setDragging($0) } },
                         onScroll: scrollCurrentDevice,
                         onShortcut: performGestureShortcut,
                         onShortcutPanel: handleShortcutPanel,
                         onInteractionBegan: { tvAuxiliaryControl.cancel() })
                .allowsHitTesting(!tvNavigationSelected)
                .transition(.opacity)
            }
            if tvNavigationSelected {
                tvNavigationSurface
                if !androidTV.canNavigate { tvNavigationSetupPrompt }
            }
        }
        .overlay {
            if televisionSelected {
                if !tvNavigationSelected {
                    GeometryReader { geometry in
                        let toolsLayout = TVAuxiliaryLayout(cardWidth: geometry.size.width)
                        if let frame = toolsLayout.scrollFrame(cardWidth: geometry.size.width, cardHeight: geometry.size.height) {
                            edgeScrollStrip
                                .frame(width: frame.width, height: frame.height)
                                .position(x: frame.midX, y: frame.midY)
                        }
                    }
                }
            } else if !showsAirMouse && !model.needsRepairing {
                // Air mouse owns the whole card; a scroll strip there would steal blind drags.
                GeometryReader { geometry in
                    edgeScrollStrip
                        .frame(width: EdgeScrollStrip.minimumHitWidth,
                               height: max(EdgeScrollStrip.minimumHitWidth, geometry.size.height - Self.headerHeight - Self.barReserve - 16))
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: layoutDirection == .rightToLeft ? .topLeading : .topTrailing)
                        .padding(.top, Self.headerHeight)
                        .padding(layoutDirection == .rightToLeft ? .leading : .trailing, 8)
                }
            }
        }
        .overlay(alignment: .top) {
            header
                .padding(.horizontal, 20)
                .padding(.top, Kare.isSmallScreen ? 6 : 0)
        }
        .overlay(alignment: .top) {
            VStack(spacing: 2) {
                RemoteSurfaceToggle(airMouse: Binding(
                    get: { remoteSurface == "airMouse" },
                    set: { remoteSurface = $0 ? "airMouse" : "trackpad" }
                ), enabled: !televisionSelected)
                if televisionSelected {
                    Text(String(localized: "连接 Mac 后可用"))
                        .font(.system(size: 11))
                        .foregroundStyle(Kare.mute)
                        .accessibilityIdentifier("airMouseUnavailableNote")
                }
            }
            .padding(.top, Kare.isSmallScreen ? 46 : 42)
        }
        .animation(.easeInOut(duration: 0.2), value: showsAirMouse)
        .onChangeCompat(of: showsAirMouse) { _, show in
            if !show { model.stopAirMouse() }
        }
        .overlay(alignment: .bottom) {
            // Physical control positions reserve the right edge for scrolling.
            // Text elsewhere continues to follow the selected language's direction.
            VStack(spacing: 0) {
                // Hairline above the bar, inside the 16 pt dead gap.
                LinearGradient(colors: [Kare.rule.opacity(0), Kare.rule, Kare.rule.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(height: 1).padding(.horizontal, Kare.isSmallScreen ? 32 : 40)
                    .padding(.bottom, Kare.isSmallScreen ? 2 : 6)
                    .allowsHitTesting(false)
                bottomBar.environment(\.layoutDirection, .leftToRight)
                    .frame(height: Self.barCellHeight)
                    .padding(.horizontal, Kare.isSmallScreen ? 7.5 : 15)
            }
                .simultaneousGesture(DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        // Tell a blind thumb it has left the stone.
                        guard showsAirMouse, !bottomBarTouched else { return }
                        bottomBarTouched = true
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                    .onEnded { _ in bottomBarTouched = false })
        }
        .overlay {
            if televisionSelected {
                GeometryReader { geometry in
                    let toolsLayout = TVAuxiliaryLayout(cardWidth: geometry.size.width)
                    let toolsFrame = toolsLayout.frame(cardWidth: geometry.size.width, cardHeight: geometry.size.height)
                    televisionAuxiliaryPager(layout: toolsLayout)
                        .frame(width: toolsLayout.width, height: toolsLayout.height)
                        .position(x: toolsFrame.midX, y: toolsFrame.midY)
                }
            }
        }
        .overlay {
            if let panel = shortcutPanel {
                DesktopShortcutPanel(selection: panel, tracking: shortcutPanelTracking,
                                     macOS: model.receiverState.platform == .macos,
                                     onSend: { sendDesktopShortcut(DesktopShortcut.allCases[$0]) },
                                     onClose: closeShortcutPanel)
                    .allowsHitTesting(!shortcutPanelTracking)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: shortcutPanel == nil)
        .onChangeCompat(of: inputEnabled) { _, enabled in if !enabled { closeShortcutPanel() } }
        .onChangeCompat(of: televisionSelected) { _, _ in closeShortcutPanel() }
    }

    private func handleShortcutPanel(_ event: TouchSurface.ShortcutPanelEvent) {
        switch event {
        case .open(let tracking, let x, let y):
            guard inputEnabled, !televisionSelected else { return }
            edgeScrollControl.cancel()
            let start = DesktopShortcut.allCases.firstIndex { $0.rawValue == lastDesktopShortcut } ?? 0
            shortcutPanel = ShortcutPanelSelection(count: DesktopShortcut.allCases.count, start: start, x: x, y: y)
            shortcutPanelTracking = tracking
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        case .move(let x, let y):
            guard shortcutPanelTracking, var panel = shortcutPanel else { return }
            let wasCancelling = panel.cancelling
            if panel.move(x: x, y: y) { UISelectionFeedbackGenerator().selectionChanged() }
            if panel.cancelling != wasCancelling { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            shortcutPanel = panel
        case .lift:
            guard shortcutPanelTracking, let panel = shortcutPanel else { return }
            shortcutPanelTracking = false
            switch panel.release {
            case .send(let index): sendDesktopShortcut(DesktopShortcut.allCases[index])
            case .keepOpen: break
            case .close: closeShortcutPanel()
            }
        case .cancel:
            if shortcutPanelTracking { closeShortcutPanel() }
        }
    }

    private func sendDesktopShortcut(_ shortcut: DesktopShortcut) {
        closeShortcutPanel()
        guard inputEnabled, !televisionSelected else { return }
        lastDesktopShortcut = shortcut.rawValue
        let stroke = shortcut.keystroke(macOS: model.receiverState.platform == .macos)
        model.key(stroke.key, modifiers: stroke.modifiers)
    }

    private func closeShortcutPanel() {
        guard shortcutPanel != nil || shortcutPanelTracking else { return }
        shortcutPanel = nil
        shortcutPanelTracking = false
    }

    private var edgeScrollStrip: some View {
        EdgeScrollStrip(enabled: inputEnabled && (!androidTVSelected || androidTV.status?.capabilities.scroll == true),
                        control: edgeScrollControl,
                        interactionID: androidTVSelected ? "androidtv" : televisionSelected ? "webos" : "computer",
                        onInteractionBegan: { touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel() },
                        onScroll: scrollCurrentDevice)
    }

    private var tvNavigationSurface: some View {
        let surface = AndroidTVNavigationPad(enabled: inputEnabled && androidTV.canNavigate, control: tvNavigationControl, onInteractionBegan: { tvAuxiliaryControl.cancel() }) { _ = androidTV.remoteKey($0) }
#if SOFATAP_TV_UI_TESTING
        return surface.accessibilityValue(androidTV.fixtureActionSummary)
#else
        return surface
#endif
    }

    private var tvNavigationSetupPrompt: some View {
        VStack(spacing: 10) {
            Text(String(localized: "电视遥控")).font(.headline)
            if androidTV.connectionReady && androidTV.status?.tvControls != nil && androidTV.status?.tvControls?.navigationStatus != .unsupported {
                Button(String(localized: "连接电视遥控")) { tvRemoteSetupSheet = true }
                    .buttonStyle(.borderedProminent).tint(Palette.mint).foregroundStyle(Palette.background)
                    .accessibilityIdentifier("tvRemoteSetup")
            } else {
                Text(String(localized: "此接收器暂不提供系统遥控，请更新接收器或使用光标模式。"))
                    .font(.footnote).multilineTextAlignment(.center)
            }
        }
        .padding(14).frame(maxWidth: 260)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
    }

    private var bottomBar: some View {
        Group {
            if televisionSelected { televisionInputBar }
            else { computerBottomBar }
        }
    }
    private func televisionAuxiliaryPager(layout: TVAuxiliaryLayout) -> some View {
        TVAuxiliaryPager(pages: televisionAuxiliaryPages,
                         identity: androidTVSelected ? "android:" + (androidTV.selectedDeviceID?.uuidString ?? "none") : "webos:" + (tv.selectedDeviceID?.uuidString ?? "none"),
                         layout: layout, interactionEnabled: interfaceAvailable, control: tvAuxiliaryControl) {
            touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
        }
    }
    private var televisionAuxiliaryPages: [[TVAuxiliaryPager.Action]] {
        let back = TVAuxiliaryPager.Action(symbol: "chevron.backward", label: String(localized: "返回"), identifier: "tvBackButton",
                                           enabled: inputEnabled && (!androidTVSelected || (tvNavigationSelected ? androidTV.canNavigate : androidTV.status?.capabilities.back == true))) {
            if androidTVSelected {
                if tvNavigationSelected { _ = androidTV.remoteKey(.back) } else { _ = androidTV.key(.back) }
            } else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); tv.button(.back) }
        }
        let home = TVAuxiliaryPager.Action(symbol: "house", label: String(localized: "电视主页"), identifier: "tvHomeButton",
                                           enabled: inputEnabled && (!androidTVSelected || (tvNavigationSelected ? androidTV.canNavigate : androidTV.status?.capabilities.home == true))) {
            if androidTVSelected {
                if tvNavigationSelected { _ = androidTV.remoteKey(.home) } else { _ = androidTV.key(.home) }
            } else { UIImpactFeedbackGenerator(style: .light).impactOccurred(); tv.button(.home) }
        }
        guard androidTVSelected else { return [[back, home]] }
        let directions = TVAuxiliaryPager.Action(symbol: "dpad", label: String(localized: "方向键与确认"), identifier: "tvDirectionButtons",
                                                 enabled: inputEnabled && androidTV.canNavigate) {
            tvKeyboardFocused = false; tvWantsDictation = false
            UISelectionFeedbackGenerator().selectionChanged(); tvDirectionSheet = true
        }
        let mode = TVAuxiliaryPager.Action(symbol: tvMode == .navigation ? "hand.draw" : "cursorarrow", label: String(localized: "切换电视遥控与光标模式"),
                                           identifier: "tvControlMode", value: tvMode == .navigation ? String(localized: "电视遥控") : String(localized: "光标模式")) {
            toggleTVControlMode()
        }
        var pages = [[back, home], [directions, mode]]
        let apps = androidTV.status?.appShortcuts?.availableApps ?? []
        let shortcuts = AndroidTVAppShortcut.allCases.filter { apps.contains($0) }.map { app in
            TVAuxiliaryPager.Action(symbol: app == .youtube ? "play.rectangle" : "n.square",
                                    label: app == .youtube ? String(localized: "打开 YouTube") : String(localized: "打开 Netflix"),
                                    identifier: "tvLaunch_" + app.rawValue,
                                    enabled: inputEnabled && androidTV.canLaunchApp(app)) {
                _ = androidTV.launchApp(app)
            }
        }
        if !shortcuts.isEmpty { pages.append(shortcuts) }
        return pages
    }
    private func toggleTVControlMode() {
        touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel(); tvWantsDictation = false
        let next: AndroidTVControlMode = tvMode == .navigation ? .pointer : .navigation
        if let identity = androidTV.saved?.deviceIdentity {
            tvControlModes[identity] = next.rawValue
            if !model.demo { UserDefaults.standard.set(tvControlModes, forKey: "sofatap.tvControlModes.v1") }
        }
#if SOFATAP_TV_UI_TESTING
        if model.demo { androidTV.fixtureModeSelection = next }
#endif
        UISelectionFeedbackGenerator().selectionChanged()
    }
    private static var barCellHeight: CGFloat { Kare.isSmallScreen ? 64 : 80 }
    private static var micDiameter: CGFloat { Kare.isSmallScreen ? 56 : 64 }

    /// One of three equal 120 pt bar cells with a delivered thin-line icon.
    private func barGlyph(_ name: String, active: Bool) -> some View {
        KareIcon(name: name, size: 24)
            .frame(width: 120, height: Self.barCellHeight)
            .contentShape(Rectangle())
            .foregroundStyle(active ? Kare.accent : Kare.ink2)
    }

    /// Hollow 1 pt accent ring (60 %) with the mic, no fill and no glow.
    /// Recording fills it with accent and draws the icon in bg colour.
    private func micRing(recording: Bool, busy: Bool) -> some View {
        ZStack {
            Circle().fill(recording ? Kare.accent : Color.clear)
            Circle().strokeBorder(Kare.accent.opacity(recording ? 1 : 0.6), lineWidth: 1)
            if busy {
                ProgressView().tint(Kare.accent)
            } else {
                KareIcon(name: recording ? "stop" : "mic", size: 24)
                    .foregroundStyle(recording ? Kare.sand : Kare.accent)
            }
        }
        .frame(width: Self.micDiameter, height: Self.micDiameter)
        .frame(width: 120, height: Self.barCellHeight)
        .contentShape(Rectangle())
    }

    private var televisionInputBar: some View {
        // Match the desktop card's physical keyboard and microphone anchors.
        HStack(spacing: 0) {
            Button {
                touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
                tvWantsDictation = false; composerVisible = true
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { tvKeyboardFocused.toggle() }
                UISelectionFeedbackGenerator().selectionChanged()
            } label: { barGlyph("kb", active: tvKeyboardFocused) }
            .buttonStyle(RemoteIconButtonStyle())
            .disabled(!androidTVSelected || !androidTV.connectionReady || androidTV.status?.tvControls == nil)
            .accessibilityValue(tvKeyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            .accessibilityLabel(tvKeyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"))
            .accessibilityIdentifier("tvKeyboardButton")
            Spacer(minLength: 0)
            Button {
                touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel(); edgeScrollControl.cancel()
                composerVisible = true; tvKeyboardFocused = false
                dictationImpact.impactOccurred(); tvWantsDictation.toggle()
            } label: { micRing(recording: tvWantsDictation, busy: false) }
            .buttonStyle(MicrophoneButtonStyle(prepareFeedback: { dictationImpact.prepare() }))
            .disabled(!androidTVSelected || !inputEnabled || !androidTV.canEditTVText)
            .opacity(androidTVSelected && androidTV.canEditTVText ? 1 : 0.45)
            .accessibilityLabel(tvWantsDictation ? String(localized: "取消语音输入") : String(localized: "开始语音输入"))
            .accessibilityIdentifier("tvDictationButton")
            Spacer(minLength: 0)
            Color.clear.frame(width: 120, height: Self.barCellHeight).allowsHitTesting(false)
        }
    }
    private var computerBottomBar: some View {
        HStack(spacing: 0) {
            Button { toggleKeyboard() } label: { barGlyph("kb", active: keyboardFocused) }
            .buttonStyle(RemoteIconButtonStyle())
            .accessibilityValue(keyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            .accessibilityLabel(keyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"))
            .accessibilityIdentifier("keyboardButton")
            Spacer(minLength: 0)
            Button { toggleDictation() } label: {
                micRing(recording: dictation.isRecording,
                        busy: dictation.state == .requestingPermission || dictation.state == .finishing || (speechRequest != nil && model.editorLoading))
            }
            .buttonStyle(MicrophoneButtonStyle(prepareFeedback: { dictationImpact.prepare() }))
            .disabled(!model.controlAvailable || model.sendingText || (model.composing && !speechBusy) || model.remoteTextFocus == .protected)
            .opacity(model.controlAvailable ? 1 : 0.45)
            .accessibilityLabel(dictation.isRecording ? String(localized: "结束听写") : speechBusy || speechRequest != nil ? String(localized: "取消语音输入") : String(localized: "开始语音输入"))
            .accessibilityValue(dictation.isRecording ? String(localized: "麦克风正在录音") : dictation.state == .finishing ? String(localized: "正在整理听写结果") : "")
            .accessibilityIdentifier("dictationButton")
            Spacer(minLength: 0)
            Button { volumeSheet = true } label: { barGlyph("vol", active: false) }
            .buttonStyle(RemoteIconButtonStyle())
            .disabled(!interfaceAvailable)
            .accessibilityLabel(String(localized: "电脑系统音量"))
            .accessibilityIdentifier("systemVolumeButton")
        }
    }

    private var statusSymbol: String {
        if androidTVSelected {
            if androidTV.phase == .failed { return "exclamationmark" }
            return androidTV.canControl ? "checkmark" : androidTV.busy ? "ellipsis" : "tv"
        }
        if televisionSelected {
            if tv.phase == .failed { return "exclamationmark" }
            return tv.phase == .ready ? "checkmark" : tv.busy ? "ellipsis" : "tv"
        }
        if model.pairingError != nil { return "exclamationmark" }
        if model.demo { return "play.fill" }
        if model.connecting { return "ellipsis" }
        if model.canControl { return "checkmark" }
        return model.connected ? "pause.fill" : "link"
    }

    private var statusColor: Color {
        if androidTVSelected { return androidTV.phase == .failed ? .orange : androidTV.canControl ? Palette.mint : Palette.muted }
        if televisionSelected { return tv.phase == .failed ? .orange : tv.phase == .ready ? Palette.mint : Palette.muted }
        if model.pairingError != nil || model.demo || (model.connected && !model.inputAvailable) { return .orange }
        return model.canControl ? Palette.mint : Palette.muted
    }

    /// Tool row (trash / keyboard / remote backspace) → input bar → delivery hint,
    /// on one opaque sand panel that sits on the keyboard's top edge.
    private func composer(height: Double) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            composerActions
            HStack(alignment: .bottom, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    if model.draft.isEmpty {
                        Text(dictation.isRecording ? String(localized: "正在听…") : model.usesLiveText ? String(localized: "输入或听写，自动同步到电脑") : String(localized: "输入或听写，确认后发送到电脑"))
                            .font(.system(size: 16)).foregroundStyle(Palette.muted.opacity(0.7))
                            .padding(14).allowsHitTesting(false)
                    }
                    NativeDraftEditor(text: $model.draft, composing: $model.composing,
                                      isFocused: $keyboardFocused,
                                      disabled: speechBusy || model.editorLoading || (model.usesLiveText && !model.liveTextReady),
                                      selection: model.usesLiveText ? $model.draftSelection : nil,
                                      onEdit: { text, selection, marked in model.editText(text, selection: selection, marked: marked) },
                                      preservesFocusWhileLoading: model.editorLoading,
                                      liveEditing: model.usesLiveText,
                                      control: draftEditorControl,
                                      onEmptyBackspace: { model.keyboardBackspaceFromEmptyDraft() })
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // A separate column reserves room for Send, including while the
                // native editor scrolls or wraps text. Nothing overlays its text.
                composerSendButton
                    .padding(.trailing, 10)
                    .padding(.bottom, 10)
            }
            .frame(height: height)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 18))
            composerNotice
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
        .background(Kare.sand.ignoresSafeArea(.container, edges: .bottom))
    }

    private var deliveryHintFont: Font {
        let chinese = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") ?? false
        return chinese ? .custom("PingFang SC", size: 13) : .system(size: 13)
    }

    @ViewBuilder
    private var composerNotice: some View {
        if let message = composerMessage {
            DeliveryNoticeRow(message: message, font: deliveryHintFont,
                              actions: deliveryActions.map { DeliveryNoticeRow.Action(title: $0.title, identifier: $0.identifier, run: $0.run) },
                              disabled: model.sendingText || speechBusy)
        }
    }

    private struct DeliveryAction { let title: String; let identifier: String; let run: () -> Void }

    private var deliveryActions: [DeliveryAction] {
        guard !model.usesLiveText, !model.composing, !speechBusy else { return [] }
        switch model.textDelivery {
        case .rejected, .noFocus:
            return [DeliveryAction(title: String(localized: "重试"), identifier: "retryText") { resendDraft() }]
        case .uncertain:
            return [DeliveryAction(title: String(localized: "已上屏"), identifier: "textArrived") { model.confirmTextDelivered() },
                    DeliveryAction(title: String(localized: "再发一次"), identifier: "resendText") { resendDraft() }]
        default:
            if model.sentTextWasEdited {
                return [DeliveryAction(title: String(localized: "再发一次"), identifier: "allowTextResend") { interruptTouch(); resendAlert = true }]
            }
            return []
        }
    }

    private func resendDraft() {
        guard draftEditorControl.flushForSend() else { return }
        interruptTouch()
        model.retryTextDelivery()
    }

    private var composerMessage: String? {
        // Keep actionable delivery/connection states, without a permanent
        // capability label under the editor. A confirmed delivery says nothing.
        if model.liveTextPaused { return model.textStatus }
        if !model.usesLiveText, !model.composing, !speechBusy {
            switch model.textDelivery {
            case .rejected, .noFocus, .uncertain: return model.textStatus
            default: break
            }
        }
        if !model.controlAvailable { return String(localized: "未连接电脑，草稿会保留在手机上。") }
        if model.textDelivery == .sent && !model.sentTextWasEdited && !model.demo { return nil }
        if model.remoteTextFocus == .protected || model.editorLoading || speechBusy || model.composing || !model.draftWithinLimit || model.sentTextWasEdited || model.textDelivery != .ready {
            let status = composerStatus
            return status.isEmpty ? nil : status
        }
        return nil
    }

    private var composerActions: some View {
        HStack(spacing: 2) {
            composerIcon("trash", label: String(localized: "清空草稿"), identifier: "clearTextDraft") {
                interruptTouch(); clearAlert = true
            }
            .disabled(model.draft.isEmpty || model.composing || model.sendingText || speechBusy || (model.usesLiveText && !model.liveTextReady))
            composerIcon(keyboardFocused ? "arrow.down" : "arrow.up",
                         label: keyboardFocused ? String(localized: "收起键盘") : String(localized: "打开键盘输入"),
                         identifier: "hideKeyboard") { toggleKeyboard() }
                .accessibilityValue(keyboardFocused ? String(localized: "键盘已展开") : String(localized: "键盘已收起"))
            composerIcon("delete.left", label: String(localized: "电脑退格"), identifier: "remoteBackspace") {
                guard draftEditorControl.flushForSend() else { return }
                interruptTouch()
                model.remoteBackspace()
            }
            .disabled(!model.canRemoteBackspace || speechBusy)
            if model.liveTextPaused {
                composerIcon("arrow.clockwise", label: String(localized: "检查电脑后重新读取输入框"), identifier: "resumeLiveText") {
                    model.restartLiveTextEditing()
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
    }

    private var composerSendButton: some View {
        Button(action: sendCurrentDraft) {
            Group {
                if model.sendingText || model.liveTextStatus == .syncing { ProgressView().tint(Palette.background) }
                else { Image(systemName: model.liveTextReady ? "checkmark" : "arrow.up").font(.system(size: 19, weight: .semibold)) }
            }
            .frame(width: 44, height: 44)
            .foregroundStyle(Palette.background)
            .background(Palette.mint, in: Circle())
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canAttemptSend)
        .opacity(canAttemptSend || model.sendingText ? 1 : 0.45)
        .accessibilityLabel(model.usesLiveText ? String(localized: "实时同步") : String(localized: "发送"))
        .accessibilityIdentifier("sendText")
    }

    private func composerIcon(_ symbol: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .sofaSymbolReplace(reduceMotion: reduceMotion)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.20), value: keyboardFocused)
                .frame(width: 44, height: 44)
                .foregroundStyle(Palette.muted)
                .contentShape(Rectangle())
        }
        .buttonStyle(RemoteIconButtonStyle())
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }

    private var canAttemptSend: Bool {
        // Keep the control stable, including after an ACK. A native keyboard can
        // update its text storage before publishing the binding; flush it first.
        // Grey while IME text or dictation is still provisional; it lights up
        // when the final text is in the draft, instead of failing silently.
        !model.usesLiveText && inputEnabled && !model.sendingText && !speechBusy && !model.composing && model.textDelivery != .uncertain
    }

    private func sendCurrentDraft() {
        guard canAttemptSend, draftEditorControl.flushForSend() else { return }
        model.sendText()
    }

    private var composerStatus: String {
        if dictation.isRecording { return model.usesLiveText ? String(localized: "正在听写并实时同步…") : String(localized: "正在听写，结束后确认文字再发送。") }
        if dictation.state == .finishing { return String(localized: "正在整理听写结果…") }
        if model.remoteTextFocus == .protected { return String(localized: "电脑当前为安全输入框，不会自动听写。") }
        if model.demo && model.textDelivery == .sent { return String(localized: "演示反馈：文字没有发送到电脑。") }
        return model.textStatus
    }

    private func toggleKeyboard() {
        guard !televisionSelected else { return }
        interruptTouch()
        cancelSpeech()
        UISelectionFeedbackGenerator().selectionChanged()
        // Keep the draft and its toggle visible after dismissing the keyboard.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.20)) {
            composerVisible = true
            keyboardFocused.toggle()
        }
        if keyboardFocused { model.openTextEditor() }
    }
    private func toggleDictation() {
        // Dictation itself marks the draft as composing; it must still be stoppable.
        guard !televisionSelected, model.controlAvailable, !model.sendingText, !model.composing || speechBusy, model.remoteTextFocus != .protected else { return }
        let releasedDrag = model.dragging
        interruptTouch()
        if dictation.isRecording {
            // Recording suppresses haptics. Stop capture and release its audio
            // session before acknowledging the explicit stop tap.
            dictation.stop()
            dictationImpact.impactOccurred()
            return
        }
        if speechBusy || speechRequest != nil {
            cancelSpeech()
            if !releasedDrag { dictationImpact.impactOccurred() }
            return
        }
        // A drag release already supplies feedback. This confirms the tap,
        // not microphone authorization or a successful recording start.
        if !releasedDrag { dictationImpact.impactOccurred() }
        keyboardFocused = false
        composerVisible = true
        let request = UUID(); speechRequest = request
        model.openTextEditor {
            guard !televisionSelected, speechRequest == request, model.controlAvailable, scenePhase == .active else { return }
            speechBaseDraft = model.draft
            speechBaseSnapshot = model.liveTextReady ? LiveTextSnapshot(text: model.draft, selection: model.draftSelection) : nil
            speechOwnsDraft = true
            dictationStartTask?.cancel()
            dictationStartTask = Task {
                guard !Task.isCancelled, !televisionSelected, speechRequest == request, model.controlAvailable, scenePhase == .active else { return }
                await dictation.start()
            }
        }
    }
    private func applyRemoteFocus() {
        guard let focus = remoteFocus.next(revision: model.focusRevision, focus: model.remoteTextFocus,
                                          interactionAvailable: !televisionSelected && model.canControl && interfaceAvailable,
                                          dragging: model.dragging, speechBusy: speechBusy) else { return }
        switch focus {
        case .editable:
            interruptTouch()
            composerVisible = true
            keyboardFocused = true
            model.openTextEditor()
        case .other, .protected:
            keyboardFocused = false
            cancelSpeech()
        case .unknown:
            break // Unsupported desktop focus detection leaves manual input available.
        }
    }
    private func stopInteraction() {
        interruptTouch()
        keyboardFocused = false
        tvKeyboardFocused = false; tvWantsDictation = false
        cancelSpeech()
        model.endLiveTextEditing()
    }
    private func cancelSpeech() {
        speechRequest = nil
        dictationStartTask?.cancel()
        dictation.cancel()
        speechOwnsDraft = false
    }
    private func interruptTouch() {
        edgeScrollControl.cancel()
        touchControl.cancel(); tvNavigationControl.cancel(); tvAuxiliaryControl.cancel()
        model.pauseInput()
        tv.pauseInput()
        androidTV.pauseInput()
    }
    private func selectTelevision() {
        stopInteraction()
        androidTV.setTargetSelected(false)
        androidSelected = false
        composerVisible = false
        model.setDesktopControlEnabled(false)
        tv.disconnect()
    }
    private func selectAndroidTelevision() {
        stopInteraction()
        composerVisible = false
        tv.disconnect()
        androidTV.disconnect()
        androidTV.setTargetSelected(true, reconnect: false)
        androidSelected = true
        model.setDesktopControlEnabled(false, televisionTarget: "androidtv")
    }
    private func selectComputer(reconnect: Bool = true) {
        stopInteraction()
        tv.disconnect()
        androidTV.setTargetSelected(false)
        androidSelected = false
        composerVisible = false
        remoteFocus.reset()
        model.setDesktopControlEnabled(true, reconnect: reconnect)
    }
    @State private var bottomBarTouched = false
    /// Device name (44 pt) and the surface tabs below it.
    private static var headerHeight: CGFloat { Kare.isSmallScreen ? 90 : 88 }
    /// Bottom bar (72 pt), its 4 pt inset and the hairline above it.
    private static var barReserve: CGFloat { barCellHeight + (Kare.isSmallScreen ? 2 : 6) }
    private var showsAirMouse: Bool { !televisionSelected && remoteSurface == "airMouse" }

    private func resumeCurrentInput() {
        guard inputSessionAvailable else { return }
        if androidTVSelected { androidTV.resumeInput() }
        else if televisionSelected { tv.resumeInput() }
        else { applyRemoteFocus() }
    }
    private func performGestureShortcut(_ action: GestureAction) {
        guard inputEnabled else { return }
        switch action {
        case .confirm:
            if androidTVSelected { androidTV.key(.confirm) }
            else if televisionSelected { tv.button(.enter) }
            else { model.key("enter") }
        case .back:
            if androidTVSelected { androidTV.key(.back) }
            else if televisionSelected { tv.button(.back) }
            else { model.key("escape") }
        case .home:
            if androidTVSelected { androidTV.key(.home) }
            else if televisionSelected { tv.button(.home) }
        case .toggleKeyboard:
            if !televisionSelected { toggleKeyboard() }
        case .toggleDictation:
            if !televisionSelected { toggleDictation() }
        default: break
        }
    }
    private func scrollCurrentDevice(_ delta: Double) {
        if androidTVSelected { androidTV.scroll(dy: delta) }
        else if televisionSelected { tv.scroll(dy: delta) }
        else { model.scroll(dy: delta) }
    }
}

private struct MicrophoneButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let prepareFeedback: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        let pressed = isEnabled && configuration.isPressed
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? 0.90 : 1)
            .brightness(pressed ? -0.12 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: pressed ? 0.10 : 0.16), value: pressed)
            // Keep the full target while its visible surface compresses.
            .contentShape(Rectangle())
            .onChangeCompat(of: pressed) { _, down in
                if down { prepareFeedback() }
            }
    }
}

private struct SystemVolumeSheet: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    private var unavailableMessage: String? {
        if model.demo { return String(localized: "界面演示：按钮只展示反馈，没有连接或操作电脑。") }
        if !model.connected { return String(localized: "连接电脑后即可调节系统音量。") }
        if !model.inputAvailable { return model.receiverState.unavailableMessage }
        if !model.receiverState.supportsSystemVolume {
            return String(localized: "当前接收器或输出设备不支持音量控制。请更新电脑接收器或切换输出设备。")
        }
        return nil
    }

    var body: some View {
        SofaNavigationStack {
            Form {
                Section {
                    volumeButton(.down, title: String(localized: "音量减"), symbol: "speaker.wave.1")
                    volumeButton(.up, title: String(localized: "音量加"), symbol: "speaker.wave.3")
                    volumeButton(.mute, title: String(localized: "静音切换"), symbol: "speaker.slash")
                } header: {
                    Text(model.computerName)
                } footer: {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(String(localized: "调节电脑默认输出设备的音量。"))
                        if let message = unavailableMessage ?? model.volumeFeedback { Text(message) }
                        if model.volumeBusy { ProgressView() }
                    }
                }
                .listRowBackground(Palette.panel)
            }
            .sofaHiddenScrollBackground().background(Palette.background)
            .navigationTitle(String(localized: "电脑系统音量"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "完成")) { dismiss() }
                }
            }
        }
        .tint(Palette.mint).preferredColorScheme(.dark)
    }

    private func volumeButton(_ command: SystemVolumeCommand, title: String, symbol: String) -> some View {
        Button { model.changeSystemVolume(command) } label: {
            Label(title, systemImage: symbol).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        }
        .disabled(!model.canChangeSystemVolume || scenePhase != .active)
        .accessibilityIdentifier("systemVolume_\(command.rawValue)")
    }
}

#Preview { RemoteView(model: ControllerModel(demo: true)).preferredColorScheme(.dark) }

/// A dimmed overlay over the touchpad, like an accessibility menu. While the
/// opening finger is down it only shows the highlight; afterwards it can be
/// swiped and tapped. Physical left and right always map to the row order.
private struct DesktopShortcutPanel: View {
    let selection: ShortcutPanelSelection
    let tracking: Bool
    let macOS: Bool
    let onSend: (Int) -> Void
    let onClose: () -> Void
    private let shortcuts = DesktopShortcut.allCases

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black.opacity(0.62))
                .contentShape(Rectangle())
                .onTapGesture { onClose() }
                .accessibilityHidden(true)
            VStack(spacing: 14) {
                let current = shortcuts[selection.index]
                VStack(spacing: 4) {
                    Text(current.title).font(.system(size: 22, weight: .semibold))
                    Text(current.keyCap(macOS: macOS)).font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.mint.opacity(0.9))
                }
                .opacity(tracking && selection.cancelling ? 0.4 : 1)
                .accessibilityHidden(tracking)
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(shortcuts.indices, id: \.self) { index in
                                cell(index).id(index)
                            }
                        }
                        .padding(.horizontal, 28).padding(.vertical, 8)
                    }
                    .sofaScrollDisabled(tracking)
                    .onAppear { proxy.scrollTo(selection.index, anchor: .center) }
                    .onChangeCompat(of: selection.index) { _, index in
                        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
                Text(hint).font(.footnote).foregroundStyle(Palette.muted)
                    .multilineTextAlignment(.center).padding(.horizontal, 24)
                if !tracking {
                    Button(String(localized: "完成"), action: onClose)
                        .buttonStyle(.bordered).tint(Palette.mint)
                        .accessibilityIdentifier("desktopShortcutPanelClose")
                }
            }
        }
        .environment(\.layoutDirection, .leftToRight)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "快捷键面板"))
        .accessibilityIdentifier("desktopShortcutPanel")
        .accessibilityAddTraits(.isModal)
    }

    private var hint: String {
        if !tracking { return String(localized: "轻点发送，左右滑动查看更多") }
        if selection.cancelling { return String(localized: "松手取消") }
        return String(localized: "左右滑动选择，松手发送") + "\n" + String(localized: "上下移开后松手取消")
    }

    private func cell(_ index: Int) -> some View {
        let shortcut = shortcuts[index]
        let selected = index == selection.index
        return Button { onSend(index) } label: {
            VStack(spacing: 6) {
                Image(systemName: shortcut.symbol).font(.system(size: 21, weight: .regular))
                Text(shortcut.keyCap(macOS: macOS)).font(.system(size: 11, weight: .medium, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(width: 64, height: 68)
            .foregroundStyle(Palette.mint)
            .background(Palette.mint.opacity(selected ? 0.26 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Palette.mint.opacity(selected ? 0.8 : 0.16), lineWidth: selected ? 1.5 : 1)
            }
            .scaleEffect(tracking && selected ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(shortcut.title)
        .accessibilityValue(shortcut.keyCap(macOS: macOS))
        .accessibilityIdentifier("desktopShortcut_" + shortcut.rawValue)
    }
}

#if DEBUG
/// Device soak (Debug builds only, `--soak-typing [--soak-seconds N]`): drives the
/// real composer UITextView with typed characters, pinyin marked text and injected
/// keyboard-dictation sessions while the system keyboard is up, and logs connection
/// changes as `SOFATAP_SOAK` lines in the device log. No microphone is used.
@MainActor extension RemoteView {
    fileprivate func soak(_ op: String, _ text: String = "") {
        NotificationCenter.default.post(name: NativeDraftEditor.soakNotification, object: nil, userInfo: ["op": op, "text": text])
    }
    func startSoak() {
        Task { @MainActor in
            let args = ProcessInfo.processInfo.arguments
            let seconds = args.firstIndex(of: "--soak-seconds").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 300
            @MainActor func log(_ line: String) { NSLog("SOFATAP_SOAK %@", line) }
            func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
            var waited = 0.0
            while !(model.connected && model.inputAvailable) && waited < 60 { await pause(0.25); waited += 0.25 }
            log("ready connected=\(model.connected) input=\(model.inputAvailable) peer=\(model.usesPeerTransport) live=\(model.usesLiveText) after=\(waited)s")
            composerVisible = true; keyboardFocused = true
            model.openTextEditor()
            await pause(2)
            var disconnects = 0, lastConnected = model.connected, lastPeer = model.usesPeerTransport
            var counts: [String: (ok: Int, total: Int)] = [:]
            let started = Date()
            @MainActor func note(_ kind: String, _ ok: Bool) {
                var c = counts[kind] ?? (0, 0); c.total += 1; if ok { c.ok += 1 }; counts[kind] = c
                let tail = String(model.draft.suffix(24)), status = "\(model.liveTextStatus)", delivery = "\(model.textDelivery)"
                log("\(kind) ok=\(ok) draft=\(tail) live=\(status) delivery=\(delivery)")
            }
            let monitor = Task { @MainActor in
                while !Task.isCancelled {
                    if model.connected != lastConnected || model.usesPeerTransport != lastPeer {
                        if lastConnected && !model.connected { disconnects += 1 }
                        log("link connected=\(model.connected) peer=\(model.usesPeerTransport) t=\(Int(Date().timeIntervalSince(started)))s notice=\(model.notice)")
                        lastConnected = model.connected; lastPeer = model.usesPeerTransport
                    }
                    await pause(0.1)
                }
            }
            @MainActor func settled(_ expected: String) async -> Bool {
                for _ in 0..<30 {
                    let draft = model.draft, composing = model.composing, ready = model.liveTextStatus == .active
                    if draft.hasSuffix(expected) && !composing && ready { return true }
                    await pause(0.1)
                }
                return false
            }
            var cycle = 0
            while Date().timeIntervalSince(started) < seconds {
                cycle += 1
                // 1. keyboard typing, one character at a time.
                let word = "type\(cycle) "
                for ch in word { soak("type", String(ch)); await pause(0.12) }
                note("typing", await settled(word))
                // 2. pinyin: marked increments, then the candidate commits.
                for m in ["n", "ni", "nih", "niha", "nihao"] { soak("mark", m); await pause(0.15) }
                soak("type", "你好"); note("pinyin", await settled("你好"))
                // 3. Chinese dictation: provisional chunks, whole replacement, end.
                soak("dictStart"); for chunk in ["今天", "天气"] { soak("type", chunk); await pause(0.3) }
                soak("replaceTail", "今天天气很好。"); await pause(0.3); soak("dictEnd")
                note("dictation-zh", await settled("今天天气很好。"))
                // 4. English dictation.
                soak("dictStart"); for chunk in ["hello", " world"] { soak("type", chunk); await pause(0.3) }
                soak("replaceTail", " Hello world."); await pause(0.3); soak("dictEnd")
                note("dictation-en", await settled(" Hello world."))
                if Date().timeIntervalSince(started) + 20 < seconds { soak("clear"); await pause(0.8) }
                log("cycle=\(cycle) t=\(Int(Date().timeIntervalSince(started)))s disconnects=\(disconnects)")
            }
            monitor.cancel()
            let summary = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value.ok)/\($0.value.total)" }.joined(separator: " ")
            log("done seconds=\(Int(Date().timeIntervalSince(started))) cycles=\(cycle) disconnects=\(disconnects) peer=\(model.usesPeerTransport) \(summary)")
        }
    }
}
#endif

/// Jony spec: shown only when the receiver explicitly refuses this pairing.
/// Sand background (inherited), the user's stone at 40 %, ink title, mute
/// explanation, one accent primary button. No red, no error icon.
struct RepairPairingPanel: View {
    let stoneAsset: String
    let scan: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(stoneAsset)
                .resizable().scaledToFit()
                .frame(width: Kare.isSmallScreen ? 180 : 230)
                .opacity(0.4)
                .accessibilityHidden(true)
            Text(String(localized: "需要重新配对"))
                .font(.custom("PingFangSC-Semibold", size: 17, relativeTo: .headline))
                .foregroundStyle(Kare.ink)
                .multilineTextAlignment(.center)
                .padding(.top, 16)
                .accessibilityIdentifier("repairPairingTitle")
            Text(String(localized: "在 Mac 上打开 Sofatap，扫一下屏幕上的二维码"))
                .font(.custom("PingFangSC-Regular", size: 13, relativeTo: .footnote))
                .foregroundStyle(Kare.mute)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.horizontal, 32)
            Spacer(minLength: 16)
            Button(action: scan) {
                Text(String(localized: "扫码配对"))
                    .font(.custom("PingFangSC-Semibold", size: 17, relativeTo: .headline))
                    .foregroundStyle(Kare.sand)
                    .frame(maxWidth: .infinity, minHeight: 44, maxHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Kare.accent))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .accessibilityIdentifier("repairPairingScan")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("repairPairing")
    }
}

/// Opens straight into the camera. A valid SofaTap computer code is saved,
/// confirmed with a light haptic and the sheet closes back to the page the
/// user was on; there is no success page. Other QR codes are ignored.
private struct RepairScanSheet: View {
    @ObservedObject var model: ControllerModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var cameraError: String?
    @State private var done = false
    var body: some View {
        ZStack(alignment: .bottom) {
            Kare.sand.ignoresSafeArea()
            QRScanner(isActive: !done && scenePhase == .active,
                      accepts: { (try? Pairing.parse($0)) != nil },
                      onScan: accept, onError: { cameraError = $0 })
                .ignoresSafeArea()
                .accessibilityLabel(String(localized: "扫描二维码"))
            VStack(spacing: 10) {
                if let message = cameraError ?? model.pairingError {
                    Text(message).font(.footnote).foregroundStyle(Kare.ink)
                        .multilineTextAlignment(.center).padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Kare.sand.opacity(0.92)))
                }
                Button(String(localized: "取消")) { dismiss() }
                    .font(.system(size: 17)).foregroundStyle(Kare.accent)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Kare.sand.opacity(0.92)))
            }
            .padding(16)
        }
    }
    private func accept(_ raw: String) {
        guard !done else { return }
        model.acceptPairing(raw)
        guard model.pairingError == nil else { return }
        done = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        dismiss()
    }
}
