import 'dart:async';
import 'dart:convert';

import 'package:dreamfinder/src/agent/system_prompt.dart';
import 'package:dreamfinder/src/immune/boot_checks.dart';
import 'package:dreamfinder/src/immune/probe.dart';
import 'package:dreamfinder/src/immune/probe_registry.dart';
import 'package:dreamfinder/src/immune/probes/auth_probe.dart';
import 'package:dreamfinder/src/immune/probes/calendar_probe.dart';
import 'package:dreamfinder/src/immune/probes/deep_search_probe.dart';
import 'package:dreamfinder/src/immune/probes/rag_probe.dart';
import 'package:test/test.dart';

/// A probe with a scripted result / behaviour, for registry tests.
class _ScriptedProbe extends Probe {
  _ScriptedProbe(this._id, this._body);
  final String _id;
  final Future<ProbeResult> Function() _body;
  @override
  String get id => _id;
  @override
  Future<ProbeResult> run() => _body();
}

/// A probe that (illegally, for PR1) declares a send side-effect.
class _SendProbe extends Probe {
  @override
  String get id => 'send';
  @override
  SideEffect get sideEffect => SideEffect.externalSend;
  @override
  Future<ProbeResult> run() async =>
      const ProbeResult(id: 'send', status: ProbeStatus.ok);
}

String _deepSearchJson({
  required List<String> searched,
  List<String> failed = const [],
  int totalCount = 3,
  String? error,
}) =>
    jsonEncode(<String, dynamic>{
      if (error != null) 'error': error,
      'sources_searched': searched,
      'sources_unavailable': <String>[],
      'sources_failed': failed,
      'total_count': totalCount,
      'results': <Object>[],
    });

void main() {
  group('ProbeRegistry', () {
    test('reports unknown (not failed) when a probe throws', () async {
      final registry = ProbeRegistry([
        _ScriptedProbe('boom', () async => throw StateError('kaboom')),
      ]);
      final results = await registry.runAll();
      expect(results.single.status, ProbeStatus.unknown);
      expect(results.single.detail, contains('threw'));
    });

    test('reports unknown when a probe exceeds the hard timeout', () async {
      final registry = ProbeRegistry(
        [
          _ScriptedProbe('slow', () async {
            await Future<void>.delayed(const Duration(seconds: 30));
            return const ProbeResult(id: 'slow', status: ProbeStatus.ok);
          }),
        ],
        probeTimeout: const Duration(milliseconds: 50),
      );
      final results = await registry.runAll();
      expect(results.single.status, ProbeStatus.unknown);
      expect(results.single.detail, contains('timed out'));
    });

    test('admission control rejects a write/send probe at construction', () {
      expect(
        () => ProbeRegistry([_SendProbe()]),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('one broken probe does not stop the others', () async {
      final registry = ProbeRegistry([
        _ScriptedProbe('bad', () async => throw Exception('x')),
        _ScriptedProbe(
          'good',
          () async => const ProbeResult(id: 'good', status: ProbeStatus.ok),
        ),
      ]);
      final results = await registry.runAll();
      expect(results.map((r) => r.status),
          [ProbeStatus.unknown, ProbeStatus.ok]);
    });
  });

  group('AuthProbe', () {
    test('ok when on OAuth', () async {
      final r = await AuthProbe(
        readAuthModeLabel: () => 'OAuth (Claude Max)',
      ).run();
      expect(r.status, ProbeStatus.ok);
    });

    test('failed on metered drift (no maintenance)', () async {
      final r = await AuthProbe(readAuthModeLabel: () => 'API key').run();
      expect(r.status, ProbeStatus.failed);
      expect(r.shouldPage, isTrue);
    });

    test('failed on OAuth→API-key FALLBACK (label contains "OAuth" but is '
        'metered)', () async {
      // Regression: the fallback label is "API key (OAuth fallback)". A naive
      // contains("oauth") check would false-negative this real drift.
      final r = await AuthProbe(
        readAuthModeLabel: () => 'API key (OAuth fallback)',
      ).run();
      expect(r.status, ProbeStatus.failed);
      expect(r.shouldPage, isTrue);
    });

    test('degraded (not failed) under metered maintenance window', () async {
      final r = await AuthProbe(
        readAuthModeLabel: () => 'API key',
        maintenanceMode: MaintenanceMode.meteredAllowed,
      ).run();
      expect(r.status, ProbeStatus.degraded);
      expect(r.shouldPage, isFalse);
    });
  });

  group('DeepSearchProbe', () {
    test('ok when sources searched and none failed', () async {
      final r = await DeepSearchProbe(
        executeTool: (_, __) async => _deepSearchJson(searched: ['memory']),
      ).run();
      expect(r.status, ProbeStatus.ok);
    });

    test('failed on the hollow signal: zero sources searched', () async {
      // The exact 11-commit incident: the tool searched nothing.
      final r = await DeepSearchProbe(
        executeTool: (_, __) async => _deepSearchJson(searched: []),
      ).run();
      expect(r.status, ProbeStatus.failed);
      expect(r.detail, contains('zero sources'));
    });

    test('failed when a source errored', () async {
      final r = await DeepSearchProbe(
        executeTool: (_, __) async =>
            _deepSearchJson(searched: ['memory'], failed: ['outline']),
      ).run();
      expect(r.status, ProbeStatus.failed);
    });

    test('failed on an explicit tool error payload', () async {
      final r = await DeepSearchProbe(
        executeTool: (_, __) async =>
            jsonEncode({'error': 'tool not found: deep_search'}),
      ).run();
      expect(r.status, ProbeStatus.failed);
    });
  });

  group('CalendarProbe', () {
    CalendarEvent event(String summary) =>
        CalendarEvent.fromJson({'summary': summary, 'start': '2026-07-10T09:00:00Z'});

    test('ok when the pinned recurring event is present', () async {
      final r = await CalendarProbe(
        fetchUpcoming: ({DateTime? now}) async =>
            [event('Weekly Imagineering Meetup'), event('Something else')],
        expectedSummarySubstring: 'Imagineering',
      ).run();
      expect(r.status, ProbeStatus.ok);
    });

    test('failed when non-empty but the pinned event is absent (wrong cal)',
        () async {
      final r = await CalendarProbe(
        fetchUpcoming: ({DateTime? now}) async => [event('Dentist')],
        expectedSummarySubstring: 'Imagineering',
      ).run();
      expect(r.status, ProbeStatus.failed);
    });

    test('degraded (not failed) when the calendar is empty (ambiguous)',
        () async {
      final r = await CalendarProbe(
        fetchUpcoming: ({DateTime? now}) async => [],
        expectedSummarySubstring: 'Imagineering',
      ).run();
      expect(r.status, ProbeStatus.degraded);
      expect(r.shouldPage, isFalse);
    });
  });

  group('RagProbe', () {
    test('ok when retrieval returns results', () async {
      final r = await RagProbe(retrieveCount: () async => 4).run();
      expect(r.status, ProbeStatus.ok);
    });

    test('degraded when retrieval is disabled (VOYAGE unset)', () async {
      final r = await RagProbe(retrieveCount: null).run();
      expect(r.status, ProbeStatus.degraded);
      expect(r.shouldPage, isFalse);
    });

    test('degraded (not failed) when retrieval returns zero (ambiguous)',
        () async {
      final r = await RagProbe(retrieveCount: () async => 0).run();
      expect(r.status, ProbeStatus.degraded);
    });
  });
}
