# 隱藏 WebView 的 JS bridge：方法名稱被混淆後 JS 就呼叫不到
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
-keepattributes JavascriptInterface

# Cronet（播放影片的網路層）：Play 服務的實作是用反射找出來的，被改名就會找不到
-keep class org.chromium.net.** { *; }
-keep class com.google.android.gms.net.** { *; }
-dontwarn org.chromium.net.**

# Flutter 引擎選用的 Play Core（延遲載入元件），沒用到
-dontwarn com.google.android.play.core.**
