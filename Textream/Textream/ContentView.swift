//
//  ContentView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject private var service = TextreamService.shared
    @State private var isRunning = false
    @State private var isDroppingPresentation = false
    @State private var dropError: String?
    @State private var dropAlertTitle: String = "导入错误"
    @State private var showSettings = false
    @State private var showAbout = false
    @FocusState private var isTextFocused: Bool

    private let defaultText = """
欢迎来到 Textream！这是你的个人提词器，它会显示在 MacBook 刘海下方。[微笑]

当你朗读时，文字会实时高亮并跟随你的语音。语音识别会匹配你说出的内容并追踪进度。[停顿]

你可以随时暂停、回退并重读，高亮会继续同步。读完整段文本后，悬浮层会自动平滑关闭。[点头]

试着大声朗读这段文字，体验高亮跟读效果。底部波形会显示你的语音活动，旁边会展示你刚说过的几个词。

祝你演示顺利！[挥手]
"""

    private var languageLabel: String {
        let settings = NotchSettings.shared
        if settings.speechEngineMode == .localSenseVoice {
            let map: [String: String] = [
                "auto": "自动",
                "zh": "中文",
                "yue": "粤语",
                "en": "英语",
                "ja": "日语",
                "ko": "韩语",
            ]
            return "本地·" + (map[settings.localSenseVoiceLanguage] ?? settings.localSenseVoiceLanguage)
        }
        let locale = settings.speechLocale
        return Locale.current.localizedString(forIdentifier: locale) ?? locale
    }

    private var currentText: Binding<String> {
        Binding(
            get: {
                guard service.currentPageIndex < service.pages.count else { return "" }
                return service.pages[service.currentPageIndex]
            },
            set: { newValue in
                guard service.currentPageIndex < service.pages.count else { return }
                service.pages[service.currentPageIndex] = newValue
            }
        )
    }

    private var hasAnyContent: Bool {
        service.pages.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Sidebar with page squares
                if service.pages.count > 1 {
                    pageSidebar
                }

                // Main content area
                ZStack {
                    TextEditor(text: currentText)
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .scrollContentBackground(.hidden)
                        .padding(20)
                        .focused($isTextFocused)

                    // Floating action button (bottom-right)
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Button {
                                if isRunning {
                                    stop()
                                } else {
                                    run()
                                }
                            } label: {
                                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(isRunning ? Color.red : Color.accentColor)
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
                            }
                            .buttonStyle(.plain)
                            .disabled(!isRunning && !hasAnyContent)
                            .opacity(!hasAnyContent && !isRunning ? 0.4 : 1)
                        }
                        .padding(20)
                    }
                }
            }

            // Drop zone overlay — sits on top so TextEditor doesn't steal the drop
            if isDroppingPresentation {
                VStack(spacing: 8) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.accentColor)
                    Text("拖入 PowerPoint（.pptx）文件")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                    Text("如果是 Keynote 或 Google Slides，\n请先导出为 PPTX。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8]))
                        .background(Color.accentColor.opacity(0.08).clipShape(RoundedRectangle(cornerRadius: 12)))
                )
                .padding(8)
            }

            // Invisible drop target covering entire window
            Color.clear
                .contentShape(Rectangle())
                .onDrop(of: [.fileURL], isTargeted: $isDroppingPresentation) { providers in
                    guard let provider = providers.first else { return false }
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url else { return }
                        let ext = url.pathExtension.lowercased()
                        if ext == "key" {
                            DispatchQueue.main.async {
                                dropAlertTitle = "需要转换"
                                dropError = "Keynote 文件无法直接导入。请先将 Keynote 演示文稿导出为 PowerPoint（.pptx），再把导出的文件拖到这里。"
                            }
                            return
                        }
                        guard ext == "pptx" else {
                            DispatchQueue.main.async {
                                dropAlertTitle = "导入错误"
                                dropError = "不支持的文件。请拖入 PowerPoint（.pptx）文件。"
                            }
                            return
                        }
                        DispatchQueue.main.async {
                            handlePresentationDrop(url: url)
                        }
                    }
                    return true
                }
                .allowsHitTesting(isDroppingPresentation)
        }
        .alert(dropAlertTitle, isPresented: Binding(get: { dropError != nil }, set: { if !$0 { dropError = nil } })) {
            Button("确定") { dropError = nil }
        } message: {
            Text(dropError ?? "")
        }
        .frame(minWidth: 360, minHeight: 240)
        .background(.ultraThinMaterial)
        .toolbar {
            ToolbarItem(placement: .automatic) {
                HStack(spacing: 8) {
                    if let fileURL = service.currentFileURL {
                        Button {
                            service.openFile()
                        } label: {
                            HStack(spacing: 4) {
                                if service.pages != service.savedPages {
                                    Circle()
                                        .fill(.orange)
                                        .frame(width: 6, height: 6)
                                }
                                Text(fileURL.deletingPathExtension().lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }

                    // Add page button in toolbar
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            service.pages.append("")
                            service.currentPageIndex = service.pages.count - 1
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("页面")
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        showSettings = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: NotchSettings.shared.listeningMode.icon)
                                .font(.system(size: 10))
                            Text(NotchSettings.shared.listeningMode == .wordTracking
                                 ? languageLabel
                                 : NotchSettings.shared.listeningMode.label)
                                .font(.system(size: 11, weight: .medium))
                                .lineLimit(1)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(settings: NotchSettings.shared)
        }
        .sheet(isPresented: $showAbout) {
            AboutView()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAbout)) { _ in
            showAbout = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Sync button state when app is re-activated (e.g. dock click)
            isRunning = service.overlayController.isShowing
        }
        .onAppear {
            // Set default text for the first page if empty
            if service.pages.count == 1 && service.pages[0].isEmpty {
                service.pages[0] = defaultText
            }
            // Sync button state with overlay
            if service.overlayController.isShowing {
                isRunning = true
            }
            if TextreamService.shared.launchedExternally {
                DispatchQueue.main.async {
                    for window in NSApp.windows where !(window is NSPanel) {
                        window.orderOut(nil)
                    }
                }
            } else {
                isTextFocused = true
            }
        }
    }

    // MARK: - Page Sidebar

    private var pageSidebar: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(Array(service.pages.enumerated()), id: \.offset) { index, _ in
                        let isRead = service.readPages.contains(index)
                        let isCurrent = service.currentPageIndex == index
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                service.currentPageIndex = index
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: isCurrent ? .bold : .medium, design: .monospaced))
                                    .foregroundStyle(isCurrent ? .white : .primary)
                                Spacer()
                                if isRead && !isCurrent {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(maxWidth: .infinity)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(isCurrent ? Color.accentColor : Color.primary.opacity(0.06))
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            if service.pages.count > 1 {
                                Button(role: .destructive) {
                                    removePage(at: index)
                                } label: {
                                    Label("删除页面", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider().padding(.horizontal, 8)

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    service.pages.append("")
                    service.currentPageIndex = service.pages.count - 1
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 30)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        .frame(width: 68)
        .background(Color.primary.opacity(0.03))
    }

    // MARK: - Actions

    private func removePage(at index: Int) {
        guard service.pages.count > 1 else { return }
        withAnimation(.easeInOut(duration: 0.2)) {
            service.pages.remove(at: index)
            if service.currentPageIndex >= service.pages.count {
                service.currentPageIndex = service.pages.count - 1
            } else if service.currentPageIndex > index {
                service.currentPageIndex -= 1
            }
        }
    }

    private func run() {
        guard hasAnyContent else { return }
        // Resign text editor focus before hiding the window to avoid ViewBridge crashes
        isTextFocused = false
        service.onOverlayDismissed = { [self] in
            isRunning = false
            service.readPages.removeAll()
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
        service.readPages.removeAll()
        service.currentPageIndex = 0
        service.readCurrentPage()
        isRunning = true
    }

    @State private var isImporting = false

    private func handlePresentationDrop(url: URL) {
        guard service.confirmDiscardIfNeeded() else { return }
        isImporting = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let notes = try PresentationNotesExtractor.extractNotes(from: url)
                DispatchQueue.main.async {
                    service.pages = notes
                    service.savedPages = notes
                    service.currentPageIndex = 0
                    service.readPages.removeAll()
                    service.currentFileURL = nil
                    isImporting = false
                }
            } catch {
                DispatchQueue.main.async {
                    dropError = error.localizedDescription
                    isImporting = false
                }
            }
        }
    }

    private func stop() {
        service.overlayController.dismiss()
        service.readPages.removeAll()
        isRunning = false
    }
}

// MARK: - About View

struct AboutView: View {
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    var body: some View {
        VStack(spacing: 16) {
            // App icon
            if let icon = NSImage(named: "AppIcon") {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
            }

            // App name & version
            VStack(spacing: 4) {
                Text("Textream 中文增强版")
                    .font(.system(size: 20, weight: .bold))
                Text("版本 \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            // Description
            Text("基于开源项目深度定制的中文演讲/录制提词器。\n\n• 完整汉化界面\n• 接入本地语音大模型\n• 优化中文跟读同步稳定性\n\n能在您朗读或口播时，确保文案平滑滚动，不“乱跳”，且无需上传任何语音数据至云端。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)

            // Links
            HStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/GravityPoet/textream-zh")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                        Text("GitHub 仓库")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.08))
                    .clipShape(Capsule())
                }
            }

            Divider().padding(.horizontal, 20)

            VStack(spacing: 4) {
                Text("上游原作者：Fatih Kadir Akin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Button("确定") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(width: 380)
        .background(.ultraThinMaterial)
    }
}

#Preview {
    ContentView()
}
