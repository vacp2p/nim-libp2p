# Coding Style
This is a complementary coding style guide for the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/). If there are divergences, the Status Nim Style Guide should be preferred.

0. Code should be formatted with [nph](https://github.com/arnetheduck/nph) and follow the [Status Nim Style Guide](https://status-im.github.io/nim-style-guide/) above all else.

1. Use `e` for naming exception variables.
```nim
try:
  # some code
except KeyError as e:
  # exception handling
```
