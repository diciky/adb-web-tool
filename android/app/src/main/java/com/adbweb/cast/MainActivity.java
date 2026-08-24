package com.adbweb.cast;

import android.app.Activity;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Bundle;
import android.view.View;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.VideoView;

public class MainActivity extends Activity implements DlnaRenderer.Listener {
  private static final int DLNA_PORT = 8192;
  private WebView web;
  private EditText url;
  private FrameLayout castOverlay;
  private VideoView castVideo;
  private DlnaRenderer dlna;
  private SharedPreferences sp;

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    setContentView(R.layout.activity_main);
    sp = getSharedPreferences("cast", MODE_PRIVATE);
    url = findViewById(R.id.url);
    web = findViewById(R.id.web);
    castOverlay = findViewById(R.id.cast_overlay);
    castVideo = findViewById(R.id.cast_video);
    Button close = findViewById(R.id.cast_close);

    WebSettings ws = web.getSettings();
    ws.setJavaScriptEnabled(true);
    ws.setDomStorageEnabled(true);
    ws.setMediaPlaybackRequiresUserGesture(false);
    ws.setAllowFileAccess(false);
    web.setWebViewClient(new WebViewClient());

    close.setOnClickListener(v -> hideCast());
    castVideo.setOnCompletionListener(mp -> hideCast());

    String saved = sp.getString("url", "http://192.168.1.100:8877");
    url.setText(saved);
    Button go = findViewById(R.id.go);
    go.setOnClickListener(v -> loadUrl(url.getText().toString()));
    loadUrl(saved);

    dlna = new DlnaRenderer(this, DLNA_PORT, this);
    dlna.start();
  }

  private void loadUrl(String u) {
    if (u == null || u.isEmpty()) return;
    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://" + u;
    sp.edit().putString("url", u).apply();
    web.loadUrl(u + (u.contains("?") ? "&" : "?") + "tab=castrecv");
  }

  private void showCast() {
    runOnUiThread(() -> castOverlay.setVisibility(View.VISIBLE));
  }

  private void hideCast() {
    runOnUiThread(() -> {
      castVideo.stopPlayback();
      castOverlay.setVisibility(View.GONE);
    });
  }

  @Override
  public void onSetUri(String uri, String title) {
    runOnUiThread(() -> {
      castOverlay.setVisibility(View.VISIBLE);
      castVideo.setVideoURI(Uri.parse(uri));
      castVideo.start();
    });
  }

  @Override
  public void onPlay() {
    runOnUiThread(() -> {
      castOverlay.setVisibility(View.VISIBLE);
      castVideo.start();
    });
  }

  @Override
  public void onPause() {
    runOnUiThread(() -> castVideo.pause());
  }

  @Override
  public void onStop() {
    hideCast();
  }

  @Override
  public void onBackPressed() {
    if (castOverlay.getVisibility() == View.VISIBLE) { hideCast(); return; }
    if (web.canGoBack()) web.goBack();
    else super.onBackPressed();
  }

  @Override
  protected void onDestroy() {
    if (dlna != null) dlna.stop();
    super.onDestroy();
  }
}
