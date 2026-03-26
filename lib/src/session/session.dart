/// Session detection — identifies trigger phrases for co-working sessions.
///
/// Matches natural language phrases like "let's have a session",
/// "session time", "start a session", "co-working session", etc.
/// Case-insensitive with word boundaries.
library;

/// Regex pattern for detecting session trigger phrases.
///
/// Matches (case-insensitive, word boundaries):
/// - "let's have a session" / "lets have a session"
/// - "session time"
/// - "start a session"
/// - "imagineering session"
/// - "co-working session" / "coworking session"
/// - "let's work together" / "lets work together"
final sessionPattern = RegExp(
  r"\b(?:let'?s\s+have\s+a\s+session|session\s+time|start\s+a\s+session|imagineering\s+session|co-?working\s+session|let'?s\s+work\s+together)\b",
  caseSensitive: false,
);

/// Returns `true` if [text] contains a session trigger phrase.
bool isSessionMessage(String text) => sessionPattern.hasMatch(text);
