# Changelog

This project follows [Semantic Versioning](https://semver.org). Install a release by its git tag.

## [0.2.0] - 2026-11-06

### Changed

- Requires `hall_monitor ~> 0.7`, installed from GitHub. An app that omits the git source gets a bundle error rather than the unrelated RubyGems gem.
- The test suite covers recalculation, change tracking and dedicated models against a real database.

### Fixed

- A Symbol for `records_to_update` is called on the cached class as documented, not on the data change.
- `dedicated_auto_cacher_klass_for` accepts a record as well as a class.
- `auto_cacher_list` is kept per model instead of being shared by every model.
- Running out of retries while creating a dedicated record no longer depends on `Rails.logger`.

## [0.1.0] - 2024-03-21

### Added
- Initial release
- Core AutoCacher functionality
- Support for field caching
- Support for dedicated cache models
- Integration with HallMonitor
- Thread-safe cache model creation
- Configurable callbacks and operations
