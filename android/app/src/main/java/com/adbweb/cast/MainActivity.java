package com.adbweb.cast;

import android.app.Activity;
import android.content.SharedPreferences;
import android.os.Bundle;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;

public class MainActivity extends Activity {
  private WebView web;
  private EditText url;
  private SharedPreferences sp;

  @Override
  protected void onCreate(Bundle b) {
    super.onCreate(b);
    setContentView(R.layout.activity_main);
    sp = getSharedPreferences("cast", MODE_PRIVATE);
    url = findViewById(R.id.url);
    web = findViewById(R.id.web);

    WebSettings ws = web.getSettings();
    ws.setJavaScriptEnabled(true);
    ws.setDomStorageEnabled(true);
    ws.setMediaPlaybackRequiresUserGesture(false);
    ws.setAllowFileAccess(false);
    web.setWebViewClient(new WebViewClient());

    String saved = sp.getString("url", "http://192.168.1.100:8877");
    url.setText(saved);
    Button go = findViewById(R.id.go);
    go.setOnClickListener(v -> loadUrl(url.getText().toString()));
    loadUrl(saved);
  }

  private void loadUrl(String u) {
    if (u == null || u.isEmpty()) return;
    if (!u.startsWith("http://") && !u.startsWith("https://")) u = "http://" + u;
    sp.edit().putString("url", u).apply();
    web.loadUrl(u + (u.contains("?") ? "&" : "?") + "tab=castrecv");
  }

  @Override
  public void onBackPressed() {
    if (web.canGoBack()) web.goBack();
    else super.onBackPressed();
  }
}
