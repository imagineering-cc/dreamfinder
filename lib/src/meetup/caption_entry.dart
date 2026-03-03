/// A single caption entry scraped from Google Meet's live captions.
library;

/// Represents one caption bubble: who said what, and when.
///
/// Created from the browser-side MutationObserver scraper via
/// [fromBrowserJson]. The [timestamp] is a JS `Date.now()` value
/// (milliseconds since epoch).
class CaptionEntry {
  const CaptionEntry({
    required this.speaker,
    required this.text,
    required this.timestamp,
  });

  /// Parse a JSON map from the browser-side caption scraper.
  ///
  /// Missing fields default to safe values: empty string for [speaker]
  /// and [text], `0` for [timestamp].
  factory CaptionEntry.fromBrowserJson(Map<String, dynamic> json) {
    return CaptionEntry(
      speaker: json['speaker'] as String? ?? '',
      text: json['text'] as String? ?? '',
      timestamp: json['timestamp'] as int? ?? 0,
    );
  }

  /// Name of the speaker (as shown in Meet captions).
  final String speaker;

  /// Caption text content.
  final String text;

  /// JS `Date.now()` timestamp (ms since epoch) when the caption appeared.
  final int timestamp;

  @override
  String toString() => 'CaptionEntry(speaker: $speaker, text: $text, '
      'timestamp: $timestamp)';
}
