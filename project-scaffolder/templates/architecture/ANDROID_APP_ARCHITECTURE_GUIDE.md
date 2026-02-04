# Android App Architecture Guide

This document outlines the architectural principles and patterns for all feature development in this project.

## 1. The Core Architecture: MVI (Model-View-Intent)

Every screen follows MVI via the `MviViewModel` base class in `ui/base/MviViewModel.kt`.

-   **Model (Domain)**: Data classes in `domain/model/`. Pure Kotlin, no logic, no UI code.
-   **View (Compose)**: Renders state via `collectAsState()`, dispatches Intents to ViewModel. **No business logic.**
-   **Intent**: Sealed interface of all user actions. The ONLY way views communicate with ViewModels.
-   **ViewModel**: Extends `MviViewModel<S, I, E>`. Owns state, processes intents, emits effects for navigation/toasts.

### MVI Contract Structure

Every screen needs State, Intent, and Effect definitions:

```kotlin
// State - all UI state in one data class
data class LoginState(
    val phoneNumber: String = "",
    val password: String = "",
    val isLoading: Boolean = false,
    val error: String? = null
) : UiState

// Intent - all possible user actions
sealed interface LoginIntent : UiIntent {
    data class PhoneChanged(val phone: String) : LoginIntent
    data class PasswordChanged(val password: String) : LoginIntent
    data object LoginClicked : LoginIntent
}

// Effect - one-time events (navigation, toasts)
sealed interface LoginEffect : UiEffect {
    data object NavigateToHome : LoginEffect
    data class ShowError(val message: String) : LoginEffect
}
```

### ViewModel Implementation

```kotlin
@HiltViewModel
class LoginViewModel @Inject constructor(
    private val authRepository: AuthRepository
) : MviViewModel<LoginState, LoginIntent, LoginEffect>(LoginState()) {

    override fun processIntent(intent: LoginIntent) {
        when (intent) {
            is LoginIntent.PhoneChanged -> updateState { copy(phoneNumber = intent.phone) }
            is LoginIntent.PasswordChanged -> updateState { copy(password = intent.password) }
            is LoginIntent.LoginClicked -> performLogin()
        }
    }

    private fun performLogin() {
        viewModelScope.launch {
            updateState { copy(isLoading = true, error = null) }
            authRepository.login(currentState.phoneNumber, currentState.password)
                .onSuccess { sendEffect(LoginEffect.NavigateToHome) }
                .onFailure { updateState { copy(isLoading = false, error = it.message) } }
        }
    }
}
```

### Composable Structure

```kotlin
@Composable
fun LoginScreen(
    viewModel: LoginViewModel = hiltViewModel(),
    onNavigateToHome: () -> Unit
) {
    val state by viewModel.state.collectAsState()

    // Handle one-time effects
    LaunchedEffect(Unit) {
        viewModel.effect.collect { effect ->
            when (effect) {
                is LoginEffect.NavigateToHome -> onNavigateToHome()
                is LoginEffect.ShowError -> { /* Show snackbar */ }
            }
        }
    }

    LoginContent(
        state = state,
        onPhoneChange = { viewModel.processIntent(LoginIntent.PhoneChanged(it)) },
        onLoginClick = { viewModel.processIntent(LoginIntent.LoginClicked) }
    )
}

@Composable
private fun LoginContent(
    state: LoginState,
    onPhoneChange: (String) -> Unit,
    onLoginClick: () -> Unit
) {
    // Stateless UI - only renders based on state
}
```

## 2. User Actions: Always Use Intents

Views dispatch intents; they never call ViewModel methods directly:

```kotlin
// CORRECT
Button(onClick = { viewModel.processIntent(ItemIntent.DeleteItem(item)) })

// WRONG - don't do this
Button(onClick = { viewModel.deleteItem(item) })
```

## 3. Data Mutations: Cache and Revert Pattern

All mutations must support optimistic updates with rollback on failure:

```kotlin
private fun deleteItem(item: Item) {
    viewModelScope.launch {
        // 1. Cache current state
        val backup = currentState.items

        // 2. Optimistic update
        updateState { copy(items = items.filter { it.id != item.id }) }

        // 3. API call
        itemRepository.deleteItem(item.id)
            .onFailure {
                // 4. Revert on failure
                Timber.e(it, "Failed to delete item")
                updateState { copy(items = backup) }
                sendEffect(ItemListEffect.ShowError("Failed to delete item"))
            }
    }
}
```

## 4. Loading States

Use `LoadingState<T>` from `MviViewModel.kt` for async data:

```kotlin
data class ItemDetailState(
    val item: LoadingState<Item> = LoadingState.Idle
) : UiState

// In ViewModel
updateState { copy(item = LoadingState.Loading) }
repository.getItem(id)
    .onSuccess { updateState { copy(item = LoadingState.Success(it)) } }
    .onFailure { updateState { copy(item = LoadingState.Error(it.message ?: "Error")) } }

// In Composable - handle all states
when (val itemState = state.item) {
    is LoadingState.Idle -> { }
    is LoadingState.Loading -> CircularProgressIndicator()
    is LoadingState.Success -> ItemContent(itemState.data)
    is LoadingState.Error -> ErrorMessage(itemState.message)
}
```

## 5. Navigation: Type-Safe Routes

Routes are defined in `ui/navigation/Routes.kt` using Kotlin Serialization:

```kotlin
sealed interface Route {
    @Serializable
    data object Login : Route

    @Serializable
    data class ItemDetail(val itemId: String) : Route
}
```

Navigation happens via Effects, not directly in composables:

```kotlin
// ViewModel sends effect
sendEffect(ItemListEffect.NavigateToItem(itemId))

// Screen handles effect
LaunchedEffect(Unit) {
    viewModel.effect.collect { effect ->
        when (effect) {
            is ItemListEffect.NavigateToItem ->
                navController.navigate(Route.ItemDetail(effect.itemId))
        }
    }
}
```

## 6. Logging: Use Timber

**Always use Timber. Never use `Log.*` or `println()`.**

```kotlin
Timber.d("Loading items...")
Timber.i("Loaded ${items.size} items")
Timber.w("No refresh token found")
Timber.e(exception, "Failed to load items")
```

## 7. DTOs vs Domain Models

Keep strict separation:

-   **DTOs** (`data/remote/dto/`): Match API JSON exactly, use `@Serializable` and `@SerialName`
-   **Domain Models** (`domain/model/`): Clean Kotlin types used throughout the app

Convert DTOs to domain models in repositories:

```kotlin
// In repository
private fun ItemDto.toDomain(): Item {
    return Item(
        id = id,
        name = name,
        createdAt = createdAt?.let { LocalDateTime.parse(it.removeSuffix("Z")) }
    )
}
```

## 8. Dependency Injection

ViewModels use constructor injection:

```kotlin
@HiltViewModel
class ItemListViewModel @Inject constructor(
    private val itemRepository: ItemRepository
) : MviViewModel<...>(...)
```

Repositories bind interface to implementation in `di/RepositoryModule.kt`:

```kotlin
@Module
@InstallIn(SingletonComponent::class)
abstract class RepositoryModule {
    @Binds @Singleton
    abstract fun bindItemRepository(impl: ItemRepositoryImpl): ItemRepository
}
```

**Scope rule**: Use `@Singleton` for repositories and network components. ViewModels are scoped automatically by Hilt.

## 9. Compose Previews

**All new screens and components must have previews.** Use `PreviewData` from `ui/preview/PreviewData.kt`:

```kotlin
@Preview(showBackground = true)
@Composable
private fun ItemCardPreview() {
    AppTheme {
        ItemCard(item = PreviewData.sampleItem, onClick = {})
    }
}

@Preview(showBackground = true, uiMode = Configuration.UI_MODE_NIGHT_YES)
@Composable
private fun ItemCardDarkPreview() {
    AppTheme {
        ItemCard(item = PreviewData.sampleItem, onClick = {})
    }
}
```

Preview all states (loading, success, error, empty):

```kotlin
@Preview(name = "Loading")
@Composable
private fun ItemListLoadingPreview() {
    AppTheme {
        ItemListContent(state = ItemListState(items = LoadingState.Loading))
    }
}

@Preview(name = "Success")
@Composable
private fun ItemListSuccessPreview() {
    AppTheme {
        ItemListContent(state = ItemListState(items = LoadingState.Success(PreviewData.sampleItems)))
    }
}
```

## 10. Repository Pattern

Repositories return `Result<T>` and handle all error mapping:

```kotlin
override suspend fun getItems(): Result<List<Item>> {
    return try {
        val dtos = api.getItems()
        Result.success(dtos.map { it.toDomain() })
    } catch (e: Exception) {
        Timber.e(e, "Failed to get items")
        Result.failure(e)
    }
}
```

## 11. File Organization

```
com.yourapp/
├── data/
│   ├── local/           # TokenManager
│   ├── remote/
│   │   ├── api/         # Retrofit interface
│   │   ├── dto/         # Request/response DTOs
│   │   └── interceptor/ # Auth interceptor
│   └── repository/      # Repository implementations
├── di/                  # Hilt modules
├── domain/
│   ├── model/           # Domain entities
│   └── repository/      # Repository interfaces
└── ui/
    ├── base/            # MviViewModel
    ├── components/      # Reusable components
    ├── navigation/      # Routes + NavHost
    ├── preview/         # PreviewData
    ├── screens/{feature}/ # Screen + ViewModel per feature
    └── theme/           # Colors, Typography, Theme
```

## Quick Reference

| Task | Pattern |
|------|---------|
| Update state | `updateState { copy(field = newValue) }` |
| Navigate | `sendEffect(Effect.NavigateTo(...))` |
| Show toast | `sendEffect(Effect.ShowMessage(...))` |
| Log | `Timber.d/i/w/e(...)` |
| API call | `repo.getData().onSuccess { }.onFailure { }` |
| Collect state | `val state by viewModel.state.collectAsState()` |
| Handle effects | `LaunchedEffect(Unit) { viewModel.effect.collect { } }` |
| Dispatch action | `viewModel.processIntent(Intent.Action)` |
