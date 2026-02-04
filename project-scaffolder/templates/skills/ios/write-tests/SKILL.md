---
name: write-tests
description: Write unit tests for iOS ViewModels. This skill should be used when asked to create tests, add test coverage, implement tests, write tests for a ViewModel, test a ViewModel, or add unit tests. Handles dependency injection refactoring, mock setup, and async testing patterns.
---

# Write ViewModel Tests

Write unit tests for the specified ViewModel.

## Prerequisites

This skill requires `{{PROJECT_NAME}}Tests/TEST_PATTERNS.md` to exist with mock references and testing patterns.

## Steps

1. **Read `{{PROJECT_NAME}}Tests/TEST_PATTERNS.md`** - timing, patterns, mocks, factory methods (see "Test Categories" section for what to test)

2. **Read the ViewModel source** - understand dependencies and public interface

3. **Check if DI refactoring needed** - if ViewModel uses `Service.shared`, refactor to inject protocol (see TEST_PATTERNS.md "DI Refactoring" section)

4. **Write tests** covering: initial state, data loading, user actions (with optimistic updates), computed properties (see TEST_PATTERNS.md "Test Categories" for examples)

5. **Run tests** - fix any failures before continuing

6. **Update TEST_PATTERNS.md** - if you discover new patterns, timing adjustments, or mock methods worth documenting

## Completion Checklist

- [ ] All tests pass
- [ ] Main code paths have coverage (happy path + error cases)
- [ ] Async operations tested with appropriate timing
- [ ] TEST_PATTERNS.md updated if new patterns discovered

## Running Tests

**Important**: Simulator names like `name=iPhone 16` may fail if that simulator isn't available. Always find an available simulator first:

1. **List available iPhone simulators**:
```bash
xcrun simctl list devices available | grep "iPhone" | head -5
```

2. **Run tests with a specific simulator ID** (most reliable):
```bash
xcodebuild test -project {{PROJECT_NAME}}.xcodeproj -scheme {{PROJECT_NAME}} \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_ID_FROM_STEP_1>' \
  -only-testing:{{PROJECT_NAME}}Tests/<TestClassName>
```

3. **Quick results filter**:
```bash
xcodebuild test ... 2>&1 | grep -E "(Test Case|passed|failed|error:|Executed)"
```

Never hardcode simulator names - always check what's available on the system first.

## Self-Correction

- **Mock throws "not implemented"**: Add that method to the mock (see Mocks Reference in TEST_PATTERNS.md)
- **Tests fail**: Fix and re-run before moving on
- **Need new TestDataFactory method**: Add it following existing patterns
- **ViewModel uses `.shared` directly**: Refactor for DI first (see DI Refactoring section)

## Arguments

Provide the ViewModel name (e.g., `LoginViewModel`).
