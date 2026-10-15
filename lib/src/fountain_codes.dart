import 'dart:typed_data';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'bytewords.dart';

// JavaScript note: this file must stay free of 64-bit integer reads, writes and shifts. On dart2js and DDC
// `ByteData.getUint64`/`setUint64` throw, and bitwise operators truncate to 32 bits. 64-bit values are
// handled as BigInt (the PRNG state) or as two 32-bit halves (CBOR integers).

/// XOR utilities for fountain codes
class Xor {
  static Uint8List xorBytes(Uint8List a, Uint8List b) {
    final length = max(a.length, b.length);
    final result = Uint8List(length);

    for (int i = 0; i < length; i++) {
      final aByte = i < a.length ? a[i] : 0;
      final bByte = i < b.length ? b[i] : 0;
      result[i] = aByte ^ bByte;
    }

    return result;
  }
}

/// Xoshiro256** 1.0 PRNG using BigInt for 64-bit accuracy
class Xoshiro256 {
  final List<BigInt> _s = List.filled(4, BigInt.zero);
  static final BigInt _mask64 = BigInt.parse('FFFFFFFFFFFFFFFF', radix: 16);

  /// Initialize with a string seed (will be hashed)
  Xoshiro256.fromString(String seed) {
    _hashThenSetS(Uint8List.fromList(seed.codeUnits));
  }

  /// Initialize with raw bytes (will be hashed)
  Xoshiro256.fromBytes(Uint8List bytes) {
    _hashThenSetS(bytes);
  }

  /// Initialize with CRC32 integer (will be hashed)
  Xoshiro256.fromCrc32(int crc32) {
    final bytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, crc32, Endian.big);
    _hashThenSetS(bytes);
  }

  void _hashThenSetS(Uint8List bytes) {
    final digest = sha256.convert(bytes).bytes;
    _setS(Uint8List.fromList(digest));
  }

  void _setS(Uint8List bytes) {
    final view = ByteData.sublistView(bytes);
    for (int i = 0; i < 4; i++) {
      // Big endian 64-bit words of the SHA256 digest, matching the C++ loop `v <<= 8; v |= a[o+n];`.
      // Read as two 32-bit halves: ByteData.getUint64 is unsupported on JavaScript.
      final high = view.getUint32(i * 8, Endian.big);
      final low = view.getUint32(i * 8 + 4, Endian.big);
      _s[i] = (BigInt.from(high) << 32) | BigInt.from(low);
    }
  }

  BigInt next() {
    final res =
        (_rotl((_s[1] * BigInt.from(5)) & _mask64, 7) * BigInt.from(9)) &
            _mask64;
    final t = (_s[1] << 17) & _mask64;

    _s[2] ^= _s[0];
    _s[3] ^= _s[1];
    _s[1] ^= _s[2]; // Corrected order matches C++
    _s[0] ^= _s[3];

    _s[2] ^= t;
    _s[3] = _rotl(_s[3], 45);

    return res;
  }

  BigInt _rotl(BigInt x, int k) {
    return ((x << k) & _mask64) | ((x >> (64 - k)));
  }

  /// Returns a double in [0, 1)
  double nextDouble() {
    // C++ implementation does next() / (MAX_UINT64 + 1)
    // MAX_UINT64 + 1 = 18446744073709551616.0
    return next().toDouble() / 18446744073709551616.0;
  }

  /// Returns an int in [low, high]
  int nextInt(int low, int high) {
    return (nextDouble() * (high - low + 1)).floor() + low;
  }

  /// Generate next byte
  int nextByte() {
    // C++: next_int(0, 255) -> next_double() * 256
    return (nextDouble() * 256).floor();
  }

  Uint8List nextData(int count) {
    final res = Uint8List(count);
    for (int i = 0; i < count; i++) {
      res[i] = nextByte();
    }
    return res;
  }
}

class RandomSampler {
  late final List<double> _probs;
  late final List<int> _aliases;

  RandomSampler(List<double> probs) {
    // Normalize given probabilities
    final sum = probs.reduce((a, b) => a + b);
    if (sum <= 0) throw ArgumentError('Sum of probabilities must be > 0');

    final n = probs.length;

    // P[i] = probs[i] * n / sum
    final P = probs.map((p) => p * n / sum).toList();

    final S = <int>[];
    final L = <int>[];

    // Set separate index lists for small and large probabilities
    // Reversed iteration order to match C++ implementation
    for (int i = n - 1; i >= 0; i--) {
      if (P[i] < 1) {
        S.add(i);
      } else {
        L.add(i);
      }
    }

    final newProbs = List<double>.filled(n, 0);
    final newAliases = List<int>.filled(n, 0);

    // Work through index lists
    while (S.isNotEmpty && L.isNotEmpty) {
      final a = S.removeLast(); // S.back(); S.pop_back();
      final g = L.removeLast(); // L.back(); L.pop_back();

      newProbs[a] = P[a];
      newAliases[a] = g;

      P[g] += P[a] - 1;

      if (P[g] < 1) {
        S.add(g);
      } else {
        L.add(g);
      }
    }

    while (L.isNotEmpty) {
      newProbs[L.removeLast()] = 1.0;
    }

    while (S.isNotEmpty) {
      newProbs[S.removeLast()] = 1.0;
    }

    _probs = newProbs;
    _aliases = newAliases;
  }

  /// Returns the next sample from two random doubles in [0, 1), drawn in this order from the RNG
  /// (the C++ implementation draws them inside, from a passed-in generator).
  int next(double r1, double r2) {
    final n = _probs.length;
    final i = (n * r1).floor();
    return r2 < _probs[i] ? i : _aliases[i];
  }
}

/// Fountain encoder part conforming to BC-UR spec
class FountainEncoderPart {
  final int seqNum;
  final int seqLength;
  final int messageLength;
  final int checksum;
  final Uint8List data;

  FountainEncoderPart({
    required this.seqNum,
    required this.seqLength,
    required this.messageLength,
    required this.checksum,
    required this.data,
  });

  factory FountainEncoderPart.fromCbor(Uint8List cbor) {
    int offset = 0;

    // Decode Array Size
    if (cbor[offset] != 0x85) {
      throw const FormatException('Invalid CBOR header');
    }
    offset++;

    // Parse seqNum
    final seqNumRes = _decodeInt(cbor, offset);
    final seqNum = seqNumRes.value;
    offset = seqNumRes.nextOffset;

    // Parse seqLength
    final seqLengthRes = _decodeInt(cbor, offset);
    final seqLength = seqLengthRes.value;
    offset = seqLengthRes.nextOffset;

    // Parse messageLength
    final messageLengthRes = _decodeInt(cbor, offset);
    final messageLength = messageLengthRes.value;
    offset = messageLengthRes.nextOffset;

    // Parse checksum
    final checksumRes = _decodeInt(cbor, offset);
    final checksum = checksumRes.value;
    offset = checksumRes.nextOffset;

    // Parse data
    final dataRes = _decodeBytes(cbor, offset);
    final data = dataRes.value;

    return FountainEncoderPart(
      seqNum: seqNum,
      seqLength: seqLength,
      messageLength: messageLength,
      checksum: checksum,
      data: data,
    );
  }

  static _IntResult _decodeInt(Uint8List cbor, int offset) {
    final first = cbor[offset];
    if (first < 24) {
      return _IntResult(first, offset + 1);
    } else if (first == 24) {
      return _IntResult(cbor[offset + 1], offset + 2);
    } else if (first == 25) {
      return _IntResult((cbor[offset + 1] << 8) | cbor[offset + 2], offset + 3);
    } else if (first == 26) {
      final value = (cbor[offset + 1] << 24) |
          (cbor[offset + 2] << 16) |
          (cbor[offset + 3] << 8) |
          cbor[offset + 4];
      return _IntResult(value, offset + 5);
    } else if (first == 27) {
      // 64-bit int, read as two 32-bit halves: ByteData.getUint64 is unsupported on JavaScript
      // (exact up to 2^53 there; the part fields are 32-bit in practice).
      final view = ByteData.sublistView(cbor, offset + 1, offset + 9);
      final value = view.getUint32(0, Endian.big) * 0x100000000 +
          view.getUint32(4, Endian.big);
      return _IntResult(value, offset + 9);
    }
    throw const FormatException('Invalid CBOR int');
  }

  static _BytesResult _decodeBytes(Uint8List cbor, int offset) {
    final first = cbor[offset];
    int length;
    int nextOffset;

    if ((first & 0xE0) == 0x40) {
      // Short or extended byte string
      final info = first & 0x1F;
      if (info < 24) {
        length = info;
        nextOffset = offset + 1;
      } else if (info == 24) {
        length = cbor[offset + 1];
        nextOffset = offset + 2;
      } else if (info == 25) {
        length = (cbor[offset + 1] << 8) | cbor[offset + 2];
        nextOffset = offset + 3;
      } else if (info == 26) {
        length = (cbor[offset + 1] << 24) |
            (cbor[offset + 2] << 16) |
            (cbor[offset + 3] << 8) |
            cbor[offset + 4];
        nextOffset = offset + 5;
      } else {
        throw const FormatException('Unsupported CBOR byte string length');
      }
    } else {
      throw const FormatException('Invalid CBOR byte string');
    }

    final data = cbor.sublist(nextOffset, nextOffset + length);
    return _BytesResult(data, nextOffset + length);
  }

  Uint8List toCbor() {
    final buffer = BytesBuilder();
    buffer.addByte(0x85); // Array with 5 elements
    _encodeInt(buffer, seqNum);
    _encodeInt(buffer, seqLength);
    _encodeInt(buffer, messageLength);
    _encodeInt(buffer, checksum);
    _encodeBytes(buffer, data);
    return buffer.toBytes();
  }

  static void _encodeInt(BytesBuilder buffer, int value) {
    if (value < 24) {
      buffer.addByte(value);
    } else if (value < 256) {
      buffer.addByte(24);
      buffer.addByte(value);
    } else if (value < 65536) {
      buffer.addByte(25);
      buffer.addByte(value >> 8);
      buffer.addByte(value & 0xFF);
    } else if (value < 4294967296) {
      buffer.addByte(26);
      buffer.addByte(value >> 24);
      buffer.addByte((value >> 16) & 0xFF);
      buffer.addByte((value >> 8) & 0xFF);
      buffer.addByte(value & 0xFF);
    } else {
      buffer.addByte(27);
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

  static void _encodeBytes(BytesBuilder buffer, Uint8List value) {
    if (value.length < 24) {
      buffer.addByte(0x40 | value.length);
    } else if (value.length < 256) {
      buffer.addByte(0x58);
      buffer.addByte(value.length);
    } else if (value.length < 65536) {
      buffer.addByte(0x59);
      buffer.addByte(value.length >> 8);
      buffer.addByte(value.length & 0xFF);
    } else {
      buffer.addByte(0x5A);
      buffer.addByte((value.length >> 24) & 0xFF);
      buffer.addByte((value.length >> 16) & 0xFF);
      buffer.addByte((value.length >> 8) & 0xFF);
      buffer.addByte(value.length & 0xFF);
    }
    buffer.add(value);
  }
}

class FountainEncoder {
  final int messageLength;
  final int fragmentLength;
  final List<Uint8List> fragments;
  final int seqLength;
  final int checksum;
  int seqNum = 0;

  FountainEncoder._(this.messageLength, this.fragmentLength, this.fragments,
      this.seqLength, this.checksum);

  factory FountainEncoder(Uint8List message,
      {int maxFragmentLength = 100,
      int minFragmentLength = 10,
      int firstSeqNum = 0}) {
    if (minFragmentLength > maxFragmentLength) {
      minFragmentLength = maxFragmentLength;
    }
    if (minFragmentLength > message.length) {
      minFragmentLength = message.length;
    }
    // Ensure min is at least 1
    if (minFragmentLength < 1) minFragmentLength = 1;

    final checksum = Bytewords.crc32(message);
    final fragmentLen = _findNominalFragmentLength(
        message.length, minFragmentLength, maxFragmentLength);
    final fragments = _partitionMessage(message, fragmentLen);
    return FountainEncoder._(
        message.length, fragmentLen, fragments, fragments.length, checksum)
      ..seqNum = firstSeqNum;
  }

  FountainEncoderPart nextPart() {
    seqNum++;
    final indexes = chooseFragments(seqNum, seqLength, checksum);
    final mixedData = _mix(indexes);
    return FountainEncoderPart(
      seqNum: seqNum,
      seqLength: seqLength,
      messageLength: messageLength,
      checksum: checksum,
      data: mixedData,
    );
  }

  bool get isComplete => seqNum >= seqLength;

  Uint8List _mix(Set<int> indexes) {
    Uint8List result = Uint8List(fragmentLength);
    for (final index in indexes) {
      result = Xor.xorBytes(result, fragments[index]);
    }
    return result;
  }

  static int _findNominalFragmentLength(
      int messageLen, int minFragmentLen, int maxFragmentLen) {
    final maxFragmentCount = messageLen ~/ minFragmentLen;
    int fragmentLen = 0;
    for (int i = 1; i <= maxFragmentCount; i++) {
      fragmentLen = (messageLen / i).ceil();
      if (fragmentLen <= maxFragmentLen) break;
    }
    return fragmentLen;
  }

  static List<Uint8List> _partitionMessage(Uint8List message, int fragmentLen) {
    List<Uint8List> fragments = [];
    int offset = 0;
    while (offset < message.length) {
      int end = min(offset + fragmentLen, message.length);
      var sub = message.sublist(offset, end);
      if (sub.length < fragmentLen) {
        // Padding
        final padded = Uint8List(fragmentLen);
        padded.setRange(0, sub.length, sub);
        fragments.add(padded);
      } else {
        fragments.add(sub);
      }
      offset += fragmentLen;
    }
    return fragments;
  }

  static List<int> shuffled(List<int> items, Xoshiro256 rng) {
    final remaining = List<int>.from(items);
    final result = <int>[];
    while (remaining.isNotEmpty) {
      final index = (rng.nextDouble() * remaining.length).floor();
      result.add(remaining[index]);
      remaining.removeAt(index);
    }
    return result;
  }

  static Set<int> chooseFragments(int seqNum, int seqLen, int checksum) {
    if (seqNum <= seqLen) {
      return {seqNum - 1};
    } else {
      // Seeding: int_to_bytes(seq_num) + int_to_bytes(checksum)
      final seed = Uint8List(8);
      seed.buffer.asByteData()
        ..setUint32(0, seqNum, Endian.big)
        ..setUint32(4, checksum, Endian.big);

      final rng = Xoshiro256.fromBytes(seed);
      final degree = chooseDegree(seqLen, rng);

      final indexes = List<int>.generate(seqLen, (i) => i);
      final shuffledIndexes = shuffled(indexes, rng);

      return shuffledIndexes.sublist(0, degree).toSet();
    }
  }

  static int chooseDegree(int seqLen, Xoshiro256 rng) {
    final probs = List<double>.generate(seqLen, (i) => 1.0 / (i + 1));
    final sampler = RandomSampler(probs);
    return sampler.next(rng.nextDouble(), rng.nextDouble()) + 1;
  }

  static Uint8List joinFragments(List<Uint8List> fragments, int messageLength) {
    final buffer = BytesBuilder();
    for (var fragment in fragments) {
      buffer.add(fragment);
    }
    final fullMessage = buffer.toBytes();
    return fullMessage.sublist(0, messageLength);
  }
}

class FountainDecoder {
  final Set<int> _receivedPartIndexes = {};
  Set<int>? _expectedPartIndexes;
  int? _expectedFragmentLen;
  int? _expectedMessageLen;
  int? _expectedChecksum;
  int _processedPartsCount = 0;
  Uint8List? _result;
  Object? _error;

  final Map<String, _DecoderPart> _simpleParts = {};
  final Map<String, _DecoderPart> _mixedParts = {};
  final List<_DecoderPart> _queuedParts = [];

  FountainDecoder();

  bool get isComplete => _result != null || _error != null;
  bool get isSuccess => _result != null;
  bool get isFailure => _error != null;
  Uint8List? get message => _result;
  int get expectedPartCount => _expectedPartIndexes?.length ?? 0;
  Set<int> get receivedPartIndexes => Set.unmodifiable(_receivedPartIndexes);
  double get estimatedPercentComplete {
    if (isComplete) return 1.0;
    if (_expectedPartIndexes == null) return 0.0;
    final estimatedInputParts = expectedPartCount * 1.75;
    return (_processedPartsCount / estimatedInputParts).clamp(0.0, 0.99);
  }

  bool receivePart(FountainEncoderPart encoderPart) {
    if (isComplete) return false;

    if (!_validatePart(encoderPart)) return false;

    final p = _DecoderPart.fromEncoderPart(encoderPart);
    _enqueue(p);

    while (!isComplete && _queuedParts.isNotEmpty) {
      _processQueueItem();
    }

    _processedPartsCount++;
    return true;
  }

  void reset() {
    _receivedPartIndexes.clear();
    _expectedPartIndexes = null;
    _expectedFragmentLen = null;
    _expectedMessageLen = null;
    _expectedChecksum = null;
    _processedPartsCount = 0;
    _result = null;
    _error = null;
    _simpleParts.clear();
    _mixedParts.clear();
    _queuedParts.clear();
  }

  void _enqueue(_DecoderPart p) {
    _queuedParts.add(p);
  }

  void _processQueueItem() {
    if (_queuedParts.isEmpty) return;
    final part = _queuedParts.removeAt(0);
    if (part.isSimple) {
      _processSimplePart(part);
    } else {
      _processMixedPart(part);
    }
  }

  void _reduceMixedBy(_DecoderPart p) {
    final reducedParts = <_DecoderPart>[];
    for (final mixedPart in _mixedParts.values) {
      reducedParts.add(_reducePartByPart(mixedPart, p));
    }

    final newMixed = <String, _DecoderPart>{};
    for (final reducedPart in reducedParts) {
      if (reducedPart.isSimple) {
        _enqueue(reducedPart);
      } else {
        newMixed[_key(reducedPart.indexes)] = reducedPart;
      }
    }
    _mixedParts.clear();
    _mixedParts.addAll(newMixed);
  }

  _DecoderPart _reducePartByPart(_DecoderPart a, _DecoderPart b) {
    if (_isStrictSubset(b.indexes, a.indexes)) {
      final newIndexes = _setDifference(a.indexes, b.indexes);
      final newData = Xor.xorBytes(a.data, b.data);
      return _DecoderPart(newIndexes, newData);
    } else {
      return a;
    }
  }

  void _processSimplePart(_DecoderPart p) {
    final fragmentIndex = p.index;
    if (_receivedPartIndexes.contains(fragmentIndex)) return;

    _simpleParts[_key(p.indexes)] = p;
    _receivedPartIndexes.add(fragmentIndex);

    if (_receivedPartIndexes.length == _expectedPartIndexes!.length) {
      // Set equality check
      // We have all parts. Reassemble.
      final sortedParts = _simpleParts.values.toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      final fragments = sortedParts.map((e) => e.data).toList();
      final message =
          FountainEncoder.joinFragments(fragments, _expectedMessageLen!);

      final checksum = Bytewords.crc32(message);
      if (checksum == _expectedChecksum) {
        _result = message;
      } else {
        _error = Exception('Invalid Checksum');
      }
    } else {
      _reduceMixedBy(p);
    }
  }

  void _processMixedPart(_DecoderPart p) {
    final key = _key(p.indexes);
    if (_mixedParts.containsKey(key)) {
      return; // Already have this exact mixed part
    }

    // Try to reduce this mixed part by existing simple parts
    _DecoderPart currentPart = p;
    for (final simplePart in _simpleParts.values) {
      currentPart = _reducePartByPart(currentPart, simplePart);
      if (currentPart.isSimple) {
        _enqueue(currentPart);
        return;
      }
    }

    // Try to reduce this mixed part by existing mixed parts
    for (final mixedPart in _mixedParts.values) {
      currentPart = _reducePartByPart(currentPart, mixedPart);
      if (currentPart.isSimple) {
        _enqueue(currentPart);
        return;
      }
    }

    // If it's still mixed and not a duplicate, add it
    _mixedParts[key] = currentPart;
  }

  /// Map key for a set of fragment indexes (Dart sets have identity equality).
  String _key(Set<int> indexes) {
    final list = indexes.toList()..sort();
    return list.join(',');
  }

  double get progress => estimatedPercentComplete;
  Uint8List? getMessage() => message;

  bool _validatePart(FountainEncoderPart part) {
    if (_expectedChecksum == null) {
      _expectedChecksum = part.checksum;
      _expectedMessageLen = part.messageLength;
      _expectedFragmentLen = part.data.length;
      _expectedPartIndexes = Set.of(List.generate(part.seqLength, (i) => i));
    } else {
      if (part.checksum != _expectedChecksum ||
          part.messageLength != _expectedMessageLen ||
          part.data.length != _expectedFragmentLen) {
        _error = Exception('Part metadata mismatch');
        return false;
      }
    }
    return true;
  }

  bool _isStrictSubset(Set<int> subset, Set<int> superset) {
    return subset.isNotEmpty &&
        superset.containsAll(subset) &&
        subset.length < superset.length;
  }

  Set<int> _setDifference(Set<int> a, Set<int> b) {
    return a.difference(b);
  }
}

class _DecoderPart {
  final Set<int> indexes;
  final Uint8List data;

  _DecoderPart(this.indexes, this.data);

  factory _DecoderPart.fromEncoderPart(FountainEncoderPart p) {
    final indexes =
        FountainEncoder.chooseFragments(p.seqNum, p.seqLength, p.checksum);
    return _DecoderPart(indexes, p.data);
  }

  bool get isSimple => indexes.length == 1;
  int get index => indexes.first;
}

class _IntResult {
  final int value;
  final int nextOffset;
  _IntResult(this.value, this.nextOffset);
}

class _BytesResult {
  final Uint8List value;
  final int nextOffset;
  _BytesResult(this.value, this.nextOffset);
}
