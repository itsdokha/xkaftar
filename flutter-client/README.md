# Kaftar Client

Cross-platform client for the Kaftar messenger backend.

## Run

```powershell
flutter pub get
flutter run -d windows --dart-define=APP_ENV=development --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

For Android emulators use:

```powershell
flutter run -d android --dart-define=APP_ENV=development --dart-define=API_BASE_URL=http://10.0.2.2:8000
```

For web:

```powershell
flutter run -d chrome --dart-define=APP_ENV=development --dart-define=API_BASE_URL=http://127.0.0.1:8000
```

## Build

```powershell
flutter build windows --dart-define=APP_ENV=production --dart-define=API_BASE_URL=https://kaftar.kuchizu.com
flutter build apk --dart-define=APP_ENV=production --dart-define=API_BASE_URL=https://kaftar.kuchizu.com
flutter build ios --dart-define=APP_ENV=production --dart-define=API_BASE_URL=https://kaftar.kuchizu.com
flutter build web --dart-define=APP_ENV=production --dart-define=API_BASE_URL=https://kaftar.kuchizu.com
```
