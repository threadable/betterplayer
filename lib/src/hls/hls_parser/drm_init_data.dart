import 'scheme_data.dart';
import 'package:threadable_better_player/src/core/iterable_utils.dart';

class DrmInitData {
  DrmInitData({this.schemeType, this.schemeData = const []});

  final List<SchemeData> schemeData;
  final String? schemeType;

  @override
  bool operator ==(Object other) {
    if (other is DrmInitData) {
      return schemeType == other.schemeType &&
          listEquals(other.schemeData, schemeData);
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(schemeType, schemeData);
}
