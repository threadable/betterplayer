import 'package:threadable_better_player/threadable_better_player.dart';

class BetterPlayerMockController extends BetterPlayerController {
  BetterPlayerMockController(
    BetterPlayerConfiguration betterPlayerConfiguration, {
    BetterPlayerPlaylistConfiguration betterPlayerPlaylistConfiguration =
        const BetterPlayerPlaylistConfiguration(),
  }) : super(betterPlayerConfiguration,
            betterPlayerPlaylistConfiguration:
                betterPlayerPlaylistConfiguration);
}
