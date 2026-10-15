import 'dart:typed_data';

/// Bytewords encoding/decoding for BC-UR
/// Based on https://github.com/ngraveio/bc-ur
class Bytewords {
  static const List<String> _bytewords = [
    'able',
    'acid',
    'also',
    'apex',
    'aqua',
    'arch',
    'atom',
    'aunt',
    'away',
    'axis',
    'back',
    'bald',
    'barn',
    'belt',
    'beta',
    'bias',
    'blue',
    'body',
    'brag',
    'brew',
    'bulb',
    'buzz',
    'calm',
    'cash',
    'cats',
    'chef',
    'city',
    'claw',
    'code',
    'cola',
    'cook',
    'cost',
    'crux',
    'curl',
    'cusp',
    'cyan',
    'dark',
    'data',
    'days',
    'deli',
    'dice',
    'diet',
    'door',
    'down',
    'draw',
    'drop',
    'drum',
    'dull',
    'duty',
    'each',
    'easy',
    'echo',
    'edge',
    'epic',
    'even',
    'exam',
    'exit',
    'eyes',
    'fact',
    'fair',
    'fern',
    'figs',
    'film',
    'fish',
    'fizz',
    'flap',
    'flew',
    'flux',
    'foxy',
    'free',
    'frog',
    'fuel',
    'fund',
    'gala',
    'game',
    'gear',
    'gems',
    'gift',
    'girl',
    'glow',
    'good',
    'gray',
    'grim',
    'guru',
    'gush',
    'gyro',
    'half',
    'hang',
    'hard',
    'hawk',
    'heat',
    'help',
    'high',
    'hill',
    'holy',
    'hope',
    'horn',
    'huts',
    'iced',
    'idea',
    'idle',
    'inch',
    'inky',
    'into',
    'iris',
    'iron',
    'item',
    'jade',
    'jazz',
    'join',
    'jolt',
    'jowl',
    'judo',
    'jugs',
    'jump',
    'junk',
    'jury',
    'keep',
    'keno',
    'kept',
    'keys',
    'kick',
    'kiln',
    'king',
    'kite',
    'kiwi',
    'knob',
    'lamb',
    'lava',
    'lazy',
    'leaf',
    'legs',
    'liar',
    'limp',
    'lion',
    'list',
    'logo',
    'loud',
    'love',
    'luau',
    'luck',
    'lung',
    'main',
    'many',
    'math',
    'maze',
    'memo',
    'menu',
    'meow',
    'mild',
    'mint',
    'miss',
    'monk',
    'nail',
    'navy',
    'need',
    'news',
    'next',
    'noon',
    'note',
    'numb',
    'obey',
    'oboe',
    'omit',
    'onyx',
    'open',
    'oval',
    'owls',
    'paid',
    'part',
    'peck',
    'play',
    'plus',
    'poem',
    'pool',
    'pose',
    'puff',
    'puma',
    'purr',
    'quad',
    'quiz',
    'race',
    'ramp',
    'real',
    'redo',
    'rich',
    'road',
    'rock',
    'roof',
    'ruby',
    'ruin',
    'runs',
    'rust',
    'safe',
    'saga',
    'scar',
    'sets',
    'silk',
    'skew',
    'slot',
    'soap',
    'solo',
    'song',
    'stub',
    'surf',
    'swan',
    'taco',
    'task',
    'taxi',
    'tent',
    'tied',
    'time',
    'tiny',
    'toil',
    'tomb',
    'toys',
    'trip',
    'tuna',
    'twin',
    'ugly',
    'undo',
    'unit',
    'urge',
    'user',
    'vast',
    'very',
    'veto',
    'vial',
    'vibe',
    'view',
    'visa',
    'void',
    'vows',
    'wall',
    'wand',
    'warm',
    'wasp',
    'wave',
    'waxy',
    'webs',
    'what',
    'when',
    'whiz',
    'wolf',
    'work',
    'yank',
    'yawn',
    'yell',
    'yoga',
    'yurt',
    'zaps',
    'zero',
    'zest',
    'zinc',
    'zone',
    'zoom',
  ];
  static final Map<String, int> _bytewordToIndex = Map.fromEntries(
    _bytewords.asMap().entries.map((e) => MapEntry(e.value, e.key)),
  );

  /// Encode bytes to bytewords string
  static String encode(Uint8List data, {bool minimal = false}) {
    final words = <String>[];

    for (var byte in data) {
      if (minimal) {
        // Minimal encoding uses first and last letters only
        final word = _bytewords[byte];
        words.add(word[0] + word[word.length - 1]);
      } else {
        words.add(_bytewords[byte]);
      }
    }

    // Add CRC32 checksum
    final checksum = crc32(data);
    final checksumBytes = Uint8List(4)
      ..buffer.asByteData().setUint32(0, checksum, Endian.big);

    for (var byte in checksumBytes) {
      if (minimal) {
        final word = _bytewords[byte];
        words.add(word[0] + word[word.length - 1]);
      } else {
        words.add(_bytewords[byte]);
      }
    }

    return minimal ? words.join('') : words.join(' ');
  }

  /// Decode bytewords string to bytes
  static Uint8List decode(String encoded) {
    final isMinimal = !encoded.contains(' ');
    final bytes = <int>[];

    if (isMinimal) {
      // Minimal encoding: 2 chars per word
      for (var i = 0; i < encoded.length - 8; i += 2) {
        final chars = encoded.substring(i, i + 2);
        final word = _findWord(chars[0], chars[1]);
        if (word == null) {
          throw FormatException('Invalid bytewords: $chars');
        }
        bytes.add(_bytewordToIndex[word]!);
      }

      // Extract checksum (last 4 bytes = 8 chars)
      final checksumBytes = <int>[];
      for (var i = encoded.length - 8; i < encoded.length; i += 2) {
        final chars = encoded.substring(i, i + 2);
        final word = _findWord(chars[0], chars[1]);
        if (word == null) {
          throw FormatException('Invalid bytewords checksum: $chars');
        }
        checksumBytes.add(_bytewordToIndex[word]!);
      }

      // Verify checksum
      final data = Uint8List.fromList(bytes);
      final expectedChecksum = crc32(data);
      final actualChecksum = (checksumBytes[0] << 24) |
          (checksumBytes[1] << 16) |
          (checksumBytes[2] << 8) |
          checksumBytes[3];

      if (expectedChecksum != actualChecksum) {
        throw FormatException('Invalid bytewords checksum');
      }

      return data;
    } else {
      // Standard encoding: space-separated words
      final words = encoded.split(' ');
      if (words.length < 4) {
        throw const FormatException('Invalid bytewords: too short');
      }

      // Extract data words (all except last 4)
      for (var i = 0; i < words.length - 4; i++) {
        final index = _bytewordToIndex[words[i]];
        if (index == null) {
          throw FormatException('Invalid byteword: ${words[i]}');
        }
        bytes.add(index);
      }

      // Extract checksum (last 4 words)
      final checksumBytes = <int>[];
      for (var i = words.length - 4; i < words.length; i++) {
        final index = _bytewordToIndex[words[i]];
        if (index == null) {
          throw FormatException('Invalid byteword checksum: ${words[i]}');
        }
        checksumBytes.add(index);
      }

      // Verify checksum
      final data = Uint8List.fromList(bytes);
      final expectedChecksum = crc32(data);
      final actualChecksum = (checksumBytes[0] << 24) |
          (checksumBytes[1] << 16) |
          (checksumBytes[2] << 8) |
          checksumBytes[3];

      if (expectedChecksum != actualChecksum) {
        throw FormatException('Invalid bytewords checksum');
      }

      return data;
    }
  }

  /// Find word by first and last letter (for minimal encoding)
  static String? _findWord(String first, String last) {
    for (final word in _bytewords) {
      if (word[0] == first && word[word.length - 1] == last) {
        return word;
      }
    }
    return null;
  }

  /// Calculate CRC32 checksum
  static int crc32(Uint8List data) {
    const polynomial = 0xEDB88320;
    var crc = 0xFFFFFFFF;

    for (var byte in data) {
      crc ^= byte;
      for (var i = 0; i < 8; i++) {
        if ((crc & 1) != 0) {
          crc = (crc >> 1) ^ polynomial;
        } else {
          crc >>= 1;
        }
      }
    }

    return crc ^ 0xFFFFFFFF;
  }
}
