# Benchmarks

Performance comparison between swift-tar and [libarchive](https://github.com/libarchive/libarchive) (C library) for reading tar archives.

## Prerequisites

```bash
# Ubuntu/Debian
sudo apt-get install -y libarchive-dev libjemalloc-dev

# macOS
brew install libarchive jemalloc

# Homebrew installs both as keg-only, so expose their pkg-config metadata.
export PKG_CONFIG_PATH="$(brew --prefix libarchive)/lib/pkgconfig:$(brew --prefix jemalloc)/lib/pkgconfig:${PKG_CONFIG_PATH}"
```

## Running

### Micro-benchmarks (package-benchmark)

Uses [package-benchmark](https://github.com/ordo-one/package-benchmark) with synthetic archives:

```bash
cd Benchmarks
swift package benchmark
```
