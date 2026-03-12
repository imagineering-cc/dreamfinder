/// Standalone summarization client for memory consolidation.
///
/// Calls Claude Haiku via a callback to summarize batches of old conversation
/// embeddings into compact summaries. Decoupled from the agent loop — no tools,
/// no history, no system prompt complexity.
library;

/// Callback that sends a prompt to a summarization model and returns the text.
typedef CreateSummarizationFn = Future<String> Function(String prompt);

/// Summarizes batches of conversation excerpts into concise paragraphs.
///
/// Used by [MemoryConsolidator] to compress old fine-grained message embeddings
/// into dense summary embeddings.
class SummarizationClient {
  SummarizationClient({required CreateSummarizationFn createSummarization})
      : _createSummarization = createSummarization;

  final CreateSummarizationFn _createSummarization;

  /// The instruction prepended to the joined source texts.
  static const _systemInstruction =
      'Summarize these conversation excerpts into a concise paragraph. '
      'Preserve key facts, decisions, names, and action items. '
      'Omit pleasantries.';

  /// Summarizes a list of source texts into a single summary string.
  ///
  /// Returns an empty string if [sourceTexts] is empty (does not call the
  /// callback). Propagates exceptions from the callback.
  Future<String> summarize(List<String> sourceTexts) async {
    if (sourceTexts.isEmpty) return '';

    final joined = sourceTexts.length == 1
        ? sourceTexts.first
        : sourceTexts.join('\n---\n');

    final prompt = '$_systemInstruction\n\n$joined';
    return _createSummarization(prompt);
  }
}
