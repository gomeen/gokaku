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
        NSString *application = [client bundleIdentifier];
        if (!application.length) return nil;
        NSRect rectangle = NSZeroRect;
        if (includeRectangle) {
            @try { [client attributesForCharacterIndex:selection.location == NSNotFound ? 0 : selection.location
                                lineHeightRectangle:&rectangle]; } @catch (NSException *nested) {}
        }
        GGHostSnapshot *result = [GGHostSnapshot new];
        result.clientID = @""; result.application = application;
        result.selection = selection; result.rectangle = rectangle;
        result.selectionValid = selection.location != NSNotFound && selection.length != NSNotFound;
        result.rectangleRead = includeRectangle;
        // 零宽光标矩形可以有效（caret 无宽度）；非有限值或负尺寸才是无效。
        result.rectangleValid = isfinite(rectangle.origin.x) && isfinite(rectangle.origin.y)
            && isfinite(rectangle.size.width) && isfinite(rectangle.size.height)
            && rectangle.size.width >= 0 && rectangle.size.height > 0;
        NSRange marked = NSMakeRange(NSNotFound, 0);
        @try { marked = [client markedRange]; } @catch (NSException *nested) {}
        result.markedRange = marked;
        return result;
    } @catch (NSException *exception) { return nil; }
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
