//
//  ijksdl_gpu_opengl_shader_compiler.h
//  FSPlayer
//
//  Created by Reach Matt on 2024/4/15.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface FSSDLOpenGLCompiler : NSObject

@property (copy) NSString *vsh;
@property (copy) NSString *fsh;

- (instancetype)initWithvsh:(NSString *)vshName
                        fsh:(NSString *)fshName;
- (BOOL)compileIfNeed;
- (uint32_t)program;
- (void)active;
- (int)getUniformLocation:(const char *)name;
- (int)getAttribLocation:(const char *)name;

@end

NS_ASSUME_NONNULL_END
