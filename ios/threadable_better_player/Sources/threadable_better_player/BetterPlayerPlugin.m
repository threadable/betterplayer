// Copyright 2017 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "BetterPlayerPlugin.h"
#import <threadable_better_player_swift/threadable_better_player_swift-Swift.h>

#if !__has_feature(objc_arc)
#error Code Requires ARC.
#endif


@implementation BetterPlayerPlugin
NSMutableDictionary* _dataSourceDict;
NSMutableDictionary*  _timeObserverIdDict;
NSMutableDictionary*  _artworkImageDict;
CacheManager* _cacheManager;
int texturesCount = -1;
BetterPlayer* _notificationPlayer;
bool _remoteCommandsInitialized = false;


#pragma mark - FlutterPlugin protocol
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    FlutterMethodChannel* channel =
    [FlutterMethodChannel methodChannelWithName:@"better_player_channel"
                                binaryMessenger:[registrar messenger]];
    BetterPlayerPlugin* instance = [[BetterPlayerPlugin alloc] initWithRegistrar:registrar];
    [registrar addMethodCallDelegate:instance channel:channel];
    //[registrar publish:instance];
    [registrar registerViewFactory:instance withId:@"io.threadable/betterplayer"];
}

- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    self = [super init];
    NSAssert(self, @"super init cannot be nil");
    _messenger = [registrar messenger];
    _registrar = registrar;
    _players = [NSMutableDictionary dictionaryWithCapacity:1];
    _timeObserverIdDict = [NSMutableDictionary dictionary];
    _artworkImageDict = [NSMutableDictionary dictionary];
    _dataSourceDict = [NSMutableDictionary dictionary];
    _cacheManager = [[CacheManager alloc] init];
    [_cacheManager setup];
    return self;
}

- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar>*)registrar {
    for (NSNumber* textureId in _players.allKeys) {
        BetterPlayer* player = _players[textureId];
        [player disposeSansEventChannel];
    }
    [_players removeAllObjects];
}

#pragma mark - FlutterPlatformViewFactory protocol
- (NSObject<FlutterPlatformView>*)createWithFrame:(CGRect)frame
                                   viewIdentifier:(int64_t)viewId
                                        arguments:(id _Nullable)args {
    NSNumber* textureId = [args objectForKey:@"textureId"];
    BetterPlayerView* player = [_players objectForKey:@(textureId.intValue)];
    return player;
}

- (NSObject<FlutterMessageCodec>*)createArgsCodec {
    return [FlutterStandardMessageCodec sharedInstance];
}

#pragma mark - BetterPlayerPlugin class
- (int)newTextureId {
    texturesCount += 1;
    return texturesCount;
}
- (void)onPlayerSetup:(BetterPlayer*)player
               result:(FlutterResult)result {
    int64_t textureId = [self newTextureId];
    FlutterEventChannel* eventChannel = [FlutterEventChannel
                                         eventChannelWithName:[NSString stringWithFormat:@"better_player_channel/videoEvents%lld",
                                                               textureId]
                                         binaryMessenger:_messenger];
    [player setMixWithOthers:false];
    [eventChannel setStreamHandler:player];
    player.eventChannel = eventChannel;
    _players[@(textureId)] = player;
    result(@{@"textureId" : @(textureId)});
}

- (void) setupRemoteNotification :(BetterPlayer*) player{
    _notificationPlayer = player;
    [self stopOtherUpdateListener:player];
    NSDictionary* dataSource = [_dataSourceDict objectForKey:[self getTextureId:player]];
    BOOL showNotification = false;
    id showNotificationObject = [dataSource objectForKey:@"showNotification"];
    if (showNotificationObject != nil && showNotificationObject != [NSNull null]) {
        showNotification = [showNotificationObject boolValue];
    }
    NSString* title = [self safeString:dataSource[@"title"] fallback:@""];
    NSString* author = [self safeString:dataSource[@"author"] fallback:@""];
    NSString* imageUrl = [self safeString:dataSource[@"imageUrl"] fallback:@""];

    if (showNotification){
        [self setRemoteCommandsNotificationActive];
        [self setupRemoteCommands: player];
        [self setupRemoteCommandNotification: player, title, author, imageUrl];
        [self setupUpdateListener: player, title, author, imageUrl];
    }
}

- (void) setRemoteCommandsNotificationActive{
    [[AVAudioSession sharedInstance] setActive:true error:nil];
    [[UIApplication sharedApplication] beginReceivingRemoteControlEvents];
}

- (void) setRemoteCommandsNotificationNotActive{
    if ([_players count] == 0) {
        [[AVAudioSession sharedInstance] setActive:false error:nil];
    }

    [[UIApplication sharedApplication] endReceivingRemoteControlEvents];
}

- (NSString*)safeString:(id)value fallback:(NSString*)fallback {
    if (value == nil || value == [NSNull null]) {
        return fallback;
    }
    if ([value isKindOfClass:[NSString class]]) {
        return value;
    }
    return [value description] ?: fallback;
}

- (BOOL)canSendRemoteCommandEvent {
    if (_notificationPlayer == nil || _notificationPlayer == NULL || _notificationPlayer == (id)[NSNull null]) {
        return NO;
    }
    if (_notificationPlayer.disposed) {
        return NO;
    }
    if (_notificationPlayer.eventSink == nil) {
        return NO;
    }
    return YES;
}

- (MPRemoteCommandHandlerStatus)sendRemoteCommandEvent:(NSString*)event {
    if (![self canSendRemoteCommandEvent]) {
        return MPRemoteCommandHandlerStatusNoSuchContent;
    }

    @try {
        _notificationPlayer.eventSink(@{@"event" : event});
        return MPRemoteCommandHandlerStatusSuccess;
    } @catch (NSException *exception) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }
}

- (MPRemoteCommandHandlerStatus)sendRemoteSeekEvent:(int64_t)millis {
    if (![self canSendRemoteCommandEvent]) {
        return MPRemoteCommandHandlerStatusNoSuchContent;
    }

    @try {
        [_notificationPlayer seekTo: millis];
        _notificationPlayer.eventSink(@{@"event" : @"seek", @"position": @(millis)});
        return MPRemoteCommandHandlerStatusSuccess;
    } @catch (NSException *exception) {
        return MPRemoteCommandHandlerStatusCommandFailed;
    }
}

- (void)setNowPlayingInfoSafely:(NSDictionary*)nowPlayingInfo {
    NSDictionary* immutableInfo = [nowPlayingInfo copy] ?: @{};
    dispatch_async(dispatch_get_main_queue(), ^{
        [MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo = immutableInfo;
    });
}

- (void)removeRemoteCommandTargets {
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.togglePlayPauseCommand removeTarget:nil];
    [commandCenter.playCommand removeTarget:nil];
    [commandCenter.pauseCommand removeTarget:nil];
    if (@available(iOS 9.1, *)) {
        [commandCenter.changePlaybackPositionCommand removeTarget:nil];
    }
    _remoteCommandsInitialized = false;
}

- (void) setupRemoteCommands:(BetterPlayer*)player  {
    if (_remoteCommandsInitialized){
        return;
    }
    MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
    [commandCenter.togglePlayPauseCommand setEnabled:YES];
    [commandCenter.playCommand setEnabled:YES];
    [commandCenter.pauseCommand setEnabled:YES];
    [commandCenter.nextTrackCommand setEnabled:NO];
    [commandCenter.previousTrackCommand setEnabled:NO];
    if (@available(iOS 9.1, *)) {
        [commandCenter.changePlaybackPositionCommand setEnabled:YES];
    }

    __weak typeof(self) weakSelf = self;
    [commandCenter.togglePlayPauseCommand addTargetWithHandler: ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil || ![strongSelf canSendRemoteCommandEvent]){
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        return [strongSelf sendRemoteCommandEvent:_notificationPlayer.isPlaying ? @"pause" : @"play"];
    }];

    [commandCenter.playCommand addTargetWithHandler: ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        return [strongSelf sendRemoteCommandEvent:@"play"];
    }];

    [commandCenter.pauseCommand addTargetWithHandler: ^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return MPRemoteCommandHandlerStatusNoSuchContent;
        }
        return [strongSelf sendRemoteCommandEvent:@"pause"];
    }];

    if (@available(iOS 9.1, *)) {
        [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf == nil || ![strongSelf canSendRemoteCommandEvent]){
                return MPRemoteCommandHandlerStatusNoSuchContent;
            }
            MPChangePlaybackPositionCommandEvent * playbackEvent = (MPChangePlaybackPositionCommandEvent *) event;
            CMTime time = CMTimeMake(playbackEvent.positionTime, 1);
            int64_t millis = [BetterPlayerTimeUtils FLTCMTimeToMillis:(time)];
            return [strongSelf sendRemoteSeekEvent:millis];
        }];
    }
    _remoteCommandsInitialized = true;
}

- (void) setupRemoteCommandNotification:(BetterPlayer*)player, NSString* title, NSString* author , NSString* imageUrl{
    if (player == nil || player.disposed) {
        return;
    }

    float positionInSeconds = MAX(0.0, player.position / 1000.0);
    float durationInSeconds = MAX(0.0, player.duration / 1000.0);
    NSString* safeTitle = [self safeString:title fallback:@""];
    NSString* safeAuthor = [self safeString:author fallback:@""];
    NSString* safeImageUrl = [self safeString:imageUrl fallback:@""];

    NSMutableDictionary * nowPlayingInfoDict = [@{MPMediaItemPropertyArtist: safeAuthor,
                                                  MPMediaItemPropertyTitle: safeTitle,
                                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: [NSNumber numberWithFloat:positionInSeconds],
                                                  MPMediaItemPropertyPlaybackDuration: [NSNumber numberWithFloat:durationInSeconds],
                                                  MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? @1 : @0,
    } mutableCopy];

    if (safeImageUrl.length == 0){
        [self setNowPlayingInfoSafely:nowPlayingInfoDict];
        return;
    }

    NSNumber* key =  [self getTextureId:player];
    if (key == nil){
        [self setNowPlayingInfoSafely:nowPlayingInfoDict];
        return;
    }

    MPMediaItemArtwork* artworkImage = [_artworkImageDict objectForKey:key];
    if (artworkImage){
        [nowPlayingInfoDict setObject:artworkImage forKey:MPMediaItemPropertyArtwork];
        [self setNowPlayingInfoSafely:nowPlayingInfoDict];
        return;
    }

    NSDictionary* baseNowPlayingInfo = [nowPlayingInfoDict copy];
    dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
    dispatch_async(queue, ^{
        @try{
            UIImage * tempArtworkImage = nil;
            if ([safeImageUrl rangeOfString:@"http"].location == NSNotFound){
                tempArtworkImage = [UIImage imageWithContentsOfFile:safeImageUrl];
            } else {
                NSURL *nsImageUrl =[NSURL URLWithString:safeImageUrl];
                if (nsImageUrl != nil) {
                    tempArtworkImage = [UIImage imageWithData:[NSData dataWithContentsOfURL:nsImageUrl]];
                }
            }

            NSMutableDictionary* infoWithArtwork = [baseNowPlayingInfo mutableCopy];
            if(tempArtworkImage)
            {
                MPMediaItemArtwork* artworkImage = [[MPMediaItemArtwork alloc] initWithImage: tempArtworkImage];
                if (artworkImage != nil) {
                    [_artworkImageDict setObject:artworkImage forKey:key];
                    [infoWithArtwork setObject:artworkImage forKey:MPMediaItemPropertyArtwork];
                }
            }
            [self setNowPlayingInfoSafely:infoWithArtwork];
        }
        @catch(NSException *exception) {
            [self setNowPlayingInfoSafely:baseNowPlayingInfo];
        }
    });
}

- (NSNumber*) getTextureId: (BetterPlayer*) player{
    NSArray* temp = [_players allKeysForObject: player];
    NSNumber* key = [temp lastObject];
    return key;
}

- (void) setupUpdateListener:(BetterPlayer*)player,NSString* title, NSString* author,NSString* imageUrl  {
    NSNumber* key =  [self getTextureId:player];
    if (key == nil) {
        return;
    }

    id _timeObserverId = [player.player addPeriodicTimeObserverForInterval:CMTimeMake(1, 1) queue:NULL usingBlock:^(CMTime time){
        [self setupRemoteCommandNotification:player, title, author, imageUrl];
    }];

    [ _timeObserverIdDict setObject:_timeObserverId forKey: key];
}

- (void) disposeNotificationData: (BetterPlayer*)player{
    if (player == _notificationPlayer){
        [self removeRemoteCommandTargets];
        _notificationPlayer = nil;
    }
    NSNumber* key =  [self getTextureId:player];
    if (key == nil) {
        [self setNowPlayingInfoSafely:@{}];
        return;
    }
    id _timeObserverId = _timeObserverIdDict[key];
    [_timeObserverIdDict removeObjectForKey: key];
    [_artworkImageDict removeObjectForKey:key];
    if (_timeObserverId){
        [player.player removeTimeObserver:_timeObserverId];
        _timeObserverId = nil;
    }
    [self setNowPlayingInfoSafely:@{}];
}

- (void) stopOtherUpdateListener: (BetterPlayer*) player{
    NSNumber* currentPlayerTextureId = [self getTextureId:player];
    for (NSNumber* textureId in [_timeObserverIdDict.allKeys copy]) {
        if ([currentPlayerTextureId isEqual:textureId]){
            continue;
        }

        id timeObserverId = [_timeObserverIdDict objectForKey:textureId];
        BetterPlayer* playerToRemoveListener = [_players objectForKey:textureId];
        if (playerToRemoveListener != nil && timeObserverId != nil) {
            [playerToRemoveListener.player removeTimeObserver: timeObserverId];
        }
        [_timeObserverIdDict removeObjectForKey:textureId];
    }

}


- (void)handleMethodCall:(FlutterMethodCall*)call result:(FlutterResult)result {


    if ([@"init" isEqualToString:call.method]) {
        // Allow audio playback when the Ring/Silent switch is set to silent
        for (NSNumber* textureId in _players) {
            BetterPlayer* player = _players[textureId];
            [self disposeNotificationData:player];
            [player dispose];
        }

        [_players removeAllObjects];
        result(nil);
    } else if ([@"create" isEqualToString:call.method]) {
        BetterPlayer* player = [[BetterPlayer alloc] initWithFrame:CGRectZero];
        [self onPlayerSetup:player result:result];
    } else {
        NSDictionary* argsMap = call.arguments;
        int64_t textureId = ((NSNumber*)argsMap[@"textureId"]).unsignedIntegerValue;
        BetterPlayer* player = _players[@(textureId)];
        if ([@"setDataSource" isEqualToString:call.method]) {
            [player clear];
            // This call will clear cached frame because we will return transparent frame

            NSDictionary* dataSource = argsMap[@"dataSource"];
            [_dataSourceDict setObject:dataSource forKey:[self getTextureId:player]];
            NSString* assetArg = dataSource[@"asset"];
            NSString* uriArg = dataSource[@"uri"];
            NSString* key = dataSource[@"key"];
            NSString* certificateUrl = dataSource[@"certificateUrl"];
            NSString* licenseUrl = dataSource[@"licenseUrl"];
            NSDictionary* headers = dataSource[@"headers"];
            NSString* cacheKey = dataSource[@"cacheKey"];
            NSNumber* maxCacheSize = dataSource[@"maxCacheSize"];
            NSString* videoExtension = dataSource[@"videoExtension"];
            
            int overriddenDuration = 0;
            if ([dataSource objectForKey:@"overriddenDuration"] != [NSNull null]){
                overriddenDuration = [dataSource[@"overriddenDuration"] intValue];
            }

            BOOL useCache = false;
            id useCacheObject = [dataSource objectForKey:@"useCache"];
            if (useCacheObject != [NSNull null]) {
                useCache = [[dataSource objectForKey:@"useCache"] boolValue];
                if (useCache){
                    [_cacheManager setMaxCacheSize:maxCacheSize];
                }
            }

            if (headers == [NSNull null] || headers == NULL){
                headers = @{};
            }

            if (assetArg) {
                NSString* assetPath;
                NSString* package = dataSource[@"package"];
                if (![package isEqual:[NSNull null]]) {
                    assetPath = [_registrar lookupKeyForAsset:assetArg fromPackage:package];
                } else {
                    assetPath = [_registrar lookupKeyForAsset:assetArg];
                }
                [player setDataSourceAsset:assetPath withKey:key withCertificateUrl:certificateUrl withLicenseUrl: licenseUrl cacheKey:cacheKey cacheManager:_cacheManager overriddenDuration:overriddenDuration];
            } else if (uriArg) {
                [player setDataSourceURL:[NSURL URLWithString:uriArg] withKey:key withCertificateUrl:certificateUrl withLicenseUrl: licenseUrl withHeaders:headers withCache: useCache cacheKey:cacheKey cacheManager:_cacheManager overriddenDuration:overriddenDuration videoExtension: videoExtension];
            } else {
                result(FlutterMethodNotImplemented);
            }
            result(nil);
        } else if ([@"dispose" isEqualToString:call.method]) {
            [player clear];
            [self disposeNotificationData:player];
            [self setRemoteCommandsNotificationNotActive];
            [_players removeObjectForKey:@(textureId)];
            // If the Flutter contains https://github.com/flutter/engine/pull/12695,
            // the `player` is disposed via `onTextureUnregistered` at the right time.
            // Without https://github.com/flutter/engine/pull/12695, there is no guarantee that the
            // texture has completed the un-reregistration. It may leads a crash if we dispose the
            // `player` before the texture is unregistered. We add a dispatch_after hack to make sure the
            // texture is unregistered before we dispose the `player`.
            //
            // TODO(cyanglaz): Remove this dispatch block when
            // https://github.com/flutter/flutter/commit/8159a9906095efc9af8b223f5e232cb63542ad0b is in
            // stable And update the min flutter version of the plugin to the stable version.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (!player.disposed) {
                    [player dispose];
                }
            });
            if ([_players count] == 0) {
                [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:nil];
            }
            result(nil);
        } else if ([@"setLooping" isEqualToString:call.method]) {
            [player setIsLooping:[argsMap[@"looping"] boolValue]];
            result(nil);
        } else if ([@"setVolume" isEqualToString:call.method]) {
            [player setVolume:[argsMap[@"volume"] doubleValue]];
            result(nil);
        } else if ([@"play" isEqualToString:call.method]) {
            [self setupRemoteNotification:player];
            [player play];
            result(nil);
        } else if ([@"position" isEqualToString:call.method]) {
            result(@([player position]));
        } else if ([@"absolutePosition" isEqualToString:call.method]) {
            result(@([player absolutePosition]));
        } else if ([@"seekTo" isEqualToString:call.method]) {
            [player seekTo:[argsMap[@"location"] intValue]];
            result(nil);
        } else if ([@"pause" isEqualToString:call.method]) {
            [player pause];
            result(nil);
        } else if ([@"setSpeed" isEqualToString:call.method]) {
            [player setSpeed:[[argsMap objectForKey:@"speed"] doubleValue] result:result];
        }else if ([@"setTrackParameters" isEqualToString:call.method]) {
            int width = [argsMap[@"width"] intValue];
            int height = [argsMap[@"height"] intValue];
            int bitrate = [argsMap[@"bitrate"] intValue];

            [player setTrackParameters:width: height : bitrate];
            result(nil);
        } else if ([@"enablePictureInPicture" isEqualToString:call.method]){
            double left = [argsMap[@"left"] doubleValue];
            double top = [argsMap[@"top"] doubleValue];
            double width = [argsMap[@"width"] doubleValue];
            double height = [argsMap[@"height"] doubleValue];
            [player enablePictureInPicture:CGRectMake(left, top, width, height)];
        } else if ([@"isPictureInPictureSupported" isEqualToString:call.method]){
            if (@available(iOS 9.0, *)){
                if ([AVPictureInPictureController isPictureInPictureSupported]){
                    result([NSNumber numberWithBool:true]);
                    return;
                }
            }

            result([NSNumber numberWithBool:false]);
        } else if ([@"disablePictureInPicture" isEqualToString:call.method]){
            [player disablePictureInPicture];
            [player setPictureInPicture:false];
        } else if ([@"setAudioTrack" isEqualToString:call.method]){
            NSString* name = argsMap[@"name"];
            int index = [argsMap[@"index"] intValue];
            [player setAudioTrack:name index: index];
        } else if ([@"setMixWithOthers" isEqualToString:call.method]){
            [player setMixWithOthers:[argsMap[@"mixWithOthers"] boolValue]];
        } else if ([@"preCache" isEqualToString:call.method]){
            NSDictionary* dataSource = argsMap[@"dataSource"];
            NSString* urlArg = dataSource[@"uri"];
            NSString* cacheKey = dataSource[@"cacheKey"];
            NSDictionary* headers = dataSource[@"headers"];
            NSNumber* maxCacheSize = dataSource[@"maxCacheSize"];
            NSString* videoExtension = dataSource[@"videoExtension"];
            
            if (headers == [ NSNull null ]){
                headers = @{};
            }
            if (videoExtension == [NSNull null]){
                videoExtension = nil;
            }
            
            if (urlArg != [NSNull null]){
                NSURL* url = [NSURL URLWithString:urlArg];
                if ([_cacheManager isPreCacheSupportedWithUrl:url videoExtension:videoExtension]){
                    [_cacheManager setMaxCacheSize:maxCacheSize];
                    [_cacheManager preCacheURL:url cacheKey:cacheKey videoExtension:videoExtension withHeaders:headers completionHandler:^(BOOL success){
                    }];
                } else {
                    NSLog(@"Pre cache is not supported for given data source.");
                }
            }
            result(nil);
        } else if ([@"clearCache" isEqualToString:call.method]){
            [_cacheManager clearCache];
            result(nil);
        } else if ([@"stopPreCache" isEqualToString:call.method]){
            NSString* urlArg = argsMap[@"url"];
            NSString* cacheKey = argsMap[@"cacheKey"];
            NSString* videoExtension = argsMap[@"videoExtension"];
            if (urlArg != [NSNull null]){
                NSURL* url = [NSURL URLWithString:urlArg];
                if ([_cacheManager isPreCacheSupportedWithUrl:url videoExtension:videoExtension]){
                    [_cacheManager stopPreCache:url cacheKey:cacheKey
                              completionHandler:^(BOOL success){
                    }];
                } else {
                    NSLog(@"Stop pre cache is not supported for given data source.");
                }
            }
            result(nil);
        } else {
            result(FlutterMethodNotImplemented);
        }
    }
}
@end
