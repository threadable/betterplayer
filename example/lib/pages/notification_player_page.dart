import 'package:threadable_better_player/threadable_better_player.dart';
import 'package:threadable_better_player_example/constants.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class NotificationPlayerPage extends StatefulWidget {
  const NotificationPlayerPage({super.key});

  @override
  _NotificationPlayerPageState createState() => _NotificationPlayerPageState();
}

class _NotificationPlayerPageState extends State<NotificationPlayerPage> {
  late BetterPlayerController _betterPlayerController;
  String? _setupError;

  @override
  void initState() {
    BetterPlayerConfiguration betterPlayerConfiguration =
        BetterPlayerConfiguration(
          aspectRatio: 16 / 9,
          fit: BoxFit.contain,
          handleLifecycle: true,
        );
    _betterPlayerController = BetterPlayerController(betterPlayerConfiguration);
    _setupDataSource();
    super.initState();
  }

  Future<void> _setupDataSource() async {
    // String imageUrl = await Utils.getFileUrl(Constants.logo);
    BetterPlayerDataSource dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      Constants.elephantDreamVideoUrl,
      notificationConfiguration: BetterPlayerNotificationConfiguration(
        showNotification: true,
        title: "Elephant dream",
        author: "Some author",
        imageUrl: Constants.catImageUrl,
      ),
    );

    try {
      await _betterPlayerController.setupDataSource(dataSource);
    } on PlatformException catch (error) {
      debugPrint("Failed to set up notification player: ${error.message}");
      if (mounted) {
        setState(() {
          _setupError = error.message ?? error.toString();
        });
      }
    } catch (error) {
      debugPrint("Failed to set up notification player: $error");
      if (mounted) {
        setState(() {
          _setupError = error.toString();
        });
      }
    }
  }

  @override
  void dispose() {
    _betterPlayerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text("Notification player")),
      body: Column(
        children: [
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Click play on player to show notification in status bar.",
              style: TextStyle(fontSize: 16),
            ),
          ),
          if (_setupError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                "Failed to load demo video: $_setupError",
                style: TextStyle(color: Colors.red),
              ),
            ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(controller: _betterPlayerController),
          ),
        ],
      ),
    );
  }
}
