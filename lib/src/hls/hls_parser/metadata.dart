import 'package:threadable_better_player/src/hls/hls_parser/hls_track_metadata_entry.dart';
import 'package:threadable_better_player/src/core/iterable_utils.dart';

class Metadata {
  Metadata(this.list);

  final List<HlsTrackMetadataEntry> list;

  @override
  bool operator ==(Object other) {
    if (other is Metadata) {
      return listEquals(other.list, list);
    }
    return false;
  }

  @override
  int get hashCode => list.hashCode;
}
