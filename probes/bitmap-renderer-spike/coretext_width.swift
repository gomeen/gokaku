import AppKit
let texts = ["中文 hello 日本語 nihao", "nihc", "你好世界", "hello🙂"]
let font = NSFont(name: "PingFangSC-Regular", size: 14) ?? NSFont.systemFont(ofSize: 14)
print("font=\(font.fontName)")
for t in texts {
    let s = NSAttributedString(string: t, attributes: [.font: font])
    let w = s.size().width
    print("\(t)\t\(String(format: "%.2f", w))")
}
