# Otto discovers file explorer callbacks by their runtime annotations.
-keepattributes RuntimeVisibleAnnotations
-keep @interface com.squareup.otto.Subscribe
-keepclassmembers class com.debugly.aura.activities.FileExplorerActivity {
    @com.squareup.otto.Subscribe <methods>;
}
