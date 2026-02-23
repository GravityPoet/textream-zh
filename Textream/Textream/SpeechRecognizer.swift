//
//  SpeechRecognizer.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import AppKit
import Foundation
import Speech
import AVFoundation
import CoreAudio

struct AudioInputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String

    static func allInputDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize) == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs) == noErr else { return [] }

        var result: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check if device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceNameCFString,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

            result.append(AudioInputDevice(id: deviceID, uid: uid as String, name: name as String))
        }
        return result
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allInputDevices().first(where: { $0.uid == uid })?.id
    }
}

@Observable
class SpeechRecognizer {
    var recognizedCharCount: Int = 0
    var isListening: Bool = false
    var error: String?
    var audioLevels: [CGFloat] = Array(repeating: 0, count: 30)
    var lastSpokenText: String = ""
    var shouldDismiss: Bool = false
    var shouldAdvancePage: Bool = false

    /// True when recent audio levels indicate the user is actively speaking
    var isSpeaking: Bool {
        let recent = audioLevels.suffix(10)
        guard !recent.isEmpty else { return false }
        let avg = recent.reduce(0, +) / CGFloat(recent.count)
        return avg > 0.08
    }

    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine = AVAudioEngine()
    private var sourceText: String = ""
    private var normalizedSource: String = ""
    private var compactSourceCharacters: [Character] = []
    private var compactSourceToOriginalOffset: [Int] = []
    private var matchStartOffset: Int = 0  // char offset to start matching from
    private var retryCount: Int = 0
    private let maxRetries: Int = 10
    private var configurationChangeObserver: Any?
    private var pendingRestart: DispatchWorkItem?
    private var sessionGeneration: Int = 0
    private var suppressConfigChange: Bool = false
    private var requiresTranscription: Bool = true
    private var transcriptionBackend: TranscriptionBackend = .none
    private var localSenseVoiceRunner: LocalSenseVoiceRunner?
    private var pendingAnchorJumpTarget: Int?
    private var pendingAnchorJumpHits: Int = 0
    private var pendingAnchorJumpTimestamp: TimeInterval = 0

    private enum TranscriptionBackend {
        case none
        case appleSpeech
        case localSenseVoice
    }

    /// Jump highlight to a specific char offset (e.g. when user taps a word)
    func jumpTo(charOffset: Int) {
        recognizedCharCount = charOffset
        matchStartOffset = charOffset
        retryCount = 0
        resetPendingAnchorJumpConfirmation()
        if isListening {
            restartRecognition()
        }
    }

    func start(with text: String) {
        // Clean up any previous session immediately so pending restarts
        // and stale taps are removed before the async auth callback fires.
        cleanupRecognition()

        let words = splitTextIntoWords(text)
        let collapsed = words.joined(separator: " ")
        sourceText = collapsed
        normalizedSource = Self.normalize(collapsed)
        rebuildCompactSourceIndex()
        recognizedCharCount = 0
        matchStartOffset = 0
        retryCount = 0
        resetPendingAnchorJumpConfirmation()
        error = nil
        sessionGeneration += 1
        let settings = NotchSettings.shared
        requiresTranscription = settings.listeningMode == .wordTracking
        if requiresTranscription {
            transcriptionBackend = settings.speechEngineMode == .localSenseVoice ? .localSenseVoice : .appleSpeech
        } else {
            transcriptionBackend = .none
        }

        // Check microphone permission first
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            error = "麦克风权限被拒绝。请前往 系统设置 → 隐私与安全性 → 麦克风，允许 Textream。"
            openMicrophoneSettings()
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        if self?.transcriptionBackend == .appleSpeech {
                            self?.requestSpeechAuthAndBegin()
                        } else {
                            self?.beginRecognition()
                        }
                    } else {
                        self?.error = "麦克风权限被拒绝。请前往 系统设置 → 隐私与安全性 → 麦克风，允许 Textream。"
                    }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            break
        }

        if transcriptionBackend == .appleSpeech {
            requestSpeechAuthAndBegin()
        } else {
            beginRecognition()
        }
    }

    private func requestSpeechAuthAndBegin() {
        SFSpeechRecognizer.requestAuthorization { [weak self] status in
            DispatchQueue.main.async {
                switch status {
                case .authorized:
                    self?.beginRecognition()
                default:
                    self?.error = "语音识别未授权。请前往 系统设置 → 隐私与安全性 → 语音识别，允许 Textream。"
                    self?.openSpeechRecognitionSettings()
                }
            }
        }
    }

    private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    func stop() {
        isListening = false
        cleanupRecognition()
    }

    func forceStop() {
        isListening = false
        sourceText = ""
        retryCount = maxRetries
        cleanupRecognition()
    }

    func resume() {
        retryCount = 0
        matchStartOffset = recognizedCharCount
        shouldDismiss = false
        beginRecognition()
    }

    private func cleanupRecognition() {
        // Cancel any pending restart to prevent overlapping beginRecognition calls
        pendingRestart?.cancel()
        pendingRestart = nil

        localSenseVoiceRunner?.stop()
        localSenseVoiceRunner = nil
        resetPendingAnchorJumpConfirmation()

        if let observer = configurationChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            configurationChangeObserver = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Coalesces all delayed beginRecognition() calls into a single pending work item.
    /// Any previously scheduled restart is cancelled before the new one is queued.
    private func scheduleBeginRecognition(after delay: TimeInterval) {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingRestart = nil
            self.beginRecognition()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func beginRecognition() {
        // Ensure clean state
        cleanupRecognition()

        // Create a fresh engine so it picks up the current hardware format.
        // AVAudioEngine caches the device format internally and reset() alone
        // does not reliably flush it after a mic switch.
        audioEngine = AVAudioEngine()

        // Set selected microphone if configured
        let micUID = NotchSettings.shared.selectedMicUID
        if !micUID.isEmpty, let deviceID = AudioInputDevice.deviceID(forUID: micUID) {
            // Suppress config-change observer during our own device switch
            suppressConfigChange = true
            let inputUnit = audioEngine.inputNode.audioUnit
            if let audioUnit = inputUnit {
                var devID = deviceID
                AudioUnitSetProperty(
                    audioUnit,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                // Re-initialize audio unit so it picks up the new device's format
                AudioUnitUninitialize(audioUnit)
                AudioUnitInitialize(audioUnit)
            }
            // Allow config changes again after a settle period
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.suppressConfigChange = false
            }
        }

        if transcriptionBackend == .appleSpeech {
            let resolvedLocale = Self.resolveSpeechLocaleIdentifier(
                preferred: NotchSettings.shared.speechLocale,
                text: sourceText
            )
            if resolvedLocale != NotchSettings.shared.speechLocale {
                NotchSettings.shared.speechLocale = resolvedLocale
            }

            speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: resolvedLocale))
            guard let speechRecognizer, speechRecognizer.isAvailable else {
                error = "语音识别器不可用"
                return
            }

            recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
            guard let recognitionRequest else { return }
            recognitionRequest.shouldReportPartialResults = true
        } else {
            speechRecognizer = nil
            recognitionRequest = nil
        }

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)

        // Guard against invalid format during device transitions (e.g. mic switch)
        guard recordingFormat.sampleRate > 0, recordingFormat.channelCount > 0 else {
            // Retry after a longer delay to let the audio system settle
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                error = "音频输入不可用"
                isListening = false
            }
            return
        }

        // Observe audio configuration changes (e.g. mic switched externally) to restart gracefully
        configurationChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.suppressConfigChange, !self.sourceText.isEmpty else { return }
            self.restartRecognition()
        }

        // Belt-and-suspenders: ensure no stale tap exists before installing
        inputNode.removeTap(onBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            if self?.transcriptionBackend == .appleSpeech {
                self?.recognitionRequest?.append(buffer)
            }

            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frameLength = Int(buffer.frameLength)
            var sum: Float = 0
            for i in 0..<frameLength {
                sum += channelData[i] * channelData[i]
            }
            let rms = sqrt(sum / Float(max(frameLength, 1)))
            let level = CGFloat(min(rms * 5, 1.0))

            DispatchQueue.main.async {
                self?.audioLevels.append(level)
                if (self?.audioLevels.count ?? 0) > 30 {
                    self?.audioLevels.removeFirst()
                }
            }
        }

        if transcriptionBackend == .appleSpeech,
           let speechRecognizer,
           let recognitionRequest {
            let currentGeneration = sessionGeneration
            recognitionTask = speechRecognizer.recognitionTask(with: recognitionRequest) { [weak self] result, error in
                guard let self else { return }
                if let result {
                    let spoken = result.bestTranscription.formattedString
                    DispatchQueue.main.async {
                        // Ignore stale results from a previous session
                        guard self.sessionGeneration == currentGeneration else { return }
                        self.retryCount = 0 // Reset on success
                        self.lastSpokenText = spoken
                        self.matchCharacters(spoken: spoken)
                    }
                }
                if error != nil {
                    DispatchQueue.main.async {
                        // If recognitionRequest is nil, cleanup already ran (intentional cancel) — don't retry
                        guard self.recognitionRequest != nil else { return }
                        if self.isListening && !self.shouldDismiss && !self.sourceText.isEmpty && self.retryCount < self.maxRetries {
                            self.retryCount += 1
                            let delay = min(Double(self.retryCount) * 0.5, 1.5)
                            self.scheduleBeginRecognition(after: delay)
                        } else {
                            self.isListening = false
                        }
                    }
                }
            }
        } else {
            recognitionTask = nil
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
            isListening = true
            if transcriptionBackend == .localSenseVoice {
                let currentGeneration = sessionGeneration
                guard startLocalSenseVoiceTranscription(generation: currentGeneration) else {
                    cleanupRecognition()
                    isListening = false
                    return
                }
            }
        } catch {
            // Transient failure after a device switch — retry with longer delay
            if retryCount < maxRetries {
                retryCount += 1
                scheduleBeginRecognition(after: 0.5)
            } else {
                self.error = "音频引擎失败：\(error.localizedDescription)"
                isListening = false
            }
        }
    }

    private func restartRecognition() {
        // Reset retries so the fresh engine gets a full set of attempts
        retryCount = 0
        isListening = true
        // Longer delay to let the audio system fully settle after a device change
        cleanupRecognition()
        scheduleBeginRecognition(after: 0.5)
    }

    private func startLocalSenseVoiceTranscription(generation: Int) -> Bool {
        let settings = NotchSettings.shared
        let configuredExecutablePath = settings.localSenseVoiceExecutablePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let executablePath = resolveLocalSenseVoiceExecutablePath(configuredExecutablePath) else {
            if configuredExecutablePath.isEmpty {
                error = "未配置本地识别程序。请在 设置 → 引导 → 本地模型 中导入 sense-voice-stream。"
            } else {
                error = "识别程序无效：\(configuredExecutablePath)\n请导入 sense-voice-stream 可执行文件。"
            }
            return false
        }
        let modelPath = settings.localSenseVoiceModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fileManager = FileManager.default

        guard !modelPath.isEmpty else {
            error = "未配置本地模型文件。请在 设置 → 引导 → 本地模型 中导入 .gguf 文件。"
            return false
        }
        guard fileManager.fileExists(atPath: modelPath) else {
            error = "本地模型文件不存在：\(modelPath)"
            return false
        }

        let language = resolveLocalSenseVoiceLanguage()
        let dyldLibraryPaths = resolveLocalSenseVoiceLibraryPaths(executablePath: executablePath)

        let runner = LocalSenseVoiceRunner()
        let started = runner.start(
            config: LocalSenseVoiceRunner.Config(
                executablePath: executablePath,
                modelPath: modelPath,
                language: language,
                disableGPU: settings.localSenseVoiceDisableGPU,
                dyldLibraryPaths: dyldLibraryPaths
            ),
            onTranscript: { [weak self] transcript in
                DispatchQueue.main.async {
                    self?.handleLocalSenseVoiceTranscript(transcript, generation: generation)
                }
            },
            onError: { [weak self] stderrLine in
                guard let self else { return }
                let normalized = stderrLine.lowercased()
                let isImportant = normalized.contains("error")
                    || normalized.contains("failed")
                    || normalized.contains("dyld")
                    || normalized.contains("couldn't")
                guard isImportant else { return }
                DispatchQueue.main.async {
                    guard self.sessionGeneration == generation else { return }
                    self.error = "本地模型错误：\(stderrLine)"
                }
            },
            onExit: { [weak self] code in
                DispatchQueue.main.async {
                    self?.handleLocalSenseVoiceExit(code: code, generation: generation)
                }
            }
        )

        if !started {
            error = runner.lastError ?? "启动本地识别失败"
            return false
        }

        localSenseVoiceRunner = runner
        return true
    }

    private func handleLocalSenseVoiceTranscript(_ transcript: String, generation: Int) {
        guard sessionGeneration == generation else { return }
        let cleaned = Self.sanitizeLocalTranscript(transcript)
        guard !cleaned.isEmpty else { return }
        retryCount = 0
        lastSpokenText = cleaned
        matchCharacters(spoken: cleaned)
    }

    private func handleLocalSenseVoiceExit(code: Int32, generation: Int) {
        guard sessionGeneration == generation else { return }
        guard isListening, !shouldDismiss, !sourceText.isEmpty else { return }
        if retryCount < maxRetries {
            retryCount += 1
            let delay = min(Double(retryCount) * 0.5, 1.5)
            scheduleBeginRecognition(after: delay)
        } else {
            isListening = false
            error = "本地识别进程已停止（退出码：\(code)）"
        }
    }

    private func resolveLocalSenseVoiceLanguage() -> String {
        let configured = NotchSettings.shared.localSenseVoiceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if configured != "auto", !configured.isEmpty {
            return configured
        }

        if let code = Self.languageCode(of: NotchSettings.shared.speechLocale) {
            switch code {
            case "zh", "en", "yue", "ja", "ko":
                return code
            default:
                break
            }
        }

        if let hint = Self.dominantLanguageHint(from: sourceText) {
            return hint
        }

        return "auto"
    }

    private func resolveLocalSenseVoiceExecutablePath(_ configuredPath: String) -> String? {
        if isValidLocalSenseVoiceExecutable(configuredPath) {
            return configuredPath
        }

        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/Tools/本地语音大模型/SenseVoice.cpp/build/bin/sense-voice-stream",
            "\(home)/Tools/SenseVoice.cpp/build/bin/sense-voice-stream",
        ]

        for candidate in candidates where isValidLocalSenseVoiceExecutable(candidate) {
            if NotchSettings.shared.localSenseVoiceExecutablePath != candidate {
                NotchSettings.shared.localSenseVoiceExecutablePath = candidate
            }
            return candidate
        }
        return nil
    }

    private func isValidLocalSenseVoiceExecutable(_ path: String) -> Bool {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return false }
        guard FileManager.default.fileExists(atPath: normalized) else { return false }
        let executableName = URL(fileURLWithPath: normalized).lastPathComponent.lowercased()
        guard executableName.contains("sense-voice-stream") else { return false }
        return ensureExecutablePermissionIfNeeded(at: normalized)
    }

    private func resolveLocalSenseVoiceLibraryPaths(executablePath: String) -> [String] {
        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: executablePath)
        let executableDirectory = executableURL.deletingLastPathComponent()

        let candidates = [
            executableDirectory.appendingPathComponent("../lib").standardizedFileURL.path,
            executableDirectory.appendingPathComponent("../../lib").standardizedFileURL.path,
            executableDirectory.path,
        ]

        var seen = Set<String>()
        var paths: [String] = []
        for path in candidates {
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                paths.append(path)
            }
        }
        return paths
    }

    private func ensureExecutablePermissionIfNeeded(at path: String) -> Bool {
        let fileManager = FileManager.default
        if fileManager.isExecutableFile(atPath: path) {
            return true
        }
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path)
        } catch {
            return false
        }
        return fileManager.isExecutableFile(atPath: path)
    }

    // MARK: - Fuzzy character-level matching

    private func matchCharacters(spoken: String) {
        // Strategy 1: character-level fuzzy match from the start offset
        let charResult = charLevelMatch(spoken: spoken)

        // Strategy 2: word-level match (handles STT word substitutions)
        let wordResult = wordLevelMatch(spoken: spoken)

        let best = max(charResult, wordResult)
        let spokenCompactCount = compactCharacters(from: spoken).count

        // Only move forward from the match start offset
        var newCount = matchStartOffset + best
        if transcriptionBackend == .localSenseVoice {
            // Local stream transcripts are short and noisy; cap base matcher movement
            // so one bad partial result cannot jump an entire paragraph.
            let maxBaseAdvance = max(28, min(180, spokenCompactCount * 7))
            newCount = min(newCount, recognizedCharCount + maxBaseAdvance)
        }

        // Local stream ASR usually emits short segment transcripts (not always cumulative).
        // Add a global anchor search so "jump reading" can snap to a later sentence.
        if transcriptionBackend == .localSenseVoice,
           let anchoredOffset = globalAnchorMatch(spoken: spoken),
           shouldAcceptAnchorJump(to: anchoredOffset, spokenCompactCount: spokenCompactCount) {
            newCount = max(newCount, anchoredOffset)
        }

        if newCount > recognizedCharCount {
            recognizedCharCount = min(newCount, sourceText.count)
            if transcriptionBackend == .localSenseVoice {
                // Keep a small lookback window so local incremental transcripts can
                // continue matching near the latest confirmed position.
                matchStartOffset = max(0, recognizedCharCount - 24)
            }
        } else if transcriptionBackend == .localSenseVoice {
            // Prevent stale far-jump confirmation state from accumulating forever.
            if Date().timeIntervalSinceReferenceDate - pendingAnchorJumpTimestamp > 1.8 {
                resetPendingAnchorJumpConfirmation()
            }
        }
    }

    private func resetPendingAnchorJumpConfirmation() {
        pendingAnchorJumpTarget = nil
        pendingAnchorJumpHits = 0
        pendingAnchorJumpTimestamp = 0
    }

    private func shouldAcceptAnchorJump(to anchoredOffset: Int, spokenCompactCount: Int) -> Bool {
        guard anchoredOffset > recognizedCharCount else {
            resetPendingAnchorJumpConfirmation()
            return false
        }

        let delta = anchoredOffset - recognizedCharCount
        let immediateLimit = max(90, min(260, spokenCompactCount * 7))
        guard delta > immediateLimit else {
            resetPendingAnchorJumpConfirmation()
            return true
        }

        let now = Date().timeIntervalSinceReferenceDate
        let timeout: TimeInterval = 1.8
        let targetTolerance = max(60, spokenCompactCount * 6)

        if let pending = pendingAnchorJumpTarget,
           abs(pending - anchoredOffset) <= targetTolerance,
           now - pendingAnchorJumpTimestamp <= timeout {
            pendingAnchorJumpHits += 1
        } else {
            pendingAnchorJumpTarget = anchoredOffset
            pendingAnchorJumpHits = 1
        }
        pendingAnchorJumpTimestamp = now

        if pendingAnchorJumpHits >= 2 {
            resetPendingAnchorJumpConfirmation()
            return true
        }
        return false
    }

    private func rebuildCompactSourceIndex() {
        compactSourceCharacters.removeAll(keepingCapacity: true)
        compactSourceToOriginalOffset.removeAll(keepingCapacity: true)

        let sourceChars = Array(sourceText)
        compactSourceCharacters.reserveCapacity(sourceChars.count)
        compactSourceToOriginalOffset.reserveCapacity(sourceChars.count)

        for (index, char) in sourceChars.enumerated() {
            for lowered in String(char).lowercased() where lowered.isLetter || lowered.isNumber {
                compactSourceCharacters.append(lowered)
                compactSourceToOriginalOffset.append(index + 1)
            }
        }
    }

    private func compactCharacters(from text: String) -> [Character] {
        var result: [Character] = []
        for char in text.lowercased() where char.isLetter || char.isNumber {
            result.append(char)
        }
        return result
    }

    private func globalAnchorMatch(spoken: String) -> Int? {
        guard !sourceText.isEmpty, !compactSourceCharacters.isEmpty else { return nil }

        let spokenCompact = compactCharacters(from: spoken)
        guard spokenCompact.count >= 4 else { return nil }
        guard spokenCompact.count <= compactSourceCharacters.count else { return nil }
        let hasPriorExact = hasPriorExactOccurrence(of: spokenCompact, beforeOriginalOffset: recognizedCharCount)
        let hasPriorSeed = hasPriorSeedOccurrence(of: spokenCompact, beforeOriginalOffset: recognizedCharCount)
        let hasForwardDuplicateSeed = hasForwardDuplicateSeedOccurrence(of: spokenCompact, fromOriginalOffset: recognizedCharCount)
        let preferNearestForward = hasPriorExact || hasPriorSeed || hasForwardDuplicateSeed
        let allowFarJump = !preferNearestForward

        // Longer snippets can use strict exact global matching first.
        if spokenCompact.count >= 6,
           let exact = findBestForwardEndOffset(
               for: spokenCompact,
               allowFarJump: allowFarJump,
               preferNearest: preferNearestForward
           ) {
            return exact
        }

        // Fuzzy anchor for noisy local ASR: compare against candidate windows
        // and choose the highest-similarity forward match.
        return fuzzyForwardEndOffset(
            for: spokenCompact,
            allowFarJump: allowFarJump,
            preferNearest: preferNearestForward
        )
    }

    private func findBestForwardEndOffset(for query: [Character], allowFarJump: Bool, preferNearest: Bool) -> Int? {
        guard !query.isEmpty else { return nil }
        guard query.count <= compactSourceCharacters.count else { return nil }

        let upperBound = compactSourceCharacters.count - query.count
        let localDistanceLimit = max(70, min(220, query.count * 6))
        var bestOffset: Int?
        var bestDistance = Int.max

        if upperBound < 0 { return nil }
        for start in 0...upperBound {
            var matched = true
            for index in 0..<query.count where compactSourceCharacters[start + index] != query[index] {
                matched = false
                break
            }
            guard matched else { continue }

            let endCompactIndex = start + query.count
            guard endCompactIndex > 0, endCompactIndex <= compactSourceToOriginalOffset.count else { continue }
            let endOffset = compactSourceToOriginalOffset[endCompactIndex - 1]

            // Forward-only anchor: do not snap backward.
            guard endOffset >= recognizedCharCount else { continue }

            let distance = endOffset - recognizedCharCount
            if !allowFarJump && !preferNearest && distance > localDistanceLimit {
                continue
            }
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = endOffset
                if distance == 0 { break }
            }
        }

        return bestOffset
    }

    private func fuzzyForwardEndOffset(for query: [Character], allowFarJump: Bool, preferNearest: Bool) -> Int? {
        let queryCount = query.count
        guard queryCount >= 4 else { return nil }

        let sourceCount = compactSourceCharacters.count
        let upperBound = sourceCount - queryCount
        guard upperBound >= 0 else { return nil }

        let queryString = String(query)
        let baseThreshold: Double
        switch queryCount {
        case 0...7:
            baseThreshold = 0.45
        case 8...11:
            baseThreshold = 0.52
        default:
            baseThreshold = 0.58
        }
        let threshold = preferNearest ? max(0.32, baseThreshold - 0.12) : baseThreshold

        var candidateStarts: [Int] = []
        if let first = query.first {
            for start in 0...upperBound where compactSourceCharacters[start] == first {
                candidateStarts.append(start)
            }
        }

        if candidateStarts.count > 240, queryCount >= 2 {
            let second = query[1]
            candidateStarts = candidateStarts.filter { start in
                start + 1 < sourceCount && compactSourceCharacters[start + 1] == second
            }
        }

        if candidateStarts.isEmpty {
            let coarseStep = max(1, queryCount / 3)
            candidateStarts = Array(stride(from: 0, through: upperBound, by: coarseStep))
        } else if candidateStarts.count > 320 {
            let strideStep = max(1, candidateStarts.count / 320)
            candidateStarts = candidateStarts.enumerated().compactMap { index, value in
                index % strideStep == 0 ? value : nil
            }
        }

        let queryPrefix = Array(query.prefix(min(3, queryCount)))
        let querySuffix = Array(query.suffix(min(3, queryCount)))
        let strictLocalLimit = max(70, min(220, queryCount * 6))
        let localBiasLimit: Int
        switch queryCount {
        case 0...6:
            localBiasLimit = 220
        case 7...10:
            localBiasLimit = 320
        case 11...14:
            localBiasLimit = 450
        default:
            localBiasLimit = 600
        }
        let softJumpLimit: Int
        switch queryCount {
        case 0...6:
            softJumpLimit = 420
        case 7...10:
            softJumpLimit = 700
        case 11...14:
            softJumpLimit = 1000
        default:
            softJumpLimit = Int.max
        }
        let farJumpSimilarityGate = 0.82

        struct FuzzyCandidate {
            let endOffset: Int
            let similarity: Double
            let distance: Int
        }
        var candidates: [FuzzyCandidate] = []
        candidates.reserveCapacity(min(candidateStarts.count, 128))

        for start in candidateStarts {
            let end = start + queryCount
            guard end <= sourceCount else { continue }

            let window = Array(compactSourceCharacters[start..<end])
            let windowPrefix = Array(window.prefix(queryPrefix.count))
            let windowSuffix = Array(window.suffix(querySuffix.count))
            let prefixMatchCount = zip(queryPrefix, windowPrefix).filter { $0 == $1 }.count
            let suffixMatchCount = zip(querySuffix, windowSuffix).filter { $0 == $1 }.count

            if queryCount >= 8 && prefixMatchCount == 0 && suffixMatchCount == 0 {
                continue
            }

            let distance = editDistance(queryString, String(window))
            let similarity = 1.0 - (Double(distance) / Double(queryCount))
            guard similarity >= threshold else { continue }

            let endOffset = compactSourceToOriginalOffset[end - 1]
            guard endOffset >= recognizedCharCount else { continue }

            let forwardDistance = endOffset - recognizedCharCount
            if !allowFarJump && !preferNearest && forwardDistance > strictLocalLimit {
                continue
            }
            if forwardDistance > softJumpLimit && similarity < farJumpSimilarityGate {
                continue
            }

            candidates.append(FuzzyCandidate(
                endOffset: endOffset,
                similarity: similarity,
                distance: forwardDistance
            ))
        }

        guard !candidates.isEmpty else { return nil }

        if preferNearest {
            let nearest = candidates.sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                    return lhs.similarity > rhs.similarity
                }
                return lhs.endOffset < rhs.endOffset
            }
            return nearest.first?.endOffset
        }

        let bestSimilarity = candidates.map(\.similarity).max() ?? threshold

        // Phase 1: local-lock for repeated text.
        // If we have a good-enough nearby candidate, prefer it and avoid jumping
        // to a later duplicated paragraph.
        let localSimilarityFloor = max(threshold + 0.08, bestSimilarity - 0.10)
        let nearLimit = allowFarJump ? localBiasLimit : strictLocalLimit
        let nearCandidates = candidates.filter { candidate in
            candidate.distance <= nearLimit && candidate.similarity >= localSimilarityFloor
        }
        if !nearCandidates.isEmpty {
            let nearSorted = nearCandidates.sorted { lhs, rhs in
                if lhs.distance != rhs.distance {
                    return lhs.distance < rhs.distance
                }
                if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                    return lhs.similarity > rhs.similarity
                }
                return lhs.endOffset < rhs.endOffset
            }
            return nearSorted.first?.endOffset
        }
        if !allowFarJump {
            // Repeated-content ambiguity mode: no nearby anchor means no anchor.
            // Keep progress stable and let local matcher continue incrementally.
            return nil
        }

        // Phase 2: global fallback (for real jump-reading).
        let similaritySlack: Double
        switch queryCount {
        case 0...7:
            similaritySlack = 0.02
        case 8...11:
            similaritySlack = 0.05
        default:
            similaritySlack = 0.08
        }
        let keptSimilarity = max(threshold, bestSimilarity - similaritySlack)
        let filtered = candidates.filter { $0.similarity >= keptSimilarity }
        let sorted = filtered.sorted { lhs, rhs in
            if lhs.distance != rhs.distance {
                return lhs.distance < rhs.distance
            }
            if abs(lhs.similarity - rhs.similarity) > 0.0001 {
                return lhs.similarity > rhs.similarity
            }
            return lhs.endOffset < rhs.endOffset
        }

        // 对重复文案：当多个位置都像时，优先取前面第一个（最近前向候选）。
        return sorted.first?.endOffset
    }

    private func compactIndex(forOriginalOffset offset: Int) -> Int {
        guard !compactSourceToOriginalOffset.isEmpty else { return 0 }
        if offset <= 0 { return 0 }
        if offset > compactSourceToOriginalOffset.last! {
            return compactSourceToOriginalOffset.count
        }

        var low = 0
        var high = compactSourceToOriginalOffset.count - 1
        var answer = compactSourceToOriginalOffset.count

        while low <= high {
            let mid = (low + high) / 2
            if compactSourceToOriginalOffset[mid] >= offset {
                answer = mid
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return answer
    }

    private func hasForwardDuplicateSeedOccurrence(of query: [Character], fromOriginalOffset offset: Int) -> Bool {
        let seedLength = min(max(4, query.count / 2), 6)
        guard query.count >= seedLength else { return false }
        guard seedLength <= compactSourceCharacters.count else { return false }

        let seed = Array(query.prefix(seedLength))
        let startCompact = max(0, compactIndex(forOriginalOffset: offset) - 1)
        let upperBound = compactSourceCharacters.count - seedLength
        guard startCompact <= upperBound else { return false }

        var matchCount = 0
        for start in startCompact...upperBound {
            var matched = true
            for index in 0..<seedLength where compactSourceCharacters[start + index] != seed[index] {
                matched = false
                break
            }
            guard matched else { continue }

            let endOffset = compactSourceToOriginalOffset[start + seedLength - 1]
            guard endOffset >= offset else { continue }

            matchCount += 1
            if matchCount >= 2 {
                return true
            }
        }
        return false
    }

    private func hasPriorExactOccurrence(of query: [Character], beforeOriginalOffset offset: Int) -> Bool {
        let queryCount = query.count
        guard queryCount >= 4 else { return false }
        guard queryCount <= compactSourceCharacters.count else { return false }

        let limitCompact = compactIndex(forOriginalOffset: offset)
        guard limitCompact >= queryCount else { return false }

        let lastStart = limitCompact - queryCount
        if lastStart < 0 { return false }

        for start in 0...lastStart {
            var matched = true
            for index in 0..<queryCount where compactSourceCharacters[start + index] != query[index] {
                matched = false
                break
            }
            if matched {
                return true
            }
        }
        return false
    }

    private func hasPriorSeedOccurrence(of query: [Character], beforeOriginalOffset offset: Int) -> Bool {
        let seedLength = min(max(4, query.count / 2), 6)
        guard query.count >= seedLength else { return false }
        let seed = Array(query.prefix(seedLength))
        return hasPriorExactOccurrence(of: seed, beforeOriginalOffset: offset)
    }

    private func charLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let src = Array(remainingSource.lowercased().unicodeScalars).map { Character($0) }
        let spk = Array(Self.normalize(spoken).unicodeScalars).map { Character($0) }

        var si = 0
        var ri = 0
        var lastGoodOrigIndex = 0

        while si < src.count && ri < spk.count {
            let sc = src[si]
            let rc = spk[ri]

            // Skip non-alphanumeric in source
            if !sc.isLetter && !sc.isNumber {
                si += 1
                continue
            }
            // Skip non-alphanumeric in spoken
            if !rc.isLetter && !rc.isNumber {
                ri += 1
                continue
            }

            if sc == rc {
                si += 1
                ri += 1
                lastGoodOrigIndex = si
            } else {
                // Try to re-sync: look ahead in both strings
                var found = false

                // Skip up to 3 chars in spoken (STT inserted extra chars)
                let maxSkipR = min(3, spk.count - ri - 1)
                if maxSkipR >= 1 {
                    for skipR in 1...maxSkipR {
                        let nextRI = ri + skipR
                        if nextRI < spk.count && spk[nextRI] == sc {
                            ri = nextRI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip up to 3 chars in source (STT missed some chars)
                let maxSkipS = min(3, src.count - si - 1)
                if maxSkipS >= 1 {
                    for skipS in 1...maxSkipS {
                        let nextSI = si + skipS
                        if nextSI < src.count && src[nextSI] == rc {
                            si = nextSI
                            found = true
                            break
                        }
                    }
                }
                if found { continue }

                // Skip both (substitution). Do not advance lastGood here;
                // otherwise long mismatch runs can falsely look like progress.
                si += 1
                ri += 1
            }
        }

        return lastGoodOrigIndex
    }

    private static func isAnnotationWord(_ word: String) -> Bool {
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        return stripped.isEmpty
    }

    private func wordLevelMatch(spoken: String) -> Int {
        let remainingSource = String(sourceText.dropFirst(matchStartOffset))
        let sourceWords = remainingSource.split(separator: " ").map { String($0) }
        let spokenWords = spoken.lowercased().split(separator: " ").map { String($0) }

        var si = 0 // source word index
        var ri = 0 // spoken word index
        var matchedCharCount = 0

        while si < sourceWords.count && ri < spokenWords.count {
            // Auto-skip annotation words in source (brackets, emoji)
            if Self.isAnnotationWord(sourceWords[si]) {
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 { matchedCharCount += 1 }
                si += 1
                continue
            }

            let srcWord = sourceWords[si].lowercased()
                .filter { $0.isLetter || $0.isNumber }
            let spkWord = spokenWords[ri]
                .filter { $0.isLetter || $0.isNumber }

            if srcWord == spkWord || isFuzzyMatch(srcWord, spkWord) {
                // Count original chars including trailing punctuation, plus space
                matchedCharCount += sourceWords[si].count
                if si < sourceWords.count - 1 {
                    matchedCharCount += 1 // space
                }
                si += 1
                ri += 1
            } else {
                // Try skipping up to 3 spoken words (STT hallucinated words)
                var foundSpk = false
                let maxSpkSkip = min(3, spokenWords.count - ri - 1)
                for skip in 1...max(1, maxSpkSkip) where skip <= maxSpkSkip {
                    let nextSpk = spokenWords[ri + skip].filter { $0.isLetter || $0.isNumber }
                    if srcWord == nextSpk || isFuzzyMatch(srcWord, nextSpk) {
                        ri += skip
                        foundSpk = true
                        break
                    }
                }
                if foundSpk { continue }

                // Try skipping up to 3 source words (user read fast, STT missed words)
                var foundSrc = false
                let maxSrcSkip = min(3, sourceWords.count - si - 1)
                for skip in 1...max(1, maxSrcSkip) where skip <= maxSrcSkip {
                    let nextSrc = sourceWords[si + skip].lowercased().filter { $0.isLetter || $0.isNumber }
                    if nextSrc == spkWord || isFuzzyMatch(nextSrc, spkWord) {
                        // Add all skipped source words' char counts
                        for s in 0..<skip {
                            matchedCharCount += sourceWords[si + s].count + 1
                        }
                        si += skip
                        foundSrc = true
                        break
                    }
                }
                if foundSrc { continue }

                // Try treating current source word as punctuation-only and skip it
                if srcWord.isEmpty {
                    matchedCharCount += sourceWords[si].count
                    if si < sourceWords.count - 1 { matchedCharCount += 1 }
                    si += 1
                    continue
                }
                // No match, advance spoken
                ri += 1
            }
        }

        // Auto-skip trailing annotation words at end of source
        while si < sourceWords.count && Self.isAnnotationWord(sourceWords[si]) {
            matchedCharCount += sourceWords[si].count
            if si < sourceWords.count - 1 { matchedCharCount += 1 }
            si += 1
        }

        return matchedCharCount
    }

    private func isFuzzyMatch(_ a: String, _ b: String) -> Bool {
        if a.isEmpty || b.isEmpty { return false }
        // Exact match
        if a == b { return true }
        // One starts with the other (phonetic prefix: "not" ~ "notch")
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        // One contains the other
        if a.contains(b) || b.contains(a) { return true }
        // Shared prefix >= 60% of shorter word
        let shared = zip(a, b).prefix(while: { $0 == $1 }).count
        let shorter = min(a.count, b.count)
        if shorter >= 2 && shared >= max(2, shorter * 3 / 5) { return true }
        // Edit distance tolerance
        let dist = editDistance(a, b)
        if shorter <= 4 { return dist <= 1 }
        if shorter <= 8 { return dist <= 2 }
        return dist <= max(a.count, b.count) / 3
    }

    private func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var dp = Array(0...b.count)
        for i in 1...a.count {
            var prev = dp[0]
            dp[0] = i
            for j in 1...b.count {
                let temp = dp[j]
                dp[j] = a[i-1] == b[j-1] ? prev : min(prev, dp[j], dp[j-1]) + 1
                prev = temp
            }
        }
        return dp[b.count]
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
    }

    private static func sanitizeLocalTranscript(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: "\\[[0-9]+(?:\\.[0-9]+)?-[0-9]+(?:\\.[0-9]+)?\\]",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "<\\|[^>]+\\|>",
            with: " ",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolveSpeechLocaleIdentifier(preferred: String, text: String) -> String {
        let supported = SFSpeechRecognizer.supportedLocales()
        guard !supported.isEmpty else { return preferred }

        if supported.contains(where: { sameLocale($0.identifier, preferred) }) {
            return preferred
        }

        if let code = languageCode(of: preferred),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        if let code = dominantLanguageHint(from: text),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        let currentID = Locale.current.identifier
        if supported.contains(where: { sameLocale($0.identifier, currentID) }) {
            return currentID
        }
        if let code = languageCode(of: currentID),
           let match = supported.first(where: { languageCode(of: $0.identifier) == code }) {
            return match.identifier
        }

        if let en = supported.first(where: { languageCode(of: $0.identifier) == "en" }) {
            return en.identifier
        }
        return supported.first?.identifier ?? preferred
    }

    private static func sameLocale(_ a: String, _ b: String) -> Bool {
        let na = canonicalLocaleKey(a)
        let nb = canonicalLocaleKey(b)
        return na == nb
    }

    private static func canonicalLocaleKey(_ id: String) -> String {
        id.lowercased().replacingOccurrences(of: "-", with: "_")
    }

    private static func languageCode(of localeID: String) -> String? {
        let components = NSLocale.components(fromLocaleIdentifier: localeID)
        return components[NSLocale.Key.languageCode.rawValue]?.lowercased()
    }

    private static func dominantLanguageHint(from text: String) -> String? {
        var zh = 0
        var ja = 0
        var ko = 0

        for scalar in text.unicodeScalars {
            let v = scalar.value
            switch v {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0xF900...0xFAFF:
                zh += 1
            case 0x3040...0x309F, 0x30A0...0x30FF:
                ja += 1
            case 0xAC00...0xD7AF:
                ko += 1
            default:
                break
            }
        }

        if zh == 0 && ja == 0 && ko == 0 {
            return nil
        }
        if zh >= ja && zh >= ko { return "zh" }
        if ja >= zh && ja >= ko { return "ja" }
        return "ko"
    }
}

private final class LocalSenseVoiceRunner {
    struct Config {
        let executablePath: String
        let modelPath: String
        let language: String
        let disableGPU: Bool
        let dyldLibraryPaths: [String]
    }

    var lastError: String?

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var outputBuffer = ""
    private var stderrBuffer = ""
    private var intentionallyStopped = false
    private var lastEmittedTranscript = ""

    private var onTranscript: ((String) -> Void)?
    private var onError: ((String) -> Void)?
    private var onExit: ((Int32) -> Void)?

    private let parserQueue = DispatchQueue(label: "Textream.LocalSenseVoiceRunner")

    func start(
        config: Config,
        onTranscript: @escaping (String) -> Void,
        onError: @escaping (String) -> Void,
        onExit: @escaping (Int32) -> Void
    ) -> Bool {
        stop()
        lastError = nil
        intentionallyStopped = false
        outputBuffer = ""
        stderrBuffer = ""
        lastEmittedTranscript = ""
        self.onTranscript = onTranscript
        self.onError = onError
        self.onExit = onExit

        let process = Process()
        process.executableURL = URL(fileURLWithPath: config.executablePath)

        var args = [
            "-m", config.modelPath,
            "-l", config.language,
            "--use-vad",
            "--chunk-size", "80",
            "-mmc", "8",
            "-mnc", "120",
            "--speech-prob-threshold", "0.2",
        ]
        if config.disableGPU {
            args.append("-ng")
        }
        process.arguments = args

        var environment = ProcessInfo.processInfo.environment
        let existingDYLD = (environment["DYLD_LIBRARY_PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var mergedDYLD: [String] = []
        for path in config.dyldLibraryPaths + existingDYLD where !path.isEmpty {
            if !mergedDYLD.contains(path) {
                mergedDYLD.append(path)
            }
        }
        if !mergedDYLD.isEmpty {
            environment["DYLD_LIBRARY_PATH"] = mergedDYLD.joined(separator: ":")
        }
        process.environment = environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parserQueue.async {
                self?.consumeOutputData(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.parserQueue.async {
                self?.consumeErrorData(data)
            }
        }

        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.parserQueue.async {
                self.clearReadHandlers()
                let status = process.terminationStatus
                let shouldNotify = !self.intentionallyStopped
                self.process = nil
                if shouldNotify {
                    self.onExit?(status)
                }
            }
        }

        do {
            try process.run()
            self.process = process
            return true
        } catch {
            clearReadHandlers()
            self.process = nil
            self.lastError = "无法启动本地识别程序：\(error.localizedDescription)"
            return false
        }
    }

    func stop() {
        intentionallyStopped = true
        clearReadHandlers()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
    }

    private func clearReadHandlers() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func consumeOutputData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        outputBuffer.append(stripANSIEscapeCodes(from: chunk))
        drainBuffer(&outputBuffer, handleLine: parseOutputLine)
    }

    private func consumeErrorData(_ data: Data) {
        guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
        stderrBuffer.append(stripANSIEscapeCodes(from: chunk))
        drainBuffer(&stderrBuffer) { [weak self] line in
            guard let self else { return }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            self.onError?(trimmed)
        }
    }

    private func drainBuffer(_ buffer: inout String, handleLine: (String) -> Void) {
        while let index = buffer.firstIndex(where: { $0 == "\n" || $0 == "\r" }) {
            let line = String(buffer[..<index])
            handleLine(line)
            var next = buffer.index(after: index)
            while next < buffer.endIndex, buffer[next] == "\n" || buffer[next] == "\r" {
                next = buffer.index(after: next)
            }
            buffer.removeSubrange(buffer.startIndex..<next)
        }
    }

    private func parseOutputLine(_ rawLine: String) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let timestampPattern = "\\[[0-9]+(?:\\.[0-9]+)?-[0-9]+(?:\\.[0-9]+)?\\]"
        let hasTimestamp = trimmed.range(of: timestampPattern, options: .regularExpression) != nil
        let hasSenseVoiceTag = trimmed.contains("<|")

        // 兼容不同 stream 构建：
        // 1) 标准输出: [0.00-1.23] <|zh|>...
        // 2) 仅标签文本: <|zh|><|ASR|>...
        guard hasTimestamp || hasSenseVoiceTag else {
            return
        }

        var text = trimmed
        if hasTimestamp {
            text = text.replacingOccurrences(of: timestampPattern, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<\\|[^>]+\\|>", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return }
        guard text != lastEmittedTranscript else { return }
        lastEmittedTranscript = text
        onTranscript?(text)
    }

    private func stripANSIEscapeCodes(from text: String) -> String {
        text.replacingOccurrences(of: "\\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    }
}
