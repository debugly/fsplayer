//
//  MRHoverTextButton.m
//  AuraPlayer
//

#import "MRHoverTextButton.h"

@interface MRHoverTextButton () {
    NSTrackingArea *_trackingArea;
}
@end

@implementation MRHoverTextButton

- (instancetype)initWithFrame:(NSRect)frameRect {
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.bordered = NO;
    self.bezelStyle = NSBezelStyleRegularSquare;
    _normalColor = [NSColor whiteColor];
    _hoverColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
}

- (void)setNormalColor:(NSColor *)normalColor {
    _normalColor = normalColor;
    [self updateTitleColor:self.normalColor];
}

- (void)setHoverColor:(NSColor *)hoverColor {
    _hoverColor = hoverColor;
}

- (void)setTitle:(NSString *)title {
    [super setTitle:title];
    [self updateTitleColor:self.normalColor];
}

- (void)setFont:(NSFont *)font {
    [super setFont:font];
    [self updateTitleColor:self.normalColor];
}

- (void)updateTitleColor:(NSColor *)color {
    if (!self.title || self.title.length == 0) return;
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:self.title];
    NSRange range = NSMakeRange(0, attr.length);
    [attr addAttribute:NSForegroundColorAttributeName value:color range:range];
    [attr addAttribute:NSFontAttributeName value:self.font ?: [NSFont systemFontOfSize:12 weight:NSFontWeightMedium] range:range];
    self.attributedTitle = attr;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds options:options owner:self userInfo:nil];
    [self addTrackingArea:_trackingArea];
    
    if (self.window) {
        NSPoint mouseLocation = [self.window mouseLocationOutsideOfEventStream];
        NSPoint localPoint = [self convertPoint:mouseLocation fromView:nil];
        if (NSPointInRect(localPoint, self.bounds)) {
            [self updateTitleColor:self.hoverColor];
        } else {
            [self updateTitleColor:self.normalColor];
        }
    }
}

- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self updateTitleColor:self.hoverColor];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    [self updateTitleColor:self.normalColor];
}

- (void)resetCursorRects {
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

@end
