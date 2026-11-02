// 最小鼠标驱动：移动（触发悬停）＋左键单击／双击，全局逻辑坐标。
// 仅本机开发验收用。用法：
//   swift scripts/mouse-click.swift move x y
//   swift scripts/mouse-click.swift click x y
//   swift scripts/mouse-click.swift double x y
import CoreGraphics
import Foundation

func post(_ type: CGEventType, at point: CGPoint, clicks: Int64 = 1) {
    let event = CGEvent(mouseEventSource: nil, mouseType: type,
                        mouseCursorPosition: point, mouseButton: .left)
    event?.setIntegerValueField(.mouseEventClickState, value: clicks)
    event?.post(tap: .cghidEventTap)
}

guard CommandLine.arguments.count >= 4,
      let x = Double(CommandLine.arguments[2]),
      let y = Double(CommandLine.arguments[3]) else {
    FileHandle.standardError.write(("usage: mouse-click.swift move|click|double x y\n").data(using: .utf8)!)
    exit(1)
}
let point = CGPoint(x: x, y: y)
let action = CommandLine.arguments[1]
switch action {
case "move":
    post(.mouseMoved, at: point)
case "click", "double":
    post(.mouseMoved, at: point)
    Thread.sleep(forTimeInterval: 0.25)   // 让 SwiftUI onHover 先生效
    post(.leftMouseDown, at: point)
    post(.leftMouseUp, at: point)
    if action == "double" {
        Thread.sleep(forTimeInterval: 0.18)
        post(.leftMouseDown, at: point, clicks: 2)
        post(.leftMouseUp, at: point, clicks: 2)
    }
default:
    exit(1)
}
