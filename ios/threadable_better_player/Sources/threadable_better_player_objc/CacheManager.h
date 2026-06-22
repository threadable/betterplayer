// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface CacheManager : NSObject

- (void)setup;
- (void)setMaxCacheSize:(NSNumber *_Nullable)maxCacheSize;
- (void)preCacheURL:(NSURL *)url
           cacheKey:(NSString *_Nullable)cacheKey
     videoExtension:(NSString *_Nullable)videoExtension
        withHeaders:(NSDictionary<NSObject *, id> *)headers
  completionHandler:(void (^_Nullable)(BOOL success))completionHandler;
- (void)stopPreCache:(NSURL *)url
            cacheKey:(NSString *_Nullable)cacheKey
   completionHandler:(void (^_Nullable)(BOOL success))completionHandler;
- (AVPlayerItem *_Nullable)getCachingPlayerItemForNormalPlayback:(NSURL *)url
                                                        cacheKey:(NSString *_Nullable)cacheKey
                                                  videoExtension:(NSString *_Nullable)videoExtension
                                                         headers:(NSDictionary<NSObject *, id> *)headers;
- (void)clearCache;
- (BOOL)isPreCacheSupportedWithUrl:(NSURL *)url videoExtension:(NSString *_Nullable)videoExtension;

@end

NS_ASSUME_NONNULL_END
