/* SPDX-License-Identifier: GPL-3.0-or-later */
/* PDTheme.h - colours and fonts for custom drawing.

   Window chrome uses standard controls so every GNUstep theme applies.
   Custom views (timeline, tracks) take their background, text and grid
   colours from the theme's system colours; only data series use fixed hues,
   chosen to read on light and dark themes alike.  */

#import <AppKit/AppKit.h>

@interface PDTheme : NSObject
+ (NSColor *) viewBackground;
+ (NSColor *) alternateBackground;
+ (NSColor *) headerBackground;
+ (NSColor *) gridColor;
+ (NSColor *) textColor;
+ (NSColor *) secondaryTextColor;
+ (NSColor *) selectionColor;      /* translucent overlay */
+ (NSColor *) selectedTrackColor;

+ (NSColor *) cpuColor;
+ (NSColor *) hangColor: (NSInteger)severity;
+ (NSColor *) signpostColor: (NSUInteger)index;
+ (NSColor *) allocationColor;
+ (NSColor *) leakColor;
+ (NSColor *) okColor;
+ (NSColor *) logColor;
+ (NSColor *) zombieColor;

+ (NSColor *) color: (NSColor *)c alpha: (CGFloat)a;
+ (NSFont *) smallFont;
+ (NSFont *) labelFont;
+ (NSFont *) boldLabelFont;
@end

/* Whether a check box is on.  Asks the cell: -[NSButton state] in libs-gui
   sends -state to an untyped cell with NSSwitch's unsigned
   NSControlStateValue signature, and libobjc2 logs a type mismatch for
   every call (gnustep/libs-gui, NSButton.m).  */
static inline BOOL
PDIsOn(NSButton *button)
{
  return [(NSCell *)[button cell] state] == NSOnState;
}
