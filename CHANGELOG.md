# Changelog

## Unreleased

- Dependencies: dev `lints` ^3.0.0 → ^6.1.0, now enabled through `analysis_options.yaml` (recommended set). Library directive is now unnamed (`library;`).

## 1.0.2

- JavaScript (dart2js/DDC) support: the fountain encoder/decoder threw `Unsupported operation` on the web because
  the Xoshiro256 seeding used `ByteData.getUint64`. 64-bit values are now read as two 32-bit halves; the 64-bit CBOR
  integer encoder/decoder paths no longer shift past 32 bits (exact up to 2^53 on JavaScript).
- The test suite passes under `dart test -p chrome`.
- Removed leftover draft comments from `fountain_codes.dart`.

## 1.0.1

- Homepage, repository, and issue tracker URLs now point to GitLab `aa22396584/bc-ur-dart`.

## 1.0.0

- Initial release.
- Complete implementation of BC-UR specification.
- **Critical Fix**: Replaced placeholder Fountain Codes with proper Robust Soliton Distribution (RSD) encoder and Peeling decoder.
- Implemented Xoshiro128++ PRNG for deterministic block selection.
- Added CBOR and Bytewords support.
- Complete BC-UR implementation with single and multipart UR support.
- CBOR encoding/decoding.
- Bytewords encoding/decoding.
- Fountain codes for animated QR codes.
