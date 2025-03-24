//
//  NSString+Ex.m
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/6/15.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import "NSString+Ex.h"
#import <CommonCrypto/CommonDigest.h>

@implementation NSString (Ex)

- (NSString *)md5Hash
{
    const char *cStr = [self UTF8String];
    unsigned char result[16];
    CC_MD5( cStr, (unsigned int)strlen(cStr), result ); // md5 call
    return [NSString stringWithFormat:
            @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
            result[0], result[1], result[2], result[3],
            result[4], result[5], result[6], result[7],
            result[8], result[9], result[10], result[11],
            result[12], result[13], result[14], result[15]
            ];
}

- (NSString *)percentEncoding
{
    NSString *encodedString = nil;
    NSString *needPercentCharacters = @"?!@#$^&%*+,:;='\"`<>()[]{}/\\| ";
    NSCharacterSet *notAllowedCharacters = [NSCharacterSet characterSetWithCharactersInString:needPercentCharacters];
    NSCharacterSet *allowedCharacters = [notAllowedCharacters invertedSet];
    
    encodedString = [self stringByAddingPercentEncodingWithAllowedCharacters:allowedCharacters];
    if(!encodedString)
        encodedString = @"";
    return encodedString;
}

- (NSString *)percentDecoding
{
    NSString *encodedString = [self stringByRemovingPercentEncoding];
    if(!encodedString)
        encodedString = @"";
    return encodedString;
}

@end
