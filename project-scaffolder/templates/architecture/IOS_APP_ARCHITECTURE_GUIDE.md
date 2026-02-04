# iOS App Architecture Guide

This document outlines the architectural principles and patterns to be followed for all new feature development and refactoring in this project. Adhering to this guide is critical for maintaining a clean, scalable, and maintainable codebase.

## 1. The Core Architecture: MVVM (Model-View-ViewModel)

Every screen should follow the MVVM pattern, which cleanly separates presentation logic from view code and enables better testability and reusability.

-   **Model (Data Layer)**: Models represent the app's data structures and business entities. Their responsibilities are:
    -   Defining the shape of data.
    -   Being pure Swift structs or classes (typically `Codable` for JSON serialization).
    -   Containing no business logic, UI code, or network calls.
    -   Being reusable across the entire application.
    -   **Models live in the `Models/` directory and are shared between ViewModels, Services, and Views.**

-   **View (SwiftUI Views)**: For all new screens, use SwiftUI. Views should be declarative and stateless. Their only responsibilities are:
    -   Rendering UI based on the ViewModel's published state.
    -   Responding to user interactions by calling methods on the ViewModel.
    -   **Views must not contain business logic, state management, or direct network calls.**

-   **ViewModel (The "Brain")**: This is an `@Observable` class (Swift 5.9+) that acts as the brain for the screen. Its responsibilities are:
    -   Owning all the state for the screen (e.g., the current data, `isEditMode` flags).
    -   Containing all presentation logic (e.g., formatting data for display, validation).
    -   Making all network calls by communicating with the Service layer.
    -   Exposing observable state to views (automatic with `@Observable` macro).
    -   **It must never contain SwiftUI/UIKit code or have any knowledge of specific view implementations.**
    -   **ViewModels must NEVER call other services beyond their primary service.**

-   **Helper Utilities**: Pure stateless utility classes for common operations. These contain NO service calls and are used by ViewModels for formatting and parsing logic.

## 2. State Management & Data Flow: Reactive and One-Way

We use SwiftUI's `@Observable` macro (Swift 5.9+) for reactive state management.

-   **Single Source of Truth**: All state for a screen **must** be owned by its `ViewModel`.
-   **`@Observable` Macro**: ViewModels use the `@Observable` macro for automatic state tracking. No need for `@Published` or `ObservableObject`.
-   **Reactive UI**: SwiftUI views automatically update when any `@Observable` property changes. Views own the ViewModel using `@State`.

```swift
// Correct: Modern SwiftUI View with @Observable ViewModel
@Observable
class ItemListViewModel {
    var items: [Item] = []  // Automatically observable
    var isLoading: Bool = false

    func loadItems() {
        isLoading = true
        // Load items...
    }
}

struct ItemListView: View {
    @State private var viewModel = ItemListViewModel()

    var body: some View {
        // UI automatically updates when viewModel properties change
        List(viewModel.items) { item in
            Text(item.name)
        }
        .onAppear {
            viewModel.loadItems()
        }
    }
}
```

## 3. User Actions: Direct Method Calls to ViewModel

User actions flow in the opposite direction of data. Views call methods directly on the ViewModel in response to user interactions:

```swift
@Observable
class ItemListViewModel {
    var items: [Item] = []

    func deleteItem(_ item: Item) {
        // Handle deletion logic
    }
}

struct ItemListView: View {
    @State private var viewModel = ItemListViewModel()

    var body: some View {
        Button("Delete") {
            viewModel.deleteItem(selectedItem)  // Direct method call
        }
    }
}
```

## 4. Data Mutations: The "Cache and Revert" Pattern

To provide a responsive UI, we use optimistic updates. To do this safely, all data mutation methods in a `ViewModel` **must** follow this pattern:

1.  **Cache State**: Before making any changes, create a backup of the current state (`let backup = self.data`).
2.  **Optimistic Update**: Modify the observable property with the new value immediately.
3.  **API Call**: Make the network request via the service layer.
4.  **Revert on Failure**: If the API call fails, revert the property to the backup (`self.data = backup`). The UI will automatically roll back to the correct state.

```swift
@Observable
class ItemListViewModel {
    var items: [Item] = []

    func deleteItem(_ item: Item) {
        // 1. Cache current state
        let backup = self.items

        // 2. Optimistic update
        self.items.removeAll { $0.id == item.id }

        // 3. API call via service layer
        ItemService.shared.deleteItem(itemId: item.id) { [weak self] result in
            DispatchQueue.main.async {
                if case .failure = result {
                    // 4. Revert on failure
                    self?.items = backup
                }
            }
        }
    }
}
```

## 5. Logging: Use Unified Logging Framework

**CRITICAL**: Always use Apple's `os.log` unified logging framework. **NEVER use `print()` statements.**

### Logging Setup

All ViewModels, Services, and complex components should include a logger:

```swift
import os.log

@Observable
class ItemListViewModel {
    private let logger = Logger(subsystem: "com.yourapp", category: "ItemListViewModel")

    func loadItems() {
        logger.debug("Loading items...")

        ItemService.shared.fetchItems { [weak self] result in
            switch result {
            case .success(let items):
                self?.logger.info("Successfully loaded \(items.count) items")
            case .failure(let error):
                self?.logger.error("Failed to load items: \(error.localizedDescription)")
            }
        }
    }
}
```

### Log Levels

Use appropriate log levels:

- **`.debug`**: Detailed information for debugging (e.g., "Parsing URL...", "Selected date: ...")
- **`.info`**: General informational messages (e.g., "User logged in", "Item created")
- **`.warning`**: Unexpected but recoverable situations (e.g., "No refresh token found")
- **`.error`**: Errors that need attention (e.g., "API call failed", "Failed to save to keychain")

### Privacy Annotations

Use privacy annotations for sensitive data:

```swift
logger.info("User logged in: \(user.phoneNumber, privacy: .private)")
logger.debug("Loading item: \(itemId, privacy: .private)")
logger.info("Downloaded image from: \(url.absoluteString, privacy: .public)")
```

### Why Not `print()`?

- `print()` statements are unstructured and hard to filter
- No log levels or categories
- No privacy controls
- Performance overhead in production
- `os.log` integrates with Console.app and Instruments
- Automatic filtering by subsystem and category
- Better performance (compiled out when not needed)

## 6. SwiftUI Previews: PreviewData Pattern

**All new SwiftUI views must include working preview providers.** Use centralized mock data to avoid network calls:

### Key Pattern: Preview Mode Flag

ViewModels that load data on init or subscribe to services MUST support preview mode:

```swift
@Observable
class MyViewModel {
    private var isPreviewMode: Bool = false

    func setPreviewMode(_ enabled: Bool) {
        isPreviewMode = enabled
    }

    func loadData() {
        if isPreviewMode { return }  // Skip network calls in preview
        // Normal loading...
    }

    func onAppear() {
        if !isPreviewMode {
            setupSubscriptions()  // Skip Combine subscriptions in preview
        }
    }
}
```

### Rules

1. **Use `Utils/PreviewData.swift`** - All mock data lives here, reusable across all previews
2. **Add factory methods** - `PreviewData.createMockMyViewModel()` sets preview mode + mock data
3. **Guard subscriptions** - Combine publishers fire immediately and overwrite mock data
4. **Guard loadData()** - Check preview mode before any network calls
5. **Views accept optional ViewModels** - `init(viewModel: MyViewModel? = nil)` for dependency injection

### Example

```swift
// PreviewData.swift
static func createMockItemListViewModel() -> ItemListViewModel {
    let vm = ItemListViewModel()
    vm.setPreviewMode(true)  // Prevents network calls
    vm.items = [item1, item2]  // Pre-populate
    return vm
}

// View Preview
struct MyView_Previews: PreviewProvider {
    static var previews: some View {
        MyView(viewModel: PreviewData.createMockMyViewModel())
    }
}
```

**Why this matters**: Without preview mode, ViewModels make real network calls that fail in previews, or Combine subscriptions overwrite mock data with empty arrays.

## 7. Quick Reference

| Task | Pattern |
|------|---------|
| Update state | Modify `@Observable` property directly |
| User action | View calls ViewModel method |
| API mutation | Cache -> Optimistic update -> API call -> Revert on failure |
| Log message | `logger.debug/info/warning/error(...)` |
| Preview | Use `PreviewData` factory methods with preview mode |
