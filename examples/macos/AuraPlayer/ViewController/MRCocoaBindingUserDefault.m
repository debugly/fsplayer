//
//  MRCocoaBindingUserDefault.m
//  AuraPlayer
//
//  Created by debugly on 2024/1/25.
//  Copyright © 2024 FSPlayer Mac. All rights reserved.
//
//https://itecnote.com/tecnote/ios-nsuserdefaultsdidchangenotification-whats-the-name-of-the-key-that-changed/

//https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaBindings/Concepts/NSUserDefaultsController.html

#import "MRCocoaBindingUserDefault.h"
#import <AppKit/NSUserDefaultsController.h>
#import <AppKit/NSColor.h>
#import <FSPlayer/FSMediaPlayback.h>
#import "NSFileManager+Sandbox.h"

@interface MRCocoaBindingUserDefault()

@property (nonatomic, strong) NSMutableDictionary *observers;

@end

static NSData *MRArchiveColor(NSColor *color) {
    if (!color) return nil;
    NSError *error = nil;
    NSData *data = [NSKeyedArchiver archivedDataWithRootObject:color requiringSecureCoding:NO error:&error];
    if (error) {
        NSLog(@"[MRCocoaBindingUserDefault] Archive color error: %@", error);
    }
    return data;
}

static NSColor *MRUnarchiveColor(NSData *data) {
    if (!data || ![data isKindOfClass:[NSData class]]) return nil;
    NSError *error = nil;
    NSColor *color = [NSKeyedUnarchiver unarchivedObjectOfClass:[NSColor class] fromData:data error:&error];
    if (!color) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            color = [NSKeyedUnarchiver unarchiveObjectWithData:data];
#pragma clang diagnostic pop
        } @catch (NSException *exception) {
            NSLog(@"[MRCocoaBindingUserDefault] Unarchive color exception: %@", exception);
        }
    }
    return color;
}

@implementation MRCocoaBindingUserDefault

+ (MRCocoaBindingUserDefault *)sharedDefault
{
    static MRCocoaBindingUserDefault *obj = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        obj = [[MRCocoaBindingUserDefault alloc] init];
    });
    return obj;
}

- (instancetype)init
{
    self = [super init];
    if (self) {
        self.observers = [NSMutableDictionary dictionary];
    }
    return self;
}

+ (NSDictionary *)initValues 
{
    FSSubtitlePreference sp = fs_subtitle_default_preference();
    
    NSColor *text_color = fs_ass_int_to_color(sp.PrimaryColour);
    NSData *text_color_data = MRArchiveColor(text_color);
    
    NSColor *SecondaryColour = fs_ass_int_to_color(sp.SecondaryColour);
    NSData *subtitle_bg_color_data = MRArchiveColor(SecondaryColour);
    
    NSColor *OutlineColour = fs_ass_int_to_color(sp.OutlineColour);
    NSData *subtitle_stroke_color_data = MRArchiveColor(OutlineColour);
    
    NSColor *BackColour = fs_ass_int_to_color(sp.BackColour);
    NSData *subtitle_shadow_color_data = MRArchiveColor(BackColour);
    
    NSDictionary *initValues = @{
        @"volume" : @(0.4),
        @"playback_speed" : @(1.0),
        
        @"log_level":@"info",
        @"color_adjust_brightness" : @(1.0),
        @"color_adjust_saturation" : @(1.0),
        @"color_adjust_contrast" : @(1.0),
        @"use_opengl" : @(0),
        @"picture_fill_mode" : @(0),
        @"picture_wh_ratio" : @(0),
        @"picture_ratate_mode" : @(0),
        @"picture_flip_mode" : @(0),
        
        @"use_hw" : @(1),
        @"copy_hw_frame" : @(0),
        @"open_hdr" : @(1),
        @"overlay_format" : @"fcc-_es2",
        
        @"force_override" : @(1),
        @"FontName" : @"STSongti-SC-Regular",
        @"subtitle_scale" : @(1.0),
        @"subtitle_bottom_margin":@(20),
        @"subtitle_delay" : @(0),
        @"Outline" : @(1),
        @"PrimaryColour" : text_color_data,
        @"SecondaryColour" : subtitle_bg_color_data,
        @"OutlineColour" : subtitle_stroke_color_data,
        @"BackColour" : subtitle_shadow_color_data,
        @"custom_style" : @"",
        
        @"audio_delay" : @(0),
        @"snapshot_type" : @(3),
        @"snapshot_format" : @"jpg",
        @"record_format" : @(0),
        @"record_method" : @(0),
        @"accurate_seek" : @(1),
        @"seek_step" : @(15),
        @"lock_screen_ratio" : @(1),
        @"play_from_history" : @(1),
        @"multi_renderer_enabled" : @(0),
        @"deinterlace" : @(0),
        
        @"open_gzip" : @(1),
        @"use_dns_cache" : @(1),
        @"dns_cache_period" : @(600),
    };
    return initValues;
}

+ (void)initUserDefaults
{
    NSDictionary * initValues = [self initValues];
    [[NSUserDefaultsController sharedUserDefaultsController] setInitialValues:initValues];
    [[[NSUserDefaultsController sharedUserDefaultsController] defaults] registerDefaults:initValues];
}

+ (void)resetAll
{
    NSDictionary * initValues = [self initValues];
    [[[NSUserDefaultsController sharedUserDefaultsController] defaults] setPersistentDomain:initValues forName:[[NSBundle mainBundle] bundleIdentifier]];
    
    //清理掉现有的值
//    [[[NSUserDefaultsController sharedUserDefaultsController] defaults] removePersistentDomainForName:[[NSBundle mainBundle] bundleIdentifier]];
}

+ (NSString *)resolveKey:(NSString *)key
{
    if (!key) {
        return nil;
    }
    if (![key hasPrefix:@"values."]) {
        key = [@"values." stringByAppendingString:key];
    }
    return key;
}

+ (id)anyForKey:(NSString *)key
{
    key = [self resolveKey:key];
    return [[NSUserDefaultsController sharedUserDefaultsController] valueForKeyPath:key];
}

+ (void)setValue:(id)value forKey:(NSString *)key
{
    key = [self resolveKey:key];
    [[NSUserDefaultsController sharedUserDefaultsController] setValue:value forKeyPath:key];
}

+ (void)resetValueForKey:(NSString *)key
{
    key = [self resolveKey:key];
    id initValue = [[[NSUserDefaultsController sharedUserDefaultsController] initialValues] objectForKey:key];
    [self setValue:initValue forKey:key];
}

+ (BOOL)boolForKey:(NSString *)key
{
    return [[self anyForKey:key] boolValue];
}

+ (float)floatForKey:(NSString *)key
{
    return [[self anyForKey:key] floatValue];
}

+ (NSString *)stringForKey:(NSString *)key
{
    return [[self anyForKey:key] description];
}

+ (int)intForKey:(NSString *)key
{
    return [[self anyForKey:key] intValue];
}

- (void)onChange:(void(^)(id,BOOL*))observer forKey:(NSString *)key
{
    [self onChange:observer forKey:key init:NO];
}

- (void)onChange:(void(^)(id,BOOL*))observer forKey:(NSString *)key init:(BOOL)init
{
    if (!observer) {
        return;
    }
    BOOL remove = NO;
    if (init) {
        id value = [[self class] anyForKey:key];
        observer(value, &remove);
    }
    
    if (!remove) {
        NSMutableArray *array = [self.observers objectForKey:key];
        if (!array) {
            array = [NSMutableArray array];
            [self.observers setObject:array forKey:key];
            NSUserDefaults *defaults = [[NSUserDefaultsController sharedUserDefaultsController] defaults];
            [defaults addObserver:self
                       forKeyPath:key
                          options:NSKeyValueObservingOptionNew
                          context:NULL];
        }
        [array addObject:[observer copy]];
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                 ofObject:(id)object
                   change:(NSDictionary *)change
                  context:(void *)context
{
    NSArray *array = [self.observers objectForKey:keyPath];
    id value = change[NSKeyValueChangeNewKey];
    NSMutableArray *removeArr = nil;
    for (NSUInteger i = 0; i < array.count; i++) {
        void(^block)(id,BOOL*) = array[i];
        BOOL remove = NO;
        if ([value isKindOfClass:[NSData class]]) {
            value = MRUnarchiveColor(value) ?: value;
        }
        block(value, &remove);
        if (remove) {
            if (removeArr == nil) {
                removeArr = [NSMutableArray array];
            }
            [removeArr addObject:@(i)];
        }
    }
    if ([removeArr count] > 0) {
        NSMutableArray *result = [NSMutableArray arrayWithArray:array];
        NSEnumerator *enumerator = [removeArr reverseObjectEnumerator];
        id obj = nil;
        while ((obj = [enumerator nextObject])) {
            [result removeObjectAtIndex:[obj intValue]];
        }
        [self.observers setObject:result forKey:keyPath];
    }
}

@end

@implementation MRCocoaBindingUserDefault (util)

+ (NSString *)log_level
{
    return [self stringForKey:@"log_level"];
}

+ (float)color_adjust_brightness
{
    return [self floatForKey:@"color_adjust_brightness"];
}

+ (float)color_adjust_saturation
{
    return [self floatForKey:@"color_adjust_saturation"];
}

+ (float)color_adjust_contrast
{
    return [self floatForKey:@"color_adjust_contrast"];
}

+ (int)picture_fill_mode
{
    return [self intForKey:@"picture_fill_mode"];
}

+ (int)picture_wh_ratio
{
    return [self intForKey:@"picture_wh_ratio"];
}

+ (int)picture_ratate_mode
{
    return [self intForKey:@"picture_ratate_mode"];
}

+ (int)picture_flip_mode
{
    return [self intForKey:@"picture_flip_mode"];
}

+ (BOOL)copy_hw_frame
{
    return [self boolForKey:@"copy_hw_frame"];
}

+ (BOOL)use_hw
{
    return [self boolForKey:@"use_hw"];
}

+ (void)setUse_hw:(BOOL)use_hw
{
    [self setValue:@(use_hw) forKey:@"use_hw"];
}

+ (BOOL)open_hdr
{
    return [self boolForKey:@"open_hdr"];
}

+ (NSString *)FontName
{
    return [self stringForKey:@"FontName"];
}

+ (void)setFontName:(NSString *)font_name
{
    [self setValue:font_name forKey:@"FontName"];
}

+ (float)subtitle_scale
{
    return [self floatForKey:@"subtitle_scale"];
}

+ (int)subtitle_bottom_margin
{
    return [self intForKey:@"subtitle_bottom_margin"];
}

+ (float)Outline
{
    return [self floatForKey:@"Outline"];
}

+ (NSColor *)PrimaryColour
{
    NSData *data = [self anyForKey:@"PrimaryColour"];
    return MRUnarchiveColor(data);
}

+ (NSColor *)SecondaryColour
{
    NSData *data = [self anyForKey:@"SecondaryColour"];
    return MRUnarchiveColor(data);
}

+ (NSColor *)BackColour
{
    NSData *data = [self anyForKey:@"BackColour"];
    return MRUnarchiveColor(data);
}

+ (NSColor *)OutlineColour
{
    NSData *data = [self anyForKey:@"OutlineColour"];
    return MRUnarchiveColor(data);
}

+ (int)force_override
{
    return [self intForKey:@"force_override"];
}

+ (NSString *)custom_style
{
    return [self stringForKey:@"custom_style"];
}

+ (float)subtitle_delay
{
    return [self floatForKey:@"subtitle_delay"];
}

+ (float)audio_delay
{
    return [self floatForKey:@"audio_delay"];
}

+ (float)volume
{
    return [self floatForKey:@"volume"];
}

+ (void)setVolume:(float)aVolume
{
    [self setValue:@(aVolume) forKey:@"volume"];
}

+ (float)playback_speed
{
    return [self floatForKey:@"playback_speed"];
}

+ (void)setPlayback_speed:(float)speed
{
    [self setValue:@(speed) forKey:@"playback_speed"];
}

+ (NSString *)overlay_format
{
    return [self stringForKey:@"overlay_format"];
}

+ (int)snapshot_type
{
    return [self intForKey:@"snapshot_type"];
}

+ (BOOL)accurate_seek
{
    return [self boolForKey:@"accurate_seek"];
}

+ (int)seek_step
{
    return [self intForKey:@"seek_step"];
}

+ (int)lock_screen_ratio
{
    return [self intForKey:@"lock_screen_ratio"];
}

+ (int)play_from_history
{
    return [self intForKey:@"play_from_history"];
}

+ (int)open_gzip
{
    return [self intForKey:@"open_gzip"];
}

+ (int)use_dns_cache
{
    return [self intForKey:@"use_dns_cache"];
}

+ (int)dns_cache_period
{
    return [self intForKey:@"dns_cache_period"];
}

+ (void)setSnapshotDirectoryURL:(NSURL *)url
{
    NSError *error = nil;
    NSData *bookmarkData = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                          includingResourceValuesForKeys:nil
                                         relativeToURL:nil
                                                 error:&error];
    if (bookmarkData) {
        [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:@"snapshot_directory_bookmark"];
        [[NSUserDefaults standardUserDefaults] setObject:url.path forKey:@"snapshot_directory_path"];
    } else {
        NSLog(@"Failed to create bookmark: %@", error);
    }
}

+ (NSURL *)snapshotDirectoryURL
{
    NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:@"snapshot_directory_bookmark"];
    if (bookmarkData) {
        BOOL isStale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmarkData
                                               options:NSURLBookmarkResolutionWithSecurityScope
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&isStale
                                                 error:&error];
        if (url) {
            [url startAccessingSecurityScopedResource];
            return url;
        }
    }
    
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:@"snapshot_directory_path"];
    if (path) {
        return [NSURL fileURLWithPath:path];
    }
    
    // Default to user's Pictures/AuraPlayer directory
    NSString *defaultDir = [NSFileManager mr_DirWithType:NSPicturesDirectory WithPathComponents:@[@"AuraPlayer"]];
    if (defaultDir) {
        return [NSURL fileURLWithPath:defaultDir];
    }
    
    NSString *picturesDir = [NSSearchPathForDirectoriesInDomains(NSPicturesDirectory, NSUserDomainMask, YES) firstObject];
    if (picturesDir) {
        NSString *auraPlayerDir = [picturesDir stringByAppendingPathComponent:@"AuraPlayer"];
        [[NSFileManager defaultManager] createDirectoryAtPath:auraPlayerDir withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:auraPlayerDir];
    }
    
    return nil;
}

+ (void)setRecordDirectoryURL:(NSURL *)url
{
    NSError *error = nil;
    NSData *bookmarkData = [url bookmarkDataWithOptions:NSURLBookmarkCreationWithSecurityScope
                          includingResourceValuesForKeys:nil
                                         relativeToURL:nil
                                                 error:&error];
    if (bookmarkData) {
        [[NSUserDefaults standardUserDefaults] setObject:bookmarkData forKey:@"record_directory_bookmark"];
        [[NSUserDefaults standardUserDefaults] setObject:url.path forKey:@"record_directory_path"];
    } else {
        NSLog(@"Failed to create record bookmark: %@", error);
    }
}

+ (NSURL *)recordDirectoryURL
{
    NSData *bookmarkData = [[NSUserDefaults standardUserDefaults] objectForKey:@"record_directory_bookmark"];
    if (bookmarkData) {
        BOOL isStale = NO;
        NSError *error = nil;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmarkData
                                               options:NSURLBookmarkResolutionWithSecurityScope
                                         relativeToURL:nil
                                   bookmarkDataIsStale:&isStale
                                                 error:&error];
        if (url) {
            [url startAccessingSecurityScopedResource];
            return url;
        }
    }
    
    NSString *path = [[NSUserDefaults standardUserDefaults] stringForKey:@"record_directory_path"];
    if (path) {
        return [NSURL fileURLWithPath:path];
    }
    
    // Default to user's Movies/AuraPlay directory
    NSString *defaultDir = [NSFileManager mr_DirWithType:NSMoviesDirectory WithPathComponents:@[@"AuraPlay"]];
    if (defaultDir) {
        return [NSURL fileURLWithPath:defaultDir];
    }
    
    NSString *moviesDir = [NSSearchPathForDirectoriesInDomains(NSMoviesDirectory, NSUserDomainMask, YES) firstObject];
    if (moviesDir) {
        NSString *auraPlayDir = [moviesDir stringByAppendingPathComponent:@"AuraPlay"];
        [[NSFileManager defaultManager] createDirectoryAtPath:auraPlayDir withIntermediateDirectories:YES attributes:nil error:nil];
        return [NSURL fileURLWithPath:auraPlayDir];
    }
    
    return nil;
}

+ (NSArray<NSString *> *)recordSupportedFormats
{
    return @[@"mp4", @"mov", @"mkv", @"ts", @"auto"];
}

+ (int)record_format
{
    return [self intForKey:@"record_format"];
}

+ (NSString *)record_format_string
{
    id val = [self anyForKey:@"record_format"];
    NSArray<NSString *> *formats = [self recordSupportedFormats];
    if ([val isKindOfClass:[NSString class]] && [(NSString *)val length] > 0) {
        if ([formats containsObject:val]) {
            return (NSString *)val;
        }
    }
    if ([val respondsToSelector:@selector(intValue)]) {
        int idx = [val intValue];
        if (idx >= 0 && idx < formats.count) {
            return formats[idx];
        }
    }
    return formats.firstObject ?: @"mp4";
}

+ (int)record_method
{
    return [self intForKey:@"record_method"];
}

+ (BOOL)record_method_is_exact
{
    return [self record_method] == 1;
}

+ (void)clearAllPlaybackHistory
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSDictionary *dict = [defaults dictionaryRepresentation];
    for (NSString *key in dict.allKeys) {
        if (key.length == 32) {
            NSCharacterSet *hexSet = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"];
            BOOL isHex = YES;
            for (NSUInteger i = 0; i < key.length; i++) {
                if (![hexSet characterIsMember:[key characterAtIndex:i]]) {
                    isHex = NO;
                    break;
                }
            }
            if (isHex) {
                [defaults removeObjectForKey:key];
            }
        }
    }
    [defaults synchronize];
}

+ (int)deinterlace
{
    return [[self anyForKey:@"deinterlace"] intValue];
}

+ (void)setDeinterlace:(int)deinterlace
{
    [self setValue:@(deinterlace) forKey:@"deinterlace"];
}

+ (NSArray *)savedPlaylist
{
    NSArray *list = [[NSUserDefaults standardUserDefaults] arrayForKey:@"saved_playlist"];
    return list ?: @[];
}

+ (void)setSavedPlaylist:(NSArray *)playlist
{
    if (playlist) {
        [[NSUserDefaults standardUserDefaults] setObject:playlist forKey:@"saved_playlist"];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"saved_playlist"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

+ (NSString *)savedPlayingURL
{
    return [[NSUserDefaults standardUserDefaults] stringForKey:@"saved_playing_url"];
}

+ (void)setSavedPlayingURL:(NSString *)url
{
    if (url) {
        [[NSUserDefaults standardUserDefaults] setObject:url forKey:@"saved_playing_url"];
    } else {
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"saved_playing_url"];
    }
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end
