import 'dart:typed_data';
import 'dart:convert';

/// CBOR encoder for BC-UR
class CborEncoder {
  /// Encode data to CBOR format
  static Uint8List encode(dynamic data) {
    final buffer = BytesBuilder();
    _encodeValue(buffer, data);
    return buffer.toBytes();
  }

  static void _encodeValue(BytesBuilder buffer, dynamic value) {
    if (value == null) {
      buffer.addByte(0xF6); // null
    } else if (value is bool) {
      buffer.addByte(value ? 0xF5 : 0xF4); // true/false
    } else if (value is int) {
      _encodeInt(buffer, value);
    } else if (value is String) {
      _encodeString(buffer, value);
    } else if (value is Uint8List) {
      _encodeBytes(buffer, value);
    } else if (value is List) {
      _encodeArray(buffer, value);
    } else if (value is Map) {
      _encodeMap(buffer, value);
    } else {
      throw ArgumentError('Unsupported type: ${value.runtimeType}');
    }
  }

  static void _encodeInt(BytesBuilder buffer, int value) {
    if (value >= 0) {
      _encodeUnsigned(buffer, 0, value);
    } else {
      _encodeUnsigned(buffer, 1, -value - 1);
    }
  }

  static void _encodeUnsigned(BytesBuilder buffer, int majorType, int value) {
    final type = majorType << 5;
    if (value < 24) {
      buffer.addByte(type | value);
    } else if (value < 256) {
      buffer.addByte(type | 24);
      buffer.addByte(value);
    } else if (value < 65536) {
      buffer.addByte(type | 25);
      buffer.addByte(value >> 8);
      buffer.addByte(value & 0xFF);
    } else if (value < 4294967296) {
      buffer.addByte(type | 26);
      buffer.addByte(value >> 24);
      buffer.addByte((value >> 16) & 0xFF);
      buffer.addByte((value >> 8) & 0xFF);
      buffer.addByte(value & 0xFF);
    } else {
      buffer.addByte(type | 27);
      // Split into 32-bit halves first: shifts past 32 bits truncate on JavaScript.
      final high = value ~/ 0x100000000;
      final low = value - high * 0x100000000;
      buffer.addByte((high >> 24) & 0xFF);
      buffer.addByte((high >> 16) & 0xFF);
      buffer.addByte((high >> 8) & 0xFF);
      buffer.addByte(high & 0xFF);
      buffer.addByte((low >> 24) & 0xFF);
      buffer.addByte((low >> 16) & 0xFF);
      buffer.addByte((low >> 8) & 0xFF);
      buffer.addByte(low & 0xFF);
    }
  }

  static void _encodeString(BytesBuilder buffer, String value) {
    final bytes = utf8.encode(value);
    _encodeUnsigned(buffer, 3, bytes.length);
    buffer.add(bytes);
  }

  static void _encodeBytes(BytesBuilder buffer, Uint8List value) {
    _encodeUnsigned(buffer, 2, value.length);
    buffer.add(value);
  }

  static void _encodeArray(BytesBuilder buffer, List value) {
    _encodeUnsigned(buffer, 4, value.length);
    for (final item in value) {
      _encodeValue(buffer, item);
    }
  }

  static void _encodeMap(BytesBuilder buffer, Map value) {
    _encodeUnsigned(buffer, 5, value.length);
    for (final entry in value.entries) {
      _encodeValue(buffer, entry.key);
      _encodeValue(buffer, entry.value);
    }
  }

  /// Encode with tag
  static Uint8List encodeTagged(int tag, dynamic data) {
    final buffer = BytesBuilder();
    _encodeUnsigned(buffer, 6, tag);
    final encoded = encode(data);
    buffer.add(encoded);
    return buffer.toBytes();
  }
}

/// CBOR decoder for BC-UR
class CborDecoder {
  final Uint8List _data;
  int _offset = 0;

  CborDecoder(this._data);

  /// Decode CBOR data
  static dynamic decode(Uint8List data) {
    final decoder = CborDecoder(data);
    return decoder._decodeValue();
  }

  dynamic _decodeValue() {
    if (_offset >= _data.length) {
      throw const FormatException('Unexpected end of CBOR data');
    }

    final byte = _data[_offset++];
    final majorType = byte >> 5;
    final additionalInfo = byte & 0x1F;

    switch (majorType) {
      case 0: // Unsigned integer
        return _decodeUnsigned(additionalInfo);
      case 1: // Negative integer
        return -1 - _decodeUnsigned(additionalInfo);
      case 2: // Byte string
        final length = _decodeUnsigned(additionalInfo);
        return _decodeBytes(length);
      case 3: // Text string
        final length = _decodeUnsigned(additionalInfo);
        return _decodeString(length);
      case 4: // Array
        final length = _decodeUnsigned(additionalInfo);
        return _decodeArray(length);
      case 5: // Map
        final length = _decodeUnsigned(additionalInfo);
        return _decodeMap(length);
      case 6: // Tag
        final tag = _decodeUnsigned(additionalInfo);
        final value = _decodeValue();
        return {'tag': tag, 'value': value};
      case 7: // Special
        return _decodeSpecial(additionalInfo);
      default:
        throw FormatException('Invalid CBOR major type: $majorType');
    }
  }

  int _decodeUnsigned(int info) {
    if (info < 24) {
      return info;
    } else if (info == 24) {
      return _data[_offset++];
    } else if (info == 25) {
      final value = (_data[_offset] << 8) | _data[_offset + 1];
      _offset += 2;
      return value;
    } else if (info == 26) {
      final value = (_data[_offset] << 24) |
          (_data[_offset + 1] << 16) |
          (_data[_offset + 2] << 8) |
          _data[_offset + 3];
      _offset += 4;
      return value;
    } else if (info == 27) {
      // Two 32-bit halves: shifting past 32 bits truncates on JavaScript (exact up to 2^53 there).
      final high = _decodeUnsigned(26);
      final low = _decodeUnsigned(26);
      return high * 0x100000000 + low;
    } else {
      throw FormatException('Invalid additional info: $info');
    }
  }

  Uint8List _decodeBytes(int length) {
    if (_offset + length > _data.length) {
      throw FormatException('Not enough data for byte string');
    }
    final bytes = _data.sublist(_offset, _offset + length);
    _offset += length;
    return bytes;
  }

  String _decodeString(int length) {
    final bytes = _decodeBytes(length);
    return utf8.decode(bytes);
  }

  List _decodeArray(int length) {
    final array = [];
    for (int i = 0; i < length; i++) {
      array.add(_decodeValue());
    }
    return array;
  }

  Map _decodeMap(int length) {
    final map = {};
    for (int i = 0; i < length; i++) {
      final key = _decodeValue();
      final value = _decodeValue();
      map[key] = value;
    }
    return map;
  }

  dynamic _decodeSpecial(int info) {
    switch (info) {
      case 20:
        return false;
      case 21:
        return true;
      case 22:
        return null;
      default:
        throw FormatException('Unsupported special value: $info');
    }
  }
}
