/// Fixture-isolated, forge-proof sentinels for probe measurement-integrity.
///
/// The deepest round-2 cage-match finding on the immune design (§probe-integrity):
/// cleaning the *diagnosis* inputs does nothing if the *probe* itself reads a
/// poisoned corpus — "cleaning the doctor's ears does nothing if the stethoscope
/// is bugged". A content-integrity probe needs a KNOWN answer it can retrieve via
/// the real tool path AND verify in a way a user-writable corpus cannot forge.
///
/// Two properties, both merge-grade per the design:
///
/// 1. **Forge-proof** — the golden payload carries an HMAC-SHA256 seal over its
///    canonical bytes, keyed by a secret only the immune system holds. An
///    attacker who plants a look-alike record in the corpus cannot produce a
///    valid seal, so a forged reading fails verification. (Contrast a bare magic
///    string: if the corpus can *contain* the sentinel, the corpus can *forge*
///    the reading.)
/// 2. **Fixture-isolated** — the *expected* answer lives in a [SentinelStore] the
///    immune system owns (out-of-band file / dedicated index), never a string we
///    hope stays rare in the same corpus users and bridges write to.
library;

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A golden record whose content integrity can be verified without trusting the
/// store it was retrieved from.
class Sentinel {
  const Sentinel({
    required this.id,
    required this.payload,
    required this.version,
  });

  /// Stable id used to retrieve the sentinel via the real tool path.
  final String id;

  /// The canonical golden content. Verification is over these exact bytes.
  final String payload;

  /// Version pinned to the data the sentinel depends on. A corpus/schema change
  /// bumps the version (retiring the old sentinel) rather than silently firing a
  /// false failure — the sentinel-retirement discipline from the design.
  final String version;

  /// The canonical byte sequence the seal signs. Fixed key order so the seal is
  /// stable across (de)serialization and independent of map iteration order.
  String canonicalBytes() => jsonEncode(<String, String>{
        'id': id,
        'payload': payload,
        'version': version,
      });
}

/// Seals and verifies [Sentinel]s with an HMAC-SHA256 over their canonical
/// bytes. The key is the immune system's secret — never in a user-writable
/// store — so without it a forged record cannot produce a valid seal.
class SentinelSealer {
  SentinelSealer(this._key) {
    if (_key.isEmpty) {
      throw ArgumentError.value(_key, 'key', 'sentinel key must be non-empty');
    }
  }

  final String _key;

  /// The HMAC-SHA256 seal (hex) over [s]'s canonical bytes.
  String seal(Sentinel s) => Hmac(sha256, utf8.encode(_key))
      .convert(utf8.encode(s.canonicalBytes()))
      .toString();

  /// True iff [signature] is a valid seal for [s] under this key. Uses a
  /// length-guarded constant-time comparison so the seal can't be recovered by
  /// timing a byte-by-byte early return.
  bool verify(Sentinel s, String signature) {
    final expected = seal(s);
    if (expected.length != signature.length) return false;
    var mismatch = 0;
    for (var i = 0; i < expected.length; i++) {
      mismatch |= expected.codeUnitAt(i) ^ signature.codeUnitAt(i);
    }
    return mismatch == 0;
  }
}

/// A sentinel paired with its seal.
class SealedSentinel {
  const SealedSentinel(this.sentinel, this.seal);
  final Sentinel sentinel;
  final String seal;
}

/// A source of golden [SealedSentinel]s, isolated from any user-writable corpus.
///
/// The immune system owns this: the corpus a probe reads *through the real tool
/// path* is DISTINCT from where the expected answer lives. If the two were the
/// same store, the store that serves the reading could also forge the
/// expectation.
abstract class SentinelStore {
  /// The sealed sentinels this store vouches for, keyed by [Sentinel.id].
  Map<String, SealedSentinel> get sentinels;
}

/// An in-memory / fixture-backed [SentinelStore] (out-of-band, not
/// user-writable). Prod seeds it from a shipped fixture file or a dedicated
/// immune-owned table; tests seed it directly.
class FixtureSentinelStore implements SentinelStore {
  FixtureSentinelStore(this.sentinels);

  /// Seals [sentinels] with [sealer] up front, keyed by id.
  factory FixtureSentinelStore.sealed(
    SentinelSealer sealer,
    List<Sentinel> sentinels,
  ) =>
      FixtureSentinelStore({
        for (final s in sentinels) s.id: SealedSentinel(s, sealer.seal(s)),
      });

  @override
  final Map<String, SealedSentinel> sentinels;
}
