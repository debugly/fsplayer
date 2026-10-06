package tv.danmaku.ijk.media.player;

/**
 * Subtitle rendering style, the java side mirror of the native
 * FSSubtitlePreference struct (ijkmedia/ijkplayer/ff_subtitle_preference.h).
 *
 * The field names are kept identical to the native ones because the JNI layer
 * reads them by name, and the colours use the ASS layout 0xAABBGGRR where an
 * alpha of 0 means fully opaque.
 */
public class FSSubtitlePreference {
    /** Font scaling, the default is 1.0. */
    public float Scale = 1.0f;

    /** Distance from the bottom edge, in the [0.0, 1.0] range. */
    public float BottomMargin = 0.025f;

    /** Force the style below to be used instead of the one from the script. */
    public int ForceOverride = 0;

    /** Font name, must fit in 255 bytes. */
    public String FontName = "";

    /** Main fill colour. */
    public int PrimaryColour = 0xFFFFFF00;

    /** Pre-fill colour used by the karaoke mode. */
    public int SecondaryColour = 0x00FFFF00;

    /** Shadow colour. */
    public int BackColour = 0x00000080;

    /** Outline colour. */
    public int OutlineColour = 0;

    /** Outline width. */
    public float Outline = 1.0f;

    /** Folder holding the fonts, when they are not installed system-wide. */
    public String FontsDir = "";
}
