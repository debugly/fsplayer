//
//  MRM3UParser.m
//  AuraPlayer
//
//  Created by Reasonix on 2025.
//  Copyright © 2025 FSPlayer Mac. All rights reserved.
//

#import "MRM3UParser.h"

#pragma mark - M3U Attribute Parser Helpers

/// Parse key="value" attributes from an #EXTINF line.
/// Handles quoted and unquoted values.
static NSDictionary<NSString *, NSString *> *MRParseAttributes(NSString *attrString)
{
    NSMutableDictionary *attrs = [NSMutableDictionary dictionary];
    if (attrString.length == 0) return attrs;
    
    NSScanner *scanner = [NSScanner scannerWithString:attrString];
    scanner.charactersToBeSkipped = nil;
    
    while (!scanner.isAtEnd) {
        // Scan key
        [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
        NSString *key = nil;
        if (![scanner scanUpToString:@"=" intoString:&key]) break;
        if (key.length == 0) break;
        
        // Skip '='
        if (![scanner scanString:@"=" intoString:NULL]) break;
        
        // Scan value (quoted or unquoted)
        NSString *value = @"";
        [scanner scanCharactersFromSet:[NSCharacterSet whitespaceCharacterSet] intoString:NULL];
        
        if ([scanner scanString:@"\"" intoString:NULL]) {
            [scanner scanUpToString:@"\"" intoString:&value];
            [scanner scanString:@"\"" intoString:NULL];
        } else {
            // Unquoted — scan until whitespace or end
            NSCharacterSet *stopSet = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSMutableString *val = [NSMutableString string];
            while (!scanner.isAtEnd) {
                unichar ch = [attrString characterAtIndex:scanner.scanLocation];
                if ([stopSet characterIsMember:ch]) break;
                [val appendFormat:@"%C", ch];
                scanner.scanLocation += 1;
            }
            value = val;
        }
        
        if (key && value) {
            attrs[key] = value;
        }
    }
    return attrs;
}

/// Resolve a potentially-relative URL against a base URL.
static NSString *MRResolveURL(NSString *urlStr, NSString *baseURLString)
{
    if (!baseURLString) return urlStr;
    
    // Already absolute
    if ([urlStr hasPrefix:@"http://"] || [urlStr hasPrefix:@"https://"] ||
        [urlStr hasPrefix:@"rtmp://"] || [urlStr hasPrefix:@"rtsp://"] ||
        [urlStr hasPrefix:@"file://"] || [urlStr hasPrefix:@"/"]) {
        return urlStr;
    }
    
    // Relative — resolve against base
    NSURL *baseURL = [NSURL URLWithString:baseURLString];
    if (!baseURL) return urlStr;
    
    NSURL *resolved = [NSURL URLWithString:urlStr relativeToURL:baseURL];
    return [resolved absoluteString] ?: urlStr;
}

/// Extract a display title from an #EXTINF line and attributes.
static NSString *MRParseTitle(NSString *extinfLine)
{
    // #EXTINF:-1 tvg-name="Name" group-title="Group",DisplayName
    // or #EXTINF:-1,DisplayName
    // or #EXTINF:0,DisplayName
    
    // Find the last comma — the display name follows it
    NSRange lastComma = [extinfLine rangeOfString:@"," options:NSBackwardsSearch];
    if (lastComma.location != NSNotFound) {
        NSString *title = [[extinfLine substringFromIndex:lastComma.location + 1]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (title.length > 0) return title;
    }
    
    return @"Unknown";
}

#pragma mark - MRM3UParser

@implementation MRM3UParser

+ (BOOL)isM3UURL:(NSString *)urlString
{
    NSString *lower = [urlString lowercaseString];
    // Handle URLs with query params
    NSURL *url = [NSURL URLWithString:urlString];
    NSString *pathExt = [[url path] pathExtension];
    if (pathExt.length > 0) {
        return [pathExt isEqualToString:@"m3u"] || [pathExt isEqualToString:@"m3u8"];
    }
    return [lower hasSuffix:@".m3u"] || [lower hasSuffix:@".m3u8"];
}

+ (NSArray<NSDictionary *> *)parseM3UContent:(NSString *)content
{
    if (content.length == 0) return @[];
    
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSArray<NSString *> *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    NSString *currentTitle = nil;
    NSString *currentLogo = nil;
    NSString *currentGroup = nil;
    
    for (NSString *rawLine in lines) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        
        // Skip empty lines
        if (line.length == 0) continue;
        
        // Skip comments (but not #EXT... directives)
        if ([line hasPrefix:@"#"]) {
            if ([line hasPrefix:@"#EXTINF:"]) {
                // Parse #EXTINF line
                NSString *afterPrefix = [line substringFromIndex:8]; // "#EXTINF:"
                
                // Parse attributes (everything before the last comma, which is the display name)
                NSRange lastComma = [afterPrefix rangeOfString:@"," options:NSBackwardsSearch];
                NSString *attrPart = @"";
                if (lastComma.location != NSNotFound) {
                    attrPart = [afterPrefix substringToIndex:lastComma.location];
                } else {
                    attrPart = afterPrefix;
                }
                
                // Extract -1, 0, or duration from before attributes
                // Format: -1 tvg-name="N" ... or just -1,
                NSRange firstSpace = [attrPart rangeOfString:@" "];
                NSString *attrString = @"";
                if (firstSpace.location != NSNotFound) {
                    attrString = [attrPart substringFromIndex:firstSpace.location + 1];
                }
                
                NSDictionary *attrs = MRParseAttributes(attrString);
                
                // Priority: tvg-name > display name after comma
                NSString *tvgName = attrs[@"tvg-name"];
                NSString *displayTitle = MRParseTitle(line);
                
                currentTitle = (tvgName.length > 0) ? tvgName : displayTitle;
                currentLogo = attrs[@"tvg-logo"];
                currentGroup = attrs[@"group-title"];
            }
            // Other # lines are comments — skip
            continue;
        }
        
        // URL line (non-comment, non-empty)
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"url"] = line;
        item[@"title"] = currentTitle ?: [line lastPathComponent] ?: line;
        if (currentLogo) item[@"logo"] = currentLogo;
        if (currentGroup) item[@"group"] = currentGroup;
        [items addObject:item];
        
        // Reset for next entry
        currentTitle = nil;
        currentLogo = nil;
        currentGroup = nil;
    }
    
    return items;
}

+ (void)parseM3UURL:(NSString *)urlString
         completion:(void (^)(NSArray<NSDictionary *> * _Nullable items, NSError * _Nullable error))completion
{
    if (!completion) return;
    
    // Determine if it's a local file or remote URL
    BOOL isLocalFile = [urlString hasPrefix:@"/"] || [urlString hasPrefix:@"file://"];
    
    if (isLocalFile) {
        // --- Local file ---
        NSString *filePath = urlString;
        if ([filePath hasPrefix:@"file://"]) {
            filePath = [[NSURL URLWithString:filePath] path];
        }
        
        NSError *readError = nil;
        NSString *content = [NSString stringWithContentsOfFile:filePath
                                                      encoding:NSUTF8StringEncoding
                                                         error:&readError];
        if (!content) {
            // Try other encodings
            content = [NSString stringWithContentsOfFile:filePath
                                                encoding:NSISOLatin1StringEncoding
                                                   error:&readError];
        }
        
        if (!content) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion(nil, readError);
            });
            return;
        }
        
        NSArray<NSDictionary *> *items = [self parseRelativeURLsInItems:[self parseM3UContent:content]
                                                             baseURL:urlString];
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(items, nil);
        });
    } else {
        // --- Remote URL ---
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            dispatch_async(dispatch_get_main_queue(), ^{
                NSError *err = [NSError errorWithDomain:@"MRM3UParser"
                                                   code:-1
                                               userInfo:@{NSLocalizedDescriptionKey: @"Invalid URL"}];
                completion(nil, err);
            });
            return;
        }
        
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        config.timeoutIntervalForRequest = 30;
        config.timeoutIntervalForResource = 60;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:config];
        
        NSURLSessionDataTask *task = [session dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        completion(nil, error);
                    });
                    return;
                }
                
                // Try UTF-8 first, then Latin-1
                NSString *content = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (!content) {
                    content = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
                }
                
                if (!content) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        NSError *err = [NSError errorWithDomain:@"MRM3UParser"
                                                           code:-2
                                                       userInfo:@{NSLocalizedDescriptionKey: @"Unable to decode playlist content"}];
                        completion(nil, err);
                    });
                    return;
                }
                
                NSArray<NSDictionary *> *items = [self parseRelativeURLsInItems:[self parseM3UContent:content]
                                                                       baseURL:urlString];
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion(items, nil);
                });
            }];
        [task resume];
    }
}

/// Resolve relative URLs in parsed items against the playlist's base URL.
+ (NSArray<NSDictionary *> *)parseRelativeURLsInItems:(NSArray<NSDictionary *> *)items
                                              baseURL:(NSString *)baseURL
{
    NSMutableArray *resolved = [NSMutableArray arrayWithCapacity:items.count];
    for (NSDictionary *item in items) {
        NSMutableDictionary *mut = [item mutableCopy];
        NSString *urlStr = item[@"url"];
        mut[@"url"] = MRResolveURL(urlStr, baseURL);
        [resolved addObject:[mut copy]];
    }
    return resolved;
}

@end
