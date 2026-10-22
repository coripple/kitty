// License: GPL v3 Copyright: 2026
//
// Native macOS project sidebar for ditty.
//
// The sidebar is an NSOutlineView in source-list style hosted in a
// sidebar-material NSVisualEffectView, so it looks and behaves like the
// sidebars in Finder, Mail and Xcode: native disclosure triangles with
// animation, a "Projects" section header, system row sizes (respecting the
// "Sidebar icon size" setting), hover accessories, context menus, inline
// rename and middle-click to close.
//
// Python sends a flat list of rows as JSON. Project and section rows are
// followed by all of their tab rows, regardless of whether they are expanded;
// collapsing is done here so that the disclosure animation is not interrupted
// by the round trip through Python.

#include "data-types.h"

#ifdef __APPLE__

#import <Cocoa/Cocoa.h>
#include <string.h>
#import <objc/runtime.h>
#include "native_sidebar.h"

// Python bridge {{{

static PyObject *sidebar_callback = NULL;

static void
call_python(const char *kind, const char *project_id, long long tab_id, const char *text) {
    if (sidebar_callback == NULL) return;
    PyGILState_STATE gstate = PyGILState_Ensure();
    PyObject *ret = PyObject_CallFunction(sidebar_callback, "ssLs", kind, project_id, tab_id, text);
    if (ret) Py_DECREF(ret);
    else PyErr_Print();
    PyGILState_Release(gstate);
}

void
native_sidebar_set_callback(PyObject *callback) {
    Py_XINCREF(callback);
    Py_XDECREF(sidebar_callback);
    sidebar_callback = callback;
}

static void
dispatch_python(const char *kind, NSString *project_id, long long tab_id, NSString *text) {
    char *kind_copy = strdup(kind ? kind : "");
    char *pid_copy = strdup(project_id ? [project_id UTF8String] : "");
    char *text_copy = strdup(text ? [text UTF8String] : "");
    if (kind_copy == NULL || pid_copy == NULL || text_copy == NULL) {
        free(kind_copy); free(pid_copy); free(text_copy);
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        call_python(kind_copy, pid_copy, tab_id, text_copy);
        free(kind_copy);
        free(pid_copy);
        free(text_copy);
    });
}

// }}}

// Helpers {{{

static NSString *
string_value(id v) {
    if ([v isKindOfClass:[NSString class]]) return v;
    if ([v respondsToSelector:@selector(stringValue)]) return [v stringValue];
    return @"";
}

static BOOL
bool_value(id v) {
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : NO;
}

static NSInteger
integer_value(id v) {
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : 0;
}

// Diagnostics for the sidebar, appended to sidebar-debug.log in the ditty
// config directory (next to the templates directory).
static NSString *debug_log_path = nil;

static void
sidebar_debug_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

static void
sidebar_debug_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[[NSString alloc] initWithFormat:fmt arguments:ap] autorelease];
    va_end(ap);
    NSLog(@"ditty sidebar: %@", msg);
    if (debug_log_path == nil) return;
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:debug_log_path];
    if (fh == nil) {
        [line writeToFile:debug_log_path atomically:NO encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) {
        NSLog(@"ditty sidebar: could not write debug log: %@", e);
    }
    [fh closeFile];
}

static NSImage *
symbol_image_with_weight(NSArray<NSString *> *names, CGFloat point_size, NSFontWeight weight, NSImageName fallback) {
    if (@available(macOS 11.0, *)) {
        for (NSString *name in names) {
            NSImage *image = [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil];
            if (image == nil) continue;
            if (point_size > 0) {
                NSImageSymbolConfiguration *config = [NSImageSymbolConfiguration configurationWithPointSize:point_size weight:weight];
                NSImage *configured = [image imageWithSymbolConfiguration:config];
                if (configured != nil) return configured;
            }
            return image;
        }
    }
    if (fallback == nil) return nil;
    NSImage *ans = [NSImage imageNamed:fallback];
    return ans;
}

static NSImage *
symbol_image(NSArray<NSString *> *names, CGFloat point_size, NSImageName fallback) {
    return symbol_image_with_weight(names, point_size, NSFontWeightSemibold, fallback);
}

// }}}

// Model {{{

@interface DittySidebarNode : NSObject
@property (nonatomic, copy) NSString *kind;
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *ident;
@property (nonatomic, copy) NSString *projectId;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *root;
@property (nonatomic) BOOL active;
@property (nonatomic) BOOL expanded;
@property (nonatomic) NSInteger count;
@property (nonatomic) BOOL customTitle;
@property (nonatomic) BOOL sshRemembered;  // tabs: a window connects with the ssh kitten
@property (nonatomic) BOOL projectOpen;  // projects: has tabs; closed ones are listed under Recent
@property (nonatomic) double lastOpened;
@property (nonatomic, copy) NSString *sessionPath;
@property (nonatomic, assign) DittySidebarNode *parent;
@property (nonatomic, readonly) NSMutableArray<DittySidebarNode *> *children;
- (BOOL)isHeader;
- (BOOL)isProject;
- (BOOL)isSection;
- (BOOL)isTab;
- (BOOL)isContainer;
- (NSString *)signature;
- (void)copyValuesFrom:(DittySidebarNode *)other;
@end

@implementation DittySidebarNode

- (instancetype)init {
    self = [super init];
    if (self) _children = [[NSMutableArray alloc] init];
    return self;
}

- (void)dealloc {
    [_kind release];
    [_key release];
    [_ident release];
    [_projectId release];
    [_title release];
    [_root release];
    [_sessionPath release];
    [_children release];
    [super dealloc];
}

- (BOOL)isHeader { return [_kind isEqualToString:@"header"]; }
- (BOOL)isProject { return [_kind isEqualToString:@"project"]; }
- (BOOL)isSection { return [_kind isEqualToString:@"section"]; }
- (BOOL)isTab { return [_kind isEqualToString:@"tab"]; }
- (BOOL)isContainer { return [self isProject] || [self isSection]; }

// The identity of the tree, ignoring values that can be updated in place.
- (NSString *)signature {
    NSMutableString *ans = [NSMutableString stringWithString:_key ? _key : @""];
    if (_children.count) {
        [ans appendString:@"("];
        for (DittySidebarNode *child in _children) {
            [ans appendString:[child signature]];
            [ans appendString:@","];
        }
        [ans appendString:@")"];
    }
    return ans;
}

- (void)copyValuesFrom:(DittySidebarNode *)other {
    self.title = other.title;
    self.root = other.root;
    self.projectId = other.projectId;
    self.active = other.active;
    self.expanded = other.expanded;
    self.count = other.count;
    self.customTitle = other.customTitle;
    self.sshRemembered = other.sshRemembered;
    self.projectOpen = other.projectOpen;
    self.lastOpened = other.lastOpened;
    self.sessionPath = other.sessionPath;
    NSUInteger n = MIN(_children.count, other.children.count);
    for (NSUInteger i = 0; i < n; i++) [_children[i] copyValuesFrom:other.children[i]];
}

@end

// }}}

// Views {{{

// Text in a row. It only takes mouse events while it is being edited
// (inline rename), otherwise clicks, double clicks and right clicks on the
// text go to the row, like clicking anywhere else in it.
@interface DittyLabel : NSTextField
@end

@implementation DittyLabel
- (NSView *)hitTest:(NSPoint)point {
    if (!self.editable) return nil;
    return [super hitTest:point];
}
@end

@interface DittyCellView : NSTableCellView
@property (nonatomic, readonly) NSTextField *badge;
@property (nonatomic, readonly) NSButton *accessoryButton;
@property (nonatomic) BOOL hovered;
@property (nonatomic) BOOL accessoryOnHoverOnly;
@property (nonatomic) BOOL hasAccessory;
- (instancetype)initWithIdentifier:(NSString *)identifier target:(id)target action:(SEL)action;
- (void)setIconVisible:(BOOL)visible;
- (void)updateAccessoryVisibility;
@end

// Distance of the trailing accessories (+, x, counts) from the right edge of
// the row, the same for every row so that they line up in one column. Rows
// are inset differently by the source list style (group rows vs. items).
static const CGFloat kTrailingAccessoryInset = 10;

@implementation DittyCellView {
    NSLayoutConstraint *_iconWidth;
    NSLayoutConstraint *_labelLeading;
    NSLayoutConstraint *_accessoryTrailing;
    NSLayoutConstraint *_badgeTrailing;
}

- (instancetype)initWithIdentifier:(NSString *)identifier target:(id)target action:(SEL)action {
    self = [super initWithFrame:NSMakeRect(0, 0, 200, 24)];
    if (self == nil) return nil;
    self.identifier = identifier;

    NSImageView *icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.imageScaling = NSImageScaleProportionallyUpOrDown;
    [self addSubview:icon];
    self.imageView = icon;
    [icon release];

    NSTextField *label = [DittyLabel labelWithString:@""];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.lineBreakMode = NSLineBreakByTruncatingTail;
    label.cell.truncatesLastVisibleLine = YES;
    label.usesSingleLineMode = YES;
    label.focusRingType = NSFocusRingTypeDefault;
    [label setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [label setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:label];
    self.textField = label;

    _badge = [[DittyLabel labelWithString:@""] retain];
    _badge.translatesAutoresizingMaskIntoConstraints = NO;
    _badge.font = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    _badge.textColor = [NSColor tertiaryLabelColor];
    _badge.alignment = NSTextAlignmentRight;
    [_badge setContentCompressionResistancePriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_badge setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    [self addSubview:_badge];

    _accessoryButton = [[NSButton alloc] initWithFrame:NSZeroRect];
    _accessoryButton.translatesAutoresizingMaskIntoConstraints = NO;
    _accessoryButton.bordered = NO;
    _accessoryButton.imagePosition = NSImageOnly;
    _accessoryButton.imageScaling = NSImageScaleProportionallyDown;
    _accessoryButton.focusRingType = NSFocusRingTypeNone;
    _accessoryButton.refusesFirstResponder = YES;
    [_accessoryButton setButtonType:NSButtonTypeMomentaryChange];
    if (@available(macOS 10.14, *)) _accessoryButton.contentTintColor = [NSColor secondaryLabelColor];
    _accessoryButton.target = target;
    _accessoryButton.action = action;
    _accessoryButton.hidden = YES;
    [self addSubview:_accessoryButton];

    _iconWidth = [icon.widthAnchor constraintEqualToConstant:16];
    _labelLeading = [label.leadingAnchor constraintEqualToAnchor:icon.trailingAnchor constant:6];
    _accessoryTrailing = [_accessoryButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8];
    _badgeTrailing = [_badge.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8];
    NSLayoutConstraint *label_before_badge = [label.trailingAnchor constraintLessThanOrEqualToAnchor:_badge.leadingAnchor constant:-6];
    NSLayoutConstraint *label_before_button = [label.trailingAnchor constraintLessThanOrEqualToAnchor:_accessoryButton.leadingAnchor constant:-4];
    [NSLayoutConstraint activateConstraints:@[
        [icon.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:2],
        [icon.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [icon.heightAnchor constraintEqualToConstant:16],
        _iconWidth,
        _labelLeading,
        [label.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        label_before_badge,
        label_before_button,
        _badgeTrailing,
        [_badge.firstBaselineAnchor constraintEqualToAnchor:label.firstBaselineAnchor],
        _accessoryTrailing,
        [_accessoryButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_accessoryButton.widthAnchor constraintEqualToConstant:16],
        [_accessoryButton.heightAnchor constraintEqualToConstant:16],
    ]];
    return self;
}

- (void)dealloc {
    [_badge release];
    [_accessoryButton release];
    [super dealloc];
}

// Align the trailing accessories to the row's right edge, not the cell's.
- (void)updateTrailingInsets {
    NSView *row = self.superview;
    if (row == nil || _accessoryTrailing == nil) return;
    CGFloat cell_inset = NSMaxX(row.bounds) - NSMaxX(self.frame);
    CGFloat constant = -MAX(2, kTrailingAccessoryInset - cell_inset);
    if (_accessoryTrailing.constant != constant) _accessoryTrailing.constant = constant;
    if (_badgeTrailing.constant != constant) _badgeTrailing.constant = constant;
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self updateTrailingInsets];
}

- (void)setFrameOrigin:(NSPoint)origin {
    [super setFrameOrigin:origin];
    [self updateTrailingInsets];
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self updateTrailingInsets];
}

- (void)setIconVisible:(BOOL)visible {
    self.imageView.hidden = !visible;
    _iconWidth.constant = visible ? 16 : 0;
    _labelLeading.constant = visible ? 6 : 0;
}

- (void)setHovered:(BOOL)hovered {
    _hovered = hovered;
    [self updateAccessoryVisibility];
}

- (void)updateAccessoryVisibility {
    BOOL show_accessory = _hasAccessory && (_hovered || !_accessoryOnHoverOnly);
    _accessoryButton.hidden = !show_accessory;
    // The accessory replaces the badge while it is visible, like Mail.
    _badge.hidden = show_accessory || _badge.stringValue.length == 0;
}

@end

@interface DittyRowView : NSTableRowView
@property (nonatomic) BOOL hovered;
- (void)refreshHoverFromMouseLocation;
@end

// Hover state is set by DittyOutlineView, which tracks the mouse for all rows.
// Per-row tracking areas get out of sync when rows are reused or reloaded.
@implementation DittyRowView

- (void)prepareForReuse {
    [super prepareForReuse];
    self.hovered = NO;
}

- (void)refreshHoverFromMouseLocation {
    if (self.window == nil) {
        self.hovered = NO;
        return;
    }
    NSPoint p = [self convertPoint:[self.window mouseLocationOutsideOfEventStream] fromView:nil];
    self.hovered = NSPointInRect(p, self.bounds);
}

- (void)setHovered:(BOOL)hovered {
    _hovered = hovered;
    for (NSView *v in self.subviews) {
        if ([v isKindOfClass:[DittyCellView class]]) [(DittyCellView *)v setHovered:hovered];
    }
}

- (void)didAddSubview:(NSView *)subview {
    [super didAddSubview:subview];
    if ([subview isKindOfClass:[DittyCellView class]]) [(DittyCellView *)subview setHovered:_hovered];
}

@end

@protocol DittyOutlineViewClickHandler
- (void)outlineViewMiddleClickedRow:(NSInteger)row;
// A second, slow click on the name of the selected row (Finder's rename gesture)
- (void)outlineViewSlowClickedRow:(NSInteger)row;
- (BOOL)outlineViewCanRenameRow:(NSInteger)row;
// Called before clicks and context menus, ends any inline rename
- (void)outlineViewWillShowMenu;
@end

@interface DittyOutlineView : NSOutlineView
@property (nonatomic, assign) id<DittyOutlineViewClickHandler> clickHandler;
@end

@implementation DittyOutlineView {
    NSTrackingArea *_hoverArea;
    NSInteger _dittyHoveredRow;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) _dittyHoveredRow = -1;
    return self;
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_hoverArea != nil) {
        [self removeTrackingArea:_hoverArea];
        [_hoverArea release];
        _hoverArea = nil;
    }
    _hoverArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_hoverArea];
}

- (void)dittySetHoveredRow:(NSInteger)row {
    _dittyHoveredRow = row;
    [self enumerateAvailableRowViewsUsingBlock:^(NSTableRowView *rv, NSInteger r) {
        if ([rv isKindOfClass:[DittyRowView class]]) {
            DittyRowView *drv = (DittyRowView *)rv;
            BOOL h = r == row;
            if (drv.hovered != h) drv.hovered = h;
        }
    }];
}

- (void)updateHoverFromMouseLocation {
    if (self.window == nil) return;
    NSPoint p = [self convertPoint:[self.window mouseLocationOutsideOfEventStream] fromView:nil];
    [self dittySetHoveredRow:NSPointInRect(p, self.visibleRect) ? [self rowAtPoint:p] : -1];
}

// Call super: the outline view uses its own tracking areas, e.g. for the
// Show/Hide button of group rows.
- (void)mouseEntered:(NSEvent *)event {
    [super mouseEntered:event];
    [self updateHoverFromMouseLocation];
}

- (void)mouseMoved:(NSEvent *)event {
    [super mouseMoved:event];
    [self updateHoverFromMouseLocation];
}

- (void)mouseExited:(NSEvent *)event {
    [super mouseExited:event];
    if (event.trackingArea == _hoverArea) [self dittySetHoveredRow:-1];
}

- (void)cancelSlowClick {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(fireSlowClick:) object:nil];
}

- (void)dealloc {
    [self cancelSlowClick];
    [_hoverArea release];
    [super dealloc];
}

- (BOOL)point:(NSPoint)p isOnLabelOfRow:(NSInteger)row {
    NSTableCellView *cell = [self viewAtColumn:0 row:row makeIfNecessary:NO];
    NSTextField *label = cell.textField;
    if (label == nil || label.hidden) return NO;
    NSRect r = [self convertRect:label.bounds fromView:label];
    // Only the text itself, not the empty space after a short name
    r.size.width = MIN(r.size.width, label.intrinsicContentSize.width + 6);
    return NSPointInRect(p, NSInsetRect(r, 0, -2));
}

- (void)mouseDown:(NSEvent *)event {
    [self cancelSlowClick];
    // The outline never becomes first responder, so clicking another row
    // would not end an inline rename by itself. Commit it like Finder does.
    if (_clickHandler != nil) [_clickHandler outlineViewWillShowMenu];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    NSInteger row = [self rowAtPoint:p];
    NSEventModifierFlags mods = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    BOOL candidate = event.clickCount == 1 && row >= 0 && row == self.selectedRow && mods == 0 && _clickHandler != nil &&
                     [_clickHandler outlineViewCanRenameRow:row] && [self point:p isOnLabelOfRow:row];
    // Runs the tracking loop until the mouse button is released
    [super mouseDown:event];
    if (candidate && self.selectedRow == row) {
        // Wait out the double-click interval; a second click cancels this.
        [self performSelector:@selector(fireSlowClick:) withObject:@(row) afterDelay:[NSEvent doubleClickInterval]];
    }
}

- (void)fireSlowClick:(NSNumber *)row {
    if (_clickHandler != nil && row.integerValue == self.selectedRow) [_clickHandler outlineViewSlowClickedRow:row.integerValue];
}

- (NSMenu *)menuForEvent:(NSEvent *)event {
    [self cancelSlowClick];
    // Finish any inline rename before the menu tracks, so the row is stable.
    if (_clickHandler != nil) [_clickHandler outlineViewWillShowMenu];
    NSMenu *ans = [super menuForEvent:event];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    sidebar_debug_log(@"menuForEvent row=%ld clickedRow=%ld menu=%@", (long)[self rowAtPoint:p], (long)self.clickedRow, ans ? @"yes" : @"nil");
    return ans;
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    sidebar_debug_log(@"rightMouseDown row=%ld", (long)[self rowAtPoint:p]);
    [super rightMouseDown:event];
}

- (void)scrollWheel:(NSEvent *)event {
    [self cancelSlowClick];
    [super scrollWheel:event];
    [self updateHoverFromMouseLocation];
}

- (void)otherMouseUp:(NSEvent *)event {
    if (event.buttonNumber == 2 && _clickHandler != nil) {
        NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
        [_clickHandler outlineViewMiddleClickedRow:[self rowAtPoint:p]];
        return;
    }
    [super otherMouseUp:event];
}

@end

// A thin invisible strip on the trailing edge of the sidebar that can be
// dragged to resize it, like the divider of an NSSplitView.
@protocol DittyResizeHandleDelegate
- (void)resizeHandleBeganDrag;
- (void)resizeHandleDraggedBy:(CGFloat)dx;
- (void)resizeHandleEndedDrag;
- (void)resizeHandleDoubleClicked;
@end

@interface DittyResizeHandle : NSView
@property (nonatomic, assign) id<DittyResizeHandleDelegate> delegate;
@end

@implementation DittyResizeHandle {
    NSTrackingArea *_trackingArea;
    CGFloat _startX;
    BOOL _dragging;
}

- (void)dealloc {
    [_trackingArea release];
    [super dealloc];
}

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (BOOL)mouseDownCanMoveWindow { return NO; }

- (void)resetCursorRects {
    [self addCursorRect:self.bounds cursor:[NSCursor resizeLeftRightCursor]];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_trackingArea != nil) {
        [self removeTrackingArea:_trackingArea];
        [_trackingArea release];
        _trackingArea = nil;
    }
    // The terminal view manages the cursor itself, so also set it explicitly.
    _trackingArea = [[NSTrackingArea alloc]
        initWithRect:NSZeroRect
             options:NSTrackingCursorUpdate | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect
               owner:self
            userInfo:nil];
    [self addTrackingArea:_trackingArea];
}

- (void)cursorUpdate:(NSEvent *)event { [[NSCursor resizeLeftRightCursor] set]; }
- (void)mouseEntered:(NSEvent *)event { [[NSCursor resizeLeftRightCursor] set]; }

- (void)mouseExited:(NSEvent *)event {
    if (!_dragging) [[NSCursor arrowCursor] set];
}

- (void)mouseDown:(NSEvent *)event {
    if (event.clickCount == 2) {
        [_delegate resizeHandleDoubleClicked];
        return;
    }
    // Screen coordinates stay stable while the sidebar itself moves.
    _startX = [NSEvent mouseLocation].x;
    _dragging = YES;
    [_delegate resizeHandleBeganDrag];
}

- (void)mouseDragged:(NSEvent *)event {
    if (!_dragging) return;
    [[NSCursor resizeLeftRightCursor] set];
    [_delegate resizeHandleDraggedBy:[NSEvent mouseLocation].x - _startX];
}

- (void)mouseUp:(NSEvent *)event {
    if (!_dragging) return;
    _dragging = NO;
    [_delegate resizeHandleEndedDrag];
    NSPoint p = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(p, self.bounds)) [[NSCursor arrowCursor] set];
}

@end

// The strip that extends the sidebar material up behind the traffic lights.
@interface DittyPassthroughEffectView : NSVisualEffectView
@end

@implementation DittyPassthroughEffectView
- (NSView *)hitTest:(NSPoint)point {
    return nil;
}
@end

// }}}

// Controller {{{

static NSString *const kCellHeader = @"ditty-header";
static NSString *const kCellProject = @"ditty-project";
static NSString *const kCellSection = @"ditty-section";
static NSString *const kCellTab = @"ditty-tab";
static NSString *const kRowView = @"ditty-row";

static const CGFloat kMinSidebarWidth = 150;
static const CGFloat kMaxSidebarWidth = 600;
// Dragging the edge narrower than this collapses the sidebar, like Finder.
static const CGFloat kCollapseThreshold = 90;
// Leave at least this much room for the terminal.
static const CGFloat kMinTerminalWidth = 240;

@interface DittySidebarController : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate, NSTextFieldDelegate, DittyOutlineViewClickHandler, DittyResizeHandleDelegate> {
    NSWindow *_window;
    unsigned long long _osWindowId;
    DittyResizeHandle *_resizeHandle;
    NSButton *_toggleButton;
    BOOL _visible;
    BOOL _sidebarHidden;
    // Live resize state
    BOOL _dragging;
    BOOL _dragCollapses;
    CGFloat _dragStartWidth;
    CGFloat _liveWidth;
    BOOL _liveResizeScheduled;
    NSVisualEffectView *_container;
    NSVisualEffectView *_titlebarStrip;
    NSScrollView *_scrollView;
    DittyOutlineView *_outline;
    DittySidebarNode *_tree;    // invisible root, owns the group headers
    DittySidebarNode *_root;    // the "Projects" group (not retained)
    DittySidebarNode *_recent;  // the "Recent" group of closed projects, may be nil (not retained)
    NSMutableSet<NSString *> *_collapsedSections;
    NSString *_lastJSON;
    CGFloat _lastWidth;
    BOOL _showAddButton;
    BOOL _suppressSelection;
    BOOL _suppressExpansion;
    NSArray<NSDictionary *> *_templates;  // [{name, path}]
    NSString *_templatesDir;
    NSString *_pendingRenameProjectId;  // rename requested before the row existed
    // A project row the user clicked stays selected (like a folder in Finder)
    // until the active tab changes or moves to another project.
    NSString *_selectedProjectId;
    NSString *_selectedProjectActiveTab;  // active tab id when it was selected, nil while switching to it
    // Inline rename state
    DittySidebarNode *_renamingNode;
    NSTextField *_renamingField;
    NSResponder *_previousResponder;
    BOOL _renameCancelled;
    NSString *_pendingJSON;
    CGFloat _pendingWidth;
}
- (instancetype)initWithWindow:(NSWindow *)window width:(CGFloat)width;
- (void)setOSWindowId:(unsigned long long)os_window_id;
- (void)finishRename:(BOOL)commit;
- (void)beginRenameProjectWithId:(NSString *)project_id;
- (void)installToggleButton;
- (void)updateToggleButton;
- (void)layoutToggleButton;
- (void)attach;
- (BOOL)isAttached;
- (void)updateWithJSON:(NSString *)json width:(CGFloat)width;
- (void)setVisible:(BOOL)visible;
@end

@implementation DittySidebarController

// Setup {{{

static NSVisualEffectView *
make_sidebar_material(Class cls, NSRect frame) {
    NSVisualEffectView *v = [[cls alloc] initWithFrame:frame];
    if (@available(macOS 10.14, *)) {
        v.material = NSVisualEffectMaterialSidebar;
    }
    v.blendingMode = NSVisualEffectBlendingModeBehindWindow;
    // Dim with the window like every other macOS sidebar.
    v.state = NSVisualEffectStateFollowsWindowActiveState;
    v.wantsLayer = YES;
    return v;
}

static NSView *
make_separator(NSRect frame) {
    NSBox *sep = [[NSBox alloc] initWithFrame:frame];
    sep.boxType = NSBoxCustom;
    sep.borderWidth = 0;
    sep.fillColor = [NSColor separatorColor];
    sep.autoresizingMask = NSViewHeightSizable | NSViewMinXMargin;
    return sep;
}

- (instancetype)initWithWindow:(NSWindow *)window width:(CGFloat)width {
    self = [super init];
    if (self == nil) return nil;
    _window = window;
    _collapsedSections = [[NSMutableSet alloc] init];
    _lastWidth = width;
    _showAddButton = YES;
    _visible = YES;

    _container = make_sidebar_material([NSVisualEffectView class], NSMakeRect(0, 0, width, window.contentView.bounds.size.height));
    _container.autoresizingMask = NSViewHeightSizable | NSViewMaxXMargin;

    NSButton *close_button = [window standardWindowButton:NSWindowCloseButton];
    NSView *titlebar_view = close_button.superview;
    if (titlebar_view != nil) {
        CGFloat th = titlebar_view.bounds.size.height;
        _titlebarStrip = make_sidebar_material([DittyPassthroughEffectView class], NSMakeRect(0, 0, width, th));
        _titlebarStrip.autoresizingMask = NSViewHeightSizable;
        NSView *tb_separator = make_separator(NSMakeRect(width - 1, 0, 1, th));
        [_titlebarStrip addSubview:tb_separator];
        [tb_separator release];
        [titlebar_view addSubview:_titlebarStrip positioned:NSWindowBelow relativeTo:close_button];
    }

    NSView *separator = make_separator(NSMakeRect(width - 1, 0, 1, _container.bounds.size.height));
    [_container addSubview:separator];
    [separator release];

    NSRect scroll_frame = _container.bounds;
    scroll_frame.size.width -= 1;  // keep clear of the separator
    _scrollView = [[NSScrollView alloc] initWithFrame:scroll_frame];
    _scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _scrollView.drawsBackground = NO;
    _scrollView.hasVerticalScroller = YES;
    _scrollView.hasHorizontalScroller = NO;
    _scrollView.autohidesScrollers = YES;
    _scrollView.borderType = NSNoBorder;
    _scrollView.automaticallyAdjustsContentInsets = NO;
    _scrollView.contentInsets = NSEdgeInsetsMake(2, 0, 8, 0);

    _outline = [[DittyOutlineView alloc] initWithFrame:NSMakeRect(0, 0, scroll_frame.size.width, 0)];
    _outline.clickHandler = self;
    _outline.headerView = nil;
    _outline.backgroundColor = [NSColor clearColor];
    if (@available(macOS 11.0, *)) {
        _outline.style = NSTableViewStyleSourceList;
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        _outline.selectionHighlightStyle = NSTableViewSelectionHighlightStyleSourceList;
#pragma clang diagnostic pop
    }
    // Follow the "Sidebar icon size" setting in System Settings > Appearance.
    _outline.rowSizeStyle = NSTableViewRowSizeStyleDefault;
    _outline.floatsGroupRows = NO;
    _outline.allowsEmptySelection = YES;
    _outline.allowsMultipleSelection = NO;
    _outline.allowsColumnReordering = NO;
    _outline.allowsColumnResizing = NO;
    // Keyboard focus stays in the terminal.
    _outline.refusesFirstResponder = YES;
    _outline.focusRingType = NSFocusRingTypeNone;
    _outline.autoresizesOutlineColumn = NO;
    _outline.columnAutoresizingStyle = NSTableViewLastColumnOnlyAutoresizingStyle;
    _outline.target = self;
    _outline.doubleAction = @selector(rowDoubleClicked:);

    NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"main"];
    column.resizingMask = NSTableColumnAutoresizingMask;
    column.width = scroll_frame.size.width;
    [_outline addTableColumn:column];
    _outline.outlineTableColumn = column;
    [column release];

    NSMenu *menu = [[NSMenu alloc] initWithTitle:@"Sidebar"];
    menu.delegate = self;
    _outline.menu = menu;
    [menu release];

    _outline.dataSource = self;
    _outline.delegate = self;
    _scrollView.documentView = _outline;
    [_container addSubview:_scrollView];
    // Keep the column exactly as wide as the visible area. Otherwise the
    // source list padding makes the rows wider than the sidebar and their
    // trailing end (close buttons, counts) is clipped. The visible width also
    // changes when legacy scroll bars appear or disappear.
    _scrollView.contentView.postsFrameChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fitColumn) name:NSViewFrameDidChangeNotification object:_scrollView.contentView];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(fitColumn) name:NSPreferredScrollerStyleDidChangeNotification object:nil];

    _resizeHandle = [[DittyResizeHandle alloc] initWithFrame:NSMakeRect(width - 4, 0, 4, _container.bounds.size.height)];
    _resizeHandle.autoresizingMask = NSViewHeightSizable | NSViewMinXMargin;
    _resizeHandle.delegate = self;
    [_container addSubview:_resizeHandle positioned:NSWindowAbove relativeTo:nil];

    [self installToggleButton];
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSNotificationName name in @[NSWindowDidResizeNotification, NSWindowDidEnterFullScreenNotification, NSWindowDidExitFullScreenNotification]) {
        [nc addObserver:self selector:@selector(windowGeometryChanged:) name:name object:window];
    }
    return self;
}

- (void)fitColumn {
    NSTableColumn *column = _outline.tableColumns.firstObject;
    if (column == nil) return;
    CGFloat available = _scrollView.contentView.bounds.size.width - _outline.intercellSpacing.width;
    if (available > 20 && fabs(column.width - available) > 0.5) column.width = available;
    [_outline sizeLastColumnToFit];
}

- (void)setOSWindowId:(unsigned long long)os_window_id {
    _osWindowId = os_window_id;
}

// Titlebar toggle button {{{

- (void)installToggleButton {
    NSButton *zoom = [_window standardWindowButton:NSWindowZoomButton];
    NSView *titlebar_view = zoom.superview;
    if (titlebar_view == nil) return;  // no titlebar (hide_window_decorations)
    _toggleButton = [[NSButton alloc] initWithFrame:NSMakeRect(0, 0, 28, 22)];
    _toggleButton.bordered = NO;
    _toggleButton.imagePosition = NSImageOnly;
    _toggleButton.imageScaling = NSImageScaleNone;
    _toggleButton.focusRingType = NSFocusRingTypeNone;
    _toggleButton.refusesFirstResponder = YES;
    [_toggleButton setButtonType:NSButtonTypeMomentaryChange];
    _toggleButton.image = symbol_image_with_weight(@[@"sidebar.left"], 15, NSFontWeightRegular, NSImageNameListViewTemplate);
    if (@available(macOS 10.14, *)) _toggleButton.contentTintColor = [NSColor secondaryLabelColor];
    _toggleButton.target = self;
    _toggleButton.action = @selector(toggleSidebarClicked:);
    _toggleButton.autoresizingMask = NSViewMaxXMargin | NSViewMinYMargin;
    [titlebar_view addSubview:_toggleButton];
    [self updateToggleButton];
    [self layoutToggleButton];
}

- (void)layoutToggleButton {
    if (_toggleButton == nil) return;
    NSButton *zoom = [_window standardWindowButton:NSWindowZoomButton];
    if (zoom == nil || zoom.superview != _toggleButton.superview) {
        _toggleButton.hidden = YES;
        return;
    }
    NSRect z = zoom.frame;
    NSSize size = _toggleButton.frame.size;
    _toggleButton.frame = NSMakeRect(round(NSMaxX(z) + 14), round(NSMidY(z) - size.height / 2), size.width, size.height);
    _toggleButton.hidden = !_visible;
}

- (void)updateToggleButton {
    if (_toggleButton == nil) return;
    NSString *label = _sidebarHidden ? @"Show Sidebar" : @"Hide Sidebar";
    _toggleButton.toolTip = [label stringByAppendingString:@" (⌃⌘S)"];
    _toggleButton.accessibilityLabel = label;
}

- (void)windowGeometryChanged:(NSNotification *)notification {
    [self layoutToggleButton];
    // AppKit repositions the traffic lights after these notifications.
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        [self layoutToggleButton];
        [self release];
    });
}

- (void)toggleSidebarClicked:(id)sender {
    dispatch_python("sidebar_hidden", nil, (long long)_osWindowId, _sidebarHidden ? @"0" : @"1");
}

// }}}

// Resizing {{{

- (CGFloat)maxSidebarWidth {
    CGFloat available = _window.contentView.bounds.size.width - kMinTerminalWidth;
    return MAX(kMinSidebarWidth, MIN(kMaxSidebarWidth, available));
}

- (void)setDragCollapsePreview:(BOOL)collapses {
    if (_dragCollapses == collapses) return;
    _dragCollapses = collapses;
    CGFloat alpha = collapses ? 0.4 : 1.0;
    _container.animator.alphaValue = alpha;
    if (_titlebarStrip != nil) _titlebarStrip.animator.alphaValue = alpha;
}

- (void)resizeHandleBeganDrag {
    _dragging = YES;
    _dragCollapses = NO;
    _dragStartWidth = _container.frame.size.width;
}

- (void)resizeHandleDraggedBy:(CGFloat)dx {
    if (!_dragging) return;
    CGFloat raw = _dragStartWidth + dx;
    [self setDragCollapsePreview:raw < kCollapseThreshold];
    CGFloat w = round(MAX(kMinSidebarWidth, MIN([self maxSidebarWidth], raw)));
    if (w == _container.frame.size.width) return;
    [self resizeToWidth:w];
    [self scheduleLiveResize:w];
}

- (void)scheduleLiveResize:(CGFloat)width {
    _liveWidth = width;
    if (_liveResizeScheduled) return;
    _liveResizeScheduled = YES;
    // Coalesce drag events so the terminal is re-laid out at most ~30 times a second.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30 * NSEC_PER_MSEC)), dispatch_get_main_queue(), ^{
        self->_liveResizeScheduled = NO;
        if (!self->_dragging) return;
        dispatch_python("sidebar_resize", nil, (long long)self->_osWindowId, [NSString stringWithFormat:@"%d", (int)self->_liveWidth]);
    });
}

- (void)resizeHandleEndedDrag {
    if (!_dragging) return;
    _dragging = NO;
    BOOL collapse = _dragCollapses;
    [self setDragCollapsePreview:NO];
    if (collapse) {
        // Keep the previous width for when the sidebar is shown again.
        [self resizeToWidth:_dragStartWidth];
        // Hide first so the terminal is not re-laid out at the old width in between.
        dispatch_python("sidebar_hidden", nil, (long long)_osWindowId, @"1");
        dispatch_python("sidebar_width", nil, (long long)_osWindowId, [NSString stringWithFormat:@"%d", (int)_dragStartWidth]);
    } else {
        dispatch_python("sidebar_width", nil, (long long)_osWindowId, [NSString stringWithFormat:@"%d", (int)_container.frame.size.width]);
    }
}

- (void)resizeHandleDoubleClicked {
    // Double-clicking the divider restores the configured default width.
    dispatch_python("sidebar_width", nil, (long long)_osWindowId, @"0");
}

// }}}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _resizeHandle.delegate = nil;
    [_resizeHandle release];
    [_toggleButton removeFromSuperview];
    [_toggleButton release];
    _outline.dataSource = nil;
    _outline.delegate = nil;
    _outline.clickHandler = nil;
    if (_renamingField != nil) _renamingField.delegate = nil;
    [_titlebarStrip removeFromSuperview];
    [_container removeFromSuperview];
    [_container release];
    [_titlebarStrip release];
    [_scrollView release];
    [_outline release];
    [_tree release];
    [_collapsedSections release];
    [_lastJSON release];
    [_templates release];
    [_templatesDir release];
    [_pendingRenameProjectId release];
    [_selectedProjectId release];
    [_selectedProjectActiveTab release];
    [_pendingJSON release];
    [_renamingNode release];
    [_renamingField release];
    [_previousResponder release];
    [super dealloc];
}

- (BOOL)isAttached {
    return _container.superview != nil;
}

- (void)attach {
    NSView *content = _window.contentView;
    if (content == nil) return;
    _container.frame = NSMakeRect(0, 0, _container.frame.size.width, content.bounds.size.height);
    [content addSubview:_container positioned:NSWindowAbove relativeTo:nil];
    [self fitColumn];
}

- (void)applyVisibility {
    BOOL show = _visible && !_sidebarHidden;
    _container.hidden = !show;
    if (_titlebarStrip != nil) _titlebarStrip.hidden = !show;
    [self updateToggleButton];
    [self layoutToggleButton];
}

// Visibility of the whole feature (off when the sidebar is disabled).
- (void)setVisible:(BOOL)visible {
    if (_visible == visible) return;
    _visible = visible;
    [self applyVisibility];
}

// The user facing show/hide state.
- (void)setSidebarHidden:(BOOL)hidden {
    if (_sidebarHidden == hidden) return;
    _sidebarHidden = hidden;
    if (hidden && _renamingField != nil) [self finishRename:YES];
    [self applyVisibility];
}

- (void)resizeToWidth:(CGFloat)width {
    NSRect f = _container.frame;
    if (f.size.width == width) return;
    f.size.width = width;
    _container.frame = f;
    if (_titlebarStrip != nil) {
        NSRect tf = _titlebarStrip.frame;
        tf.size.width = width;
        if (_titlebarStrip.superview != nil) tf.size.height = _titlebarStrip.superview.bounds.size.height;
        _titlebarStrip.frame = tf;
    }
    [self fitColumn];
}

// }}}

// Data {{{

// "5m ago", "2d ago" for the Recent list
static NSString *
relative_time(double timestamp) {
    if (timestamp <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:timestamp];
    if (@available(macOS 10.15, *)) {
        static NSRelativeDateTimeFormatter *formatter = nil;
        if (formatter == nil) {
            formatter = [[NSRelativeDateTimeFormatter alloc] init];
            formatter.unitsStyle = NSRelativeDateTimeFormatterUnitsStyleAbbreviated;
            formatter.dateTimeStyle = NSRelativeDateTimeFormatterStyleNumeric;
        }
        if (-[date timeIntervalSinceNow] < 60) return @"now";
        return [formatter localizedStringForDate:date relativeToDate:[NSDate date]];
    }
    return @"";
}

static DittySidebarNode *
make_group(NSString *key, NSString *title, DittySidebarNode *parent) {
    DittySidebarNode *ans = [[[DittySidebarNode alloc] init] autorelease];
    ans.kind = @"header";
    ans.key = key;
    ans.title = title;
    ans.expanded = YES;
    ans.parent = parent;
    return ans;
}

// Builds an invisible root holding the "Projects" group (open projects, their
// tabs and tabs outside any project) and, when there are any, the "Recent"
// group of closed projects.
- (DittySidebarNode *)treeFromRows:(NSArray *)rows {
    DittySidebarNode *tree = [[[DittySidebarNode alloc] init] autorelease];
    tree.kind = @"root";
    tree.key = @"root";
    DittySidebarNode *header = make_group(@"header", @"Projects", tree);
    DittySidebarNode *recent = make_group(@"recent", @"Recent", tree);
    _showAddButton = NO;
    DittySidebarNode *container = nil;
    for (id raw in rows) {
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *row = raw;
        NSString *kind = string_value(row[@"kind"]);
        if ([kind isEqualToString:@"new_project"]) {
            _showAddButton = YES;
            continue;
        }
        DittySidebarNode *node = [[DittySidebarNode alloc] init];
        node.kind = kind;
        node.ident = string_value(row[@"id"]);
        node.projectId = string_value(row[@"project_id"]);
        node.title = string_value(row[@"title"]);
        node.root = string_value(row[@"root"]);
        node.active = bool_value(row[@"active"]);
        node.expanded = bool_value(row[@"expanded"]);
        node.count = integer_value(row[@"count"]);
        node.customTitle = bool_value(row[@"custom_title"]);
        node.sshRemembered = bool_value(row[@"ssh"]);
        node.sessionPath = string_value(row[@"session_path"]);
        node.lastOpened = [row[@"last_opened"] respondsToSelector:@selector(doubleValue)] ? [row[@"last_opened"] doubleValue] : 0;
        // Rows without the flag (older payloads) count as open
        node.projectOpen = row[@"open"] == nil || bool_value(row[@"open"]);
        if ([node isProject] && !node.projectOpen) {
            node.key = [@"p:" stringByAppendingString:node.ident];
            node.parent = recent;
            [recent.children addObject:node];
            container = nil;
        } else if ([node isProject] || [node isSection]) {
            node.key = [node isProject] ? [@"p:" stringByAppendingString:node.ident] : [@"s:" stringByAppendingString:node.title];
            if ([node isSection]) node.expanded = ![_collapsedSections containsObject:node.key];
            node.parent = header;
            [header.children addObject:node];
            container = node;
        } else if ([node isTab]) {
            node.key = [@"t:" stringByAppendingString:node.ident];
            DittySidebarNode *parent = container != nil ? container : header;
            node.parent = parent;
            [parent.children addObject:node];
        }
        [node release];
    }
    [tree.children addObject:header];
    if (recent.children.count) [tree.children addObject:recent];
    return tree;
}

- (void)updateWithJSON:(NSString *)json width:(CGFloat)width {
    if (_renamingNode != nil) {
        // Reloading would tear down the field editor; apply once editing ends.
        [_pendingJSON release];
        _pendingJSON = [json copy];
        _pendingWidth = width;
        return;
    }
    if (_lastJSON != nil && [json isEqualToString:_lastJSON] && width == _lastWidth) return;
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    if (data == nil) return;
    NSError *error = nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
    if (![parsed isKindOfClass:[NSDictionary class]]) {
        NSLog(@"ditty sidebar: ignoring invalid payload: %@", error);
        return;
    }
    NSArray *rows = ((NSDictionary *)parsed)[@"rows"];
    if (![rows isKindOfClass:[NSArray class]]) return;
    [_lastJSON release];
    _lastJSON = [json copy];
    _lastWidth = width;
    // While dragging, the drag owns the width; Python lags behind it.
    if (!_dragging) [self resizeToWidth:width];
    [self setSidebarHidden:bool_value(((NSDictionary *)parsed)[@"hidden"])];
    [self updateTemplates:((NSDictionary *)parsed)[@"templates"] directory:((NSDictionary *)parsed)[@"templates_dir"]];

    BOOL old_show_add = _showAddButton;
    DittySidebarNode *tree = [self treeFromRows:rows];
    _suppressSelection = YES;
    _suppressExpansion = YES;
    if (_tree != nil && old_show_add == _showAddButton && [[_tree signature] isEqualToString:[tree signature]]) {
        // Same shape: update the values in place so that hover state,
        // running animations and scroll position are all preserved.
        [_tree copyValuesFrom:tree];
        [self reconfigureVisibleCells];
    } else {
        [_tree release];
        _tree = [tree retain];
        _root = _tree.children.count > 0 ? _tree.children[0] : nil;
        _recent = _tree.children.count > 1 ? _tree.children[1] : nil;
        [_outline reloadData];
        [self fitColumn];
    }
    [self syncExpansion];
    _suppressExpansion = NO;
    [self selectActiveRow];
    _suppressSelection = NO;
    if (_pendingRenameProjectId != nil) {
        NSString *pid = [_pendingRenameProjectId autorelease];
        _pendingRenameProjectId = nil;
        [self beginRenameProjectWithId:pid];
    }
}

- (void)updateTemplates:(id)raw directory:(id)dir {
    NSMutableArray<NSDictionary *> *ans = [NSMutableArray array];
    if ([raw isKindOfClass:[NSArray class]]) {
        for (id t in (NSArray *)raw) {
            if (![t isKindOfClass:[NSDictionary class]]) continue;
            NSString *name = string_value(((NSDictionary *)t)[@"name"]);
            NSString *path = string_value(((NSDictionary *)t)[@"path"]);
            if (name.length && path.length) [ans addObject:@{@"name": name, @"path": path}];
        }
    }
    [_templates release];
    _templates = [ans copy];
    [_templatesDir release];
    _templatesDir = [string_value(dir) copy];
    if (debug_log_path == nil && _templatesDir.length) {
        debug_log_path = [[[_templatesDir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"sidebar-debug.log"] retain];
    }
}

- (void)reconfigureVisibleCells {
    NSInteger n = _outline.numberOfRows;
    for (NSInteger row = 0; row < n; row++) {
        DittyCellView *cell = [_outline viewAtColumn:0 row:row makeIfNecessary:NO];
        if (cell == nil) continue;
        DittySidebarNode *node = [_outline itemAtRow:row];
        if (node != nil) [self configureCell:cell forNode:node];
    }
}

- (BOOL)wantsExpanded:(DittySidebarNode *)node {
    if ([node isSection]) return ![_collapsedSections containsObject:node.key];
    return node.expanded;
}

- (void)syncExpansion {
    if (_root == nil) return;
    if (![_outline isItemExpanded:_root]) [_outline expandItem:_root];
    if (_recent != nil) {
        BOOL want = ![_collapsedSections containsObject:_recent.key];
        if (want != [_outline isItemExpanded:_recent]) {
            if (want) [_outline expandItem:_recent];
            else [_outline collapseItem:_recent];
        }
    }
    for (DittySidebarNode *node in _root.children) {
        if (node.children.count == 0) continue;
        BOOL want = [self wantsExpanded:node];
        if (want != [_outline isItemExpanded:node]) {
            if (want) [_outline expandItem:node];
            else [_outline collapseItem:node];
        }
    }
}

- (DittySidebarNode *)activeTabNode {
    for (DittySidebarNode *container in _root.children) {
        if ([container isTab]) {
            if (container.active) return container;
            continue;
        }
        for (DittySidebarNode *tab in container.children) {
            if (tab.active) return tab;
        }
    }
    return nil;
}

- (void)setSelectedProject:(NSString *)project_id activeTab:(NSString *)tab_id {
    if (project_id != _selectedProjectId) {
        [_selectedProjectId release];
        _selectedProjectId = [project_id copy];
    }
    if (tab_id != _selectedProjectActiveTab) {
        [_selectedProjectActiveTab release];
        _selectedProjectActiveTab = [tab_id copy];
    }
}

- (DittySidebarNode *)projectNodeWithId:(NSString *)project_id {
    for (DittySidebarNode *group in _tree.children) {
        for (DittySidebarNode *node in group.children) {
            if ([node isProject] && [node.ident isEqualToString:project_id]) return node;
        }
    }
    return nil;
}

// The selected project row, if the user's project selection is still valid.
- (DittySidebarNode *)stickyProjectForActiveTab:(DittySidebarNode *)active {
    if (_selectedProjectId == nil) return nil;
    DittySidebarNode *project = [self projectNodeWithId:_selectedProjectId];
    BOOL valid = project != nil;
    if (valid && active != nil) {
        if (active.parent != project) {
            // Still switching to the project (it may not have opened yet),
            // otherwise the user went elsewhere.
            valid = _selectedProjectActiveTab == nil;
        } else if (_selectedProjectActiveTab == nil) {
            // The switch to the project completed; remember its active tab
            [self setSelectedProject:_selectedProjectId activeTab:active.ident];
        } else if (![_selectedProjectActiveTab isEqualToString:active.ident]) {
            valid = NO;  // the user switched tabs, e.g. with the keyboard
        }
    }
    if (!valid) {
        [self setSelectedProject:nil activeTab:nil];
        return nil;
    }
    return project;
}

- (void)selectActiveRow {
    BOOL old = _suppressSelection;
    _suppressSelection = YES;
    DittySidebarNode *active = [self activeTabNode];
    DittySidebarNode *sticky = [self stickyProjectForActiveTab:active];
    NSInteger row = -1;
    if (sticky != nil) {
        row = [_outline rowForItem:sticky];
    } else if (active != nil) {
        row = [_outline rowForItem:active];
        // The active tab is inside a collapsed project: highlight the project.
        if (row < 0 && active.parent != nil && ![active.parent isHeader]) row = [_outline rowForItem:active.parent];
    }
    if (row >= 0) {
        if (_outline.selectedRow != row) [_outline selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
        [_outline scrollRowToVisible:row];
    } else {
        [_outline deselectAll:nil];
    }
    _suppressSelection = old;
}

- (DittySidebarNode *)nodeAtRow:(NSInteger)row {
    if (row < 0 || row >= _outline.numberOfRows) return nil;
    id item = [_outline itemAtRow:row];
    return [item isKindOfClass:[DittySidebarNode class]] ? item : nil;
}

// }}}

// NSOutlineViewDataSource {{{

- (NSInteger)outlineView:(NSOutlineView *)outlineView numberOfChildrenOfItem:(id)item {
    if (item == nil) return _tree != nil ? (NSInteger)_tree.children.count : 0;
    return (NSInteger)((DittySidebarNode *)item).children.count;
}

- (id)outlineView:(NSOutlineView *)outlineView child:(NSInteger)index ofItem:(id)item {
    if (item == nil) return _tree.children[(NSUInteger)index];
    return ((DittySidebarNode *)item).children[(NSUInteger)index];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView isItemExpandable:(id)item {
    DittySidebarNode *node = item;
    return ![node isTab] && node.children.count > 0;
}

// }}}

// NSOutlineViewDelegate {{{

- (BOOL)outlineView:(NSOutlineView *)outlineView isGroupItem:(id)item {
    return [(DittySidebarNode *)item isHeader];
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldShowOutlineCellForItem:(id)item {
    // "Projects" is permanently expanded, so it gets no Show/Hide; "Recent"
    // gets the usual Show/Hide on hover like the groups in Finder.
    return item != _root;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldCollapseItem:(id)item {
    return item != _root;
}

- (BOOL)outlineView:(NSOutlineView *)outlineView shouldSelectItem:(id)item {
    DittySidebarNode *node = item;
    return [node isProject] || [node isTab];
}

- (NSTableRowView *)outlineView:(NSOutlineView *)outlineView rowViewForItem:(id)item {
    DittyRowView *row = [outlineView makeViewWithIdentifier:kRowView owner:self];
    if (row == nil) {
        row = [[[DittyRowView alloc] initWithFrame:NSZeroRect] autorelease];
        row.identifier = kRowView;
    }
    return row;
}

- (void)outlineView:(NSOutlineView *)outlineView didAddRowView:(NSTableRowView *)rowView forRow:(NSInteger)row {
    if ([rowView isKindOfClass:[DittyRowView class]]) [(DittyRowView *)rowView refreshHoverFromMouseLocation];
}

- (NSView *)outlineView:(NSOutlineView *)outlineView viewForTableColumn:(NSTableColumn *)tableColumn item:(id)item {
    DittySidebarNode *node = item;
    NSString *identifier = kCellTab;
    if ([node isHeader]) identifier = kCellHeader;
    else if ([node isProject]) identifier = kCellProject;
    else if ([node isSection]) identifier = kCellSection;
    DittyCellView *cell = [outlineView makeViewWithIdentifier:identifier owner:self];
    if (cell == nil) {
        cell = [[[DittyCellView alloc] initWithIdentifier:identifier target:self action:@selector(accessoryClicked:)] autorelease];
    }
    [self configureCell:cell forNode:node];
    return cell;
}

- (void)configureCell:(DittyCellView *)cell forNode:(DittySidebarNode *)node {
    NSTextField *label = cell.textField;
    NSImageView *icon = cell.imageView;
    NSButton *accessory = cell.accessoryButton;
    BOOL expanded = [_outline isItemExpanded:node];
    // Do not clobber the text while the user is typing a new name.
    if (label != _renamingField) label.stringValue = node.title ? node.title : @"";
    cell.badge.stringValue = @"";
    cell.hasAccessory = NO;
    cell.accessoryOnHoverOnly = YES;

    if ([node isHeader]) {
        [cell setIconVisible:NO];
        label.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold];
        label.textColor = [NSColor secondaryLabelColor];
        cell.toolTip = nil;
        cell.hasAccessory = _showAddButton && node == _root;
        cell.accessoryOnHoverOnly = NO;
        accessory.image = symbol_image(@[@"plus"], 12, NSImageNameAddTemplate);
        accessory.toolTip = @"New Project";
        accessory.accessibilityLabel = @"New Project";
    } else if ([node isProject] && !node.projectOpen) {
        // A closed project under Recent: click to re-open it
        [cell setIconVisible:YES];
        icon.image = symbol_image(@[@"folder"], 0, NSImageNameFolder);
        if (@available(macOS 10.14, *)) icon.contentTintColor = [NSColor tertiaryLabelColor];
        label.textColor = [NSColor secondaryLabelColor];
        cell.badge.stringValue = relative_time(node.lastOpened);
        NSString *path = node.root.length ? [node.root stringByAbbreviatingWithTildeInPath] : @"";
        cell.toolTip = path.length ? [NSString stringWithFormat:@"%@\nClick to open", path] : @"Click to open";
    } else if ([node isProject]) {
        BOOL live = node.count > 0;
        [cell setIconVisible:YES];
        icon.image = symbol_image(@[@"folder"], 0, NSImageNameFolder);
        if (@available(macOS 10.14, *)) icon.contentTintColor = live ? [NSColor controlAccentColor] : [NSColor tertiaryLabelColor];
        label.textColor = live ? [NSColor labelColor] : [NSColor secondaryLabelColor];
        if (live && !expanded) cell.badge.stringValue = [NSString stringWithFormat:@"%ld", (long)node.count];
        cell.toolTip = node.root.length ? [node.root stringByAbbreviatingWithTildeInPath] : nil;
        cell.hasAccessory = YES;
        accessory.image = symbol_image(@[@"plus"], 11, NSImageNameAddTemplate);
        accessory.toolTip = @"New Tab in Project";
        accessory.accessibilityLabel = @"New Tab in Project";
    } else if ([node isSection]) {
        [cell setIconVisible:YES];
        icon.image = symbol_image(@[@"tray"], 0, NSImageNameFolder);
        if (@available(macOS 10.14, *)) icon.contentTintColor = [NSColor secondaryLabelColor];
        label.textColor = [NSColor secondaryLabelColor];
        if (!expanded && node.count > 0) cell.badge.stringValue = [NSString stringWithFormat:@"%ld", (long)node.count];
        cell.toolTip = nil;
    } else {
        [cell setIconVisible:YES];
        icon.image = symbol_image(@[@"apple.terminal", @"terminal"], 0, NSImageNameMultipleDocuments);
        if (@available(macOS 10.14, *)) icon.contentTintColor = node.active ? [NSColor controlAccentColor] : [NSColor secondaryLabelColor];
        label.textColor = [NSColor labelColor];
        cell.toolTip = node.title.length > 24 ? node.title : nil;
        cell.hasAccessory = YES;
        // Like Safari's tabs: the current tab always shows its close button
        cell.accessoryOnHoverOnly = !node.active;
        accessory.image = symbol_image(@[@"xmark"], 10, NSImageNameStopProgressTemplate);
        accessory.toolTip = @"Close Tab";
        accessory.accessibilityLabel = @"Close Tab";
    }
    [cell updateAccessoryVisibility];
}

- (void)outlineViewItemWillCollapse:(NSNotification *)notification {
    // Collapsing a project hides the selected tab; do not treat the
    // resulting selection change as a click.
    _suppressSelection = YES;
}

- (void)expansionChanged:(NSNotification *)notification expanded:(BOOL)expanded {
    DittySidebarNode *node = notification.userInfo[@"NSObject"];
    if (![node isKindOfClass:[DittySidebarNode class]]) return;
    NSInteger row = [_outline rowForItem:node];
    DittyCellView *cell = row >= 0 ? [_outline viewAtColumn:0 row:row makeIfNecessary:NO] : nil;
    if (cell != nil) [self configureCell:cell forNode:node];  // count badge
    if (_suppressExpansion) return;
    if ([node isSection] || node == _recent) {
        if (expanded) [_collapsedSections removeObject:node.key];
        else [_collapsedSections addObject:node.key];
    } else if ([node isProject] && node.expanded != expanded) {
        node.expanded = expanded;
        dispatch_python("set_expanded", node.ident, 0, expanded ? @"1" : @"0");
    }
}

- (void)outlineViewItemDidExpand:(NSNotification *)notification {
    [self expansionChanged:notification expanded:YES];
}

- (void)outlineViewItemDidCollapse:(NSNotification *)notification {
    [self expansionChanged:notification expanded:NO];
    if (!_suppressExpansion) {
        [self selectActiveRow];
        _suppressSelection = NO;
    }
}

- (void)outlineViewSelectionDidChange:(NSNotification *)notification {
    if (_suppressSelection) return;
    DittySidebarNode *node = [self nodeAtRow:_outline.selectedRow];
    if (node == nil) return;
    if ([node isProject]) {
        DittySidebarNode *active = [self activeTabNode];
        if (active != nil && active.parent == node) {
            // Already in this project: just select the row.
            [self setSelectedProject:node.ident activeTab:active.ident];
            return;
        }
        // Switch the terminal to the project but keep its row selected.
        [self setSelectedProject:node.ident activeTab:nil];
        dispatch_python("project", node.ident, 0, nil);
    } else if ([node isTab]) {
        [self setSelectedProject:nil activeTab:nil];
        if (!node.active) dispatch_python("tab", node.projectId, [node.ident longLongValue], nil);
    }
}

// }}}

// Actions {{{

- (void)accessoryClicked:(NSButton *)sender {
    DittySidebarNode *node = [self nodeAtRow:[_outline rowForView:sender]];
    if (node == nil) return;
    if (node == _root) dispatch_python("new_project", nil, 0, nil);
    else if ([node isProject]) dispatch_python("new_tab", node.ident, 0, nil);
    else if ([node isTab]) [self confirmCloseTab:node];
}

- (void)outlineViewMiddleClickedRow:(NSInteger)row {
    DittySidebarNode *node = [self nodeAtRow:row];
    if ([node isTab]) [self confirmCloseTab:node];
}

static NSString *const kDontConfirmTabCloseKey = @"DittySidebarDontConfirmTabClose";

// Ask before closing tabs from the sidebar. With "Don't ask again" checked
// once, tabs close right away from then on.
- (void)confirmClose:(NSString *)message info:(NSString *)info button:(NSString *)button then:(void (^)(void))action {
    if ([[NSUserDefaults standardUserDefaults] boolForKey:kDontConfirmTabCloseKey]) {
        action();
        return;
    }
    if (_window.attachedSheet != nil) {
        NSBeep();
        return;
    }
    void (^act)(void) = [[action copy] autorelease];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = message;
    alert.informativeText = info;
    NSButton *close = [alert addButtonWithTitle:button];
    if (@available(macOS 11.0, *)) close.hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];
    alert.showsSuppressionButton = YES;
    alert.suppressionButton.title = @"Don’t ask again";
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse code) {
        if (code == NSAlertFirstButtonReturn) {
            if (alert.suppressionButton.state == NSControlStateValueOn) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDontConfirmTabCloseKey];
            }
            act();
        }
        [alert release];
    }];
}

- (void)confirmCloseTab:(DittySidebarNode *)node {
    if (![node isTab]) return;
    NSString *project_id = [[node.projectId copy] autorelease];
    long long tab_id = [node.ident longLongValue];
    [self confirmClose:[NSString stringWithFormat:@"Close “%@”?", node.title]
                  info:@"Programs running in this tab will be terminated."
                button:@"Close Tab"
                  then:^{ dispatch_python("close_tab", project_id, tab_id, @"confirmed"); }];
}

- (BOOL)outlineViewCanRenameRow:(NSInteger)row {
    DittySidebarNode *node = [self nodeAtRow:row];
    return _renamingNode == nil && ([node isProject] || [node isTab]);
}

- (void)outlineViewSlowClickedRow:(NSInteger)row {
    if ([self outlineViewCanRenameRow:row]) [self beginRenameAtRow:row];
}

- (void)outlineViewWillShowMenu {
    if (_renamingNode != nil) [self finishRename:YES];
}

- (void)rowDoubleClicked:(id)sender {
    NSInteger row = _outline.clickedRow;
    DittySidebarNode *node = [self nodeAtRow:row];
    if ([node isProject] || [node isTab]) [self beginRenameAtRow:row];
}

- (DittySidebarNode *)menuNode:(NSMenuItem *)item {
    id obj = item.representedObject;
    return [obj isKindOfClass:[DittySidebarNode class]] ? obj : nil;
}

- (void)menuNewProject:(NSMenuItem *)item { dispatch_python("new_project", nil, 0, nil); }
- (void)menuNewTab:(NSMenuItem *)item { dispatch_python("new_tab", [self menuNode:item].ident, 0, nil); }
- (void)menuOpenProject:(NSMenuItem *)item { dispatch_python("project", [self menuNode:item].ident, 0, nil); }

- (void)menuCloseTab:(NSMenuItem *)item {
    [self confirmCloseTab:[self menuNode:item]];
}

- (void)menuRename:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    NSInteger row = node != nil ? [_outline rowForItem:node] : -1;
    if (row >= 0) [self beginRenameAtRow:row];
}

- (void)menuShowInFinder:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if (node.root.length == 0) return;
    NSURL *url = [NSURL fileURLWithPath:node.root isDirectory:YES];
    [[NSWorkspace sharedWorkspace] activateFileViewerSelectingURLs:@[url]];
}

- (void)menuCopyPath:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if (node.root.length == 0) return;
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:node.root forType:NSPasteboardTypeString];
}

- (void)menuDeleteProject:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if (![node isProject]) return;
    NSString *project_id = [[node.ident copy] autorelease];
    NSString *session_path = [[node.sessionPath copy] autorelease];
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = [NSString stringWithFormat:@"Delete “%@”?", node.title];
    NSString *tabs = node.projectOpen ? @"Its tabs will be closed and its" : @"Its";
    alert.informativeText = [NSString stringWithFormat:@"%@ saved session will be moved to the Trash. The project folder%@ is not touched.", tabs,
        node.root.length ? [NSString stringWithFormat:@" %@", [node.root stringByAbbreviatingWithTildeInPath]] : @""];
    NSButton *remove = [alert addButtonWithTitle:@"Delete"];
    if (@available(macOS 11.0, *)) remove.hasDestructiveAction = YES;
    [alert addButtonWithTitle:@"Cancel"];
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse code) {
        if (code == NSAlertFirstButtonReturn) {
            dispatch_python("delete_project", project_id, 0, nil);
            // After Python has dropped the project from its index, so that
            // nothing writes the session file again.
            dispatch_async(dispatch_get_main_queue(), ^{
                if (session_path.length == 0 || ![[NSFileManager defaultManager] fileExistsAtPath:session_path]) return;
                NSError *error = nil;
                if (![[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:session_path] resultingItemURL:nil error:&error]) {
                    sidebar_debug_log(@"could not move %@ to the Trash: %@", session_path, error);
                }
            });
        }
        [alert release];
    }];
}

static long long
tab_id_of(DittySidebarNode *node) {
    return [node isTab] ? [node.ident longLongValue] : 0;
}

- (void)dispatchTabAction:(const char *)kind item:(NSMenuItem *)item text:(NSString *)text {
    DittySidebarNode *node = [self menuNode:item];
    if ([node isTab]) dispatch_python(kind, node.projectId, tab_id_of(node), text);
}

- (void)menuDuplicateTab:(NSMenuItem *)item { [self dispatchTabAction:"duplicate_tab" item:item text:nil]; }
- (void)menuResetTabTitle:(NSMenuItem *)item { [self dispatchTabAction:"rename_tab" item:item text:@""]; }
- (void)menuDetachTab:(NSMenuItem *)item { [self dispatchTabAction:"detach_tab" item:item text:nil]; }
- (void)menuShowTabCwd:(NSMenuItem *)item { [self dispatchTabAction:"show_tab_cwd" item:item text:nil]; }
- (void)menuCopyTabCwd:(NSMenuItem *)item { [self dispatchTabAction:"copy_tab_cwd" item:item text:nil]; }
- (void)menuCloseOtherTabs:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if (![node isTab]) return;
    NSUInteger others = node.parent.children.count > 0 ? node.parent.children.count - 1 : 0;
    NSString *where = [node.parent isProject] ? [NSString stringWithFormat:@" in “%@”", node.parent.title] : @"";
    NSString *project_id = [[node.projectId copy] autorelease];
    long long tab_id = [node.ident longLongValue];
    [self confirmClose:[NSString stringWithFormat:@"Close %lu other tab%@%@?", (unsigned long)others, others == 1 ? @"" : @"s", where]
                  info:@"Programs running in those tabs will be terminated."
                button:@"Close Tabs"
                  then:^{ dispatch_python("close_other_tabs", project_id, tab_id, @"confirmed"); }];
}
- (void)menuReconnectSSH:(NSMenuItem *)item { [self dispatchTabAction:"reconnect_ssh" item:item text:nil]; }

- (void)menuMoveTab:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    if (![info isKindOfClass:[NSDictionary class]]) return;
    DittySidebarNode *tab = info[@"tab"];
    NSString *project_id = info[@"project"];
    if ([tab isTab] && project_id.length) dispatch_python("move_tab", project_id, tab_id_of(tab), nil);
}

- (void)menuCloseProject:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if ([node isProject]) dispatch_python("close_project", node.ident, 0, nil);
}

// Templates {{{

- (void)menuNewTabFromTemplate:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    if (![info isKindOfClass:[NSDictionary class]]) return;
    dispatch_python("new_tab_from_template", info[@"project"], 0, info[@"path"]);
}

- (void)menuEditTemplate:(NSMenuItem *)item {
    NSDictionary *info = item.representedObject;
    if ([info isKindOfClass:[NSDictionary class]]) dispatch_python("edit_template", nil, 0, info[@"path"]);
}

- (void)menuOpenTemplatesFolder:(NSMenuItem *)item {
    if (_templatesDir.length == 0) return;
    NSError *error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:_templatesDir withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"ditty sidebar: could not create %@: %@", _templatesDir, error);
        return;
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:_templatesDir isDirectory:YES]];
}

// A submenu listing the templates. Holding Option turns each entry into "Edit".
- (NSMenuItem *)templatesMenuItemForProject:(NSString *)project_id {
    NSMenuItem *parent = [[[NSMenuItem alloc] initWithTitle:@"New Tab from Template" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *sub = [[[NSMenu alloc] initWithTitle:@"Templates"] autorelease];
    NSString *pid = project_id ? project_id : @"";
    if (_templates.count == 0) {
        NSMenuItem *empty = [sub addItemWithTitle:@"No Templates" action:NULL keyEquivalent:@""];
        empty.enabled = NO;
    }
    NSImage *icon = symbol_image_with_weight(@[@"doc.text"], 0, NSFontWeightRegular, nil);
    for (NSDictionary *t in _templates) {
        NSDictionary *info = @{@"path": t[@"path"], @"project": pid};
        NSMenuItem *open = [sub addItemWithTitle:t[@"name"] action:@selector(menuNewTabFromTemplate:) keyEquivalent:@""];
        open.target = self;
        open.keyEquivalentModifierMask = 0;  // pairs with the Option alternate below
        open.representedObject = info;
        open.toolTip = [t[@"path"] stringByAbbreviatingWithTildeInPath];
        if (icon != nil) open.image = icon;
        NSMenuItem *edit = [sub addItemWithTitle:[NSString stringWithFormat:@"Edit “%@”", t[@"name"]] action:@selector(menuEditTemplate:) keyEquivalent:@""];
        edit.target = self;
        edit.representedObject = info;
        edit.keyEquivalentModifierMask = NSEventModifierFlagOption;
        edit.alternate = YES;
    }
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *folder = [sub addItemWithTitle:@"Open Templates Folder" action:@selector(menuOpenTemplatesFolder:) keyEquivalent:@""];
    folder.target = self;
    parent.submenu = sub;
    return parent;
}

- (BOOL)templateExists:(NSString *)name {
    for (NSDictionary *t in _templates) {
        if ([t[@"name"] caseInsensitiveCompare:name] == NSOrderedSame) return YES;
    }
    return NO;
}

static NSString *
suggested_template_name(NSString *title) {
    NSMutableString *ans = [NSMutableString stringWithString:title ? title : @""];
    [ans replaceOccurrencesOfString:@"/" withString:@"-" options:0 range:NSMakeRange(0, ans.length)];
    [ans replaceOccurrencesOfString:@":" withString:@"-" options:0 range:NSMakeRange(0, ans.length)];
    NSString *trimmed = [ans stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length > 60) trimmed = [trimmed substringToIndex:60];
    return trimmed.length ? trimmed : @"Untitled";
}

// Ask for a template name, confirm replacing an existing one, then hand the
// name to Python. kind is "save_tab_template" or "save_project_template".
- (void)promptForTemplateNameFor:(DittySidebarNode *)node kind:(const char *)kind {
    if (node == nil) return;
    NSString *project_id = [[([node isTab] ? node.projectId : node.ident) copy] autorelease];
    long long tab_id = tab_id_of(node);
    char *kind_copy = strdup(kind);
    if (kind_copy == NULL) return;

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [node isTab] ? @"Save Tab as Template" : @"Save Project as Template";
    NSString *dir = _templatesDir.length ? [_templatesDir stringByAbbreviatingWithTildeInPath] : @"the templates folder";
    alert.informativeText = [NSString stringWithFormat:@"The layout, working directories and running programs are saved to %@. Templates are listed under New Tab from Template.", dir];
    [alert addButtonWithTitle:@"Save"];
    [alert addButtonWithTitle:@"Cancel"];
    NSTextField *field = [[[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 260, 24)] autorelease];
    field.stringValue = suggested_template_name(node.title);
    field.placeholderString = @"Template name";
    alert.accessoryView = field;
    [alert layout];
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:_window completionHandler:^(NSModalResponse code) {
        NSString *name = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        [alert release];
        if (code != NSAlertFirstButtonReturn || name.length == 0) {
            free(kind_copy);
            return;
        }
        if (![self templateExists:name]) {
            dispatch_python(kind_copy, project_id, tab_id, name);
            free(kind_copy);
            return;
        }
        // The first sheet is still closing, present the confirmation after it.
        dispatch_async(dispatch_get_main_queue(), ^{
            NSAlert *confirm = [[NSAlert alloc] init];
            confirm.alertStyle = NSAlertStyleWarning;
            confirm.messageText = [NSString stringWithFormat:@"A template named “%@” already exists. Replace it?", name];
            NSButton *replace = [confirm addButtonWithTitle:@"Replace"];
            if (@available(macOS 11.0, *)) replace.hasDestructiveAction = YES;
            [confirm addButtonWithTitle:@"Cancel"];
            [confirm beginSheetModalForWindow:self->_window completionHandler:^(NSModalResponse c2) {
                if (c2 == NSAlertFirstButtonReturn) dispatch_python(kind_copy, project_id, tab_id, name);
                free(kind_copy);
                [confirm release];
            }];
        });
    }];
}

- (void)menuSaveTemplate:(NSMenuItem *)item {
    DittySidebarNode *node = [self menuNode:item];
    if ([node isTab]) [self promptForTemplateNameFor:node kind:"save_tab_template"];
    else if ([node isProject]) [self promptForTemplateNameFor:node kind:"save_project_template"];
}

// }}}

- (void)menuNewProjectFromFolder:(NSMenuItem *)item {
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseDirectories = YES;
    panel.canChooseFiles = NO;
    panel.canCreateDirectories = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Create Project";
    panel.message = @"Choose the folder for the new project";
    [panel beginSheetModalForWindow:_window completionHandler:^(NSModalResponse code) {
        if (code != NSModalResponseOK) return;
        NSURL *url = panel.URLs.firstObject;
        if (url.path.length) dispatch_python("new_project_dir", nil, 0, url.path);
    }];
}

static NSMenuItem *
add_menu_item(NSMenu *menu, NSString *title, SEL action, id target, DittySidebarNode *node) {
    NSMenuItem *item = [menu addItemWithTitle:title action:action keyEquivalent:@""];
    item.target = target;
    item.representedObject = node;
    return item;
}

static void
add_separator(NSMenu *menu) {
    if (menu.numberOfItems && !menu.itemArray.lastObject.separatorItem) [menu addItem:[NSMenuItem separatorItem]];
}

- (void)buildProjectMenu:(NSMenu *)menu node:(DittySidebarNode *)node {
    BOOL open = node.projectOpen;
    BOOL live = node.count > 0;  // has tabs in this window
    if (open) {
        add_menu_item(menu, @"New Tab", @selector(menuNewTab:), self, node);
        [menu addItem:[self templatesMenuItemForProject:node.ident]];
    } else {
        add_menu_item(menu, @"Open Project", @selector(menuOpenProject:), self, node);
    }
    add_separator(menu);
    add_menu_item(menu, @"Rename…", @selector(menuRename:), self, node);
    if (live) add_menu_item(menu, @"Save as Template…", @selector(menuSaveTemplate:), self, node);
    if (node.root.length) {
        add_separator(menu);
        add_menu_item(menu, @"Show in Finder", @selector(menuShowInFinder:), self, node);
        add_menu_item(menu, @"Copy Path", @selector(menuCopyPath:), self, node);
    }
    add_separator(menu);
    if (open) add_menu_item(menu, @"Close Project", @selector(menuCloseProject:), self, node).toolTip = @"Save the project and close its tabs. It stays under Recent.";
    add_menu_item(menu, @"Delete Project…", @selector(menuDeleteProject:), self, node);
}

- (void)buildTabMenu:(NSMenu *)menu node:(DittySidebarNode *)node {
    DittySidebarNode *parent = node.parent;
    BOOL in_project = [parent isProject];
    if (in_project) add_menu_item(menu, @"New Tab", @selector(menuNewTab:), self, parent);
    [menu addItem:[self templatesMenuItemForProject:(in_project ? parent.ident : @"")]];
    add_menu_item(menu, @"Duplicate Tab", @selector(menuDuplicateTab:), self, node);
    if (node.sshRemembered) {
        add_menu_item(menu, @"Reconnect SSH", @selector(menuReconnectSSH:), self, node).toolTip =
            @"Reconnect the windows of this tab whose ssh connection is down";
    }
    add_separator(menu);
    add_menu_item(menu, @"Rename Tab…", @selector(menuRename:), self, node);
    if (node.customTitle) add_menu_item(menu, @"Reset Tab Title", @selector(menuResetTabTitle:), self, node);
    add_menu_item(menu, @"Save as Template…", @selector(menuSaveTemplate:), self, node);

    // Move to another project
    NSMenuItem *move = [[[NSMenuItem alloc] initWithTitle:@"Move to Project" action:NULL keyEquivalent:@""] autorelease];
    NSMenu *move_menu = [[[NSMenu alloc] initWithTitle:@"Move to Project"] autorelease];
    for (DittySidebarNode *p in _root.children) {
        if (![p isProject]) continue;
        NSMenuItem *it = [move_menu addItemWithTitle:p.title action:@selector(menuMoveTab:) keyEquivalent:@""];
        it.target = self;
        it.representedObject = @{@"tab": node, @"project": p.ident};
        if (p == parent) {
            it.state = NSControlStateValueOn;
            it.action = NULL;
            it.enabled = NO;
        }
    }
    move.submenu = move_menu;
    move.enabled = move_menu.numberOfItems > 1 || (move_menu.numberOfItems == 1 && !in_project);
    [menu addItem:move];
    add_menu_item(menu, @"Move to New Window", @selector(menuDetachTab:), self, node);

    add_separator(menu);
    add_menu_item(menu, @"Show Working Directory in Finder", @selector(menuShowTabCwd:), self, node);
    add_menu_item(menu, @"Copy Working Directory", @selector(menuCopyTabCwd:), self, node);

    add_separator(menu);
    if (parent.children.count > 1) {
        add_menu_item(menu, in_project ? @"Close Other Tabs in Project" : @"Close Other Tabs", @selector(menuCloseOtherTabs:), self, node);
    }
    add_menu_item(menu, @"Close Tab", @selector(menuCloseTab:), self, node);
}

- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    NSInteger clicked = _outline.clickedRow;
    DittySidebarNode *node = [self nodeAtRow:clicked];
    @try {
        [self buildMenu:menu forNode:node];
    } @catch (NSException *e) {
        sidebar_debug_log(@"building the menu for row %ld (%@) failed: %@\n%@", (long)clicked, node.kind, e, e.callStackSymbols);
        [menu removeAllItems];
        if ([node isTab]) add_menu_item(menu, @"Close Tab", @selector(menuCloseTab:), self, node);
        add_menu_item(menu, @"Hide Sidebar", @selector(toggleSidebarClicked:), self, nil);
    }
    sidebar_debug_log(@"context menu for row %ld kind=%@ items=%ld", (long)clicked, node.kind ? node.kind : @"(none)", (long)menu.numberOfItems);
}

- (void)buildMenu:(NSMenu *)menu forNode:(DittySidebarNode *)node {
    if ([node isProject]) {
        [self buildProjectMenu:menu node:node];
    } else if ([node isTab]) {
        [self buildTabMenu:menu node:node];
    } else {
        // Header, sections and empty space
        add_menu_item(menu, @"New Project", @selector(menuNewProject:), self, nil).toolTip = @"Create a project for the working directory of the active window";
        add_menu_item(menu, @"New Project from Folder…", @selector(menuNewProjectFromFolder:), self, nil);
        add_separator(menu);
        [menu addItem:[self templatesMenuItemForProject:nil]];
    }
    add_separator(menu);
    add_menu_item(menu, @"Hide Sidebar", @selector(toggleSidebarClicked:), self, nil);
}

// }}}

// Inline rename {{{

// Called from Python right after a project is created, so the user can name it.
- (void)beginRenameProjectWithId:(NSString *)project_id {
    if (project_id.length == 0 || _sidebarHidden || !_visible) return;
    DittySidebarNode *target = nil;
    for (DittySidebarNode *node in _root.children) {
        if ([node isProject] && [node.ident isEqualToString:project_id]) {
            target = node;
            break;
        }
    }
    NSInteger row = target != nil ? [_outline rowForItem:target] : -1;
    if (row < 0) {
        // Python has not sent the new project yet; retry after the next update.
        [_pendingRenameProjectId release];
        _pendingRenameProjectId = [project_id copy];
        return;
    }
    // Let the selection changes from activating the project settle first.
    [self retain];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSInteger r = [self->_outline rowForItem:target];
        if (r >= 0) [self beginRenameAtRow:r];
        [self release];
    });
}

- (void)beginRenameAtRow:(NSInteger)row {
    if (_renamingNode != nil) return;
    DittySidebarNode *node = [self nodeAtRow:row];
    if (![node isProject] && ![node isTab]) return;
    [_outline scrollRowToVisible:row];
    DittyCellView *cell = [_outline viewAtColumn:0 row:row makeIfNecessary:YES];
    NSTextField *field = cell.textField;
    if (field == nil) return;
    _renamingNode = [node retain];
    _renamingField = [field retain];
    _renameCancelled = NO;
    [_previousResponder release];
    _previousResponder = [_window.firstResponder retain];
    field.editable = YES;
    field.selectable = YES;
    field.delegate = self;
    // Look like Finder's rename field: an opaque text box with a focus ring
    // that scrolls instead of truncating.
    field.drawsBackground = YES;
    field.backgroundColor = [NSColor textBackgroundColor];
    field.textColor = [NSColor textColor];
    field.focusRingType = NSFocusRingTypeExterior;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.scrollable = YES;
    field.cell.truncatesLastVisibleLine = NO;
    [cell.badge setHidden:YES];
    cell.accessoryButton.hidden = YES;
    field.stringValue = node.title ? node.title : @"";
    if ([_window makeFirstResponder:field]) {
        [field.currentEditor selectAll:nil];
    } else {
        [self finishRename:NO];
    }
}

- (BOOL)control:(NSControl *)control textView:(NSTextView *)textView doCommandBySelector:(SEL)selector {
    if (control != _renamingField) return NO;
    if (selector == @selector(cancelOperation:)) {
        _renameCancelled = YES;
        [self finishRename:NO];
        return YES;
    }
    return NO;
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
    if (notification.object != _renamingField) return;
    [self finishRename:!_renameCancelled];
}

- (void)finishRename:(BOOL)commit {
    if (_renamingNode == nil) return;
    DittySidebarNode *node = [_renamingNode autorelease];
    NSTextField *field = [_renamingField autorelease];
    NSResponder *previous = [_previousResponder autorelease];
    _renamingNode = nil;
    _renamingField = nil;
    _previousResponder = nil;

    NSString *name = [field.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    field.delegate = nil;
    // End editing first (handing keyboard focus back to the terminal), so the
    // field editor cannot write the typed text back after we reset it.
    NSResponder *target = previous;
    if (target == nil || target == field || target == field.currentEditor) target = _window.contentView;
    if (field.currentEditor != nil) {
        if (![_window makeFirstResponder:target]) [field abortEditing];
    }
    // Return keeps the field editor around; make sure focus leaves the sidebar.
    NSResponder *fr = _window.firstResponder;
    if (fr == field || [fr isKindOfClass:[NSText class]]) [_window makeFirstResponder:target];
    field.editable = NO;
    field.selectable = NO;
    field.drawsBackground = NO;
    field.focusRingType = NSFocusRingTypeDefault;
    field.cell.scrollable = NO;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    field.cell.truncatesLastVisibleLine = YES;
    if (commit && name.length && ![name isEqualToString:node.title]) {
        node.title = name;  // optimistic, Python will confirm
        if ([node isTab]) dispatch_python("rename_tab", node.projectId, tab_id_of(node), name);
        else dispatch_python("rename_project", node.ident, 0, name);
    }
    field.stringValue = node.title ? node.title : @"";
    // Restore colors, badge and accessory for the row
    if ([field.superview isKindOfClass:[DittyCellView class]]) [self configureCell:(DittyCellView *)field.superview forNode:node];

    if (_pendingJSON != nil) {
        // Apply on the next run loop iteration: this may be called while a
        // context menu is about to open, and reloading now would change the
        // clicked row under it.
        [self retain];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self->_pendingJSON != nil && self->_renamingNode == nil) {
                NSString *json = [self->_pendingJSON autorelease];
                self->_pendingJSON = nil;
                [self updateWithJSON:json width:self->_pendingWidth];
            }
            [self release];
        });
    }
}

// }}}

@end

// }}}

// C API {{{

static char kDittySidebarControllerKey;

void
native_sidebar_set_data(void *glfw_window, unsigned long long os_window_id, const char *payload, int width_pt) {
    if (glfw_window == NULL || payload == NULL) return;
    @autoreleasepool {
        NSWindow *window = (NSWindow *)glfwGetCocoaWindow((GLFWwindow *)glfw_window);
        if (window == nil) return;
        DittySidebarController *controller = objc_getAssociatedObject(window, &kDittySidebarControllerKey);
        if (controller == nil) {
            controller = [[DittySidebarController alloc] initWithWindow:window width:(CGFloat)width_pt];
            objc_setAssociatedObject(window, &kDittySidebarControllerKey, controller, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            [controller attach];
            [controller release];
        } else if (![controller isAttached]) {
            [controller attach];
        }
        [controller setOSWindowId:os_window_id];
        NSString *json = [NSString stringWithUTF8String:payload];
        if (json != nil) [controller updateWithJSON:json width:(CGFloat)width_pt];
        [controller setVisible:YES];
    }
}

void
native_sidebar_begin_rename_project(void *glfw_window, unsigned long long os_window_id, const char *project_id) {
    if (glfw_window == NULL || project_id == NULL) return;
    @autoreleasepool {
        NSWindow *window = (NSWindow *)glfwGetCocoaWindow((GLFWwindow *)glfw_window);
        if (window == nil) return;
        DittySidebarController *controller = objc_getAssociatedObject(window, &kDittySidebarControllerKey);
        if (controller == nil) return;
        [controller setOSWindowId:os_window_id];
        NSString *pid = [NSString stringWithUTF8String:project_id];
        if (pid != nil) [controller beginRenameProjectWithId:pid];
    }
}

void
native_sidebar_set_visible(void *glfw_window, int visible) {
    if (glfw_window == NULL) return;
    @autoreleasepool {
        NSWindow *window = (NSWindow *)glfwGetCocoaWindow((GLFWwindow *)glfw_window);
        if (window == nil) return;
        DittySidebarController *controller = objc_getAssociatedObject(window, &kDittySidebarControllerKey);
        if (controller != nil) [controller setVisible:visible ? YES : NO];
    }
}

// }}}

#endif
