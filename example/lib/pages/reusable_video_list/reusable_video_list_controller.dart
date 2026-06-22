import 'package:threadable_better_player/threadable_better_player.dart';

class ReusableVideoListController {
  final List<BetterPlayerController> _betterPlayerControllerRegistry = [];
  final List<BetterPlayerController> _usedBetterPlayerControllerRegistry = [];

  ReusableVideoListController() {
    for (int index = 0; index < 3; index++) {
      _betterPlayerControllerRegistry.add(
        BetterPlayerController(
          BetterPlayerConfiguration(handleLifecycle: false, autoDispose: false),
        ),
      );
    }
  }

  BetterPlayerController? getBetterPlayerController() {
    BetterPlayerController? freeController;
    for (final controller in _betterPlayerControllerRegistry) {
      if (!_usedBetterPlayerControllerRegistry.contains(controller)) {
        freeController = controller;
        break;
      }
    }

    if (freeController != null) {
      _usedBetterPlayerControllerRegistry.add(freeController);
    }

    return freeController;
  }

  void freeBetterPlayerController(
    BetterPlayerController? betterPlayerController,
  ) {
    _usedBetterPlayerControllerRegistry.remove(betterPlayerController);
  }

  void dispose() {
    _betterPlayerControllerRegistry.forEach((controller) {
      controller.dispose();
    });
  }
}
