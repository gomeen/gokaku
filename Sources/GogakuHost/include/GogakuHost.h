#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface GGHostSnapshot : NSObject
@property(nonatomic, copy) NSString *clientID;
@property(nonatomic, copy) NSString *application;
@property(nonatomic) NSRange selection;
@property(nonatomic) BOOL selectionValid;
@property(nonatomic) BOOL rectangleValid;
@property(nonatomic) NSRange markedRange;  /* 宿主字母范围；location NSNotFound = 无 */
@property(nonatomic) NSRect rectangle;
@end
/** 只读取 client 元数据/光标，不读取正文。IPC 异常按无法确认目标处理。 */
FOUNDATION_EXPORT GGHostSnapshot * _Nullable gg_read_host(id _Nullable client);
/** 复查身份／选区时跳过光标几何 IPC；includeRectangle=NO 时 rectangleValid=NO。 */
FOUNDATION_EXPORT GGHostSnapshot * _Nullable gg_read_host_state(id _Nullable client, BOOL includeRectangle);
/** 更新输入区字母；caret 是 UTF-16 偏移，独立于已选中文前缀。 */
FOUNDATION_EXPORT BOOL gg_update_marked_text(id _Nullable client, NSString *text, NSUInteger caret);
/** 兼容原文确认路径，选区位于文本末尾。 */
FOUNDATION_EXPORT BOOL gg_mark_confirmed_text(id _Nullable client, NSString *text);
/** 清除宿主中的 marked text（失焦／切换前先清字母再存草稿）。 */
FOUNDATION_EXPORT BOOL gg_clear_marked_text(id _Nullable client);
/** 使用已校验 client 的当前选区插字；YES 仅表示调用已发出，不代表宿主已显示，不得自动重试。 */
FOUNDATION_EXPORT BOOL gg_insert_text(id _Nullable client, NSString *text);
NS_ASSUME_NONNULL_END
