/*
 * FSSDLAudioKit.m
 *
 * Copyright (c) 2013-2014 Bilibili
 * Copyright (c) 2013-2014 Zhang Rui <bbcallen@gmail.com>
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

#import "FSSDLAudioKit.h"
#include "ijksdl/ijksdl_aout.h"
#import "FSAudioRenderingProtocol.h"

void FSSDLGetAudioComponentDescriptionFromSpec(FSAudioSpec *spec, AudioComponentDescription *desc)
{
    desc->componentType = kAudioUnitType_Output;
#if TARGET_OS_IOS
    desc->componentSubType = kAudioUnitSubType_RemoteIO;
#elif TARGET_OS_OSX
    desc->componentSubType = kAudioUnitSubType_DefaultOutput;
#else
    desc->componentSubType = kAudioUnitSubType_GenericOutput;
#endif
    desc->componentManufacturer = kAudioUnitManufacturer_Apple;
    desc->componentFlags = 0;
    desc->componentFlagsMask = 0;
}

void FSSDLGetAudioStreamBasicDescriptionFromSpec(FSAudioSpec *spec, AudioStreamBasicDescription *desc)
{
    desc->mSampleRate = spec.freq;
    desc->mFormatID = kAudioFormatLinearPCM;
    desc->mFormatFlags = kLinearPCMFormatFlagIsPacked;
    desc->mChannelsPerFrame = spec.channels;
    desc->mFramesPerPacket = 1;
    
    desc->mBitsPerChannel = SDL_AUDIO_BITSIZE(spec.format);
    if (SDL_AUDIO_ISBIGENDIAN(spec.format))
    desc->mFormatFlags |= kLinearPCMFormatFlagIsBigEndian;
    if (SDL_AUDIO_ISFLOAT(spec.format))
    desc->mFormatFlags |= kLinearPCMFormatFlagIsFloat;
    if (SDL_AUDIO_ISSIGNED(spec.format))
    desc->mFormatFlags |= kLinearPCMFormatFlagIsSignedInteger;
    
    desc->mBytesPerFrame = desc->mBitsPerChannel * desc->mChannelsPerFrame / 8;
    desc->mBytesPerPacket = desc->mBytesPerFrame * desc->mFramesPerPacket;
}

void FSSDLCalculateAudioSpec(FSAudioSpec * spec)
{
    switch (spec.format) {
    case AUDIO_U8:
        spec.silence = 0x80;
        break;
    default:
        spec.silence = 0x00;
        break;
    }
    spec.size = SDL_AUDIO_BITSIZE(spec.format) / 8;
    spec.size *= spec.channels;
    spec.size *= spec.samples;
}

