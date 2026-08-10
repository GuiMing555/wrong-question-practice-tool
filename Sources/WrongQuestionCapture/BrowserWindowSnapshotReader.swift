import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum BrowserPageTextSource: String {
    case chromeDOM = "chrome_dom"
    case accessibility = "accessibility"
}

struct BrowserPageTextCandidate {
    let source: BrowserPageTextSource
    let text: String
}

struct BrowserPageReadResult {
    let candidates: [BrowserPageTextCandidate]
    let diagnostics: [String]
}

struct BrowserPageArchive {
    let pageURL: URL
    let html: String
}

struct BrowserWindowSnapshotReader {
    private let maximumVisitedNodes = 30_000
    private let maximumCharacters = 500_000
    private let maximumArchiveCharacters = 15_000_000

    func readPageText(ownerPID: pid_t, windowTitle: String, bounds: CGRect) -> String? {
        readPageTextCandidates(
            ownerPID: ownerPID,
            windowTitle: windowTitle,
            bounds: bounds
        ).candidates.first?.text
    }

    func readPageTextCandidates(
        ownerPID: pid_t,
        windowTitle: String,
        bounds: CGRect
    ) -> BrowserPageReadResult {
        var candidates: [BrowserPageTextCandidate] = []
        var diagnostics: [String] = []

        do {
            let value = try executeChromeJavaScript(
                windowTitle: windowTitle,
                javaScript: "document.documentElement.innerText"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 20, value.count <= maximumCharacters {
                candidates.append(BrowserPageTextCandidate(source: .chromeDOM, text: value))
            } else {
                diagnostics.append("chrome_dom 字符数异常：\(value.count)")
            }
        } catch {
            diagnostics.append("chrome_dom 读取失败：\(error.localizedDescription)")
        }

        if AXIsProcessTrusted() {
            let application = AXUIElementCreateApplication(ownerPID)
            if let window = matchingWindow(
                in: application,
                targetTitle: windowTitle,
                targetBounds: bounds
            ), let document = firstDocument(in: window) {
                if let text = accessibilitySnapshot(from: document) {
                    if !candidates.contains(where: { $0.text == text }) {
                        candidates.append(BrowserPageTextCandidate(source: .accessibility, text: text))
                    }
                } else {
                    diagnostics.append("accessibility 没有读取到足够文字")
                }
            } else {
                diagnostics.append("accessibility 未找到匹配的浏览器文档")
            }
        } else {
            diagnostics.append("accessibility 权限未开启")
        }

        return BrowserPageReadResult(candidates: candidates, diagnostics: diagnostics)
    }

    func readPageArchive(windowTitle: String) throws -> BrowserPageArchive {
        let javaScript = #"""
        (() => {
          const clone = document.documentElement.cloneNode(true);
          const styleProperties = [
            'display', 'position', 'top', 'right', 'bottom', 'left', 'z-index',
            'box-sizing', 'width', 'min-width', 'max-width', 'height', 'min-height', 'max-height',
            'margin-top', 'margin-right', 'margin-bottom', 'margin-left',
            'padding-top', 'padding-right', 'padding-bottom', 'padding-left',
            'border-top-width', 'border-right-width', 'border-bottom-width', 'border-left-width',
            'border-top-style', 'border-right-style', 'border-bottom-style', 'border-left-style',
            'border-top-color', 'border-right-color', 'border-bottom-color', 'border-left-color',
            'border-radius', 'background-color', 'color', 'font-family', 'font-size',
            'font-weight', 'font-style', 'line-height', 'letter-spacing', 'text-align',
            'text-indent', 'text-decoration', 'white-space', 'word-break', 'overflow-wrap',
            'overflow-x', 'overflow-y', 'opacity', 'visibility', 'transform', 'transform-origin',
            'flex', 'flex-basis', 'flex-direction', 'flex-grow', 'flex-shrink', 'flex-wrap',
            'align-content', 'align-items', 'align-self', 'justify-content', 'justify-items',
            'justify-self', 'gap', 'row-gap', 'column-gap', 'grid-template-columns',
            'grid-template-rows', 'grid-column', 'grid-row', 'list-style', 'table-layout',
            'border-collapse', 'vertical-align', 'object-fit'
          ];
          const originalElements = [document.documentElement, ...document.documentElement.querySelectorAll('*')];
          const clonedElements = [clone, ...clone.querySelectorAll('*')];
          originalElements.forEach((source, index) => {
            const target = clonedElements[index];
            if (!target) return;
            const computed = getComputedStyle(source);
            target.removeAttribute('style');
            target.setAttribute('style', styleProperties.map(property => {
              return property + ':' + computed.getPropertyValue(property);
            }).join(';'));
            const position = computed.getPropertyValue('position');
            if (position === 'fixed' || position === 'sticky') {
              target.style.visibility = 'hidden';
            }
            if (source.scrollHeight > source.clientHeight + 2) {
              target.style.height = source.scrollHeight + 'px';
              target.style.maxHeight = 'none';
              target.style.overflowY = 'visible';
            }
            if (source.scrollWidth > source.clientWidth + 2) {
              target.style.width = source.scrollWidth + 'px';
              target.style.maxWidth = 'none';
              target.style.overflowX = 'visible';
            }
          });
          const originalControls = Array.from(document.querySelectorAll('input, textarea, select'));
          const clonedControls = Array.from(clone.querySelectorAll('input, textarea, select'));
          originalControls.forEach((source, index) => {
            const target = clonedControls[index];
            if (!target) return;
            if (source instanceof HTMLTextAreaElement) {
              target.textContent = source.value;
            } else if (source instanceof HTMLSelectElement) {
              Array.from(target.options).forEach((option, optionIndex) => {
                option.selected = source.options[optionIndex]?.selected === true;
              });
            } else {
              target.setAttribute('value', source.value || '');
              if (source.checked) target.setAttribute('checked', 'checked');
              else target.removeAttribute('checked');
            }
          });
          clone.querySelectorAll('script, noscript, style, link, iframe, object, embed, video, audio, source').forEach(node => node.remove());
          clone.querySelectorAll('meta[http-equiv="Content-Security-Policy"], meta[http-equiv="refresh"]').forEach(node => node.remove());
          clone.querySelectorAll('[src], [srcset], [poster], [background], [data]').forEach(node => {
            node.removeAttribute('src');
            node.removeAttribute('srcset');
            node.removeAttribute('poster');
            node.removeAttribute('background');
            node.removeAttribute('data');
          });
          clone.querySelectorAll('img').forEach(node => {
            node.setAttribute('src', 'data:image/gif;base64,R0lGODlhAQABAAD/ACwAAAAAAQABAAACADs=');
          });
          clone.querySelectorAll('image').forEach(node => {
            node.removeAttribute('href');
            node.removeAttribute('xlink:href');
          });
          clone.style.height = 'auto';
          clone.style.overflow = 'visible';
          const clonedBody = clone.querySelector('body');
          if (clonedBody) {
            clonedBody.style.height = 'auto';
            clonedBody.style.overflow = 'visible';
          }
          return JSON.stringify({
            pageURL: location.href,
            html: '<!doctype html>\n' + clone.outerHTML
          });
        })()
        """#
        let value = try executeChromeJavaScript(windowTitle: windowTitle, javaScript: javaScript)
        guard value.count <= maximumArchiveCharacters else {
            throw NSError(
                domain: "BrowserWindowSnapshotReader",
                code: 21,
                userInfo: [NSLocalizedDescriptionKey: "页面镜像超过 15 MB，已停止生成长图。"]
            )
        }
        guard let data = value.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawURL = object["pageURL"] as? String,
              let pageURL = URL(string: rawURL),
              let html = object["html"] as? String,
              !html.isEmpty
        else {
            throw NSError(
                domain: "BrowserWindowSnapshotReader",
                code: 22,
                userInfo: [NSLocalizedDescriptionKey: "浏览器返回的页面镜像格式无效。"]
            )
        }
        return BrowserPageArchive(pageURL: pageURL, html: html)
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

    private func executeChromeJavaScript(windowTitle: String, javaScript: String) throws -> String {
        let escapedTitle = windowTitle
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let escapedJavaScript = javaScript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
        let source = """
        tell application "Google Chrome"
            repeat with candidateWindow in windows
                set candidateTitle to title of active tab of candidateWindow
                if candidateTitle is "\(escapedTitle)" or candidateTitle contains "\(escapedTitle)" or "\(escapedTitle)" contains candidateTitle then
                    return execute active tab of candidateWindow javascript "\(escapedJavaScript)"
                end if
            end repeat
            error "没有找到标题匹配的 Chrome 标签页。"
        end tell
        """
        var error: NSDictionary?
        guard let descriptor = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
            let message = (error?[NSAppleScript.errorMessage] as? String) ?? "Chrome 页面脚本执行失败。"
            throw NSError(
                domain: "BrowserWindowSnapshotReader",
                code: 20,
                userInfo: [NSLocalizedDescriptionKey: message]
            )
        }
        return descriptor.stringValue ?? ""
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
