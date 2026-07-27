//
//  NSString+Ex.h
//  AuraPlayer
//
//  Created by debugly on 2023/6/15.
//  Copyright © 2023 debugly. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (Ex)

- (NSString *)md5Hash;
- (NSString *)percentEncoding;
- (NSString *)percentDecoding;

@end

NS_ASSUME_NONNULL_END
