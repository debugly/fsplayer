/*
 * FSSDLAudioUnitController.m
 *
 * Copyright (c) 2013 Bilibili
 * Copyright (c) 2013 Zhang Rui <bbcallen@gmail.com>
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * based on https://github.com/kolyvan/kxmovie
 *
 * This file is part of FSPlayer.
 *
 * FSPlayer is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 3 of the License, or (at your option) any later version.
 *
 * FSPlayer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with FSPlayer; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA
 */

#import "FSSDLAudioUnitController.h"
#import "FSSDLAudioKit.h"
#include "ijksdl/ijksdl_log.h"

#import <AVFoundation/AVFoundation.h>

@implementation FSSDLAudioUnitController {
    AudioUnit _auUnit;
    BOOL _isPaused;
}
@synthesize automaticallySetupAudioSession = _automaticallySetupAudioSession;

- (BOOL)isSupportAudioSpec:(FSAudioSpec *)aSpec err:(NSError *__autoreleasing *)outErr
{
    if (aSpec == NULL) {
        if (outErr) {
            *outErr = [NSError errorWithDomain:@"fsplayer.audiounit" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Spec is nil"}];
        }
        return NO;
    }
    
    if (aSpec.format != FSAudioSpecS16) {
        if (outErr) *outErr = [NSError errorWithDomain:@"fsplayer.audiounit" code:2 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"unsupported format %d", (int)aSpec.format]}];
        return NO;
    }
    
    if (aSpec.channels > 6) {
        if (outErr) *outErr = [NSError errorWithDomain:@"fsplayer.audiounit" code:3 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"unsupported channels %d", (int)aSpec.channels]}];
        return NO;
    }
    
    /* Get the current format */
    AudioComponentDescription desc;
    FSSDLGetAudioComponentDescriptionFromSpec(aSpec, &desc);
    
    AudioComponent auComponent = AudioComponentFindNext(NULL, &desc);
    if (auComponent == NULL) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:4 userInfo:@{NSLocalizedDescriptionKey:@"AudioComponentFindNext is NULL"}];
        return NO;
    }
    
    AudioUnit auUnit;
    OSStatus status = AudioComponentInstanceNew(auComponent, &auUnit);
    if (status != noErr) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:5 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"AudioComponentInstanceNew failed:%d",status]}];
        return NO;
    }
    
    UInt32 flag = 1;
    status = AudioUnitSetProperty(auUnit,
                                  kAudioOutputUnitProperty_EnableIO,
                                  kAudioUnitScope_Output,
                                  0,
                                  &flag,
                                  sizeof(flag));
    if (status != noErr) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:6 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"failed to set IO mode (%d)", (int)status]}];
    }
    
    /* Get the current format */
    aSpec.format = FSAudioSpecS16;
    aSpec.channels = 2;
    AudioStreamBasicDescription streamDescription;
    FSSDLGetAudioStreamBasicDescriptionFromSpec(aSpec, &streamDescription);
    
    /* Set the desired format */
    UInt32 i_param_size = sizeof(streamDescription);
    status = AudioUnitSetProperty(auUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &streamDescription,
                                  i_param_size);
    if (status != noErr) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:7 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"failed to set stream format (%d)", (int)status]}];
        return NO;
    }
    
    /* Retrieve actual format */
    status = AudioUnitGetProperty(auUnit,
                                  kAudioUnitProperty_StreamFormat,
                                  kAudioUnitScope_Input,
                                  0,
                                  &streamDescription,
                                  &i_param_size);
    if (status != noErr) {
        ALOGE("AudioUnit: failed to verify stream format (%d)\n", (int)status);
    }
    
    AURenderCallbackStruct callback;
    callback.inputProc = (AURenderCallback) RenderCallback;
    callback.inputProcRefCon = (__bridge void*) self;
    status = AudioUnitSetProperty(auUnit,
                                  kAudioUnitProperty_SetRenderCallback,
                                  kAudioUnitScope_Input,
                                  0, &callback, sizeof(callback));
    if (status != noErr) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:8 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"render callback setup failed (%d)", (int)status]}];
        return NO;
    }
    
    FSSDLCalculateAudioSpec(aSpec);
    
    /* AU initiliaze */
    status = AudioUnitInitialize(auUnit);
    if (status != noErr) {
        if (outErr) *outErr = [NSError errorWithDomain:@"ijk.audiounit" code:9 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"AudioUnitInitialize failed (%d)", (int)status]}];
        return NO;
    }
    
    _auUnit = auUnit;
    _spec = aSpec;
    return YES;
}

- (void)dealloc
{
    [self close];
}

- (void)play
{
    if (!_auUnit)
    return;
    
    _isPaused = NO;
#if TARGET_OS_IOS
    if (_automaticallySetupAudioSession) {
        NSError *error = nil;
        if (NO == [[AVAudioSession sharedInstance] setActive:YES error:&error]) {
            NSLog(@"AudioUnit: AVAudioSession.setActive(YES) failed: %@\n", error ? [error localizedDescription] : @"nil");
        }
    }
#endif
    OSStatus status = AudioOutputUnitStart(_auUnit);
    if (status != noErr)
    NSLog(@"AudioUnit: AudioOutputUnitStart failed (%d)\n", (int)status);
}

- (void)pause
{
    if (!_auUnit)
    return;
    
    _isPaused = YES;
    OSStatus status = AudioOutputUnitStop(_auUnit);
    if (status != noErr)
    ALOGE("AudioUnit: failed to stop AudioUnit (%d)\n", (int)status);
}

- (void)flush
{
    if (!_auUnit)
    return;
    
    AudioUnitReset(_auUnit, kAudioUnitScope_Global, 0);
}

- (void)stop
{
    if (!_auUnit)
    return;
    
    OSStatus status = AudioOutputUnitStop(_auUnit);
    if (status != noErr)
    ALOGE("AudioUnit: failed to stop AudioUnit (%d)", (int)status);
}

- (void)close
{
    [self stop];
    
    if (!_auUnit)
    return;
    
    AURenderCallbackStruct callback;
    memset(&callback, 0, sizeof(AURenderCallbackStruct));
    AudioUnitSetProperty(_auUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input, 0, &callback,
                         sizeof(callback));
    
    AudioComponentInstanceDispose(_auUnit);
    _auUnit = NULL;
}

- (double)get_latency_seconds
{
    return _spec.samples / _spec.freq;
}

- (void)setPlaybackRate:(float)playbackRate { 
    
}


- (void)setPlaybackVolume:(float)playbackVolume { 
    
}


static OSStatus RenderCallback(void                        *inRefCon,
                               AudioUnitRenderActionFlags  *ioActionFlags,
                               const AudioTimeStamp        *inTimeStamp,
                               UInt32                      inBusNumber,
                               UInt32                      inNumberFrames,
                               AudioBufferList             *ioData)
{
    @autoreleasepool {
        FSSDLAudioUnitController* auController = (__bridge FSSDLAudioUnitController *) inRefCon;
        
        if (!auController || auController->_isPaused) {
            for (UInt32 i = 0; i < ioData->mNumberBuffers; i++) {
                AudioBuffer *ioBuffer = &ioData->mBuffers[i];
                memset(ioBuffer->mData, auController.spec.silence, ioBuffer->mDataByteSize);
            }
            return noErr;
        }
        
        for (int i = 0; i < (int)ioData->mNumberBuffers; i++) {
            AudioBuffer *ioBuffer = &ioData->mBuffers[i];
            (*auController.spec.callback)(auController.spec.userdata, ioBuffer->mData, ioBuffer->mDataByteSize);
        }
        
        return noErr;
    }
}

@end
