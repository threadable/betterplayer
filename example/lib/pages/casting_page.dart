import 'package:flutter/material.dart';
import 'package:threadable_better_player/threadable_better_player.dart';
import 'package:threadable_better_player_example/constants.dart';

class CastingPage extends StatefulWidget {
  const CastingPage({super.key});

  @override
  _CastingPageState createState() => _CastingPageState();
}

class _CastingPageState extends State<CastingPage> {
  late final BetterPlayerController _betterPlayerController;
  String? _message;

  @override
  void initState() {
    super.initState();

    _betterPlayerController = BetterPlayerController(
      BetterPlayerConfiguration(
        aspectRatio: 16 / 9,
        autoPlay: true,
        fit: BoxFit.contain,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          overflowMenuCustomItems: [
            BetterPlayerOverflowMenuItem(
              Icons.cast,
              'Cast / AirPlay',
              _showCastIntegrationMessage,
            ),
          ],
        ),
      ),
    );

    _betterPlayerController.addEventsListener((event) {
      if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
        debugPrint('Casting example failed: ${event.parameters}');
        if (mounted) {
          setState(() {
            _message = 'Failed to load cast example media. See console logs.';
          });
        }
      }
    });

    _betterPlayerController.setupDataSource(
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        Constants.hlsTestStreamUrl,
        liveStream: true,
        notificationConfiguration: BetterPlayerNotificationConfiguration(
          showNotification: true,
          title: 'Threadable cast example',
          author: 'Threadable',
          imageUrl: Constants.placeholderUrl,
        ),
      ),
    );
  }

  void _showCastIntegrationMessage() {
    setState(() {
      _message =
          'BetterPlayer prepares playback, media session, and notifications. '
          'Wire this menu action to your app-level Cast / AirPlay route picker '
          'or session manager.';
    });

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Hook this action into your Cast / AirPlay route picker.',
        ),
      ),
    );
  }

  @override
  void dispose() {
    _betterPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Casting')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'This example shows a cast-ready BetterPlayer setup with HLS media, '
            'notification metadata, and a custom overflow-menu Cast action.',
            style: TextStyle(fontSize: 16),
          ),
          const SizedBox(height: 12),
          const Text(
            'The plugin does not currently expose a full Dart Cast session picker. '
            'Use the Cast / AirPlay overflow action as the integration point for '
            'your app-level route picker or native Cast session manager.',
          ),
          const SizedBox(height: 16),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(controller: _betterPlayerController),
          ),
          if (_message != null) ...[
            const SizedBox(height: 16),
            Text(
              _message!,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
          const SizedBox(height: 16),
          const Text(
            'Try the three-dot menu in the player controls and tap Cast / AirPlay.',
          ),
        ],
      ),
    );
  }
}
