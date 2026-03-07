---
layout: page
title: CI/CD Integration
---

# CI/CD Integration

A complete guide to running Volt API tests in your continuous integration and continuous deployment pipelines. Whether you use GitHub Actions, GitLab CI, Jenkins, or any other platform, this guide walks you through everything from first principles.

---

## Table of Contents

1. [Why API Testing in CI/CD?](#1-why-api-testing-in-cicd)
2. [Zero-Config CI Detection](#2-zero-config-ci-detection)
3. [GitHub Actions](#3-github-actions)
4. [GitLab CI](#4-gitlab-ci)
5. [Jenkins](#5-jenkins)
6. [Azure DevOps](#6-azure-devops)
7. [CircleCI](#7-circleci)
8. [Travis CI](#8-travis-ci)
9. [Bitbucket Pipelines](#9-bitbucket-pipelines)
10. [Test Reports](#10-test-reports)
11. [Exit Codes](#11-exit-codes)
12. [Environment Variables in CI](#12-environment-variables-in-ci)
13. [Data-Driven Testing in CI](#13-data-driven-testing-in-ci)
14. [Load Testing in CI](#14-load-testing-in-ci)
15. [Monitoring with CI](#15-monitoring-with-ci)
16. [Docker Integration](#16-docker-integration)
17. [Best Practices](#17-best-practices)

---

## 1. Why API Testing in CI/CD?

If you are new to CI/CD, here is the core idea: every time someone pushes code to your repository, an automated system builds your project, runs your tests, and tells you whether anything broke. This happens before the code reaches production, catching bugs early when they are cheap to fix.

**API testing** is a critical part of this. Your API is the contract between your backend and everything that consumes it -- frontend apps, mobile clients, third-party integrations, internal microservices. If someone changes a field name, removes an endpoint, or introduces a performance regression, you want to know immediately, not after users start complaining.

Here is what automated API testing in CI/CD gives you:

### Catch breaking changes instantly

A developer renames a JSON field from `user_name` to `username`. Without automated tests, this silently breaks every client that depends on the old name. With Volt tests in CI, the pipeline fails immediately and the developer sees exactly which assertion broke.

### Verify deployments automatically

After deploying to staging, your CI pipeline can run `volt test api/ --env staging` to verify that the deployed service is actually working. No manual clicking through Postman. No "it works on my machine" surprises.

### Enforce API contracts

Your `.volt` test files define what your API should return -- status codes, response shapes, header values, JSONPath assertions. These files live in git alongside your code, so every pull request shows exactly how the API contract is changing.

### Prevent regressions

When you fix a bug, add a Volt test for it. That test runs on every future push, ensuring the bug never comes back. Over time, you build up a comprehensive safety net.

### Speed up development

Developers can push code with confidence knowing that the full API test suite runs automatically. No waiting for QA to manually test every endpoint. No spreadsheets of test cases to check off.

### The Volt advantage for CI/CD

Most API testing tools require you to install a runtime (Node.js for Newman/Postman, Python for HTTPie), pull Docker images, or configure complex test environments. Volt is different:

- **Single binary, zero dependencies.** Copy one ~4 MB file into your CI environment. No `npm install`, no `pip install`, no runtime needed.
- **Starts in under 10ms.** Your CI minutes are not wasted waiting for a test runner to boot.
- **Uses ~5 MB of RAM.** Even the smallest CI runners can handle it.
- **Plain text test files.** Your `.volt` files are human-readable and git-diffable. Reviewers can understand test changes in pull requests without opening a separate tool.

---

## 2. Zero-Config CI Detection

Volt includes a built-in CI auto-detection feature. When you run `volt ci`, Volt checks for well-known environment variables set by popular CI platforms and automatically configures the output format to match.

```bash
volt ci
```

### Supported platforms

| CI Platform | Environment Variable Checked | Detection Condition |
|---|---|---|
| GitHub Actions | `GITHUB_ACTIONS` | Set to `"true"` |
| GitLab CI | `GITLAB_CI` | Set to `"true"` |
| Jenkins | `JENKINS_URL` | Present (any value) |
| Azure DevOps | `TF_BUILD` | Set to `"True"` |
| CircleCI | `CIRCLECI` | Set to `"true"` |
| Travis CI | `TRAVIS` | Set to `"true"` |
| Bitbucket Pipelines | `BITBUCKET_BUILD_NUMBER` | Present (any value) |

### How it works

When `volt ci` runs, it reads the process environment variables in the order listed above. The first match wins. For example, if `GITHUB_ACTIONS=true` is set, Volt knows it is running inside GitHub Actions and uses GitHub-native annotation format (`::error`, `::notice`) for test results. For all other platforms, it defaults to JUnit XML, which is the universal standard for CI test reporting.

Here is what happens behind the scenes:

1. Volt scans the environment for known CI variables.
2. It identifies the platform (or falls back to "Unknown").
3. It selects the appropriate report format:
   - **GitHub Actions**: GitHub annotation format (inline error/notice markers in pull requests).
   - **All other platforms**: JUnit XML format (compatible with virtually every CI system).
4. It finds all `.volt` files in the current directory (recursively).
5. It runs every test and outputs results in the detected format.
6. It exits with code `0` if all tests passed, or `1` if any test failed.

### Output example

```
Volt CI Mode - GitHub Actions
  Format: github

  Found 12 .volt file(s)

::notice file=api/health.volt::Test passed: status equals 200
::notice file=api/users.volt::Test passed: status equals 200
::notice file=api/users.volt::Test passed: $.0.name equals Leanne Graham
::error file=api/orders.volt::Expected status 200 but got 500

--- CI Summary (GitHub Actions) ---
  Total:   4
  Passed:  3
  Failed:  1
  Time:    847.3ms
  Result:  FAILED
```

You can also skip auto-detection and explicitly control the output format:

```bash
# Explicitly generate JUnit XML regardless of CI platform
volt test --report junit -o results.xml

# Explicitly generate HTML report
volt test --report html -o report.html

# Explicitly generate JSON report
volt test --report json -o results.json
```

---

## 3. GitHub Actions

GitHub Actions is the most common CI platform for open source projects. Volt provides a first-party action (`volt-api/volt-action@v1`) for the simplest setup, but you can also download the binary manually for full control.

### Option A: Using the official GitHub Action

The easiest way. One step, no configuration.

```yaml
# .github/workflows/api-tests.yml
name: API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Run API tests
        uses: volt-api/volt-action@v1
        with:
          command: test --report junit -o results.xml

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: api-test-results
          path: results.xml
```

The `volt-api/volt-action@v1` action downloads the correct Volt binary for your runner, caches it for future runs, and executes the command you specify.

The `if: always()` on the upload step is important -- it ensures the test results artifact is uploaded even when tests fail, so you can always inspect what went wrong.

### Option B: Manual binary download

If you prefer full control or need to pin a specific Volt version:

```yaml
# .github/workflows/api-tests.yml
name: API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Verify installation
        run: volt version

      - name: Run API tests
        run: volt test api/ --report junit -o results.xml

      - name: Upload JUnit results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results
          path: results.xml

      - name: Upload HTML report
        if: always()
        run: volt test api/ --report html -o report.html

      - name: Upload HTML report artifact
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: html-report
          path: report.html
```

### Using environments

If your API has different environments (dev, staging, production), you can test against each one:

```yaml
# .github/workflows/api-tests.yml
name: API Tests (Multi-Environment)
on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, staging]
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run API tests (${{ matrix.environment }})
        run: volt test api/ --env ${{ matrix.environment }} --report junit -o results-${{ matrix.environment }}.xml
        env:
          API_KEY: ${{ secrets.API_KEY }}
          API_TOKEN: ${{ secrets.API_TOKEN }}

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results-${{ matrix.environment }}
          path: results-${{ matrix.environment }}.xml
```

### Matrix testing across platforms

Test your API client on multiple operating systems:

```yaml
# .github/workflows/api-tests.yml
name: API Tests (Cross-Platform)
on: [push, pull_request]

jobs:
  test:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-latest, windows-latest]
        include:
          - os: ubuntu-latest
            binary: volt-linux-x86_64
          - os: macos-latest
            binary: volt-macos-aarch64
          - os: windows-latest
            binary: volt-windows-x86_64.exe
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        shell: bash
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/${{ matrix.binary }} -o volt
          chmod +x volt

      - name: Run API tests
        shell: bash
        run: ./volt test api/ --report junit -o results.xml

      - name: Upload test results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: test-results-${{ matrix.os }}
          path: results.xml
```

### Using `volt ci` for auto-detection

The simplest possible GitHub Actions workflow:

```yaml
# .github/workflows/api-tests.yml
name: API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: volt-api/volt-action@v1
        with:
          command: ci
```

Because `GITHUB_ACTIONS=true` is set automatically, `volt ci` will use GitHub annotation format. Failed tests appear as inline annotations directly on the pull request diff.

---

## 4. GitLab CI

GitLab CI has native support for JUnit XML reports. When you upload a JUnit file as an artifact, GitLab automatically parses it and shows test results directly in the merge request UI.

### Basic setup

```yaml
# .gitlab-ci.yml
stages:
  - test

api_tests:
  stage: test
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
    - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
    - chmod +x /usr/local/bin/volt
  script:
    - volt test api/ --report junit -o results.xml
  artifacts:
    when: always
    reports:
      junit: results.xml
    paths:
      - results.xml
    expire_in: 30 days
```

The `artifacts.reports.junit` key tells GitLab to parse the XML file and display test results in the merge request. The `when: always` ensures the artifact is saved even when tests fail.

### Multiple environments

```yaml
# .gitlab-ci.yml
stages:
  - test

.volt_base:
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
    - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
    - chmod +x /usr/local/bin/volt

test_dev:
  extends: .volt_base
  stage: test
  script:
    - volt test api/ --env dev --report junit -o results-dev.xml
  artifacts:
    when: always
    reports:
      junit: results-dev.xml

test_staging:
  extends: .volt_base
  stage: test
  script:
    - volt test api/ --env staging --report junit -o results-staging.xml
  variables:
    API_KEY: $STAGING_API_KEY
  artifacts:
    when: always
    reports:
      junit: results-staging.xml
  only:
    - main
    - merge_requests
```

### With HTML report

```yaml
# .gitlab-ci.yml
api_tests:
  stage: test
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
    - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
    - chmod +x /usr/local/bin/volt
  script:
    - volt test api/ --report junit -o results.xml
    - volt test api/ --report html -o report.html
  artifacts:
    when: always
    reports:
      junit: results.xml
    paths:
      - results.xml
      - report.html
    expire_in: 30 days
```

### Using `volt ci` for auto-detection

```yaml
# .gitlab-ci.yml
api_tests:
  stage: test
  image: alpine:latest
  before_script:
    - apk add --no-cache curl
    - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
    - chmod +x /usr/local/bin/volt
  script:
    - volt ci
```

Because GitLab sets `GITLAB_CI=true` automatically, Volt detects the platform and outputs JUnit XML.

---

## 5. Jenkins

Jenkins uses Declarative or Scripted Pipeline syntax (Jenkinsfile). It has a built-in JUnit plugin that parses XML test reports and tracks trends over time.

### Declarative Pipeline

```groovy
// Jenkinsfile
pipeline {
    agent any

    stages {
        stage('Install Volt') {
            steps {
                sh '''
                    curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
                    chmod +x volt
                '''
            }
        }

        stage('Run API Tests') {
            steps {
                sh './volt test api/ --report junit -o results.xml'
            }
        }
    }

    post {
        always {
            junit 'results.xml'
            archiveArtifacts artifacts: 'results.xml', fingerprint: true
        }
    }
}
```

The `junit 'results.xml'` step in the `post` block tells Jenkins to parse the file and display results in the build dashboard. The `always` block ensures this runs whether tests pass or fail.

### With environment variables and HTML report

```groovy
// Jenkinsfile
pipeline {
    agent any

    environment {
        API_KEY = credentials('api-key-credential-id')
        API_TOKEN = credentials('api-token-credential-id')
    }

    stages {
        stage('Install Volt') {
            steps {
                sh '''
                    curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
                    chmod +x volt
                '''
            }
        }

        stage('Lint') {
            steps {
                sh './volt lint api/'
            }
        }

        stage('Test Dev') {
            steps {
                sh './volt test api/ --env dev --report junit -o results-dev.xml'
            }
        }

        stage('Test Staging') {
            when {
                branch 'main'
            }
            steps {
                sh './volt test api/ --env staging --report junit -o results-staging.xml'
            }
        }

        stage('Generate HTML Report') {
            steps {
                sh './volt test api/ --report html -o report.html'
            }
        }
    }

    post {
        always {
            junit 'results-*.xml'
            archiveArtifacts artifacts: '*.xml, report.html', fingerprint: true
            publishHTML([
                allowMissing: true,
                alwaysLinkToLastBuild: true,
                keepAll: true,
                reportDir: '.',
                reportFiles: 'report.html',
                reportName: 'API Test Report'
            ])
        }
    }
}
```

### Using `volt ci` for auto-detection

```groovy
// Jenkinsfile
pipeline {
    agent any

    stages {
        stage('Install Volt') {
            steps {
                sh '''
                    curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
                    chmod +x volt
                '''
            }
        }

        stage('Run API Tests') {
            steps {
                sh './volt ci'
            }
        }
    }
}
```

Jenkins sets `JENKINS_URL` automatically, so `volt ci` detects the platform and outputs JUnit format.

---

## 6. Azure DevOps

Azure DevOps Pipelines support JUnit XML natively through the `PublishTestResults` task.

### Basic setup

```yaml
# azure-pipelines.yml
trigger:
  - main

pool:
  vmImage: 'ubuntu-latest'

steps:
  - script: |
      curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
      chmod +x volt
      sudo mv volt /usr/local/bin/
    displayName: 'Install Volt'

  - script: volt version
    displayName: 'Verify Volt installation'

  - script: volt test api/ --report junit -o $(Build.ArtifactStagingDirectory)/results.xml
    displayName: 'Run API tests'

  - task: PublishTestResults@2
    condition: always()
    inputs:
      testResultsFormat: 'JUnit'
      testResultsFiles: '$(Build.ArtifactStagingDirectory)/results.xml'
      testRunTitle: 'API Tests'

  - task: PublishBuildArtifacts@1
    condition: always()
    inputs:
      pathToPublish: '$(Build.ArtifactStagingDirectory)/results.xml'
      artifactName: 'test-results'
```

### With environments and secrets

```yaml
# azure-pipelines.yml
trigger:
  - main
  - develop

pool:
  vmImage: 'ubuntu-latest'

variables:
  - group: api-secrets  # Variable group containing API_KEY, API_TOKEN

stages:
  - stage: Test
    displayName: 'API Tests'
    jobs:
      - job: TestDev
        displayName: 'Test Dev Environment'
        steps:
          - script: |
              curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
              chmod +x volt
              sudo mv volt /usr/local/bin/
            displayName: 'Install Volt'

          - script: volt test api/ --env dev --report junit -o results.xml
            displayName: 'Run API tests (dev)'
            env:
              API_KEY: $(API_KEY)
              API_TOKEN: $(API_TOKEN)

          - task: PublishTestResults@2
            condition: always()
            inputs:
              testResultsFormat: 'JUnit'
              testResultsFiles: 'results.xml'
              testRunTitle: 'API Tests (Dev)'

      - job: TestStaging
        displayName: 'Test Staging Environment'
        condition: eq(variables['Build.SourceBranch'], 'refs/heads/main')
        steps:
          - script: |
              curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
              chmod +x volt
              sudo mv volt /usr/local/bin/
            displayName: 'Install Volt'

          - script: volt test api/ --env staging --report junit -o results.xml
            displayName: 'Run API tests (staging)'
            env:
              API_KEY: $(STAGING_API_KEY)

          - task: PublishTestResults@2
            condition: always()
            inputs:
              testResultsFormat: 'JUnit'
              testResultsFiles: 'results.xml'
              testRunTitle: 'API Tests (Staging)'
```

### Using `volt ci` for auto-detection

```yaml
# azure-pipelines.yml
steps:
  - script: |
      curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
      chmod +x volt
      ./volt ci
    displayName: 'Run Volt CI'
```

Azure DevOps sets `TF_BUILD=True` automatically, so `volt ci` detects the platform.

---

## 7. CircleCI

CircleCI supports JUnit XML through its `store_test_results` step, which provides test insights, timing-based splitting, and flaky test detection.

### Basic setup

```yaml
# .circleci/config.yml
version: 2.1

jobs:
  api-tests:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout

      - run:
          name: Install Volt
          command: |
            curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
            chmod +x volt
            sudo mv volt /usr/local/bin/

      - run:
          name: Run API tests
          command: volt test api/ --report junit -o results.xml

      - store_test_results:
          path: results.xml

      - store_artifacts:
          path: results.xml
          destination: test-results

workflows:
  test:
    jobs:
      - api-tests
```

### With multiple environments

```yaml
# .circleci/config.yml
version: 2.1

commands:
  install-volt:
    steps:
      - run:
          name: Install Volt
          command: |
            curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
            chmod +x volt
            sudo mv volt /usr/local/bin/

jobs:
  test-dev:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout
      - install-volt
      - run:
          name: Run API tests (dev)
          command: volt test api/ --env dev --report junit -o results.xml
      - store_test_results:
          path: results.xml
      - store_artifacts:
          path: results.xml

  test-staging:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout
      - install-volt
      - run:
          name: Run API tests (staging)
          command: volt test api/ --env staging --report junit -o results.xml
          environment:
            API_KEY: ${STAGING_API_KEY}
      - store_test_results:
          path: results.xml
      - store_artifacts:
          path: results.xml

  generate-report:
    docker:
      - image: cimg/base:stable
    steps:
      - checkout
      - install-volt
      - run:
          name: Generate HTML report
          command: volt test api/ --report html -o report.html
      - store_artifacts:
          path: report.html
          destination: html-report

workflows:
  api-tests:
    jobs:
      - test-dev
      - test-staging:
          requires:
            - test-dev
          filters:
            branches:
              only: main
      - generate-report:
          requires:
            - test-dev
```

---

## 8. Travis CI

Travis CI is configured through a `.travis.yml` file at the root of your repository.

### Basic setup

```yaml
# .travis.yml
language: minimal

before_install:
  - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
  - chmod +x volt
  - sudo mv volt /usr/local/bin/

script:
  - volt test api/ --report junit -o results.xml

after_script:
  - volt test api/ --report html -o report.html
```

### With multiple environments

```yaml
# .travis.yml
language: minimal

before_install:
  - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
  - chmod +x volt
  - sudo mv volt /usr/local/bin/

jobs:
  include:
    - stage: test
      name: "API Tests (dev)"
      script:
        - volt test api/ --env dev --report junit -o results-dev.xml

    - stage: test
      name: "API Tests (staging)"
      if: branch = main
      script:
        - volt test api/ --env staging --report junit -o results-staging.xml
      env:
        - secure: "encrypted_api_key_here"

stages:
  - test
```

### Using `volt ci` for auto-detection

```yaml
# .travis.yml
language: minimal

before_install:
  - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
  - chmod +x volt
  - sudo mv volt /usr/local/bin/

script:
  - volt ci
```

Travis sets `TRAVIS=true` automatically, so Volt detects the platform.

---

## 9. Bitbucket Pipelines

Bitbucket Pipelines is configured through a `bitbucket-pipelines.yml` file.

### Basic setup

```yaml
# bitbucket-pipelines.yml
image: alpine:latest

pipelines:
  default:
    - step:
        name: API Tests
        script:
          - apk add --no-cache curl
          - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
          - chmod +x /usr/local/bin/volt
          - volt test api/ --report junit -o results.xml
        artifacts:
          - results.xml
```

### With environments and branches

```yaml
# bitbucket-pipelines.yml
image: alpine:latest

definitions:
  steps:
    - step: &install-volt
        name: Install Volt
        script:
          - apk add --no-cache curl
          - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
          - chmod +x /usr/local/bin/volt

pipelines:
  default:
    - step:
        name: API Tests (dev)
        script:
          - apk add --no-cache curl
          - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
          - chmod +x /usr/local/bin/volt
          - volt test api/ --env dev --report junit -o results.xml
        artifacts:
          - results.xml

  branches:
    main:
      - step:
          name: API Tests (dev)
          script:
            - apk add --no-cache curl
            - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
            - chmod +x /usr/local/bin/volt
            - volt test api/ --env dev --report junit -o results-dev.xml
          artifacts:
            - results-dev.xml

      - step:
          name: API Tests (staging)
          script:
            - apk add --no-cache curl
            - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
            - chmod +x /usr/local/bin/volt
            - volt test api/ --env staging --report junit -o results-staging.xml
          artifacts:
            - results-staging.xml

      - step:
          name: Generate HTML report
          script:
            - apk add --no-cache curl
            - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
            - chmod +x /usr/local/bin/volt
            - volt test api/ --report html -o report.html
          artifacts:
            - report.html
```

### Using `volt ci` for auto-detection

```yaml
# bitbucket-pipelines.yml
image: alpine:latest

pipelines:
  default:
    - step:
        name: API Tests
        script:
          - apk add --no-cache curl
          - curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt
          - chmod +x /usr/local/bin/volt
          - volt ci
```

Bitbucket sets `BITBUCKET_BUILD_NUMBER` automatically, so Volt detects the platform.

---

## 10. Test Reports

Volt can generate test reports in three formats. Each format serves a different purpose in CI/CD.

### JUnit XML

The industry standard for CI test reporting. Supported by virtually every CI platform.

```bash
volt test api/ --report junit -o results.xml
```

This produces a standard JUnit XML file:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="volt" tests="5" failures="1" time="1.234">
    <testcase name="status equals 200" classname="api/health.volt" time="0.042" />
    <testcase name="header.content-type contains json" classname="api/health.volt" time="0.042" />
    <testcase name="status equals 200" classname="api/users.volt" time="0.187" />
    <testcase name="$.0.name equals Leanne Graham" classname="api/users.volt" time="0.187" />
    <testcase name="status equals 200" classname="api/orders.volt" time="0.963">
        <failure message="Expected status 200 but got 500" />
    </testcase>
</testsuite>
```

**When to use:** Always generate JUnit XML in CI. It is the common format that all CI platforms can parse and display. Use it for GitHub Actions, GitLab CI, Jenkins, Azure DevOps, CircleCI, Travis CI, and Bitbucket Pipelines.

### HTML report

A self-contained HTML file with a dark-themed visual report. Useful for sharing with stakeholders who do not use the CI platform directly.

```bash
volt test api/ --report html -o report.html
```

**When to use:** Generate as an artifact alongside JUnit XML. Upload it so team members can download and open it in a browser for a visual summary.

### JSON report

Machine-readable JSON output. Useful for custom dashboards, Slack notifications, or post-processing scripts.

```bash
volt test api/ --report json -o results.json
```

The JSON output includes structured data about each test -- name, file, pass/fail status, error messages, and timing -- that you can parse with `jq`, Python, or any other tool.

**When to use:** When you want to build custom integrations, send test results to Slack, update a dashboard, or do any kind of programmatic post-processing.

### Generating multiple reports at once

You can run `volt test` multiple times with different output formats. Because Volt starts in under 10ms, the overhead is negligible:

```bash
# Generate all three report formats
volt test api/ --report junit -o results.xml
volt test api/ --report html -o report.html
volt test api/ --report json -o results.json
```

---

## 11. Exit Codes

Volt uses meaningful exit codes that your CI pipeline can use to make decisions. These are compatible with HTTPie's exit code conventions.

### Exit code table

| Exit Code | Meaning | When it occurs |
|---|---|---|
| `0` | Success | Request completed successfully, all tests passed |
| `1` | General error | Parse error, file not found, invalid arguments |
| `2` | Request timeout | The request exceeded the configured timeout |
| `3` | Too many redirects | Server responded with 3xx but redirect limit was reached |
| `4` | Client error (4xx) | Server responded with 400, 401, 403, 404, etc. |
| `5` | Server error (5xx) | Server responded with 500, 502, 503, etc. |
| `6` | Connection failed | Could not connect to the server (DNS failure, connection refused, etc.) |
| `7` | TLS/SSL error | Certificate verification failed, TLS handshake error, etc. |

### The `--check-status` flag

By default, `volt run` exits with `0` as long as it receives any HTTP response, regardless of the status code. A `500 Internal Server Error` is still a successful HTTP response from Volt's perspective.

To make Volt return exit codes based on the HTTP status, use the `--check-status` flag:

```bash
# Without --check-status: exits 0 even on 500
volt run api/health.volt

# With --check-status: exits 5 on 500 responses
volt run api/health.volt --check-status
```

### Using exit codes in CI

Exit codes are especially useful for health checks and deployment gates:

```yaml
# GitHub Actions example: gate deployment on API health
- name: Check API health
  run: volt run api/health.volt --check-status --timeout 5000
  # Exit code 0 = healthy, any other code = pipeline fails

- name: Deploy to production
  if: success()
  run: ./deploy.sh
```

You can also use exit codes in shell scripts for more granular handling:

```bash
#!/bin/bash
volt run api/health.volt --check-status
exit_code=$?

case $exit_code in
  0) echo "API is healthy" ;;
  2) echo "API timed out -- possible performance issue" ;;
  4) echo "API returned client error -- check authentication" ;;
  5) echo "API returned server error -- do not deploy" ;;
  6) echo "Cannot reach API -- check network/DNS" ;;
  7) echo "TLS certificate issue -- check cert expiry" ;;
  *) echo "Unknown error (code $exit_code)" ;;
esac

exit $exit_code
```

### Exit codes with `volt test`

The `volt test` command uses its own exit code logic:

- `0` -- All tests passed.
- `1` -- One or more tests failed.

This is independent of `--check-status`. If you want both test assertions AND HTTP status code checking, use `volt test` (which inherently checks assertions including status code assertions).

---

## 12. Environment Variables in CI

Most CI platforms provide a mechanism for storing secrets (API keys, tokens, passwords) and injecting them as environment variables at runtime. Volt can read these environment variables and use them in your `.volt` files.

### How it works

There are two ways to pass secrets from your CI environment into Volt.

**Option 1: Use CI environment variables directly in `_env.volt`**

Volt resolves `{{variable_name}}` from your `_env.volt` file. You can set values in your environment files that reference CI-injected env vars, or you can override them at runtime.

Create a CI-specific environment in your `_env.volt`:

```ini
[default]
base_url = https://localhost:3000
api_key = dev-key-for-local

[ci]
base_url = https://api.staging.example.com
api_key = ${API_KEY}
```

Then run with the CI environment:

```bash
volt test api/ --env ci
```

**Option 2: Use `volt env set` in your CI script**

Set variables dynamically before running tests:

```bash
# In your CI script
volt env set api_key "$API_KEY"
volt env set api_token "$API_TOKEN"
volt env set base_url "$API_BASE_URL"
volt test api/
```

### Platform-specific examples

**GitHub Actions:**

```yaml
steps:
  - name: Run API tests
    run: volt test api/ --env ci
    env:
      API_KEY: ${{ secrets.API_KEY }}
      API_TOKEN: ${{ secrets.API_TOKEN }}
      BASE_URL: ${{ secrets.STAGING_URL }}
```

**GitLab CI:**

```yaml
api_tests:
  script:
    - volt test api/ --env ci
  variables:
    API_KEY: $CI_API_KEY          # From CI/CD settings
    API_TOKEN: $CI_API_TOKEN
```

**Jenkins:**

```groovy
environment {
    API_KEY = credentials('api-key-id')
    API_TOKEN = credentials('api-token-id')
}

stages {
    stage('Test') {
        steps {
            sh 'volt test api/ --env ci'
        }
    }
}
```

**Azure DevOps:**

```yaml
steps:
  - script: volt test api/ --env ci
    displayName: 'Run API tests'
    env:
      API_KEY: $(ApiKey)            # From pipeline variables or variable groups
      API_TOKEN: $(ApiToken)
```

### Security best practices for CI secrets

1. **Never hard-code secrets** in `.volt` files that are committed to git. Use `{{$variable}}` references (the `$` prefix ensures values are masked in output).
2. **Use your CI platform's secret store** (GitHub Secrets, GitLab CI/CD Variables, Jenkins Credentials, Azure Key Vault, etc.).
3. **Use `volt secrets detect`** in your CI pipeline to catch accidentally committed secrets:

```yaml
# Add this step before your tests
- name: Check for exposed secrets
  run: volt secrets detect api/
```

4. **Rotate secrets regularly** and use environment-specific values (different API keys for dev, staging, production).

---

## 13. Data-Driven Testing in CI

Data-driven testing lets you run the same API test template with many different inputs. This is useful for testing edge cases, validating different user roles, or running regression tests with real data.

### How it works

Create a template `.volt` file with variable placeholders, and a CSV or JSON data file with the values:

**Template: `api/create-user.volt`**

```yaml
name: Create User
method: POST
url: https://api.example.com/users
headers:
  - Content-Type: application/json
body:
  type: json
  content: |
    {
      "name": "{{name}}",
      "email": "{{email}}",
      "role": "{{role}}"
    }
tests:
  - status equals {{expected_status}}
  - $.name equals {{name}}
```

**Data file: `test-data/users.csv`**

```csv
name,email,role,expected_status
Alice,alice@example.com,admin,201
Bob,bob@example.com,user,201
,missing@example.com,user,400
Charlie,invalid-email,user,400
```

### Running data-driven tests in CI

```bash
volt test api/create-user.volt --data test-data/users.csv --report junit -o results.xml
```

Volt runs the request once for each row in the CSV, substituting the column values into the template. Each row becomes a separate test case in the JUnit report.

### CI pipeline example

```yaml
# .github/workflows/data-driven-tests.yml
name: Data-Driven API Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run data-driven tests
        run: |
          volt test api/create-user.volt --data test-data/users.csv --report junit -o results.xml
        env:
          API_KEY: ${{ secrets.API_KEY }}

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: data-driven-results
          path: results.xml
```

### JSON data source

You can also use JSON instead of CSV:

**`test-data/users.json`**

```json
[
  {"name": "Alice", "email": "alice@example.com", "role": "admin", "expected_status": "201"},
  {"name": "Bob", "email": "bob@example.com", "role": "user", "expected_status": "201"},
  {"name": "", "email": "missing@example.com", "role": "user", "expected_status": "400"}
]
```

```bash
volt test api/create-user.volt --data test-data/users.json --report junit -o results.xml
```

---

## 14. Load Testing in CI

Volt includes a built-in load testing tool (`volt bench`) that you can run in CI to catch performance regressions. This is not a full-scale load testing replacement for tools like k6 or Locust, but it is a fast way to set performance baselines and detect regressions.

### Basic load test

```bash
# Send 100 requests with 10 concurrent connections
volt bench api/health.volt -n 100 -c 10
```

Output includes:

- Total time
- Requests per second
- Latency percentiles (p50, p95, p99)
- Success/failure counts

### Load testing in CI

```yaml
# .github/workflows/performance.yml
name: Performance Tests
on:
  push:
    branches: [main]

jobs:
  bench:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run load test (health endpoint)
        run: volt bench api/health.volt -n 200 -c 20

      - name: Run load test (users endpoint)
        run: volt bench api/get-users.volt -n 100 -c 10
```

### Setting performance gates

Use `volt bench` output with a script to enforce performance thresholds:

```bash
#!/bin/bash
# performance-gate.sh

# Run bench and capture output
output=$(volt bench api/health.volt -n 100 -c 10 2>&1)
echo "$output"

# Check if median latency exceeds threshold (example: fail if > 500ms)
# Parse the output as needed for your requirements
if echo "$output" | grep -q "FAILED"; then
  echo "Performance test had failures"
  exit 1
fi
```

### Best practices for CI load testing

- **Keep it lightweight.** CI runners have limited resources. Use 50-200 requests, not thousands.
- **Test relative performance.** Compare against your own baseline, not absolute numbers. CI runners have variable performance.
- **Run on a schedule.** Load tests are slower than unit tests. Consider running them on a cron schedule rather than every push.
- **Target a staging environment.** Do not load test production from CI.

---

## 15. Monitoring with CI

Volt's `volt monitor` command can run health checks at regular intervals. While it is primarily designed for long-running monitoring, you can use it in CI for deployment verification -- checking that an endpoint is healthy after a deploy.

### Basic health check

```bash
# Check health endpoint every 10 seconds, 5 times
volt monitor api/health.volt -i 10 -n 5
```

### Post-deployment verification

```yaml
# .github/workflows/deploy.yml
name: Deploy and Verify
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Deploy to staging
        run: ./deploy.sh staging

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Wait for deployment to stabilize
        run: sleep 10

      - name: Verify deployment health
        run: volt monitor api/health.volt -i 5 -n 6
        # Checks health every 5 seconds, 6 times (30 seconds total)
        # Fails if any check returns an error

      - name: Run smoke tests
        run: volt test api/ --env staging --report junit -o results.xml

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: smoke-test-results
          path: results.xml
```

### Quick health check with `--check-status`

For a simple pass/fail health check without `volt monitor`:

```bash
# Single request, fail if not 200
volt run api/health.volt --check-status --timeout 5000
```

This exits with code `0` on success, or a non-zero code on any error (timeout, connection failure, server error, etc.). Simple and effective for deployment gates.

---

## 16. Docker Integration

Volt is an ideal tool for Docker-based CI environments. It is a single static binary with zero dependencies -- no runtime, no shared libraries, no package manager needed.

### Using Volt in a Dockerfile

```dockerfile
# Multi-stage: install Volt in a build stage, copy to runtime
FROM alpine:latest AS volt-installer
RUN apk add --no-cache curl && \
    curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt && \
    chmod +x /usr/local/bin/volt

FROM alpine:latest
COPY --from=volt-installer /usr/local/bin/volt /usr/local/bin/volt
COPY api/ /app/api/
COPY _env.volt /app/_env.volt
WORKDIR /app
ENTRYPOINT ["volt"]
CMD ["test", "api/", "--report", "junit", "-o", "results.xml"]
```

Build and run:

```bash
docker build -t api-tests .
docker run --rm -v $(pwd)/results:/app/results api-tests
```

### Minimal Docker image

Because Volt has zero dependencies, your Docker image can be incredibly small:

```dockerfile
FROM scratch
COPY volt /volt
COPY api/ /api/
ENTRYPOINT ["/volt"]
CMD ["test", "/api/"]
```

This produces a Docker image that is barely larger than the Volt binary itself (~4 MB).

Note: The `scratch` image has no shell, so you cannot use shell features. Use `alpine` if you need shell scripting around Volt commands.

### Docker Compose for testing

If your API runs in Docker Compose, you can add Volt as a test service:

```yaml
# docker-compose.test.yml
version: '3.8'

services:
  api:
    build: .
    ports:
      - "3000:3000"
    environment:
      - DATABASE_URL=postgres://db:5432/test

  db:
    image: postgres:16
    environment:
      POSTGRES_DB: test
      POSTGRES_PASSWORD: test

  api-tests:
    image: alpine:latest
    depends_on:
      api:
        condition: service_healthy
    volumes:
      - ./api:/app/api
      - ./results:/app/results
    working_dir: /app
    entrypoint: /bin/sh
    command: |
      -c "
        apk add --no-cache curl &&
        curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o /usr/local/bin/volt &&
        chmod +x /usr/local/bin/volt &&
        volt test api/ --env docker --report junit -o results/results.xml
      "
```

Run with:

```bash
docker compose -f docker-compose.test.yml up --abort-on-container-exit --exit-code-from api-tests
```

### CI with Docker

Many CI platforms use Docker under the hood. Here is a GitHub Actions example that tests an API running in a Docker container:

```yaml
# .github/workflows/integration-tests.yml
name: Integration Tests
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest

    services:
      api:
        image: your-org/your-api:latest
        ports:
          - 3000:3000
        env:
          DATABASE_URL: postgres://postgres:postgres@postgres:5432/test
        options: >-
          --health-cmd "curl -f http://localhost:3000/health || exit 1"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5

    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run integration tests
        run: volt test api/ --env ci --report junit -o results.xml
        env:
          BASE_URL: http://localhost:3000

      - name: Upload results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: integration-results
          path: results.xml
```

---

## 17. Best Practices

Here are recommendations for getting the most out of Volt in your CI/CD pipelines, gathered from real-world usage patterns.

### Organize your test files

Separate your API test files from your application code with a clear directory structure:

```
project/
  src/                  # Application source code
  api/                  # Volt API tests
    _env.volt           # Environment variables
    _collection.volt    # Shared auth and headers
    health/
      health.volt       # Health check endpoint
    auth/
      01-login.volt     # Authentication flow
      02-refresh.volt   # Token refresh
    users/
      get-users.volt    # List users
      create-user.volt  # Create user
      get-user.volt     # Get single user
  test-data/            # CSV/JSON data files for data-driven testing
    users.csv
    edge-cases.json
```

### Use environments for different stages

Define separate environments in `_env.volt` for each stage of your pipeline:

```ini
[dev]
base_url = http://localhost:3000
api_key = dev-key

[ci]
base_url = http://localhost:3000
api_key = ci-key

[staging]
base_url = https://staging.api.example.com
api_key = ${STAGING_API_KEY}

[production]
base_url = https://api.example.com
api_key = ${PROD_API_KEY}
```

Then use the `--env` flag in each CI stage:

```bash
volt test api/ --env ci          # In CI unit/integration tests
volt test api/ --env staging     # After staging deployment
volt test api/ --env production  # After production deployment (smoke tests only)
```

### Fail fast

In CI, you want to know about failures as quickly as possible. Structure your pipeline to run fast checks first:

```yaml
steps:
  # Step 1: Lint (fastest -- catches syntax errors immediately)
  - run: volt lint api/

  # Step 2: Health check (fast -- one request)
  - run: volt run api/health.volt --check-status --timeout 5000

  # Step 3: Full test suite
  - run: volt test api/ --report junit -o results.xml

  # Step 4: Load test (slowest -- only on main branch)
  - run: volt bench api/health.volt -n 100 -c 10
    if: github.ref == 'refs/heads/main'
```

### Cache the Volt binary

Most CI platforms support caching. Cache the Volt binary to avoid downloading it on every run:

**GitHub Actions:**

```yaml
- name: Cache Volt binary
  uses: actions/cache@v4
  id: volt-cache
  with:
    path: /usr/local/bin/volt
    key: volt-${{ runner.os }}-latest

- name: Install Volt
  if: steps.volt-cache.outputs.cache-hit != 'true'
  run: |
    curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
    chmod +x volt
    sudo mv volt /usr/local/bin/
```

**GitLab CI:**

```yaml
cache:
  key: volt-binary
  paths:
    - .volt-bin/

before_script:
  - |
    if [ ! -f .volt-bin/volt ]; then
      mkdir -p .volt-bin
      curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o .volt-bin/volt
      chmod +x .volt-bin/volt
    fi
  - export PATH="$PWD/.volt-bin:$PATH"
```

### Always upload artifacts

Use `if: always()` (GitHub Actions), `when: always` (GitLab), or equivalent to ensure test results are uploaded even when tests fail. This lets you inspect failures without re-running the pipeline.

### Run secret detection

Add a `volt secrets detect` step early in your pipeline to catch accidentally committed secrets:

```yaml
- name: Scan for exposed secrets
  run: volt secrets detect api/
```

This step should fail the pipeline if any unencrypted secrets are found in your `.volt` files.

### Use `volt lint` as a pre-check

Validate your `.volt` files before running tests. This catches syntax errors and malformed files instantly:

```bash
volt lint api/
```

Linting is nearly instantaneous and saves you from waiting for a full test run only to discover a typo.

### Pin Volt versions for reproducibility

Instead of always downloading `latest`, pin to a specific release for reproducible builds:

```bash
# Pin to a specific version
curl -fsSL https://github.com/volt-api/volt/releases/download/v1.1.0/volt-linux-x86_64 -o volt
```

Update the version number explicitly when you want to upgrade.

### Keep CI tests focused

Not every test belongs in CI. Think of your test suite in tiers:

| Tier | What to test | When to run | Speed |
|---|---|---|---|
| Smoke tests | Health endpoint, basic auth, one request per resource | Every push | < 5 seconds |
| Functional tests | Full CRUD flows, error cases, edge cases | Every push to main, every PR | < 30 seconds |
| Data-driven tests | Many input combinations, boundary values | Nightly or weekly | 1-5 minutes |
| Load tests | Performance baselines, latency thresholds | Nightly or before release | 1-5 minutes |
| Monitoring | Post-deploy health checks | After each deployment | 30-60 seconds |

### Use collections for ordered workflows

When tests depend on each other (login, then use token, then verify), use Volt's collection runner with numeric prefixes:

```
api/
  01-auth/
    01-login.volt          # Logs in, extracts token
    02-verify-token.volt   # Uses extracted token
  02-users/
    01-create-user.volt    # Creates user, extracts ID
    02-get-user.volt       # Fetches created user by ID
    03-delete-user.volt    # Deletes created user
```

Run the entire sequence:

```bash
volt collection api/
```

Variables extracted in one step (`extract auth_token $.token`) are automatically available in subsequent steps.

### Generate tests from existing responses

If you are adding CI tests to an existing API, use `volt generate` to bootstrap your test files:

```bash
volt generate api/users.volt -o api/users-test.volt
```

This runs the request and generates assertions based on the actual response, giving you a starting point that you can then customize.

### Validate against schemas

For strict API contract testing, combine Volt tests with JSON Schema validation:

```bash
volt validate api/users.volt --schema schemas/user-response.json
```

This ensures the response structure matches your documented schema, catching issues like missing fields, wrong types, or unexpected extra fields.

---

## Complete Example: Full CI Pipeline

Here is a complete GitHub Actions workflow that combines everything from this guide into a production-ready pipeline:

```yaml
# .github/workflows/api-pipeline.yml
name: API Test Pipeline
on:
  push:
    branches: [main, develop]
  pull_request:
    branches: [main]
  schedule:
    - cron: '0 6 * * *'  # Nightly at 6am UTC

jobs:
  lint:
    name: Lint .volt files
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: volt-api/volt-action@v1
        with:
          command: lint api/

  secret-scan:
    name: Scan for exposed secrets
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: volt-api/volt-action@v1
        with:
          command: secrets detect api/

  test:
    name: API Tests
    needs: [lint, secret-scan]
    runs-on: ubuntu-latest
    strategy:
      matrix:
        environment: [dev, staging]
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Run tests (${{ matrix.environment }})
        run: volt test api/ --env ${{ matrix.environment }} --report junit -o results.xml
        env:
          API_KEY: ${{ secrets.API_KEY }}
          API_TOKEN: ${{ secrets.API_TOKEN }}

      - name: Generate HTML report
        if: always()
        run: volt test api/ --env ${{ matrix.environment }} --report html -o report.html

      - name: Upload JUnit results
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: junit-${{ matrix.environment }}
          path: results.xml

      - name: Upload HTML report
        if: always()
        uses: actions/upload-artifact@v4
        with:
          name: html-report-${{ matrix.environment }}
          path: report.html

  data-driven:
    name: Data-Driven Tests
    needs: [lint]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' || github.event_name == 'schedule'
    steps:
      - uses: actions/checkout@v4
      - uses: volt-api/volt-action@v1
        with:
          command: test api/create-user.volt --data test-data/users.csv --report junit -o data-results.xml
      - uses: actions/upload-artifact@v4
        if: always()
        with:
          name: data-driven-results
          path: data-results.xml

  performance:
    name: Performance Baseline
    needs: [test]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: actions/checkout@v4

      - name: Install Volt
        run: |
          curl -fsSL https://github.com/volt-api/volt/releases/latest/download/volt-linux-x86_64 -o volt
          chmod +x volt
          sudo mv volt /usr/local/bin/

      - name: Load test health endpoint
        run: volt bench api/health.volt -n 200 -c 20

      - name: Load test users endpoint
        run: volt bench api/get-users.volt -n 100 -c 10
```

This pipeline:

1. **Lints** all `.volt` files for syntax errors (fast, parallel).
2. **Scans** for accidentally committed secrets (fast, parallel).
3. **Runs tests** against dev and staging environments (parallel matrix).
4. **Generates** both JUnit XML and HTML reports.
5. **Uploads** all artifacts for inspection.
6. **Runs data-driven tests** on main branch and nightly builds.
7. **Runs performance baselines** on main branch after tests pass.

All of this runs using a single ~4 MB binary with zero dependencies. No `npm install`. No Docker pulls. No runtime setup. Just Volt.
