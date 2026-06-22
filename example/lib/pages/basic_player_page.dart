import 'package:threadable_better_player/threadable_better_player.dart';
import 'package:threadable_better_player_example/constants.dart';
import 'package:threadable_better_player_example/utils.dart';
import 'package:flutter/material.dart';

class BasicPlayerPage extends StatefulWidget {
  const BasicPlayerPage({super.key});

  @override
  _BasicPlayerPageState createState() => _BasicPlayerPageState();
}

class _BasicPlayerPageState extends State<BasicPlayerPage> {
  late final BetterPlayerController _networkController;
  String? _networkError;

  @override
  void initState() {
    super.initState();

    _networkController = BetterPlayerController(
      const BetterPlayerConfiguration(aspectRatio: 16 / 9, autoPlay: true),
    );

    _networkController.addEventsListener((event) {
      if (event.betterPlayerEventType == BetterPlayerEventType.exception) {
        debugPrint(
          'Basic player failed for source: ${Constants.bugBuckBunnyVideoUrl}',
        );
        debugPrint('BetterPlayer exception parameters: ${event.parameters}');

        if (mounted) {
          setState(() {
            _networkError =
                'Failed to load demo video:\n${Constants.bugBuckBunnyVideoUrl}';
          });
        }
      }
    });

    _networkController.setupDataSource(
      BetterPlayerDataSource(
        BetterPlayerDataSourceType.network,
        Constants.bugBuckBunnyVideoUrl,
        headers: const {'User-Agent': 'Mozilla/5.0', 'Accept': '*/*'},
      ),
    );
  }

  @override
  void dispose() {
    _networkController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Basic player")),
      body: Column(
        children: [
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Basic player created with an explicit controller so demo errors can be handled.",
              style: TextStyle(fontSize: 16),
            ),
          ),
          if (_networkError != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _networkError!,
                style: const TextStyle(color: Colors.red),
              ),
            ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: BetterPlayer(controller: _networkController),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              "Next player shows video from file.",
              style: TextStyle(fontSize: 16),
            ),
          ),
          const SizedBox(height: 8),
          FutureBuilder<String>(
            future: Utils.getFileUrl(Constants.fileTestVideoUrl),
            builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
              if (snapshot.data != null) {
                return BetterPlayer.file(snapshot.data!);
              } else {
                return const SizedBox();
              }
            },
          ),
        ],
      ),
    );
  }
}
