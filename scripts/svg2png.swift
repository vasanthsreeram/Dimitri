// svg2png: render an SVG file to PNG at exact pixel sizes using WebKit.
//
// No third-party tools: it loads the SVG into an offscreen WKWebView, draws it
// into a <canvas> and writes the canvas as a PNG with alpha. Each output is
// drawn at the largest whole multiple of its size that fits in 2048 px and
// box-filtered down (exact area coverage per pixel). WebKit evaluates SVG
// filters at low resolution on small targets, which otherwise blurs 16-128 px
// icons, and the averaging also smooths its gradient dithering.
//
// usage:
//   swift scripts/svg2png.swift [options] <input.svg> <size>=<output.png> [...]
//
//   <size>  "512" renders 512 px wide with the height taken from the viewBox
//           aspect ratio; "512x256" forces both dimensions.
//
// options:
//   --class <name>     add a class to the root <svg> before rendering; the
//                      design SVGs use class="dark" for their dark-background
//                      colours
//   --css <rules>      append a <style> element with these rules to the SVG
//   --background <c>   fill the canvas with a CSS colour first (review renders)
//   --supersample <n>  fixed supersampling factor (1 renders directly)
//
// WebKit does not pass the system appearance into SVG images, so renders are
// the same in light and dark mode; use --class to pick a variant.
//
// example:
//   swift scripts/svg2png.swift design/dimitri-icon.svg 16=a.png 1024=b.png

import AppKit
import WebKit

struct Job {
    let width: Int
    let height: Int?
    let output: URL
}

struct Options {
    var input: URL?
    var jobs: [Job] = []
    var rootClass: String?
    var css: String?
    var background: String?
    var supersample: Int?
}

let usage = """
    usage: svg2png [--class NAME] [--css RULES] [--background COLOR] [--supersample N] \
    input.svg SIZE=out.png ...
    """

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("svg2png: \(message)\n".utf8))
    exit(1)
}

func parseArguments() -> Options {
    var options = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let arg = args.removeFirst()
        switch arg {
        case "--class":
            guard !args.isEmpty else { fail("--class needs a value") }
            options.rootClass = args.removeFirst()
        case "--css":
            guard !args.isEmpty else { fail("--css needs a value") }
            options.css = args.removeFirst()
        case "--background":
            guard !args.isEmpty else { fail("--background needs a value") }
            options.background = args.removeFirst()
        case "--supersample":
            guard !args.isEmpty, let n = Int(args.removeFirst()), (1...32).contains(n) else {
                fail("--supersample needs a whole number from 1 to 32")
            }
            options.supersample = n
        case "-h", "--help":
            print(usage)
            exit(0)
        default:
            if options.input == nil {
                options.input = URL(fileURLWithPath: arg)
                continue
            }
            let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { fail("expected SIZE=output.png, got \(arg)") }
            let dims = parts[0].lowercased().split(separator: "x").compactMap { Int($0) }
            guard (1...2).contains(dims.count), dims.allSatisfy({ $0 > 0 && $0 <= 8192 }) else {
                fail("bad size \(parts[0])")
            }
            options.jobs.append(Job(
                width: dims[0],
                height: dims.count == 2 ? dims[1] : nil,
                output: URL(fileURLWithPath: parts[1])
            ))
        }
    }
    guard options.input != nil, !options.jobs.isEmpty else { fail(usage) }
    return options
}

// Runs inside the page. Sizing the <svg> root to the drawing size makes WebKit
// rasterise the vector at that size; the canvas keeps the alpha channel. The
// drawing is `ss` times the output size and is box-filtered down in
// premultiplied alpha, which gives exact area coverage per output pixel.
let renderScript = """
const doc = new DOMParser().parseFromString(svg, 'image/svg+xml');
const root = doc.documentElement;
if (root.nodeName !== 'svg' || doc.getElementsByTagName('parsererror').length) {
  throw new Error('input is not a well-formed SVG document');
}
let w = width, h = height;
if (!h) {
  const vb = (root.getAttribute('viewBox') || '').trim().split(/[\\s,]+/).map(Number);
  if (vb.length !== 4 || !(vb[2] > 0) || !(vb[3] > 0)) {
    throw new Error('SVG has no usable viewBox; pass WxH explicitly');
  }
  h = Math.round(w * vb[3] / vb[2]);
}
const ss = supersample || Math.max(1, Math.floor(2048 / Math.max(w, h)));
const W = w * ss, H = h * ss;
if (rootClass) {
  root.classList.add(rootClass);
}
if (css) {
  const style = doc.createElementNS('http://www.w3.org/2000/svg', 'style');
  style.textContent = css;
  root.appendChild(style);
}
root.setAttribute('width', String(W));
root.setAttribute('height', String(H));
const text = new XMLSerializer().serializeToString(doc);
const url = URL.createObjectURL(new Blob([text], { type: 'image/svg+xml' }));
try {
  const img = new Image();
  await new Promise((resolve, reject) => {
    img.onload = resolve;
    img.onerror = () => reject(new Error('WebKit could not load the SVG'));
    img.src = url;
  });
  const big = document.createElement('canvas');
  big.width = W;
  big.height = H;
  const bigCtx = big.getContext('2d');
  if (background) {
    bigCtx.fillStyle = background;
    bigCtx.fillRect(0, 0, W, H);
  }
  bigCtx.drawImage(img, 0, 0, W, H);
  if (ss === 1) {
    return big.toDataURL('image/png');
  }
  const src = bigCtx.getImageData(0, 0, W, H).data;
  const canvas = document.createElement('canvas');
  canvas.width = w;
  canvas.height = h;
  const ctx = canvas.getContext('2d');
  const out = ctx.createImageData(w, h);
  const n = ss * ss;
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      let r = 0, g = 0, b = 0, a = 0;
      for (let j = 0; j < ss; j++) {
        let k = ((y * ss + j) * W + x * ss) * 4;
        for (let i = 0; i < ss; i++, k += 4) {
          const alpha = src[k + 3];
          r += src[k] * alpha;
          g += src[k + 1] * alpha;
          b += src[k + 2] * alpha;
          a += alpha;
        }
      }
      const o = (y * w + x) * 4;
      if (a > 0) {
        out.data[o] = Math.round(r / a);
        out.data[o + 1] = Math.round(g / a);
        out.data[o + 2] = Math.round(b / a);
      }
      out.data[o + 3] = Math.round(a / n);
    }
  }
  ctx.putImageData(out, 0, 0);
  return canvas.toDataURL('image/png');
} finally {
  URL.revokeObjectURL(url);
}
"""

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var pageLoaded: CheckedContinuation<Void, Error>?

    override init() {
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 64, height: 64))
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
    }

    func loadBlankPage() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            pageLoaded = continuation
            webView.loadHTMLString("<!doctype html><html><head><meta charset=\"utf-8\"></head><body></body></html>", baseURL: nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageLoaded?.resume()
        pageLoaded = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageLoaded?.resume(throwing: error)
        pageLoaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        pageLoaded?.resume(throwing: error)
        pageLoaded = nil
    }

    func render(svg: String, job: Job, options: Options) async throws -> Data {
        let arguments: [String: Any] = [
            "svg": svg,
            "width": job.width,
            "height": job.height ?? 0,
            "rootClass": options.rootClass ?? "",
            "css": options.css ?? "",
            "background": options.background ?? "",
            "supersample": options.supersample ?? 0,
        ]
        let result = try await webView.callAsyncJavaScript(
            renderScript, arguments: arguments, in: nil, contentWorld: .page)
        guard let dataURL = result as? String,
              let comma = dataURL.firstIndex(of: ","),
              let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...]))
        else {
            throw NSError(domain: "svg2png", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "canvas returned no PNG data"])
        }
        return data
    }
}

let options = parseArguments()
let svgText: String
do {
    svgText = try String(contentsOf: options.input!, encoding: .utf8)
} catch {
    fail("cannot read \(options.input!.path): \(error.localizedDescription)")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

Task { @MainActor in
    let renderer = Renderer()
    do {
        try await renderer.loadBlankPage()
        for job in options.jobs {
            let png = try await renderer.render(svg: svgText, job: job, options: options)
            try FileManager.default.createDirectory(
                at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: job.output)
        }
        exit(0)
    } catch {
        let info = (error as NSError).userInfo
        fail(info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription)
    }
}

app.run()
