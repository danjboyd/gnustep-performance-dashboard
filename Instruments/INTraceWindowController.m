#import "INTraceWindowController.h"
#import "INTimelineView.h"
#import "INTrackRenderer.h"
#import "INDetailController.h"
#import "INInspectorView.h"
#import "INTheme.h"

@interface INTraceWindowController () <INTimelineDelegate, INDetailControllerDelegate,
                                       GSPRecorderDelegate, NSWindowDelegate>
@end

@implementation INTraceWindowController
{
  NSString *_tracePath;
  GSPTrace *_trace;
  GSPRecorder *_recorder;
  GSPRecordingOptions *_options;
  BOOL _temporary;

  INTrackRenderer *_renderer;
  INTimelineView *_timeline;
  INDetailController *_detail;
  INInspectorView *_inspector;
  NSSplitView *_mainSplit;
  NSUInteger _sizedForTracks;

  NSButton *_recordButton;
  NSButton *_leaksButton;
  NSTextField *_targetLabel;
  NSTextField *_statusLabel;
  NSPopUpButton *_processPopup;
  NSTimer *_timer;
  NSUInteger _ticks;
  NSDate *_recordStart;
}

- (NSString *) tracePath { return _tracePath; }
- (BOOL) isRecording { return _recorder.isRecording; }
- (BOOL) isTemporary { return _temporary; }

/* ------------------------------------------------------------------ */
/* construction                                                        */

static NSTextField *
label(NSRect frame, NSFont *font)
{
  NSTextField *t = [[NSTextField alloc] initWithFrame: frame];
  [t setEditable: NO];
  [t setSelectable: NO];
  [t setBezeled: NO];
  [t setDrawsBackground: NO];
  [t setFont: font];
  return t;
}

static NSButton *
push_button(NSString *title, NSRect frame, id target, SEL action)
{
  NSButton *b = [[NSButton alloc] initWithFrame: frame];
  [b setButtonType: NSMomentaryPushInButton];
  [b setBezelStyle: NSRoundedBezelStyle];
  [b setTitle: title];
  [b setTarget: target];
  [b setAction: action];
  return b;
}

- (void) buildWindow
{
  NSRect screen = [[NSScreen mainScreen] visibleFrame];
  NSRect frame = NSMakeRect(screen.origin.x + 60, screen.origin.y + 40,
                            MIN(1280, screen.size.width - 120),
                            MIN(860, screen.size.height - 80));
  NSWindow *w = [[NSWindow alloc] initWithContentRect: frame
    styleMask: NSTitledWindowMask | NSClosableWindowMask | NSMiniaturizableWindowMask
               | NSResizableWindowMask
      backing: NSBackingStoreBuffered defer: NO];
  [w setMinSize: NSMakeSize(800, 520)];
  [w setReleasedWhenClosed: NO];
  [w setDelegate: self];
  [self setWindow: w];

  NSView *content = [w contentView];
  NSRect b = [content bounds];
  CGFloat barH = 40;

  /* control bar */
  NSView *bar = [[NSView alloc] initWithFrame: NSMakeRect(0, b.size.height - barH, b.size.width, barH)];
  [bar setAutoresizingMask: NSViewWidthSizable | NSViewMinYMargin];
  _recordButton = push_button(@"Record", NSMakeRect(8, 6, 96, 28), self, @selector(toggleRecording:));
  [bar addSubview: _recordButton];
  _targetLabel = label(NSMakeRect(112, 18, 420, 18), [INTheme boldLabelFont]);
  [bar addSubview: _targetLabel];
  _statusLabel = label(NSMakeRect(112, 2, 420, 16), [INTheme smallFont]);
  [_statusLabel setTextColor: [INTheme secondaryTextColor]];
  [bar addSubview: _statusLabel];
  _leaksButton = push_button(@"Check for Leaks", NSMakeRect(540, 6, 130, 28), self,
                             @selector(checkForLeaksNow:));
  [_leaksButton setHidden: YES];
  [bar addSubview: _leaksButton];

  _processPopup = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(b.size.width - 520, 8, 200, 24)
                                             pullsDown: NO];
  [_processPopup setAutoresizingMask: NSViewMinXMargin];
  [_processPopup setTarget: self];
  [_processPopup setAction: @selector(processChanged:)];
  [_processPopup setHidden: YES];
  [bar addSubview: _processPopup];

  CGFloat x = b.size.width - 310;
  NSArray *zooms = [NSArray arrayWithObjects:
    [NSArray arrayWithObjects: @"Zoom Out", NSStringFromSelector(@selector(zoomOut:)), nil],
    [NSArray arrayWithObjects: @"Zoom In", NSStringFromSelector(@selector(zoomIn:)), nil],
    [NSArray arrayWithObjects: @"Fit", NSStringFromSelector(@selector(zoomToFit:)), nil], nil];
  for (NSArray *z in zooms)
    {
      NSButton *btn = push_button([z objectAtIndex: 0], NSMakeRect(x, 6, 96, 28), nil,
                                  NSSelectorFromString([z objectAtIndex: 1]));
      [btn setAutoresizingMask: NSViewMinXMargin];
      [bar addSubview: btn];
      [btn setTag: 99];
      x += 100;
    }
  [content addSubview: bar];

  /* main split: timeline above, details below */
  NSSplitView *main = [[NSSplitView alloc] initWithFrame:
    NSMakeRect(0, 0, b.size.width, b.size.height - barH)];
  [main setVertical: NO];
  [main setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];

  _timeline = [[INTimelineView alloc] initWithFrame: NSMakeRect(0, 0, b.size.width, 330)];
  [_timeline setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _timeline.delegate = self;

  NSSplitView *lower = [[NSSplitView alloc] initWithFrame:
    NSMakeRect(0, 0, b.size.width, b.size.height - barH - 340)];
  [lower setVertical: YES];
  [lower setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  CGFloat inspectorW = 340;
  NSRect lowerB = [lower bounds];
  _inspector = [[INInspectorView alloc] initWithFrame:
    NSMakeRect(0, 0, inspectorW, lowerB.size.height)];
  [_inspector setAutoresizingMask: NSViewHeightSizable | NSViewMinXMargin];
  _detail = [[INDetailController alloc] initWithFrame:
    NSMakeRect(0, 0, lowerB.size.width - inspectorW - 8, lowerB.size.height) inspector: _inspector];
  _detail.delegate = self;
  [lower addSubview: _detail.view];
  [lower addSubview: _inspector];
  [lower adjustSubviews];

  [main addSubview: _timeline];
  [main addSubview: lower];
  [main adjustSubviews];
  [content addSubview: main];
  _mainSplit = main;

  /* zoom buttons target the timeline */
  for (NSView *v in [bar subviews])
    if ([v isKindOfClass: [NSButton class]] && [(NSButton *)v tag] == 99)
      [(NSButton *)v setTarget: _timeline];
}

- (instancetype) initWithTracePath: (NSString *)path error: (NSError **)error
{
  GSPTrace *trace = [GSPTrace traceWithPath: path error: error];
  if (trace == nil)
    return nil;
  if ((self = [super initWithWindow: nil]) != nil)
    {
      _tracePath = [path copy];
      [self buildWindow];
      [self attachTrace: trace];
      [_recordButton setEnabled: [trace.info objectForKey: @"TargetPath"] != nil];
      [self updateLabels];
    }
  return self;
}

- (instancetype) initWithRecordingOptions: (GSPRecordingOptions *)options
{
  if ((self = [super initWithWindow: nil]) != nil)
    {
      _options = options;
      [self buildWindow];
      [self updateLabels];
    }
  return self;
}

/* ------------------------------------------------------------------ */

- (void) attachTrace: (GSPTrace *)trace
{
  _trace = trace;
  if (_renderer == nil)
    {
      _renderer = [[INTrackRenderer alloc] initWithTrace: trace];
      _timeline.dataSource = _renderer;
      _detail.renderer = _renderer;
      [_detail showInstrument: [_renderer instrumentForTrack: 0]];
    }
  else
    {
      _renderer.trace = trace;
      [_renderer invalidate];
    }
  [self rebuildProcessPopup];
  [self fitTimelineToTracks];
  _timeline.duration = trace.duration;
  [_timeline reloadData];
  [_leaksButton setHidden: !([trace.instrumentIdentifiers containsObject: GSPInstrumentLeaks]
                             && _recorder.isRecording)];
}

/* Give the timeline just the height its tracks need (once per track count). */
- (void) fitTimelineToTracks
{
  NSUInteger n = [_renderer.trackIdentifiers count];
  if (n == 0 || n == _sizedForTracks)
    return;
  _sizedForTracks = n;
  CGFloat want = [INTimelineView rulerHeight] + 15 + n * 64 + 6;
  CGFloat total = [_mainSplit bounds].size.height;
  want = MAX(150, MIN(want, total * 0.6));
  [_mainSplit setPosition: want ofDividerAtIndex: 0];
}

- (void) rebuildProcessPopup
{
  NSArray *procs = _trace.processes;
  [_processPopup setHidden: [procs count] < 2];
  if ([procs count] < 2)
    return;
  NSInteger selected = _renderer.process.pid;
  [_processPopup removeAllItems];
  for (GSPProcess *p in procs)
    {
      [_processPopup addItemWithTitle: [NSString stringWithFormat: @"%@ (%d)",
        [p.executablePath lastPathComponent], p.pid]];
      [[_processPopup lastItem] setTag: p.pid];
    }
  [_processPopup selectItemAtIndex: MAX(0, [_processPopup indexOfItemWithTag: selected])];
}

- (void) processChanged: (id)sender
{
  GSPProcess *p = [_trace processWithPID: (int)[[_processPopup selectedItem] tag]];
  if (p == nil)
    return;
  _renderer.process = p;
  [_timeline reloadData];
  [_detail showInstrument: [_renderer instrumentForTrack: _timeline.selectedTrack]];
}

- (NSString *) targetName
{
  NSString *path = _options ? _options.executablePath : [_trace.info objectForKey: @"TargetPath"];
  if (path == nil)
    path = _trace.targetProcess.executablePath;
  return [path lastPathComponent] ?: @"Untitled";
}

- (NSString *) templateName
{
  return (_options ? _options.templateName : _trace.templateName) ?: @"Trace";
}

- (void) updateLabels
{
  NSString *title = [NSString stringWithFormat: @"%@ — %@", [self targetName], [self templateName]];
  [[self window] setTitle: _recorder.isRecording
    ? [title stringByAppendingString: @" (Recording)"] : title];
  [_targetLabel setStringValue: [NSString stringWithFormat: @"%@  ·  %@",
    [self targetName], [self templateName]]];
  if (_recorder.isRecording)
    {
      double t = -[_recordStart timeIntervalSinceNow];
      [_statusLabel setStringValue: [NSString stringWithFormat: @"Recording  %@  (pid %d)",
        [INTimelineView formatTime: t], _recorder.pid]];
      [_recordButton setTitle: @"Stop"];
    }
  else
    {
      [_recordButton setTitle: @"Record"];
      if (_trace)
        [_statusLabel setStringValue: [NSString stringWithFormat: @"%@  ·  %@%@",
          GSPFormatDuration(_trace.duration),
          _trace.startDate ? [_trace.startDate descriptionWithCalendarFormat:
                               @"%Y-%m-%d %H:%M:%S" timeZone: nil locale: nil] : @"",
          _temporary ? @"  ·  not saved" : @""]];
      else
        [_statusLabel setStringValue: @"Press Record to start."];
    }
}

/* ------------------------------------------------------------------ */
/* recording                                                           */

- (void) toggleRecording: (id)sender
{
  if (_recorder.isRecording)
    [self stopRecording: sender];
  else
    [self startRecording: sender];
}

- (NSString *) temporaryTracePath
{
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent: @"GNUstep Instruments"];
  [[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  NSDateFormatter *f = [NSDateFormatter new];
  [f setDateFormat: @"yyyyMMdd-HHmmss"];
  return [dir stringByAppendingPathComponent: [NSString stringWithFormat: @"%@ %@ %@.gstrace",
    [self targetName], [self templateName], [f stringFromDate: [NSDate date]]]];
}

- (void) startRecording: (id)sender
{
  if (_options == nil)
    {
      /* re-record the same target with the same template */
      NSDictionary *info = _trace.info;
      if ([info objectForKey: @"TargetPath"] == nil)
        return;
      _options = [GSPRecordingOptions new];
      _options.executablePath = [info objectForKey: @"TargetPath"];
      _options.arguments = [info objectForKey: @"Arguments"] ?: [NSArray array];
      _options.templateName = _trace.templateName;
      _options.instrumentIdentifiers = _trace.instrumentIdentifiers;
    }
  _options.outputPath = [self temporaryTracePath];
  _options.captureOutput = YES;
  _recorder = [[GSPRecorder alloc] initWithOptions: _options];
  _recorder.delegate = self;
  NSError *error = nil;
  if (![_recorder start: &error])
    {
      NSRunAlertPanel(@"Cannot Start Recording", @"%@", @"OK", nil, nil,
                      [error localizedDescription]);
      _recorder = nil;
      return;
    }
  _tracePath = _recorder.tracePath;
  _temporary = YES;
  _trace = nil;
  _recordStart = [NSDate date];
  _timeline.following = YES;
  _ticks = 0;
  _timer = [NSTimer scheduledTimerWithTimeInterval: 0.5 target: self
                                          selector: @selector(tick:) userInfo: nil repeats: YES];
  [self updateLabels];
}

- (void) tick: (NSTimer *)t
{
  _ticks++;
  [self updateLabels];
  if (_tracePath == nil)
    return;
  if (_trace == nil)
    {
      GSPTrace *trace = [GSPTrace traceWithPath: _tracePath error: NULL];
      if (trace)
        [self attachTrace: trace];
      return;
    }
  [_trace reload: NULL];
  if (_trace.changedOnLastReload)
    {
      [_renderer invalidate];
      [self fitTimelineToTracks];
      if (_ticks % 4 == 0)
        [_detail reload];
    }
  _timeline.duration = MAX(_trace.duration, -[_recordStart timeIntervalSinceNow]);
  [_timeline reloadData];
}

- (void) stopRecording: (id)sender
{
  [_recorder stop];
  [_statusLabel setStringValue: @"Stopping…"];
  [_recordButton setEnabled: NO];
}

- (void) recorder: (GSPRecorder *)recorder didFinishWithError: (NSError *)error
{
  [_timer invalidate];
  _timer = nil;
  [_recordButton setEnabled: YES];
  _timeline.following = NO;
  if (error)
    {
      NSString *output = [NSString stringWithContentsOfFile:
        [_tracePath stringByAppendingPathComponent: @"output.txt"]];
      NSRunAlertPanel(@"Recording Failed", @"%@%@", @"OK", nil, nil,
                      [error localizedDescription],
                      [output length] ? [@"\n\nTarget output:\n" stringByAppendingString:
                        [output length] > 600 ? [output substringToIndex: 600] : output] : @"");
      [self updateLabels];
      return;
    }
  GSPTrace *trace = [GSPTrace traceWithPath: _tracePath error: NULL];
  if (trace)
    [self attachTrace: trace];
  [_timeline zoomToFit: nil];
  [_detail reload];
  [_leaksButton setHidden: YES];
  [self updateLabels];
}

- (void) checkForLeaksNow: (id)sender
{
  [_recorder requestLeakCheck];
}

/* ------------------------------------------------------------------ */
/* saving and exporting                                                */

- (void) saveTraceAs: (id)sender
{
  if (_tracePath == nil || _recorder.isRecording)
    return;
  NSSavePanel *panel = [NSSavePanel savePanel];
  [panel setTitle: @"Save Trace"];
  [panel setRequiredFileType: @"gstrace"];
  if ([panel runModalForDirectory: NSHomeDirectory()
                             file: [_tracePath lastPathComponent]] != NSOKButton)
    return;
  NSString *dest = [panel filename];
  if (![[dest pathExtension] isEqual: @"gstrace"])
    dest = [dest stringByAppendingPathExtension: @"gstrace"];
  NSFileManager *fm = [NSFileManager defaultManager];
  NSError *error = nil;
  if ([fm fileExistsAtPath: dest])
    [fm removeItemAtPath: dest error: NULL];
  if (![fm copyItemAtPath: _tracePath toPath: dest error: &error])
    {
      NSRunAlertPanel(@"Cannot Save Trace", @"%@", @"OK", nil, nil, [error localizedDescription]);
      return;
    }
  if (_temporary)
    [fm removeItemAtPath: _tracePath error: NULL];
  _tracePath = dest;
  _temporary = NO;
  _trace = [GSPTrace traceWithPath: dest error: NULL] ?: _trace;
  [self attachTrace: _trace];
  [self updateLabels];
  [[NSUserDefaults standardUserDefaults] setObject: dest forKey: @"INLastSavedTrace"];
}

- (void) exportTrace: (id)sender
{
  if (_trace == nil)
    return;
  NSArray *formats = [GSPExporter formats];
  NSPopUpButton *popup = [[NSPopUpButton alloc] initWithFrame: NSMakeRect(0, 0, 260, 26)
                                                    pullsDown: NO];
  [popup addItemsWithTitles: [NSArray arrayWithObjects:
    @"JSON summary (.json)", @"Chrome / Perfetto trace (.json)",
    @"speedscope profile (.speedscope.json)", @"Folded stacks for flame graphs (.folded)",
    @"CSV: samples", @"CSV: allocations", @"CSV: signposts", @"CSV: hangs",
    @"CSV: leaks", @"CSV: os_log", nil]];
  NSSavePanel *panel = [NSSavePanel savePanel];
  [panel setTitle: @"Export Trace"];
  [panel setAccessoryView: popup];
  if ([panel runModalForDirectory: NSHomeDirectory()
                             file: [[[_tracePath lastPathComponent] stringByDeletingPathExtension]
                                     stringByAppendingPathExtension: @"json"]] != NSOKButton)
    return;
  NSInteger idx = [popup indexOfSelectedItem];
  NSString *format, *table = nil;
  if (idx < 4)
    format = [formats objectAtIndex: (NSUInteger)idx];
  else
    {
      format = @"csv";
      table = [[GSPExporter csvTables] objectAtIndex: (NSUInteger)(idx - 4)];
    }
  NSError *error = nil;
  NSData *d = [GSPExporter exportTrace: _trace process: _renderer.process format: format
                                 table: table error: &error];
  if (d == nil || ![d writeToFile: [panel filename] atomically: YES])
    NSRunAlertPanel(@"Export Failed", @"%@", @"OK", nil, nil,
                    error ? [error localizedDescription] : @"Cannot write the file.");
}

/* ------------------------------------------------------------------ */
/* timeline / detail coordination                                      */

- (void) timelineSelectionDidChange: (INTimelineView *)view
{
  if (view.hasSelection)
    [_detail setRangeStart: [_trace absoluteTime: view.selectionStart]
                       end: [_trace absoluteTime: view.selectionEnd]];
  else
    [_detail setRangeStart: 0 end: 0];
}

- (void) timeline: (INTimelineView *)view didSelectTrack: (NSUInteger)track
{
  NSString *ident = [_renderer instrumentForTrack: track];
  if (ident && ![ident isEqual: _detail.instrument])
    [_detail showInstrument: ident];
}

- (void) detailController: (INDetailController *)dc
       showTimeRangeStart: (GSPTime)start end: (GSPTime)end
{
  /* Show where the item is without filtering the detail list itself. */
  double s = [_trace relativeTime: start], e = [_trace relativeTime: end];
  if (e - s < 0.0005)
    {
      s -= 0.00025;
      e += 0.00025;
    }
  id saved = _timeline.delegate;
  _timeline.delegate = nil;
  [_timeline setSelectionFrom: s to: e];
  _timeline.delegate = saved;
  if (s < _timeline.visibleStart || e > _timeline.visibleStart + _timeline.visibleDuration)
    _timeline.visibleStart = MAX(0, (s + e) / 2 - _timeline.visibleDuration / 2);
}

- (BOOL) windowShouldClose: (id)sender
{
  if (_recorder.isRecording)
    {
      NSInteger r = NSRunAlertPanel(@"Stop Recording?",
        @"Closing the window stops the recording and ends the target.",
        @"Stop and Close", @"Cancel", nil);
      if (r != NSAlertDefaultReturn)
        return NO;
      [_recorder stop];
      [_recorder waitUntilFinished];
    }
  if (_temporary && _trace != nil)
    {
      NSInteger r = NSRunAlertPanel(@"Save Trace?",
        @"This recording has not been saved. It stays in the temporary folder until the system cleans it up.",
        @"Save…", @"Close", nil);
      if (r == NSAlertDefaultReturn)
        {
          [self saveTraceAs: nil];
          return !_temporary;
        }
    }
  return YES;
}

- (void) windowWillClose: (NSNotification *)note
{
  [_timer invalidate];
  _timer = nil;
  [[NSNotificationCenter defaultCenter] postNotificationName: @"INTraceWindowClosed"
                                                      object: self];
}

@end
