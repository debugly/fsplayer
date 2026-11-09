#!/usr/bin/env python3
"""Execute production FSHudView on JVM UI stubs; not Android layout verification."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
PACKAGE = ROOT / 'ijkmedia/wrapper/android/fsplayer/src/main/java/com/debugly/fsplayer/player'
STUBS = {
'android.content.Context': 'public android.content.res.Resources getResources(){return new android.content.res.Resources();}',
'android.content.res.Resources': 'public android.util.DisplayMetrics getDisplayMetrics(){return new android.util.DisplayMetrics();}',
'android.util.DisplayMetrics': 'public float density=1;',
'android.util.TypedValue': 'public static final int COMPLEX_UNIT_SP=2;',
'android.graphics.Typeface': 'public static final Typeface MONOSPACE=new Typeface();',
'android.graphics.drawable.GradientDrawable': 'public void setColor(int c){} public void setCornerRadius(float r){}',
'android.text.TextUtils': 'public static boolean isEmpty(CharSequence s){return s==null||s.length()==0;}',
}
VIEW = '''package android.view;
public class View {
 public static final int GONE=8,VISIBLE=0; private int visibility;
 private final android.content.Context context;
 public View(android.content.Context c){context=c;}
 public android.content.Context getContext(){return context;}
 public android.content.res.Resources getResources(){return context.getResources();}
 public void setVisibility(int v){visibility=v;} public int getVisibility(){return visibility;}
 public void bringToFront(){} public void setLayoutParams(Object p){}
}'''
GROUP = '''package android.view;
public class ViewGroup extends View {
 private final java.util.ArrayList<View> children=new java.util.ArrayList<>();
 public ViewGroup(android.content.Context c){super(c);}
 public void addView(View v){children.add(v);} public void removeView(View v){children.remove(v);}
 public View getChildAt(int n){return children.get(n);} public int getChildCount(){return children.size();}
}'''
WIDGETS = {
'ScrollView': '''extends android.view.ViewGroup {
 public ScrollView(android.content.Context c,android.util.AttributeSet a){super(c);}
}''',
'LinearLayout': '''extends android.view.ViewGroup {
 public static final int VERTICAL=1;
 public LinearLayout(android.content.Context c){super(c);}
 public void setOrientation(int v){} public void setPadding(int a,int b,int c,int d){}
 public void setBackground(android.graphics.drawable.GradientDrawable d){}
 public static class LayoutParams { public static final int WRAP_CONTENT=-2; public LayoutParams(int w,int h){} }
}''',
'TextView': '''extends android.view.View {
 private CharSequence text=""; public TextView(android.content.Context c){super(c);}
 public void setText(CharSequence s){text=s;} public CharSequence getText(){return text;}
 public void setTextColor(int c){} public void setTextSize(int unit,float size){}
 public void setTypeface(android.graphics.Typeface t){}
}''',
}
DRIVER = '''package com.debugly.fsplayer.player;
import android.view.View;
import android.view.ViewGroup;
import android.widget.TextView;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
public class HudRendererTitleCheck {
 public static void main(String[] args) throws Exception {
  FSHudView hud=new FSHudView(new android.content.Context());
  Method setter=null;
  for(Method m:FSHudView.class.getDeclaredMethods())
   if(m.getName().equals("setRendererTitle"))setter=m;
  if(setter==null)throw new AssertionError("HUD must update actual renderer in its first/title line");
  assert !Modifier.isPublic(setter.getModifiers());
  assert !Modifier.isPrivate(setter.getModifiers()) && !Modifier.isProtected(setter.getModifiers());
  hud.appendTitle("Vulkan");hud.appendTitle("Extra title");
  hud.setHudValue("test.mp4","path");
  ViewGroup card=(ViewGroup)hud.getChildAt(0);
  TextView title=(TextView)card.getChildAt(0);
  setter.invoke(hud,"OpenGL ES 3");
  assert title.getText().toString().equals("OpenGL ES 3\\nExtra title");
  assert title.getVisibility()==View.VISIBLE;
  assert card.getChildCount()==2 && hud.allHudItem().size()==1;
  assert !hud.allHudItem().containsKey("v-renderer");
  setter.invoke(hud,"Vulkan");setter.invoke(hud,"Vulkan");
  assert title.getText().toString().equals("Vulkan\\nExtra title");
  assert card.getChildCount()==2;
  hud.clear();setter.invoke(hud,"Not initialized");
  assert title.getText().toString().equals("Not initialized");
  assert title.getVisibility()==View.VISIBLE && card.getChildCount()==1;
  System.out.println("PASS: actual renderer replaces first title, preserves later titles, no extra renderer row/API");
 }
}'''


def main():
    scratch = Path(os.environ.get('TMPDIR', str(Path.home()/'.hermes/cache/scratch')))
    scratch.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='hud-title-', dir=scratch) as directory:
        root = Path(directory)
        sources = []
        def put(name, text):
            p = root / (name.replace('.', '/') + '.java')
            p.parent.mkdir(parents=True, exist_ok=True)
            p.write_text(text)
            sources.append(str(p))
        for name, body in STUBS.items():
            package, cls = name.rsplit('.', 1)
            put(name, 'package '+package+'; public class '+cls+' {'+body+'}')
        put('android.util.AttributeSet', 'package android.util; public interface AttributeSet {}')
        put('android.view.View', VIEW)
        put('android.view.ViewGroup', GROUP)
        for name, body in WIDGETS.items():
            put('android.widget.'+name, 'package android.widget; public class '+name+' '+body)
        put('com.debugly.fsplayer.player.HudRendererTitleCheck', DRIVER)
        home = Path(os.environ.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
        javac = str(home/'bin/javac') if (home/'bin/javac').exists() else 'javac'
        java = str(home/'bin/java') if (home/'bin/java').exists() else 'java'
        subprocess.run([javac, '-d', str(root), *sources, str(PACKAGE/'FSHudView.java')], check=True, timeout=25)
        subprocess.run([java, '-ea', '-cp', str(root), 'com.debugly.fsplayer.player.HudRendererTitleCheck'], check=True, timeout=10)
    presenter = (PACKAGE/'FSHudPresenter.java').read_text()
    assert 'mHud.setRendererTitle(rendererName)' in presenter
    assert '"Renderer: "' not in presenter
    assert '"v-renderer"' not in presenter
    for relative in (
        'examples/android/aura/src/main/java/com/debugly/aura/widget/media/FSVideoView.java',
        'examples/android/aura/src/main/java/com/debugly/aura/testing/MainActivity.java',
    ):
        text = (ROOT/relative).read_text()
        assert 'appendTitle("Vulkan")' not in text and 'appendTitle("FSPlayer")' not in text
    print('PASS: presenter routes native actual renderer to title, not a labeled row')


if __name__ == '__main__':
    main()
