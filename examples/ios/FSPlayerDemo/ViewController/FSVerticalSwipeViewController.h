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

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Full-screen player where a vertical swipe moves to the neighbour room.
///
/// Ported from SohuLive's live room:
///
///  - a blurred cover sits in the back, a pan container in front of it holds
///    the player, and the whole container follows the finger;
///  - the room changes only at the end of the drag, once the finger has passed
///    a threshold -- so a short flick springs back instead of switching;
///  - the backdrop crossfades between rooms as they are prepared.
///
/// Rooms come from FSVerticalFeedStore, which reads bundled JSON. Edit the JSON
/// to change rooms; no view code depends on the current feed.
@interface FSVerticalSwipeViewController : UIViewController

@end

NS_ASSUME_NONNULL_END