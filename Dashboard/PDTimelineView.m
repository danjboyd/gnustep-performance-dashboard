#import "PDTimelineView.h"
#import "PDTheme.h"

#include <math.h>

#define HEADER_WIDTH 180.0
#define RULER_HEIGHT 22.0
#define SCROLLER_HEIGHT 15.0
#define MIN_VISIBLE 0.0005

@implementation PDTimelineView
{
  NSScroller *_scroller;
  BOOL _hasSelection;
  double _selStart, _selEnd;
  double _dragAnchor;
  BOOL _dragging;
  BOOL _dragMoved;
  NSString *_hover;
  NSPoint _hoverPoint;
}

+ (CGFloat) headerWidth { return HEADER_WIDTH; }
+ (CGFloat) rulerHeight { return RULER_HEIGHT; }

+ (NSString *) formatTime: (double)s
{
  if (s < 0)
    s = 0;
  int minutes = (int)(s / 60);
  double rest = s - minutes * 60;
  return [NSString stringWithFormat: @"%02d:%06.3f", minutes, rest];
}

- (instancetype) initWithFrame: (NSRect)frame
{
  if ((self = [super initWithFrame: frame]) != nil)
    {
      _visibleDuration = 10;
      _duration = 0;
      _scroller = [[NSScroller alloc] initWithFrame:
        NSMakeRect(HEADER_WIDTH, 0, frame.size.width - HEADER_WIDTH, SCROLLER_HEIGHT)];
      [_scroller setTarget: self];
      [_scroller setAction: @selector(scrolled:)];
      [_scroller setEnabled: YES];
      [_scroller setAutoresizingMask: NSViewWidthSizable | NSViewMaxYMargin];
      [self addSubview: _scroller];
      [self updateScroller];
    }
  return self;
}

- (BOOL) isFlipped
{
  return YES;
}

- (BOOL) acceptsFirstResponder
{
  return YES;
}

- (void) resizeSubviewsWithOldSize: (NSSize)old
{
  [super resizeSubviewsWithOldSize: old];
  NSRect b = [self bounds];
  [_scroller setFrame: NSMakeRect(HEADER_WIDTH, NSMaxY(b) - SCROLLER_HEIGHT,
                                  b.size.width - HEADER_WIDTH, SCROLLER_HEIGHT)];
}

- (NSRect) graphRect
{
  NSRect b = [self bounds];
  return NSMakeRect(HEADER_WIDTH, RULER_HEIGHT, MAX(10, b.size.width - HEADER_WIDTH),
                    MAX(0, b.size.height - RULER_HEIGHT - SCROLLER_HEIGHT));
}

- (double) timeForX: (CGFloat)x
{
  NSRect g = [self graphRect];
  return _visibleStart + (x - g.origin.x) / g.size.width * _visibleDuration;
}

- (CGFloat) xForTime: (double)t
{
  NSRect g = [self graphRect];
  return g.origin.x + (CGFloat)((t - _visibleStart) / _visibleDuration) * g.size.width;
}

- (double) clampStart: (double)start
{
  double maxStart = MAX(0, MAX(_duration, _visibleDuration) - _visibleDuration);
  if (start > maxStart)
    start = maxStart;
  return start < 0 ? 0 : start;
}

- (void) updateScroller
{
  double total = MAX(_duration, _visibleDuration);
  double proportion = total > 0 ? _visibleDuration / total : 1;
  double maxStart = total - _visibleDuration;
  double value = maxStart > 0 ? _visibleStart / maxStart : 0;
  [_scroller setKnobProportion: (CGFloat)MIN(1, proportion)];
  [_scroller setDoubleValue: value];
  [_scroller setEnabled: proportion < 0.999];
}

- (void) setDuration: (double)duration
{
  BOOL wasFit = _visibleDuration >= _duration - 1e-9 || _duration == 0;
  _duration = duration;
  if (_following)
    {
      if (_visibleDuration < 10 && duration < 10)
        _visibleDuration = 10;
      if (duration > _visibleStart + _visibleDuration)
        _visibleStart = duration - _visibleDuration;
    }
  else if (wasFit && duration > 0)
    {
      _visibleStart = 0;
      _visibleDuration = duration;
    }
  _visibleStart = [self clampStart: _visibleStart];
  [self updateScroller];
  [self setNeedsDisplay: YES];
}

- (void) setVisibleStart: (double)s
{
  _visibleStart = [self clampStart: s];
  [self updateScroller];
  [self setNeedsDisplay: YES];
}

- (void) setVisibleDuration: (double)d
{
  _visibleDuration = MAX(MIN_VISIBLE, d);
  _visibleStart = [self clampStart: _visibleStart];
  [self updateScroller];
  [self setNeedsDisplay: YES];
}

- (void) scrolled: (id)sender
{
  double total = MAX(_duration, _visibleDuration);
  double maxStart = total - _visibleDuration;
  NSScrollerPart part = [_scroller hitPart];
  double page = _visibleDuration * 0.9;
  switch (part)
    {
    case NSScrollerDecrementPage: _visibleStart -= page; break;
    case NSScrollerIncrementPage: _visibleStart += page; break;
    case NSScrollerDecrementLine: _visibleStart -= _visibleDuration * 0.1; break;
    case NSScrollerIncrementLine: _visibleStart += _visibleDuration * 0.1; break;
    default: _visibleStart = [_scroller doubleValue] * maxStart; break;
    }
  _following = NO;
  [self setVisibleStart: _visibleStart];
}

- (void) zoomBy: (double)factor around: (double)t
{
  double newDur = MAX(MIN_VISIBLE, _visibleDuration * factor);
  double total = MAX(_duration, 0.001);
  if (newDur > total)
    newDur = total;
  double frac = _visibleDuration > 0 ? (t - _visibleStart) / _visibleDuration : 0.5;
  _visibleStart = t - frac * newDur;
  _visibleDuration = newDur;
  _following = NO;
  [self setVisibleStart: _visibleStart];
}

- (void) zoomIn: (id)sender
{
  double c = _hasSelection ? (_selStart + _selEnd) / 2 : _visibleStart + _visibleDuration / 2;
  [self zoomBy: 0.5 around: c];
}

- (void) zoomOut: (id)sender
{
  [self zoomBy: 2.0 around: _visibleStart + _visibleDuration / 2];
}

- (void) zoomToFit: (id)sender
{
  _visibleStart = 0;
  _visibleDuration = MAX(_duration, 0.001);
  [self setVisibleStart: 0];
}

- (void) zoomToSelection: (id)sender
{
  if (!_hasSelection || _selEnd - _selStart < MIN_VISIBLE)
    return;
  _visibleDuration = _selEnd - _selStart;
  _following = NO;
  [self setVisibleStart: _selStart];
}

- (void) reloadData
{
  [self setNeedsDisplay: YES];
}

- (BOOL) hasSelection { return _hasSelection; }
- (double) selectionStart { return _selStart; }
- (double) selectionEnd { return _selEnd; }

- (void) setSelectionFrom: (double)start to: (double)end
{
  if (end < start)
    {
      double t = start;
      start = end;
      end = t;
    }
  _hasSelection = YES;
  _selStart = MAX(0, start);
  _selEnd = end;
  [self setNeedsDisplay: YES];
  if ([_delegate respondsToSelector: @selector(timelineSelectionDidChange:)])
    [_delegate timelineSelectionDidChange: self];
}

- (void) clearSelection
{
  if (!_hasSelection)
    return;
  _hasSelection = NO;
  [self setNeedsDisplay: YES];
  if ([_delegate respondsToSelector: @selector(timelineSelectionDidChange:)])
    [_delegate timelineSelectionDidChange: self];
}

/* ------------------------------------------------------------------ */
/* drawing                                                             */

static double
nice_step(double minStep)
{
  double p = pow(10, floor(log10(minStep)));
  double m = minStep / p;
  if (m <= 1)
    return p;
  if (m <= 2)
    return 2 * p;
  if (m <= 5)
    return 5 * p;
  return 10 * p;
}

- (void) drawRuler: (NSRect)g
{
  NSRect r = NSMakeRect(0, 0, NSMaxX(g), RULER_HEIGHT);
  NSDictionary *attrs = [NSDictionary dictionaryWithObjectsAndKeys:
    [PDTheme smallFont], NSFontAttributeName,
    [PDTheme secondaryTextColor], NSForegroundColorAttributeName, nil];

  [[PDTheme headerBackground] set];
  NSRectFill(r);
  [[PDTheme gridColor] set];
  NSRectFill(NSMakeRect(0, RULER_HEIGHT - 1, NSMaxX(g), 1));

  double secondsPerPixel = _visibleDuration / g.size.width;
  double step = nice_step(secondsPerPixel * 90);
  double first = ceil(_visibleStart / step) * step;
  for (double t = first; t <= _visibleStart + _visibleDuration; t += step)
    {
      CGFloat x = floor([self xForTime: t]) + 0.5;
      [[PDTheme gridColor] set];
      NSRectFill(NSMakeRect(x, RULER_HEIGHT - 6, 1, 6));
      NSString *label = step >= 1 ? [NSString stringWithFormat: @"%.0fs", t]
        : (step >= 0.01 ? [NSString stringWithFormat: @"%.2fs", t]
           : [NSString stringWithFormat: @"%.1fms", t * 1000]);
      [label drawAtPoint: NSMakePoint(x + 3, 3) withAttributes: attrs];
    }
  /* minor ticks */
  double minor = step / 5;
  for (double t = ceil(_visibleStart / minor) * minor; t <= _visibleStart + _visibleDuration;
       t += minor)
    {
      CGFloat x = floor([self xForTime: t]) + 0.5;
      [[PDTheme gridColor] set];
      NSRectFill(NSMakeRect(x, RULER_HEIGHT - 3, 1, 3));
    }
  NSString *title = @"Time";
  [title drawAtPoint: NSMakePoint(8, 3) withAttributes: attrs];
}

- (void) drawRect: (NSRect)dirty
{
  NSRect g = [self graphRect];
  NSUInteger n = [_dataSource numberOfTracksInTimeline: self];
  NSDictionary *titleAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
    [PDTheme boldLabelFont], NSFontAttributeName,
    [PDTheme textColor], NSForegroundColorAttributeName, nil];
  NSDictionary *subAttrs = [NSDictionary dictionaryWithObjectsAndKeys:
    [PDTheme smallFont], NSFontAttributeName,
    [PDTheme secondaryTextColor], NSForegroundColorAttributeName, nil];

  [[PDTheme viewBackground] set];
  NSRectFill([self bounds]);
  [self drawRuler: g];

  CGFloat y = RULER_HEIGHT;
  for (NSUInteger i = 0; i < n; i++)
    {
      CGFloat h = [_dataSource timeline: self heightOfTrack: i];
      NSRect header = NSMakeRect(0, y, HEADER_WIDTH, h);
      NSRect track = NSMakeRect(HEADER_WIDTH, y, g.size.width, h);

      [(i % 2 ? [PDTheme alternateBackground] : [PDTheme viewBackground]) set];
      NSRectFill(track);
      [[PDTheme headerBackground] set];
      NSRectFill(header);
      if (i == _selectedTrack)
        {
          [[PDTheme selectedTrackColor] set];
          NSRectFillUsingOperation(header, NSCompositeSourceOver);
        }
      [[_dataSource timeline: self titleOfTrack: i]
        drawInRect: NSMakeRect(10, y + 8, HEADER_WIDTH - 16, 18) withAttributes: titleAttrs];
      NSString *sub = [_dataSource timeline: self subtitleOfTrack: i];
      if (sub)
        [sub drawInRect: NSMakeRect(10, y + 28, HEADER_WIDTH - 16, h - 30)
         withAttributes: subAttrs];

      [NSGraphicsContext saveGraphicsState];
      NSRectClip(track);
      [_dataSource timeline: self drawTrack: i
                     inRect: NSInsetRect(track, 0, 3)
                       from: _visibleStart to: _visibleStart + _visibleDuration];
      [NSGraphicsContext restoreGraphicsState];

      [[PDTheme gridColor] set];
      NSRectFill(NSMakeRect(0, y + h - 1, NSMaxX(track), 1));
      y += h;
    }
  [[PDTheme gridColor] set];
  NSRectFill(NSMakeRect(HEADER_WIDTH - 1, 0, 1, y));

  /* end of data */
  if (_duration > 0 && _duration < _visibleStart + _visibleDuration)
    {
      CGFloat x = [self xForTime: _duration];
      [[PDTheme color: [PDTheme textColor] alpha: 0.08] set];
      NSRectFillUsingOperation(NSMakeRect(x, RULER_HEIGHT, NSMaxX(g) - x, y - RULER_HEIGHT),
                               NSCompositeSourceOver);
    }

  if (_hasSelection)
    {
      CGFloat x0 = MAX(g.origin.x, [self xForTime: _selStart]);
      CGFloat x1 = MIN(NSMaxX(g), [self xForTime: _selEnd]);
      if (x1 - x0 < 1)
        x1 = x0 + 1;
      if (x1 > g.origin.x && x0 < NSMaxX(g))
        {
          [[PDTheme selectionColor] set];
          NSRectFillUsingOperation(NSMakeRect(x0, 0, x1 - x0, y), NSCompositeSourceOver);
          [[NSColor selectedControlColor] set];
          NSRectFill(NSMakeRect(x0, 0, 1, y));
          NSRectFill(NSMakeRect(x1 - 1, 0, 1, y));
        }
    }

  if (_hover)
    {
      NSDictionary *a = [NSDictionary dictionaryWithObjectsAndKeys:
        [PDTheme smallFont], NSFontAttributeName,
        [NSColor controlTextColor], NSForegroundColorAttributeName, nil];
      NSSize sz = [_hover sizeWithAttributes: a];
      NSRect box = NSMakeRect(_hoverPoint.x + 12, _hoverPoint.y + 4, sz.width + 10, sz.height + 6);
      if (NSMaxX(box) > NSMaxX([self bounds]))
        box.origin.x = _hoverPoint.x - box.size.width - 8;
      [[NSColor controlBackgroundColor] set];
      NSRectFill(box);
      [[PDTheme gridColor] set];
      NSFrameRect(box);
      [_hover drawAtPoint: NSMakePoint(box.origin.x + 5, box.origin.y + 3) withAttributes: a];
    }
}

/* ------------------------------------------------------------------ */
/* events                                                              */

- (NSInteger) trackAtY: (CGFloat)y
{
  NSUInteger n = [_dataSource numberOfTracksInTimeline: self];
  CGFloat top = RULER_HEIGHT;
  for (NSUInteger i = 0; i < n; i++)
    {
      CGFloat h = [_dataSource timeline: self heightOfTrack: i];
      if (y >= top && y < top + h)
        return (NSInteger)i;
      top += h;
    }
  return -1;
}

- (void) selectTrack: (NSInteger)track
{
  if (track < 0)
    return;
  _selectedTrack = (NSUInteger)track;
  [self setNeedsDisplay: YES];
  if ([_delegate respondsToSelector: @selector(timeline:didSelectTrack:)])
    [_delegate timeline: self didSelectTrack: (NSUInteger)track];
}

- (void) mouseDown: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSInteger track = [self trackAtY: p.y];

  [[self window] makeFirstResponder: self];
  if (p.x < HEADER_WIDTH)
    {
      [self selectTrack: track];
      return;
    }
  if ([event clickCount] >= 2)
    {
      [self clearSelection];
      return;
    }
  if (track >= 0 && (NSUInteger)track != _selectedTrack)
    [self selectTrack: track];
  _dragAnchor = MAX(0, [self timeForX: p.x]);
  _dragging = YES;
  _dragMoved = NO;
}

- (void) mouseDragged: (NSEvent *)event
{
  if (!_dragging)
    return;
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  double t = MAX(0, [self timeForX: p.x]);
  if (fabs([self xForTime: t] - [self xForTime: _dragAnchor]) < 3 && !_dragMoved)
    return;
  _dragMoved = YES;
  _hasSelection = YES;
  _selStart = MIN(_dragAnchor, t);
  _selEnd = MAX(_dragAnchor, t);
  [self setNeedsDisplay: YES];
}

- (void) mouseUp: (NSEvent *)event
{
  if (!_dragging)
    return;
  _dragging = NO;
  if (_dragMoved)
    [self setSelectionFrom: _selStart to: _selEnd];
}

- (void) mouseMoved: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  NSInteger track = [self trackAtY: p.y];
  NSString *text = nil;
  if (p.x >= HEADER_WIDTH && track >= 0
      && [_dataSource respondsToSelector: @selector(timeline:describeTrack:atTime:)])
    {
      double t = [self timeForX: p.x];
      NSString *d = [_dataSource timeline: self describeTrack: (NSUInteger)track atTime: t];
      text = d ? [NSString stringWithFormat: @"%@  %@", [PDTimelineView formatTime: t], d]
               : [PDTimelineView formatTime: t];
    }
  if (text != _hover && ![text isEqual: _hover])
    {
      _hover = text;
      _hoverPoint = p;
      [self setNeedsDisplay: YES];
    }
  else if (text)
    {
      _hoverPoint = p;
      [self setNeedsDisplay: YES];
    }
}

- (void) mouseExited: (NSEvent *)event
{
  _hover = nil;
  [self setNeedsDisplay: YES];
}

- (void) viewDidMoveToWindow
{
  [super viewDidMoveToWindow];
  [[self window] setAcceptsMouseMovedEvents: YES];
  [self addTrackingRect: [self bounds] owner: self userData: NULL assumeInside: NO];
}

- (void) scrollWheel: (NSEvent *)event
{
  NSPoint p = [self convertPoint: [event locationInWindow] fromView: nil];
  CGFloat dy = [event deltaY], dx = [event deltaX];
  if ([event modifierFlags] & NSControlKeyMask)
    {
      if (dy != 0)
        [self zoomBy: dy > 0 ? 0.8 : 1.25 around: [self timeForX: p.x]];
      return;
    }
  CGFloat d = dx != 0 ? dx : dy;
  _following = NO;
  [self setVisibleStart: _visibleStart - d * _visibleDuration * 0.05];
}

- (void) keyDown: (NSEvent *)event
{
  NSString *c = [event charactersIgnoringModifiers];
  if ([c isEqual: @"+"] || [c isEqual: @"="])
    [self zoomIn: nil];
  else if ([c isEqual: @"-"])
    [self zoomOut: nil];
  else if ([c isEqual: @"0"])
    [self zoomToFit: nil];
  else if ([c isEqual: @"\e"])
    [self clearSelection];
  else
    [super keyDown: event];
}

@end
