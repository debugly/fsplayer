/*
 * Copyright (c) 2019 debugly <qianlongxu@gmail.com>
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#import "FSSceneDelegate.h"
#import "FSDemoMainViewController.h"

@implementation FSSceneDelegate

- (void)scene:(UIScene *)scene
    willConnectToSession:(UISceneSession *)session
                 options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]]) {
        return;
    }

    UIWindowScene *windowScene = (UIWindowScene *)scene;

    UIWindow *window = [[UIWindow alloc] initWithWindowScene:windowScene];
    window.rootViewController =
        [[UINavigationController alloc] initWithRootViewController:[[FSDemoMainViewController alloc] init]];
    [window makeKeyAndVisible];

    self.window = window;
}

- (void)sceneDidDisconnect:(UIScene *)scene
{
    self.window = nil;
}

@end