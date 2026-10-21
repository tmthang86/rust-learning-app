# Test fixtures

These RSA keys exist only for tests. They are not used anywhere else and
protect nothing.

- `test-key-1.pem`, `test-key-2.pem`: private keys (2048-bit) that sign test
  App Check tokens.
- `jwks.json`: the matching public keys, with `kid` `test-1` and `test-2`,
  in the format Firebase serves at `/v1/jwks`.

Regenerate with `openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048`
and rebuild `jwks.json` from each key's modulus (exponent 65537 = `AQAB`).
