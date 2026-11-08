#!/usr/bin/env python3
"""Compile the real private helper; exercise callback/wait lifetime with JVM stubs.
The stubs test synchronization, not Android BufferQueue or GL behavior.
"""
from pathlib import Path
import os
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[5]
helper = repo/'android/fsplayer/src/main/java/com/debugly/fsplayer/player/FSGLESCodecSurface.java'
assert helper.exists(), 'private MediaCodec SurfaceTexture helper is missing'
scratch = Path.home()/'.hermes/cache/scratch'
scratch.mkdir(parents=True, exist_ok=True)
build = Path(tempfile.mkdtemp(prefix='fs-gles-java-', dir=scratch))
sources = {
'android/os/Looper.java': 'package android.os; public class Looper {}',
'android/os/Handler.java': 'package android.os; public class Handler { public Handler(Looper l) {} }',
'android/os/HandlerThread.java': '''package android.os; public class HandlerThread {
 public static int live; public HandlerThread(String n) {} public void start(){live++;}
 public Looper getLooper(){return new Looper();} public boolean quitSafely(){live--;return true;}
}''',
'android/graphics/SurfaceTexture.java': '''package android.graphics;
import android.os.Handler;
public class SurfaceTexture {
 public interface OnFrameAvailableListener {void onFrameAvailable(SurfaceTexture t);}
 public static SurfaceTexture last; public static int live; public int updates;
 public OnFrameAvailableListener listener;
 public SurfaceTexture(int t){last=this;live++;}
 public void setOnFrameAvailableListener(OnFrameAvailableListener l, Handler h){listener=l;}
 public void signal(){if(listener!=null)listener.onFrameAvailable(this);}
 public void updateTexImage(){updates++;}
 public void getTransformMatrix(float[] m){for(int i=0;i<16;i++)m[i]=i;}
 public void release(){live--;}
}''',
'android/view/Surface.java': '''package android.view; import android.graphics.SurfaceTexture;
public class Surface {public static int live; public Surface(SurfaceTexture t){live++;}
 public void release(){live--;}}
''',
'com/debugly/fsplayer/player/CodecSurfaceTest.java': '''package com.debugly.fsplayer.player;
import android.graphics.SurfaceTexture;
public class CodecSurfaceTest {
 static void check(boolean v){if(!v)throw new AssertionError();}
 public static void main(String[] args)throws Exception {
  Thread.setDefaultUncaughtExceptionHandler((thread,error)->{error.printStackTrace();System.exit(2);});
  FSGLESCodecSurface s=new FSGLESCodecSurface(7); float[] m=new float[16];
  check(s.getSurface()!=null); check(!s.latch(m,0));
  SurfaceTexture t=SurfaceTexture.last; t.signal(); check(s.latch(m,100));
  check(t.updates==1 && m[15]==15); check(!s.latch(m,0));
  Thread producer=new Thread(()->{try{Thread.sleep(25);}catch(Exception e){}t.signal();});
  producer.start(); check(s.latch(m,500)); producer.join(); check(t.updates==2);
  long start=System.nanoTime(); check(!s.latch(m,35));
  check(System.nanoTime()-start>=20000000L); check(t.updates==2);
  Thread interrupt=new Thread(()->{Thread.currentThread().interrupt();check(!s.latch(m,500));
    check(Thread.currentThread().isInterrupted());}); interrupt.start();interrupt.join();
  Thread waiter=new Thread(()->check(!s.latch(m,1000)));waiter.start();
  Thread.sleep(20);s.release();waiter.join(500);check(!waiter.isAlive());
  s.release();check(!s.latch(m,0));check(t.listener==null);
  check(android.os.HandlerThread.live==0 && SurfaceTexture.live==0 && android.view.Surface.live==0);
  System.out.println("Java helper synchronization/lifetime PASS");
 }
}'''
}
paths=[]
for name, content in sources.items():
 p=build/name; p.parent.mkdir(parents=True,exist_ok=True);p.write_text(content);paths.append(str(p))
java_home=os.environ.get('JAVA_HOME','/Applications/Android Studio.app/Contents/jbr/Contents/Home')
subprocess.run([java_home+'/bin/javac','-source','8','-target','8','-Xlint:-options','-d',str(build),str(helper)]+paths,check=True)
subprocess.run([java_home+'/bin/java','-cp',str(build),'com.debugly.fsplayer.player.CodecSurfaceTest'],check=True)
print('JAVA CHECK PASS',build)
