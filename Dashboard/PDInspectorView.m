#import "PDInspectorView.h"
#import "PDTheme.h"

@interface PDInspectorView () <NSTableViewDataSource, NSTableViewDelegate>
@end

@implementation PDInspectorView
{
  NSTextField *_title;
  NSTextView *_text;
  NSScrollView *_textScroll;
  NSTableView *_frames;
  NSScrollView *_framesScroll;
  NSButton *_sourceLines;
  GSPProcess *_process;
  NSMutableArray *_symbols;     /* GSPSymbol */
  NSMutableArray *_addresses;   /* NSNumber */
  NSMutableArray *_lines;       /* NSString or NSNull */
}

- (instancetype) initWithFrame: (NSRect)frame
{
  if ((self = [super initWithFrame: frame]) != nil)
    {
      CGFloat w = frame.size.width, h = frame.size.height;

      _title = [[NSTextField alloc] initWithFrame: NSMakeRect(6, h - 26, w - 12, 20)];
      [_title setEditable: NO];
      [_title setSelectable: YES];
      [_title setBezeled: NO];
      [_title setDrawsBackground: NO];
      [_title setFont: [PDTheme boldLabelFont]];
      [_title setStringValue: @"Extended Detail"];
      [_title setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
      [self addSubview: _title];

      _textScroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(4, h - 120, w - 8, 92)];
      [_textScroll setHasVerticalScroller: YES];
      [_textScroll setBorderType: NSBezelBorder];
      [_textScroll setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
      _text = [[NSTextView alloc] initWithFrame: [[_textScroll contentView] bounds]];
      [_text setEditable: NO];
      [_text setSelectable: YES];
      [_text setFont: [PDTheme smallFont]];
      [_text setAutoresizingMask: NSViewWidthSizable];
      [_textScroll setDocumentView: _text];
      [self addSubview: _textScroll];

      _sourceLines = [[NSButton alloc] initWithFrame: NSMakeRect(4, h - 146, w - 8, 20)];
      [_sourceLines setButtonType: NSSwitchButton];
      [_sourceLines setTitle: @"Show source lines"];
      [_sourceLines setFont: [PDTheme smallFont]];
      [_sourceLines setTarget: self];
      [_sourceLines setAction: @selector(toggleLines:)];
      [_sourceLines setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
      [self addSubview: _sourceLines];

      _framesScroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(4, 4, w - 8, h - 154)];
      [_framesScroll setHasVerticalScroller: YES];
      [_framesScroll setHasHorizontalScroller: YES];
      [_framesScroll setBorderType: NSBezelBorder];
      [_framesScroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
      _frames = [[NSTableView alloc] initWithFrame: [[_framesScroll contentView] bounds]];
      NSTableColumn *sym = [[NSTableColumn alloc] initWithIdentifier: @"symbol"];
      [[sym headerCell] setStringValue: @"Stack Trace"];
      [sym setWidth: 250];
      [sym setEditable: NO];
      [_frames addTableColumn: sym];
      NSTableColumn *lib = [[NSTableColumn alloc] initWithIdentifier: @"library"];
      [[lib headerCell] setStringValue: @"Library"];
      [lib setWidth: 150];
      [lib setEditable: NO];
      [_frames addTableColumn: lib];
      NSTableColumn *src = [[NSTableColumn alloc] initWithIdentifier: @"source"];
      [[src headerCell] setStringValue: @"Source"];
      [src setWidth: 140];
      [src setEditable: NO];
      [_frames addTableColumn: src];
      [_frames setDataSource: self];
      [_frames setDelegate: self];
      [_frames setUsesAlternatingRowBackgroundColors: YES];
      [_frames setColumnAutoresizingStyle: NSTableViewUniformColumnAutoresizingStyle];
      [_framesScroll setDocumentView: _frames];
      [self addSubview: _framesScroll];

      _symbols = [NSMutableArray array];
      _addresses = [NSMutableArray array];
      _lines = [NSMutableArray array];
    }
  return self;
}

- (void) clear
{
  [_title setStringValue: @"Extended Detail"];
  [_text setString: @""];
  [_symbols removeAllObjects];
  [_addresses removeAllObjects];
  [_lines removeAllObjects];
  [_frames reloadData];
}

- (void) showTitle: (NSString *)title text: (NSString *)text stack: (uint32_t)stack
           process: (GSPProcess *)process
{
  _process = process;
  [_title setStringValue: title ?: @"Extended Detail"];
  [_text setString: text ?: @""];
  [_symbols removeAllObjects];
  [_addresses removeAllObjects];
  [_lines removeAllObjects];
  if (stack != 0 && process != nil)
    {
      NSArray *syms = [process.symbolicator symbolsForStack: stack];
      NSArray *addrs = [process.symbolicator addressesForStack: stack];
      for (NSUInteger i = 0; i < [syms count]; i++)
        {
          [_symbols addObject: [syms objectAtIndex: i]];
          [_addresses addObject: [addrs objectAtIndex: i]];
          [_lines addObject: [NSNull null]];
        }
      if (PDIsOn(_sourceLines))
        [self loadLines];
    }
  [_frames reloadData];
}

- (void) loadLines
{
  for (NSUInteger i = 0; i < [_addresses count]; i++)
    {
      NSString *loc = [_process.symbolicator sourceLocationForFrame:
        [[_addresses objectAtIndex: i] unsignedLongLongValue] index: 0];
      [_lines replaceObjectAtIndex: i withObject: loc ? (id)loc : (id)[NSNull null]];
    }
}

- (void) toggleLines: (id)sender
{
  if (PDIsOn(_sourceLines))
    [self loadLines];
  [_frames reloadData];
}

- (NSInteger) numberOfRowsInTableView: (NSTableView *)tv
{
  return (NSInteger)[_symbols count];
}

- (id) tableView: (NSTableView *)tv objectValueForTableColumn: (NSTableColumn *)col
             row: (NSInteger)row
{
  GSPSymbol *s = [_symbols objectAtIndex: (NSUInteger)row];
  id line = [_lines objectAtIndex: (NSUInteger)row];
  NSString *ident = [col identifier];
  if ([ident isEqual: @"library"])
    return s.imageName ?: @"";
  if ([ident isEqual: @"source"])
    return line == [NSNull null] ? @"" : line;
  return s.name;
}

- (void) tableView: (NSTableView *)tv willDisplayCell: (id)cell
    forTableColumn: (NSTableColumn *)col row: (NSInteger)row
{
  GSPSymbol *s = [_symbols objectAtIndex: (NSUInteger)row];
  if ([cell respondsToSelector: @selector(setTextColor:)])
    [cell setTextColor: s.isSystem ? [PDTheme secondaryTextColor] : [PDTheme textColor]];
  if ([cell respondsToSelector: @selector(setFont:)])
    [cell setFont: [PDTheme smallFont]];

}

@end
