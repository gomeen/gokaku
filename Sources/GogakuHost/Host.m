#import "GogakuHost.h"
#import <InputMethodKit/InputMethodKit.h>
@implementation GGHostSnapshot
@end
GGHostSnapshot *gg_read_host(id value) {
    return gg_read_host_state(value, YES);
}
GGHostSnapshot *gg_read_host_state(id value, BOOL includeRectangle) {
    @try {
        id<IMKTextInput> client = value;
        if (!client || ![client supportsUnicode]) return nil;
        NSRange selection = NSMakeRange(NSNotFound, 0);
        @try { selection = [client selectedRange]; } @catch (NSException *nested) {}
        // 宿主窗口层级：候选窗排序依据（IMKTextInput 公开只读属性）。
        NSInteger windowLevel = 0;
        BOOL windowLevelValid = NO;
        @try {
            windowLevel = [(id<IMKTextInput>)client windowLevel];
            windowLevelValid = YES;
        } @catch (NSException *nested) { windowLevel = 0; windowLevelValid = NO; }
        NSString *application = [client bundleIdentifier];
        if (!application.length) return nil;
        NSRange marked = NSMakeRange(NSNotFound, 0);
        @try { marked = [client markedRange]; } @catch (NSException *nested) {}
        NSRect rectangle = NSZeroRect;
        BOOL rectangleRead = NO;
        BOOL rectangleValid = NO;
        if (includeRectangle) {
            // 选区未知（NSNotFound）不再用字符索引 0 冒充光标：索引 0 的矩形属于
            // 正文开头，与真实插入点无关，会误导候选窗定位。
            rectangleRead = YES;
            if (selection.location != NSNotFound) {
                @try { [client attributesForCharacterIndex:selection.location lineHeightRectangle:&rectangle]; }
                @catch (NSException *nested) { rectangle = NSZeroRect; }
            }
            // 零宽光标矩形可以有效（caret 无宽度）；非有限值或负尺寸才是无效。
            // 组合中矩形无效（Orca 1.4.246 对组合覆盖的插入点返回零矩形）由控
            // 制器冻结组合内最后有效锚点（refreshDisplayPosition）；此处不做
            // 组合起点索引回退——网页/Electron 输入框对组合起点返回控件原点
            // 附近的矩形，会被误当合法锚点把面板钉到屏幕左上角（2026-11-02
            // 用户报告后撤销该回退）。
            rectangleValid = isfinite(rectangle.origin.x) && isfinite(rectangle.origin.y)
                && isfinite(rectangle.size.width) && isfinite(rectangle.size.height)
                && rectangle.size.width >= 0 && rectangle.size.height > 0;
        }
        GGHostSnapshot *result = [GGHostSnapshot new];
        result.clientID = @""; result.application = application;
        result.selection = selection; result.rectangle = rectangle;
        result.selectionValid = selection.location != NSNotFound && selection.length != NSNotFound;
        result.rectangleRead = rectangleRead;
        result.rectangleValid = rectangleValid;
        result.windowLevel = windowLevel;
        result.windowLevelValid = windowLevelValid;
        result.markedRange = marked;
        return result;
    } @catch (NSException *exception) { return nil; }
}
/** 候选窗基准层级（NSWindow.Level.popUpMenu）：宿主层级不可用或更低时使用。 */
NSInteger const GGPanelLevelBaseline = 101;
/** 宿主异常层级的钳制上限：高于常规浮层，不把候选窗推到系统层之上。 */
NSInteger const GGPanelLevelCeiling = 10000;

/** 宿主窗口层级 → 候选窗目标层级（纯函数，HostTests/PanelLevelTests 覆盖）：
 *  clientWindowLevelValid=NO 或 clientWindowLevel ≤ 0 → 基准；
 *  否则 max(基准, clientWindowLevel + 1)，再钳到上限（先钳后加避免溢出）。
 *  客户端层级不高于基准时不抬高，常态排序不变。 */
NSInteger GGPanelTargetLevel(NSInteger clientWindowLevel, BOOL clientWindowLevelValid) {
    if (!clientWindowLevelValid || clientWindowLevel <= 0) return GGPanelLevelBaseline;
    if (clientWindowLevel >= GGPanelLevelCeiling) return GGPanelLevelCeiling;
    NSInteger raised = clientWindowLevel + 1;
    if (raised < GGPanelLevelBaseline) return GGPanelLevelBaseline;
    if (raised > GGPanelLevelCeiling) return GGPanelLevelCeiling;
    return raised;
}

BOOL gg_update_marked_text(id value, NSString *text, NSUInteger caret) {
    @try {
        if (!value) return NO;
        // 纯 NSString 会被宿主端 IMK 机制把选区改写成 (0, len)，拼音光标丢失；
        // NSAttributedString＋NSNotFound 替换范围保留光标（与 Squirrel 同源结论，
        // 实测见 docs/validation/short-tests）。
        // 注意 replacementRange 不能用 (0,0)：实测被当成绝对位置 0，在已有正文前插字。
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:text];
        [(id<IMKTextInput>)value setMarkedText:attr selectionRange:NSMakeRange(MIN(caret, text.length), 0)
                            replacementRange:NSMakeRange(NSNotFound, 0)];
        return YES;
    } @catch (NSException *exception) { return NO; }
}
BOOL gg_mark_confirmed_text(id value, NSString *text) {
    return gg_update_marked_text(value, text, text.length);
}

BOOL gg_clear_marked_text(id value) {
    @try {
        if (!value) return NO;
        NSAttributedString *attr = [[NSAttributedString alloc] initWithString:@""];
        [(id<IMKTextInput>)value setMarkedText:attr selectionRange:NSMakeRange(0, 0)
                            replacementRange:NSMakeRange(NSNotFound, 0)];
        return YES;
    } @catch (NSException *exception) { return NO; }
}
BOOL gg_insert_text(id value, NSString *text) {
    @try {
        if (!value) return NO;
        // NSNotFound tells the client to use its current selection. Explicit
        // ranges are not portable to Chromium's hidden terminal input field.
        id<IMKTextInput> client = value;
        [client insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
        return YES;
    } @catch (NSException *exception) { return NO; }
}
