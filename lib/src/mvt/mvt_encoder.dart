import 'dart:typed_data';

import '../pbf/pbf_writer.dart';
import 'mvt_geometry.dart';
import 'mvt_tile.dart';

/// Thrown when a tile cannot be encoded.
class MvtEncodeException implements Exception {
  final String message;

  const MvtEncodeException(this.message);

  @override
  String toString() => 'MvtEncodeException: $message';
}

/// Encodes an [MvtTile] into Mapbox Vector Tile 2.1 bytes.
///
/// The output is a protobuf message, *uncompressed* — callers gzip it, because
/// the container decides that: a PMTiles archive records its tile compression
/// once in its header rather than per tile.
///
/// Attribute keys and values are dictionary-encoded per layer: each distinct
/// key and each distinct value is written once and features reference them by
/// index. This is why a schema that reuses a small vocabulary (`class: primary`
/// on ten thousand roads) produces far smaller tiles than one that writes free
/// text per feature.
class MvtEncoder {
  const MvtEncoder();

  // Field numbers from the vector tile schema. See
  // https://github.com/mapbox/vector-tile-spec/blob/master/2.1/vector_tile.proto
  static const int _tileLayers = 3;

  static const int _layerName = 1;
  static const int _layerFeatures = 2;
  static const int _layerKeys = 3;
  static const int _layerValues = 4;
  static const int _layerExtent = 5;
  static const int _layerVersion = 15;

  static const int _featureId = 1;
  static const int _featureTags = 2;
  static const int _featureType = 3;
  static const int _featureGeometry = 4;

  static const int _valueString = 1;
  static const int _valueDouble = 3;
  static const int _valueInt = 4;
  static const int _valueBool = 7;

  /// Vector tile spec version implemented here.
  static const int specVersion = 2;

  /// Encodes [tile].
  ///
  /// Layers that contribute no features are skipped — whether they were empty
  /// to begin with or every feature's geometry turned out degenerate. They
  /// would only add a name to the output and change nothing on screen.
  Uint8List encode(MvtTile tile) {
    final writer = PbfWriter();

    for (final layer in tile.layers) {
      if (layer.features.isEmpty) continue;
      final encoded = _encodeLayer(layer);
      if (encoded != null) writer.writeMessage(_tileLayers, encoded);
    }

    return writer.toBytes();
  }

  /// Encodes one layer, or returns null if nothing in it survived encoding.
  PbfWriter? _encodeLayer(MvtLayer layer) {
    if (layer.extent < 1) {
      throw MvtEncodeException(
        'layer "${layer.name}" has a non-positive extent (${layer.extent})',
      );
    }

    final keys = <String, int>{};
    final values = <String, int>{};
    final valueWriters = <PbfWriter>[];
    final features = <PbfWriter>[];

    for (final feature in layer.features) {
      final geometry = MvtGeometryEncoder.encode(feature);
      // A feature whose geometry collapsed to nothing (every part degenerate)
      // cannot render; dropping it here keeps the dictionaries clean too.
      if (geometry.isEmpty) continue;

      final tags = <int>[];
      feature.attributes.forEach((key, value) {
        if (value == null) return;
        final keyIndex = keys.putIfAbsent(key, () => keys.length);
        final valueIndex = values.putIfAbsent(_valueKey(layer.name, value), () {
          valueWriters.add(_encodeValue(layer.name, value));
          return values.length;
        });
        tags
          ..add(keyIndex)
          ..add(valueIndex);
      });

      final f = PbfWriter();
      final id = feature.id;
      if (id != null) f.writeUint(_featureId, id);
      f.writePackedUint(_featureTags, tags);
      f.writeUint(_featureType, feature.type.value);
      f.writePackedUint(_featureGeometry, geometry);
      features.add(f);
    }

    if (features.isEmpty) return null;

    final w = PbfWriter()..writeString(_layerName, layer.name);
    for (final f in features) {
      w.writeMessage(_layerFeatures, f);
    }
    for (final k in keys.keys) {
      w.writeString(_layerKeys, k);
    }
    for (final v in valueWriters) {
      w.writeMessage(_layerValues, v);
    }
    w
      ..writeUint(_layerExtent, layer.extent)
      ..writeUint(_layerVersion, specVersion);
    return w;
  }

  /// A cache key that distinguishes values by type as well as content, so that
  /// `1` and `1.0` and `'1'` do not collapse onto one dictionary entry.
  String _valueKey(String layer, Object value) => switch (value) {
    String() => 's:$value',
    bool() => 'b:$value',
    int() => 'i:$value',
    double() => 'd:$value',
    _ => throw MvtEncodeException(
      'layer "$layer" has an attribute of unsupported type '
      '${value.runtimeType}; expected String, int, double or bool',
    ),
  };

  PbfWriter _encodeValue(String layer, Object value) {
    final w = PbfWriter();
    switch (value) {
      case String():
        w.writeString(_valueString, value);
      case bool():
        w.writeBool(_valueBool, value);
      // `int_value` is the field every decoder reads. Negative values are
      // sign-extended to ten bytes, which is acceptable for the rare negative
      // attribute and buys maximum reader compatibility.
      case int():
        w.writeInt(_valueInt, value);
      case double():
        w.writeDouble(_valueDouble, value);
      default:
        throw MvtEncodeException(
          'layer "$layer" has an attribute of unsupported type '
          '${value.runtimeType}; expected String, int, double or bool',
        );
    }
    return w;
  }
}
