# Changelog

All notable changes after the Sherlock audit will be documented in this file.

The format is based on [Common Changelog](https://common-changelog.org/).

[1.0.1]: https://github.com/ohmzeus/Cooler/compare/v1.0.0...v1.0.1
[1.0.0]: https://github.com/ohmzeus/Cooler/releases/tag/v1.0.0

## [1.0.1] - 2023-09-27

### Changed

- Updated imports so that etherscan can verify `Clearinghouse.sol` when deployed from the `olympus-v3` repo ([#65](https://github.com/ohmzeus/Cooler/pull/65)).
- Modified `extendLoan` in `Clearinghouse.sol` to add a cooler factory check + logic to sweep / defund based on the state of the contract ([#66](https://github.com/ohmzeus/Cooler/pull/66)).
- Added a getter function to `CoolerFactory.sol` to help FE retrieve the coolers of a given user ([#67](https://github.com/ohmzeus/Cooler/pull/67)).

## [1.0.0] - 2023-09-21

### Added

- Initial release
