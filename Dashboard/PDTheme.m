#import "PDTheme.h"

static NSColor *
rgb(double r, double g, double b)
{
  return [NSColor colorWithCalibratedRed: r green: g blue: b alpha: 1.0];
}

/* Theme colours may be named or pattern colours that ignore alpha;
   convert to RGB before making them translucent.  */
static NSColor *
with_alpha(NSColor *c, CGFloat a)
{
  NSColor *rgbc = [c colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
  return [(rgbc ? rgbc : c) colorWithAlphaComponent: a];
}

@implementation PDTheme

+ (NSColor *) viewBackground
{
  return [NSColor controlBackgroundColor];
}

+ (NSColor *) alternateBackground
{
  /* A faint stripe derived from the text colour works for light and dark
     themes alike.  */
  NSColor *bg = [[NSColor controlBackgroundColor] colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
  NSColor *fg = [[NSColor controlTextColor] colorUsingColorSpaceName: NSCalibratedRGBColorSpace];
  if (bg == nil || fg == nil)
    return [NSColor controlBackgroundColor];
  return [bg blendedColorWithFraction: 0.04 ofColor: fg];
}

+ (NSColor *) headerBackground
{
  return [NSColor windowBackgroundColor];
}

+ (NSColor *) gridColor
{
  return with_alpha([NSColor controlTextColor], 0.15);
}

+ (NSColor *) textColor
{
  return [NSColor controlTextColor];
}

+ (NSColor *) secondaryTextColor
{
  return with_alpha([NSColor controlTextColor], 0.6);
}

+ (NSColor *) selectionColor
{
  return with_alpha([NSColor selectedTextBackgroundColor], 0.35);
}

+ (NSColor *) selectedTrackColor
{
  return with_alpha([NSColor selectedControlColor], 0.25);
}

+ (NSColor *) cpuColor { return rgb(0.20, 0.50, 0.90); }
+ (NSColor *) allocationColor { return rgb(0.10, 0.62, 0.55); }
+ (NSColor *) leakColor { return rgb(0.86, 0.22, 0.20); }
+ (NSColor *) okColor { return rgb(0.25, 0.65, 0.30); }
+ (NSColor *) logColor { return rgb(0.55, 0.55, 0.60); }
+ (NSColor *) zombieColor { return rgb(0.60, 0.30, 0.75); }

+ (NSColor *) hangColor: (NSInteger)severity
{
  switch (severity)
    {
    case 0: return rgb(0.95, 0.70, 0.15);
    case 1: return rgb(0.93, 0.45, 0.13);
    default: return rgb(0.86, 0.22, 0.20);
    }
}

+ (NSColor *) signpostColor: (NSUInteger)index
{
  static NSArray *palette;
  if (palette == nil)
    palette = [[NSArray alloc] initWithObjects:
      rgb(0.55, 0.36, 0.85), rgb(0.20, 0.55, 0.85), rgb(0.15, 0.65, 0.45),
      rgb(0.90, 0.55, 0.15), rgb(0.85, 0.30, 0.55), rgb(0.40, 0.60, 0.20), nil];
  return [palette objectAtIndex: index % [palette count]];
}

+ (NSColor *) color: (NSColor *)c alpha: (CGFloat)a
{
  return with_alpha(c, a);
}

+ (NSFont *) smallFont
{
  return [NSFont systemFontOfSize: [NSFont smallSystemFontSize]];
}

+ (NSFont *) labelFont
{
  return [NSFont systemFontOfSize: [NSFont systemFontSize]];
}

+ (NSFont *) boldLabelFont
{
  return [NSFont boldSystemFontOfSize: [NSFont systemFontSize]];
}

@end
