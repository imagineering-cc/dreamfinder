/// The canonical golden sentinels River's content-integrity probe verifies.
///
/// Each golden's [Sentinel.payload] is BOTH the retrieval anchor (the exact text
/// the probe embeds as its query, so cosine ≈ 1.0 against the seeded row and the
/// `_minScore` threshold is always cleared — the probe must never flap on its own
/// seed) AND the identity the probe asserts the real path returned. The immune
/// system owns this list; it is the *expected* answer, sealed into a
/// [FixtureSentinelStore] at boot. The *retrieved* copy lives in the RAG corpus
/// under [immuneGoldenChatId] and is compared against this.
library;

import 'sentinel.dart';

/// Reserved chatId the golden row is seeded under. A `same_chat` row here is
/// invisible to every real conversation (`getVisibleMemories` matches only
/// `visibility='cross_chat' OR chat_id=?`), so the sentinel never surfaces in a
/// user's recall — isolation enforced by an existing invariant, not a filter.
const immuneGoldenChatId = '__immune__';

/// The content-integrity golden. `version` is pinned to the payload; a change to
/// the payload MUST bump the version (retire the sentinel) rather than silently
/// firing a false failure.
const immuneContentGolden = Sentinel(
  id: 'immune_content_golden',
  payload: 'River immune system content-integrity golden sentinel — '
      'the golem remembers what the corpus must return.',
  version: 'v1',
);

/// All goldens the content probe seeds + verifies. One for PR2b; the list is the
/// extension seam for further catalogued-incident content antibodies (PR2c).
const immuneGoldens = <Sentinel>[immuneContentGolden];
