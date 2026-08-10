import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

struct BrowserWindowSnapshotReader {
    private let maximumVisitedNodes = 30_000
    private let maximumCharacters = 500_000

    func readPageText(ownerPID: pid_t, windowTitle: String, bounds: CGRect) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let application = AXUIElementCreateApplication(ownerPID)
        guard let window = matchingWindow(
            in: application,
            targetTitle: windowTitle,
            targetBounds: bounds
        ), let document = firstDocument(in: window) else { return nil }

        let domText = directChromeDOMText(windowTitle: windowTitle)
        let accessibilityText = accessibilitySnapshot(from: document)
        return [domText, accessibilityText]
            .compactMap { $0 }
            .max(by: { $0.count < $1.count })
    }

    private func accessibilitySnapshot(from document: AXUIElement) -> String? {

        var queue: [AXUIElement] = [document]
        var cursor = 0
        var visited: Set<CFHashCode> = []
        var lines: [String] = []
        var characterCount = 0

        while cursor < queue.count,
              visited.count < maximumVisitedNodes,
              characterCount < maximumCharacters {
            let element = queue[cursor]
            cursor += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }

            let role = stringAttribute(element, kAXRoleAttribute)
            if shouldReadText(for: role), let value = readableText(from: element, role: role) {
                for rawLine in value.components(separatedBy: .newlines) {
                    let line = rawLine
                        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !line.isEmpty, lines.last != line else { continue }
                    lines.append(line)
                    characterCount += line.count + 1
                    if characterCount >= maximumCharacters { break }
                }
            }
            queue.append(contentsOf: children(of: element))
        }

        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count >= 20 ? text : nil
    }

    private func directChromeDOMText(windowTitle: String) -> String? {
        let escapedTitle = windowTitle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let source = """
        tell application "Google Chrome"
            repeat with candidateWindow in windows
                set candidateTitle to title of active tab of candidateWindow
                if candidateTitle is "\(escapedTitle)" or candidateTitle contains "\(escapedTitle)" or "\(escapedTitle)" contains candidateTitle then
                    return execute active tab of candidateWindow javascript "document.documentElement.innerText"
                end if
            end repeat
        end tell
        """
        var error: NSDictionary?
        guard let value = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue else {
            return nil
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.count >= 20 && normalized.count <= maximumCharacters ? normalized : nil
    }

    private func matchingWindow(
        in application: AXUIElement,
        targetTitle: String,
        targetBounds: CGRect
    ) -> AXUIElement? {
        let windows = elementsAttribute(application, kAXWindowsAttribute)
        return windows.min { left, right in
            windowDistance(left, targetTitle: targetTitle, targetBounds: targetBounds) <
                windowDistance(right, targetTitle: targetTitle, targetBounds: targetBounds)
        }
    }

    private func windowDistance(
        _ window: AXUIElement,
        targetTitle: String,
        targetBounds: CGRect
    ) -> CGFloat {
        var distance: CGFloat = 0
        if let position = pointAttribute(window, kAXPositionAttribute),
           let size = sizeAttribute(window, kAXSizeAttribute) {
            distance += abs(position.x - targetBounds.origin.x)
            distance += abs(position.y - targetBounds.origin.y)
            distance += abs(size.width - targetBounds.width)
            distance += abs(size.height - targetBounds.height)
        } else {
            distance += 100_000
        }
        let title = stringAttribute(window, kAXTitleAttribute) ?? ""
        if !targetTitle.isEmpty, title != targetTitle { distance += 10_000 }
        return distance
    }

    private func firstDocument(in window: AXUIElement) -> AXUIElement? {
        var queue: [AXUIElement] = [window]
        var cursor = 0
        var visited: Set<CFHashCode> = []
        while cursor < queue.count, visited.count < 5_000 {
            let element = queue[cursor]
            cursor += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            let role = stringAttribute(element, kAXRoleAttribute)
            if role == "AXWebArea" || role == "AXDocument" { return element }
            queue.append(contentsOf: children(of: element))
        }
        return nil
    }

    private func shouldReadText(for role: String?) -> Bool {
        guard let role else { return false }
        return [
            kAXStaticTextRole as String,
            "AXHeading", "AXLink", kAXButtonRole as String,
            kAXRadioButtonRole as String, kAXCheckBoxRole as String,
            kAXTextFieldRole as String, kAXTextAreaRole as String
        ].contains(role)
    }

    private func readableText(from element: AXUIElement, role: String?) -> String? {
        if role == kAXStaticTextRole as String ||
            role == kAXTextFieldRole as String ||
            role == kAXTextAreaRole as String,
           let value = stringAttribute(element, kAXValueAttribute), !value.isEmpty {
            return value
        }
        if let title = stringAttribute(element, kAXTitleAttribute), !title.isEmpty { return title }
        return stringAttribute(element, kAXValueAttribute)
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        elementsAttribute(element, kAXChildrenAttribute)
    }

    private func elementsAttribute(_ element: AXUIElement, _ name: String) -> [AXUIElement] {
        guard let value = attribute(element, name) else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    private func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let raw = attribute(element, name), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success
            ? value
            : nil
    }
}
