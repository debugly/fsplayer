//
//  MRDragView.m
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2020/12/2.
//

#import "MRDragView.h"

@implementation MRDragView

- (void)registerDragTypes
{
    [self registerForDraggedTypes:[NSArray arrayWithObjects:NSPasteboardTypeFileURL, nil]];
}

- (id)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        //注册文件拖动事件
        [self registerDragTypes];
    }
    return self;
}

- (void)awakeFromNib
{
    [super awakeFromNib];
    [self registerDragTypes];
}

- (void)dealloc
{
    [self unregisterDraggedTypes];
}

- (NSArray *)draggedFileList:(id<NSDraggingInfo> _Nonnull)sender
{
    NSPasteboard *pboard = [sender draggingPasteboard];
    NSArray *list = nil;
    if ([[pboard types] containsObject:NSPasteboardTypeFileURL]) {
        list = [pboard readObjectsForClasses:@[[NSURL class]] options:nil];
    }
    
    NSMutableArray <NSURL *>*result = [NSMutableArray arrayWithArray:list];
    for (int i = 0; i < [result count]; i ++) {
        NSURL * obj = result[i];
        if ([obj isKindOfClass:[NSString class]]) {
            obj = [NSURL fileURLWithPath:(NSString *)obj];
            result[i] = obj;
        } else {
            //convert file:///.file/id=6571367.2701401 to normal path
            result[i] = [NSURL fileURLWithPath:[obj path]];;
        }
    }
    return [result copy];
}

//当文件被拖动到界面触发
- (NSDragOperation)draggingEntered:(id <NSDraggingInfo>)sender
{
    NSArray * list = [self draggedFileList:sender];
    if (self.delegate && [self.delegate respondsToSelector:@selector(acceptDragOperation:)]) {
        return [self.delegate acceptDragOperation:list];
    }
    return NSDragOperationNone;
}

//当文件在界面中放手
- (BOOL)prepareForDragOperation:(id<NSDraggingInfo>)sender
{
    NSArray * list = [self draggedFileList:sender];
    if (list.count && self.delegate && [self.delegate respondsToSelector:@selector(handleDragFileList:append:)]) {
        [self.delegate handleDragFileList:list append:sender.draggingSourceOperationMask != NSDragOperationGeneric];
    }
    return YES;
}

@end
