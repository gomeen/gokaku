import Foundation

// 验收驱动用：向本会话发 Distributed Notification（如 org.gogaku.settings.changed），
// 触发输入法热更新设置；不触碰任何用户应用偏好。
let name = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "org.gogaku.settings.changed"
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name(name), object: nil, userInfo: nil, deliverImmediately: true)
