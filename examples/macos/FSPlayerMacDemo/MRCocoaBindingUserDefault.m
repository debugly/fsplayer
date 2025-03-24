//
//  MRCocoaBindingUserDefault.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2024/1/25.
//  Copyright © 2024 IJK Mac. All rights reserved.
//
//https://itecnote.com/tecnote/ios-nsuserdefaultsdidchangenotification-whats-the-name-of-the-key-that-changed/

//https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/CocoaBindings/Concepts/NSUserDefaultsController.html

#import "MRCocoaBindingUserDefault.h"
#import <AppKit/NSUserDefaultsController.h>
#import <AppKit/NSColor.h>
#import <IJKMediaPlayerKit/ff_subtitle_def.h>
#import <IJKMediaPlayerKit/IJKMediaPlayback.h>

@interface MRCocoaBindingUserDefault()

@property (nonatomic, strong) NSMutableDictionary *observers;

@end

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
    IJKSDLSubtitlePreference sp = ijk_subtitle_default_preference();
    
    NSColor *text_color = ijk_ass_int_to_color(sp.PrimaryColour);
    NSData *text_color_data = [NSKeyedArchiver archivedDataWithRootObject:text_color];
    
    NSColor *SecondaryColour = ijk_ass_int_to_color(sp.SecondaryColour);
    NSData *subtitle_bg_color_data = [NSKeyedArchiver archivedDataWithRootObject:SecondaryColour];
    
    NSColor *OutlineColour = ijk_ass_int_to_color(sp.OutlineColour);
    NSData *subtitle_stroke_color_data = [NSKeyedArchiver archivedDataWithRootObject:OutlineColour];
    
    NSColor *BackColour = ijk_ass_int_to_color(sp.BackColour);
    NSData *subtitle_shadow_color_data = [NSKeyedArchiver archivedDataWithRootObject:BackColour];
    
    NSDictionary *initValues = @{
        @"volume" : @(0.4),
        
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
        @"de_interlace" : @(0),
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
        @"accurate_seek" : @(1),
        @"seek_step" : @(15),
        @"lock_screen_ratio" : @(1),
        @"play_from_history" : @(1),
        
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
    for (int i = 0; i< array.count; i++) {
        void(^block)(id,BOOL*) = array[i];
        BOOL remove = NO;
        if ([value isKindOfClass:[NSData class]]) {
            value = [NSKeyedUnarchiver unarchiveObjectWithData:value];
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
        while (obj = [enumerator nextObject]) {
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

+ (NSString *)FontName
{
    return [self stringForKey:@"FontName"];
}

+ (void)setFontName:(NSString *)font_name
{
    return [self setValue:font_name forKey:@"FontName"];
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
    if (data) {
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    }
    return nil;
}

+ (NSColor *)SecondaryColour
{
    NSData *data = [self anyForKey:@"SecondaryColour"];
    if (data) {
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    }
    return nil;
}

+ (NSColor *)BackColour
{
    NSData *data = [self anyForKey:@"BackColour"];
    if (data) {
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    }
    return nil;
}

+ (NSColor *)OutlineColour
{
    NSData *data = [self anyForKey:@"OutlineColour"];
    if (data) {
        return [NSKeyedUnarchiver unarchiveObjectWithData:data];
    }
    return nil;
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

+ (NSString *)overlay_format
{
    return [self stringForKey:@"overlay_format"];
}

+ (BOOL)use_opengl
{
    return [self boolForKey:@"use_opengl"];
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

@end
