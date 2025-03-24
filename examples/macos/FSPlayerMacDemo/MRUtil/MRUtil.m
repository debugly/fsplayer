//
//  MRUtil.m
//  FFmpegTutorial-macOS
//
//  Created by qianlongxu on 2020/12/2.
//

#import "MRUtil.h"
#import <ImageIO/ImageIO.h>
#if TARGET_OS_IOS
#import <MobileCoreServices/MobileCoreServices.h>
#endif

@implementation MRUtil

+ (NSArray <NSString *>*)audioType
{
    //https://samplerateconverter.com/educational/dsd-dsf-dff-audio
    //https://filesamples.com/categories/audio
    //https://software-download.name/sample-amr-audio-file/download.html
    static NSArray *audioTypes;
    if (!audioTypes) {
        NSDictionary *dic = [[NSBundle mainBundle] infoDictionary];
        NSArray *documentTypes = dic[@"CFBundleDocumentTypes"];
        NSMutableArray *_list = [NSMutableArray array];
        for (NSDictionary *item in documentTypes) {
            NSString *typeName = item[@"CFBundleTypeName"];
            if ([typeName isEqualToString:@"Other Audio Document"]) {
                NSArray *exts = item[@"CFBundleTypeExtensions"];
                [_list addObjectsFromArray:exts];
            }
        }
        audioTypes = [_list copy];
    }
    return audioTypes;
}

+ (NSArray <NSString *>*)subtitleType
{
    static NSArray *subTypes;
    if (!subTypes) {
        NSDictionary *dic = [[NSBundle mainBundle] infoDictionary];
        NSArray *documentTypes = dic[@"CFBundleDocumentTypes"];
        NSMutableArray *_list = [NSMutableArray array];
        for (NSDictionary *item in documentTypes) {
            NSString *typeName = item[@"CFBundleTypeName"];
            if ([typeName isEqualToString:@"Other Subtitle Document"]) {
                NSArray *exts = item[@"CFBundleTypeExtensions"];
                [_list addObjectsFromArray:exts];
            }
        }
        subTypes = [_list copy];
    }
    return subTypes;
}

+ (NSArray <NSString *>*)pictureType
{
    static NSArray *picTypes;
    if (!picTypes) {
        NSDictionary *dic = [[NSBundle mainBundle] infoDictionary];
        NSArray *documentTypes = dic[@"CFBundleDocumentTypes"];
        NSMutableArray *_list = [NSMutableArray array];
        for (NSDictionary *item in documentTypes) {
            NSString *typeName = item[@"CFBundleTypeName"];
            if ([typeName isEqualToString:@"Other Picture Document"]) {
                NSArray *exts = item[@"CFBundleTypeExtensions"];
                [_list addObjectsFromArray:exts];
            }
        }
        picTypes = [_list copy];
    }
    return picTypes;
}

// mov,qt,mp4,m4v,flv,f4v,webm,3gp2,3gpp,3gp,3g2,rm,rmvb,wmv,avi,asf,mpg,mpeg,mpe,ts,mkv,mod,flc,fli,ram,dirac,cpk,lavf,dat,div,dv,divx,vob
+ (NSArray <NSString *>*)videoType
{
    static NSArray *videoTypes;
    if (!videoTypes) {
        NSDictionary *dic = [[NSBundle mainBundle] infoDictionary];
        NSArray *documentTypes = dic[@"CFBundleDocumentTypes"];
        NSMutableArray *_list = [NSMutableArray array];
        
        for (NSDictionary *item in documentTypes) {
            NSString *typeName = item[@"CFBundleTypeName"];
            if ([typeName isEqualToString:@"Other Picture Document"] || [typeName isEqualToString:@"Other Subtitle Document"] || [typeName isEqualToString:@"Other Audio Document"]) {
                continue;
            }
            NSArray *exts = item[@"CFBundleTypeExtensions"];
            [_list addObjectsFromArray:exts];
        }
        videoTypes = [_list copy];
    }
    return videoTypes;
}

+ (NSArray <NSString *>*)acceptMediaType
{
    NSMutableArray *r = [[NSMutableArray alloc] init];
    [r addObjectsFromArray:[self audioType]];
    [r addObjectsFromArray:[self videoType]];
    [r addObjectsFromArray:[self subtitleType]];
    [r addObjectsFromArray:[self pictureType]];
    return r;
}

+ (BOOL)saveImageToFile:(CGImageRef)img path:(NSString *)imgPath
{
    CFStringRef imageUTType = NULL;
    NSString *fileType = [[imgPath pathExtension] lowercaseString];
    if ([fileType isEqualToString:@"jpg"] || [fileType isEqualToString:@"jpeg"]) {
        imageUTType = kUTTypeJPEG;
    } else if ([fileType isEqualToString:@"png"]) {
        imageUTType = kUTTypePNG;
    } else if ([fileType isEqualToString:@"tiff"]) {
        imageUTType = kUTTypeTIFF;
    } else if ([fileType isEqualToString:@"bmp"]) {
        imageUTType = kUTTypeBMP;
    } else if ([fileType isEqualToString:@"gif"]) {
        imageUTType = kUTTypeGIF;
    } else if ([fileType isEqualToString:@"pdf"]) {
        imageUTType = kUTTypePDF;
    }
    
    if (imageUTType == NULL) {
        imageUTType = kUTTypePNG;
    }

    CFStringRef key = kCGImageDestinationLossyCompressionQuality;
    CFStringRef value = CFSTR("0.5");
    const void * keys[] = {key};
    const void * values[] = {value};
    CFDictionaryRef opts = CFDictionaryCreate(CFAllocatorGetDefault(), keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    NSURL *fileUrl = [NSURL fileURLWithPath:imgPath];
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef) fileUrl, imageUTType, 1, opts);
    CFRelease(opts);
    
    if (destination) {
        CGImageDestinationAddImage(destination, img, NULL);
        CGImageDestinationFinalize(destination);
        CFRelease(destination);
        return YES;
    } else {
        return NO;
    }
}

+ (NSArray *)parseXPlayList:(NSURL*)url
{
    NSString *str = [[NSString alloc] initWithContentsOfFile:[url path] encoding:NSUTF8StringEncoding error:nil];
    str = [str stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSArray *lines = [str componentsSeparatedByString:@"\n"];
    NSMutableArray *preLines = [NSMutableArray array];
    int begin = -1;
    int end = -1;
    
    for (int i = 0; i < lines.count; i++) {
        NSString *path = lines[i];
        if (!path || [path length] == 0) {
            continue;
        } else if ([path hasPrefix:@"#"] || ([path hasPrefix:@"-"] && ![path hasPrefix:@"--"] )) {
            continue;
        } else if ([path hasPrefix:@"--begin"]) {
            begin = (int)preLines.count;
            continue;
        } else if ([path hasPrefix:@"--end"]) {
            end = (int)preLines.count;
            break;
        }
        path = [path stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [preLines addObject:path];
    }
    
    if (begin == -1) {
        begin = 0;
    }
    if (end == -1) {
        end = (int)[preLines count] - 1;
    }
    if (begin >= end) {
        NSLog(@"请检查XList文件里的begin位置");
        return nil;
    }
    NSArray *preLines2 = [preLines subarrayWithRange:NSMakeRange(begin, end - begin)];
    NSMutableArray *playList = [NSMutableArray array];
    for (int i = 0; i < preLines2.count; i++) {
        NSString *path = preLines2[i];
        if (!path || [path length] == 0) {
            continue;
        }
        NSURL *url = [NSURL URLWithString:path];
        [playList addObject:url];
    }
    NSLog(@"从XList读取到：%lu个视频文件",(unsigned long)playList.count);
    return [playList copy];
}

@end
