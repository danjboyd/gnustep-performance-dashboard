/* SPDX-License-Identifier: GPL-3.0-or-later */
#import "PDTraceWindowController.h"
#import "PDTimelineView.h"
#import "PDTrackRenderer.h"
#import "PDDetailController.h"
#import "PDInspectorView.h"
#import "PDTheme.h"
#import "PDAppController.h"
#import "PDRecordPanel.h"
#import "PDInvestigationWindowController.h"
#import "PDRecordingStatus.h"

@interface PDTraceWindowController () <PDTimelineDelegate, PDDetailControllerDelegate,
                                       GSPRecorderDelegate, NSWindowDelegate>
@end

@implementation PDTraceWindowController
{
  PDInvestigationWindowController *_generationsWindow, *_comparisonWindow;
  NSString *_tracePath;
  GSPTrace *_trace;
  GSPRecorder *_recorder;
  GSPRecordingOptions *_options;
  BOOL _temporary;
  BOOL _loading, _closed;
  NSProgressIndicator *_loadProgress;
  void (^_loadCompletion)(BOOL, NSError *);

  PDTrackRenderer *_renderer;
  PDTimelineView *_timeline;
  PDDetailController *_detail;
  PDInspectorView *_inspector;
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
- (BOOL) isLoading { return _loading; }

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
  _targetLabel = label(NSMakeRect(112, 18, 420, 18), [PDTheme boldLabelFont]);
  [bar addSubview: _targetLabel];
  _statusLabel = label(NSMakeRect(112, 2, 420, 16), [PDTheme smallFont]);
  [_statusLabel setTextColor: [PDTheme secondaryTextColor]];
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

  _timeline = [[PDTimelineView alloc] initWithFrame: NSMakeRect(0, 0, b.size.width, 330)];
  [_timeline setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  _timeline.delegate = self;

  NSSplitView *lower = [[NSSplitView alloc] initWithFrame:
    NSMakeRect(0, 0, b.size.width, b.size.height - barH - 340)];
  [lower setVertical: YES];
  [lower setAutoresizingMask: NSViewWidthSizable | NSViewHeightSizable];
  CGFloat inspectorW = 340;
  NSRect lowerB = [lower bounds];
  _inspector = [[PDInspectorView alloc] initWithFrame:
    NSMakeRect(0, 0, inspectorW, lowerB.size.height)];
  [_inspector setAutoresizingMask: NSViewHeightSizable | NSViewMinXMargin];
  _detail = [[PDDetailController alloc] initWithFrame:
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
      [self updateLabels];
    }
  return self;
}

- (instancetype) initForLoadingTraceAtPath: (NSString *)path
                              completion: (void (^)(BOOL, NSError *))completion
{
  if ((self = [super initWithWindow: nil]) != nil)
    {
      _tracePath = [path copy];
      _loading = YES;
      _loadCompletion = [completion copy];
      [self buildWindow];
      [[self window] setTitle: @"Opening Trace…"];
      [_targetLabel setStringValue: [path lastPathComponent]];
      [_statusLabel setStringValue: @"Reading trace and preparing analyses…"];
      [_recordButton setEnabled: NO];
      [_mainSplit setHidden: YES];
      NSRect bounds = [[[self window] contentView] bounds];
      _loadProgress = [[NSProgressIndicator alloc] initWithFrame:
        NSMakeRect((bounds.size.width - 320) / 2, (bounds.size.height - 16) / 2,
                   320, 16)];
      [_loadProgress setAutoresizingMask: NSViewMinXMargin | NSViewMaxXMargin
                                         | NSViewMinYMargin | NSViewMaxYMargin];
      [_loadProgress setIndeterminate: YES];
      [_loadProgress setStyle: NSProgressIndicatorBarStyle];
      [[[self window] contentView] addSubview: _loadProgress];
      [_loadProgress startAnimation: self];
      [NSThread detachNewThreadSelector: @selector(loadTraceInBackground:)
                              toTarget: self withObject: _tracePath];
    }
  return self;
}

- (void) loadTraceInBackground: (NSString *)path
{
  NSDictionary *completed = nil;
  @autoreleasepool
    {
      NSMutableDictionary *result = [NSMutableDictionary dictionary];
      NSError *error = nil;
      @try
        {
          GSPTrace *trace = [GSPTrace traceWithPath: path error: &error];
          if (trace)
            {
              PDTrackRenderer *renderer = [[PDTrackRenderer alloc] initWithTrace: trace];
              [renderer prepareAnalyses];
              [result setObject: trace forKey: @"trace"];
              [result setObject: renderer forKey: @"renderer"];
            }
        }
      @catch (NSException *exception)
        {
          error = [NSError errorWithDomain: GSPTraceErrorDomain code: 5
            userInfo: @{NSLocalizedDescriptionKey: exception.reason ?: @"Cannot read trace"}];
        }
      if (error) [result setObject: error forKey: @"error"];
      completed = [result copy];
    }
  /* Temporary Foundation objects are drained before publishing the model. */
  [self performSelectorOnMainThread: @selector(didLoadTrace:)
                         withObject: completed waitUntilDone: NO];
}

- (void) didLoadTrace: (NSDictionary *)result
{
  _loading = NO;
  [_loadProgress stopAnimation: self];
  [_loadProgress removeFromSuperview];
  _loadProgress = nil;
  GSPTrace *trace = [result objectForKey: @"trace"];
  NSError *error = [result objectForKey: @"error"];
  BOOL success = !_closed && trace != nil && error == nil;
  if (success)
    {
      _renderer = [result objectForKey: @"renderer"];
      _timeline.dataSource = _renderer;
      _detail.renderer = _renderer;
      [_detail showInstrument: [_renderer instrumentForTrack: 0]];
      [self attachTrace: trace];
      [self updateLabels];
      [_mainSplit setHidden: NO];
      [_recordButton setEnabled: YES];
    }
  void (^completion)(BOOL, NSError *) = _loadCompletion;
  _loadCompletion = nil;
  if (completion) completion(success, _closed ? nil : error);
  if (!success && !_closed) [[self window] close];
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
      _renderer = [[PDTrackRenderer alloc] initWithTrace: trace];
      _timeline.dataSource = _renderer;
      _detail.renderer = _renderer;
      [_detail showInstrument: [_renderer instrumentForTrack: 0]];
    }
  else if (_renderer.trace != trace)
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
  CGFloat want = [PDTimelineView rulerHeight] + 15 + 6;
  for (NSUInteger i = 0; i < n; i++)
    want += [_renderer timeline: _timeline heightOfTrack: i];
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
        [PDTimelineView formatTime: t], _recorder.pid]];
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
  NSArray *warnings = [_trace qualityWarningsIncludingIncomplete: !_recorder.isRecording];
  [_statusLabel setToolTip: [warnings componentsJoinedByString: @"\n"]];
  if ([warnings count])
    {
      NSString *summary = @"recording diagnostics";
      for (GSPProcess *p in _trace.processes)
        {
          if (p.droppedSamples)
            summary = @"dropped samples";
          if (!_recorder.isRecording && !p.finishedCleanly)
            summary = @"incomplete recording";
          if (p.leakScanUnavailable)
            {
              summary = @"leak scan unavailable";
              break;
            }
        }
      [_statusLabel setStringValue: [NSString stringWithFormat: @"%@Warning: %@%@",
        _recorder.isRecording ? @"Recording · " : @"", summary,
        _temporary ? @" · not saved" : @""]];
    }
#if defined(__linux__)
  if (!_recorder.isRecording)
    {
      NSString *trigger = _recorder.stopTrigger ?: [_trace.info objectForKey: @"StopTrigger"];
      if (trigger)
        [_statusLabel setStringValue: [[_statusLabel stringValue] stringByAppendingFormat:
          @" · stopped: %@%@", trigger, _recorder.recordingError ? @" · incomplete" : @""]];
      NSMutableArray *details = [warnings mutableCopy] ?: [NSMutableArray array];
      NSString *summary = [_statusLabel stringValue];
      NSString *statusSummary = PDRecordingStatusSummary(_trace.info, summary);
      if (![statusSummary isEqualToString: summary])
        {
          [_statusLabel setStringValue: statusSummary];
          [details insertObject: statusSummary atIndex: 0];
        }
      if (_recorder.recordingError) [details addObject: [_recorder.recordingError localizedDescription]];
      for (NSString *key in @[@"StopTrigger", @"StopReason", @"CaptureStatus", @"MaximumTraceBytes",
                              @"MinimumFreeBytes", @"ObservedTraceBytes", @"ObservedAvailableBytes",
                              @"WaitPIDErrno", @"WaitPIDErrorName", @"WaitPIDError"])
        if ([_trace.info objectForKey: key])
          [details addObject: [NSString stringWithFormat: @"%@: %@", key, [_trace.info objectForKey: key]]];
      [_statusLabel setToolTip: [details componentsJoinedByString: @"\n"]];
    }
#endif
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
  NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent: @"Performance Dashboard"];
  [[NSFileManager defaultManager] createDirectoryAtPath: dir withIntermediateDirectories: YES
                                             attributes: nil error: NULL];
  NSString *name = [[GSPRecorder defaultTracePathForExecutable: [self targetName]
                                                   template: [self templateName]] lastPathComponent];
  return [dir stringByAppendingPathComponent: name];
}

- (void) startRecording: (id)sender
{
  if (_options == nil)
    {
      /* An opened trace: show the template chooser (or the process list
         for an attached trace) set up like this trace, and record into a
         new window so this one stays as it is.  */
      NSDictionary *info = _trace.info;
      GSPRecordingOptions *o;
      if ([[info objectForKey: @"Attached"] boolValue])
        o = [PDAttachPanel runPanel];
      else
        {
          GSPRecordingOptions *initial = [GSPRecordingOptions new];
          initial.templateName = _trace.templateName;
          initial.executablePath = [info objectForKey: @"TargetPath"];
          initial.arguments = [info objectForKey: @"Arguments"];
          o = [PDRecordPanel runPanelWithOptions: initial];
        }
      if (o != nil)
        [(PDAppController *)[NSApp delegate] startRecordingWithOptions: o];
      return;
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
      _renderer.trace = _trace;  /* exec may replace the selected process epoch */
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

- (void) finishRecording
{
  if (_recorder.isRecording)
    {
      [_recorder stop];
      [_recorder waitUntilFinished];
    }
}

- (void) recorder: (GSPRecorder *)recorder didFinishWithError: (NSError *)error
{
  [_timer invalidate];
  _timer = nil;
  [_recordButton setEnabled: YES];
  _timeline.following = NO;
  if (error)
    {
#if defined(__linux__)
      GSPTrace *partial = [GSPTrace traceWithPath: _tracePath error: NULL];
      if (partial) [self attachTrace: partial];
#endif
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
  if (![_trace copyToPath: dest error: &error])
    {
      NSRunAlertPanel(@"Cannot Save Trace", @"%@", @"OK", nil, nil, [error localizedDescription]);
      return;
    }
  if (_temporary && ![[_tracePath stringByResolvingSymlinksInPath]
                       isEqual: [dest stringByResolvingSymlinksInPath]])
    [fm removeItemAtPath: _tracePath error: NULL];
  _tracePath = dest;
  _temporary = NO;
  _trace = [GSPTrace traceWithPath: dest error: NULL] ?: _trace;
  [self attachTrace: _trace];
  [self updateLabels];
  [[NSUserDefaults standardUserDefaults] setObject: dest forKey: @"PDLastSavedTrace"];
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
    @"CSV: leaks", @"CSV: os_log", @"CSV: file and network operations", nil]];
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

- (void) showGenerations: (id)sender
{
  if (!_trace || ![_trace.instrumentIdentifiers containsObject: GSPInstrumentAllocations]) return;
  [_generationsWindow close];
  _generationsWindow = [[PDInvestigationWindowController alloc] initWithTrace: _trace
    process: _renderer.process generations: YES
    start: _timeline.hasSelection ? [_trace absoluteTime: _timeline.selectionStart] : 0
    end: _timeline.hasSelection ? [_trace absoluteTime: _timeline.selectionEnd] : 0];
  [_generationsWindow showWindow: self];
}

- (void) compareRecording: (id)sender
{
  if (!_trace || self.isRecording) return;
  [_comparisonWindow close];
  _comparisonWindow = [[PDInvestigationWindowController alloc] initWithTrace: _trace
    process: _trace.targetProcess generations: NO
    start: _timeline.hasSelection ? [_trace absoluteTime: _timeline.selectionStart] : 0
    end: _timeline.hasSelection ? [_trace absoluteTime: _timeline.selectionEnd] : 0];
  [_comparisonWindow showWindow: self];
}

- (void) timelineSelectionDidChange: (PDTimelineView *)view
{
  if (view.hasSelection)
    [_detail setRangeStart: [_trace absoluteTime: view.selectionStart]
                       end: [_trace absoluteTime: view.selectionEnd]];
  else
    [_detail setRangeStart: 0 end: 0];
}

- (void) timeline: (PDTimelineView *)view didSelectTrack: (NSUInteger)track
{
  uint32_t tid = [_renderer threadForTrack: track];
  NSString *ident = [_renderer instrumentForTrack: track];
  if (tid)
    {
      NSString *tp = [_renderer.trackIdentifiers containsObject: GSPInstrumentTimeProfiler]
        ? GSPInstrumentTimeProfiler : GSPInstrumentSystemProfiler;
      if (![tp isEqual: _detail.instrument])
        [_detail showInstrument: tp];
      [_detail showThread: tid];
      return;
    }
  if (ident && ![ident isEqual: _detail.instrument])
    [_detail showInstrument: ident];
  else if ([ident isEqual: GSPInstrumentTimeProfiler] || [ident isEqual: GSPInstrumentSystemProfiler])
    [_detail showThread: 0];
}

- (void) detailController: (PDDetailController *)dc
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

/* View menu actions arrive through the window delegate; the timeline
   does the work whether or not it is first responder.  */
- (void) zoomIn: (id)sender { [_timeline zoomIn: sender]; }
- (void) zoomOut: (id)sender { [_timeline zoomOut: sender]; }
- (void) zoomToFit: (id)sender { [_timeline zoomToFit: sender]; }
- (void) zoomToSelection: (id)sender { [_timeline zoomToSelection: sender]; }
- (void) clearSelection { [_timeline clearSelection]; }

- (BOOL) validateMenuItem: (NSMenuItem *)item
{
  if (item.action == @selector(showGenerations:))
    return _trace && [_trace.instrumentIdentifiers containsObject: GSPInstrumentAllocations];
  if (item.action == @selector(compareRecording:)) return _trace && !self.isRecording;
  SEL a = [item action];
  if (a == @selector(startRecording:))
    return !_loading && !_recorder.isRecording;
  if (a == @selector(stopRecording:))
    return _recorder.isRecording;
  if (a == @selector(checkForLeaksNow:))
    return _recorder.isRecording && [_options.instrumentIdentifiers containsObject: GSPInstrumentLeaks];
  if (a == @selector(saveTraceAs:) || a == @selector(exportTrace:))
    return _trace != nil && !_recorder.isRecording;
  return YES;
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
  _closed = YES;
  [_generationsWindow close];
  [_comparisonWindow close];
  [_timer invalidate];
  _timer = nil;
  [[NSNotificationCenter defaultCenter] postNotificationName: @"PDTraceWindowClosed"
                                                      object: self];
}

@end
