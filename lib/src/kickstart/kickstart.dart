/// Kickstart detection — identifies trigger phrases for guided onboarding.
///
/// Matches natural language phrases like "let's set up", "kickstart",
/// "get started", "onboard", etc. Case-insensitive with word boundaries.
library;

/// Regex pattern for detecting kickstart trigger phrases.
///
/// Matches (case-insensitive, word boundaries):
/// - "let's set up" / "lets set up"
/// - "set up dreamfinder" / "set up `<botname>`"
/// - "kickstart"
/// - "get started"
/// - "onboard" / "onboarding"
final kickstartPattern = RegExp(
  r"\b(?:let'?s\s+set\s+up|set\s+up\s+\w+|kickstart|get\s+started|onboard(?:ing)?)\b",
  caseSensitive: false,
);

/// Returns `true` if [text] contains a kickstart trigger phrase.
bool isKickstartMessage(String text) => kickstartPattern.hasMatch(text);
