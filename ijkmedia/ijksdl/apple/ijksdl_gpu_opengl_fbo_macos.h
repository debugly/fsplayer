//
//  ijksdl_gpu_opengl_fbo_macos.h
//  FSPlayer
//
//  Created by Reach Matt on 2024/4/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol FSSDLSubtitleTextureWrapper;
@interface FSSDLOpenGLFBO : NSObject

@property(nonatomic, readonly) id<FSSDLSubtitleTextureWrapper> texture;

- (instancetype)initWithSize:(CGSize)size;
- (BOOL)canReuse:(CGSize)size;
- (CGSize)size;
- (void)bind;

@end

NS_ASSUME_NONNULL_END
