//
//  FSPlayerKit.h
//  FSPlayerKit
//
//  Created by Justin Qian on 2021/9/30.
//

#ifndef FSMediaPlayerKit_h
#define FSMediaPlayerKit_h


#if TARGET_OS_IOS || TARGET_OS_TV
#import <UIKit/UIKit.h>
#else
#import <AppKit/AppKit.h>
#endif

#import <FSPlayer/FSMediaPlayback.h>
#import <FSPlayer/FSMonitor.h>
#import <FSPlayer/FSOptions.h>
#import <FSPlayer/FSPlayer.h>
#import <FSPlayer/FSMediaModule.h>
#import <FSPlayer/FSNotificationManager.h>
#import <FSPlayer/FSKVOController.h>
#import <FSPlayer/FSVideoRenderingProtocol.h>
#import <FSPlayer/FSVideoRenderView.h>

#endif /* FSMediaPlayerKit_h */
