//
//  NSString+Ex.h
//  IJKMediaMacDemo
//
//  Created by Reach Matt on 2023/6/15.
//  Copyright © 2023 IJK Mac. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (Ex)

- (NSString *)md5Hash;
- (NSString *)percentEncoding;
- (NSString *)percentDecoding;

@end

NS_ASSUME_NONNULL_END
