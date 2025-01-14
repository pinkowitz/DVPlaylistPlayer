//
//  DVPlaylistPlayer.m
//  Playlist Player SDK
//
//  Created by Mikhail Grushin on 07.06.13.
//  Copyright (c) 2013 DENIVIP Group. All rights reserved.
//

#import "DVPlaylistPlayer.h"
#import "DVAudioSession.h"
#import "DVPlaylistPlayerView.h"
#import "THObserver.h"

typedef void (^TimeObserverBlock)(CMTime time);

@interface DVPlaylistPlayer()

@property (nonatomic, strong) NSInvocation *invocationOnError;
@property (nonatomic) float unmuteVolume;
@property (nonatomic) BOOL forcedStop;

@property (nonatomic, strong) THObserver *playerItemStatusObserver;
@property (nonatomic, strong) THObserver *playerRateObserver;
@property (nonatomic, strong) THObserver *playerItemPlaybackLikelyToKeepUpObserver;
@property (nonatomic, strong) id playerPeriodicTimeObserver;

@property (nonatomic) CMTime periodicTimeObserverTime;
@property (nonatomic) dispatch_queue_t periodicTimeObserverQueue;
@property (nonatomic, strong) TimeObserverBlock periodicTimeObserverBlock;

@property (nonatomic, strong) NSError *error;

@end

@implementation DVPlaylistPlayer

@synthesize playerView = _playerView;

-(UIView *)playerView {
    if (!_playerView) {
        _playerView = [[DVPlaylistPlayerView alloc] initWithFrame:CGRectZero];
    }
    
    return _playerView;
}

#pragma mark - Player control methods

- (void)playMediaAtIndex:(NSInteger)index {
    
    if (!self.dataSource ||
        [self.dataSource numberOfPlayerItems] < 1) {
        [self triggerError:nil];
        return;
    }
    
    _currentItemIndex = index;
    
    [self playCurrentMedia];
}

- (void)playCurrentMedia {
    if (_currentItemIndex < 0) {
        _currentItemIndex = 0;
    } else if (_currentItemIndex > [self.dataSource numberOfPlayerItems] - 1) {
        _currentItemIndex = [self.dataSource numberOfPlayerItems] - 1;
        [self stop];
        return;
    }
    
    if (self.currentItem.status == AVPlayerItemStatusReadyToPlay &&
        self.forcedStop) {
        if ([self.delegate respondsToSelector:@selector(queuePlayerDidStopPlaying:)]) {
            [self.delegate queuePlayerDidStopPlaying:self];
        }
    }
    
    self.forcedStop = YES;
    
    AVPlayerItem *playerItem = [self.dataSource queuePlayer:self playerItemAtIndex:_currentItemIndex];
    
    self.playerItemStatusObserver = [THObserver observerForObject:playerItem keyPath:@"status" block:^{
        switch (self.currentItem.status) {
            case AVPlayerItemStatusReadyToPlay: {
                [self.player play];
                _state = DVQueuePlayerStatePlaying;
            }
                break;
             
            case AVPlayerItemStatusFailed: {
                [self triggerError:self.currentItem.error];
                [self.invocationOnError invoke];
            }
                break;
                
            case AVPlayerItemStatusUnknown:
            default:
                break;
        }
    }];
    
    self.playerItemPlaybackLikelyToKeepUpObserver = [THObserver observerForObject:playerItem keyPath:@"playbackLikelyToKeepUp" block:^{
            if (!self.currentItem.playbackLikelyToKeepUp) {
                if ([self.delegate respondsToSelector:@selector(queuePlayerBuffering:)]) {
                    [self.delegate queuePlayerBuffering:self];
                }
                _state = DVQueuePlayerStateBuffering;
            }
    }];
    
    AVPlayer *player = [AVPlayer playerWithPlayerItem:playerItem];
    
    __block BOOL currentlyStartingToPlay = YES;
    self.playerRateObserver = [THObserver observerForObject:player keyPath:@"rate" block:^{
        if (self.player.rate > 0 && currentlyStartingToPlay) {
            currentlyStartingToPlay = NO;
            if ([self.delegate respondsToSelector:@selector(queuePlayerDidStartPlaying:)]) {
                [self.delegate queuePlayerDidStartPlaying:self];
            }
            _state = DVQueuePlayerStatePlaying;
        }
        else if (self.player.rate > 0) {
            if ([self.delegate respondsToSelector:@selector(queuePlayerDidResumePlaying:)]) {
                [self.delegate queuePlayerDidResumePlaying:self];
            }
            _state = DVQueuePlayerStatePlaying;
        }
        else if (self.player.rate == 0 && !currentlyStartingToPlay &&
                 self.currentItem.playbackLikelyToKeepUp) {
            if ([self.delegate respondsToSelector:@selector(queuePlayerDidPausePlaying:)]) {
                [self.delegate queuePlayerDidPausePlaying:self];
            }
            _state = DVQueuePlayerStatePause;
        }
    }];
    
    if (self.player && self.playerPeriodicTimeObserver) {
        [self.player removeTimeObserver:self.playerPeriodicTimeObserver];
        self.playerPeriodicTimeObserver = nil;
    }
    
    if (CMTIME_IS_VALID(self.periodicTimeObserverTime)) {
        self.playerPeriodicTimeObserver = [player addPeriodicTimeObserverForInterval:self.periodicTimeObserverTime
                                                                               queue:self.periodicTimeObserverQueue
                                                                          usingBlock:self.periodicTimeObserverBlock];
    }

    ((DVPlaylistPlayerView *)self.playerView).playerLayer.player = player;
    self.currentItem = playerItem;
    self.player = player;
}

-(void)setCurrentItem:(AVPlayerItem *)currentItem {
    if (!currentItem && _currentItem) {
        [[NSNotificationCenter defaultCenter] removeObserver:self
                                                        name:AVPlayerItemDidPlayToEndTimeNotification
                                                      object:_currentItem];
    }
    
    _currentItem = currentItem;
    
    if (_currentItem) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(playerItemReachedEnd)
                                                     name:AVPlayerItemDidPlayToEndTimeNotification
                                                   object:_currentItem];
    }
}

- (void)playerItemReachedEnd {
    self.forcedStop = NO;
    if ([self.delegate respondsToSelector:@selector(queuePlayerDidCompletePlaying:)]) {
        [self.delegate queuePlayerDidCompletePlaying:self];
    }

}

-(void)resume {
    [self.player play];
    self.invocationOnError = nil;
}

-(void)pause {
    [self.player pause];
}

-(void)stop {
    self.invocationOnError = nil;
    
    if (!self.player)
        return;
    
    [self.player removeTimeObserver:self.playerPeriodicTimeObserver];
    
    self.playerItemStatusObserver = nil;
    self.playerPeriodicTimeObserver = nil;
    self.playerRateObserver = nil;
    self.playerItemPlaybackLikelyToKeepUpObserver = nil;
    
    ((DVPlaylistPlayerView *)self.playerView).playerLayer.player = nil;
    self.player = nil;
    self.currentItem = nil;
    
    _state = DVQueuePlayerStateStop;
    
    if (self.forcedStop) {
        if ([self.delegate respondsToSelector:@selector(queuePlayerDidStopPlaying:)]) {
            [self.delegate queuePlayerDidStopPlaying:self];
        }
    }
    self.forcedStop = NO;
}

-(void)next {    
    ++_currentItemIndex;
    
    self.invocationOnError = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(next)]];
    self.invocationOnError.target = self;
    self.invocationOnError.selector = @selector(next);
    if ([self.delegate respondsToSelector:@selector(queuePlayerDidMoveToNext:)]) {
        [self.delegate queuePlayerDidMoveToNext:self];
    }
    
    [self playCurrentMedia];
    
}

-(void)previous {
    --_currentItemIndex;
    
    self.invocationOnError = [NSInvocation invocationWithMethodSignature:[[self class] instanceMethodSignatureForSelector:@selector(previous)]];
    self.invocationOnError.target = self;
    self.invocationOnError.selector = @selector(previous);
    
    [self playCurrentMedia];
}

-(void)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime))block {
    self.periodicTimeObserverTime = interval;
    self.periodicTimeObserverQueue = queue;
    self.periodicTimeObserverBlock = block;
}

#pragma mark - Volume Control

- (void)configureVolume
{
    float volume = (self.isMuted ? 0.f : self.volume);
    [DVAudioSession defaultSession].volume = volume;
}

- (void)mute
{
    if (self.isMuted) {
        return;
    }
    
    _muted = YES;
    self.unmuteVolume = self.volume;
    [self configureVolume];
    
    if ([self.delegate respondsToSelector:@selector(queuePlayerDidMute:)]) {
        [self.delegate queuePlayerDidMute:self];
    }
}

- (void)unmute
{
    if (! self.isMuted) {
        return;
    }
    
    _muted = NO;
    _volume = self.unmuteVolume;
    [self configureVolume];
    
    if ([self.delegate respondsToSelector:@selector(queuePlayerDidUnmute:)]) {
        [self.delegate queuePlayerDidUnmute:self];
    }
}

- (void)setVolume:(float)volume
{
    _volume = volume;
    
    if (_volume > 0.f) {
        _muted = NO;
    }
    
    [self configureVolume];
    if ([self.delegate respondsToSelector:@selector(queuePlayerDidChangeVolume:)]) {
        [self.delegate queuePlayerDidChangeVolume:self];
    }
}

#pragma mark - Firing events

- (void)triggerError:(NSError *)error
{
    self.error = error;
    _state = DVQueuePlayerStateStop;
    if ([self.delegate respondsToSelector:@selector(queuePlayerFailedToPlay:withError:)]) {
        [self.delegate queuePlayerFailedToPlay:self withError:error];
    }
}

@end
