import 'package:flutter_test/flutter_test.dart';
import 'package:threadable_better_player/src/hls/hls_parser/exception.dart';
import 'package:threadable_better_player/src/hls/hls_parser/hls_master_playlist.dart';
import 'package:threadable_better_player/src/hls/hls_parser/hls_media_playlist.dart';
import 'package:threadable_better_player/src/hls/hls_parser/hls_playlist_parser.dart';
import 'package:threadable_better_player/src/hls/hls_parser/mime_types.dart';

void main() {
  final parser = HlsPlaylistParser.create();

  group('HlsPlaylistParser', () {
    test('parses master playlists and resolves relative URLs', () async {
      const input = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="audio/en.m3u8"
#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English",DEFAULT=YES,AUTOSELECT=YES,LANGUAGE="en",URI="subs/en.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=1280000,AVERAGE-BANDWIDTH=1000000,CODECS="avc1.64001f,mp4a.40.2",RESOLUTION=640x360,FRAME-RATE=30.0,AUDIO="audio",SUBTITLES="subs"
low/index.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=2560000,CODECS="avc1.640028,mp4a.40.2",RESOLUTION=1280x720,AUDIO="audio",SUBTITLES="subs"
high/index.m3u8
''';

      final result = await parser.parseString(
        Uri.parse('https://example.com/hls/master.m3u8'),
        input,
      );

      expect(result, isA<HlsMasterPlaylist>());
      final master = result as HlsMasterPlaylist;
      expect(master.hasIndependentSegments, isTrue);
      expect(master.variants, hasLength(2));
      expect(
        master.variants.first.url.toString(),
        'https://example.com/hls/low/index.m3u8',
      );
      expect(master.variants.first.format.width, 640);
      expect(master.variants.first.format.height, 360);
      expect(master.variants.first.format.frameRate, 30);
      expect(
        master.audios.single.url.toString(),
        'https://example.com/hls/audio/en.m3u8',
      );
      expect(master.subtitles.single.format.language, 'en');
      expect(master.mediaPlaylistUrls, hasLength(4));
    });

    test('parses media playlists, durations, and discontinuities', () async {
      const input = '''
#EXTM3U
#EXT-X-VERSION:3
#EXT-X-TARGETDURATION:10
#EXT-X-MEDIA-SEQUENCE:1
#EXTINF:9.0,first
seg1.ts
#EXT-X-DISCONTINUITY
#EXTINF:8.5,second
seg2.ts
#EXT-X-ENDLIST
''';

      final result = await parser.parseString(
        Uri.parse('https://example.com/hls/video.m3u8'),
        input,
      );

      expect(result, isA<HlsMediaPlaylist>());
      final media = result as HlsMediaPlaylist;
      expect(media.version, 3);
      expect(media.targetDurationUs, 10000000);
      expect(media.mediaSequence, 1);
      expect(media.hasEndTag, isTrue);
      expect(media.segments, hasLength(2));
      expect(media.segments.first.url, 'seg1.ts');
      expect(media.segments.first.durationUs, 9000000);
      expect(media.segments.last.relativeDiscontinuitySequence, 1);
      expect(media.durationUs, 17500000);
    });

    test('rejects an invalid header and a playlist without a type tag', () {
      expect(
        () => parser.parseString(null, '#EXT-X-VERSION:3'),
        throwsA(isA<UnrecognizedInputFormatException>()),
      );
      expect(
        () => parser.parseString(null, '#EXTM3U\n#EXT-X-VERSION:3'),
        throwsA(isA<FormatException>()),
      );
    });

    test('parses a playlist with an encrypted media segment', () async {
      const input = '''
#EXTM3U
#EXT-X-TARGETDURATION:6
#EXT-X-KEY:METHOD=AES-128,URI="key.bin",IV=0x00000000000000000000000000000001
#EXTINF:5.5,encrypted
encrypted.ts
#EXT-X-ENDLIST
''';

      final result =
          await parser.parseString(
                Uri.parse('https://example.com/stream/index.m3u8'),
                input,
              )
              as HlsMediaPlaylist;

      expect(result.segments.single.fullSegmentEncryptionKeyUri, 'key.bin');
      expect(
        result.segments.single.encryptionIV,
        '0x00000000000000000000000000000001',
      );
    });

    test('maps common codecs and MIME types', () {
      expect(MimeTypes.getMediaMimeType('avc1.64001f'), MimeTypes.videoH264);
      expect(
        MimeTypes.getMediaMimeType('hvc1.1.6.L93.B0'),
        MimeTypes.videoH265,
      );
      expect(
        MimeTypes.getMediaMimeType('dvhe.05.06'),
        MimeTypes.videoDolbyVision,
      );
      expect(MimeTypes.getMediaMimeType('av01.0.05M.08'), MimeTypes.videoAv1);
      expect(MimeTypes.getMediaMimeType('vp09.00.10.08'), MimeTypes.videoVp9);
      expect(MimeTypes.getMediaMimeType('mp4a.40.2'), MimeTypes.audioAac);
      expect(MimeTypes.getMediaMimeType('ac-3'), MimeTypes.audioAc3);
      expect(MimeTypes.getMediaMimeType('ec-3'), MimeTypes.audioEAc3);
      expect(MimeTypes.getMediaMimeType('opus'), MimeTypes.audioOpus);
      expect(MimeTypes.getMediaMimeType('flac'), MimeTypes.audioFlac);
      expect(MimeTypes.getMediaMimeType('unknown'), isNull);

      expect(MimeTypes.getTrackType(MimeTypes.videoMp4), isNotNull);
      expect(MimeTypes.getTrackType(MimeTypes.audioMp4), isNotNull);
      expect(MimeTypes.getTrackType(MimeTypes.textVtt), isNotNull);
      expect(MimeTypes.getTrackType(MimeTypes.applicationId3), isNotNull);
      expect(MimeTypes.getTopLevelType('video/mp4'), 'video');
      expect(MimeTypes.getTopLevelType('invalid'), isNull);
      expect(MimeTypes.isVideo(MimeTypes.videoMp4), isTrue);
      expect(MimeTypes.isAudio(MimeTypes.audioMp4), isTrue);
      expect(MimeTypes.isText(MimeTypes.textVtt), isTrue);
    });
  });
}
