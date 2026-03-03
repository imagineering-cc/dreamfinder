/// Abstraction for browser interaction with Google Meet.
library;

import 'dart:convert';

import '../mcp/mcp_manager.dart';
import 'caption_entry.dart';

/// Interface for controlling a Google Meet session via a browser.
///
/// Production implementation ([PlaywrightMeetBrowser]) uses Playwright MCP
/// tools to automate Chrome. Tests can use [FakeMeetBrowser] to record calls
/// without a real browser.
abstract class MeetBrowser {
  /// Join a Google Meet call.
  ///
  /// Navigates to the Meet link, enters the display name, turns off camera,
  /// and joins the call.
  Future<void> joinMeet({
    required String meetLink,
    required String displayName,
  });

  /// Speak text using browser TTS (Web Speech API).
  ///
  /// The browser's audio output routes into Google Meet's outbound audio.
  /// Returns when the utterance completes.
  Future<void> speak(String text);

  /// Enable live captions in the Meet call.
  Future<void> enableCaptions();

  /// Leave the current Meet call.
  Future<void> leaveMeet();

  /// Inject a MutationObserver that scrapes live captions into a JS buffer.
  ///
  /// Idempotent — safe to call multiple times. The observer watches Meet's
  /// caption DOM and pushes `{speaker, text, timestamp}` objects to
  /// `window.__dreamfinderCaptions`.
  Future<void> startCaptionScraping();

  /// Drain the caption buffer and return new entries since the last poll.
  ///
  /// Returns an empty list if no new captions are available or if scraping
  /// hasn't started. Never throws — returns empty on failure for graceful
  /// degradation.
  Future<List<CaptionEntry>> pollCaptions();

  /// Whether currently connected to a Meet call.
  bool get isConnected;
}

/// Playwright MCP-based implementation of [MeetBrowser].
///
/// Uses Playwright tools to automate Chrome for Google Meet interaction.
/// The Playwright MCP server must be connected via [McpManager] before use.
///
/// **Join flow**: Navigate to Meet link -> enter name -> turn off camera ->
/// click join -> enable captions.
///
/// **Speaking**: Uses the Web Speech API (`speechSynthesis.speak()`) via
/// `browser_evaluate`. Chrome routes TTS audio into Meet's outbound stream.
///
/// **Selectors**: Google Meet's DOM is obfuscated and changes periodically.
/// The selectors here are best-effort starting points; use `browser_snapshot`
/// to discover current selectors when they break.
class PlaywrightMeetBrowser implements MeetBrowser {
  PlaywrightMeetBrowser({required McpManager mcpManager}) : _mcp = mcpManager;

  final McpManager _mcp;
  bool _connected = false;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> joinMeet({
    required String meetLink,
    required String displayName,
  }) async {
    // 1. Navigate to the Meet link.
    await _callTool('browser_navigate', <String, dynamic>{'url': meetLink});

    // 2. Take a snapshot to discover the current page state.
    await _callTool('browser_snapshot', <String, dynamic>{});

    // 3. Enter the display name (the "Your name" input before joining).
    await _callTool('browser_fill_form', <String, dynamic>{
      'selector': 'input[aria-label="Your name"]',
      'value': displayName,
    });

    // 4. Turn off camera (click the camera toggle button).
    await _callTool('browser_click', <String, dynamic>{
      'selector': '[aria-label*="camera" i]',
    });

    // 5. Click "Join now" or "Ask to join".
    await _callTool('browser_click', <String, dynamic>{
      'selector': 'button:has-text("Join now"), button:has-text("Ask to join")',
    });

    _connected = true;
  }

  @override
  Future<void> speak(String text) async {
    if (!_connected) {
      throw StateError('Not connected to a Meet call');
    }

    // Escape text for safe embedding in a JS string literal.
    final escapedText = text
        .replaceAll('\\', '\\\\')
        .replaceAll("'", "\\'")
        .replaceAll('\n', ' ');

    // Use Web Speech API. The browser's audio routes into Meet.
    await _callTool('browser_evaluate', <String, dynamic>{
      'expression': """
(() => {
  return new Promise((resolve, reject) => {
    const utterance = new SpeechSynthesisUtterance('$escapedText');
    utterance.rate = 1.0;
    utterance.pitch = 1.0;
    utterance.onend = () => resolve('done');
    utterance.onerror = (e) => reject(e.error);
    speechSynthesis.speak(utterance);
  });
})()""",
    });
  }

  @override
  Future<void> enableCaptions() async {
    if (!_connected) {
      throw StateError('Not connected to a Meet call');
    }

    // Click the CC / captions button.
    await _callTool('browser_click', <String, dynamic>{
      'selector': '[aria-label*="caption" i], [aria-label*="subtitle" i]',
    });
  }

  @override
  Future<void> leaveMeet() async {
    if (!_connected) return;

    // Click the "Leave call" button.
    await _callTool('browser_click', <String, dynamic>{
      'selector': '[aria-label*="Leave" i]',
    });

    _connected = false;
  }

  @override
  Future<void> startCaptionScraping() async {
    if (!_connected) {
      throw StateError('Not connected to a Meet call');
    }

    // Inject a MutationObserver that watches for caption elements.
    // Google Meet renders captions in a container; each caption bubble has
    // a speaker name and text. The exact selectors are best-effort.
    // Idempotency: guard with window.__dreamfinderObserver.
    await _callTool('browser_evaluate', <String, dynamic>{
      'expression': """
(() => {
  if (window.__dreamfinderObserver) return 'already running';
  window.__dreamfinderCaptions = [];
  const container = document.querySelector('[class*="caption"]')
    || document.body;
  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const node of m.addedNodes) {
        if (node.nodeType !== 1) continue;
        const speaker = node.querySelector('[class*="name"]')?.textContent || '';
        const text = node.textContent || '';
        window.__dreamfinderCaptions.push({
          speaker: speaker.trim(),
          text: text.trim(),
          timestamp: Date.now(),
        });
      }
    }
  });
  observer.observe(container, { childList: true, subtree: true });
  window.__dreamfinderObserver = observer;
  return 'started';
})()""",
    });
  }

  @override
  Future<List<CaptionEntry>> pollCaptions() async {
    if (!_connected) return [];

    try {
      final result = await _callTool('browser_evaluate', <String, dynamic>{
        'expression': '''
(() => {
  const buf = window.__dreamfinderCaptions || [];
  window.__dreamfinderCaptions = [];
  return JSON.stringify(buf);
})()''',
      });

      // The result is a JSON string of caption objects.
      final parsed = _parseCaptionJson(result);
      return parsed;
    } on Object {
      // Graceful degradation — never crash the tick loop over captions.
      return [];
    }
  }

  /// Parse the JSON string returned by the caption drain script.
  static List<CaptionEntry> _parseCaptionJson(String jsonStr) {
    try {
      final Object? decoded = jsonDecode(jsonStr);
      if (decoded is List<Object?>) {
        return [
          for (final item in decoded)
            if (item is Map<String, Object?>)
              CaptionEntry.fromBrowserJson(
                item.cast<String, dynamic>(),
              ),
        ];
      }
    } on FormatException {
      // Ignore parse failures.
    }
    return [];
  }

  /// Calls a Playwright MCP tool via the [McpManager].
  Future<String> _callTool(
    String toolName,
    Map<String, dynamic> args,
  ) async {
    return _mcp.callTool(toolName, args);
  }
}

/// Fake [MeetBrowser] for testing that records all calls.
class FakeMeetBrowser implements MeetBrowser {
  /// All method calls recorded in order.
  final List<String> calls = [];

  /// All texts passed to [speak], in order.
  final List<String> spokenTexts = [];

  /// Whether [startCaptionScraping] has been called.
  bool captionScrapingStarted = false;

  final List<CaptionEntry> _captionQueue = [];

  bool _connected = false;

  /// Whether [joinMeet] should throw an error.
  bool failOnJoin = false;

  /// Whether [speak] should throw an error.
  bool failOnSpeak = false;

  @override
  bool get isConnected => _connected;

  @override
  Future<void> joinMeet({
    required String meetLink,
    required String displayName,
  }) async {
    if (failOnJoin) throw Exception('Failed to join Meet');
    calls.add('joinMeet($meetLink, $displayName)');
    _connected = true;
  }

  @override
  Future<void> speak(String text) async {
    if (failOnSpeak) throw Exception('TTS failed');
    calls.add('speak($text)');
    spokenTexts.add(text);
  }

  @override
  Future<void> enableCaptions() async {
    calls.add('enableCaptions()');
  }

  @override
  Future<void> leaveMeet() async {
    calls.add('leaveMeet()');
    _connected = false;
  }

  @override
  Future<void> startCaptionScraping() async {
    calls.add('startCaptionScraping()');
    captionScrapingStarted = true;
  }

  @override
  Future<List<CaptionEntry>> pollCaptions() async {
    final drained = List<CaptionEntry>.of(_captionQueue);
    _captionQueue.clear();
    return drained;
  }

  /// Enqueue captions for the next [pollCaptions] call.
  void enqueueCaptions(List<CaptionEntry> captions) {
    _captionQueue.addAll(captions);
  }

  /// Reset all recorded state.
  void reset() {
    calls.clear();
    spokenTexts.clear();
    _captionQueue.clear();
    captionScrapingStarted = false;
    _connected = false;
    failOnJoin = false;
    failOnSpeak = false;
  }
}
