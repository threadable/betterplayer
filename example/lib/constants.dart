class Constants {
  static const String bugBuckBunnyVideoUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4";
  static const String forBiggerBlazesUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4";
  static const String fileTestVideoUrl = "testvideo.mp4";
  static const String fileTestVideoEncryptUrl = "testvideo_encrypt.mp4";
  static const String networkTestVideoEncryptUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerFun.mp4";
  static const String fileExampleSubtitlesUrl = "example_subtitles.srt";
  static const String hlsTestStreamUrl =
      "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
  static const String hlsPlaylistUrl =
      "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
  static const Map<String, String> exampleResolutionsUrls = {
    "LOW":
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4",
    "MEDIUM":
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4",
    "LARGE":
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
    "EXTRA_LARGE":
        "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4",
  };
  static const String phantomVideoUrl =
      "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
  static const String elephantDreamVideoUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ElephantsDream.mp4";
  static const String forBiggerJoyridesVideoUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4";
  static const String verticalVideoUrl =
      "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4";
  static String logo = "logo.png";
  static String placeholderUrl =
      "https://storage.googleapis.com/gtv-videos-bucket/sample/images/BigBuckBunny.jpg";
  static String elephantDreamStreamUrl =
      "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";

  /// These DRM samples require valid, non-expired provider credentials.
  /// Keep them isolated from the default smoke-test pages.
  static String tokenEncodedHlsUrl =
      "https://amssamples.streaming.mediaservices.windows.net/830584f8-f0c8-4e41-968b-6538b9380aa5/TearsOfSteelTeaser.ism/manifest(format=m3u8-aapl)";
  static String tokenEncodedHlsToken = "";
  static String widevineVideoUrl =
      "https://storage.googleapis.com/wvmedia/cenc/h264/tears/tears_sd.mpd";
  static String widevineLicenseUrl =
      "https://proxy.uat.widevine.com/proxy?provider=widevine_test";
  static String fairplayHlsUrl =
      "https://fps.ezdrm.com/demo/hls/BigBuckBunny_320x180.m3u8";
  static String fairplayCertificateUrl =
      "https://github.com/koldo92/betterplayer/raw/fairplay_ezdrm/example/assets/eleisure.cer";
  static String fairplayLicenseUrl = "https://fps.ezdrm.com/api/licenses/";

  static String catImageUrl =
      "https://storage.googleapis.com/gtv-videos-bucket/sample/images/BigBuckBunny.jpg";
  static String dashStreamUrl =
      "https://dash.akamaized.net/akamai/bbb_30fps/bbb_30fps.mpd";
  static String segmentedSubtitlesHlsUrl =
      "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8";
}
