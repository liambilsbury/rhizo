#include <android/log.h>
#include <android/native_activity.h>
#include <android_native_app_glue.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <jni.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define TAG "RhizoFps"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, TAG, __VA_ARGS__)
#define FILL_LAYERS 40

struct State {
  struct android_app* app;
  EGLDisplay dpy;
  EGLSurface surf;
  EGLContext ctx;
  GLuint prog;
  GLint aPos, uColor, uScale;
  int width, height;
  int ready;
  char scene[16];
  long swapsThisSecond;
  long second;
  struct timespec secondStart;
};

static const char* kVs =
    "attribute vec2 aPos; uniform vec2 uScale;"
    "void main() { gl_Position = vec4(aPos * uScale, 0.0, 1.0); }";
static const char* kFs =
    "precision mediump float; uniform vec4 uColor;"
    "void main() { gl_FragColor = uColor; }";

// compile a shader of the given type from source
static GLuint Shader(GLenum type, const char* src) {
  GLuint s = glCreateShader(type);
  glShaderSource(s, 1, &src, NULL);
  glCompileShader(s);
  return s;
}

// read the scene name from the intent
static void ReadSceneExtra(struct State* st) {
  strcpy(st->scene, "vsync");
  JavaVM* vm = st->app->activity->vm;
  JNIEnv* env = NULL;
  if ((*vm)->AttachCurrentThread(vm, &env, NULL) != JNI_OK) return;
  jobject activity = st->app->activity->clazz;
  jclass actCls = (*env)->GetObjectClass(env, activity);
  jmethodID getIntent = (*env)->GetMethodID(env, actCls, "getIntent", "()Landroid/content/Intent;");
  jobject intent = (*env)->CallObjectMethod(env, activity, getIntent);
  if (intent) {
    jclass intCls = (*env)->GetObjectClass(env, intent);
    jmethodID getExtra = (*env)->GetMethodID(env, intCls, "getStringExtra",
                                             "(Ljava/lang/String;)Ljava/lang/String;");
    jstring key = (*env)->NewStringUTF(env, "scene");
    jstring val = (jstring)(*env)->CallObjectMethod(env, intent, getExtra, key);
    if (val) {
      const char* c = (*env)->GetStringUTFChars(env, val, NULL);
      if (c && strlen(c) < sizeof(st->scene)) strcpy(st->scene, c);
      (*env)->ReleaseStringUTFChars(env, val, c);
    }
  }
  (*vm)->DetachCurrentThread(vm);
}

// create the EGL display, context and surface and link the program
static int InitGl(struct State* st) {
  st->dpy = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  eglInitialize(st->dpy, NULL, NULL);
  const EGLint attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT, EGL_SURFACE_TYPE,
                            EGL_WINDOW_BIT, EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                            EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  eglChooseConfig(st->dpy, attribs, &cfg, 1, &n);
  if (n < 1) { LOGI("no EGL config"); return 0; }
  EGLint fmt;
  eglGetConfigAttrib(st->dpy, cfg, EGL_NATIVE_VISUAL_ID, &fmt);
  ANativeWindow_setBuffersGeometry(st->app->window, 0, 0, fmt);
  st->surf = eglCreateWindowSurface(st->dpy, cfg, st->app->window, NULL);
  const EGLint ctxAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  st->ctx = eglCreateContext(st->dpy, cfg, EGL_NO_CONTEXT, ctxAttribs);
  if (!eglMakeCurrent(st->dpy, st->surf, st->surf, st->ctx)) { LOGI("eglMakeCurrent failed"); return 0; }
  eglSwapInterval(st->dpy, 1);
  eglQuerySurface(st->dpy, st->surf, EGL_WIDTH, &st->width);
  eglQuerySurface(st->dpy, st->surf, EGL_HEIGHT, &st->height);
  st->prog = glCreateProgram();
  glAttachShader(st->prog, Shader(GL_VERTEX_SHADER, kVs));
  glAttachShader(st->prog, Shader(GL_FRAGMENT_SHADER, kFs));
  glLinkProgram(st->prog);
  glUseProgram(st->prog);
  st->aPos = glGetAttribLocation(st->prog, "aPos");
  st->uColor = glGetUniformLocation(st->prog, "uColor");
  st->uScale = glGetUniformLocation(st->prog, "uScale");
  glViewport(0, 0, st->width, st->height);
  LOGI("RhizoFps: init scene=%s w=%d h=%d renderer=%s", st->scene, st->width, st->height,
       (const char*)glGetString(GL_RENDERER));
  clock_gettime(CLOCK_MONOTONIC, &st->secondStart);
  st->ready = 1;
  return 1;
}

// draw a frame of the selected scene
static void Draw(struct State* st, long frame) {
  const int fill = strcmp(st->scene, "fill") == 0;
  float t = (frame % 120) / 120.0f;
  glClearColor(0.05f, 0.05f, 0.1f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  glEnableVertexAttribArray(st->aPos);
  if (fill) {
    static const GLfloat quad[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    glVertexAttribPointer(st->aPos, 2, GL_FLOAT, GL_FALSE, 0, quad);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glUniform2f(st->uScale, 1.0f, 1.0f);
    for (int i = 0; i < FILL_LAYERS; i++) {
      float k = (i + 1) / (float)FILL_LAYERS;
      glUniform4f(st->uColor, k, 1.0f - k, t, 0.3f);
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
    glDisable(GL_BLEND);
  } else if (strcmp(st->scene, "pattern") == 0) {
    glUniform2f(st->uScale, 1.0f, 1.0f);
    for (int cell = 0; cell < 16; cell++) {
      const int cx = cell % 4, cy = cell / 4;
      const GLfloat x0 = -1.0f + cx * 0.5f, y0 = -1.0f + cy * 0.5f;
      const GLfloat quad[] = {x0, y0, x0 + 0.5f, y0, x0, y0 + 0.5f, x0 + 0.5f, y0 + 0.5f};
      glVertexAttribPointer(st->aPos, 2, GL_FLOAT, GL_FALSE, 0, quad);
      glUniform4f(st->uColor, (cx + 1) / 4.0f, (cy + 1) / 4.0f, ((cell * 5) % 16) / 16.0f, 1.0f);
      glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }
  } else {
    static const GLfloat tri[] = {-0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f};
    glVertexAttribPointer(st->aPos, 2, GL_FLOAT, GL_FALSE, 0, tri);
    glUniform2f(st->uScale, 0.4f + 0.2f * sinf(t * 6.2831f), 0.4f + 0.2f * cosf(t * 6.2831f));
    glUniform4f(st->uColor, 0.9f, 0.6f, 0.1f, 1.0f);
    glDrawArrays(GL_TRIANGLES, 0, 3);
  }
  glDisableVertexAttribArray(st->aPos);
}

// handle the window init and term commands
static void OnCmd(struct android_app* app, int32_t cmd) {
  struct State* st = (struct State*)app->userData;
  if (cmd == APP_CMD_INIT_WINDOW && app->window) {
    ReadSceneExtra(st);
    InitGl(st);
  } else if (cmd == APP_CMD_TERM_WINDOW) {
    st->ready = 0;
  }
}

// run the event loop and draw and count frames
void android_main(struct android_app* app) {
  struct State st;
  memset(&st, 0, sizeof st);
  st.app = app;
  app->userData = &st;
  app->onAppCmd = OnCmd;
  long frame = 0;
  for (;;) {
    int events;
    struct android_poll_source* source;
    while (ALooper_pollOnce(st.ready ? 0 : -1, NULL, &events, (void**)&source) >= 0) {
      if (source) source->process(app, source);
      if (app->destroyRequested) return;
    }
    if (!st.ready) continue;
    Draw(&st, frame++);
    eglSwapBuffers(st.dpy, st.surf);
    st.swapsThisSecond++;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double elapsed = (now.tv_sec - st.secondStart.tv_sec) + (now.tv_nsec - st.secondStart.tv_nsec) / 1e9;
    if (elapsed >= 1.0) {
      st.second++;
      LOGI("RhizoFps: scene=%s second=%ld swaps=%ld w=%d h=%d elapsed_ms=%.0f", st.scene, st.second,
           st.swapsThisSecond, st.width, st.height, elapsed * 1000.0);
      st.swapsThisSecond = 0;
      st.secondStart = now;
    }
  }
}
