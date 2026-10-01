import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:threadable_better_player/src/asms/better_player_asms_subtitle_segment.dart';
import 'package:threadable_better_player/src/asms/better_player_asms_track.dart';
import 'package:threadable_better_player/src/clearkey/better_player_clearkey_utils.dart';
import 'package:threadable_better_player/src/configuration/better_player_buffering_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_cache_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_controls_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_data_source.dart';
import 'package:threadable_better_player/src/configuration/better_player_data_source_type.dart';
import 'package:threadable_better_player/src/configuration/better_player_drm_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_drm_type.dart';
import 'package:threadable_better_player/src/configuration/better_player_event.dart';
import 'package:threadable_better_player/src/configuration/better_player_event_type.dart';
import 'package:threadable_better_player/src/configuration/better_player_notification_configuration.dart';
import 'package:threadable_better_player/src/configuration/better_player_translations.dart';
import 'package:threadable_better_player/src/configuration/better_player_video_format.dart';
import 'package:threadable_better_player/src/dash/better_player_dash_utils.dart';
import 'package:threadable_better_player/src/subtitles/better_player_subtitle.dart';
import 'package:threadable_better_player/src/subtitles/better_player_subtitles_source.dart';
import 'package:threadable_better_player/src/subtitles/better_player_subtitles_source_type.dart';
import 'package:threadable_better_player/src/hls/hls_parser/mime_types.dart';

void main() {
  group('BetterPlayerDataSource', () {
    test('creates network, file, and memory sources', () {
      final network = BetterPlayerDataSource.network(
        'https://example.com/video.m3u8',
        headers: {'Authorization': 'Bearer token'},
        qualities: {'720p': 'https://example.com/720.mp4'},
        videoFormat: BetterPlayerVideoFormat.hls,
      );
      final file = BetterPlayerDataSource.file('/tmp/video.mp4');
      final memory = BetterPlayerDataSource.memory([
        0,
        1,
        2,
      ], videoExtension: 'mp4');

      expect(network.type, BetterPlayerDataSourceType.network);
      expect(network.headers, {'Authorization': 'Bearer token'});
      expect(network.resolutions, {'720p': 'https://example.com/720.mp4'});
      expect(network.videoFormat, BetterPlayerVideoFormat.hls);
      expect(file.type, BetterPlayerDataSourceType.file);
      expect(memory.type, BetterPlayerDataSourceType.memory);
      expect(memory.bytes, [0, 1, 2]);
      expect(memory.videoExtension, 'mp4');
    });

    test('copyWith overrides values while preserving the source', () {
      final source = BetterPlayerDataSource.network(
        'https://example.com/video.mp4',
        liveStream: true,
        overriddenDuration: const Duration(seconds: 30),
      );
      final copy = source.copyWith(
        url: 'https://example.com/other.mp4',
        liveStream: false,
        bufferingConfiguration: const BetterPlayerBufferingConfiguration(
          minBufferMs: 100,
        ),
      );

      expect(source.url, 'https://example.com/video.mp4');
      expect(copy.url, 'https://example.com/other.mp4');
      expect(copy.liveStream, isFalse);
      expect(copy.overriddenDuration, const Duration(seconds: 30));
      expect(copy.bufferingConfiguration.minBufferMs, 100);
    });

    test('rejects an empty memory source', () {
      expect(
        () => BetterPlayerDataSource.memory(const <int>[]),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('configuration models', () {
    test('uses stable defaults and supports configuration overrides', () {
      const buffering = BetterPlayerBufferingConfiguration();
      const cache = BetterPlayerCacheConfiguration();
      const notification = BetterPlayerNotificationConfiguration(
        showNotification: true,
        title: 'Title',
        author: 'Author',
      );
      final drm = BetterPlayerDrmConfiguration(
        drmType: BetterPlayerDrmType.widevine,
        licenseUrl: 'https://example.com/license',
      );
      const configuration = BetterPlayerConfiguration();
      final changed = configuration.copyWith(
        autoPlay: true,
        aspectRatio: 1.5,
        fit: BoxFit.contain,
        rotation: 90,
        handleLifecycle: false,
      );

      expect(buffering.minBufferMs, 25000);
      expect(buffering.maxBufferMs, 6553600);
      expect(cache.useCache, isFalse);
      expect(cache.preCacheSize, 3 * 1024 * 1024);
      expect(notification.showNotification, isTrue);
      expect(notification.title, 'Title');
      expect(drm.drmType, BetterPlayerDrmType.widevine);
      expect(configuration.autoPlay, isFalse);
      expect(configuration.fit, BoxFit.fill);
      expect(changed.autoPlay, isTrue);
      expect(changed.aspectRatio, 1.5);
      expect(changed.fit, BoxFit.contain);
      expect(changed.rotation, 90);
      expect(changed.handleLifecycle, isFalse);
    });

    test('provides material, white, cupertino, and theme control styles', () {
      const defaults = BetterPlayerControlsConfiguration();
      final white = BetterPlayerControlsConfiguration.white();
      final cupertino = BetterPlayerControlsConfiguration.cupertino();
      final themed = BetterPlayerControlsConfiguration.theme(ThemeData.dark());

      expect(defaults.showControls, isTrue);
      expect(defaults.enablePlaybackSpeed, isTrue);
      expect(white.controlBarColor, Colors.white);
      expect(white.textColor, Colors.black);
      expect(cupertino.playIcon, isNot(defaults.playIcon));
      expect(themed.textColor, ThemeData.dark().textTheme.bodyLarge?.color);
      expect(themed.iconsColor, ThemeData.dark().textTheme.labelLarge?.color);
    });

    test('creates subtitle and event models', () {
      final source = BetterPlayerSubtitlesSource.single(
        type: BetterPlayerSubtitlesSourceType.memory,
        name: 'English',
        content: 'content',
        selectedByDefault: true,
      ).single;
      final event = BetterPlayerEvent(
        BetterPlayerEventType.initialized,
        parameters: {'duration': 10},
      );

      expect(source.type, BetterPlayerSubtitlesSourceType.memory);
      expect(source.name, 'English');
      expect(source.content, 'content');
      expect(source.selectedByDefault, isTrue);
      expect(event.betterPlayerEventType, BetterPlayerEventType.initialized);
      expect(event.parameters, {'duration': 10});
    });

    test('creates the supported localized translations', () {
      final translations = <BetterPlayerTranslations>[
        BetterPlayerTranslations.polish(),
        BetterPlayerTranslations.chinese(),
        BetterPlayerTranslations.hindi(),
        BetterPlayerTranslations.arabic(),
        BetterPlayerTranslations.turkish(),
        BetterPlayerTranslations.vietnamese(),
        BetterPlayerTranslations.spanish(),
      ];

      expect(translations.map((translation) => translation.languageCode), [
        'pl',
        'zh',
        'hi',
        'ar',
        'tr',
        'vi',
        'es',
      ]);
      expect(translations.first.generalRetry, isNotEmpty);
      expect(translations.last.qualityAuto, isNotEmpty);
    });

    test('creates ASMS track and subtitle segment models', () {
      final track = BetterPlayerAsmsTrack.defaultTrack();
      final segment = BetterPlayerAsmsSubtitleSegment(
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        'https://example.com/captions.vtt',
      );

      expect(track.width, 0);
      expect(track.height, 0);
      expect(track == BetterPlayerAsmsTrack.defaultTrack(), isTrue);
      expect(track == Object(), isFalse);
      expect(track.hashCode, isA<int>());
      expect(segment.startTime, const Duration(seconds: 1));
      expect(segment.endTime, const Duration(seconds: 2));
      expect(segment.realUrl, contains('captions.vtt'));
    });
  });

  group('subtitle parsing', () {
    test('parses SRT cues with an index and comma milliseconds', () {
      final subtitle = BetterPlayerSubtitle(
        '2\n00:00:01,250 --> 00:00:03,500\nHello\nWorld',
        false,
      );

      expect(subtitle.index, 2);
      expect(subtitle.start, const Duration(milliseconds: 1250));
      expect(subtitle.end, const Duration(milliseconds: 3500));
      expect(subtitle.texts, ['Hello', 'World']);
    });

    test('parses WebVTT cues without an index and dot milliseconds', () {
      final subtitle = BetterPlayerSubtitle(
        '00:01.500 --> 00:03.000\nA cue',
        true,
      );

      expect(subtitle.index, -1);
      expect(subtitle.start, const Duration(milliseconds: 1500));
      expect(subtitle.end, const Duration(seconds: 3));
      expect(subtitle.texts, ['A cue']);
    });

    test('returns an empty subtitle for malformed input', () {
      final subtitle = BetterPlayerSubtitle('not a cue', false);

      expect(subtitle.start, isNull);
      expect(subtitle.end, isNull);
      expect(subtitle.texts, isNull);
    });
  });

  group('ClearKey and DASH helpers', () {
    test('encodes ClearKey values as base64url-compatible strings', () {
      final result =
          jsonDecode(
                BetterPlayerClearKeyUtils.generateKey({
                  '00000000000000000000000000000001':
                      '00000000000000000000000000000002',
                }),
              )
              as Map<String, dynamic>;

      expect(result['type'], 'temporary');
      expect(result['keys'], isA<List<dynamic>>());
      expect((result['keys'] as List).single['kty'], 'oct');
      expect((result['keys'] as List).single['kid'], contains('AQ'));
    });

    test('parses DASH video, audio, and subtitle adaptation sets', () async {
      const xml = '''
<MPD>
  <Period>
    <AdaptationSet mimeType="video/mp4">
      <Representation id="video-1" width="1280" height="720" bandwidth="800000" frameRate="30" codecs="avc1.64001f" />
    </AdaptationSet>
    <AdaptationSet mimeType="audio/mp4" lang="en" label="English" segmentAlignment="true" />
    <AdaptationSet mimeType="text/vtt" lang="en" segmentAlignment="false">
      <Representation><BaseURL>captions.vtt</BaseURL></Representation>
    </AdaptationSet>
  </Period>
</MPD>''';

      final result = await BetterPlayerDashUtils.parse(
        xml,
        'https://example.com/media/manifest.mpd',
      );
      final tracks = result.tracks!;
      final audios = result.audios!;
      final subtitles = result.subtitles!;

      expect(tracks, hasLength(1));
      expect(tracks.single.width, 1280);
      expect(tracks.single.mimeType, MimeTypes.videoH264);
      expect(audios, hasLength(1));
      expect(audios.single.label, 'English');
      expect(audios.single.segmentAlignment, isTrue);
      expect(subtitles, hasLength(1));
      expect(subtitles.single.url, 'https://example.com/media/captions.vtt');
    });

    test('returns empty DASH results for invalid XML', () async {
      final result = await BetterPlayerDashUtils.parse('<invalid', 'url');

      expect(result.tracks, isEmpty);
      expect(result.audios, isEmpty);
      expect(result.subtitles, isEmpty);
    });
  });
}
