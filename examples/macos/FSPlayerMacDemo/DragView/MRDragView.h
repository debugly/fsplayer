//
//  MRDragView.h
//  FFmpegTutorial-macOS
//
//  Created by debugly on 2020/12/2.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol MRDragViewDelegate <NSObject>

- (NSDragOperation)acceptDragOperation:(NSArray <NSURL *> *)list;
//默认追加，按下option替换
- (void)handleDragFileList:(NSArray <NSURL *> *)fileUrls append:(BOOL)append;

@end

@interface MRDragView : NSView

@property (weak, nonatomic) IBOutlet id<MRDragViewDelegate> delegate;

@end

NS_ASSUME_NONNULL_END
