package com.muye.ecells.music;

import android.app.Activity;
import androidx.core.splashscreen.SplashScreen;

/**
 * core-splashscreen 桥接。
 *
 * 该库把 installSplashScreen 编译成伴生对象上的特殊扩展形态，本项目所用
 * Kotlin 编译器（2.2.20）无法解析该符号（表现为 Unresolved reference），
 * 但字节码中 {@code SplashScreen.installSplashScreen(Activity)} 是公开静态
 * 方法，Java 侧可稳定调用——易格音乐 1.x（Java 项目）正是这种调用方式。
 * Kotlin 侧统一经本类安装启动屏。
 */
public final class SplashCompat {

    private SplashCompat() {}

    public static void install(Activity activity) {
        SplashScreen.installSplashScreen(activity);
    }
}
