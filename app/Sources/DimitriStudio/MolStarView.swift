import SwiftUI
import WebKit

/// Mol* in a WKWebView. Mol* itself loads from jsDelivr, so the viewer needs a
/// network connection the first time it is used; a plain fallback message is
/// shown if the CDN cannot be reached.
struct MolStarView: NSViewRepresentable {
    let cif: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        guard context.coordinator.loadedCIF != cif else { return }
        context.coordinator.loadedCIF = cif
        webView.loadHTMLString(Self.html(for: cif), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedCIF: String?
    }

    static func html(for cif: String) -> String {
        let encoded = Data(cif.utf8).base64EncodedString()
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8" />
          <style>
            html, body, #app { margin: 0; padding: 0; width: 100%; height: 100%; background: #0d1117; }
            #fallback {
              display: none; color: #9aa4b2; font: 13px -apple-system, system-ui;
              padding: 24px; text-align: center;
            }
            #loading { color: #9aa4b2; font: 12px -apple-system, system-ui; padding: 16px; }
          </style>
          <script src="https://cdn.jsdelivr.net/npm/molstar@4.10.0/build/viewer/molstar.js"></script>
        </head>
        <body>
          <div id="app"></div>
          <div id="loading">Loading Mol* viewer…</div>
          <div id="fallback">The Mol* viewer could not load. Check your network connection; structures can still be exported below.</div>
          <script>
            const b64 = "\(encoded)";
            const raw = atob(b64);
            const bytes = new Uint8Array(raw.length);
            for (let i = 0; i < raw.length; i++) { bytes[i] = raw.charCodeAt(i); }
            const text = new TextDecoder("utf-8").decode(bytes);

            function fail(message) {
              document.getElementById("loading").style.display = "none";
              const fallback = document.getElementById("fallback");
              fallback.style.display = "block";
              fallback.textContent = message;
            }

            if (!window.molstar) {
              fail("The Mol* viewer could not load from the CDN. Check your network connection; structures can still be exported.");
            } else {
              molstar.Viewer.create("app", {
                layoutIsExpanded: false,
                layoutShowControls: false,
                layoutShowSequence: false,
                layoutShowLog: false,
                layoutShowLeftPanel: false,
                viewportShowExpand: false,
                viewportShowSelectionMode: false,
                viewportShowAnimation: false
              }).then(async (viewer) => {
                document.getElementById("loading").style.display = "none";
                await viewer.loadStructureFromData(text, "mmcif");
                window.__dimitriViewerReady = true;
                try {
                  viewer.plugin.canvas3d?.setProps({
                    renderer: { backgroundColor: 0x0d1117 }
                  });
                } catch (e) { /* colour is cosmetic */ }
              }).catch((error) => {
                fail("Could not display this structure: " + error);
              });
            }
          </script>
        </body>
        </html>
        """
    }
}
