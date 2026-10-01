import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:threadable_better_player/src/controls/better_player_clickable_widget.dart';
import 'package:threadable_better_player/src/controls/better_player_material_controls.dart';
import 'package:threadable_better_player/src/controls/better_player_material_progress_bar.dart';
import 'package:threadable_better_player/src/hls/better_player_hls_utils.dart';
import 'package:threadable_better_player/src/subtitles/better_player_subtitles_factory.dart';
import 'package:threadable_better_player/threadable_better_player.dart';

import 'better_player_test_utils.dart';
import 'mock_video_player_controller.dart';

const _masterPlaylist = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-STREAM-INF:BANDWIDTH=1280000,RESOLUTION=640x360,CODECS="avc1.64001f"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,RESOLUTION=1280x720,CODECS="avc1.640028"
high/index.m3u8
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('better_player_channel');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('ASMS utilities', () {
    test('identifies and parses HLS and DASH sources', () async {
      expect(BetterPlayerAsmsUtils.isDataSourceHls('stream.m3u8'), isTrue);
      expect(BetterPlayerAsmsUtils.isDataSourceDash('manifest.mpd'), isTrue);
      expect(BetterPlayerAsmsUtils.isDataSourceAsms('video.mp4'), isFalse);

      final tracks = await BetterPlayerHlsUtils.parseTracks(
        _masterPlaylist,
        'https://example.com/hls/master.m3u8',
      );
      final languages = await BetterPlayerHlsUtils.parseLanguages(
        _masterPlaylist,
        'https://example.com/hls/master.m3u8',
      );
      final subtitles = await BetterPlayerHlsUtils.parseSubtitles(
        _masterPlaylist,
        'https://example.com/hls/master.m3u8',
      );
      final parsed = await BetterPlayerAsmsUtils.parse(
        _masterPlaylist,
        'https://example.com/hls/master.m3u8',
      );

      expect(tracks, hasLength(3));
      expect(tracks.first.width, 0);
      expect(tracks[1].height, 360);
      expect(languages, isEmpty);
      expect(subtitles, isEmpty);
      expect(parsed.tracks, hasLength(3));
    });

    test('returns empty HLS results for malformed playlists', () async {
      expect(
        await BetterPlayerHlsUtils.parseTracks(
          'not a playlist',
          'https://example.com/video.m3u8',
        ),
        isEmpty,
      );
      final parsed = await BetterPlayerAsmsUtils.parse(
        '<invalid',
        'https://example.com/manifest.mpd',
      );
      expect(parsed.tracks, isEmpty);
      expect(await BetterPlayerAsmsUtils.getDataFromUrl('not a uri'), isEmpty);
    });
  });

  group('subtitle factory', () {
    test(
      'parses subtitles from memory and ignores unsupported sources',
      () async {
        const content =
            '1\n00:00:00.000 --> 00:00:01.000\nHello\n\n'
            '2\n00:00:01.000 --> 00:00:02.000\nWorld';
        final source = BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.memory,
          content: content,
        );

        final subtitles = await BetterPlayerSubtitlesFactory.parseSubtitles(
          source,
        );
        final unsupported = await BetterPlayerSubtitlesFactory.parseSubtitles(
          BetterPlayerSubtitlesSource(
            type: BetterPlayerSubtitlesSourceType.none,
          ),
        );

        expect(subtitles, hasLength(2));
        expect(subtitles.first.texts, ['Hello']);
        expect(unsupported, isEmpty);
      },
    );

    test('returns no cues for a memory source without separators', () async {
      final subtitles = await BetterPlayerSubtitlesFactory.parseSubtitles(
        BetterPlayerSubtitlesSource(
          type: BetterPlayerSubtitlesSourceType.memory,
          content: 'not a subtitle file',
        ),
      );

      expect(subtitles, isEmpty);
    });
  });

  testWidgets('material controls render and toggle playback', (
    WidgetTester tester,
  ) async {
    final videoController = MockVideoPlayerController();
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
      controller: videoController,
    );
    await controller.setupDataSource(
      BetterPlayerDataSource.network('https://example.com/video.mp4'),
    );
    videoController.setDuration(const Duration(seconds: 100));

    await tester.pumpWidget(
      MaterialApp(
        home: BetterPlayerControllerProvider(
          controller: controller,
          child: SizedBox(
            width: 400,
            height: 250,
            child: BetterPlayerMaterialControls(
              controlsConfiguration: const BetterPlayerControlsConfiguration(
                enablePip: false,
                enableOverflowMenu: false,
              ),
              onControlsVisibilityChanged: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 250));
    controller.setControlsVisibility(true);
    await tester.pump();

    final playPause = find.byKey(
      const Key('better_player_material_controls_play_pause_button'),
    );
    expect(playPause, findsOneWidget);
    await tester.tapAt(const Offset(200, 100));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(playPause);
    await tester.pump();
    expect(videoController.value.isPlaying, isTrue);
    await tester.tap(playPause);
    await tester.pump();
    expect(videoController.value.isPlaying, isFalse);
  });

  testWidgets('material controls show an error state', (
    WidgetTester tester,
  ) async {
    final videoController = MockVideoPlayerController();
    videoController.value = VideoPlayerValue.erroneous('broken');
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
      controller: videoController,
    );
    await controller.setupDataSource(
      BetterPlayerDataSource.network('https://example.com/video.mp4'),
    );
    videoController.value = VideoPlayerValue.erroneous('broken');

    await tester.pumpWidget(
      MaterialApp(
        home: BetterPlayerControllerProvider(
          controller: controller,
          child: const SizedBox(
            width: 400,
            height: 250,
            child: BetterPlayerMaterialControls(
              controlsConfiguration: BetterPlayerControlsConfiguration(
                enablePip: false,
                enableOverflowMenu: false,
              ),
              onControlsVisibilityChanged: _ignoreVisibility,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byIcon(Icons.warning), findsOneWidget);
    expect(find.text("Video can't be played"), findsOneWidget);
  });

  testWidgets('progress bar seeks on tap and drag', (
    WidgetTester tester,
  ) async {
    final videoController = MockVideoPlayerController();
    videoController.setDuration(const Duration(seconds: 100));
    final controller = BetterPlayerTestUtils.setupBetterPlayerMockController(
      controller: videoController,
    );
    await controller.setupDataSource(
      BetterPlayerDataSource.network('https://example.com/video.mp4'),
    );

    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(300, 100)),
        child: MaterialApp(
          home: SizedBox(
            width: 300,
            height: 100,
            child: BetterPlayerMaterialVideoProgressBar(
              videoController,
              controller,
            ),
          ),
        ),
      ),
    );
    final progressBar = find.byType(BetterPlayerMaterialVideoProgressBar);
    await tester.tapAt(tester.getCenter(progressBar));
    await tester.pump();
    expect(videoController.value.position.inSeconds, greaterThan(0));

    final progressOrigin = tester.getTopLeft(progressBar);
    await tester.dragFrom(
      progressOrigin + const Offset(20, 50),
      const Offset(240, 0),
    );
    await tester.pump();
    expect(videoController.value.position.inSeconds, greaterThan(20));
  });

  testWidgets('gesture and clickable helpers forward interaction', (
    WidgetTester tester,
  ) async {
    var clicked = 0;
    var inherited = false;

    await tester.pumpWidget(
      MaterialApp(
        home: BetterPlayerMultipleGestureDetector(
          child: Column(
            children: [
              BetterPlayerMaterialClickableWidget(
                onTap: () => clicked++,
                child: const SizedBox(width: 100, height: 50),
              ),
              Builder(
                builder: (context) {
                  inherited =
                      BetterPlayerMultipleGestureDetector.of(context) != null;
                  return const SizedBox(
                    key: Key('gesture-target'),
                    width: 100,
                    height: 50,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(
      find.byType(BetterPlayerMaterialClickableWidget),
      warnIfMissed: false,
    );
    await tester.pump();

    expect(clicked, 1);
    expect(inherited, isTrue);
    expect(find.byKey(const Key('gesture-target')), findsOneWidget);
  });

  test('creates progress colors', () {
    final colors = BetterPlayerProgressColors(
      playedColor: Colors.green,
      bufferedColor: Colors.blue,
      handleColor: Colors.yellow,
      backgroundColor: Colors.black,
    );

    expect(colors.playedPaint.color.toARGB32(), Colors.green.toARGB32());
    expect(colors.bufferedPaint.color.toARGB32(), Colors.blue.toARGB32());
    expect(colors.handlePaint.color.toARGB32(), Colors.yellow.toARGB32());
    expect(colors.backgroundPaint.color.toARGB32(), Colors.black.toARGB32());
  });
}

void _ignoreVisibility(bool _) {}
