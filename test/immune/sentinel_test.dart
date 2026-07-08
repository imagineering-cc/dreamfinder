import 'package:dreamfinder/src/immune/probe.dart';
import 'package:dreamfinder/src/immune/probe_registry.dart';
import 'package:dreamfinder/src/immune/probes/content_integrity_probe.dart';
import 'package:dreamfinder/src/immune/sentinel.dart';
import 'package:test/test.dart';

void main() {
  group('SentinelSealer', () {
    final sealer = SentinelSealer('immune-secret-key');
    const golden = Sentinel(
      id: 'golden-1',
      payload: 'the river remembers',
      version: 'v1',
    );

    test('seal is deterministic for the same key + sentinel', () {
      expect(sealer.seal(golden), sealer.seal(golden));
    });

    test('verify accepts a genuine seal', () {
      expect(sealer.verify(golden, sealer.seal(golden)), isTrue);
    });

    test('verify rejects a tampered payload (forge-proof)', () {
      final seal = sealer.seal(golden);
      const forged = Sentinel(
        id: 'golden-1',
        payload: 'the river forgot', // attacker-substituted content
        version: 'v1',
      );
      // Same id + version, different payload → the seal cannot validate without
      // the key. This is the poisoned-corpus defence.
      expect(sealer.verify(forged, seal), isFalse);
    });

    test('verify rejects a seal from a different key', () {
      final otherKey = SentinelSealer('a-different-secret');
      expect(sealer.verify(golden, otherKey.seal(golden)), isFalse);
    });

    test('a version bump changes the seal (retire, not fire)', () {
      const v2 = Sentinel(
          id: 'golden-1', payload: 'the river remembers', version: 'v2');
      expect(sealer.seal(v2), isNot(sealer.seal(golden)));
    });

    test('a nonempty key is required', () {
      expect(() => SentinelSealer(''), throwsA(isA<ArgumentError>()));
    });
  });

  group('FixtureSentinelStore', () {
    final sealer = SentinelSealer('k');
    test('seals every sentinel up front, keyed by id', () {
      final store = FixtureSentinelStore.sealed(sealer, const [
        Sentinel(id: 'a', payload: 'pa', version: 'v1'),
        Sentinel(id: 'b', payload: 'pb', version: 'v1'),
      ]);
      expect(store.sentinels.keys, containsAll(<String>['a', 'b']));
      final a = store.sentinels['a']!;
      expect(sealer.verify(a.sentinel, a.seal), isTrue);
    });
  });

  group('ContentIntegrityProbe', () {
    final sealer = SentinelSealer('immune-secret-key');
    const golden =
        Sentinel(id: 'lore-canary', payload: 'GOLDEN', version: 'v1');
    final store = FixtureSentinelStore.sealed(sealer, const [golden]);
    final goldenSeal = FixtureSentinelStore.sealed(sealer, const [golden])
        .sentinels['lore-canary']!
        .seal;

    ContentIntegrityProbe probe(SealedFetcher? fetch) => ContentIntegrityProbe(
          id: 'probe_lore_content',
          sentinelId: 'lore-canary',
          store: store,
          sealer: sealer,
          fetchSealed: fetch,
        );

    test('degraded when the fetcher is not wired (disabled capability)',
        () async {
      final r = await probe(null).run();
      expect(r.status, ProbeStatus.degraded);
      expect(r.shouldPage, isFalse);
    });

    test('ok when the real path returns the true sealed golden', () async {
      final r = await probe(
        (_) async => (payload: 'GOLDEN', seal: goldenSeal),
      ).run();
      expect(r.status, ProbeStatus.ok);
    });

    test('failed (content-hollow) when the known sentinel is not retrievable',
        () async {
      // The real path could not surface a doc we KNOW exists — the integration
      // is returning nothing for a query it must answer.
      final r = await probe((_) async => null).run();
      expect(r.status, ProbeStatus.failed);
      expect(r.shouldPage, isTrue);
      expect(r.detail, contains('not retrievable'));
    });

    test('failed (forgery) when payload is tampered — seal no longer validates',
        () async {
      // An attacker plants a look-alike doc with the sentinel id but different
      // content. Without the key they cannot produce a valid seal.
      final r = await probe(
        (_) async => (payload: 'POISONED', seal: goldenSeal),
      ).run();
      expect(r.status, ProbeStatus.failed);
      expect(r.shouldPage, isTrue);
      expect(r.detail, contains('seal'));
    });

    test('failed when the seal itself is forged (attacker-computed)', () async {
      final r = await probe(
        (_) async => (payload: 'POISONED', seal: 'deadbeef'),
      ).run();
      expect(r.status, ProbeStatus.failed);
    });

    test('declares pureRead side-effect and carries sentinel version', () {
      final p = probe((_) async => null);
      expect(p.sideEffect, SideEffect.pureRead);
      expect(p.sentinelVersion, 'v1');
    });
  });

  group('Probe lifecycle metadata', () {
    test('base defaults: owner=immune, no sentinelVersion, no expiry', () {
      final p = _BareProbe();
      expect(p.owner, 'immune');
      expect(p.sentinelVersion, isNull);
      expect(p.expiry, isNull);
    });
  });

  group('ProbeRegistry.expired', () {
    final t0 = DateTime.utc(2026, 7, 9, 12);
    test('lists probes past their recalibration date, ignoring null/future',
        () {
      final registry = ProbeRegistry([
        _ExpiringProbe('stale', t0.subtract(const Duration(days: 1))),
        _ExpiringProbe('fresh', t0.add(const Duration(days: 30))),
        _BareProbe(), // no expiry — never expires
      ]);
      final expired = registry.expired(t0);
      expect(expired, <String>['stale']);
    });

    test('empty when nothing is past its date', () {
      final registry = ProbeRegistry([
        _ExpiringProbe('fresh', t0.add(const Duration(days: 1))),
      ]);
      expect(registry.expired(t0), isEmpty);
    });
  });
}

class _BareProbe extends Probe {
  @override
  String get id => 'bare';
  @override
  Future<ProbeResult> run() async =>
      const ProbeResult(id: 'bare', status: ProbeStatus.ok);
}

class _ExpiringProbe extends Probe {
  _ExpiringProbe(this._id, this._expiry);
  final String _id;
  final DateTime _expiry;
  @override
  String get id => _id;
  @override
  DateTime? get expiry => _expiry;
  @override
  Future<ProbeResult> run() async =>
      ProbeResult(id: _id, status: ProbeStatus.ok);
}
