//
//  MarqueeTextView.swift
//  Textream
//
//  Created by Fatih Kadir Akın on 8.02.2026.
//

import SwiftUI

// MARK: - Data

struct WordItem: Identifiable {
    let id: Int
    let word: String
    let charOffset: Int // char offset of this word in the full text (counting spaces)
    let isAnnotation: Bool // true for [bracket] words and emoji-only words
}

// MARK: - Preference key to report word Y positions

struct WordYPreferenceKey: PreferenceKey {
    static var defaultValue: [Int: CGFloat] = [:]
    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Teleprompter

struct SpeechScrollView: View {
    let words: [String]
    let highlightedCharCount: Int
    var font: NSFont = .systemFont(ofSize: 18, weight: .semibold)
    var highlightColor: Color = .white
    var onWordTap: ((Int) -> Void)? = nil
    /// Called when user starts/stops manual scrolling in smooth mode.
    /// Bool: true = scrolling started (pause timer), false = scrolling ended (resume timer).
    /// Double: new word progress to resume from (only meaningful when false).
    var onManualScroll: ((Bool, Double) -> Void)? = nil
    var smoothScroll: Bool = false
    /// Continuous word progress (e.g. 3.7 = 70% through 4th word). Drives scroll in smooth mode.
    var smoothWordProgress: Double = 0

    var isListening: Bool = true
    @State private var scrollOffset: CGFloat = 0
    @State private var manualOffset: CGFloat = 0
    @State private var wordYPositions: [Int: CGFloat] = [:]
    @State private var containerHeight: CGFloat = 0
    @State private var isUserScrolling: Bool = false

    var body: some View {
        GeometryReader { geo in
            WordFlowLayout(
                words: words,
                highlightedCharCount: highlightedCharCount,
                font: font,
                highlightColor: highlightColor,
                highlightWords: !smoothScroll,
                containerWidth: geo.size.width,
                onWordTap: { charOffset in
                    manualOffset = 0
                    onWordTap?(charOffset)
                    // Force recenter on tapped word
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        recalcCenter(containerHeight: containerHeight)
                    }
                }
            )
            .onPreferenceChange(WordYPreferenceKey.self) { positions in
                let wasEmpty = wordYPositions.isEmpty
                wordYPositions = positions
                // After a page switch, wordYPositions was cleared — recenter once new positions arrive
                if wasEmpty && !positions.isEmpty {
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .offset(y: scrollOffset + manualOffset)
            .animation(smoothScroll ? .linear(duration: 0.06) : .easeOut(duration: 0.5), value: scrollOffset)
            .animation(.easeOut(duration: 0.15), value: manualOffset)
            .onChange(of: geo.size.height) { _, newHeight in
                containerHeight = newHeight
                if highlightedCharCount == 0 && smoothWordProgress == 0 {
                    // Initial state: center first line on screen
                    let lineHeight = font.pointSize * 1.4
                    scrollOffset = newHeight * 0.5 - lineHeight * 0.5
                } else if isListening {
                    recalcCenter(containerHeight: newHeight)
                }
            }
            .onChange(of: highlightedCharCount) { _, _ in
                if isListening && !smoothScroll {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: smoothWordProgress) { _, _ in
                if isListening && smoothScroll {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: isListening) { _, listening in
                if listening {
                    manualOffset = 0
                    recalcCenter(containerHeight: containerHeight)
                }
            }
            .onChange(of: words) { _, _ in
                // First line at vertical center: height/2 + lineHeight/2
                let lineHeight = font.pointSize * 1.4
                scrollOffset = containerHeight * 0.5 - lineHeight * 0.5
                manualOffset = 0
                wordYPositions = [:]
            }
            .onAppear {
                containerHeight = geo.size.height
                // First line at vertical center: height/2 + lineHeight/2
                let lineHeight = font.pointSize * 1.4
                scrollOffset = containerHeight * 0.5 - lineHeight * 0.5
            }
            .overlay(
                ScrollWheelView(
                    onScroll: { delta in
                        let canScroll = smoothScroll ? isListening : !isListening
                        guard canScroll else { return }

                        // Pause timer when user starts scrolling in smooth mode
                        if smoothScroll && !isUserScrolling {
                            isUserScrolling = true
                            onManualScroll?(true, 0)
                        }

                        let maxY = wordYPositions.values.max() ?? 0
                        let containerHeight = geo.size.height
                        let maxUp = containerHeight * 0.5
                        let maxDown = max(0, maxY - containerHeight * 0.5)

                        let newOffset = manualOffset + delta
                        let upperBound = maxUp
                        let lowerBound = -maxDown

                        if newOffset > upperBound {
                            let over = newOffset - upperBound
                            manualOffset = upperBound + over * 0.2
                        } else if newOffset < lowerBound {
                            let over = lowerBound - newOffset
                            manualOffset = lowerBound - over * 0.2
                        } else {
                            manualOffset = newOffset
                        }
                    },
                    onScrollEnd: {
                        if smoothScroll && isUserScrolling {
                            // Find the word at the new visual center
                            let newProgress = wordProgressAtCurrentOffset()
                            withAnimation(.easeOut(duration: 0.15)) {
                                manualOffset = 0
                            }
                            isUserScrolling = false
                            onManualScroll?(false, newProgress)
                        } else {
                            let maxY = wordYPositions.values.max() ?? 0
                            let containerHeight = geo.size.height
                            let upperBound = containerHeight * 0.5
                            let lowerBound = -max(0, maxY - containerHeight * 0.5)

                            if manualOffset > upperBound || manualOffset < lowerBound {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    manualOffset = min(upperBound, max(lowerBound, manualOffset))
                                }
                            }
                        }
                    }
                )
            )
        }
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .white, location: 0.05),
                    .init(color: .white, location: 0.95),
                    .init(color: .clear, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func recalcCenter(containerHeight: CGFloat) {
        let center = containerHeight * 0.5

        if smoothScroll {
            // Classic/silence-paused: anchor active word near the bottom, scrolling up
            let bottomAnchor = containerHeight - 20
            let wordIdx = Int(smoothWordProgress)
            let fraction = smoothWordProgress - Double(wordIdx)
            let clampedIdx = max(0, min(wordIdx, words.count - 1))
            guard let wordY = wordYPositions[clampedIdx] else { return }
            let nextY = wordYPositions[clampedIdx + 1] ?? wordY
            let interpolatedY = wordY + (nextY - wordY) * CGFloat(fraction)
            scrollOffset = bottomAnchor - interpolatedY
        } else {
            // Word-tracking/voice-activated: active word at vertical center
            let wordIdx = activeWordIndex()
            if let wordY = wordYPositions[wordIdx] {
                let target = center - wordY
                // Only update if it actually changed to avoid redundant animations
                if abs(scrollOffset - target) > 1 {
                    scrollOffset = target
                }
            }
        }
    }

    /// Find the word progress at the current visual position (scrollOffset + manualOffset)
    private func wordProgressAtCurrentOffset() -> Double {
        let center = containerHeight * 0.5
        // The Y position currently at the center of the view
        let targetY = center - (scrollOffset + manualOffset)

        // Find the closest word and interpolate
        let sorted = wordYPositions.sorted { $0.key < $1.key }
        guard !sorted.isEmpty else { return smoothWordProgress }

        for i in 0..<sorted.count {
            let (wordIdx, wordY) = sorted[i]
            if i + 1 < sorted.count {
                let (_, nextY) = sorted[i + 1]
                if targetY >= wordY && targetY <= nextY {
                    let frac = (nextY - wordY) > 0 ? Double(targetY - wordY) / Double(nextY - wordY) : 0
                    return Double(wordIdx) + frac
                }
            } else if targetY >= wordY {
                return Double(wordIdx)
            }
        }
        // If scrolled above all words, return 0
        if targetY < (sorted.first?.value ?? 0) {
            return 0
        }
        return Double(words.count)
    }

    private func activeWordIndex() -> Int {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if highlightedCharCount <= end { return i }
            offset = end + 1
        }
        return max(0, words.count - 1)
    }

    /// Returns (wordIndex, fractionThroughWord) for smooth interpolation
    private func activeWordFraction() -> (Int, Double) {
        var offset = 0
        for (i, word) in words.enumerated() {
            let end = offset + word.count
            if highlightedCharCount <= end {
                let wordLen = max(1, word.count)
                let into = highlightedCharCount - offset
                return (i, Double(into) / Double(wordLen))
            }
            offset = end + 1
        }
        return (max(0, words.count - 1), 1.0)
    }
}

// MARK: - Word Flow Layout

struct WordFlowLayout: View {
    let words: [String]
    let highlightedCharCount: Int
    let font: NSFont
    var highlightColor: Color = .white
    var highlightWords: Bool = true
    let containerWidth: CGFloat
    var onWordTap: ((Int) -> Void)? = nil

    // Find the index of the next word to read (first non-fully-lit, non-annotation word)
    private func nextWordIndex() -> Int {
        let items = buildItems()
        for item in items {
            if item.isAnnotation { continue }
            let charsIntoWord = highlightedCharCount - item.charOffset
            let litCount = max(0, min(item.word.count, charsIntoWord))
            let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
            if litCount < letterCount {
                return item.id
            }
        }
        return -1
    }

    var body: some View {
        let items = buildItems()
        let lines = buildLines(items: items)
        let nextIdx = nextWordIndex()
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 0) {
                    ForEach(line, id: \.id) { item in
                        wordView(for: item, isNextWord: item.id == nextIdx)
                            .id(item.id)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: "flowLayout")
    }

    private func wordView(for item: WordItem, isNextWord: Bool) -> some View {
        let wordLen = item.word.count
        let charsIntoWord = highlightedCharCount - item.charOffset
        let litCount = max(0, min(wordLen, charsIntoWord))
        let letterCount = max(1, item.word.filter { $0.isLetter || $0.isNumber }.count)
        let isFullyLit = litCount >= letterCount
        let isCurrentWord = isNextWord || (charsIntoWord >= 0 && !isFullyLit)

        // When highlighting is off (classic/silence-paused), use uniform color
        if !highlightWords {
            let uniformColor: Color = item.isAnnotation
                ? Color.white.opacity(0.4)
                : highlightColor

            return Text(item.word + " ")
                .font(item.isAnnotation ? Font(font).italic() : Font(font))
                .foregroundStyle(uniformColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Annotations: italic, always dimmed
        if item.isAnnotation {
            let annotationColor: Color = isFullyLit
                ? Color.white.opacity(0.5)
                : Color.white.opacity(0.2)

            return Text(item.word + " ")
                .font(Font(font).italic())
                .foregroundStyle(annotationColor)
                .background(
                    GeometryReader { wordGeo in
                        Color.clear.preference(
                            key: WordYPreferenceKey.self,
                            value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                        )
                    }
                )
                .contentShape(Rectangle())
                .onTapGesture {
                    onWordTap?(item.charOffset)
                }
        }

        // Dim color: highlight color variant for current word, full for unread
        let dimColor: Color = isCurrentWord
            ? highlightColor.opacity(0.6)
            : highlightColor

        // Base color for the whole word
        let wordColor: Color = isFullyLit ? highlightColor.opacity(0.3) : dimColor

        return Text(item.word + " ")
            .font(Font(font))
            .foregroundStyle(wordColor)
            .underline(isCurrentWord, color: wordColor)
            .background(
                GeometryReader { wordGeo in
                    Color.clear.preference(
                        key: WordYPreferenceKey.self,
                        value: [item.id: wordGeo.frame(in: .named("flowLayout")).midY]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                onWordTap?(item.charOffset)
            }
    }

    private func buildItems() -> [WordItem] {
        var items: [WordItem] = []
        var offset = 0
        for (i, word) in words.enumerated() {
            let isAnnotation = Self.isAnnotationWord(word)
            items.append(WordItem(id: i, word: word, charOffset: offset, isAnnotation: isAnnotation))
            offset += word.count + 1 // +1 for space
        }
        return items
    }

    static func isAnnotationWord(_ word: String) -> Bool {
        // Words inside square brackets like [smile]
        if word.hasPrefix("[") && word.hasSuffix("]") { return true }
        // Emoji-only words (no letters or numbers)
        let stripped = word.filter { $0.isLetter || $0.isNumber }
        if stripped.isEmpty { return true }
        return false
    }

    private func buildLines(items: [WordItem]) -> [[WordItem]] {
        var lines: [[WordItem]] = [[]]
        var currentLineWidth: CGFloat = 0
        let spaceWidth = (" " as NSString).size(withAttributes: [.font: font]).width

        for item in items {
            let wordWidth = (item.word as NSString).size(withAttributes: [.font: font]).width + spaceWidth
            if currentLineWidth + wordWidth > containerWidth && !lines[lines.count - 1].isEmpty {
                lines.append([])
                currentLineWidth = 0
            }
            lines[lines.count - 1].append(item)
            currentLineWidth += wordWidth
        }
        return lines
    }
}

// MARK: - Audio Waveform + Progress

struct AudioWaveformProgressView: View {
    let levels: [CGFloat]
    let progress: Double // 0.0 to 1.0

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                let barProgress = Double(index) / Double(max(1, levels.count - 1))
                let isLit = barProgress <= progress

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(isLit
                          ? Color.yellow.opacity(0.9)
                          : Color.white.opacity(0.15)
                    )
                    .frame(width: 3, height: max(3, level * 28))
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
    }
}

// Keep the old one for backward compat
struct AudioWaveformView: View {
    let levels: [CGFloat]

    var body: some View {
        AudioWaveformProgressView(levels: levels, progress: 0)
    }
}

// MARK: - Scroll Wheel Handler

struct ScrollWheelView: NSViewRepresentable {
    var onScroll: (CGFloat) -> Void
    var onScrollEnd: (() -> Void)?

    init(onScroll: @escaping (CGFloat) -> Void, onScrollEnd: (() -> Void)? = nil) {
        self.onScroll = onScroll
        self.onScrollEnd = onScrollEnd
    }

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.onScrollEnd = onScrollEnd
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onScrollEnd = onScrollEnd
    }
}

class ScrollWheelNSView: NSView {
    var onScroll: ((CGFloat) -> Void)?
    var onScrollEnd: (() -> Void)?
    private var scrollMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && scrollMonitor == nil {
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window else { return event }
                // Only handle if event is in our window
                if event.window == window {
                    let delta = event.scrollingDeltaY
                    let scaled = event.hasPreciseScrollingDeltas ? delta : delta * 10
                    self.onScroll?(scaled)

                    if event.phase == .ended || event.momentumPhase == .ended {
                        self.onScrollEnd?()
                    }
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = scrollMonitor {
            NSEvent.removeMonitor(monitor)
            scrollMonitor = nil
        }
        super.removeFromSuperview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return nil
    }
}
