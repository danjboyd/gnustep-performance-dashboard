/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDSourceWindowController.h"
#import "PDTheme.h"
#import <GSPerformance/GSPerformance.h>

@implementation PDSourceWindowController
{
  NSString *_location, *_path;
  NSTextView *_source;
  NSTextField *_caption;
  NSMutableDictionary *_mappings;
}

- (instancetype) initWithLocation: (NSString *)location
{
  NSWindow *window = [[NSWindow alloc] initWithContentRect: NSMakeRect(100, 100, 900, 620)
    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSResizableWindowMask
    backing: NSBackingStoreBuffered defer: NO];
  if ((self = [super initWithWindow: window]))
    {
      [window setReleasedWhenClosed: NO];
      [window setMinSize: NSMakeSize(600, 400)];
      [window setTitle: @"Source"];
      _location = [location copy];
      _mappings = [[[NSUserDefaults standardUserDefaults] dictionaryForKey: @"PDSourceMappings"] mutableCopy]
        ?: [NSMutableDictionary dictionary];
      NSView *view = window.contentView;
      _caption = [[NSTextField alloc] initWithFrame: NSMakeRect(10, 564, 880, 48)];
      [_caption setEditable: NO]; [_caption setSelectable: YES];
      [_caption setBezeled: NO]; [_caption setDrawsBackground: NO];
      [_caption setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
      [view addSubview: _caption];
      NSArray *titles = @[@"Locate Source…", @"Open in Editor"];
      NSArray *actions = @[@"locate:", @"openEditor:"];
      for (NSUInteger i = 0; i < titles.count; i++)
        {
          NSButton *button = [[NSButton alloc] initWithFrame: NSMakeRect(10 + i * 160, 528, 150, 28)];
          [button setTitle: titles[i]]; [button setBezelStyle: NSRoundedBezelStyle];
          [button setTarget: self]; [button setAction: NSSelectorFromString(actions[i])];
          [button setAutoresizingMask: NSViewMinYMargin]; [view addSubview: button];
        }
      NSScrollView *scroll = [[NSScrollView alloc] initWithFrame: NSMakeRect(10, 10, 880, 508)];
      [scroll setHasVerticalScroller: YES]; [scroll setHasHorizontalScroller: YES];
      [scroll setBorderType: NSBezelBorder];
      [scroll setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
      _source = [[NSTextView alloc] initWithFrame: scroll.contentView.bounds];
      [_source setEditable: NO]; [_source setSelectable: YES];
      [_source setFont: [NSFont userFixedPitchFontOfSize: 12]];
      [_source setTextColor: [PDTheme textColor]];
      [_source setBackgroundColor: [NSColor textBackgroundColor]];
      [_source setAutoresizingMask: NSViewWidthSizable];
      [scroll setDocumentView: _source]; [view addSubview: scroll];
      [window setInitialFirstResponder: _source];
      [self loadSource];
    }
  return self;
}

- (void) loadSource
{
  NSDictionary *info = [GSPSymbolicator sourceFileAndLine: _location mappings: _mappings];
  _path = info[@"path"];
  [_caption setStringValue: [NSString stringWithFormat: @"Recorded: %@\nLocal: %@", _location, _path ?: @"Unavailable"]];
  NSDictionary *attributes = _path ? [[NSFileManager defaultManager] attributesOfItemAtPath: _path error: NULL] : nil;
  if (!attributes || ![attributes[NSFileType] isEqual: NSFileTypeRegular]
      || [attributes[NSFileSize] unsignedLongLongValue] > 4 * 1024 * 1024)
    {
      [_source setString: @"Source is missing, not a regular file, or exceeds the 4 MiB viewer limit. Use Locate Source to map its recorded directory to a local directory."];
      return;
    }
  NSError *error = nil;
  NSStringEncoding encoding = NSUTF8StringEncoding;
  NSString *text = [NSString stringWithContentsOfFile: _path usedEncoding: &encoding error: &error];
  if (!text) { [_source setString: error.localizedDescription]; return; }
  NSArray *lines = [text componentsSeparatedByString: @"\n"];
  NSMutableString *numbered = [NSMutableString string];
  NSRange selected = NSMakeRange(0, 0);
  NSUInteger target = [info[@"line"] unsignedIntegerValue];
  for (NSUInteger i = 0; i < lines.count; i++)
    {
      NSUInteger start = numbered.length;
      [numbered appendFormat: @"%6lu  %@\n", (unsigned long)i + 1, lines[i]];
      if (i + 1 == target) selected = NSMakeRange(start, numbered.length - start);
    }
  [_source setString: numbered];
  [_source setSelectedRange: selected]; [_source scrollRangeToVisible: selected];
  if (target > lines.count)
    [_caption setStringValue: [NSString stringWithFormat: @"%@\nLine is outside this file; verify that the source matches the recorded build.", _location]];
}

- (void) locate: (id)sender
{
  NSDictionary *info = [GSPSymbolicator sourceFileAndLine: _location mappings: @{}];
  if (!info) return;
  NSOpenPanel *panel = [NSOpenPanel openPanel];
  [panel setTitle: @"Locate the matching source file (its directory will be remembered)"];
  [panel setCanChooseFiles: YES]; [panel setCanChooseDirectories: NO];
  if ([panel runModal] != NSOKButton) return;
  NSString *selected = panel.URL.path;
  if (![selected.lastPathComponent isEqual: [info[@"recordedPath"] lastPathComponent]])
    {
      NSRunAlertPanel(@"Source filename differs", @"Choose the matching source filename to map its directory.", @"OK", nil, nil);
      return;
    }
  NSString *directory = [info[@"recordedPath"] stringByDeletingLastPathComponent];
  _mappings[directory.length ? directory : @"."] = [selected stringByDeletingLastPathComponent];
  [[NSUserDefaults standardUserDefaults] setObject: _mappings forKey: @"PDSourceMappings"];
  [self loadSource];
}

- (void) openEditor: (id)sender
{
  if (!_path || ![[NSWorkspace sharedWorkspace] openFile: _path])
    NSRunAlertPanel(@"Cannot open source", @"Locate the source file and configure a default editor for its file type.", @"OK", nil, nil);
}
@end
