dart pub get
dart pub upgrade
dart run flutter_launcher_icons:main
dart run flutter_native_splash:create
#flutter pub run flutter_app_name
flutter gen-l10n
dart run build_runner build -d
#flutter pub run flutter_native_splash:create

(cd packages/warp_api_ffi; dart pub get; dart run build_runner build -d)

