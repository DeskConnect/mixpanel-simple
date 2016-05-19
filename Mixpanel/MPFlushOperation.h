//
//  MPFlushOperation.h
//  mixpanel-simple
//
//  Created by Conrad Kramer on 11/19/14.
//  Copyright (c) 2014 DeskConnect. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MPFlushOperation : NSOperation

@property (nonatomic, readonly, strong) NSURL *cacheURL;

- (instancetype)initWithCacheURL:(NSURL *)cacheURL NS_DESIGNATED_INITIALIZER;

@end
