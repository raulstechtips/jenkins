# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Move Jenkins out of [cluster-config](https://github.com/raulstechtips/cluster-config) into this standalone repo, which manages the Jenkins chart ([DEVSECOPS-32](https://raulstechtips.atlassian.net/browse/DEVSECOPS-32)).

### Changed

- Build this repo with the Jenkins shared library (`Jenkinsfile` and `project-pipeline-config.yaml`) and keep the GitHub Actions workflow as a manual backup ([DEVSECOPS-34](https://raulstechtips.atlassian.net/browse/DEVSECOPS-34)).

### Fixed

[Unreleased]: https://github.com/raulstechtips/jenkins/commits/main
