import 'dart:typed_data';
import 'cbor_encoder.dart';
import 'bytewords.dart';
import 'fountain_codes.dart';

/// BC-UR encoder/decoder implementation
class BCUR {
  final String type;
  final Uint8List payload;

  BCUR({required this.type, required this.payload});

  /// Create BC-UR from CBOR data
  factory BCUR.fromCbor(String type, Uint8List cbor) {
    return BCUR(type: type, payload: cbor);
  }

  /// Create BC-UR from any data (will encode to CBOR)
  factory BCUR.fromData(String type, dynamic data) {
    final cbor = CborEncoder.encode(data);
    return BCUR(type: type, payload: cbor);
  }

  /// Create BC-UR from tagged data
  factory BCUR.fromTaggedData(String type, int tag, dynamic data) {
    final cbor = CborEncoder.encodeTagged(tag, data);
    return BCUR(type: type, payload: cbor);
  }

  /// Parse BC-UR string
  factory BCUR.fromString(String ur) {
    if (!ur.startsWith('ur:')) {
      throw ArgumentError('Invalid UR: must start with "ur:"');
    }

    final parts = ur.substring(3).split('/');
    if (parts.length < 2) {
      throw ArgumentError('Invalid UR: missing type or payload');
    }

    final type = parts[0];

    // Check if it's multipart
    if (parts.length == 3) {
      // Multipart UR: ur:type/seq/fragment
      throw UnimplementedError('Multipart UR parsing not yet implemented');
    }

    // Single part UR
    final bytewordsPayload = parts[1];
    final decoded = Bytewords.decode(bytewordsPayload);

    return BCUR(type: type, payload: decoded);
  }

  /// Convert to UR string
  @override
  String toString() {
    final encoded = Bytewords.encode(payload, minimal: true);
    return 'ur:$type/$encoded';
  }

  /// Get the CBOR payload
  Uint8List getCbor() => payload;

  /// Decode CBOR payload to data
  dynamic decodeData() {
    return CborDecoder.decode(payload);
  }

  /// Get payload as hex string
  String toHex() {
    return payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Create from hex string
  factory BCUR.fromHex(String type, String hex) {
    final bytes = Uint8List.fromList(
      List.generate(hex.length ~/ 2, (i) {
        return int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
      }),
    );
    return BCUR(type: type, payload: bytes);
  }
}

/// BC-UR Fountain Encoder for multipart transmission
class BCURFountainEncoder {
  final BCUR ur;
  final FountainEncoder _encoder;
  BCURFountainEncoder(this.ur, {int maxFragmentLength = 100})
      : _encoder = FountainEncoder(
          ur.payload,
          maxFragmentLength: maxFragmentLength,
        );

  /// Get next part as UR string
  String nextPart() {
    final part = _encoder.nextPart();
    final partCbor = part.toCbor();
    final encoded = Bytewords.encode(partCbor, minimal: true);

    // Format: ur:type/seqNum-seqLength/fragment
    return 'ur:${ur.type}/${part.seqNum}-${part.seqLength}/$encoded';
  }

  /// Generate multiple parts
  List<String> generateParts(int count) {
    final parts = <String>[];
    for (int i = 0; i < count; i++) {
      parts.add(nextPart());
    }
    return parts;
  }
}

/// BC-UR Fountain Decoder for multipart reception
class BCURFountainDecoder {
  final FountainDecoder _decoder = FountainDecoder();
  String? _type;

  /// Receive a part
  void receivePart(String urPart) {
    if (!urPart.startsWith('ur:')) {
      throw ArgumentError('Invalid UR part');
    }

    final parts = urPart.substring(3).split('/');
    if (parts.length != 3) {
      throw ArgumentError('Invalid multipart UR format');
    }

    final type = parts[0];
    final seqInfo = parts[1];
    final fragment = parts[2];

    // Store type from first part
    if (_type == null) {
      _type = type;
    } else if (_type != type) {
      throw ArgumentError('Type mismatch in multipart UR');
    }

    // Parse sequence info
    final seqParts = seqInfo.split('-');
    if (seqParts.length != 2) {
      throw ArgumentError('Invalid sequence info');
    }

    final seqNum = int.parse(seqParts[0]);
    final seqLength = int.parse(seqParts[1]);

    // Decode fragment
    final fragmentData = Bytewords.decode(fragment);

    // Parse CBOR to get fountain part
    // This is simplified - real implementation would properly parse CBOR array
    final part = _parseFountainPart(fragmentData, seqNum, seqLength);

    _decoder.receivePart(part);
  }

  FountainEncoderPart _parseFountainPart(
    Uint8List cbor,
    int seqNum,
    int seqLength,
  ) {
    // Simplified CBOR parsing for fountain part
    // Real implementation would use proper CBOR decoder

    // For now, just extract the data portion
    // Assuming the CBOR structure: [seqNum, seqLength, messageLength, checksum, data]

    // Skip the array header and first 4 integers
    int offset = 1; // Skip array header

    // Skip seqNum
    if (cbor[offset] < 24) {
      offset++;
    } else if (cbor[offset] == 0x18) {
      offset += 2;
    } else if (cbor[offset] == 0x19) {
      offset += 3;
    } else {
      offset += 5;
    }

    // Skip seqLength
    if (cbor[offset] < 24) {
      offset++;
    } else if (cbor[offset] == 0x18) {
      offset += 2;
    } else if (cbor[offset] == 0x19) {
      offset += 3;
    } else {
      offset += 5;
    }

    // Parse messageLength
    int messageLength;
    if (cbor[offset] < 24) {
      messageLength = cbor[offset];
      offset++;
    } else if (cbor[offset] == 0x18) {
      messageLength = cbor[offset + 1];
      offset += 2;
    } else if (cbor[offset] == 0x19) {
      messageLength = (cbor[offset + 1] << 8) | cbor[offset + 2];
      offset += 3;
    } else {
      messageLength = (cbor[offset + 1] << 24) |
          (cbor[offset + 2] << 16) |
          (cbor[offset + 3] << 8) |
          cbor[offset + 4];
      offset += 5;
    }

    // Parse checksum
    int checksum;
    if (cbor[offset] < 24) {
      checksum = cbor[offset];
      offset++;
    } else if (cbor[offset] == 0x18) {
      checksum = cbor[offset + 1];
      offset += 2;
    } else if (cbor[offset] == 0x19) {
      checksum = (cbor[offset + 1] << 8) | cbor[offset + 2];
      offset += 3;
    } else {
      checksum = (cbor[offset + 1] << 24) |
          (cbor[offset + 2] << 16) |
          (cbor[offset + 3] << 8) |
          cbor[offset + 4];
      offset += 5;
    }

    // Parse data
    // Parse data
    int dataLength;
    if (cbor[offset] == 0x58) {
      dataLength = cbor[offset + 1];
      offset += 2;
    } else if (cbor[offset] == 0x59) {
      dataLength = (cbor[offset + 1] << 8) | cbor[offset + 2];
      offset += 3;
    } else if ((cbor[offset] & 0xE0) == 0x40) {
      dataLength = cbor[offset] & 0x1F;
      offset++;
    } else {
      // Fallback or error? Assuming > 0x59 is handled or we use 0x59 for 2 bytes
      // Original code had else for 16-bit length which corresponds to 0x59
      dataLength = (cbor[offset + 1] << 8) | cbor[offset + 2];
      offset += 3;
    }

    final data = cbor.sublist(offset, offset + dataLength);

    return FountainEncoderPart(
      seqNum: seqNum,
      seqLength: seqLength,
      messageLength: messageLength,
      checksum: checksum,
      data: data,
    );
  }

  /// Check if decoding is complete
  bool get isComplete => _decoder.isComplete;

  /// Get progress (0.0 to 1.0)
  double get progress => _decoder.progress;

  /// Get expected part count
  int get expectedCount => _decoder.expectedPartCount;

  /// Get received part count (simple parts recovered)
  int get receivedCount => _decoder.receivedPartIndexes.length;

  /// Get the decoded UR
  BCUR? getResult() {
    if (!isComplete) return null;

    final message = _decoder.getMessage();
    if (message == null || _type == null) return null;

    return BCUR(type: _type!, payload: message);
  }

  /// Reset decoder
  void reset() {
    _decoder.reset();
    _type = null;
  }
}

/// Registry item for BC-UR
abstract class BCURRegistryItem {
  final int tag;
  final String type;
  final Map<String, dynamic> data;

  BCURRegistryItem({required this.tag, required this.type, required this.data});

  /// Convert to BC-UR
  BCUR toBCUR() {
    return BCUR.fromTaggedData(type, tag, data);
  }

  /// Create from BC-UR
  static T fromBCUR<T extends BCURRegistryItem>(
    BCUR ur,
    T Function(Map<String, dynamic>) factory,
  ) {
    final decoded = ur.decodeData();

    // Extract data from tagged CBOR
    if (decoded is Map &&
        decoded.containsKey('tag') &&
        decoded.containsKey('value')) {
      return factory(decoded['value']);
    }

    // Or handle untagged data
    return factory(decoded);
  }
}
