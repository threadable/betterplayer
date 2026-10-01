import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'package:threadable_better_player/src/configuration/better_player_buffering_configuration.dart';
import 'package:threadable_better_player/src/video_player/method_channel_video_player.dart';
import 'package:threadable_better_player/src/video_player/video_player_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('better_player_channel');
  late MethodChannelVideoPlayer platform;
  late List<MethodCall> calls;
  int absolutePosition = 1700000000000;
  Object? Function(MethodCall)? response;

  setUp(() {
    platform = MethodChannelVideoPlayer();
    calls = [];
    response = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
          calls.add(call);
          if (response != null) {
            return response!(call);
          }
          switch (call.method) {
            case 'create':
              return {'textureId': 42};
            case 'position':
              return 1250;
            case 'absolutePosition':
              return absolutePosition;
            case 'isPictureInPictureSupported':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('creates players with and without buffering configuration', () async {
    expect(await platform.create(), 42);
    expect(calls.last.method, 'create');
    expect(calls.last.arguments, isNull);

    expect(
      await platform.create(
        bufferingConfiguration: const BetterPlayerBufferingConfiguration(
          minBufferMs: 100,
          maxBufferMs: 200,
          bufferForPlaybackMs: 10,
          bufferForPlaybackAfterRebufferMs: 20,
        ),
      ),
      42,
    );
    expect(calls.last.arguments, {
      'minBufferMs': 100,
      'maxBufferMs': 200,
      'bufferForPlaybackMs': 10,
      'bufferForPlaybackAfterRebufferMs': 20,
    });
  });

  test('maps asset, network, and file sources to platform payloads', () async {
    final asset = DataSource(
      sourceType: DataSourceType.asset,
      asset: 'assets/video.mp4',
      package: 'example',
      showNotification: true,
      overriddenDuration: const Duration(seconds: 9),
    );
    final network = DataSource(
      sourceType: DataSourceType.network,
      uri: 'https://example.com/video.m3u8',
      formatHint: VideoFormat.hls,
      headers: {'Authorization': 'Bearer token'},
      useCache: true,
      cacheKey: 'video',
      licenseUrl: 'https://example.com/license',
      videoExtension: 'm3u8',
    );
    final file = DataSource(
      sourceType: DataSourceType.file,
      uri: '/tmp/video.mp4',
      clearKey: '{"keys":[]}',
    );

    await platform.setDataSource(7, asset);
    expect(calls.last.arguments['textureId'], 7);
    expect(
      calls.last.arguments['dataSource'],
      containsPair('asset', asset.asset),
    );
    expect(calls.last.arguments['dataSource']['overriddenDuration'], 9000);

    await platform.setDataSource(7, network);
    final networkPayload = calls.last.arguments['dataSource'];
    expect(networkPayload['uri'], network.uri);
    expect(networkPayload['formatHint'], 'hls');
    expect(networkPayload['headers'], network.headers);
    expect(networkPayload['useCache'], isTrue);
    expect(networkPayload['licenseUrl'], network.licenseUrl);

    await platform.setDataSource(7, file);
    final filePayload = calls.last.arguments['dataSource'];
    expect(filePayload['uri'], file.uri);
    expect(filePayload['useCache'], isFalse);
    expect(filePayload['clearKey'], file.clearKey);
  });

  test('adds source context when setDataSource fails', () async {
    response = (MethodCall call) {
      if (call.method == 'setDataSource') {
        throw PlatformException(code: 'source_error', message: 'Unavailable');
      }
      return null;
    };

    await expectLater(
      platform.setDataSource(
        1,
        DataSource(
          sourceType: DataSourceType.network,
          uri: 'https://example.com/video.mp4',
        ),
      ),
      throwsA(
        isA<PlatformException>().having(
          (error) => error.message,
          'message',
          contains('(source: https://example.com/video.mp4)'),
        ),
      ),
    );
  });

  test('forwards playback controls and returns positions', () async {
    await platform.init();
    await platform.dispose(3);
    await platform.setLooping(3, true);
    await platform.play(3);
    await platform.pause(3);
    await platform.setVolume(3, 0.5);
    await platform.setSpeed(3, 1.25);
    await platform.setTrackParameters(3, 1280, 720, 800000);
    await platform.seekTo(3, const Duration(seconds: 4));
    await platform.enablePictureInPicture(3, 1, 2, 3, 4);
    expect(await platform.isPictureInPictureEnabled(3), isTrue);
    await platform.disablePictureInPicture(3);
    await platform.setAudioTrack(3, 'English', 1);
    await platform.setMixWithOthers(3, true);
    await platform.clearCache();
    await platform.stopPreCache('https://example.com/video.mp4', 'video');

    expect(await platform.getPosition(3), const Duration(milliseconds: 1250));
    expect(
      await platform.getAbsolutePosition(3),
      DateTime.fromMillisecondsSinceEpoch(absolutePosition),
    );

    expect(
      calls.map((call) => call.method),
      containsAll(<String>[
        'init',
        'dispose',
        'setLooping',
        'play',
        'pause',
        'setVolume',
        'setSpeed',
        'setTrackParameters',
        'seekTo',
        'enablePictureInPicture',
        'isPictureInPictureSupported',
        'disablePictureInPicture',
        'setAudioTrack',
        'setMixWithOthers',
        'clearCache',
        'stopPreCache',
        'position',
        'absolutePosition',
      ]),
    );
    expect(
      calls.firstWhere((call) => call.method == 'seekTo').arguments,
      containsPair('location', 4000),
    );
    expect(
      calls
          .firstWhere((call) => call.method == 'enablePictureInPicture')
          .arguments,
      containsPair('width', 3.0),
    );
  });

  test('returns null for unavailable absolute positions', () async {
    absolutePosition = 0;
    expect(await platform.getAbsolutePosition(1), isNull);

    absolutePosition = 8640000000000001;
    expect(await platform.getAbsolutePosition(1), isNull);
  });

  test('builds the platform view for non-iOS targets', () {
    expect(platform.buildView(12), isA<Texture>());
  });
}
