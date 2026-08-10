import AppKit
import CoreGraphics
import Foundation
import WebKit

final class BrowserFullPageRenderer: NSObject, WKNavigationDelegate {
    private struct PageMetrics: Decodable {
        let width: Double
        let height: Double
    }

    private let maximumCSSHeight: CGFloat = 40_000
    private let maximumPixelCount = 50_000_000
    private var webView: WKWebView?
    private var completion: ((Result<CGImage, Error>) -> Void)?
    private var timeoutWorkItem: DispatchWorkItem?

    func render(
        archive: BrowserPageArchive,
        viewportWidth: CGFloat,
        completion: @escaping (Result<CGImage, Error>) -> Void
    ) {
        guard self.completion == nil else {
            completion(.failure(Self.error(code: 30, message: "已有整页长图正在生成。")))
            return
        }

        self.completion = completion
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let width = min(max(viewportWidth, 640), 2_400)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: width, height: 900),
            configuration: configuration
        )
        webView.navigationDelegate = self
        self.webView = webView

        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(.failure(Self.error(code: 31, message: "隐藏页面渲染超过 15 秒。")))
        }
        timeoutWorkItem = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
        webView.loadHTMLString(archive.html, baseURL: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self, weak webView] in
            guard let self, let webView else { return }
            self.measureAndRender(webView)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(error))
    }

    private func measureAndRender(_ webView: WKWebView) {
        let script = """
        JSON.stringify({
          width: Math.max(document.documentElement.scrollWidth, document.body ? document.body.scrollWidth : 0, window.innerWidth),
          height: Math.max(document.documentElement.scrollHeight, document.body ? document.body.scrollHeight : 0, window.innerHeight)
        })
        """
        webView.evaluateJavaScript(script) { [weak self, weak webView] value, error in
            guard let self, let webView else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let metrics = try? JSONDecoder().decode(PageMetrics.self, from: data)
            else {
                self.finish(.failure(Self.error(code: 32, message: "无法测量隐藏页面的完整尺寸。")))
                return
            }

            let width = CGFloat(metrics.width.rounded(.up))
            let height = CGFloat(metrics.height.rounded(.up))
            guard width >= 240, height >= 160 else {
                self.finish(.failure(Self.error(code: 33, message: "隐藏页面尺寸异常：\(Int(width))×\(Int(height))。")))
                return
            }
            guard height <= self.maximumCSSHeight else {
                self.finish(.failure(Self.error(
                    code: 34,
                    message: "页面高度 \(Int(height)) 超过 \(Int(self.maximumCSSHeight))，已停止生成长图。"
                )))
                return
            }

            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: width, height: height)
            webView.createPDF(configuration: configuration) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let data):
                    do {
                        self.finish(.success(try self.rasterizePDF(data)))
                    } catch {
                        self.finish(.failure(error))
                    }
                case .failure(let error):
                    self.finish(.failure(error))
                }
            }
        }
    }

    private func rasterizePDF(_ data: Data) throws -> CGImage {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0
        else {
            throw Self.error(code: 35, message: "隐藏页面没有生成有效 PDF。")
        }

        let pages: [(CGPDFPage, CGRect)] = try (1...document.numberOfPages).map { index in
            guard let page = document.page(at: index) else {
                throw Self.error(code: 36, message: "无法读取长图中间页。")
            }
            return (page, page.getBoxRect(.mediaBox))
        }
        let widestPage = pages.map { $0.1.width }.max() ?? 0
        guard widestPage > 0 else {
            throw Self.error(code: 37, message: "长图页面宽度无效。")
        }

        let outputWidth = Int(ceil(min(widestPage, 2_400)))
        let scale = CGFloat(outputWidth) / widestPage
        let pageHeights = pages.map { Int(ceil($0.1.height * scale)) }
        let outputHeight = pageHeights.reduce(0, +)
        guard outputWidth > 0, outputHeight > 0,
              outputWidth * outputHeight <= maximumPixelCount
        else {
            throw Self.error(
                code: 38,
                message: "整页长图尺寸过大：\(outputWidth)×\(outputHeight)，已停止生成。"
            )
        }

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Self.error(code: 39, message: "无法创建整页长图画布。")
        }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))

        var consumedHeight = 0
        for (index, item) in pages.enumerated() {
            let pageHeight = pageHeights[index]
            let destination = CGRect(
                x: 0,
                y: outputHeight - consumedHeight - pageHeight,
                width: outputWidth,
                height: pageHeight
            )
            context.saveGState()
            context.concatenate(item.0.getDrawingTransform(
                .mediaBox,
                rect: destination,
                rotate: 0,
                preserveAspectRatio: true
            ))
            context.drawPDFPage(item.0)
            context.restoreGState()
            consumedHeight += pageHeight
        }

        guard let image = context.makeImage() else {
            throw Self.error(code: 40, message: "无法输出整页长图。")
        }
        return image
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        webView?.navigationDelegate = nil
        webView?.stopLoading()
        webView = nil
        completion(result)
    }

    private static func error(code: Int, message: String) -> NSError {
        NSError(
            domain: "BrowserFullPageRenderer",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
