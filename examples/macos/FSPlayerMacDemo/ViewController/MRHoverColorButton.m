#import "MRHoverColorButton.h"

@interface MRHoverColorButton () {
    NSTrackingArea *_trackingArea;
}
@end

@implementation MRHoverColorButton

- (instancetype)initWithFrame:(NSRect)frameRect
{
    self = [super initWithFrame:frameRect];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder
{
    self = [super initWithCoder:coder];
    if (self) {
        [self commonInit];
    }
    return self;
}

- (void)commonInit
{
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.bordered = NO;
    self.bezelStyle = NSBezelStyleRegularSquare;
    self.contentTintColor = [NSColor whiteColor];
}

- (void)updateTrackingAreas
{
    [super updateTrackingAreas];
    
    if (_trackingArea) {
        [self removeTrackingArea:_trackingArea];
    }
    
    NSTrackingAreaOptions options = NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways;
    _trackingArea = [[NSTrackingArea alloc] initWithRect:self.bounds
                                                 options:options
                                                   owner:self
                                                userInfo:nil];
    [self addTrackingArea:_trackingArea];
    
    if (self.window) {
        NSPoint mouseLocation = [self.window mouseLocationOutsideOfEventStream];
        NSPoint localPoint = [self convertPoint:mouseLocation fromView:nil];
        if (NSPointInRect(localPoint, self.bounds)) {
            self.contentTintColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
        } else {
            self.contentTintColor = [NSColor whiteColor];
        }
    }
}

- (void)resetCursorRects
{
    [super resetCursorRects];
    [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}

- (void)mouseEntered:(NSEvent *)event
{
    [super mouseEntered:event];
    self.contentTintColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
}

- (void)mouseExited:(NSEvent *)event
{
    [super mouseExited:event];
    self.contentTintColor = [NSColor whiteColor];
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    
    if (highlighted) {
        // Pressed tactile feedback: dark grey shade
        self.contentTintColor = [NSColor colorWithWhite:0.6 alpha:1.0];
    } else {
        // Released state: restore back based on real-time mouse position
        NSPoint mouseLocation = [self.window mouseLocationOutsideOfEventStream];
        NSPoint localPoint = [self convertPoint:mouseLocation fromView:nil];
        if (NSPointInRect(localPoint, self.bounds)) {
            self.contentTintColor = [NSColor colorWithRed:229.0/255.0 green:9.0/255.0 blue:20.0/255.0 alpha:1.0];
        } else {
            self.contentTintColor = [NSColor whiteColor];
        }
    }
}

@end
