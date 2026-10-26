#ifndef FSPLAYER_FF_HWDEC_RECOVERY_H
#define FSPLAYER_FF_HWDEC_RECOVERY_H

/* VideoToolbox foreground recovery is only used by iOS and tvOS apps.
 * Keep its cache, decoder state and entry points out of other platforms. */
#if defined(__APPLE__)
#include <TargetConditionals.h>
#define FFP_APPLE_MOBILE_HWDEC_RECOVERY (TARGET_OS_IOS || TARGET_OS_TV)
#else
#define FFP_APPLE_MOBILE_HWDEC_RECOVERY 0
#endif

#endif
