# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Move Jenkins out of [cluster-config](https://github.com/raulstechtips/cluster-config) into this standalone repo, which manages the Jenkins chart ([DEVSECOPS-32](https://raulstechtips.atlassian.net/browse/DEVSECOPS-32)).

### Changed

- Build this repo with the Jenkins shared library (`Jenkinsfile` and `project-pipeline-config.yaml`) and keep the GitHub Actions workflow as a manual backup ([DEVSECOPS-34](https://raulstechtips.atlassian.net/browse/DEVSECOPS-34)).
- Set the chart version to `0.0.0` and remove `appVersion`, because the build version comes from the release tags and the controller image tag comes from the chart version ([DEVSECOPS-191](https://raulstechtips.atlassian.net/browse/DEVSECOPS-191)).
- Add the `ignore-committer-strategy` plugin and use it in the organization folder build strategies, so a push with only `raulstechtips-jenkins[bot]` commits starts no branch build. Raise the `checks-api` pin to `434.va_a_3dd79d7723`, which the plugin's `junit` dependency needs ([DEVSECOPS-191](https://raulstechtips.atlassian.net/browse/DEVSECOPS-191)).

### Fixed

[Unreleased]: https://github.com/raulstechtips/jenkins/commits/main
