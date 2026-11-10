#import "GogakuHost.h"
#import <InputMethodKit/InputMethodKit.h>
@implementation GGHostSnapshot
@end
GGHostSnapshot *gg_read_host(id value) {
    return gg_read_host_state(value, YES);
}
/** 宿主矩形可用：有限值、非负宽、正高，且不是零矩形（宿主「无数据」的回报）。 */
static BOOL gg_rectangle_usable(NSRect r) {
    return isfinite(r.origin.x) && isfinite(r.origin.y)
        && isfinite(r.size.width) && isfinite(r.size.height)
        && r.size.width >= 0 && r.size.height > 0;
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
            rectangleValid = gg_rectangle_usable(rectangle);
            // 组合中按插入点读不到有效矩形时，按 SDK 契约读索引 0（索引相对
            // inline session，0＝组合起点）。2026-11-10 Orca 终端诊断实测：
            // 组合期间索引≥1（组合内相对位置、组合末尾、文档绝对位置）全为零，
            // 只有索引 0 返回非零且落在真实输入行；而首键前按绝对位置读到的
            // 是 pi 启动前 shell 行的陈旧矩形（面板钉在顶部）。只在组合中使用：
            // 无组合时索引 0 在 Orca 读数会在相邻字符格间循环，不可靠。
            // 2026-11-02 撤销的「组合起点回退」传的是 markedRange.location
            // （文档绝对位置），网页输入框据此返回控件原点；与索引 0 不同。
            if (!rectangleValid && marked.location != NSNotFound && marked.length > 0) {
                NSRect composition = NSZeroRect;
                @try { [client attributesForCharacterIndex:0 lineHeightRectangle:&composition]; }
                @catch (NSException *nested) { composition = NSZeroRect; }
                if (gg_rectangle_usable(composition)) {
                    rectangle = composition;
                    rectangleValid = YES;
                }
            }
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
