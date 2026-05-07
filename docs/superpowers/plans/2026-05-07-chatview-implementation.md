# ChatView Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement ChatView for BoringNotch - click SessionRow to open message list view with dynamic window sizing (600×480).

**Architecture:** Extend NotchViews enum with `.chat(sessionId)` case, add openChat/closeChat methods to BoringViewCoordinator, create ChatView.swift with Header + StatusView + BottomBar layout, wire SessionRow tap gesture.

**Tech Stack:** SwiftUI, AppKit, Combine, Defaults, XPC Helper

---

## File Structure

| File | Responsibility |
|------|----------------|
| `enums/generic.swift` | NotchViews enum with chat case |
| `BoringViewCoordinator.swift` | Chat navigation state management |
| `BoringViewModel.swift` | Window size calculation for chat |
| `ContentView.swift` | Switch case for ChatView rendering |
| `SessionRow.swift` | Tap gesture wired to openChat |
| `AI/Views/ChatView.swift` | NEW - Chat message view |

---

### Task 1: Extend NotchViews Enum

**Files:**
- Modify: `boringNotch/enums/generic.swift:27-31`

- [ ] **Step 1: Read current NotchViews enum**

Run: Read file at `boringNotch/enums/generic.swift` lines 27-31

- [ ] **Step 2: Add chat case with Equatable**

```swift
public enum NotchViews: Equatable {
    case home
    case shelf
    case ai
    case chat(sessionId: String)  // NEW
    
    public static func == (lhs: NotchViews, rhs: NotchViews) -> Bool {
        switch (lhs, rhs) {
        case (.home, .home): return true
        case (.shelf, .shelf): return true
        case (.ai, .ai): return true
        case (.chat(let l), .chat(let r)): return l == r
        default: return false
        }
    }
}
```

- [ ] **Step 3: Commit**

```bash
git add boringNotch/enums/generic.swift
git commit -m "feat: add chat case to NotchViews enum"
```

---

### Task 2: Add Chat Navigation to BoringViewCoordinator

**Files:**
- Modify: `boringNotch/BoringViewCoordinator.swift`

- [ ] **Step 1: Read BoringViewCoordinator to find state properties location**

Run: Read file to find where `@Published var currentView` is defined

- [ ] **Step 2: Add selectedChatSession property and navigation methods**

Add after `currentView` property:

```swift
@Published var selectedChatSession: String? = nil

func openChat(sessionId: String) {
    selectedChatSession = sessionId
    currentView = .chat(sessionId: sessionId)
}

func closeChat() {
    selectedChatSession = nil
    currentView = .ai
}
```

- [ ] **Step 3: Commit**

```bash
git add boringNotch/BoringViewCoordinator.swift
git commit -m "feat: add openChat/closeChat navigation methods"
```

---

### Task 3: Update effectiveOpenNotchSize for Chat

**Files:**
- Modify: `boringNotch/models/BoringViewModel.swift:145-155`

- [ ] **Step 1: Read current effectiveOpenNotchSize implementation**

Run: Read `boringNotch/models/BoringViewModel.swift` lines 140-160

- [ ] **Step 2: Add chat case for fixed window size**

Insert at beginning of `effectiveOpenNotchSize`:

```swift
var effectiveOpenNotchSize: CGSize {
    let baseHeight = openNotchSize.height
    
    // Chat view: fixed 600×480
    if case .chat(_) = coordinator.currentView {
        return CGSize(width: 600, height: 480)
    }
    
    // Existing home view logic...
    if coordinator.currentView == .home && !aiManager.sessions.isEmpty && Defaults[.aiShowInNotch] {
        // ... keep existing calculation
    }
    
    return openNotchSize
}
```

- [ ] **Step 3: Commit**

```bash
git add boringNotch/models/BoringViewModel.swift
git commit -m "feat: add chat window size (600×480) to effectiveOpenNotchSize"
```

---

### Task 4: Create ChatView.swift

**Files:**
- Create: `boringNotch/AI/Views/ChatView.swift`

- [ ] **Step 1: Write ChatView with placeholder content**

```swift
import SwiftUI
import Defaults

struct ChatView: View {
    let sessionId: String
    @ObservedObject var aiManager = AIManager.shared
    @ObservedObject var coordinator = BoringViewCoordinator.shared
    @State private var inputText: String = ""
    @Default(.aiSleepAnimationEnabled) private var sleepAnimationEnabled
    
    private var session: AISessionState? {
        aiManager.sessions[sessionId]
    }
    
    var body: some View {
        VStack(spacing: 0) {
            chatHeader
            messageArea
            bottomBar
        }
        .background(Color.black)
    }
    
    // MARK: - Header
    
    @State private var isHeaderHovered = false
    
    private var chatHeader: some View {
        Button {
            coordinator.closeChat()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHeaderHovered ? .white : .white.opacity(0.6))
                    .frame(width: 24, height: 24)
                
                Text(projectName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(isHeaderHovered ? .white : .white.opacity(0.85))
                    .lineLimit(1)
                
                Spacer()
                
                // Status indicator
                if let session = session {
                    statusIndicator(for: session.phase)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isHeaderHovered ? Color.white.opacity(0.08) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHeaderHovered = $0 }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    // MARK: - Message Area (Placeholder)
    
    private var messageArea: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let session = session {
                    // Current status card
                    statusCard(session)
                    
                    // Placeholder message
                    placeholderMessageView
                } else {
                    Text("Session not found")
                        .foregroundColor(.white.opacity(0.4))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
    }
    
    @ViewBuilder
    private func statusCard(_ session: AISessionState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Phase
            HStack(spacing: 6) {
                Circle()
                    .fill(phaseColor(session.phase))
                    .frame(width: 8, height: 8)
                Text(session.phase.rawValue)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(phaseColor(session.phase))
            }
            
            // Current tool
            if let tool = session.currentTool {
                HStack(spacing: 6) {
                    Image(systemName: "wrench")
                        .font(.system(size: 11))
                        .foregroundColor(.orange)
                    Text(tool)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            
            // CWD
            if let cwd = session.cwd {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.blue)
                    Text(cwd)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.08))
        )
    }
    
    private var placeholderMessageView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Message History")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
            
            Text("Loading messages from JSONL will be implemented in Phase 2. For now, this shows current session status.")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white.opacity(0.05))
        )
    }
    
    // MARK: - Bottom Bar
    
    private var bottomBar: some View {
        HStack(spacing: 12) {
            TextField(canSendMessage ? "Message Claude..." : "Open in tmux to send messages", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(canSendMessage ? .white : .white.opacity(0.4))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.white.opacity(canSendMessage ? 0.08 : 0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20)
                                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                        )
                )
                .disabled(!canSendMessage)
                .onSubmit {
                    sendMessage()
                }
            
            Button {
                sendMessage()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 28))
                    .foregroundColor(!canSendMessage || inputText.isEmpty ? .white.opacity(0.2) : .white.opacity(0.9))
            }
            .buttonStyle(.plain)
            .disabled(!canSendMessage || inputText.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.black.opacity(0.2))
    }
    
    // MARK: - Helpers
    
    private var projectName: String {
        guard let cwd = session?.cwd else { return "Claude Code" }
        return cwd.split(separator: "/").last.map(String.init) ?? "Claude Code"
    }
    
    private var canSendMessage: Bool {
        session?.tty != nil
    }
    
    @ViewBuilder
    private func statusIndicator(for phase: AISessionPhase) -> some View {
        switch phase {
        case .processing, .runningTool, .compacting:
            ProcessingSpinner()
        case .waitingForApproval:
            Circle().fill(Color.orange).frame(width: 8, height: 8)
        case .waitingForInput:
            Circle().fill(Color.green).frame(width: 8, height: 8)
        case .toolFailed, .error:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        default:
            SleepIcon(size: 16, enableAnimation: sleepAnimationEnabled)
        }
    }
    
    private func phaseColor(_ phase: AISessionPhase) -> Color {
        switch phase {
        case .processing, .runningTool: return .orange
        case .waitingForApproval: return .orange
        case .waitingForInput: return .green
        case .toolFailed, .error: return .red
        default: return .gray
        }
    }
    
    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, canSendMessage else { return }
        
        inputText = ""
        Task {
            await aiManager.sendReply(text)
        }
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add boringNotch/AI/Views/ChatView.swift
git commit -m "feat: create ChatView with header, status card, bottom bar"
```

---

### Task 5: Wire SessionRow Tap Gesture

**Files:**
- Modify: `boringNotch/AI/Views/SessionRow.swift`

- [ ] **Step 1: Add coordinator reference**

Add at top of SessionRow struct:

```swift
@ObservedObject var coordinator = BoringViewCoordinator.shared
```

- [ ] **Step 2: Replace placeholder tap gesture**

Replace the `onTapGesture` block:

```swift
.onTapGesture {
    coordinator.openChat(sessionId: session.id)
}
```

- [ ] **Step 3: Commit**

```bash
git add boringNotch/AI/Views/SessionRow.swift
git commit -m "feat: wire SessionRow tap to openChat"
```

---

### Task 6: Add ChatView Case in ContentView Switch

**Files:**
- Modify: `boringNotch/ContentView.swift:398-407`

- [ ] **Step 1: Read current switch statement**

Run: Read `boringNotch/ContentView.swift` lines 395-410

- [ ] **Step 2: Add chat case**

```swift
switch coordinator.currentView {
case .home:
    NotchHomeView(albumArtNamespace: albumArtNamespace)
case .shelf:
    ShelfView()
case .ai:
    AIExpandedView()
case .chat(let sessionId):
    ChatView(sessionId: sessionId)
}
```

- [ ] **Step 3: Commit**

```bash
git add boringNotch/ContentView.swift
git commit -m "feat: add ChatView case in ContentView switch"
```

---

### Task 7: Build and Test

- [ ] **Step 1: Build the project**

Run: `xcodebuild -scheme boringNotch -configuration Debug build`

Expected: BUILD SUCCEEDED

- [ ] **Step 2: Quit existing app and launch new build**

```bash
osascript -e 'quit app "boringNotch"'
sleep 2
open ~/Library/Developer/Xcode/DerivedData/boringNotch-*/Build/Products/Debug/boringNotch.app
```

- [ ] **Step 3: Verify ChatView flow**

Manual verification:
1. Ensure AI sessions exist (run `claude` in terminal)
2. Click Notch to expand
3. Click a SessionRow → window should resize to 600×480
4. ChatView should display (Header + Status Card + Bottom Bar)
5. Click back button → return to AI view with original size

- [ ] **Step 4: Final commit if needed**

```bash
git status
# If any uncommitted changes:
git add -A
git commit -m "fix: any build or runtime fixes"
```

---

## Self-Review Checklist

**1. Spec coverage:**
- ✅ NotchViews enum extended with chat case
- ✅ BoringViewCoordinator has openChat/closeChat
- ✅ Window size 600×480 for chat
- ✅ ChatView created with Header + Messages + Bottom Bar
- ✅ SessionRow tap wired
- ✅ ContentView switch updated

**2. Placeholder scan:**
- ✅ No TBD/TODO in code blocks
- ✅ All code is complete
- ✅ All file paths are exact

**3. Type consistency:**
- ✅ `sessionId: String` type consistent across all tasks
- ✅ `NotchViews.chat(sessionId: String)` signature consistent
- ✅ `openChat(sessionId: String)` signature consistent

---

## Future Work (Phase 2)

Not included in this plan:
- Message history loading from JSONL
- ChatHistoryManager integration
- Full message rendering (user/assistant/tool)
- Three-button approval (Allow/Always/Deny)
- Inverted scroll for chat messages