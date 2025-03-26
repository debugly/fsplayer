//
//  MRUtil+SystemPanel.m
//  FSPlayerDemo
//
//  Created by debugly on 2020/3/11.
//  Copyright © 2021 debugly.. All rights reserved.
//

#import "MRUtil+SystemPanel.h"
#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UTType.h>

@implementation MRUtil (SystemPanel)

+ (NSDictionary *)makeBookmarkWithURL:(NSURL *)url
{
    if ([url isFileURL]) {
        NSString *pathExtension = [[url pathExtension] lowercaseString];
        NSError *error = nil;
        NSData *bookmark = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                            | NSURLBookmarkCreationSecurityScopeAllowOnlyReadAccess includingResourceValuesForKeys:nil relativeToURL:nil error:&error];
        NSMutableDictionary *dic = [NSMutableDictionary dictionary];
        [dic setObject:url forKey:@"url"];
        if (bookmark) {
            [dic setObject:bookmark forKey:@"bookmark"];
        }
        if ([[self subtitleType] containsObject:pathExtension]) {
            [dic setObject:@(1) forKey:@"type"];
        } else {
            [dic setObject:@(0) forKey:@"type"];
        }
        return [dic copy];
    } else {
        NSMutableDictionary *dic = [NSMutableDictionary dictionary];
        [dic setObject:url forKey:@"url"];
        NSString *pathExtension = [[url pathExtension] lowercaseString];
        if ([[self subtitleType] containsObject:pathExtension]) {
            [dic setObject:@(1) forKey:@"type"];
        } else {
            [dic setObject:@(0) forKey:@"type"];
        }
        return [dic copy];
    }
    return nil;
}

+ (BOOL)isBDMVFloder:(NSString *)folder
{
    NSString *bdmv = [folder stringByAppendingPathComponent:@"BDMV"];
    BOOL isDirectory = NO;
    BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDirectory];
    if (isExist && isDirectory) {
        NSString *PLAYLIST = [bdmv stringByAppendingPathComponent:@"PLAYLIST"];
        NSString *STREAM = [bdmv stringByAppendingPathComponent:@"STREAM"];
        
        BOOL hasPLAYLIST = [[NSFileManager defaultManager] fileExistsAtPath:PLAYLIST isDirectory:&isDirectory] && isDirectory;
        BOOL hasSTREAM = [[NSFileManager defaultManager] fileExistsAtPath:STREAM isDirectory:&isDirectory] && isDirectory;
        
        return hasPLAYLIST && hasSTREAM;
    }
    return NO;
}

+ (NSArray <NSDictionary *>*)scanFolder:(NSURL *)url filter:(NSArray<NSString *>*)types
{
    NSError *error = nil;
    NSMutableArray *bookmarkArr = [NSMutableArray arrayWithCapacity:3];
    
    //先判断是不是文件夹
    BOOL isDirectory = NO;
    NSString *path = [url path];
    BOOL isExist = [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory];
    if (isExist) {
        if (isDirectory) {
            //扫描文件夹
            if ([self isBDMVFloder:path]) {
                NSDictionary *dic = [MRUtil makeBookmarkWithURL:url];
                NSURL *url = dic[@"url"];
                NSString *blurayPath = [@"bluray://" stringByAppendingString:[url path]];
                NSURL *blurayUrl = [NSURL URLWithString:blurayPath];
                NSMutableDictionary *muDic = [NSMutableDictionary dictionaryWithDictionary:dic];
                [muDic setObject:blurayUrl forKey:@"url"];
                [bookmarkArr addObject:muDic];
            } else {
                NSString *dir = path;
                NSArray<NSString *> *contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:&error];
                contents = [contents sortedArrayUsingComparator:^NSComparisonResult(NSString *  _Nonnull obj1, NSString *  _Nonnull obj2) {
                    return (NSComparisonResult)[obj1 compare:obj2 options:NSNumericSearch];
                }];
                
                if (!error && contents) {
                    for (NSString *c in contents) {
                        if ([c isEqualToString:@".DS_Store"]) {
                            continue;
                        }
                        NSString*fullPath = [dir stringByAppendingPathComponent:c];
                        NSArray *scaned = [self scanFolder:[NSURL fileURLWithPath:fullPath] filter:types];
                        if ([scaned count] > 0) {
                            [bookmarkArr addObjectsFromArray:scaned];
                        }
                    }
                    return [bookmarkArr copy];
                }
            }
        } else {
            NSString *pathExtension = [[path pathExtension] lowercaseString];
            if ([[self acceptMediaType] containsObject:pathExtension]) {
                NSDictionary *dic = [MRUtil makeBookmarkWithURL:url];
                [bookmarkArr addObject:dic];
            }
        }
    }
    return bookmarkArr;
}

+ (NSArray<NSDictionary *> *)_showSystemChooseFileOrFolderPanelWithType:(NSArray<NSString *>*)types {
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = YES;
    openPanel.allowsMultipleSelection = YES;
    
    NSString *downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    
    [openPanel setDirectoryURL:[NSURL URLWithString:downloadsDir]];
    [openPanel setAllowedFileTypes:types];
    
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    
    if ([openPanel runModal] == NSModalResponseOK) {
        NSArray<NSURL *> *urls = [openPanel URLs];
        for (NSURL *url in urls) {
            NSArray *dicArr = [self scanFolder:url filter:types];
            [bookmarkArr addObjectsFromArray:dicArr];
        }
    }
    
    if ([bookmarkArr count] > 0) {
        return bookmarkArr;
    } else {
        return nil;
    }
}

+ (NSArray<NSDictionary *> *)_showSystemChoosePanelWithType:(NSArray<NSString *>*)types autoScan:(BOOL)autoScan
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = YES;
    
    NSString *downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    
    [openPanel setDirectoryURL:[NSURL URLWithString:downloadsDir]];
    [openPanel setAllowedFileTypes:types];
    
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    
    if ([openPanel runModal] == NSModalResponseOK)
    {
        BOOL singleSelect = [[openPanel URLs] count] == 1;
        ///单选时才尝试自动扫描
        if (singleSelect && autoScan) {
            NSURL *url = [openPanel URL];
            NSString *dir = [[url path] stringByDeletingLastPathComponent];
            
            NSArray *dicArr = [self scanFolder:[NSURL fileURLWithPath:dir] filter:types];
            
            if ([dicArr count] > 0) {
                for (int i = 0; i < [dicArr count]; i ++) {
                    NSDictionary *dic = dicArr[i];
                    NSURL *_url = dic[@"url"];
                    ///标记下
                    if ([url isEqualTo:_url]) {
                        NSMutableDictionary *m_dic = [NSMutableDictionary dictionaryWithDictionary:dic];
                        [m_dic setObject:@"1" forKey:@"default"];
                        [bookmarkArr addObject:m_dic];
                    } else {
                        [bookmarkArr addObject:dic];
                    }
                }
            } else {
                ///不是download或者movie目录
                NSArray *urls = [openPanel URLs];
                
                for (NSURL *url in urls) {
                    NSDictionary *dic = [self makeBookmarkWithURL:url];
                    [bookmarkArr addObject:dic];
                }
            }
        } else {
            NSArray *urls = [openPanel URLs];
            
            for (NSURL *url in urls) {
                NSDictionary *dic = [self makeBookmarkWithURL:url];
                [bookmarkArr addObject:dic];
            }
        }
    }
    
    if ([bookmarkArr count] > 0) {
        return bookmarkArr;
    } else {
        return nil;
    }
}

+ (NSArray<NSDictionary *> *)_showSystemChooseFolderPanelWithType:(NSArray<NSString *>*)types
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = NO;
    openPanel.canChooseDirectories = YES;
    openPanel.allowsMultipleSelection = YES;
    
    NSString *downloadsDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    
    [openPanel setDirectoryURL:[NSURL URLWithString:downloadsDir]];
    [openPanel setAllowedFileTypes:types];
    
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    
    if ([openPanel runModal] == NSModalResponseOK) {
        ///扫描文件夹
        NSURL *url = [openPanel URL];
        NSArray *dicArr = [self scanFolder:url filter:types];
        [bookmarkArr addObjectsFromArray:dicArr];
        if ([dicArr count] > 0) {
            [bookmarkArr addObjectsFromArray:dicArr];
        }
    }
    
    if ([bookmarkArr count] > 0) {
        return bookmarkArr;
    } else {
        return nil;
    }
}

+ (NSArray<NSDictionary *> *)showSystemChooseVideoPanalForLocal {
    return [self _showSystemChooseFileOrFolderPanelWithType:[self videoType]];
}

+ (NSArray<NSDictionary *> *)showSystemChooseVideoPanel
{
    return [self _showSystemChoosePanelWithType:[self videoType] autoScan:NO];
}

+ (NSArray<NSDictionary *> *)showSystemChooseVideoPanelAutoScan
{
    return [self _showSystemChoosePanelWithType:[self videoType] autoScan:YES];
}

+ (NSArray<NSDictionary *> *)showSystemChooseFolderPanel
{
    return [self _showSystemChooseFolderPanelWithType:[self videoType]];
}

+ (NSArray<NSDictionary *> *)showSystemChooseVideoPanel4Share
{
    NSMutableArray *videoTypes = [NSMutableArray array];
    [videoTypes addObjectsFromArray:[self videoType]];
    [videoTypes addObjectsFromArray:[self subtitleType]];
    
    return [self _showSystemChoosePanelWithType:videoTypes autoScan:NO];
}

+ (NSDictionary *)showSystemChooseSubtitlePanel4Share:(NSString *)optDir
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = NO;
    
    if (!optDir) {
        optDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    }
    
    optDir = [optDir stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    
    [openPanel setDirectoryURL:[NSURL URLWithString:optDir]];
    
    [openPanel setAllowedFileTypes:[self subtitleType]];
    
    if ([openPanel runModal] == NSModalResponseOK)
    {
        NSURL *url = [[openPanel URLs] firstObject];
        return [self makeBookmarkWithURL:url];
    }
    return nil;
}

// 中文字符串转换成拼音
+ (NSString *)chineseStringTransformPinyin:(NSString *)chineseString
{
    if (chineseString == nil) {
        return nil;
    }
    // 拼音字段
    NSMutableString *tempNamePinyin = [chineseString mutableCopy];
    CFStringTransform((__bridge CFMutableStringRef)tempNamePinyin, NULL, kCFStringTransformMandarinLatin, NO);
    CFStringTransform((__bridge CFMutableStringRef)tempNamePinyin, NULL, kCFStringTransformStripDiacritics, NO);
    return tempNamePinyin.uppercaseString;
}

// 对中文字符串数组进行排序
+ (NSArray *)chineseSortWithStringArray:(NSArray *)stringArray
{
    if (stringArray == nil) {
        return nil;
    }
    NSMutableArray *tempArray = [[NSMutableArray alloc] init];
    for (int i = 0 ; i < [stringArray count] ; i++) {
        if (![[stringArray objectAtIndex:i] isKindOfClass:[NSString class]]) {
            return nil;
        }
        NSDictionary *tempDic = [[NSDictionary alloc] initWithObjectsAndKeys:[stringArray objectAtIndex:i], @"chinese", [self chineseStringTransformPinyin:[stringArray objectAtIndex:i]], @"pinyin", nil];
        [tempArray addObject:tempDic];
    }
    // 排序
    [tempArray sortUsingComparator:^NSComparisonResult(id obj1, id obj2) {
        return [[obj1 objectForKey:@"pinyin"] compare:[obj2 objectForKey:@"pinyin"] options:NSNumericSearch];
    }];
    NSMutableArray *resultArray = [[NSMutableArray alloc] init];
    for (NSDictionary *tempDic in tempArray) {
        [resultArray addObject:[tempDic objectForKey:@"chinese"]];
    }
    return resultArray;
}

+ (NSArray<NSDictionary *> *)showSystemChooseSubtitlesPanel4Share:(NSString *)optDir
{
    NSOpenPanel *openPanel = [NSOpenPanel openPanel];
    openPanel.canChooseFiles = YES;
    openPanel.canChooseDirectories = NO;
    openPanel.allowsMultipleSelection = YES;
    
    if (!optDir) {
        optDir = [NSSearchPathForDirectoriesInDomains(NSDownloadsDirectory, NSUserDomainMask, YES) firstObject];
    }
    
    optDir = [optDir stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    
    [openPanel setDirectoryURL:[NSURL URLWithString:optDir]];
    
    [openPanel setAllowedFileTypes:[self subtitleType]];
    
    NSMutableArray *bookmarkArr = [NSMutableArray array];
    
    if ([openPanel runModal] == NSModalResponseOK)
    {
        NSArray <NSURL *>* urls = [openPanel URLs];
        NSString *lastPathComponent;
        NSMutableArray *sortArray = [NSMutableArray array];
        for (NSURL *url in urls) {
            NSString *name = [[url path] lastPathComponent];
            lastPathComponent = [[url path] stringByDeletingLastPathComponent];
            [sortArray addObject:name];
        }
        //根据名称排序
        NSArray *sortedArray = [self chineseSortWithStringArray:sortArray];
        sortedArray = [[sortedArray reverseObjectEnumerator] allObjects];
        for (NSString *name in sortedArray) {
            NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@",lastPathComponent,name]];
            NSDictionary *dic = [self makeBookmarkWithURL:url];
            [bookmarkArr addObject:dic];
        }
        
        return [bookmarkArr count] > 0 ? [bookmarkArr copy] : nil;
    }
    return nil;
}

@end
