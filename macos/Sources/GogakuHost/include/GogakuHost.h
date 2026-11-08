#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface GGHostSnapshot : NSObject
@property(nonatomic, copy) NSString *clientID;
@property(nonatomic, copy) NSString *application;
@property(nonatomic) NSRange selection;
@property(nonatomic) BOOL selectionValid;
/** 光标矩形三态：YES＝本次读取且有效；NO＋rectangleRead=NO＝未读取（身份复查等
 *  跳过几何）；NO＋rectangleRead=YES＝读取了但没有可信矩形——几何异常，或选区
 *  未知（location NSNotFound）时不读任何字符索引，不冒充光标，控制器据此隐藏
 *  面板保留组合。 */
@property(nonatomic) BOOL rectangleValid;
@property(nonatomic) BOOL rectangleRead;
/** 宿主自报窗口层级（IMKTextInput.windowLevel）；windowLevelValid=NO 时恒为 0。 */
@property(nonatomic) NSInteger windowLevel;
@property(nonatomic) BOOL windowLevelValid;
@property(nonatomic) NSRange markedRange;  /* 宿主字母范围；location NSNotFound = 无 */
@property(nonatomic) NSRect rectangle;
@end

/** 候选窗基准层级（NSWindow.Level.popUpMenu）；宿主层级不可用或更低时使用。 */
FOUNDATION_EXPORT NSInteger const GGPanelLevelBaseline;
/** 宿主异常层级的钳制上限，防止候选窗被推到系统层之上。 */
FOUNDATION_EXPORT NSInteger const GGPanelLevelCeiling;
/** 宿主窗口层级 → 候选窗目标层级（纯函数）：无效或 ≤0 → 基准；
 *  否则 max(基准, clientWindowLevel + 1)，钳到上限。 */
FOUNDATION_EXPORT NSInteger GGPanelTargetLevel(NSInteger clientWindowLevel, BOOL clientWindowLevelValid);
/** 只读取 client 元数据/光标，不读取正文。IPC 异常按无法确认目标处理。 */
FOUNDATION_EXPORT GGHostSnapshot * _Nullable gg_read_host(id _Nullable client);
/** 复查身份／选区时跳过光标几何 IPC；includeRectangle=NO 时 rectangleRead=NO、rectangleValid=NO。 */
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
